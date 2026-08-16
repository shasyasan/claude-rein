# shellcheck shell=bash
# Fixture generation for selftests, plus **the verification helpers several selftests share**.
# Keeps the shims that stand in for the real CLI in one place, so the watcher and the attach
# loop don't grow separate shims with diverging readings of the contract.
# Not an executable script, so it doesn't get the execute bit (out of scope for the --selftest
# convention).

# This file assumes the shared library (lib/rein-common.sh) has already been sourced (building
# the isolation env looks up the name of the env var that carries the never-touch roots to the
# child from there).
# **Fail this precondition check at source time.** Failing it with `return 1` inside a function
# would be silently swallowed, since none of the callers run under `set -e` -- the check would
# pass with **an env-arg list that can't carry the never-touch roots to the child** (an empty
# name, so `env` gets `=<root>` instead), and the gate would go green without ever being armed.
# This follows the same convention as the load-order checks in lib/rein-common.sh and
# lib/rein-config.sh.
if [ -z "${REIN_SELFTEST_NEVER_ROOTS_ENV_NAME:-}" ]; then
  printf 'rein: the selftest fixtures were loaded before the shared library (load lib/rein-common.sh first)\n' >&2
  exit 1
fi

# Delimiter for the fake CLI's call log (US = 0x1f). Picking a control character that never
# shows up in an argument keeps one call per line while still preserving argument boundaries
# ("$*" concatenation would lose the boundaries, and a substring grep couldn't tell an extra
# argument tacked on from one argument split in two).
# Log line shape: <argc>US<argv1>US<argv2>...
REIN_ST_US="$(printf '\037')"
# What newlines inside an argument fold to (RS = 0x1e). kickoff carries the handover-request
# command with newlines in it, so this folds them to one character to keep the one-call-per-line
# log shape while still letting a check see past the end of the command to whatever follows it.
# shellcheck disable=SC2034  # read by each script's selftest, which sources this file
REIN_ST_RS="$(printf '\036')"

# **The bash a selftest uses when it spawns itself or a neighboring script as a child.** Plain
# `bash` would run whatever bash sits first on PATH (a Homebrew 5.x, say), so even when
# check.sh's bash32 gate pins the outer runner to /bin/bash, **the code under test would never
# once run under 3.2** -- the gate would report PASS while missing anything that only breaks
# under 3.2 (measured: placing a logging shim at the front of PATH and running
# scripts/rein-request.sh --selftest showed all 98 internal launches going through PATH). The
# default is **the bash currently running this process** (`$BASH`), so the outer and inner runs
# are always the same implementation. `REIN_SELFTEST_BASH` is the override point for that
# default -- check.sh's bash32 gate passes the actual 3.2 binary through here.
# shellcheck disable=SC2034  # read by each script's selftest, which sources this file
REIN_ST_BASH="${REIN_SELFTEST_BASH:-${BASH:-bash}}"

# Substring matching against stdout. **This lives in this file because both the hook runner
# (scripts/rein-hook.sh) and the CLI (scripts/lib/cli/selftest/) share this one implementation.**
# The CLI's helpers.sh can't be loaded from the hook side -- `st_run` (helpers.sh runs
# "$REIN_BIN_PATH" "$@", while the hook side streams the payload through stdin and captures
# stdout and stderr separately) and `st_cleanup` (helpers.sh's version calls `st_stop_watchers`,
# which calls the CLI-only `watcher_state`) are different functions under the same name, so
# whichever side loaded the other would break its own startup and teardown. Consolidating them
# into this file, which both sides already load, removes any room for the two implementations to
# drift apart -- rather than leaving a cross-check to chase the drift after the fact.
# Call convention: `<case name> <expected string>`.

# Catches an expected string written **with a literal backslash-tab or backslash-newline**
# (`\t` isn't TAB, it's the two characters "\" and "t") as a mis-written check. This form can
# never match real output, so the contains side is always false and the not_contains side is
# always true -- **it goes green without measuring anything.** Use `$'\t'` (ANSI-C quoting) to
# write an actual control character. The judgment is routed through this one function because
# two helpers with their own separate spellings of it would leave one of them lax. Returns the
# literal spelling it found, so the failure message can say what was in there.
rein_st_needle_escape_literal() {
  case "$1" in
    *'\t'*) printf '%s\n' '\t' ;;
    *'\n'*) printf '%s\n' '\n' ;;
    *'\r'*) printf '%s\n' '\r' ;;
    *) return 1 ;;
  esac
  return 0
}

# A call with an empty expected string **always matches** (`*""*` matches any string), which
# would bank a pass without ever looking at the output. Calls that pass the needle through a
# whole variable do exist, so a typo'd variable name would go green (it passes the selftest
# gate and the shellcheck gate both). Fails an empty needle as a mis-written check -- an
# unmeasured check doesn't get counted as a pass.
st_expect_contains() {
  local name="$1" needle="$2" escape
  if [ -z "$needle" ]; then
    st_fail "${name}" "the expected string is empty (a mis-written check -- it succeeds without ever looking at the output)"
    return
  fi
  if escape="$(rein_st_needle_escape_literal "$needle")"; then
    st_fail "${name}" "the expected string has a literal backslash-${escape} in it (a mis-written check -- it can never match real output; write the real character as \$'${escape}'): ${needle}"
    return
  fi
  case "$ST_OUT" in
    *"$needle"*)
      st_ok
      ;;
    *)
      st_fail "${name}" "${needle} did not appear: ${ST_OUT}"
      ;;
  esac
}

# The must-not-appear side catches the same mis-written check. Here a mismatch is the expected
# outcome, so the mis-written form flips to **always true** -- it adds a passing check without
# ever failing (harder to spot than on the contains side).
st_expect_not_contains() {
  local name="$1" needle="$2" escape
  if escape="$(rein_st_needle_escape_literal "$needle")"; then
    st_fail "${name}" "the expected string has a literal backslash-${escape} in it (a mis-written check -- it can never match real output, so it always succeeds): ${needle}"
    return
  fi
  case "$ST_OUT" in
    *"$needle"*)
      st_fail "${name}" "${needle} should not appear: ${ST_OUT}"
      ;;
    *)
      st_ok
      ;;
  esac
}

# The list of roots (newline-separated) that a check's child process **must never resolve as a
# location to write to**. Built from the parent's environment -- captured now, before isolation
# drops them. Three families go in:
#   (a) The real lineage the management marker names explicitly (the runtime directory and its
#       parent -- the state area's root -- and the records location). **A lineage pulled in with
#       `--root` sits outside XDG**, so a root resolved from XDG alone wouldn't reach it (this is
#       the one that actually gets dirtied on a machine that is itself under rein's management).
#   (b) The real state root resolved from XDG. This catches a run that falls through to the
#       default location even with no marker present (going through check.sh drops every REIN_*
#       var).
#   (c) The default location for the usage record (`${HOME}/.claude/state/context-usage`). Its
#       source is HOME, so it doesn't sit under either (a) or (b) -- without it,
#       `rein-statusline.sh`'s gate would never see the leak it's actually meant to catch. The
#       isolation env redirects HOME to a temp directory too, so a child that resolves here is
#       direct evidence that the real HOME leaked through.
# The check's own temp directory never falls under any of these (mktemp creates under TMPDIR).
REIN_ST_NEVER_ROOTS=""
rein_st_never_roots() {
  local candidate parent
  REIN_ST_NEVER_ROOTS=""
  rein_st_never_roots_add "${REIN_MANAGED_RUNTIME_DIR:-}"
  # The firing log lives in the runtime directory's **parent** (the state area's root), so add
  # the parent to the roots too.
  parent="${REIN_MANAGED_RUNTIME_DIR:-}"
  parent="${parent%/*}"
  # `/xxx`'s parent is empty, and `/`'s parent is empty too -- don't treat the root itself as
  # never-touch (only accept a depth of 2 or more).
  case "$parent" in
    /*/*) rein_st_never_roots_add "$parent" ;;
  esac
  rein_st_never_roots_add "${REIN_MANAGED_RECORDS_DIR:-}"
  if rein_xdg_base "${XDG_STATE_HOME:-}" XDG_STATE_HOME .local/state "runtime data"; then
    candidate="$REIN_XDG_BASE/rein"
    rein_st_never_roots_add "$candidate"
  fi
  # Built with the same literal path as the production default (rein_config_dynamic_default in
  # rein-config.sh), and skipped wherever HOME isn't an absolute path (folding it to a
  # bare "/..." as a never-touch root would make every location trip it).
  case "${HOME:-}" in
    /*) rein_st_never_roots_add "${HOME}/.claude/state/context-usage" ;;
  esac
}

# Adds one root (absolute paths only, and never the same root twice).
rein_st_never_roots_add() {
  local root="$1" existing
  case "$root" in
    /*) ;;
    *) return 0 ;;
  esac
  while IFS= read -r existing; do
    [ "$existing" = "$root" ] && return 0
  done <<EOF
$REIN_ST_NEVER_ROOTS
EOF
  if [ -z "$REIN_ST_NEVER_ROOTS" ]; then
    REIN_ST_NEVER_ROOTS="$root"
  else
    REIN_ST_NEVER_ROOTS="${REIN_ST_NEVER_ROOTS}
${root}"
  fi
}

# The isolation env (an `env` argument list) passed to a selftest's launch point. **Drops every
# variable starting with `REIN_` currently in the environment, without exception**, then rebuilds
# only the check's own entries after that (env lets a later entry win). Overwriting just a few
# keys per launch point would reopen the same hole (writing to the real user config, the real
# state) at every new call site, so this consolidates the assembly into one place.
#
# **The key move here is not keeping a list of what to drop.** An earlier version enumerated "the
# known config keys, plus 3 isolation vars, plus 6 management-marker vars, plus the notification
# cooldown" -- and a reader outside every one of those lists (`REIN_MANAGED_SETTINGS_POLICY`) was
# actually leaking through. An enumeration needs updating every time a new reader is added, and a
# missed update becomes an isolation hole, so this closes the failure point itself (having an
# enumeration at all) instead. Names are read from the environment (`compgen -e` returns
# **only the names** of exported variables -- unlike parsing `env`'s output lines, a variable
# whose value contains a newline can't throw off the field count).
# The result lands in the REIN_ST_ENV_ARGS array (a function can't return an array).
rein_st_isolation_env() {
  local user_config="$1" xdg_config="$2" xdg_state="$3" key
  REIN_ST_ENV_ARGS=()
  while IFS= read -r key; do
    case "$key" in
      REIN_*) REIN_ST_ENV_ARGS+=(-u "$key") ;;
    esac
  done <<EOF
$(compgen -e)
EOF
  # Doesn't inherit the notification cooldown from the surrounding environment either. If it did,
  # the fake osascript would never get called even once just because a cooldown happened to be
  # set in the user's own environment, and a check watching "did a notification fire" would
  # silently stop testing anything (a launch point that wants a cooldown passes it explicitly
  # after this -- env lets a later entry win). This is already covered by the blanket drop above,
  # but **the check's correctness depends on that coverage**, so the reason is recorded here too.
  REIN_ST_ENV_ARGS+=(
    "REIN_CONFIG_FILE=$user_config"
    "XDG_CONFIG_HOME=$xdg_config"
    "XDG_STATE_HOME=$xdg_state"
  )
  # **Redirects HOME too, to an empty check-only location.** Setting the two XDG vars alone
  # leaves an opening -- the default value of a known key can itself contain HOME
  # (`usage_state_dir` defaults to `${HOME}/.claude/state/context-usage`), so a check where no
  # config layer sets a value would still write under the real HOME. Isolation isn't closed by
  # just dropping the surrounding settings; it also has to redirect the default fall-through
  # location to a temp directory. This location stays inside a per-launch-point temp directory
  # ($4, or next to the user config when a launch point doesn't pass $4 -- either way, never
  # outside the check).
  REIN_ST_ENV_ARGS+=("HOME=${4:-${user_config%/*}/never-home}")
  # **Dropping the vars alone doesn't close this.** A leak only shows up as "the child resolved a
  # real lineage's location and wrote to it" -- by the time it's written, counting it needs a
  # fingerprint prepared per call site (an overwritten name, a location outside the state area, a
  # marker with a generation number, none of those show up in a count). So instead, **hand the
  # child the roots it must never touch, and fail the moment it resolves one of them.** The roots
  # have to be captured by the parent now, before they get dropped -- they can't be read back from
  # the child's environment, since that's exactly what gets dropped.
  rein_st_never_roots
  # If not even one root gets built, both layers of defense **go silently inert at once** -- the
  # gate becomes a no-op on an empty env, and the fingerprint count always reads 0 (an empty tree
  # to look at means zero diff, which always reads green). Failing to build any roots can actually
  # happen (`rein_st_never_roots_add` silently drops a non-absolute value, and if `rein_xdg_base`
  # fails, that whole branch produces nothing), so this fails **only where something is
  # guaranteed to need protecting**: with the management marker set, meaning the user's own real
  # lineage is named explicitly -- if the roots come out empty there, the assembly is broken.
  # With no marker (CI, a bare shell) there may genuinely be no real state, so an empty result
  # there passes as normal.
  if [ -n "${REIN_MANAGED:-}" ] && [ -z "$REIN_ST_NEVER_ROOTS" ]; then
    st_fail "the isolation check can build its never-touch roots" \
      "REIN_MANAGED is set, but not even one root got built (this disables the gate and the fingerprint count at once)"
  fi
  REIN_ST_ENV_ARGS+=("${REIN_SELFTEST_NEVER_ROOTS_ENV_NAME}=$REIN_ST_NEVER_ROOTS")
}

# Count of calls whose argv matches exactly. Matched down to argc, so gaining or losing an
# argument fails it either way.
rein_st_count_calls() {
  local log="$1" needle arg count
  shift
  needle="$#"
  for arg in "$@"; do
    needle="${needle}${REIN_ST_US}${arg}"
  done
  # Passes the value to match via an environment variable (awk -v would expand backslashes in
  # the assigned value).
  count="$(REIN_ST_WANT="$needle" awk '
    BEGIN { want = ENVIRON["REIN_ST_WANT"] }
    $0 == want { n++ }
    END { print n + 0 }' "$log" 2>/dev/null)"
  case "$count" in
    '' | *[!0-9]*) count=0 ;;
  esac
  printf '%s\n' "$count"
}

rein_st_has_call() {
  [ "$(rein_st_count_calls "$@")" -gt 0 ]
}

# Count of calls whose first argument (the subcommand) matches.
rein_st_count_sub() {
  local log="$1" sub="$2" count
  count="$(REIN_ST_WANT="$sub" awk -F"$REIN_ST_US" '
    BEGIN { want = ENVIRON["REIN_ST_WANT"] }
    $2 == want { n++ }
    END { print n + 0 }' "$log" 2>/dev/null)"
  case "$count" in
    '' | *[!0-9]*) count=0 ;;
  esac
  printf '%s\n' "$count"
}

# The call number (1-based, 0 if none) of the first call whose first argument matches.
rein_st_call_index() {
  local log="$1" sub="$2" index
  index="$(REIN_ST_WANT="$sub" awk -F"$REIN_ST_US" '
    BEGIN { want = ENVIRON["REIN_ST_WANT"] }
    $2 == want { print NR; found = 1; exit }
    END { if (!found) print 0 }' "$log" 2>/dev/null)"
  case "$index" in
    '' | *[!0-9]*) index=0 ;;
  esac
  printf '%s\n' "$index"
}

# Returns the recorded environment for the last call to `<subcommand>`, as
# `<config>|<runtime>|<records>`. Used to check the boundary where isolation env vars get
# dropped before spawning (they read back as `||` when they were).
rein_st_env_values() {
  local log="$1" sub="$2"
  REIN_ST_WANT="$sub" awk -F"$REIN_ST_US" '
    BEGIN { want = ENVIRON["REIN_ST_WANT"] }
    $1 == want { v = $2 "|" $3 "|" $4 }
    END { print v }' "$log" 2>/dev/null
}

# The REIN_-namespaced names still present at that call (space-separated, empty if none).
rein_st_env_rein_names() {
  local log="$1" sub="$2"
  REIN_ST_WANT="$sub" awk -F"$REIN_ST_US" '
    BEGIN { want = ENVIRON["REIN_ST_WANT"] }
    $1 == want { v = $5 }
    END { print v }' "$log" 2>/dev/null
}

rein_st_calls_total() {
  local total
  total="$(awk 'END { print NR + 0 }' "$1" 2>/dev/null)"
  case "$total" in
    '' | *[!0-9]*) total=0 ;;
  esac
  printf '%s\n' "$total"
}

rein_st_call_argc() {
  local argc
  argc="$(awk -F"$REIN_ST_US" -v n="$2" 'NR == n { print $1 }' "$1" 2>/dev/null)"
  case "$argc" in
    '' | *[!0-9]*) argc=0 ;;
  esac
  printf '%s\n' "$argc"
}

# The i-th argument (1-based) of the n-th call.
rein_st_call_arg() {
  awk -F"$REIN_ST_US" -v n="$2" -v i="$3" 'NR == n { print $(i + 1) }' "$1" 2>/dev/null
}

# The title / message of one notification. rein_notify passes them to osascript in the order
# `-- <message> <title>`, so this takes the last two arguments by counting back from argc (the
# position stays right even if the -e arguments ahead of them change).
rein_st_notify_field() {
  local log="$1" n="$2" field="$3" argc index
  argc="$(rein_st_call_argc "$log" "$n")"
  [ "$argc" -ge 2 ] || return 1
  case "$field" in
    title) index="$argc" ;;
    message) index="$((argc - 1))" ;;
    *) return 1 ;;
  esac
  rein_st_call_arg "$log" "$n" "$index"
}

# A resident-watcher fixture. The check (rein_watcher_state) only looks at the watcher lock's pid
# and that process's command line, so this places one process satisfying its 3 conditions (the
# lock's pid is alive, that process is rein's watcher for the target cwd, and it isn't the
# bootstrap entry point) without spawning a real watcher. Spawning a real watcher would make a
# check that only needs to set up whether one is resident also run a full handover cycle and
# call out to the external CLI.
# Teardown works not by killing the process but through **the disappearance of its own watch
# lock** and **a stop-request file**. It watches for the stop request so that the check's cleanup
# tears down every watcher it started through the same entry point production uses (the stop
# request). It also watches for the lock's disappearance because a check that wipes out the whole
# location (`rm -rf <root>/state`) never delivers the stop request -- missing either signal fails
# the check at the end with "a watcher was not fully stopped". The lock is created **before**
# starting the process (creating it after would let the child, right after it starts, read "no
# lock" and immediately exit).
# Records the watcher lock and pid of each fake watcher started. Without this, how to tear one down
# would depend on **the caller's own bookkeeping** (did it drop an owner file at that location,
# did it go through the whole-location-deletion path), and a leftover run would fail at a case
# unrelated to the actual cause (the final "the check tears down every watcher it started" case)
# -- where it failed would say nothing about why. A single variable can't track
# multiple runs that each started one, so this keeps a list.
REIN_ST_FAKE_WATCHER_LOCKS=""
REIN_ST_FAKE_WATCHER_PIDS=""
# The prefix on the token the fake watcher publishes to declare itself. **Whether a lock is safe
# to release is decided by this literal string** (the record above is a "this check started it at
# some point" log that doesn't get cleared on release -- if the real watcher retook the same
# location afterward, a release that only consulted the log would delete the real lock). The
# publishing side and the releasing side both read this one constant.
REIN_ST_FAKE_WATCHER_TOKEN_PREFIX="st-fake-watcher-"

# A fixture that needs a live pid uses a short-lived child that watches a stop-request file and
# exits on its own. Keeps process termination out of ordinary teardown, and bounds even a failure
# case by the child's own natural exit.
REIN_ST_COOPERATIVE_HOLDER_PID=""
REIN_ST_COOPERATIVE_HOLDER_STATE=""

rein_st_start_cooperative_holder() {
  local state_dir="$1" ready control pid polls=0
  state_dir="${state_dir:?}"
  ready="$state_dir/ready"
  control="$state_dir/stop"
  mkdir -p "$state_dir"
  rm -f "$ready" "$control"
  # shellcheck disable=SC2016  # runs in the child shell, so this $ must not expand in the caller
  "${BASH:-bash}" -c '
    ready=$1
    control=$2
    state=$3
    printf "ready\n" >"$ready"
    n=0
    while [ ! -e "$control" ] && [ "$n" -lt 100 ]; do
      n=$((n + 1))
      sleep 0.05
    done
    rm -f "$ready" "$control"
    rmdir "$state" 2>/dev/null || :
  ' _ "$ready" "$control" "$state_dir" >/dev/null 2>&1 &
  pid=$!
  REIN_ST_COOPERATIVE_HOLDER_PID="$pid"
  REIN_ST_COOPERATIVE_HOLDER_STATE="$state_dir"

  while [ "$polls" -lt 100 ]; do
    [ -f "$ready" ] && return 0
    sleep 0.05
    polls=$((polls + 1))
  done
  return 1
}

rein_st_stop_all_cooperative_holders() {
  local pid="$REIN_ST_COOPERATIVE_HOLDER_PID"
  local state="$REIN_ST_COOPERATIVE_HOLDER_STATE" ready control polls=0 status=0
  [ -n "$pid" ] || return 0
  ready="$state/ready"
  control="$state/stop"
  : >"$control"
  # An exited-but-unreaped child still shows up in ps, so waiting for its pid to disappear would
  # never let this get to wait. This instead waits for the child itself to remove `ready` as a
  # done marker, then calls wait to reap its exit code.
  while [ "$polls" -lt 120 ] && [ -e "$ready" ]; do
    sleep 0.05
    polls=$((polls + 1))
  done
  if [ -e "$ready" ]; then
    status=1
  else
    wait "$pid" 2>/dev/null || status=1
  fi
  rm -f "$ready" "$control"
  if [ -d "$state" ] && ! rmdir "$state" 2>/dev/null; then
    status=1
  fi
  if [ "$status" -eq 0 ]; then
    REIN_ST_COOPERATIVE_HOLDER_PID=""
    REIN_ST_COOPERATIVE_HOLDER_STATE=""
  fi
  return "$status"
}

# Passing `bare` as the third argument publishes a lock with **no role or cwd declared** (just
# the pid plus the token used to decide whether to release it). The reader (`rein_watcher_state`)
# has 2 branches: a lock that carries a declaration (one rein itself published) is decided by
# matching mode / cwd and **stops there**. Only a lock with no declaration (placed by hand, or by
# something other than rein) falls through to **re-parsing its command line**
# (`rein_watcher_command_matches`), so a check exercising that path can only reach it through this
# mode -- the default fixture never once touches it, which would leave "checking the command-line
# parsing" measuring nothing.
rein_st_start_fake_watcher() {
  local runtime_dir="$1" cwd="$2" shape="${3:-declared}" lock token common polls=0
  lock="$runtime_dir/$REIN_LOCK_DIRNAME"
  mkdir -p "$runtime_dir"
  # Checks for a live owner **exactly once** before removing anything. Removing unconditionally
  # would seize **a live owner's watcher lock** whenever a check pointed at the wrong location, or
  # a prior fixture was left un-torn-down, putting that lineage under double ownership -- and
  # since it was the check that seized it, the damage lands outside the check (on the user's own
  # real lineage). This uses the exact same decision function as production (giving the check its
  # own separate liveness check would split the contract's reading into two). It stops on both
  # "present" and "can't be confirmed" -- this doesn't loosen this module's rule (never seize a
  # lock whose status can't be confirmed) just because it's the check running it. Removal is only
  # allowed once the owner has **been confirmed gone** (a stale lock).
  rein_watcher_state "$runtime_dir" "$cwd"
  case $? in
    0)
      st_fail "the fake-watcher fixture does not remove a live watcher lock" \
        "held by pid=${REIN_WATCHER_PID}: ${lock}"
      return 1
      ;;
    2)
      st_fail "the fake-watcher fixture does not remove a lock whose owner can't be confirmed" \
        "${REIN_WATCHER_REASON}"
      return 1
      ;;
  esac
  rm -rf "$lock"
  # The lock is published through **the same entry point as the real one**
  # (`rein_claim_lock_dir` with start/cwd/mode/token). Placing a `pid`-only lock by hand would
  # never exercise the reader's (`rein_watcher_state`'s) main decision -- matching the
  # declaration W3 puts in -- and would only ever exercise the final command-line match. That
  # branch documents itself as the path "rein's own lock never reaches here", so for as long as
  # the fixture goes through it, a check claiming to test "the watcher is resident" keeps
  # measuring a different path than production.
  # The declaration's start time can only be assembled **by the pid doing the claiming** (the real
  # watcher claims for itself too), so the child process publishes it itself, and the parent waits
  # for that publish to finish before returning.
  rein_nonce >/dev/null
  token="${REIN_ST_FAKE_WATCHER_TOKEN_PREFIX}${REIN_NONCE}"
  common="$REIN_REPO_ROOT/scripts/lib/rein-common.sh"
  # Checks whether the stop request exists using **the same predicate as production** (`-e` is
  # also true for a directory or a symlink, so a fixture using anything else couldn't measure
  # "production doesn't stop for a directory-shaped stop request").
  # shellcheck disable=SC2016  # runs in the child shell, so this $ must not expand in the caller
  "${BASH:-bash}" -c '
. "$5"
if [ "$7" = "bare" ]; then
  rein_claim_lock_dir "$3" token "$6" || exit 1
else
  rein_claim_lock_dir "$3" \
    start "$(rein_process_start_identity "$$")" \
    cwd "$2" \
    mode "$REIN_LOCK_MODE_WATCH" \
    token "$6" || exit 1
fi
n=0
while [ -d "$3" ] && [ ! -f "$4" ] && [ "$n" -lt 600 ]; do n=$((n + 1)); sleep 1; done' \
    "$REIN_WATCHER_SCRIPT_PATH" --cwd "$cwd" "$lock" \
    "$runtime_dir/$REIN_STOP_REQUEST_BASENAME" "$common" "$token" "$shape" >/dev/null 2>&1 &
  REIN_ST_WATCHER_PID=$!
  # **Records it at the moment it's started** (before waiting on the publish). Placing this after
  # the publish wait would mean a run whose publish fails leaves behind only the child process,
  # recorded in neither the log nor the pid list, and **nobody could ever release the lock** it
  # publishes later (excluded from the bulk-release sweep, and the next check that looks at that
  # same location would read "resident"). Recording before waiting means even a failed run gets
  # picked up by teardown's entry point.
  REIN_ST_FAKE_WATCHER_LOCKS="${REIN_ST_FAKE_WATCHER_LOCKS}${lock}
"
  REIN_ST_FAKE_WATCHER_PIDS="${REIN_ST_FAKE_WATCHER_PIDS}${REIN_ST_FAKE_WATCHER_PIDS:+ }${REIN_ST_WATCHER_PID}"
  while [ "$polls" -lt 200 ] && [ ! -f "$lock/pid" ]; do
    sleep 0.05
    polls=$((polls + 1))
  done
  if [ ! -f "$lock/pid" ]; then
    st_fail "the fake-watcher fixture can publish its watcher lock" "never published: ${lock}"
    return 1
  fi
}

# Whether the given lock is **one this check's fixture started** (present in the log).
# This is split out as a predicate-only function because the guard on the release side banks a
# failure when it fires, so checking both the in-the-log and not-in-the-log cases needs a
# version that doesn't fire the guard.
# 0 = present in the log / 1 = not present
rein_st_fake_watcher_lock_known() {
  local lock="$1" entry
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    [ "$entry" = "$lock" ] && return 0
  done <<EOF
$REIN_ST_FAKE_WATCHER_LOCKS
EOF
  return 1
}

# Returns a resident fixture to "not present" (releases the watcher lock -- the check's first
# condition then fails). Only allowed to remove **a lock this fixture started**. Putting the
# liveness guard only on the starting side would let the releasing side seize **a real watcher's
# watcher lock** on a run pointed at the wrong location (the same damage the acquiring side guards
# against -- a guard on only one side is asymmetric). An argument not in the log fails without
# removing anything.
rein_st_stop_fake_watcher() {
  local runtime_dir="${1:?}" lock
  lock="$runtime_dir/$REIN_LOCK_DIRNAME"
  if ! rein_st_fake_watcher_lock_known "$lock"; then
    st_fail "the fake-watcher fixture does not remove a lock it didn't start" \
      "not present in the log: ${lock}"
    return 1
  fi
  rein_st_release_fake_watcher_lock "$lock"
}

# Confirms, from the contents of its published declaration (token), that the lock currently at
# this location **was published by this check's fake watcher**, before removing it. The log is a
# "started this at some point" record that doesn't get cleared on release -- if **the real
# watcher** retook the same location afterward, a release that only consulted the log would seize
# the real lock (the same damage the acquiring side's guard names -- a guard on only one side is
# asymmetric). A no-op if the lock is already gone (calling this twice on an already-released
# location is normal).
# 0 = removed, or was already gone / 1 = a different lock, left in place (banks a failure)
rein_st_release_fake_watcher_lock() {
  local lock="$1" token
  [ -d "$lock" ] || return 0
  token="$(rein_lock_field "$lock" token)"
  case "$token" in
    "$REIN_ST_FAKE_WATCHER_TOKEN_PREFIX"*)
      rm -rf "$lock"
      return 0
      ;;
  esac
  st_fail "the fake-watcher fixture does not remove a lock it didn't publish" \
    "the published token doesn't match (token=${token:-none}): ${lock}"
  return 1
}

# Tears down every fake watcher this check started. Meant to be called once from teardown's entry
# point, so a case-by-case failure to tear one down never turns into something left behind.
rein_st_stop_all_fake_watchers() {
  local lock pid i
  [ -n "$REIN_ST_FAKE_WATCHER_LOCKS" ] || return 0
  while IFS= read -r lock; do
    [ -n "$lock" ] || continue
    # **This bulk path goes through the same predicate too** (removing unconditionally here would
    # let teardown's entry point seize a real lock whenever the real watcher retook a location
    # still left in the log).
    rein_st_release_fake_watcher_lock "$lock"
  done <<EOF
$REIN_ST_FAKE_WATCHER_LOCKS
EOF
  for pid in $REIN_ST_FAKE_WATCHER_PIDS; do
    i=0
    while [ "$i" -lt 30 ] && rein_pid_alive "$pid"; do
      sleep 0.2
      i=$((i + 1))
    done
  done
  REIN_ST_FAKE_WATCHER_LOCKS=""
  REIN_ST_FAKE_WATCHER_PIDS=""
}

# A shim that records `ps` calls one line at a time (the evidence for the decision itself is
# left to the real binary). The rule "this path doesn't add another external command" can only
# be measured by **the number of calls** -- checking the output alone would let a violation pass.
rein_st_write_counting_ps() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat >"$bin_dir/ps" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_PS_LOG:-/dev/null}"
exec /bin/ps "$@"
EOF
  chmod +x "$bin_dir/ps"
}

# PATH with every directory that could resolve the given command removed. **Lives in this file
# because both the hook runner (scripts/rein-hook.sh) and the CLI
# (scripts/lib/cli/selftest/) use it** (the canonical reason is at the top of this file).
# An implementation that branches on whether the command resolves from PATH would move its
# check's result with whether the user's own installation happens to sit on the surrounding
# PATH -- **it would only pass on this one machine**. This rebuilds a check-only PATH here to cut
# that tie (the behavior on a machine where `claude` isn't on PATH at all can only be measured
# this way too).
rein_st_path_without_cmd() {
  local cmd="$1" out="" dir
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    [ -x "$dir/$cmd" ] && continue
    out="${out}${out:+:}${dir}"
  done <<EOF
$(printf '%s\n' "${PATH//:/$'\n'}")
EOF
  printf '%s\n' "$out"
}

# A fake claude / fake osascript, placed first on PATH. Records its arguments and plays out
# branches driven by environment variables.
rein_st_write_fake_bin() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat >"$bin_dir/claude" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
# Records the arguments with their boundaries preserved (argc first, US = 0x1f as the delimiter).
# Newlines inside an argument fold to RS = 0x1e (keeps one call per line; kickoff's argument
# contains newlines).
{
  printf '%s' "$#"
  for fake_arg in "$@"; do
    printf '\037%s' "${fake_arg//$'\n'/$'\036'}"
  done
  printf '\n'
} >>"$FAKE_LOG"

# Plays out a real-CLI constraint: stop / attach only accept the short job ID (id) from the
# enumeration -- passing a full session ID exits non-zero with `No job matching` (measured
# behavior).
fake_require_job_handle() {
  if jq -e --arg jid "$1" 'any(.[]; (.id // "") == $jid)' "$FAKE_AGENTS" >/dev/null 2>&1; then
    return 0
  fi
  printf 'No job matching %s\n' "$1" >&2
  exit 1
}

sub=""
for a in "$@"; do
  case "$a" in
    agents | stop | attach | rm | plugin)
      sub="$a"
      break
      ;;
    --bg)
      sub="bg"
      break
      ;;
  esac
done

# Also records the environment for each call (whether it was spawned with the isolation env vars
# dropped). Written to a separate file from the argv log, so it doesn't add a column to the
# check that counts by argv match (rein_st_count_calls).
# The 5th field is **the REIN_-namespaced names still present** (space-separated) -- this same
# record shows not just the 3 known ones but also a leftover config-layer env var
# (REIN_THRESHOLD_HANDOVER, etc.).
fake_rein_env_names=""
while IFS= read -r fake_env_name; do
  case "$fake_env_name" in
    REIN_*) fake_rein_env_names="${fake_rein_env_names}${fake_rein_env_names:+ }${fake_env_name}" ;;
  esac
done < <(compgen -e)
{
  printf '%s' "$sub"
  printf '\037%s' "${REIN_CONFIG_FILE:-}" "${REIN_RUNTIME_DIR:-}" "${REIN_RECORDS_ROOT:-}" \
    "$fake_rein_env_names"
  printf '\n'
} >>"$FAKE_LOG.env"

case "$sub" in
  agents)
    if [ "${FAKE_AGENTS_FAIL:-0}" = "1" ]; then
      printf 'fake agents boom\n' >&2
      exit 1
    fi
    count=0
    if [ -f "$FAKE_LOG.agents" ]; then
      count="$(cat "$FAKE_LOG.agents")"
    fi
    count=$((count + 1))
    printf '%s' "$count" >"$FAKE_LOG.agents"
    # Makes the enumeration unreadable **for that one call only** (the CLI stalls briefly, or
    # has just resumed from sleep). Kept separate from a permanent failure
    # (FAKE_AGENTS_FAIL) because the resilience path and the fail-loud path are different
    # behaviors.
    if [ -n "${FAKE_AGENTS_FAIL_ONCE_AT:-}" ] && [ "$count" = "$FAKE_AGENTS_FAIL_ONCE_AT" ]; then
      printf 'fake agents boom\n' >&2
      exit 1
    fi
    # Makes the enumeration unreadable partway through. Used to let the
    # pre-launch enumeration succeed while breaking only the successor's launch confirmation.
    if [ -n "${FAKE_AGENTS_FAIL_AFTER:-}" ] && [ "$count" -gt "$FAKE_AGENTS_FAIL_AFTER" ]; then
      printf 'fake agents boom\n' >&2
      exit 1
    fi
    # The normal enumeration and `--all` **carry different content** (measured). Only live
    # elements show up in the normal enumeration; a finished one (missing the pid and status
    # keys) only ever appears with `--all`. Returning the same content regardless of the argument
    # would let a check pass even after `rein prune`'s candidate extraction got swapped to read
    # the normal enumeration instead (in the real environment, that swap would leave zero
    # candidates picked up and things silently unpruned).
    # Liveness is read from the fixture's `pid` (a finished one has no pid or status keys --
    # the measured shape).
    fake_all=0
    for a in "$@"; do
      if [ "$a" = "--all" ]; then
        fake_all=1
      fi
    done
    fake_visible='.'
    if [ "$fake_all" = "0" ]; then
      fake_visible='[ .[] | select((.pid // null) != null) ]'
    fi
    if [ -n "${FAKE_EXIT_AFTER_POLLS:-}" ] && [ "$count" -gt "$FAKE_EXIT_AFTER_POLLS" ]; then
      jq -c --arg id "${FAKE_PRED_ID:-}" '[ .[] | select(.sessionId != $id) ]' "$FAKE_AGENTS"
    else
      cat "$FAKE_AGENTS"
    fi | jq -c "$fake_visible"
    ;;
  bg)
    if [ -n "${FAKE_BG_HANG_SEC:-}" ]; then
      # Makes the call never return (the CLI hangs). If the capped runner isn't in effect, the
      # watcher stalls right here.
      sleep "$FAKE_BG_HANG_SEC"
      exit 0
    fi
    if [ -n "${FAKE_SABOTAGE_PATH:-}" ]; then
      # Breaks the state directory's write target partway through a handover (blocks it off
      # with a directory).
      rm -f "$FAKE_SABOTAGE_PATH"
      mkdir -p "$FAKE_SABOTAGE_PATH"
    fi
    if [ "${FAKE_BG_FAIL:-0}" = "1" ]; then
      # Plays out a CLI that fails with the received --settings value included in stderr (this
      # is how a config value can reach the audit log and notifications through the
      # failure-reason path -- the redaction check can only exercise it here).
      fake_settings=""
      prev=""
      for a in "$@"; do
        if [ "$prev" = "--settings" ]; then
          fake_settings="$a"
        fi
        prev="$a"
      done
      printf 'fake bg boom%s\n' "${fake_settings:+ --settings ${fake_settings}}" >&2 # shell-quote-exempt: not a one-liner meant to be pasted and typed -- this plays out a fake CLI echoing the received value verbatim (quoting it here would transform the raw value the redaction check needs to see)
      exit 3
    fi
    if [ "${FAKE_BG_SILENT:-0}" = "1" ]; then
      exit 0
    fi
    # Plays out the one thing a launched session does that the watcher can observe: its
    # SessionStart hook deletes the temporary launch settings, using a path it can only have
    # learned from the managed marker. Without this, no fake launch would ever delete it and
    # **every** handover case would look like a marker that never arrived.
    # The content is copied aside first (a sibling of the argv log, like `.env` and `.agents`), so
    # a check can still inspect what was handed over after the file itself is gone. `cp -p` keeps
    # the mode, so the "created 0600" check reads the real thing.
    # FAKE_BG_KEEP_SETTINGS=1 is the other side: the session comes up but the marker never
    # reaches its hook, so the file stays.
    fake_settings=""
    prev=""
    for a in "$@"; do
      if [ "$prev" = "--settings" ]; then
        fake_settings="$a"
      fi
      prev="$a"
    done
    if [ -f "$fake_settings" ]; then
      cp -p "$fake_settings" "$FAKE_LOG.settings"
      if [ "${FAKE_BG_KEEP_SETTINGS:-0}" != "1" ]; then
        rm -f "$fake_settings"
      fi
    fi
    name=""
    prev=""
    for a in "$@"; do
      if [ "$prev" = "--name" ]; then
        name="$a"
      fi
      prev="$a"
    done
    now_ms="$(($(date -u +%s) * 1000))"
    sid="${FAKE_SUCC_ID:-fake-successor}"
    tmp="$(mktemp "${FAKE_AGENTS}.XXXXXX")"
    # The measured shape of a background session right after it starts (has id and state; still
    # processing, so state=working, status=busy, pid is a real number).
    jq -c \
      --arg name "$name" \
      --arg cwd "$PWD" \
      --arg sid "$sid" \
      --arg jid "job-$sid" \
      --argjson started "$now_ms" \
      '. + [{pid: 9001, cwd: $cwd, kind: "background", startedAt: $started, id: $jid, sessionId: $sid, name: $name, state: "working", status: "busy"}]' \
      "$FAKE_AGENTS" >"$tmp"
    mv "$tmp" "$FAKE_AGENTS"
    if [ "${FAKE_BG_DUPLICATE:-0}" = "1" ]; then
      tmp="$(mktemp "${FAKE_AGENTS}.XXXXXX")"
      jq -c \
        --arg name "$name" \
        --arg cwd "$PWD" \
        --arg sid "${sid}-dup" \
        --arg jid "job-${sid}-dup" \
        --argjson started "$now_ms" \
        '. + [{pid: 9002, cwd: $cwd, kind: "background", startedAt: $started, id: $jid, sessionId: $sid, name: $name, state: "working", status: "busy"}]' \
        "$FAKE_AGENTS" >"$tmp"
      mv "$tmp" "$FAKE_AGENTS"
    fi
    ;;
  stop)
    target=""
    prev=""
    for a in "$@"; do
      if [ "$prev" = "stop" ]; then
        target="$a"
      fi
      prev="$a"
    done
    fake_require_job_handle "$target"
    if [ "${FAKE_STOP_INEFFECTIVE:-0}" = "1" ]; then
      exit 0
    fi
    if [ "${FAKE_STOP_FAIL:-0}" = "1" ]; then
      printf 'fake stop boom\n' >&2
      exit 4
    fi
    tmp="$(mktemp "${FAKE_AGENTS}.XXXXXX")"
    # The real CLI's `claude stop` **doesn't delete the element** (measured) -- it loses the pid
    # and status keys, becomes state=done, drops out of the normal enumeration but stays in
    # `--all`. Only `rm` deletes it outright.
    jq -c --arg jid "$target" \
      '[ .[] | if (.id // "") == $jid then del(.pid, .status) + {state: "done"} else . end ]' \
      "$FAKE_AGENTS" >"$tmp"
    mv "$tmp" "$FAKE_AGENTS"
    ;;
  rm)
    # The real CLI's `claude rm <id>` "deletes a finished background session and its worktree".
    # Accepts only a short job ID, same as stop / attach.
    target=""
    prev=""
    for a in "$@"; do
      if [ "$prev" = "rm" ]; then
        target="$a"
      fi
      prev="$a"
    done
    fake_require_job_handle "$target"
    if [ "${FAKE_RM_FAIL:-0}" = "1" ]; then
      printf 'fake rm boom\n' >&2
      exit 6
    fi
    tmp="$(mktemp "${FAKE_AGENTS}.XXXXXX")"
    jq -c --arg jid "$target" '[ .[] | select((.id // "") != $jid) ]' "$FAKE_AGENTS" >"$tmp"
    mv "$tmp" "$FAKE_AGENTS"
    ;;
  plugin)
    # `plugin list` and `plugin marketplace list` are **separate queries** (the former is the
    # list of installed plugins, the latter is the marketplaces they're distributed from).
    # Returning the same response for both would let the distributor check go green off the
    # `plugin list` fixture, without ever exercising what it's actually meant to check.
    if [ "${FAKE_PLUGIN_FAIL:-0}" = "1" ]; then
      printf 'fake plugin boom\n' >&2
      exit 1
    fi
    # Builds a verb sequence out of the words after `plugin` (options excluded).
    fake_plugin_verbs=""
    fake_plugin_seen=0
    for a in "$@"; do
      if [ "$fake_plugin_seen" -eq 0 ]; then
        [ "$a" = "plugin" ] && fake_plugin_seen=1
        continue
      fi
      case "$a" in
        -*) continue ;;
      esac
      fake_plugin_verbs="${fake_plugin_verbs}${fake_plugin_verbs:+ }${a}"
    done
    case "$fake_plugin_verbs" in
      "marketplace list"*)
        # The measured shape of `claude plugin marketplace list --json` (a directory-distributed
        # entry has a path; a github-distributed one has no path but has repo). The default is
        # an empty array -- nothing registered.
        if [ -n "${FAKE_MARKETPLACES:-}" ] && [ -f "$FAKE_MARKETPLACES" ]; then
          cat "$FAKE_MARKETPLACES"
        else
          printf '[]\n'
        fi
        ;;
      "marketplace add"*)
        if [ "${FAKE_MARKETPLACE_ADD_FAIL:-0}" = "1" ]; then
          printf 'fake marketplace add boom\n' >&2
          exit 1
        fi
        # The real CLI's `marketplace add <path>` registers that directory in the registry as a
        # directory-distributed marketplace (adding the same path under an already-registered
        # name is a no-op that returns `already on disk` -- measured). This **actually rewrites
        # the registry** so that a check measuring "does following the instructions actually fix
        # it" can work -- with a fixture where re-diagnosing after the fix returns the same answer
        # as before it, an implementation that never actually fixes anything would still pass.
        fake_marketplace_path=""
        fake_prev=""
        for a in "$@"; do
          if [ "$fake_prev" = "add" ]; then
            fake_marketplace_path="$a"
          fi
          fake_prev="$a"
        done
        if [ -n "${FAKE_MARKETPLACES:-}" ] && [ -n "$fake_marketplace_path" ]; then
          fake_marketplace_name="$(jq -r '.name // empty' \
            "$fake_marketplace_path/.claude-plugin/marketplace.json" 2>/dev/null)"
          if [ -n "$fake_marketplace_name" ]; then
            [ -f "$FAKE_MARKETPLACES" ] || printf '[]\n' >"$FAKE_MARKETPLACES"
            tmp="$(mktemp "${FAKE_MARKETPLACES}.XXXXXX")"
            jq --arg name "$fake_marketplace_name" --arg path "$fake_marketplace_path" \
              '[ (map(select((.name // "") != $name)))[],
                 {name: $name, source: "directory", path: $path, installLocation: $path} ]' \
              "$FAKE_MARKETPLACES" >"$tmp"
            mv "$tmp" "$FAKE_MARKETPLACES"
          fi
        fi
        ;;
      "enable"*)
        if [ "${FAKE_PLUGIN_ENABLE_FAIL:-0}" = "1" ]; then
          printf 'fake plugin enable boom\n' >&2
          exit 1
        fi
        ;;
      "install"*)
        if [ "${FAKE_PLUGIN_INSTALL_FAIL:-0}" = "1" ]; then
          printf 'fake plugin install boom\n' >&2
          exit 1
        fi
        ;;
      *)
        # The measured shape of `claude plugin list --json` (id is `<name>@<marketplace>`,
        # enabled is a boolean). The default is an empty array -- "not installed" (doctor's 3rd
        # branch).
        if [ -n "${FAKE_PLUGINS:-}" ] && [ -f "$FAKE_PLUGINS" ]; then
          cat "$FAKE_PLUGINS"
        else
          printf '[]\n'
        fi
        ;;
    esac
    ;;
  attach)
    target=""
    prev=""
    for a in "$@"; do
      if [ "$prev" = "attach" ]; then
        target="$a"
      fi
      prev="$a"
    done
    fake_require_job_handle "$target"
    if [ -n "${FAKE_ATTACH_CP_SRC:-}" ] && [ -n "${FAKE_ATTACH_CP_DST:-}" ]; then
      # Places it with a single rename (never opens a window where a reader sees a partial write).
      cp "$FAKE_ATTACH_CP_SRC" "${FAKE_ATTACH_CP_DST}.fake-partial" &&
        mv "${FAKE_ATTACH_CP_DST}.fake-partial" "$FAKE_ATTACH_CP_DST"
    fi
    # Plays out "the pointer switched over, but attach never returns" (the external stop on the
    # predecessor isn't taking effect). Sleeps after the cp, so from the watcher's view attach
    # is still sitting there after the handover.
    if [ -n "${FAKE_ATTACH_SLEEP_SEC:-}" ]; then
      sleep "$FAKE_ATTACH_SLEEP_SEC"
    fi
    exit "${FAKE_ATTACH_EXIT:-0}"
    ;;
esac
exit 0
EOF
  chmod +x "$bin_dir/claude"

  cat >"$bin_dir/osascript" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
# Notifications also get logged with argument boundaries preserved (so title / message can be
# matched verbatim; newlines fold to RS, same as claude's own log).
{
  printf '%s' "$#"
  for fake_arg in "$@"; do
    printf '\037%s' "${fake_arg//$'\n'/$'\036'}"
  done
  printf '\n'
} >>"$FAKE_NOTIFY_LOG"
if [ "${FAKE_OSASCRIPT_FAIL:-0}" = "1" ]; then
  printf 'fake osascript boom\n' >&2
  exit 5
fi
exit 0
EOF
  chmod +x "$bin_dir/osascript"
}

# A shim for a prerequisite tool that is "on PATH but doesn't work". Plays out the GNU variants
# of date/stat (missing -j / -f) and a broken jq / perl. The absence itself can't be built by
# removing the tool from PATH, because where jq lives under /usr/bin, dropping that whole
# directory would take other tools down with it.
rein_st_write_broken_tool() {
  local bin_dir="$1" tool="$2"
  mkdir -p "$bin_dir"
  cat >"$bin_dir/$tool" <<EOF
#!/usr/bin/env bash
printf '%s: broken tool fixture\n' "$tool" >&2
exit 127
EOF
  chmod +x "$bin_dir/$tool"
}

# The enumeration's `startedAt` is **a millisecond-epoch number** (measured). A fixture on the
# predecessor side only needs to stay older than the successor's launch-confirmation window (the
# time the launch command was issued), so all of these fixtures share this one value. Matching
# even the digit count to the measured shape keeps an implementation that mixes up the unit (one
# that still passes with a second-epoch value, or a plain sequence number) from slipping past a
# comparison that treats it as a millisecond epoch (`startedAt >= launch time`).
REIN_ST_STARTED_AT_MS=1700000000000

# The enumeration returns the session ID (sessionId) and the short job ID (id) as separate
# fields. In the real CLI, the correspondence between the two is an implementation detail, so
# this fixture also uses values with no shared prefix, to keep an implementation that "extracts
# the UUID and passes that" from passing.
# The shape matches what was measured: only kind=background has id and state, and while it's
# alive it also has pid (a real number) and status (busy / idle). This writer produces
# **still-processing** liveness (state=working, status=busy).
rein_st_write_agents() {
  local file="$1" cwd="$2"
  shift 2
  jq -nc --arg cwd "$cwd" --argjson started "$REIN_ST_STARTED_AT_MS" \
    '[ $ARGS.positional[]
       | {pid: 4242, cwd: $cwd, kind: "background", startedAt: $started,
          id: ("job-" + .), sessionId: ., name: "predecessor", state: "working", status: "busy"} ]' \
    --args "$@" >"$file"
}

# The measured shape of **liveness after a turn finishes** (the normal steady state in real
# operation): state is `done`, the same word used for a finished session, but status=idle, it
# has a pid, and it's in the normal enumeration -- it's alive. This is why the liveness check
# (`rein_agents_has_live`) reads `.status // .state` in that order; swapping the order would turn
# a primary session sitting in ordinary steady state into "finished" every single time. This is
# the only fixture that exercises that field order.
rein_st_write_agents_idle() {
  local file="$1" cwd="$2"
  shift 2
  jq -nc --arg cwd "$cwd" --argjson started "$REIN_ST_STARTED_AT_MS" \
    '[ $ARGS.positional[]
       | {pid: 4242, cwd: $cwd, kind: "background", startedAt: $started,
          id: ("job-" + .), sessionId: ., name: "predecessor", state: "done", status: "idle"} ]' \
    --args "$@" >"$file"
}

# The measured shape of a finished background session: appears only in an enumeration with
# `--all`, **has no pid or status keys at all**, and state is done (stopped / blocked also show
# up in measurements, but rein's check treats all 3 words as finished, so the shape is the same).
# Cleanup of a finished generation (`rein prune`) can only find its targets from this shape.
rein_st_write_agents_done() {
  local file="$1" cwd="$2"
  shift 2
  jq -nc --arg cwd "$cwd" --argjson started "$REIN_ST_STARTED_AT_MS" \
    '[ $ARGS.positional[]
       | {cwd: $cwd, kind: "background", startedAt: $started,
          id: ("job-" + .), sessionId: ., name: "past", state: "done"} ]' \
    --args "$@" >"$file"
}

# The measured shape of an interactive session: no id or state, but it has pid and status.
# The path "an interactive session can't be stopped or attached to externally" can only be
# exercised through this shape.
rein_st_write_agents_interactive() {
  local file="$1" cwd="$2"
  shift 2
  jq -nc --arg cwd "$cwd" --argjson started "$REIN_ST_STARTED_AT_MS" \
    '[ $ARGS.positional[]
       | {pid: 4242, cwd: $cwd, kind: "interactive", startedAt: $started,
          sessionId: ., name: "predecessor", status: "busy"} ]' \
    --args "$@" >"$file"
}

# The fixture for `claude plugin list --json` (measured shape -- id is `<name>@<marketplace>`,
# enabled is a boolean). Passing id and enabled **in pairs** can produce multiple elements -- the
# only way to set up the real plugin coexisting with a same-named one distributed by a different
# marketplace.
# installPath points, as measured, to **a cached copy** (not where the source lives). An
# implementation that reads this value as the distributor would fail on a correctly installed
# environment -- this value is here so a check can pin that mix-up down.
# The variable name carries a prefix because this shared fixture gets sourced with `-x` by many
# executable scripts, and a generic name (pairs, say) would drag shellcheck into misreading the
# type of **a variable of the same name in the sourcing script**, producing a false positive.
rein_st_write_plugins() {
  local file="$1" plugin_pairs=()
  shift
  while [ "$#" -ge 2 ]; do
    plugin_pairs+=("$1" "$2")
    shift 2
  done
  jq -nc '[ $ARGS.positional as $p
            | range(0; ($p | length); 2) as $i
            | ($p[$i] | split("@")) as $parts
            | { id: $p[$i], version: "0.1.0", scope: "user",
                enabled: ($p[$i + 1] == "true"),
                installPath: ("/does-not-exist/plugins/cache/" + ($parts[1] // "unknown")
                  + "/" + $parts[0] + "/0.1.0") } ]' \
    --args ${plugin_pairs[@]+"${plugin_pairs[@]}"} >"$file"
}

# The fixture for `claude plugin marketplace list --json` (measured shape). A
# directory-distributed element has `path`; a github-distributed one has no `path` but has
# `repo`. Passing no name (just the file argument) produces an empty registry -- nothing
# registered.
rein_st_write_marketplaces() {
  local file="$1" mkt_name="${2:-}" mkt_source="${3:-}" mkt_location="${4:-}"
  if [ -z "$mkt_name" ]; then
    printf '[]\n' >"$file"
    return 0
  fi
  if [ "$mkt_source" = "directory" ]; then
    jq -nc --arg name "$mkt_name" --arg path "$mkt_location" \
      '[{name: $name, source: "directory", path: $path, installLocation: $path}]' >"$file"
    return 0
  fi
  jq -nc --arg name "$mkt_name" --arg source "$mkt_source" --arg repo "$mkt_location" \
    '[{name: $name, source: $source, repo: $repo,
       installLocation: ("/does-not-exist/plugins/marketplaces/" + $name)}]' >"$file"
}

# A fixture for the usage state (the writer is the statusline -- rein only reads it).
# used_percentage is embedded as a raw JSON literal (there's a check that passes a non-numeric
# value through). The 4th argument is the timestamp the writer records (default: now). Freshness
# is decided by **this value**, so a case that wants a stale state passes a past timestamp here
# (no need to touch mtime).
rein_st_write_usage() {
  local dir="$1" session_id="$2" pct="$3" at="${4:-}"
  [ -n "$at" ] || at="$(rein_iso_now)"
  mkdir -p "$dir"
  printf '{"at":"%s","session_id":"%s","cwd":"/tmp","context_window":{"total_input_tokens":1,"context_window_size":1000000,"used_percentage":%s}}\n' \
    "$at" "$session_id" "$pct" >"$dir/$session_id.json"
}

# The shape where the writer puts a space after `: ` (equivalent JSON). Checks that the fast
# path can read this shape too.
rein_st_write_usage_spaced() {
  local dir="$1" session_id="$2" pct="$3" at="${4:-}"
  [ -n "$at" ] || at="$(rein_iso_now)"
  mkdir -p "$dir"
  printf '{"at": "%s", "session_id": "%s", "context_window": {"used_percentage": %s}}\n' \
    "$at" "$session_id" "$pct" >"$dir/$session_id.json"
}

# The shape where the writer records no timestamp (a state with no `at`). The path where
# the freshness check falls back to mtime can only be exercised through this fixture.
rein_st_write_usage_without_at() {
  local dir="$1" session_id="$2" pct="$3"
  mkdir -p "$dir"
  printf '{"session_id":"%s","cwd":"/tmp","context_window":{"used_percentage":%s}}\n' \
    "$session_id" "$pct" >"$dir/$session_id.json"
}

# The shape of an injection that reached the transcript (the attachment line the harness writes
# to it). A PostToolBatch injection is recorded under a synthetic ID (`hook-<uuid>`), so the check
# matches on **a nonce mixed into the injected text** (measured).
rein_st_write_transcript_nonce() {
  local file="$1" nonce="$2"
  mkdir -p "${file%/*}"
  printf '{"parentUuid":"x","isSidechain":false,"attachment":{"type":"hook_additional_context","content":["[rein] ... [rein:%s]"],"hookName":"PostToolBatch","toolUseID":"hook-1234","hookEvent":"PostToolBatch"}}\n' \
    "$nonce" >"$file"
}

# The shape of an injection that reached the transcript (the attachment line the harness writes
# to it). Placing only a line that carries a different tool_use_id produces "another injection
# exists, but not this one" -- i.e., not reached.
rein_st_write_transcript() {
  local file="$1" tool_use_id="$2"
  mkdir -p "$(dirname "$file")"
  printf '{"parentUuid":"x","isSidechain":false,"attachment":{"type":"hook_additional_context","content":["y"],"hookName":"PostToolUse:Bash","toolUseID":"%s","hookEvent":"PostToolUse"}}\n' \
    "$tool_use_id" >"$file"
}

# A hook payload. Overlays the common fields (session_id, transcript_path, cwd) with whatever
# JSON fragment the caller wants added on top (tool_use_id, agent_id, agent_type,
# stop_hook_active).
rein_st_hook_payload() {
  local session_id="$1" cwd="$2" transcript="$3" extra="${4:-}"
  [ -n "$extra" ] || extra='{}'
  jq -nc \
    --arg sid "$session_id" \
    --arg cwd "$cwd" \
    --arg transcript "$transcript" \
    --argjson extra "$extra" \
    '{session_id: $sid, cwd: $cwd, transcript_path: $transcript} + $extra'
}

# A handoff-document fixture for the side where a handover request is **accepted**. The
# section-structure acceptance rule is decided by the shared library's own list, so this fixture
# builds from that same list too -- if a check hardcoded the section names instead, a change to
# that list would leave only the "input that's supposed to pass" behind with the old names, and
# it would fail from the fixture going stale, not from an actual mechanism change.
# The content (each section's body) is irrelevant to rein's semantics, so this only satisfies
# "the section is present".
rein_st_write_handoff() {
  local path="$1" name
  {
    printf '# Handoff document\n'
    for name in "${REIN_HANDOFF_SECTIONS[@]}"; do
      printf '\n## %s\n\n(selftest fixture)\n' "$name"
    done
  } >"$path"
}

rein_st_write_marker() {
  local file="$1" session_id="$2" requested_at="$3" handoff="$4" cwd="$5"
  jq -nc \
    --arg schema "$REIN_MARKER_SCHEMA" \
    --arg sid "$session_id" \
    --arg at "$requested_at" \
    --arg handoff "$handoff" \
    --arg cwd "$cwd" \
    '{schema: $schema, session_id: $sid, requested_at: $at, handoff_path: $handoff, cwd: $cwd}' \
    >"$file"
}

# The 6th argument is the previous generation's session ID (omitted = null). Only this argument
# can build the state where nothing but the handover's last stage is left standing (the pointer
# already points at the successor, but the predecessor session is still there).
rein_st_write_pointer() {
  local file="$1" session_id="$2" session_name="$3" cwd="$4" generation="$5" predecessor="${6:-}"
  jq -nc \
    --arg schema "$REIN_POINTER_SCHEMA" \
    --arg sid "$session_id" \
    --arg name "$session_name" \
    --arg cwd "$cwd" \
    --arg at "$(rein_iso_now)" \
    --arg predecessor "$predecessor" \
    --argjson generation "$generation" \
    '{
      schema: $schema,
      session_id: $sid,
      session_name: $name,
      cwd: $cwd,
      generation: $generation,
      updated_at: $at,
      predecessor_session_id: (if $predecessor == "" then null else $predecessor end),
      handoff_path: null
    }' >"$file"
}
