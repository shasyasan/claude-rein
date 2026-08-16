# shellcheck shell=bash
# selftest's shared helpers (counting, launching, matching, cleanup).
# Not an executable script, so it carries no execute bit (out of scope for the --selftest convention).
# section-table-exempt: not a section itself but a tool the sections share, so it doesn't go in the section table (listing it would let it be called by a section name that doesn't exist).

st_pass_count=0
st_fail_count=0

st_ok() {
  st_pass_count=$((st_pass_count + 1))
}

st_fail() {
  st_fail_count=$((st_fail_count + 1))
  printf '  FAIL %s: %s\n' "$1" "$2"
}

# Leaves no watcher this check started behind. Watchers are stopped through the same interface
# production uses (a stop-request file) -- killing the process directly in just this one place
# would give this check a means outside the contract. Simply removing the temp directory would
# leave an abandoned watcher looping while it looks at a location that has vanished.
st_stop_watchers() {
  local lock dir i=0 pending="" alive owner_cwd
  [ -n "${ST_TMPDIR:-}" ] || return 0
  # Only deals with locks a watcher actually holds (a check also plants locks of the same name
  # as fixtures, so without checking who actually owns them, this would end up waiting for the
  # stop of watchers that never existed).
  while IFS= read -r lock; do
    [ -n "$lock" ] || continue
    dir="$(dirname "$lock")"
    # The counterpart for the identity check is that location's owner file. This check process
    # has no target cwd, so leaving the default counterpart (TARGET_CWD = empty) would make
    # every one of them come back as unconfirmable, and not a single watcher this check started
    # would ever get stopped. A watcher missed this way recreates its activity-log location
    # during cleanup, and the temp directory's removal then fails because it is not empty.
    owner_cwd=""
    if [ -f "$dir/$REIN_OWNER_BASENAME" ] && [ ! -L "$dir/$REIN_OWNER_BASENAME" ]; then
      owner_cwd="$(head -1 "$dir/$REIN_OWNER_BASENAME" 2>/dev/null)"
    fi
    [ -n "$owner_cwd" ] || continue
    watcher_state "$dir" "$owner_cwd" || continue
    printf '{"schema":"%s","requested_at":"%s","requested_by_pid":%s}\n' \
      "$REIN_STOP_REQUEST_SCHEMA" "$(rein_iso_now)" "$$" >"$dir/$REIN_STOP_REQUEST_BASENAME"
    pending="${pending}${pending:+ }${WATCHER_PID}"
  done <<EOF
$(find "$ST_TMPDIR" -type d -name "$REIN_LOCK_DIRNAME" -print 2>/dev/null)
EOF
  [ -n "$pending" ] || return 0
  while [ "$i" -lt 50 ]; do
    alive=""
    for lock in $pending; do
      if rein_pid_alive "$lock"; then
        alive="$lock"
        break
      fi
    done
    [ -n "$alive" ] || return 0
    sleep 0.2
    i=$((i + 1))
  done
  printf '%s: a watcher this check started is still around: pid=%s\n' "$SCRIPT_NAME" "$pending" >&2
  return 0
}

# PATH with every directory that can resolve `rein` stripped out. Assembly is shared with the
# hook runner (rein_st_path_without_cmd in lib/rein-selftest-fixtures.sh) -- so the two
# implementations never have room to drift apart.
st_path_without_rein() {
  rein_st_path_without_cmd rein
}

# A `sleep` shim (placed at the front of PATH) that stalls only the watcher's cycle-sleep. While
# a hold file is present, it holds back **only the `sleep` whose caller is rein-watcher.sh** --
# any `rein` wait running on the same PATH (the cap `down` waits on for the stop) passes right
# through. Being stalled can be observed through the frozen file, so a round this failed to
# catch never gets waved through as a watcher that just happened to run a slow cycle.
# On a loaded machine, spacing the cycle interval out wide and betting that the observation
# finishes first would let the observation lag behind and get overtaken by the cycle, producing a
# different result each round (the check on `down`'s cap actually flaked this way in practice).
st_write_watcher_hold_sleep_shim() {
  local bin_dir="$1" hold="$2" frozen="$3"
  mkdir -p "$bin_dir"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'hold=%s\n' "$(rein_shell_quote "$hold")"
    printf 'frozen=%s\n' "$(rein_shell_quote "$frozen")"
    cat <<'SHIM'
case "$(/bin/ps -o command= -p "$PPID" 2>/dev/null)" in
  *rein-watcher.sh*)
    while [ -e "$hold" ]; do
      : >"$frozen"
      /bin/sleep 0.1
    done
    ;;
esac
exec /bin/sleep "$@"
SHIM
  } >"$bin_dir/sleep"
  chmod +x "$bin_dir/sleep"
}

st_cleanup() {
  rein_st_stop_all_fake_watchers
  st_stop_watchers
  [ -n "${ST_TMPDIR:-}" ] && rm -rf "$ST_TMPDIR"
}

st_run() {
  ST_OUT="$("$ST_BASH" "$REIN_BIN_PATH" "$@" 2>&1 </dev/null)"
  ST_STATUS=$?
}

# Launches with the fake CLI at the front of PATH (a verb check never starts the real claude).
st_run_env() {
  ST_OUT="$(env "${ST_VERB_ENV[@]}" "$ST_BASH" "$REIN_BIN_PATH" "$@" 2>&1 </dev/null)"
  ST_STATUS=$?
}

# Allows a hand-placed project config (the allow gate goes by **a hash of the content**, so this
# is needed every time a fixture is rewritten). Recording the allow goes through **the real
# verb** -- this check never becomes a second writer of the ledger. The common options
# (`--root` / `--config` / `--cwd`) are passed through as the caller gave them.
st_allow_project() {
  st_run "$@" config allow
  [ "$ST_STATUS" -eq 0 ] ||
    st_fail "can allow this check's fixture" "exit=${ST_STATUS}: ${ST_OUT}"
}

# Allows a fixture that **doesn't hold together as a valid config** (`config allow` confirms the
# content holds together before recording, so the verb itself can't allow this). Whether the
# reader side rejects a format violation or an unknown key is a separate concern from the allow
# decision, so the already-allowed state has to be built before that can be measured (a
# user who can hand-edit the ledger can build the same state -- the reader side's fail-loud is
# the one line of defense this can't drop). The write goes through the config layer's own
# recording entry point directly, so this adds no extra writer of the ledger.
# $1=the project config's path, $2=that lineage's user config (the ledger sits next to it).
st_allow_project_file() {
  local file="$1" user="$2" saved="${REIN_CONFIG_USER_FILE:-}"
  REIN_CONFIG_USER_FILE="$user"
  rein_config_allow_record "$file" ||
    st_fail "can allow a fixture that doesn't hold together (same process)" "$REIN_PROJECT_ALLOW_ERROR"
  REIN_CONFIG_USER_FILE="$saved"
}

# Launches with one added environment variable (can pass a value containing a newline too).
st_run_with() {
  local assignment="$1"
  shift
  ST_OUT="$(env "$assignment" "$ST_BASH" "$REIN_BIN_PATH" "$@" 2>&1 </dev/null)"
  ST_STATUS=$?
}

st_expect_status() {
  local name="$1" expected="$2"
  if [ "$ST_STATUS" -ne "$expected" ]; then
    st_fail "${name}" "exit=${ST_STATUS} (expected ${expected}): ${ST_OUT}"
    return 1
  fi
  return 0
}

st_expect_out() {
  local name="$1" expected="$2"
  if [ "$ST_OUT" = "$expected" ]; then
    st_ok
  else
    st_fail "${name}" "output differs: expected [${expected}] / got [${ST_OUT}]"
  fi
}

# **The seat line only**, pulled out of the status table before the needle is matched. Matching
# against the whole output passes as long as the words turn up *somewhere*, and every phrase this
# particular line uses -- a session id, "the current pointer" -- also appears in the `primary
# session` and `seat log` lines sitting right next to it. A seat line that regressed all the way
# back to a bare `attached (pid=N)` would still have gone green that way.
# `seat log:` is a different line and is never picked up (the prefix carries its own space).
st_expect_seat_line() {
  local name="$1" needle="$2" line="" candidate
  if [ -z "$needle" ]; then
    st_fail "${name}" "the expected string is empty (a mis-written check -- it succeeds without ever looking at the output)"
    return
  fi
  while IFS= read -r candidate; do
    case "$candidate" in
      "seat: "*) line="$candidate" ;;
    esac
  done <<EOF
$ST_OUT
EOF
  if [ -z "$line" ]; then
    st_fail "${name}" "there is no seat line in the output: ${ST_OUT}"
    return
  fi
  case "$line" in
    *"$needle"*)
      st_ok
      ;;
    *)
      st_fail "${name}" "the seat line does not contain ${needle}: ${line}"
      ;;
  esac
}

# The must-not-appear side of the same extraction. Needed as its own helper because the phrases
# worth ruling out of the seat line -- a session id it should have stopped naming, "matches the
# current pointer" -- do appear elsewhere in the table, so the whole-output form of this check
# would fail on lines that are perfectly correct.
st_expect_seat_line_lacks() {
  local name="$1" needle="$2" line="" candidate
  if [ -z "$needle" ]; then
    st_fail "${name}" "the expected string is empty (a mis-written check -- it can never fail)"
    return
  fi
  while IFS= read -r candidate; do
    case "$candidate" in
      "seat: "*) line="$candidate" ;;
    esac
  done <<EOF
$ST_OUT
EOF
  if [ -z "$line" ]; then
    st_fail "${name}" "there is no seat line in the output: ${ST_OUT}"
    return
  fi
  case "$line" in
    *"$needle"*)
      st_fail "${name}" "the seat line still contains ${needle}: ${line}"
      ;;
    *)
      st_ok
      ;;
  esac
}

# `st_expect_contains` / `st_expect_not_contains` don't live here -- to share one implementation
# with the hook runner (scripts/rein-hook.sh), both read it from lib/rein-selftest-fixtures.sh
# (why it lives there is spelled out verbatim at the top of that file). selftest.sh loads
# helpers.sh before fixtures.sh, so both are already defined by the time st_expect_reject below calls them.

# The rejecting side is checked on 2 points: the expected exit code, and the reason's literal text.
st_expect_reject() {
  local name="$1" expected="$2" needle="$3"
  if ! st_expect_status "$name" "$expected"; then
    return 1
  fi
  st_expect_contains "$name" "$needle"
  return 0
}

st_file_content() {
  cat "$1" 2>/dev/null
}

st_expect_file() {
  local name="$1" file="$2" expected="$3" actual
  actual="$(st_file_content "$file")"
  if [ "$actual" = "$expected" ]; then
    st_ok
  else
    st_fail "${name}" "content differs: expected [${expected}] / got [${actual}]"
  fi
}

st_expect_true() {
  local name="$1"
  shift
  if "$@"; then
    st_ok
  else
    st_fail "${name}" "condition did not hold: $*"
  fi
}

# Expands the finished command embedded in a message into **the argv the shell would actually
# parse**. Instructions are meant to be pasted and run, so with no quoting, whitespace would
# split it into separate words and `$( )` would be evaluated as a command substitution --
# a check that only looks at whether the literal text appears can't measure that far.
# The expansion is confined to a child process (the message's own content must never rewrite this check process's own state).
st_argv_of() {
  # shellcheck disable=SC2016  # literal text meant to be expanded inside the subshell (expanding it here would defeat the point)
  ST_ARGV_LINE="$1" "$ST_BASH" -c 'eval "set -- $ST_ARGV_LINE"; printf "%s\n" "$@"' 2>/dev/null
}

# Cuts the finished command out of a message (from after $2 up to before $3). The advice sits
# embedded inside a prose sentence, so it's pulled out by matching the text on either side. If it
# can't be bracketed, this returns non-zero (never let an empty cut read as an empty command
# that expanded correctly).
st_slice_between() {
  local text="$1" head="$2" tail="$3" rest
  case "$text" in
    *"$head"*) ;;
    *) return 1 ;;
  esac
  rest="${text#*"$head"}"
  case "$rest" in
    *"$tail"*) ;;
    *) return 1 ;;
  esac
  printf '%s\n' "${rest%%"$tail"*}"
}

# Confirms a command cut out of a message expands into exactly the expected argv.
st_expect_argv() {
  local name="$1" text="$2" head="$3" tail="$4" line actual expected
  shift 4
  if ! line="$(st_slice_between "$text" "$head" "$tail")"; then
    st_fail "${name}" "cannot cut a command out of the message ([${head}] ... [${tail}]): ${text}"
    return
  fi
  expected="$(printf '%s\n' "$@")"
  actual="$(st_argv_of "$line")"
  if [ "$actual" = "$expected" ]; then
    st_ok
  else
    st_fail "${name}" "argv differs from expected: [${actual}] / expected [${expected}] / cut [${line}]"
  fi
}
