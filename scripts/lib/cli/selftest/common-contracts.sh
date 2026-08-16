# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034  # selftest state is shared across sections (the caller selftest()'s locals and the ST_* globals)
# shellcheck disable=SC2016  # body meant to be evaluated in the subshell (expanding it here would change what gets measured)
# The directive above applies to the **whole file** -- in this file, neither an unused local
# inside a function nor a misspelled reference gets caught. The shared variables are scattered
# across the whole file, so a line-level directive can't be scoped tightly enough. SC2016 gets
# the same treatment -- every single-quoted literal in this file is a body evaluated in a
# subshell with HOME dropped, scattered line by line, so it's handled the same way.
#
# selftest for the **contract itself** of the shared library (lib/rein-common.sh). Calls
# functions directly without starting a verb -- what's measured here is only the property that
# must hold no matter which verb calls it:
#   (1) the default location declares that it cannot be assembled where there is no HOME
#       (doesn't silently fall back to right under root)
#   (2) enumeration liveness judgment never returns outside the declared 0/1/2
#   (3) a GUI notification is called with a cap (called from inside a cycle, so it must not
#       stall on a notification path that never returns)
#   (4) releasing a stale lock with a match check never touches the public name of a lock it
#       didn't itself see
#   (5) a lineage-token draw that doesn't come back as 64 hex characters places nothing (no
#       padding, no retry, no weaker value left behind)
#   (6) resolving the short job ID runs the same entry check on the enumeration as the liveness
#       judgment (an unreadable body never comes back as "no match")
#   (7) a process's identity is one string no matter which time zone the reader runs under
#       (a live lock owner is never read as stale just because TZ moved)
# Not an executable script, so it carries no execute bit (out of scope for the --selftest convention).
#
# **This section only runs once registered with selftest.sh** (dropping the file in on its own
# isn't picked up). Two lines are needed: the source line
# `. "$SCRIPTS_DIR/lib/cli/selftest/common-contracts.sh"`, and the one line
# `pure:common-contracts st_section_common_contracts` in the section table.

# Calls one shared-library function with HOME / XDG dropped. Always measured in a subshell
# **so this check process's own HOME is never touched** (an unset-then-restore form would leave
# later sections running with no HOME if this one died partway through).
# $1=body evaluated in the subshell. $2 onward=assignments added to env (a way to override the
# defaults, e.g. `HOME=`).
st_cc_probe() {
  local body="$1"
  shift
  env -u HOME -u XDG_STATE_HOME -u XDG_CONFIG_HOME "ST_CC_BODY=$body" "$@" \
    "$ST_BASH" -c '. "$1"; eval "$ST_CC_BODY"' _ "$SCRIPTS_DIR/lib/rein-common.sh" 2>&1
}

# Watches whether the public name went empty **even for an instant**. Whether a stale release
# with a match check ever touched a lock it never saw itself cannot be measured from the
# location afterward (whatever it backed off gets put back, so it ends up looking unchanged
# again) -- without catching the empty instant itself, there's no way to say whether the window
# where a third party could grab the public name (the precondition for double ownership) was
# actually closed. The watch steps down once the call under test returns (capped by wall clock).
st_cc_watch_lock_name() {
  local lock="$1" gone="$2" done_flag="$3" i=0 deadline
  deadline=$(($(date +%s) + 10))
  while [ ! -e "$done_flag" ]; do
    [ -e "$lock" ] || : >"$gone"
    i=$((i + 1))
    if [ $((i % 500)) -eq 0 ] && [ "$(date +%s)" -ge "$deadline" ]; then
      return 0
    fi
  done
  return 0
}

# One lineage-token provisioning attempt, run with a fake `od` whose 32-byte draw comes back as
# $2. The directory is made fresh every time -- an existing token is taken as-is by the function
# under test, so a leftover one would mean the draw was never reached at all.
# **The prerequisite check's own result rides along in the output** (`prereq=<rc>|`): what this
# case measures is the residue that check cannot see, so a run where the tool check was red for
# some unrelated reason must not be able to look like a pass.
# $1=the runtime directory to provision $2=what the draw comes back as $3=the stub's bin directory
# $4=the real `od` the stub delegates every other call to
st_cc_token_draw() {
  local dir="$1" draw="$2" bin="$3" real_od="$4"
  rm -rf "$dir"
  mkdir -p "$dir"
  st_cc_probe 'rein_check_prerequisites "$1"
    printf "prereq=%s|" "$?"
    rein_ensure_runtime_token "$ST_CC_TOKEN_DIR"
    printf "rc=%s|%s\n" "$?" "$REIN_RUNTIME_ERROR"' \
    "PATH=$bin:$PATH" "ST_CC_OD_DRAW=$draw" "ST_CC_TOKEN_DIR=$dir" "ST_CC_REAL_OD=$real_od"
}

st_section_common_contracts() {
  local cc_dir cc_bin cc_body cc_out cc_rc cc_lock cc_gone cc_done cc_watch cc_err cc_pid
  local cc_real_od cc_token_dir cc_hex32 cc_hex64 cc_draw cc_draw_kind
  local cc_agents cc_tz_dir cc_tz_here cc_tz_far cc_lock_tz

  cc_dir="$tmp/common-contracts"
  mkdir -p "$cc_dir"

  # (1) The default location declares that it cannot be assembled where there is no HOME (home-01).
  #
  # `${XDG_STATE_HOME:-${HOME:-}/.local/state}` folds down to `/.local/state` when HOME is
  # empty, and since it starts with `/` it slips past the absolute-path check -- the location
  # quietly resolves to an unwritable path right under root, and the reason it fails becomes the
  # far-removed "mkdir failed" (HOME never gets named even once). This checks that the same
  # discipline applied to a relative XDG value also applies here, on both sides (reject / pass).
  cc_body='out="$(rein_resolve_runtime_dir /p/proj)"; printf "rc=%s|%s\n" "$?" "$out"'
  cc_out="$(st_cc_probe "$cc_body")"
  case "$cc_out" in
    *"rc=1|"*) st_ok ;;
    *) st_fail "doesn't resolve the runtime-data location on a machine with no HOME" "[${cc_out}]" ;;
  esac
  case "$cc_out" in
    *"neither HOME nor XDG_STATE_HOME is set"*) st_ok ;;
    *) st_fail "names HOME explicitly as the reason it couldn't resolve" "[${cc_out}]" ;;
  esac
  # An empty-string HOME is treated the same as unset (the same form `${HOME:-}` folds down to).
  cc_out="$(st_cc_probe "$cc_body" HOME=)"
  case "$cc_out" in
    *"neither HOME nor XDG_STATE_HOME is set"*"rc=1|") st_ok ;;
    *) st_fail "treats an empty-string HOME the same as unset" "[${cc_out}]" ;;
  esac
  # A relative XDG is still rejected as before (the discipline hasn't split apart). The reason names the XDG side.
  cc_out="$(st_cc_probe "$cc_body" XDG_STATE_HOME=relative/dir)"
  case "$cc_out" in
    *"XDG_STATE_HOME holds a relative path"*"rc=1|") st_ok ;;
    *) st_fail "rejects a relative XDG, naming the reason on the XDG side" "[${cc_out}]" ;;
  esac
  # Accepting side (1): with HOME present, it returns `<HOME>/.local/state/rein/<key>` as before.
  cc_out="$(st_cc_probe "$cc_body" "HOME=$cc_dir/home")"
  case "$cc_out" in
    "rc=0|$cc_dir/home/.local/state/rein/proj-"*) st_ok ;;
    *) st_fail "returns the default location when HOME is present" "[${cc_out}]" ;;
  esac
  # Accepting side (2): a lineage with an explicit location doesn't depend on HOME (the explicit value returns at the entry point).
  cc_body='out="$(rein_resolve_runtime_dir /p/proj /explicit/rt)"; printf "rc=%s|%s\n" "$?" "$out"'
  cc_out="$(st_cc_probe "$cc_body")"
  if [ "$cc_out" = "rc=0|/explicit/rt" ]; then
    st_ok
  else
    st_fail "a lineage with an explicit location resolves even without HOME" "[${cc_out}]"
  fi
  # Naming the lineage explicitly (the one line a successor types) is checked under the same
  # discipline. If a machine that can't assemble the default treated the result as the default
  # location anyway, `--runtime-dir` would drop out of the line, and the successor, running where
  # HOME is restored, would go looking at a different location.
  cc_body='rein_lineage_opts /.local/state/rein/proj-abc /x/.rein
    printf "rc=%s|%s|%s\n" "$?" "$REIN_LINEAGE_GLOBAL_OPTS" "$REIN_LINEAGE_VERB_OPTS"'
  cc_out="$(st_cc_probe "$cc_body")"
  case "$cc_out" in
    *"--runtime-dir '/.local/state/rein/proj-abc'"*) st_ok ;;
    *) st_fail "falls onto naming the location explicitly on a machine that can't assemble the default" "[${cc_out}]" ;;
  esac
  # Accepting side: when HOME is present and this really is the default location, the naming
  # stays empty as before (`--runtime-dir` isn't added).
  cc_body='rein_lineage_opts "$HOME/.local/state/rein/proj-abc" /x/.rein
    printf "rc=%s|%s|%s\n" "$?" "$REIN_LINEAGE_GLOBAL_OPTS" "$REIN_LINEAGE_VERB_OPTS"'
  cc_out="$(st_cc_probe "$cc_body" "HOME=$cc_dir/home")"
  if [ "$cc_out" = "rc=0||" ]; then
    st_ok
  else
    st_fail "the default location still adds no naming, as before" "[${cc_out}]"
  fi
  # The naming on the user config side carries the same wording too (aligned across all 3 spots).
  cc_body='rein_config_lineage_opts /.config/rein/config
    printf "rc=%s|%s\n" "$?" "$REIN_LINEAGE_GLOBAL_OPTS"'
  cc_out="$(st_cc_probe "$cc_body")"
  case "$cc_out" in
    *"--config '/.config/rein/config'"*) st_ok ;;
    *) st_fail "config's naming is also made explicit on a machine that can't assemble the default" "[${cc_out}]" ;;
  esac

  # (2) Liveness judgment never returns outside the declared 0/1/2 (agents-01).
  #
  # If the entry point only checked `type == "array"`, a response that **is an array but whose
  # elements aren't objects** (like `[1,2,3]`) would slip through, jq would hit a runtime error
  # (rc=5) indexing `.sessionId`, and that would become the return value as-is. 5 matches
  # neither the caller's (bootstrap) 0 nor 2, so it falls onto the default branch -- "no
  # predecessor" -- which is exactly the case this function is supposed to close off (a fresh
  # session starting up even though a live primary session exists).
  for cc_out in '[1,2,3]' '["str"]' '[null]' '{"error":"x"}' 'not-json'; do
    rein_agents_has_live "$cc_out" sid >/dev/null 2>&1
    cc_rc=$?
    if [ "$cc_rc" -eq 2 ]; then
      st_ok
    else
      st_fail "a response unusable as an enumeration declares itself 2 (undeterminable)" "[${cc_out}] -> rc=${cc_rc}"
    fi
  done
  # Accepting side: a normal enumeration still returns 0 / 1 as before (not over-widened toward undeterminable).
  cc_out='[{"sessionId":"sid","pid":1,"status":"running"}]'
  rein_agents_has_live "$cc_out" sid
  st_expect_true "a live session returns 0" test "$?" -eq 0
  rein_agents_has_live "$cc_out" other
  st_expect_true "an absent session returns 1" test "$?" -eq 1
  rein_agents_has_live '[{"sessionId":"sid","pid":1,"status":"done"}]' sid
  st_expect_true "a finished session returns 1" test "$?" -eq 1
  rein_agents_has_live '[]' sid
  st_expect_true "an empty enumeration returns 1 (not undeterminable)" test "$?" -eq 1
  rein_is_session_live sid '[1,2,3]'
  st_expect_true "the enumeration relayed through still never returns outside 0/1/2" test "$?" -eq 2
  # The stranded-predecessor judgment doesn't fold undeterminable into "not stranded" either
  # (folding it would let a live predecessor go unnoticed on a round where the enumeration broke).
  mkdir -p "$cc_dir/strand/$REIN_RECORDS_DIRNAME"
  cc_out="$(cd "$cc_dir/strand" && pwd -P)"
  printf '{"schema":"%s","session_id":"succ","predecessor_session_id":"pred","generation":2,"cwd":"%s"}\n' \
    "$REIN_POINTER_SCHEMA" "$cc_out" >"$cc_dir/strand/$REIN_RECORDS_DIRNAME/$REIN_POINTER_BASENAME"
  rein_stranded_predecessor "$cc_dir/strand/$REIN_RECORDS_DIRNAME/$REIN_POINTER_BASENAME" \
    "$cc_out" '[1,2,3]' >/dev/null 2>&1
  st_expect_true "a round with a broken enumeration reports stranded as 2 (undeterminable)" test "$?" -eq 2
  rein_stranded_predecessor "$cc_dir/strand/$REIN_RECORDS_DIRNAME/$REIN_POINTER_BASENAME" \
    "$cc_out" '[{"sessionId":"pred","pid":1},{"sessionId":"succ","pid":2}]' >/dev/null 2>&1
  st_expect_true "both alive still reports 0 (stranded) as before" test "$?" -eq 0
  rein_stranded_predecessor "$cc_dir/strand/$REIN_RECORDS_DIRNAME/$REIN_POINTER_BASENAME" \
    "$cc_out" '[{"sessionId":"succ","pid":2}]' >/dev/null 2>&1
  st_expect_true "no predecessor present reports 1 as before" test "$?" -eq 1

  # (3) A GUI notification is called with a cap (notify-01).
  #
  # The caller sits **inside a cycle** of the watcher and the seat, so stalling on a
  # notification path that never returns (no GUI session present, or Notification Center not
  # responding) stalls the heartbeat update along with it. The fake osascript is built to
  # **deliberately not `exec`** (it spawns a child and waits) -- this is the only form that
  # actually exercises the capped runner. A fake that keeps everything to one process via `exec`
  # would still pass even back when the cap could only bind the one process it replaced, and
  # this check would never once have measured whether the notification actually returns. With a
  # spawned child, the child keeps holding stdout, so `rein_notify`'s command substitution waits
  # for the pipe to close -- it doesn't come back unless the cap reaches the whole group.
  cc_bin="$cc_dir/bin"
  mkdir -p "$cc_bin"
  cat >"$cc_bin/osascript" <<'EOF'
#!/usr/bin/env bash
/bin/sleep 30
EOF
  chmod +x "$cc_bin/osascript"
  cc_err="$cc_dir/notify-hang.err"
  # An outer cap too -- so if the cap ever stops working, this check fails instead of hanging
  # (a hang reduces the cause to nothing more than a deadline exceeded, and which contract broke drops out of the summary line).
  rein_run_limited 15 env -u REIN_NOTIFY_SILENT "PATH=$cc_bin:$PATH" \
    "$ST_BASH" -c '
      . "$1"
      REIN_NOTIFY_TIMEOUT_SEC=1
      rein_notify heading body
    ' _ "$SCRIPTS_DIR/lib/rein-common.sh" >/dev/null 2>"$cc_err"
  cc_rc=$?
  if [ "$cc_rc" -ne "$REIN_TIMEOUT_RC" ]; then
    st_ok
  else
    st_fail "rein_notify still returns even on a notification path that never returns" "cut off by the outer cap (rc=${cc_rc})"
  fi
  case "$(cat "$cc_err")" in
    *"cut off the GUI notification"*) st_ok ;;
    *) st_fail "a cutoff names a reason distinct from a failure" "[$(cat "$cc_err")]" ;;
  esac
  # Accepting side (1): an osascript that returns right away still prints no reason line, as before.
  printf '#!/bin/bash\nexit 0\n' >"$cc_bin/osascript"
  env -u REIN_NOTIFY_SILENT "PATH=$cc_bin:$PATH" "$ST_BASH" -c '
    . "$1"
    rein_notify heading body
  ' _ "$SCRIPTS_DIR/lib/rein-common.sh" >/dev/null 2>"$cc_err"
  st_expect_file "a notification that succeeds prints only the one heading-and-body line" "$cc_err" "heading: body"
  # Accepting side (2): the reason text for a failing osascript is unchanged (not swapped out by the cap).
  printf '#!/bin/bash\nprintf "execution error: boom\\n" >&2\nexit 1\n' >"$cc_bin/osascript"
  env -u REIN_NOTIFY_SILENT "PATH=$cc_bin:$PATH" "$ST_BASH" -c '
    . "$1"
    rein_notify heading body
  ' _ "$SCRIPTS_DIR/lib/rein-common.sh" >/dev/null 2>"$cc_err"
  case "$(cat "$cc_err")" in
    *"GUI notification failed: execution error: boom"*) st_ok ;;
    *) st_fail "a failed notification's reason text is unchanged" "[$(cat "$cc_err")]" ;;
  esac

  # (4) Releasing a stale lock with a match check never touches a lock it didn't itself see (lock-01).
  #
  # If the lock were moved aside first and the match checked only afterward, a different run
  # that cleared and **retook** the same stale lock in the window between judging and reaching
  # here would have its live lock stripped off the public name once. If a third party grabs the
  # public name during that gap,
  # whatever this backed off gets thrown away, contents and all -- meaning the party that retook
  # it and the third party both believe they're holding the lock and proceed (the discarded side
  # exits cleanly on release due to a token mismatch, so double ownership never shows up in any
  # record). This property can't be measured without watching for **the instant it went empty**.
  cc_lock="$cc_dir/reclaim.lock"
  mkdir -p "$cc_lock"
  printf '12345\n' >"$cc_lock/pid"
  printf 'tokenB\n' >"$cc_lock/token"
  cc_gone="$cc_dir/lock-was-gone"
  cc_done="$cc_dir/lock-probe-done"
  rm -f "$cc_gone" "$cc_done"
  st_cc_watch_lock_name "$cc_lock" "$cc_gone" "$cc_done" &
  cc_watch=$!
  rein_release_lock_dir_if_stale "$cc_lock" 99999999 2>/dev/null
  cc_rc=$?
  : >"$cc_done"
  wait "$cc_watch"
  st_expect_true "a lock with a different pid than the one seen is never removed from the public name, not even for an instant" test ! -e "$cc_gone"
  st_expect_true "a lock with a different pid than the one seen is left alone and returns 1" test "$cc_rc" -eq 1
  st_expect_true "an untouched lock keeps its contents intact" \
    test "$(rein_lock_pid "$cc_lock")" = "12345"
  st_expect_true "an untouched round creates no temporary name either" \
    test -z "$(find "$cc_dir" -maxdepth 1 -name 'reclaim.lock.release.*' -print)"
  # Accepting side: a lock whose pid matches the one seen is still removed as before (not over-narrowed to the point of blocking this too).
  cc_pid="$(rein_lock_pid "$cc_lock")"
  rein_release_lock_dir_if_stale "$cc_lock" "$cc_pid"
  st_expect_true "a lock matching the pid seen is removed" test "$?" -eq 0
  st_expect_true "a removed lock disappears" test ! -e "$cc_lock"
  rm -f "$cc_gone" "$cc_done"

  # (5) A lineage-token draw that isn't 64 hex characters places nothing (token-01).
  #
  # The prerequisite check draws 4 bytes through the same command shape, so an `od` that is
  # missing, or that doesn't take these flags, is named at install / launch / diagnostics time
  # (measured in doctor's section, on a broken `od`). **What that check cannot see is this one
  # call** -- rein_new_runtime_token's own comment says so, and until now nothing measured the
  # residue it names: a short read from /dev/urandom, an `od` that prints more than the `-N` it
  # was handed, or one that prints characters outside `0-9a-f`. All three arrive at the draw with
  # every prerequisite green, and the draw refusing them is the only thing standing between them
  # and a lineage token weaker than the one the marker check rests on (see "A clone can supply
  # the marker env" in docs/spec/hooks.md).
  cc_bin="$cc_dir/token-bin"
  mkdir -p "$cc_bin"
  cc_real_od="$(command -v od)"
  st_expect_true "the fixture can find the real od to delegate to" test -x "$cc_real_od"
  # **Only the 32-byte draw is faked**; every other call runs the real `od`, so the prerequisite
  # check's own 4-byte probe passes for the real reason rather than against a second fake. The
  # real path is handed in rather than written here, so this never pins a location.
  cat >"$cc_bin/od" <<'EOF'
#!/usr/bin/env bash
for od_arg in "$@"; do
  if [ "$od_arg" = "-N32" ]; then
    printf '%s\n' "$ST_CC_OD_DRAW"
    exit 0
  fi
done
exec "$ST_CC_REAL_OD" "$@"
EOF
  chmod +x "$cc_bin/od"
  cc_token_dir="$cc_dir/token-runtime"
  cc_hex32="deadbeefdeadbeefdeadbeefdeadbeef"
  cc_hex64="${cc_hex32}${cc_hex32}"
  # The three shapes are picked so **each can only be refused by one of the two checks**, and so
  # that loosening either one on either side is caught. `short` and `long` are both entirely hex
  # and differ from the real thing only in width -- `long` is what a width check relaxed from
  # "exactly" to "at least" would accept, and `short` what dropping the width check would. The
  # non-hex value is **exactly 64 characters** so the width check cannot absorb it and only the
  # character check can refuse it. Its non-hex character is `z` rather than an uppercase hex
  # digit, because no collation folds `z` into `a-f` (an uppercase one would make what this case
  # measures depend on the locale it runs under).
  for cc_draw_kind in short long non-hex; do
    case "$cc_draw_kind" in
      short) cc_draw="$cc_hex32" ;;
      long) cc_draw="${cc_hex64}${cc_hex32}" ;;
      non-hex) cc_draw="zz${cc_hex64#??}" ;;
    esac
    cc_out="$(st_cc_token_draw "$cc_token_dir" "$cc_draw" "$cc_bin" "$cc_real_od")"
    case "$cc_out" in
      "prereq=0|rc=1|"*) st_ok ;;
      *) st_fail "a ${cc_draw_kind} draw is refused on a machine whose prerequisite tools are all green" "[${cc_out}]" ;;
    esac
    # The reason has to be the draw's own. Under a loosened check the value gets written and the
    # read-back refuses it instead, which is a **different** reason for a state that already has
    # the weak value on disk -- so pinning the wording is what tells the two apart.
    case "$cc_out" in
      *"cannot draw a lineage token"*) st_ok ;;
      *) st_fail "a ${cc_draw_kind} draw's reason names the draw itself" "[${cc_out}]" ;;
    esac
    st_expect_true "a ${cc_draw_kind} draw leaves no token file behind" \
      test ! -e "$cc_token_dir/$REIN_TOKEN_BASENAME"
    # Measured on the whole directory, not just that one name: a weakened value written under any
    # other name is still a weak secret sitting inside the runtime directory.
    st_expect_true "a ${cc_draw_kind} draw leaves the runtime directory empty" \
      test -z "$(find "$cc_token_dir" -mindepth 1 -print)"
  done
  # Accepting side: with the real `od` back, the very same call still places a token -- so none of
  # the cases above can be passing because provisioning simply stopped working.
  rm -rf "$cc_token_dir"
  mkdir -p "$cc_token_dir"
  cc_out="$(st_cc_probe 'rein_ensure_runtime_token "$ST_CC_TOKEN_DIR"
    printf "rc=%s|%s\n" "$?" "$REIN_RUNTIME_TOKEN"' "ST_CC_TOKEN_DIR=$cc_token_dir")"
  case "$cc_out" in
    "rc=0|"*) st_ok ;;
    *) st_fail "a real draw still places a lineage token" "[${cc_out}]" ;;
  esac
  st_expect_true "the token a real draw places is the declared width" \
    test "$(wc -c <"$cc_token_dir/$REIN_TOKEN_BASENAME" | tr -d ' ')" -eq "$((REIN_TOKEN_HEX_LEN + 1))"

  # (6) Resolving the short job ID runs the same entry check as the liveness judgment (agents-02).
  #
  # This reader's own entry check only went as far as `jq -e .`, so `{"error":...}` and `[1,2,3]`
  # reached the narrowing jq, which failed with a runtime error and left the handle empty --
  # returned as **1, "no match in enumeration"**. The wording the caller then shows names the
  # wrong cause ("not in the enumeration" for a CLI that never produced an enumeration at all),
  # and a broken CLI becomes indistinguishable from a session that really has gone.
  cc_body='rein_list_agents() { printf "%s" "$ST_CC_AGENTS"; }
    out="$(rein_resolve_job_handle sid)"
    printf "rc=%s|%s\n" "$?" "$out"'
  for cc_agents in '{"error":"not logged in"}' '[1,2,3]' '["str"]' '[null]' 'not-json'; do
    cc_out="$(st_cc_probe "$cc_body" "ST_CC_AGENTS=$cc_agents")"
    if [ "$cc_out" = "rc=2|" ]; then
      st_ok
    else
      st_fail "an enumeration that cannot be read declares itself 2 while resolving the job ID" \
        "[${cc_agents}] -> [${cc_out}]"
    fi
  done
  # Accepting side, all three of the declared outcomes (so none of the above can be passing
  # because resolution simply stopped answering).
  cc_out="$(st_cc_probe "$cc_body" \
    'ST_CC_AGENTS=[{"sessionId":"sid","id":"job-sid","pid":1,"status":"busy"}]')"
  st_expect_true "a matching element still resolves to its short job ID" \
    test "$cc_out" = "rc=0|job-sid"
  cc_out="$(st_cc_probe "$cc_body" \
    'ST_CC_AGENTS=[{"sessionId":"other","id":"job-other","pid":1,"status":"busy"}]')"
  st_expect_true "an enumeration without the session still returns 1 (no match)" \
    test "$cc_out" = "rc=1|"
  cc_out="$(st_cc_probe "$cc_body" \
    'ST_CC_AGENTS=[{"sessionId":"sid","pid":1,"status":"busy"}]')"
  st_expect_true "an element present but carrying no short job ID still returns 3" \
    test "$cc_out" = "rc=3|"

  # (7) A process's identity never depends on the reader's time zone (lock-01).
  #
  # `ps -o lstart` renders the start time in the **reader's** effective zone, so one and the same
  # live process yields two different strings the moment TZ differs between the claim and the
  # liveness judgment (a machine moved across zones between the two, or a launchd-started watcher
  # running with TZ unset next to a terminal that exports one). Nothing distinguishes that from
  # pid reuse, so the owner reads as stale and its lock gets seized -- breaking "only a lock
  # confirmed to have no living owner is ever retaken". A case run under a single zone cannot
  # observe this at all, so the claim below is made under one zone and judged under another.
  cc_tz_dir="$cc_dir/tz"
  mkdir -p "$cc_tz_dir"
  # The control comes first: on this machine TZ really does move what a rendering reads back.
  # Without it, a machine that ignored TZ outright would pass every case below while measuring
  # nothing at all.
  cc_tz_here="$(TZ=UTC date -r 0 +%Y-%m-%dT%H)"
  cc_tz_far="$(TZ=Pacific/Kiritimati date -r 0 +%Y-%m-%dT%H)"
  st_expect_true "the two zones this case uses really do render one instant differently" \
    test "$cc_tz_here" != "$cc_tz_far"
  # The identity is taken for **this** process (alive throughout, so the liveness judgment below
  # has a real owner to find), rendered by two readers running under different zones.
  cc_tz_here="$(st_cc_probe 'rein_process_start_identity "$ST_CC_PID"' TZ=UTC "ST_CC_PID=$$")"
  cc_tz_far="$(st_cc_probe 'rein_process_start_identity "$ST_CC_PID"' \
    TZ=Pacific/Kiritimati "ST_CC_PID=$$")"
  # Material actually came back (two empty strings would compare equal and measure nothing).
  st_expect_true "the identity of a live process is not empty" test -n "$cc_tz_here"
  st_expect_true "a process's identity is the same string in either zone" \
    test "$cc_tz_here" = "$cc_tz_far"
  # End to end through the judgment that acts on it: the declaration is the one a reader under
  # UTC produced, and the reader that judges it runs under a zone 14 hours away.
  cc_lock_tz="$cc_tz_dir/owner.lock"
  rein_claim_lock_dir "$cc_lock_tz" start "$cc_tz_here" cwd "$cc_tz_dir" token "st-tz"
  st_expect_true "the lock this case judges was actually claimed" test -e "$cc_lock_tz/start"
  cc_out="$(st_cc_probe 'rein_lock_owner_alive "$ST_CC_LOCK"; printf "rc=%s\n" "$?"' \
    TZ=Pacific/Kiritimati "ST_CC_LOCK=$cc_lock_tz")"
  st_expect_true "a lock declared under another zone still reads as having a live owner" \
    test "$cc_out" = "rc=0"
  # The other side of the same judgment: a declared start that genuinely does not belong to the
  # owner still reads as stale, so the case above cannot be passing because the comparison
  # stopped being made at all.
  printf 'Thu Jan 1 00:00:00 1970\n' >"$cc_lock_tz/start"
  cc_out="$(st_cc_probe 'rein_lock_owner_alive "$ST_CC_LOCK"; printf "rc=%s\n" "$?"' \
    TZ=Pacific/Kiritimati "ST_CC_LOCK=$cc_lock_tz")"
  st_expect_true "a declared start that does not match still reads as stale" \
    test "$cc_out" = "rc=1"
}
