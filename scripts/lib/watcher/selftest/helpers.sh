# shellcheck shell=bash
# Common helpers for the watcher's selftest (counting, building cases, launching, checking, cleanup).
# Not an executable script, so it carries no execute bit (outside the --selftest convention).
# section-table-exempt: this is a tool the sections share, not a section itself, so it is not listed in the section table (listing it would let callers invoke a section name that doesn't exist).

st_pass_count=0
st_fail_count=0

st_ok() {
  st_pass_count=$((st_pass_count + 1))
}

st_fail() {
  st_fail_count=$((st_fail_count + 1))
  printf '  FAIL %s: %s\n' "$1" "$2"
}

st_cleanup() {
  rein_st_stop_all_fake_watchers
  [ -n "${ST_TMPDIR:-}" ] && rm -rf "$ST_TMPDIR"
}

# Allow the project settings the case places (`<cwd>/.rein/config`). The allow gate checks by
# **the content's hash**, so this is needed again every time the file is rewritten. Recording goes
# through the settings layer's own entry point (no new writer for the ledger).
# The ledger stays next to this case's user config -- inside the case's temp directory.
st_allow_project_config() {
  local saved="${REIN_CONFIG_USER_FILE:-}"
  REIN_CONFIG_USER_FILE="$ST_USER_CONFIG"
  rein_config_allow_record "$ST_RECORDS/config" ||
    st_fail "can allow the case's fixture" "$REIN_PROJECT_ALLOW_ERROR"
  REIN_CONFIG_USER_FILE="$saved"
}

# Build one case's working directory. Keep each case independent so it doesn't inherit state from
# the previous one.
st_setup_case() {
  local case_dir="$1"
  mkdir -p "$case_dir"
  ST_CWD="$(cd "$case_dir" && pwd -P)"
  # The default runtime data location is the user's state area, so the case must always point at
  # an isolated location.
  # The default path is via --runtime-dir. Only the cases that test the environment-variable path
  # override these two.
  ST_RUNTIME="$ST_CWD/runtime"
  ST_RUNTIME_ARGS=(--runtime-dir "$ST_RUNTIME")
  ST_RUNTIME_ENV=""
  mkdir -p "$ST_RUNTIME"
  # The lineage's records live on the project side (cwd is the case's own temp directory, so this
  # is isolated too).
  # Create it up front so the fixture can place the pointer directly (a dedicated case checks that
  # the watcher itself can create it).
  ST_RECORDS="$ST_CWD/$REIN_RECORDS_DIRNAME"
  mkdir -p "$ST_RECORDS"
  # Now that settings layers are read, the case must always point at an isolated config.
  ST_USER_CONFIG="$ST_CWD/user-config"
  # Instead of listing env vars at every launch entry point, gather the isolation setup into one
  # place in fixtures (if even one path still leaks surrounding REIN_* vars through, the user's
  # real config would sway the case's result).
  rein_st_isolation_env "$ST_USER_CONFIG" "$ST_CWD/xdg-config" "$ST_CWD/xdg"
  ST_ENV_ARGS=("${REIN_ST_ENV_ARGS[@]}")
  ST_HANDOFF="$ST_CWD/handoff.md"
  # Some sections actually launch the writer command (rein-request.sh), so build this to match the
  # template's section structure -- a document missing a section gets rejected on the
  # handover-request side, before it ever reaches the acceptance behavior under test.
  rein_st_write_handoff "$ST_HANDOFF"
  ST_AGENTS="$ST_CWD/agents.json"
  ST_LOG="$ST_CWD/claude-args.log"
  ST_NOTIFY="$ST_CWD/notify.log"
  : >"$ST_LOG"
  : >"$ST_NOTIFY"
  rein_st_write_agents "$ST_AGENTS" "$ST_CWD" "pred-1"
}

# A shim for `date` that advances the clock (placed at the front of PATH). It only advances the
# `-u +%s` form that `rein_now_epoch` uses; every other format (contract timestamps, archive-name
# timestamps, epoch-to-string conversion) passes through to the real binary -- what's under test is
# only whether the entry point that reads the current time feeds the deadline check, and breaking
# time conversion too would make a failure indistinguishable from a different cause.
# Advances by one hour on every call (a single jump would make the result depend on whether the
# jump lands before or after the deadline calculation, so a run whose jump position drifts would
# pass as a false green even with the wall clock unchanged).
# Not added to the shared fixtures (only this case uses it, so it stays with this selftest).
st_write_clock_shim() {
  local bin_dir="$1" state="$2"
  mkdir -p "$bin_dir"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'state=%s\n' "$(rein_shell_quote "$state")"
    cat <<'SHIM'
if [ "$*" = "-u +%s" ]; then
  n=0
  [ -f "$state" ] && n="$(cat "$state")"
  n=$((n + 1))
  printf '%s\n' "$n" >"$state"
  printf '%s\n' "$(($(/bin/date -u +%s) + n * 3600))"
  exit 0
fi
exec /bin/date "$@"
SHIM
  } >"$bin_dir/date"
  chmod +x "$bin_dir/date"
}

# A fake claude wrapper that plays the "successor dies right after launch confirmation" shape
# (placed at the front of PATH). Not added to the shared fixtures (only this case uses it).
# **Drops the successor from the next enumeration, once it has appeared in enumeration even once**
# -- dropping it by counting call invocations would shift the window as soon as the implementation's
# enumeration call count changes, and that run would end up testing a different case where the
# successor is still alive (a false green).
st_write_successor_death_shim() {
  local bin_dir="$1" state="$2" sid="$3"
  mkdir -p "$bin_dir"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'real=%s\n' "$(rein_shell_quote "$ST_BIN/claude")"
    printf 'state=%s\n' "$(rein_shell_quote "$state")"
    printf 'sid=%s\n' "$(rein_shell_quote "$sid")"
    cat <<'SHIM'
is_agents=0
for a in "$@"; do
  [ "$a" = "agents" ] && is_agents=1
done
if [ "$is_agents" -eq 0 ]; then
  exec "$real" "$@"
fi
out="$("$real" "$@")"
rc=$?
if [ -f "$state" ]; then
  filtered="$(printf '%s' "$out" | jq -c --arg s "$sid" '[ .[] | select(.sessionId != $s) ]' 2>/dev/null)"
  [ -n "$filtered" ] && out="$filtered"
elif printf '%s' "$out" | jq -e --arg s "$sid" 'any(.[]; .sessionId == $s)' >/dev/null 2>&1; then
  : >"$state"
fi
printf '%s\n' "$out"
exit "$rc"
SHIM
  } >"$bin_dir/claude"
  chmod +x "$bin_dir/claude"
}

# A shim for `ps` that creates the shape "another run reclaims the same location right after it's
# judged stale". Timing the race with sleep would make reproduction probabilistic, so this rides
# along the query the judgment itself issues (the owner's command line) to interrupt
# deterministically at exactly one point: **after the judgment, before the release**.
# Not added to the shared fixtures (only this case uses it).
st_write_lock_swap_ps_shim() {
  local bin_dir="$1" lock="$2" state="$3" new_pid="$4"
  mkdir -p "$bin_dir"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'lock=%s\n' "$(rein_shell_quote "$lock")"
    printf 'state=%s\n' "$(rein_shell_quote "$state")"
    printf 'new_pid=%s\n' "$(rein_shell_quote "$new_pid")"
    cat <<'SHIM'
swap=0
for a in "$@"; do
  [ "$a" = "command=" ] && swap=1
done
if [ "$swap" -eq 1 ] && [ ! -f "$state" ]; then
  : >"$state"
  rm -rf "$lock"
  mkdir -p "$lock"
  printf '%s\n' "$new_pid" >"$lock/pid"
fi
exec /bin/ps "$@"
SHIM
  } >"$bin_dir/ps"
  chmod +x "$bin_dir/ps"
}

# A shim for `sleep` that interrupts deterministically **inside the window** of the wait (placed
# at the front of PATH). Stage 2's loop always runs `rein_sleep_capped` -> `sleep` on every iteration, so
# riding along that call to write a marker on the nth invocation lands inside the window without a
# sleep race (the same shape as the existing `ps` shim riding along the judgment's own query).
# Aiming by wall-clock time or elapsed time would drift outside the window on a loaded machine and
# produce a false green.
# Not added to the shared fixtures (only this case uses it).
st_write_sleep_mark_shim() {
  local bin_dir="$1" state="$2" mark_file="$3" content="$4" at_call="${5:-1}"
  mkdir -p "$bin_dir"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'state=%s\n' "$(rein_shell_quote "$state")"
    printf 'mark_file=%s\n' "$(rein_shell_quote "$mark_file")"
    printf 'content=%s\n' "$(rein_shell_quote "$content")"
    printf 'at_call=%s\n' "$(rein_shell_quote "$at_call")"
    cat <<'SHIM'
n=0
[ -f "$state" ] && n="$(cat "$state")"
n=$((n + 1))
printf '%s\n' "$n" >"$state"
if [ "$n" = "$at_call" ]; then
  printf '%s\n' "$content" >"$mark_file"
fi
exec /bin/sleep "$@"
SHIM
  } >"$bin_dir/sleep"
  chmod +x "$bin_dir/sleep"
}

# A shim for `claude` that writes a marker **at the moment the successor is launched** (placed at
# the front of PATH). The wait deletes both markers on its way out, so a marker placed as a fixture
# before the run can never reproduce "a cancellation that arrived after the window had closed" --
# the only way into that window is to ride along the launch call itself, which by definition
# happens after the wait was left. Aiming by wall-clock or elapsed time would drift outside the
# window on a loaded machine and produce a false green.
# Everything else passes through to the fake CLI unchanged (breaking anything beyond the one point
# under test would make a failure indistinguishable from a different cause).
# Not added to the shared fixtures (only this case uses it, so it stays with this selftest).
st_write_bg_mark_shim() {
  local bin_dir="$1" mark_file="$2" content="$3"
  mkdir -p "$bin_dir"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'real=%s\n' "$(rein_shell_quote "$ST_BIN/claude")"
    printf 'mark_file=%s\n' "$(rein_shell_quote "$mark_file")"
    printf 'content=%s\n' "$(rein_shell_quote "$content")"
    cat <<'SHIM'
for a in "$@"; do
  if [ "$a" = "--bg" ]; then
    printf '%s\n' "$content" >"$mark_file"
    break
  fi
done
exec "$real" "$@"
SHIM
  } >"$bin_dir/claude"
  chmod +x "$bin_dir/claude"
}

# A shim for `date` that deterministically creates the shape "the marker vanishes right before
# claim" (another instance consumed it first -- a round that lost the race), placed at the front of
# PATH. The `-u +%Y%m%dT%H%M%SZ` form that reads the archive name's timestamp is called only from
# claim and archiving (aside from reclaiming leftovers, which only runs when processing has a
# .json in it), so riding along **the first call to claim** to delete the marker leaves `mv`'s
# source gone -- the same window as a real race. Aiming by wall-clock time or elapsed time would
# drift outside the window on a loaded machine and produce a false green.
# Every other format (contract timestamps, epoch) passes through to the real binary -- breaking
# anything beyond the one point under test would make a failure indistinguishable from a different
# cause. Not added to the shared fixtures (only this case uses it).
st_write_marker_vanish_shim() {
  local bin_dir="$1" marker="$2"
  mkdir -p "$bin_dir"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'marker=%s\n' "$(rein_shell_quote "$marker")"
    cat <<'SHIM'
if [ "$*" = "-u +%Y%m%dT%H%M%SZ" ]; then
  rm -f "$marker"
fi
exec /bin/date "$@"
SHIM
  } >"$bin_dir/date"
  chmod +x "$bin_dir/date"
}

# A shim for `claude` that measures whether the heartbeat keeps advancing **across a blocking
# external call** (placed at the front of PATH). Not added to the shared fixtures (only these
# cases use it).
# Deletes the heartbeat on every enumeration, and on the calls that block (`--bg`, `stop`) records
# whether it is back. Each record then answers exactly one question -- "did the implementation
# write the heartbeat between the last enumeration and this call" -- with **no wall clock in the
# judgment**: comparing timestamps or mtimes would need the blocking call to genuinely outlast the
# staleness cutoff, which would make the case take a minute and still drift on a loaded machine.
# Riding along the enumeration is what makes the measured gap the real one: an enumeration runs
# immediately before each blocking call in both stretches (the pre-launch snapshot before
# `claude --bg`, and resolving the job handle before `claude stop`).
# One line is appended per call, so "written before every one of them" can be told apart from
# "written before the first one only".
st_write_heartbeat_probe_shim() {
  local bin_dir="$1" heartbeat="$2" probe_dir="$3"
  mkdir -p "$bin_dir" "$probe_dir"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'real=%s\n' "$(rein_shell_quote "$ST_BIN/claude")"
    printf 'heartbeat=%s\n' "$(rein_shell_quote "$heartbeat")"
    printf 'probe_dir=%s\n' "$(rein_shell_quote "$probe_dir")"
    cat <<'SHIM'
probe_sub=""
for a in "$@"; do
  case "$a" in
    agents | stop)
      probe_sub="$a"
      break
      ;;
    --bg)
      probe_sub="bg"
      break
      ;;
  esac
done
probe_state() {
  if [ -f "$heartbeat" ]; then
    printf 'present\n'
  else
    printf 'absent\n'
  fi
}
case "$probe_sub" in
  agents)
    probe_state >"$probe_dir/last-agents"
    rm -f "$heartbeat"
    ;;
  bg | stop)
    probe_state >>"$probe_dir/$probe_sub"
    # What the enumeration right before this call saw. The enumeration is itself a blocking
    # external command, so this is the record that says whether the heartbeat was written before
    # **it** -- a stretch the record above cannot reach, since that same enumeration deletes the
    # heartbeat again on its way through.
    [ -f "$probe_dir/last-agents" ] && cat "$probe_dir/last-agents" >>"$probe_dir/${probe_sub}-prev-agents"
    ;;
esac
exec "$real" "$@"
SHIM
  } >"$bin_dir/claude"
  chmod +x "$bin_dir/claude"
}

# Reads one probe record back. A missing file means the call under observation never happened,
# which is a failure of its own -- a case that goes green because the call it watches never ran is
# a false green -- so it is reported apart from a record saying the heartbeat was gone.
st_expect_heartbeat_probe() {
  local name="$1" file="$2" content
  if [ ! -f "$file" ]; then
    st_fail "${name}" "the call under observation never happened (no record at ${file})"
    return
  fi
  content="$(cat "$file")"
  case "$content" in
    *absent*)
      st_fail "${name}" "the heartbeat had not been written when the call started: ${content}"
      return
      ;;
  esac
  st_ok
}

st_run_watcher() {
  local env_args alarm_args
  # Distinguish "pass this env var" from "don't pass it" (settings layers read an explicit empty
  # value as "disabled at this layer", so always passing an empty string would block config-file
  # values from ever reaching through).
  env_args=(
    "${ST_ENV_ARGS[@]}"
    "PATH=${ST_BROKEN_BIN:+$ST_BROKEN_BIN:}$ST_BIN:$PATH"
    "FAKE_LOG=$ST_LOG"
    "FAKE_NOTIFY_LOG=$ST_NOTIFY"
    "FAKE_AGENTS=$ST_AGENTS"
    "REIN_POLL_INTERVAL_SEC=${ST_INTERVAL:-0.2}"
    # Disable the final-output wait by default (0 seconds). Hooks are what place the marker, and
    # this selftest never launches hooks -- left at the real default, every case that exercises a
    # handover would sit through the full 120-second wait. Only the cases that test the wait itself
    # override these two (-> proc:final-output).
    "REIN_FINAL_OUTPUT_TIMEOUT_SEC=${ST_FINAL_OUTPUT_TIMEOUT:-0}"
    "REIN_FINAL_OUTPUT_WAIT_SEC=${ST_FINAL_OUTPUT_WAIT:-0}"
    "REIN_LAUNCH_TIMEOUT_SEC=${ST_LAUNCH_TIMEOUT:-2}"
    "REIN_EXIT_GRACE_SEC=${ST_EXIT_GRACE:-1}"
    "REIN_STOP_TIMEOUT_SEC=${ST_STOP_TIMEOUT:-1}"
    "REIN_CMD_TIMEOUT_SEC=${ST_CMD_TIMEOUT:-60}"
    "FAKE_BG_SILENT=${ST_BG_SILENT:-0}"
    "FAKE_BG_FAIL=${ST_BG_FAIL:-0}"
    # The launched session's hook deleting the temporary launch settings, and the watcher's grace
    # period for observing that deletion. The fake deletes it inside the `--bg` call itself, so on
    # the healthy path the wait ends on its first check and this value is never spent -- it is
    # shortened here only so the case that makes it run out (ST_BG_KEEP_SETTINGS) doesn't sit
    # through the real grace period.
    "FAKE_BG_KEEP_SETTINGS=${ST_BG_KEEP_SETTINGS:-0}"
    "REIN_MANAGED_SETTINGS_DROP_SEC=${ST_MANAGED_SETTINGS_DROP:-1}"
    "FAKE_BG_DUPLICATE=${ST_BG_DUPLICATE:-0}"
    "FAKE_BG_HANG_SEC=${ST_BG_HANG:-}"
    "FAKE_SABOTAGE_PATH=${ST_SABOTAGE:-}"
    "FAKE_STOP_INEFFECTIVE=${ST_STOP_INEFFECTIVE:-0}"
    "FAKE_STOP_FAIL=${ST_STOP_FAIL:-0}"
    "FAKE_EXIT_AFTER_POLLS=${ST_EXIT_AFTER_POLLS:-}"
    "FAKE_AGENTS_FAIL=${ST_AGENTS_FAIL:-0}"
    "FAKE_AGENTS_FAIL_AFTER=${ST_AGENTS_FAIL_AFTER:-}"
    "FAKE_OSASCRIPT_FAIL=${ST_OSASCRIPT_FAIL:-0}"
    "FAKE_PRED_ID=${ST_PRED_ID:-pred-1}"
    "FAKE_SUCC_ID=${ST_SUCC_ID:-succ-1}"
  )
  if [ -n "${ST_RUNTIME_ENV:-}" ]; then
    env_args+=("REIN_RUNTIME_DIR=$ST_RUNTIME_ENV")
  fi
  # Case-specific overrides (such as where the organization managed settings live).
  env_args+=(${ST_ENV_EXTRA[@]+"${ST_ENV_EXTRA[@]}"})
  # An outer cutoff (only for cases that set `ST_ALARM_SEC`). **Instead of measuring the wait limit
  # by elapsed real time**, set the limit large enough that reaching it always means being cut off,
  # and send SIGALRM from outside just before that -- a run that waits out the full limit exits
  # 142 (128+SIGALRM), while a run that exits normally returns its real exit code.
  # Splitting on an absolute elapsed-time value would produce a false red on a loaded machine that
  # crosses the boundary.
  alarm_args=()
  if [ -n "${ST_ALARM_SEC:-}" ]; then
    alarm_args=(perl -e 'alarm shift; exec @ARGV' "$ST_ALARM_SEC")
  fi
  ST_OUT="$(env "${env_args[@]}" ${alarm_args[@]+"${alarm_args[@]}"} \
    "$REIN_ST_BASH" "$SCRIPT_PATH" --cwd "$ST_CWD" ${ST_RUNTIME_ARGS[@]+"${ST_RUNTIME_ARGS[@]}"} \
    ${ST_MODE_ARGS[@]+"${ST_MODE_ARGS[@]}"} \
    ${ST_ARGS[@]+"${ST_ARGS[@]}"} 2>&1 </dev/null)"
  ST_STATUS=$?
}

# Common check for the shape that fails at startup (missing prerequisite tool, bad settings value).
# Does not launch a successor, sends a notification, and exits non-zero.
# A call with an empty expected string **always matches** (`*""*` matches any string), which would
# count a pass without looking at the output at all. Calls that pass the whole needle through a
# variable do exist, so a run with a misspelled variable name would turn green. Fail an empty
# needle as a broken case instead.
st_expect_startup_reject() {
  local name="$1" needle="$2"
  if [ -z "$needle" ]; then
    st_fail "${name}" "the expected string is empty (a broken case -- it would pass without looking at the output)"
    return
  fi
  if ! st_expect_status "${name}" 2; then
    return
  fi
  case "$ST_OUT" in
    *"$needle"*) ;;
    *)
      st_fail "${name}" "the reason doesn't contain ${needle}: ${ST_OUT}"
      return
      ;;
  esac
  if [ -s "$ST_LOG" ]; then
    st_fail "${name}" "should have failed before launch, but called claude: $(cat "$ST_LOG")"
    return
  fi
  st_expect_notify "${name}" "rein: cannot start the watcher" "$needle" || return
  st_ok
}

# Outer limit (seconds) for daemon cases. The cutoff is sent by st_alarm_watcher_daemon once
# observation is done, so this value doesn't affect the normal duration -- it's a guardrail that
# only rescues a run so slow that observation itself never arrives.
# Setting it close to the observation's actual duration would kill the watcher before observation
# finishes on a loaded machine, failing every run -- always set it larger than the sum of every
# waiting entry point's default below, stacked across everything one daemon case watches for.
# shellcheck disable=SC2034  # the reader is on the section's file side -- looks unused within this one file
ST_DAEMON_GUARD_SEC=180

# The entry point that runs daemon mode (no --once) for a bounded time. It's cut off from outside
# by alarm, so it can also observe "it never finishes on its own" (a healthy, still-watching daemon
# dies with 142).
# The argument is an upper limit, not a wait time -- sections whose observation is done close it
# themselves via st_alarm_watcher_daemon.
st_run_watcher_daemon_bg() {
  local seconds="$1" st_daemon_child
  ST_DAEMON_OUT="$ST_CWD/daemon.out"
  ST_DAEMON_RC_FILE="$ST_CWD/daemon.rc"
  # Capture the watcher's own pid so the cutoff can be sent from outside. The subshell's pid can't
  # substitute for it (sending to the subshell would leave the watcher alive).
  ST_DAEMON_WATCHER_PID_FILE="$ST_CWD/daemon.watcher-pid"
  rm -f "$ST_DAEMON_RC_FILE" "$ST_DAEMON_WATCHER_PID_FILE"
  # Capture the exit status via a file. Waiting directly on a background job killed by a signal
  # makes the calling shell mix an "Alarm clock" notice line into the output.
  (
    env "${ST_ENV_ARGS[@]}" \
      PATH="${ST_BROKEN_BIN:+$ST_BROKEN_BIN:}$ST_BIN:$PATH" \
      FAKE_LOG="$ST_LOG" \
      FAKE_NOTIFY_LOG="$ST_NOTIFY" \
      FAKE_AGENTS="$ST_AGENTS" \
      REIN_POLL_INTERVAL_SEC=0.2 \
      REIN_FINAL_OUTPUT_TIMEOUT_SEC="${ST_FINAL_OUTPUT_TIMEOUT:-0}" \
      REIN_FINAL_OUTPUT_WAIT_SEC="${ST_FINAL_OUTPUT_WAIT:-0}" \
      REIN_LAUNCH_TIMEOUT_SEC=2 \
      REIN_EXIT_GRACE_SEC=1 \
      REIN_STOP_TIMEOUT_SEC=1 \
      FAKE_PRED_ID="pred-1" \
      FAKE_SUCC_ID="succ-1" \
      perl -e 'alarm shift; exec @ARGV' "$seconds" \
      "$REIN_ST_BASH" "$SCRIPT_PATH" --cwd "$ST_CWD" ${ST_RUNTIME_ARGS[@]+"${ST_RUNTIME_ARGS[@]}"} \
      >"$ST_DAEMON_OUT" 2>&1 </dev/null &
    st_daemon_child=$!
    # perl arms the alarm, then exec replaces it with the watcher -- so this pid is the watcher itself.
    printf '%s' "$st_daemon_child" >"$ST_DAEMON_WATCHER_PID_FILE"
    wait "$st_daemon_child"
    printf '%s' "$?" >"$ST_DAEMON_RC_FILE"
    # The shell prints the signal-exit notice line ("Alarm clock"), so discard this subshell's
    # stderr wholesale (the watcher's own output is captured separately in daemon.out).
  ) 2>/dev/null &
  # shellcheck disable=SC2034  # the reader is on the section's file side (`wait "$ST_DAEMON_PID"`) -- looks unused within this one file
  ST_DAEMON_PID=$!
}

# Witnesses that the daemon has not stepped down on its own. **Does not wait by wall clock** --
# on a loaded machine that would only say "it survived that many seconds", passing even with the
# loop stalled. The heartbeat is a marker that advances on every poll (what the attach loop uses to
# tell whether the watcher has stopped), so one advance means "it has genuinely completed a cycle
# since the last observation". Returns as soon as it advances, so on a fast-cycling machine this is
# quicker than waiting out a fixed time.
# The location differs per section (some sections don't pass `--runtime-dir`), so pull the real
# path from the case's temp directory -- a case only launches one watcher, so exactly one heartbeat
# is found.
st_witness_daemon_alive() {
  local limit="${1:-150}" i=0 hb first now
  hb="$(find "$ST_CWD" -name "$REIN_HEARTBEAT_BASENAME" 2>/dev/null)"
  case "$hb" in
    '')
      st_fail "the daemon publishes a heartbeat" "no heartbeat found: ${ST_CWD}"
      return 1
      ;;
    *$'\n'*)
      st_fail "the daemon's heartbeat resolves to exactly one" "multiple heartbeats found: ${hb}"
      return 1
      ;;
  esac
  first="$(rein_mtime "$hb")"
  while [ "$i" -lt "$limit" ]; do
    # A run that has already stepped down on its own never advances no matter how long it waits --
    # fail it explicitly before it blocks all the way to the limit.
    if [ -s "$ST_DAEMON_RC_FILE" ]; then
      st_fail "the daemon stays alive throughout the witness" \
        "the watcher exited on its own with exit $(cat "$ST_DAEMON_RC_FILE"): $(cat "$ST_DAEMON_OUT" 2>/dev/null)"
      return 1
    fi
    sleep 0.2
    now="$(rein_mtime "$hb")"
    if [ -n "$first" ] && [ -n "$now" ] && [ "$now" -gt "$first" ]; then
      return 0
    fi
    i=$((i + 1))
  done
  st_fail "the heartbeat advances during the witness" "mtime hasn't advanced past ${first}: ${hb}"
  return 1
}

# Close a daemon watcher whose observation is done, without waiting out the full limit.
#   1. Witness it (wait until the heartbeat advances once -- see one cycle complete). Cutting off
#      right after the last observation would let through the shape "steps down right after being
#      observed". A section that has already witnessed passes 0.
#   2. Send SIGALRM from outside (the same signal as perl's alarm -- keeps the exit-142 observation
#      unchanged).
# **Do not send it to a run whose exit code is already recorded** (one that had already stepped
# down on its own) -- that is exactly the regression these cases exist to catch, and that pid could
# have been recycled to a different process by then (staying inside the guarantee that what gets
# signaled is only a process this test itself launched).
# Confirming it's alive is not this function's job -- the caller's "is it 142" check owns that.
st_alarm_watcher_daemon() {
  local witness="${1:-1}" pid="" i=0
  # pid is written by the subshell, so wait for it to appear (some sections close it right after
  # launch).
  while [ "$i" -lt 50 ]; do
    pid="$(cat "$ST_DAEMON_WATCHER_PID_FILE" 2>/dev/null)"
    [ -n "$pid" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  if [ -z "$pid" ]; then
    # Proceeding silently on a miss would block all the way to the outer limit without ever sending
    # the signal, turning a fast red into a slow one (the section would then fail for "not 142", not
    # for the missing pid).
    st_fail "can capture the daemon watcher's pid" "the pid file never appeared: ${ST_DAEMON_WATCHER_PID_FILE}"
    wait "$ST_DAEMON_PID"
    return 1
  fi
  if [ "$witness" != "0" ]; then
    st_witness_daemon_alive
  fi
  if [ ! -s "$ST_DAEMON_RC_FILE" ]; then
    kill -ALRM "$pid" 2>/dev/null
  fi
  wait "$ST_DAEMON_PID"
}

# Wait until the given path appears (returns 1 if it never does). A watcher launched as a daemon
# publishes the marker that shows it's alive (the watcher lock) asynchronously, so reading before
# it's published just misses.
st_wait_for_path() {
  local path="$1" limit="${2:-100}" i=0
  [ -n "$path" ] || return 1
  while [ "$i" -lt "$limit" ]; do
    [ -e "$path" ] && return 0
    sleep 0.2
    i=$((i + 1))
  done
  return 1
}

# Summarize a lock's declared fields into one line (material for failure messages). A missing
# field can't be fixed without seeing exactly which name is absent.
st_lock_dump() {
  local lock="$1" name out=""
  if [ ! -d "$lock" ]; then
    printf 'no lock: %s\n' "$lock"
    return 0
  fi
  for name in pid start cwd mode token; do
    out="${out}${out:+ }${name}=$(rein_lock_field "$lock" "$name")"
  done
  printf '%s\n' "$out"
}

# Wait until the given line appears in the watcher log (returns 1 if it never does).
# An empty needle always matches on the first pass (`grep -q ""` matches every line), returning
# "it appeared" without ever waiting. Since the caller proceeds assuming the wait succeeded,
# treat an empty needle as a failed wait instead.
st_wait_for_watcher_log() {
  local needle="$1" limit="${2:-100}" i=0
  [ -n "$needle" ] || return 1
  while [ "$i" -lt "$limit" ]; do
    if grep -q "$needle" "$ST_RECORDS/$REIN_WATCHER_LOG_BASENAME" 2>/dev/null; then
      return 0
    fi
    sleep 0.2
    i=$((i + 1))
  done
  return 1
}

# Wait until the given line appears in the handover log (returns 1 if it never does). Empty is
# handled the same as above.
st_wait_for_log() {
  local needle="$1" limit="${2:-100}" i=0
  [ -n "$needle" ] || return 1
  while [ "$i" -lt "$limit" ]; do
    if st_log_has "$needle"; then
      return 0
    fi
    sleep 0.2
    i=$((i + 1))
  done
  return 1
}

st_expect_status() {
  local name="$1" expected="$2"
  if [ "$ST_STATUS" -ne "$expected" ]; then
    st_fail "${name}" "exit=${ST_STATUS} (expected ${expected}): ${ST_OUT}"
    return 1
  fi
  return 0
}

# An empty needle matches every line (`grep -q ""`), returning true without ever looking at the
# log. Every caller passes on true, so return false for empty instead and let the caller's st_fail
# surface it.
st_log_has() {
  [ -n "$1" ] || return 1
  grep -q "$1" "$ST_RECORDS/$REIN_LOG_BASENAME" 2>/dev/null
}

# Check the notification word-for-word. title must match exactly; message is checked for
# containing the given text ("the notification file isn't empty" alone would let a garbled
# recipient or reason pass through unnoticed).
# A call with an empty expected string **always matches** (`*""*` matches any string), counting a
# pass without looking at the output at all. Calls that pass the whole needle through a variable do
# exist, so a run with a misspelled variable name would turn green. Fail an empty needle as a
# broken case instead.
st_expect_notify() {
  local name="$1" title="$2" needle="$3" count got_title got_message
  if [ -z "$needle" ]; then
    st_fail "${name}" "the expected string is empty (a broken case -- it would pass without looking at the output)"
    return 1
  fi
  count="$(rein_st_calls_total "$ST_NOTIFY")"
  if [ "$count" -eq 0 ]; then
    st_fail "${name}" "no notification was sent"
    return 1
  fi
  got_title="$(rein_st_notify_field "$ST_NOTIFY" "$count" title)"
  got_message="$(rein_st_notify_field "$ST_NOTIFY" "$count" message)"
  if [ "$got_title" != "$title" ]; then
    st_fail "${name}" "the notification's title differs: expected=${title} actual=${got_title}"
    return 1
  fi
  case "$got_message" in
    *"$needle"*) ;;
    *)
      st_fail "${name}" "the notification's message doesn't contain ${needle}: ${got_message}"
      return 1
      ;;
  esac
  return 0
}

# Also checks that the notification's message matches the corresponding handover-log event's
# detail word-for-word (if the notification and the log ever disagree on the reason, there's no
# way to tell which one to trust when tracing an incident).
st_expect_notify_matches_event() {
  local name="$1" title="$2" needle="$3" event="$4" count got_message detail
  st_expect_notify "$name" "$title" "$needle" || return 1
  count="$(rein_st_calls_total "$ST_NOTIFY")"
  got_message="$(rein_st_notify_field "$ST_NOTIFY" "$count" message)"
  detail="$(jq -r --arg e "$event" 'select(.event == $e) | .detail' \
    "$ST_RECORDS/$REIN_LOG_BASENAME" 2>/dev/null | tail -1)"
  if [ "$got_message" != "$detail" ]; then
    st_fail "${name}" "the notification's message and the handover log's ${event} detail differ: notification=${got_message} log=${detail}"
    return 1
  fi
  return 0
}

st_usage_case() {
  local name="$1" expected="$2"
  shift 2
  local out status
  out="$("$REIN_ST_BASH" "$SCRIPT_PATH" "$@" 2>&1 </dev/null)"
  status=$?
  if [ "$status" -ne "$expected" ]; then
    st_fail "${name}" "exit=${status} (expected ${expected}): ${out}"
    return
  fi
  case "$out" in
    *"usage:"*) ;;
    *)
      st_fail "${name}" "usage text is missing: ${out}"
      return
      ;;
  esac
  case "$out" in
    *"unbound variable"* | *"command not found"*)
      st_fail "${name}" "a runtime error is mixed in: ${out}"
      return
      ;;
  esac
  st_ok
}

# Set a file's mtime to the given epoch (BSD touch's -d accepts an ISO8601 timestamp with Z).
# A boundary case can't pin down whether the lower edge is inclusive without an actual "window
# value +/- 1 second".
st_touch_epoch() {
  touch -d "$(TZ=UTC date -u -r "$2" +%Y-%m-%dT%H:%M:%SZ)" "$1"
}

# The accepting side: clears every freshness check and the handover completes end to end.
# Check acceptance via the handover log's completion line (exit 0 alone can't distinguish this
# from "there was no marker, so it did nothing").
st_accept_case() {
  local name="$1"
  if ! st_expect_status "${name}" 0; then
    return
  fi
  if ! st_log_has '"event":"handover_completed"'; then
    st_fail "${name}" "the handover did not complete: $(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    return
  fi
  st_ok
}

# The rejecting side: each freshness rule. None of them launches a successor; all of them notify and
# exit non-zero.
# The 3rd argument is the **actual threshold value** that appears in the reason (e.g. `limit 900
# seconds`). Matching on the rule name alone would let the check pass vacuously even if the value
# used for judgment drifted from its default or was overridden by a settings layer, so rules that
# carry a threshold pin that value down too.
st_reject_case() {
  local name="$1" rule="$2" threshold="${3:-}" archived
  # The rule name reaches both the notification's message and the log **as a bare variable** (the
  # two spots below). Empty would match everything in both, turning green without ever
  # looking at the rejection reason -- fail it here as a broken case instead.
  if [ -z "$rule" ]; then
    st_fail "${name}" "the rule name is empty (a broken case -- it would pass without looking at the rejection reason)"
    return
  fi
  if ! st_expect_status "${name}" 1; then
    return
  fi
  if [ "$(rein_st_count_sub "$ST_LOG" "--bg")" -ne 0 ]; then
    st_fail "${name}" "launched a successor despite the rejection: $(cat "$ST_LOG")"
    return
  fi
  # Check the notification's recipient (title) and reason (rule name, matching the log's detail)
  # word-for-word.
  if ! st_expect_notify_matches_event "${name}" "rein: rejected a handover request" "$rule" "marker_rejected"; then
    return
  fi
  if ! st_log_has "\"event\":\"marker_rejected\""; then
    st_fail "${name}" "marker_rejected was not recorded"
    return
  fi
  if ! grep -q -e "$rule" "$ST_RECORDS/$REIN_LOG_BASENAME"; then
    st_fail "${name}" "the rejection reason is not ${rule}: $(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    return
  fi
  if [ -n "$threshold" ] && ! grep -q -e "$threshold" "$ST_RECORDS/$REIN_LOG_BASENAME"; then
    st_fail "${name}" "the rejection reason doesn't include the value used for judgment (${threshold}): $(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    return
  fi
  # Don't put a generation number on a rejection line (don't let an audit read a number for a
  # handover that never took place).
  if [ "$(jq -r 'select(.event == "marker_rejected") | .generation' "$ST_RECORDS/$REIN_LOG_BASENAME" | tr '\n' ' ')" != "null " ]; then
    st_fail "${name}" "the rejection line's generation is not null: $(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    return
  fi
  if [ -f "$ST_RUNTIME/$REIN_MARKER_BASENAME" ]; then
    st_fail "${name}" "the rejected marker is still there (re-judgment would run forever)"
    return
  fi
  # The rejection reason also lands on **the archived record itself**. This is the handoff to the
  # Stop hook: the hook reads the `rejected/` record to make "block the stop once, for the rejected
  # generation, and quote the reason word-for-word" hold true (reverting to putting the reason only
  # in the handover log and the notification would leave the hook with no single file to read who
  # was rejected and why, and re-blocking the stop would silently stop working).
  archived="$(find "$ST_RUNTIME/$REIN_REJECTED_DIRNAME" -maxdepth 1 -type f -name '*.json' -print -quit 2>/dev/null)"
  if [ -z "$archived" ]; then
    st_fail "${name}" "the rejected marker was not archived to rejected: $(ls -a "$ST_RUNTIME/$REIN_REJECTED_DIRNAME" 2>&1)"
    return
  fi
  if jq -e . "$archived" >/dev/null 2>&1; then
    # The contract puts the rule name (R1-R10) at the front of the reason. Checking with a prefix
    # match, so a change that moves the rule name later or prepends another word fails here too.
    if ! jq -e --arg rule "$rule" '(.rejected_reason // "") | startswith($rule)' \
      "$archived" >/dev/null 2>&1; then
      st_fail "${name}" "the archived record doesn't carry the rejection reason: $(cat "$archived")"
      return
    fi
  elif [ "$rule" != "R1" ]; then
    # The only rule that can leave a record unparseable as JSON is R1 (not valid JSON). Landing
    # here under any other rule means the archived content itself is broken.
    st_fail "${name}" "the archived record is not valid JSON: $(cat "$archived")"
    return
  fi
  st_ok
}

# Don't let an explicitly empty CLI flag silently turn into "not specified" (it would run on a
# lower layer's value with no signal back to a user who meant to disable it). Keep the one way to
# disable it as config unset.
st_empty_opt_case() {
  local name="$1" key="$2"
  shift 2
  ST_ARGS=("$@")
  st_run_watcher
  unset ST_ARGS
  if ! st_expect_status "${name}" 2; then
    return
  fi
  case "$ST_OUT" in
    *"cannot take an empty value"*"config unset --user ${key} or config unset --project ${key}"*) ;;
    *)
      st_fail "${name}" "the empty-value reason is missing: ${ST_OUT}"
      return
      ;;
  esac
  if [ -s "$ST_LOG" ]; then
    st_fail "${name}" "should have failed, but called claude: $(cat "$ST_LOG")"
    return
  fi
  st_ok
}
