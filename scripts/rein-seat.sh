#!/usr/bin/env bash
# The attach loop that keeps the seat's terminal pointed at whatever session the current pointer
# names. When a handover swaps the pointer, this attaches to the successor with zero action from the
# user. Contract: docs/spec/architecture.md. No errexit: a non-zero return from attach still has to fall
# through to the logic below it.
set -uo pipefail

# Normalize the entry environment. Force the locale to UTF-8 (bash can't parse this file under a
# non-UTF-8 multibyte locale) and unset CDPATH (it makes `$(cd ... && pwd -P)` print two lines).
# Both must happen **before the shared libraries are sourced**; see the same two lines next to
# bin/rein for why.
unset LC_ALL CDPATH
export LC_CTYPE=UTF-8

# Resolve this script's own location with **string manipulation only** -- never `dirname` / `cd` /
# `pwd`. Delegating that to an external command means a `dirname` that returns empty makes `cd ""`
# succeed as a no-op, leaving the working directory unchanged, so the source right after it picks
# up **a same-named library in the working directory** (`./lib/rein-common.sh`) instead --
# whatever code sits there then runs inside this process. All it takes is a `dirname` that prints
# empty, placed ahead on PATH (observed: launching from a directory carrying the planted trap
# exits with the trap's own exit code).
# A relative invocation gets the working directory prepended to make it absolute (same as
# rein-hook.sh). This isn't skipped, because **a relative launch is the legitimate path** --
# `scripts/rein-seat.sh --selftest` is exactly how the development guide says to run it; only the
# path launched from bin/rein is already absolute.
# Prepending doesn't reopen the trap: the source resolves to **this file's own directory** (the
# real path the launcher named), never to a same-named library sitting in the working directory.
SCRIPT_PATH="${BASH_SOURCE[0]}"
case "$SCRIPT_PATH" in
  /*) ;;
  *) SCRIPT_PATH="$PWD/$SCRIPT_PATH" ;;
esac
SCRIPT_NAME="${SCRIPT_PATH##*/}"
SCRIPT_DIR="${SCRIPT_PATH%/*}"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/rein-common.sh
. "$SCRIPT_DIR/lib/rein-common.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/rein-config.sh
. "$SCRIPT_DIR/lib/rein-config.sh"

# The CLI's real path, for embedding in a one-line hint. **This layer has no way to inspect
# PATH** -- confirming whether `command -v` resolves to this implementation means following a
# symlink, and only the entry point (before the shared libraries load) has that -- so the hint
# always names the real path, which runs regardless of whether rein is on PATH.
# Built with **string manipulation only** (no extra external command). `${SCRIPT_DIR%/*}` comes
# out empty only when the real file sits directly under the root (`/scripts/`), in which case the
# concatenation becomes `/bin/rein` -- the real file directly under the root, which is correct.
# (This is not the same shape as `${HOME:-}/...`, where **missing material folds to the root**;
# folding here is correct.)
REIN_BIN="${SCRIPT_DIR%/*}/$REIN_CLI_RELPATH"

# Effective values come from the config layer (once at startup; contract "point of effect").
# These initializers exist only so nothing reads them before config is loaded; the defaults'
# canonical source is the known-keys table.
POLL_INTERVAL_SEC=""
# 0 means unlimited. The seat sitting idle while it waits for a handover is normal, so there is
# no cap by default.
WAIT_TIMEOUT_SEC=""
# Retry cap for re-attaching after attach returns non-zero. A handover in progress can fail attach
# transiently, so a few retries are allowed, but retrying forever would make "attach isn't
# working" indistinguishable from waiting.
ATTACH_RETRY_MAX=""
# Cap on how old the watcher's heartbeat can get before it's treated as stale, while waiting.
HEARTBEAT_MAX_AGE_SEC=""
# Grace period before a handover that isn't being followed counts as stalled (sum of the
# watcher side's worst-case durations).
EXIT_GRACE_SEC=""
STOP_TIMEOUT_SEC=""

TARGET_CWD=""
RUNTIME_DIR_OPT=""
MAX_ATTACH=0

RUNTIME_DIR=""
RECORDS_DIR=""
POINTER_FILE=""
# The seat's own log (only this attach loop ever writes it). Whether attach succeeded, why it
# failed, why the loop stepped down -- none of that survives anywhere else but a notification and
# a non-zero exit, and an unattended lineage has no way to trace what happened after the fact.
SEAT_LOG_FILE=""
HEARTBEAT_FILE=""
# Marker `rein down` drops when it shuts a lineage down. Only this attach loop ever reads (and
# clears) it.
SEAT_STOP_FILE=""
HEARTBEAT_WARNED=0
# How many **consecutive** rounds the watcher can be absent (no heartbeat, or a stale one) before
# the wait for a handover gives up. It doesn't give up after a single round because a watcher
# restart or a heartbeat rewrite can produce one transient miss (the same discipline as never
# concluding from a single read -- a transient enumeration failure is never a reason to step down
# from the seat). But if it's absent for consecutive rounds, whoever would drive a handover isn't
# there -- no amount of waiting will make the handover happen, and continuing to wait just keeps
# spawning the external CLI every round for nothing. It gives up on a wait that can't succeed.
WATCHER_ABSENT_LIMIT=3
WATCHER_ABSENT_STREAK=0
WATCHER_ABSENT_DETAIL=""
WATCHDOG_SENTINEL=""
WATCHDOG_PID=""
# The seat lock (a lineage has one seat). The token is checked on release (only release the one
# this process itself claimed).
SEAT_LOCK_DIR=""
SEAT_LOCK_TOKEN=""

usage() {
  cat <<EOF
usage: $SCRIPT_NAME --cwd <target project path> [options]
       $SCRIPT_NAME --selftest [section ...]
       $SCRIPT_NAME --selftest --list

  --cwd <path>          the target project's directory (required)
  --runtime-dir <path>  where runtime data is kept (default: config's runtime_dir -> XDG state area)
  --max-attach <N>      cap on how many times to attach (default: 0 = unlimited)
  --once                attach once and exit (same as --max-attach 1)

  The current pointer is read from the target project's ${REIN_RECORDS_DIRNAME}/ (where the
  lineage's records are kept).
EOF
}

# One record line (column assembly lives in one place, the shared library). The generation is
# included only on the rounds where it can be read from the pointer.
seat_log() {
  local event="$1" detail="$2" session="${3:-}" generation=""
  [ -n "$SEAT_LOG_FILE" ] || return 0
  # The seat **never creates** the records location. If the lineage exists, the location already
  # exists (rein up / rein init sets it up via rein_ensure_records_dir, with a `.gitignore`
  # holding just `*`), so its absence means the directory has no lineage at all -- writing here
  # anyway would grow a `.rein/` in an unrelated repository from one mistyped cwd (the shared
  # path for writing a record line runs through the one function that provisions the location, so
  # the `.gitignore` would be there too, but the location itself still shouldn't sprout in an
  # unrelated repository).
  [ -d "$RECORDS_DIR" ] || return 0
  if [ -f "$POINTER_FILE" ]; then
    generation="$(rein_pointer_field "$POINTER_FILE" "generation")"
    case "$generation" in
      '' | *[!0-9]*) generation="" ;;
    esac
  fi
  rein_seat_log_event "$SEAT_LOG_FILE" "$event" "$detail" "$generation" "$session"
}

seat_fail() {
  seat_log seat_failed "$1"
  rein_notify "rein: cannot keep the seat" "$1"
  return 1
}

# Validates a CLI flag's value (the wording for the reason lives in the config layer -- not
# duplicated across the three scripts).
check_opt() {
  rein_config_check_opt "$@" && return 0
  printf '%s: %s\n' "$SCRIPT_NAME" "$REIN_CONFIG_ERROR" >&2
  return 2
}

# The value entry point for flags that don't correspond to a config-layer key (--cwd /
# --max-attach). Rejects, with a reason, both a missing value and an **explicit empty value** (the
# same discipline as bin/rein's need_value and the config layer's rein_config_check_opt, wording
# included -- so the same typo lands on the same one line regardless of which entry point it came in
# through). Using `shift 2`'s non-zero directly as the return would turn one typo into a
# **completely silent non-zero** -- the user at the keyboard couldn't even tell whether they got
# seated. Not silently folding an empty value into "unspecified" is the same reasoning: never return
# without a signal, leaving a lower layer's value (the shell's own cwd, for `--cwd ""`) to run
# instead.
need_value() {
  local flag="$1" count="$2" value="${3-}"
  if [ "$count" -lt 2 ]; then
    printf '%s: %s requires a value\n' "$SCRIPT_NAME" "$flag" >&2
    return 2
  fi
  if [ -z "$value" ]; then
    printf '%s: %s cannot take an empty value (not treated as unspecified)\n' "$SCRIPT_NAME" "$flag" >&2
    return 2
  fi
  return 0
}

startup_reject() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2
  rein_notify "rein: cannot start the attach loop" "$1"
  return 2
}

# Reads the config layer, then layers CLI flags (stronger than environment variables) on top
# before extracting the effective values (contract "point of effect" -- the attach loop does this
# once at startup). Type and combination checks are already done by the config layer, so this
# only looks at --max-attach, which sits outside it.
load_config() {
  local reason
  if ! rein_config_prepare "$REIN_BIN" "$TARGET_CWD"; then
    startup_reject "$REIN_CONFIG_ERROR"
    return 2
  fi
  if [ -n "$RUNTIME_DIR_OPT" ] && ! rein_config_override runtime_dir "$RUNTIME_DIR_OPT"; then
    startup_reject "$REIN_CONFIG_ERROR"
    return 2
  fi
  if ! rein_config_check_cross_fields; then
    startup_reject "$REIN_CONFIG_ERROR"
    return 2
  fi
  rein_config_bind POLL_INTERVAL_SEC poll_interval_sec || return 2
  rein_config_bind WAIT_TIMEOUT_SEC seat_wait_timeout_sec || return 2
  rein_config_bind ATTACH_RETRY_MAX seat_attach_retry_max || return 2
  rein_config_bind HEARTBEAT_MAX_AGE_SEC seat_heartbeat_max_age_sec || return 2
  rein_config_bind EXIT_GRACE_SEC exit_grace_sec || return 2
  rein_config_bind STOP_TIMEOUT_SEC stop_timeout_sec || return 2
  rein_config_bind CMD_TIMEOUT_SEC cmd_timeout_sec || return 2
  rein_config_bind RUNTIME_DIR runtime_dir || return 2
  RUNTIME_DIR="$(rein_resolve_runtime_dir "$TARGET_CWD" "$RUNTIME_DIR")"
  if [ -z "$RUNTIME_DIR" ]; then
    startup_reject "cannot resolve where runtime data is kept (name it explicitly with --runtime-dir)"
    return 2
  fi
  # Verify the runtime directory's owner (read-only -- the seat doesn't add a writer). A seat
  # pointed at the wrong location would read another lineage's watcher heartbeat as its own, and
  # keep waiting silently on a "fresh heartbeat" even while its own watcher is dead.
  if ! rein_verify_runtime_owner "$RUNTIME_DIR" "$TARGET_CWD"; then
    startup_reject "$REIN_RUNTIME_ERROR"
    return 2
  fi
  if ! rein_validate_number "--max-attach" "$MAX_ATTACH" nonneg-int; then
    printf -v reason 'the setting value is invalid: %s' "$REIN_INVALID_VALUE"
    startup_reject "$reason"
    return 2
  fi
  return 0
}

# Startup prerequisite check. Entering the wait with a missing tool makes pointer validation and
# liveness checks fail for the wrong reason.
validate_runtime() {
  local reason
  if ! rein_check_prerequisites "$SCRIPT_PATH"; then
    printf -v reason 'a prerequisite is not usable: %s' "$REIN_MISSING_TOOLS"
    startup_reject "$reason"
    return 2
  fi
  return 0
}

# Checks whether the watcher is alive by the heartbeat's freshness. Stepping the seat down after one
# absent round would close the user's own terminal, so this function's job stops at **counting and
# sending one notification**; whether to give up on the wait is decided by the wait loop itself from
# the consecutive-round count (WATCHER_ABSENT_STREAK). Deciding it here would step down before a
# handover or a `rein down` marker that landed in the same round gets a chance -- vacating the seat
# without looking at material that could still move things forward.
check_watcher_heartbeat() {
  local mtime age detail="" reason
  [ "$HEARTBEAT_MAX_AGE_SEC" -gt 0 ] || return 0
  mtime="$(rein_mtime "$HEARTBEAT_FILE")"
  case "$mtime" in
    '' | *[!0-9]*)
      detail='no heartbeat'
      ;;
    *)
      age="$(($(rein_now_epoch) - mtime))"
      if [ "$age" -gt "$HEARTBEAT_MAX_AGE_SEC" ]; then
        printf -v detail 'heartbeat is %s seconds old > cap %s seconds' "$age" "$HEARTBEAT_MAX_AGE_SEC"
      fi
      ;;
  esac
  if [ -z "$detail" ]; then
    # A fresh heartbeat read in even one round breaks the streak (a transient miss around a
    # watcher restart or a heartbeat rewrite doesn't step the seat down).
    WATCHER_ABSENT_STREAK=0
    WATCHER_ABSENT_DETAIL=""
    return 0
  fi
  WATCHER_ABSENT_DETAIL="$detail"
  WATCHER_ABSENT_STREAK=$((WATCHER_ABSENT_STREAK + 1))
  # One notification per wait, at most (firing every poll would make the notification
  # meaningless). The counting itself keeps running silently -- returning early once notified
  # would stop the streak at 1 and the give-up threshold would never fire.
  [ "$HEARTBEAT_WARNED" -eq 0 ] || return 0
  HEARTBEAT_WARNED=1
  printf -v reason 'the watcher may have stopped (%s): %s' "$detail" "$HEARTBEAT_FILE"
  seat_log heartbeat_warned "$reason"
  rein_notify "rein: the handover may not be coming" "$reason"
  return 0
}

# Assembles the one-line hint for restarting the watcher (the lineage is named from the effective
# values, so the hint never points at the wrong lineage). When the name can't be assembled, this
# says so instead of printing the line (the same discipline as rein-request.sh). The body is
# built into a variable, and the line meant to be typed sits at the end so it can be selected
# and pasted straight from the terminal.
WATCHER_RESTART_HINT=""
watcher_restart_hint() {
  if ! rein_lineage_cmd "$REIN_BIN" "$RUNTIME_DIR" "$RECORDS_DIR" "$TARGET_CWD" up; then
    printf -v WATCHER_RESTART_HINT 'restart the watcher (cannot name this lineage: %s)' \
      "$REIN_LINEAGE_ERROR"
    return 0
  fi
  printf -v WATCHER_RESTART_HINT 'restart the watcher: %s' "$REIN_LINEAGE_CMD"
}

# A missing, broken, or empty pointer isn't something waiting will fix, so this never waits silently
# through one. It also checks schema and cwd -- attaching to the wrong location's session would mix
# work in without the user being able to tell.
read_pointer_session_id() {
  local session_id schema pointer_cwd
  if [ ! -f "$POINTER_FILE" ]; then
    return 1
  fi
  if ! jq -e . "$POINTER_FILE" >/dev/null 2>&1; then
    return 2
  fi
  schema="$(rein_pointer_field "$POINTER_FILE" "schema")"
  if [ "$schema" != "$REIN_POINTER_SCHEMA" ]; then
    return 4
  fi
  pointer_cwd="$(rein_pointer_field "$POINTER_FILE" "cwd")"
  if [ "$pointer_cwd" != "$TARGET_CWD" ]; then
    return 5
  fi
  session_id="$(rein_pointer_field "$POINTER_FILE" "session_id")"
  if [ -z "$session_id" ]; then
    return 3
  fi
  printf '%s\n' "$session_id"
  return 0
}

pointer_error_reason() {
  case "$1" in
    1)
      printf 'there is no current pointer: %s' "$POINTER_FILE"
      ;;
    2)
      printf 'the current pointer is broken JSON: %s' "$POINTER_FILE"
      ;;
    4)
      printf "the current pointer's schema does not match the contract: %s" "$(rein_pointer_field "$POINTER_FILE" "schema")"
      ;;
    5)
      printf "the current pointer's cwd does not match the target: %s" "$(rein_pointer_field "$POINTER_FILE" "cwd")"
      ;;
    *)
      printf 'the current pointer has no session_id: %s' "$POINTER_FILE"
      ;;
  esac
}

# Waits for the pointer to change. If the target session disappears while waiting, the handover
# has stalled partway through (nobody is picking up the seat), so this surfaces it instead of
# continuing to wait.
# 0=the pointer changed / 1=there's a reason it can't wait (SEAT_WAIT_REASON) / 2=a marker for
# shutting the lineage down was dropped
wait_for_pointer_change() {
  local previous_id="$1" deadline current rc
  deadline=0
  if [ "$WAIT_TIMEOUT_SEC" -gt 0 ]; then
    # The deadline is measured on a monotonic clock (a wall clock would let a running clock
    # adjustment stretch or shrink the cap).
    deadline="$(($(rein_now_monotonic) + WAIT_TIMEOUT_SEC))"
  fi
  while :; do
    sleep "$POLL_INTERVAL_SEC"
    # The marker is dropped **before** the external stop, so a waiting seat notices it a round
    # ahead. Missing it and moving on would let the primary session disappear right after, firing
    # the "the session ended but the pointer wasn't updated" notification -- ringing an alarm over a
    # stop the user meant to trigger.
    if seat_stop_mark_present; then
      return 2
    fi
    check_watcher_heartbeat
    current="$(read_pointer_session_id)"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      SEAT_WAIT_REASON="$(pointer_error_reason "$rc")"
      return 1
    fi
    if [ "$current" != "$previous_id" ]; then
      return 0
    fi
    rein_is_session_live "$previous_id"
    rc=$?
    if [ "$rc" -eq 1 ]; then
      printf -v SEAT_WAIT_REASON 'session %s ended, but the current pointer was never updated' "$previous_id"
      return 1
    fi
    if [ "$rc" -eq 2 ]; then
      printf -v SEAT_WAIT_REASON '%s (cannot determine whether the session is alive)' "$(rein_list_agents_error)"
      return 1
    fi
    if [ "$deadline" -gt 0 ] && [ "$(rein_now_monotonic)" -gt "$deadline" ]; then
      printf -v SEAT_WAIT_REASON 'the current pointer did not change for %s seconds' "$WAIT_TIMEOUT_SEC"
      return 1
    fi
    # The watcher has been absent for consecutive rounds -- whoever would drive a handover isn't
    # there. This is checked **only after every other check above has passed**, so a handover, a
    # stop marker, or the target disappearing in the same round is never missed (anything that
    # can still move things forward wins first). The design still waits indefinitely by default;
    # this only gives up on a wait that cannot succeed.
    if [ "$WATCHER_ABSENT_STREAK" -ge "$WATCHER_ABSENT_LIMIT" ]; then
      watcher_restart_hint
      printf -v SEAT_WAIT_REASON "the watcher's heartbeat has not been updated for %s consecutive rounds (%s): %s. Nobody is there to drive a handover, so waiting longer will not switch to a successor. %s" \
        "$WATCHER_ABSENT_LIMIT" "$WATCHER_ABSENT_DETAIL" "$HEARTBEAT_FILE" "$WATCHER_RESTART_HINT"
      return 1
    fi
  done
}

seat_cleanup() {
  [ -n "$WATCHDOG_SENTINEL" ] && rm -f "$WATCHDOG_SENTINEL" "${WATCHDOG_SENTINEL}.log"
  release_seat_lock
  rein_close_error_sink
}

# **Claims** the seat ahead of time (a lineage has one seat). This doesn't decide by matching
# against `ps`, because that can't close the gap where "the other side disappears between the
# check and the claim" or "both start at once" -- an atomic create (mkdir + publish by rename) is
# the only thing that can claim ahead of time.
# The claim records pid plus start time (so a reused pid isn't mistaken for the owner), cwd, and
# a token.
# 0=claimed / 1=already seated (reason already printed) / 2=cannot provision
claim_seat_lock() {
  local rc pid start reason
  # The lock lives in the runtime directory. The seat can start before the watcher does, so this
  # creates it here if it's missing (with the owner recorded -- this is where grabbing the wrong
  # cwd's location would fail).
  if ! rein_ensure_runtime_dir "$RUNTIME_DIR" "$TARGET_CWD"; then
    printf '%s: %s\n' "$SCRIPT_NAME" "$REIN_RUNTIME_ERROR" >&2
    return 2
  fi
  SEAT_LOCK_DIR="$RUNTIME_DIR/$REIN_SEAT_LOCK_DIRNAME"
  SEAT_LOCK_TOKEN="$(rein_nonce)"
  start="$(rein_process_start_identity "$$")"
  rein_claim_lock_dir "$SEAT_LOCK_DIR" \
    start "$start" cwd "$TARGET_CWD" mode "$REIN_LOCK_MODE_SEAT" token "$SEAT_LOCK_TOKEN"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    return 0
  fi
  if [ "$rc" -eq 1 ]; then
    SEAT_LOCK_DIR=""
    printf '%s: cannot provision the seat lock: %s\n' "$SCRIPT_NAME" "$RUNTIME_DIR/$REIN_SEAT_LOCK_DIRNAME" >&2
    return 2
  fi
  # One already exists. If its owner is really there, **refuse** (the mechanism never seizes a seat
  # the user is actively working in).
  if rein_lock_owner_alive "$SEAT_LOCK_DIR"; then
    pid="$(rein_lock_pid "$SEAT_LOCK_DIR")"
    printf -v reason 'did not sit down: an attach loop is already seated (pid=%s)' "${pid:-unknown}"
    seat_log seat_occupied "$reason"
    printf '%s: this lineage already has an attach loop seated (pid=%s). Press Ctrl-C in that terminal, then restart it: %s\n' \
      "$SCRIPT_NAME" "${pid:-unknown}" "$TARGET_CWD" >&2
    SEAT_LOCK_DIR=""
    return 1
  fi
  # No live owner (it died, or the pid was reused) -- this is a leftover. Clear it, then claim
  # again. This clears **only the lock whose pid this process itself judged stale** (the shared
  # library's reclaim). A plain release would risk stripping a lock another seat had already
  # reclaimed in the gap between checking and clearing the same leftover -- pulling a live lock
  # out from under it (two attach loops seated at once).
  rein_claim_lock_dir_or_reclaim "$SEAT_LOCK_DIR" \
    start "$start" cwd "$TARGET_CWD" mode "$REIN_LOCK_MODE_SEAT" token "$SEAT_LOCK_TOKEN"
  rc=$?
  if [ "$rc" -eq 1 ]; then
    printf '%s: cannot clear the leftover seat lock: %s\n' "$SCRIPT_NAME" "$SEAT_LOCK_DIR" >&2
    SEAT_LOCK_DIR=""
    return 2
  fi
  if [ "$rc" -eq 0 ]; then
    return 0
  fi
  pid="$(rein_lock_pid "$SEAT_LOCK_DIR")"
  printf '%s: cannot claim the seat lock (pid=%s): %s\n' "$SCRIPT_NAME" "${pid:-unknown}" "$SEAT_LOCK_DIR" >&2
  SEAT_LOCK_DIR=""
  return 1
}

# The cap (seconds) within which a `down` that dropped the marker can still be called "in the
# middle of stopping." `down` fires one external stop right after dropping the marker (capped by
# cmd_timeout_sec) and then waits for the target to drop out of enumeration (capped by
# stop_timeout_sec), so the time from dropping the marker to `down` finishing is bounded by this
# sum (scripts/lib/cli/down.sh's stop_main_session_layer).
seat_stop_mark_grace_sec() {
  printf '%s\n' "$((CMD_TIMEOUT_SEC + STOP_TIMEOUT_SEC))"
}

# Whether the marker is still fresh enough to count as "a stop request in progress." **pid liveness
# alone isn't enough** -- pids get reused, so liveness alone would mistake the reused pid for the
# marker's owner and treat a leftover from a previous `down` as a "live request." The seat would sit
# down on it -- only to consume it silently on the very next attach return, making it look as though
# a `rein down` had fired that the user never ran. The same material the seat lock uses (pid plus
# start time) exists on the marker side as `requested_at`. The writer (`rein down`) always stamps it
# in the contract's format (UTC, second precision), so a marker that can't be parsed can't prove
# it's inside the window -- it's treated as a leftover.
# 0=inside the window (in progress) / 1=outside the window, or unparseable
seat_stop_mark_fresh() {
  local requested_at age
  requested_at="$(jq -r '.requested_at // empty' "$SEAT_STOP_FILE" 2>/dev/null)"
  rein_iso_to_epoch "$requested_at" >/dev/null || return 1
  # This compares against a value on disk (a time the writer stamped), so it stays on the wall
  # clock (a monotonic clock's origin differs per process -- a writer's and a reader's values in
  # different processes can't be compared).
  age=$(($(rein_now_epoch) - REIN_ISO_EPOCH))
  # A future timestamp (from a running clock adjustment) isn't "old" -- this errs toward never
  # clearing a stop marker the user actually dropped.
  [ "$age" -le "$(seat_stop_mark_grace_sec)" ]
}

# The seat-directed marker `rein down` drops. This checks the contract's format (schema) before
# reading it -- consuming a file that doesn't match the format as the marker would step the seat
# down silently just because something with the same name got placed there.
seat_stop_mark_present() {
  [ -f "$SEAT_STOP_FILE" ] || return 1
  [ "$(jq -r '.schema // empty' "$SEAT_STOP_FILE" 2>/dev/null)" = "$REIN_SEAT_STOP_SCHEMA" ]
}

# Clears any marker left over from before this seat sat down. Sitting down with a previous `down`'s
# marker still in place means this seat consumes it on its very first attach return and steps down
# silently (a seat never consumes a marker that isn't addressed to it). **Cleanup does not check the
# contract's format** (its discipline differs from consumption) -- the side that consumes a marker
# and steps down checks the schema to honor "never step down on something else," but cleanup's job
# is "get rid of whatever is left lying around," so something with just a matching name gets cleared
# the same way. But **it leaves the marker alone if the `down` that dropped it is still mid-stop**
# -- a seat that sits down inside the window between the marker being dropped and the external stop
# taking effect, and consumes it, would find no marker on the very next attach return, and the stop
# the user actually triggered would ring as the "session ended but the pointer was never updated"
# failure (the seat only holds the seat lock, so `down`'s operation lock does not serialize against
# it). The judgment uses **both** the pid's liveness and the freshness of `requested_at` (either
# alone mistakes a reused pid for the owner -- see seat_stop_mark_fresh). A marker with no pid, an
# unparseable one, or one outside the window is cleared as a leftover.
# 0=gone, or left in place because it's an in-progress request / 1=cannot clear (don't sit down)
clear_stale_seat_stop() {
  local owner alive_rc
  [ -e "$SEAT_STOP_FILE" ] || return 0
  owner="$(jq -r '.requested_by_pid // empty' "$SEAT_STOP_FILE" 2>/dev/null)"
  case "$owner" in
    '' | *[!0-9]*) ;;
    *)
      # A form whose liveness can't be confirmed isn't treated as "a leftover" -- never clear a stop
      # marker the user actually dropped (clearing it would ring the intended stop as a failure on
      # the very next attach return).
      rein_pid_alive "$owner"
      alive_rc=$?
      if [ "$alive_rc" -ne 1 ] && seat_stop_mark_fresh; then
        return 0
      fi
      ;;
  esac
  if rm -f "$SEAT_STOP_FILE"; then
    return 0
  fi
  printf '%s: cannot clear the leftover seat-directed marker (sitting down with this marker still in place makes the seat step down on the very next attach return): %s\n' \
    "$SCRIPT_NAME" "$SEAT_STOP_FILE" >&2
  return 1
}

# Clears the marker, prints one line to the terminal, and steps down (no GUI notification -- the
# user is the one who triggered the stop, and they're sitting at the terminal already). The contract
# that only the seat clears this marker lives in this one place. **A round that fails to clear it
# never says "shut down"** -- since only the seat clears it, a marker left behind is consumed
# silently by whichever seat sits down next, on its first attach return (an immediate exit the user
# has no way to explain).
# 0=cleared and stepped down / 1=cannot clear (reason already logged and notified)
consume_seat_stop_mark() {
  if ! rm -f "$SEAT_STOP_FILE"; then
    seat_fail "cannot clear the seat-directed marker rein down dropped (leaving it means the next seat that sits down steps down silently on its first attach return): ${SEAT_STOP_FILE}" # lineage-cmd-exempt: describes what happened, not a command to paste and run
    return 1
  fi
  seat_log seat_stopped "rein down shut the lineage down, so the attach loop is ending" # lineage-cmd-exempt: describes what happened, not a command to paste and run
  printf '%s: rein down shut the lineage down (ending the attach loop)\n' "$SCRIPT_NAME" # lineage-cmd-exempt: describes what happened, not a command to paste and run
  return 0
}

release_seat_lock() {
  [ -n "$SEAT_LOCK_DIR" ] || return 0
  rein_release_lock_dir_if_mine "$SEAT_LOCK_DIR" "$SEAT_LOCK_TOKEN"
  SEAT_LOCK_DIR=""
  return 0
}

# The grace period (seconds) for the watchdog that only notifies when a handover isn't being
# followed. Sum of the watcher side's worst case for the step that retires the predecessor
# (retire_predecessor): grace after the pointer update + cap for one external stop command + cap
# for confirming the stop + (cap for one enumeration call x how many steps run an enumeration),
# which by default is 15 + 60 + 60 + 182 x 3 = 681 seconds. If attach still hasn't returned past
# this, the assumption that "an external stop makes attach return" has broken down.
# **Enumeration retries are always folded in.** Dropping them from the sum (the old formula,
# `grace + cap + stop confirmation` = 135 seconds by default) crosses the threshold while the
# watcher is still legitimately re-measuring, producing a false "not being followed" notification
# even as the handover proceeds normally. The cap for one enumeration call is assembled in the
# same place as the retry constant (rein_list_agents_worst_sec) -- the formula is never
# duplicated here where only one copy would go stale.
watchdog_limit_sec() {
  printf '%s\n' "$((EXIT_GRACE_SEC + CMD_TIMEOUT_SEC + STOP_TIMEOUT_SEC \
    + $(rein_list_agents_worst_sec) * REIN_RETIRE_LIST_AGENTS_CALLS))"
}

# How far apart the notification repeats (seconds), **which is not the firing threshold**. The
# threshold has to cover the worst case a legitimate handover can take, so that the first
# notification is never a false alarm; the spacing only has to remind someone of a state already
# confirmed to be wrong, and by the time it applies the false-alarm hypothesis has been settled.
# Reusing the threshold as the spacing put both jobs on one number and broke at both ends
# (measured with this same function's inputs): `cmd_timeout_sec` at 300 gives a threshold of 3081
# seconds -- 51 minutes between reports -- and at 600 gives 6081 (101 minutes), which for any
# realistic sitting is back to the single-shot behaviour the repeat exists to fix; at the minimal
# settings a selftest uses it gives 16 seconds, a notification four times a minute.
# The derivation is kept (a lineage with wider caps still gets wider spacing) and clamped into a
# range a person can live with. The bounds bracket the default without moving it: the default
# threshold is 681 seconds (measured), which already sits inside [300, 900], so an ordinary
# lineage reports about every 11 minutes exactly as before, and only the extremes are pulled in.
watchdog_repeat_sec() {
  local limit
  limit="$(watchdog_limit_sec)"
  if [ "$limit" -lt "$REIN_SEAT_NOTIFY_REPEAT_MIN_SEC" ]; then
    printf '%s\n' "$REIN_SEAT_NOTIFY_REPEAT_MIN_SEC"
    return 0
  fi
  if [ "$limit" -gt "$REIN_SEAT_NOTIFY_REPEAT_MAX_SEC" ]; then
    printf '%s\n' "$REIN_SEAT_NOTIFY_REPEAT_MAX_SEC"
    return 0
  fi
  printf '%s\n' "$limit"
}

# Whether the seat that forked this watchdog is still the process holding that pid. **A pid alone
# is not enough** -- once the seat is gone its pid can be handed to something else, and a watchdog
# that took the new occupant for its parent would keep notifying about a seat nobody is in and go
# on appending to the seat log **beside a fresh seat that is also writing it**, which is the one
# thing the "one writer per file" contract rules out. The exposure is not hypothetical any more:
# the watchdog now runs for as long as the mismatch lasts rather than returning after one
# notification, so an orphan lives until something else claims the pid, not for a few seconds.
# The identity is the start time, the same material the lock owner check uses.
# The recorded identity being empty means `ps` could not answer at fork time; there is nothing to
# compare against then, so this falls back to plain liveness rather than treating every round as a
# mismatch (which would silently switch the watchdog off).
# A parent that cannot be confirmed either way counts as gone -- what the plain `ps` check this
# replaced already did. It fails toward going quiet rather than toward notifying about a seat
# that may no longer exist.
# 0=the parent is still there / 1=gone, replaced by a different process, or unconfirmable
seat_watchdog_parent_present() {
  local parent_pid="$1" recorded="$2"
  if [ -z "$recorded" ]; then
    rein_pid_alive "$parent_pid" || return 1
    return 0
  fi
  [ "$(rein_process_start_identity "$parent_pid")" = "$recorded" ] || return 1
  return 0
}

# A seat mid-attach has its terminal occupied and can't judge anything itself, so a child process
# watches the current pointer instead. It **only notifies** -- it never touches the terminal or
# attach (no active detach; the mechanism never seizes a seat the user is actively working in). It
# ends on its own (no stop-style command) once its parent disappears or attach has returned (the
# sentinel is gone).
#
# **It never returns after firing.** Returning on the first notification (what it used to do) made
# the whole mechanism a single-shot: the observed accident had the seat left on the predecessor
# for over 4 hours, and after that one notification -- which the user did not happen to be at the
# machine for -- nothing was ever said again, so the state that was still wrong stayed silent for
# the entire remaining window. As long as the two are out of step it keeps saying so.
#
# **The firing threshold and the repeat spacing are two different numbers** (limit and repeat).
# They answer different questions -- "could this still be a handover in progress?" and "how often
# should a state already known to be wrong be brought up again?" -- and tying the second to the
# first made the pacing swing from four notifications a minute to one every 101 minutes purely on
# a config value. The spacing is watchdog_repeat_sec; the reasoning is there.
#
# **Every firing is written to the seat log** as well as notified. A notification is not a record
# -- once it is dismissed, or missed because nobody was at the machine, nothing survives it, and
# the accident could only be reconstructed at all because a temp file happened not to have been
# cleaned up. The log is the lineage's own after-the-fact trace of how long the mismatch ran.
#
# **There is deliberately no way to silence it.** This lineage has a snooze vocabulary, and the
# watchdog does not read it: a pointer and a seat out of step is always wrong, and the mechanism
# already refuses to act on it, so the notification is the only thing left. Whether someone
# staying on an old session on purpose needs a way to quiet it is a question for the user, not
# something to decide by adding a key here.
run_attach_watchdog() {
  local attached_id="$1" sentinel="$2" parent_pid="$3" parent_start="$4" limit="$5" repeat="$6"
  local changed_at=0 notified_at=0 current reason now elapsed
  while :; do
    sleep "$POLL_INTERVAL_SEC"
    [ -e "$sentinel" ] || return 0
    seat_watchdog_parent_present "$parent_pid" "$parent_start" || return 0
    current="$(read_pointer_session_id)" || continue
    if [ "$current" = "$attached_id" ]; then
      # Back in step. The repeat clock is cleared along with the measurement, so a later mismatch
      # is spaced from its own first firing rather than from a stale one.
      changed_at=0
      notified_at=0
      continue
    fi
    now="$(rein_now_monotonic)"
    if [ "$changed_at" -eq 0 ]; then
      changed_at="$now"
      continue
    fi
    elapsed="$((now - changed_at))"
    if [ "$elapsed" -le "$limit" ]; then
      continue
    fi
    if [ "$notified_at" -ne 0 ] && [ "$((now - notified_at))" -lt "$repeat" ]; then
      continue
    fi
    notified_at="$now"
    # The instruction comes first: on a notification the tail can be cut off, and what the user
    # needs is the one action that ends the state, not the arithmetic behind it.
    printf -v reason 'attach has not returned -- %s. The pointer moved to %s %s seconds ago while this seat is still connected to %s (this only notifies: it never touches your terminal or the connection). It repeats every %s seconds until the two line up.' \
      "$REIN_SEAT_DETACH_HINT" "$current" "$elapsed" "$attached_id" "$repeat"
    seat_log "$REIN_SEAT_EVENT_HANDOVER_STALLED" "$reason" "$attached_id"
    rein_notify "rein: the handover is not being followed" "$reason"
  done
}

run_seat() {
  local session_id next_id rc attach_handle attach_count=0 attach_rc attach_retry=0 watchdog_parent_start
  local resolved_cwd cwd_error

  if [ -z "$TARGET_CWD" ]; then
    printf '%s: --cwd is required\n' "$SCRIPT_NAME" >&2
    return 2
  fi
  if [ ! -d "$TARGET_CWD" ]; then
    printf '%s: the target directory doesn'\''t exist: %s\n' "$SCRIPT_NAME" "$TARGET_CWD" >&2
    return 2
  fi
  # A directory can exist but still fail to resolve (no permission to cd into it, an ancestor
  # that can't be traversed), so the resolution failure is checked. Skipping the check would let
  # the assignment run first and leave TARGET_CWD empty, turning the failure reason into
  # something else entirely (observed: the records location resolves to `/.rein/`, producing
  # "there is no current pointer: /.rein/current.json") -- on top of leaking bash's raw error
  # line into user-facing output.
  # The reason is captured from cd's stderr and folded into this script's own one line (same
  # resolution, same wording, as rein-request.sh).
  resolved_cwd="$(cd "$TARGET_CWD" 2>/dev/null && pwd -P)"
  if [ -z "$resolved_cwd" ]; then
    # This branch is **expected to fail** (it's only here to capture the reason text), so its
    # exit code is ignored.
    cwd_error="$(cd "$TARGET_CWD" 2>&1 || :)"
    # Strip bash's own prefix (`<script>: line <n>: cd: `) and keep only the reason.
    case "$cwd_error" in
      *": cd: "*) cwd_error="${cwd_error##*": cd: "}" ;;
    esac
    printf '%s: cannot resolve the target directory: %s\n' "$SCRIPT_NAME" "${cwd_error:-$TARGET_CWD}" >&2
    return 2
  fi
  TARGET_CWD="$resolved_cwd"

  validate_runtime
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

  load_config
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

  # Called **outside `$( )`** so a rejection can be told apart from success. Received through
  # `$( )` the two are the same empty string, and the pointer and the seat log below would become
  # `/current.json` / `/seat.log` -- the seat would read the filesystem root as its lineage and
  # sit down on it. The reason is carried out through REIN_RECORDS_ERROR, and re-emitted through
  # this script's own startup rejection (the resolver's stderr line is suppressed so the user gets
  # one line, not two).
  if ! rein_records_dir "$TARGET_CWD" >/dev/null 2>&1; then
    startup_reject "${REIN_RECORDS_ERROR:-cannot resolve the lineage records location}"
    return 2
  fi
  RECORDS_DIR="$REIN_RECORDS_PATH"
  # Gate that only fires for a selftest's own child; dies here the instant isolation slips.
  # **The same predicate, the same placement**, as rein-hook.sh's hook_prepare and
  # lib/cli/base.sh's prepare_runtime. load_config has resolved the runtime directory and the
  # line right above has resolved the records location -- this sits right after both are known
  # and before a single byte has been written. The seat only ever writes to two places, the seat
  # lock (runtime directory) and the seat log (records), and both are derived from these same two
  # variables, so this one spot covers them even if more writers are added later.
  # **This isn't split into stages because no write path exists before this point** -- startup
  # rejection (startup_reject) only writes stderr and a GUI notification, owner verification is
  # read-only, and seat_log returns early on the leading `[ -n ... ]` while RECORDS_DIR is still
  # empty (the watcher needs two such gates only because its failure paths ahead of the records
  # branch write to wlog).
  # The rejection here goes straight to stderr, bypassing startup_reject (which would also ring a
  # GUI notification).
  if [ -n "${REIN_SELFTEST_NEVER_ROOTS:-}" ] &&
    rein_selftest_never_root_hit "$RUNTIME_DIR" "$RECORDS_DIR"; then
    printf '%s: a selftest child resolved a location it must never touch (isolation has slipped): %s\n' \
      "$SCRIPT_NAME" "$REIN_SELFTEST_NEVER_ROOT_HIT" >&2
    return 2
  fi
  POINTER_FILE="$RECORDS_DIR/$REIN_POINTER_BASENAME"
  # Records live at the lineage's records location (same resolution as the handover log -- for a
  # `--root` lineage, this leans toward the root side).
  SEAT_LOG_FILE="$RECORDS_DIR/$REIN_SEAT_LOG_BASENAME"
  HEARTBEAT_FILE="$RUNTIME_DIR/$REIN_HEARTBEAT_BASENAME"
  SEAT_STOP_FILE="$RUNTIME_DIR/$REIN_SEAT_STOP_BASENAME"

  if ! rein_open_error_sink; then
    printf '%s: cannot create a temp file to capture output from external commands\n' "$SCRIPT_NAME" >&2
    return 2
  fi
  # Cleanup hangs off EXIT only. INT / TERM / HUP are deliberately not trapped separately -- **a
  # measured choice**: (1) bash runs an EXIT trap even before dying from a signal, if one is set, so
  # cleanup already gets there; (2) an explicit trap would delay signal handling until "the
  # foreground child currently running (`claude attach`) returns" -- a TERM / HUP sent to a seat
  # mid-attach wouldn't take effect until the user finished their work (observed: no explicit trap
  # acts immediately; adding one waits for the child to exit).
  trap seat_cleanup EXIT

  # Checks whether the lineage exists (whether the current pointer can be read) **before creating
  # anything**. Provisioning the seat lock (claim_seat_lock -> rein_ensure_runtime_dir) creates
  # the runtime directory and the owner file, so doing that first would leave the location behind
  # even on an immediate failure -- one mistyped cwd would grow runtime data in a directory with
  # no lineage at all. Once this check passes, the location already exists (the pointer is
  # present at the records location), so any later failure can still be recorded.
  read_pointer_session_id >/dev/null
  rc=$?
  if [ "$rc" -ne 0 ]; then
    seat_fail "$(pointer_error_reason "$rc")"
    return 1
  fi

  # A lineage has one seat. This claims it **before entering attach** (claiming after entry would
  # mean fighting over the terminal).
  claim_seat_lock
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  clear_stale_seat_stop || return 2
  # **The moment a new seat exists is itself a record.** The log outlives the process that wrote
  # it, so without this line a seat that has just sat down and not yet entered attach leaves the
  # previous seat's `attach_started` as the newest life-cycle line -- and a reader taking "the
  # last one" would name a session this seat has never been near, from an occupancy that may have
  # ended days ago. Written after the lock is claimed, so a run that never got the seat never
  # claims to have taken one.
  seat_log "$REIN_SEAT_EVENT_SEATED" "a seat has sat down (it has not entered attach yet)"

  while :; do
    session_id="$(read_pointer_session_id)"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      seat_fail "$(pointer_error_reason "$rc")"
      return 1
    fi

    # What's passed to attach is the short job ID resolved from enumeration. The pointer still
    # holds the full session_id (the contract keeps the full ID; the CLI takes the short one), so
    # this resolves it right before attach.
    attach_handle="$(rein_resolve_job_handle "$session_id")"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      # The marker is what tells the seat whether resolution failed because of a stop the user
      # triggered. `rein down` drops the marker **before** externally stopping the primary session,
      # so a seat that sat down again inside the window between the marker being dropped and the
      # stop taking effect fails to resolve the primary session once that stop lands (by then it
      # has dropped out of the live enumeration -- `claude agents --json` without `--all` lists
      # only live elements) and rings it as a failure -- with no difference at all in exit code,
      # wording, or notification between the marker being present and not (material that could
      # distinguish the two existed but went unused). So the marker is checked before ringing this
      # as a failure.
      if seat_stop_mark_present; then
        consume_seat_stop_mark
        return $?
      fi
      seat_fail "$(rein_job_handle_error "$session_id" "$rc")"
      return 1
    fi

    printf '%s: attaching to %s\n' "$SCRIPT_NAME" "$session_id"
    # The record is written **before** entering attach. `claude attach` doesn't return until the
    # user leaves, so writing it only after return would leave the entire attached period looking
    # like "nothing happened."
    seat_log "$REIN_SEAT_EVENT_ATTACH_STARTED" "attaching to session $session_id" "$session_id"
    WATCHDOG_SENTINEL="$(mktemp "${TMPDIR:-/tmp}/rein-seat-attach.XXXXXX")"
    if [ -z "$WATCHDOG_SENTINEL" ]; then
      seat_fail "cannot create the watchdog's temp file (cannot detect a stall during attach)"
      return 1
    fi
    # The watchdog's output goes to the user's terminal only after attach returns (the terminal is
    # occupied by a TUI during attach, and injecting a line into it there would corrupt the
    # display). The GUI notification, though, fires immediately.
    # **The parent writes nothing to the seat log for as long as this child lives.** From the line
    # below it is blocked in the foreground on attach, and it does not write its own closing
    # record until the child has been reaped a few lines further down -- so the two never append
    # to that file at the same time, which is what keeps "one writer per file" true now that the
    # writer is a parent and a child rather than a single process.
    # The parent's identity is captured before the fork so the child can tell "my parent is still
    # there" from "something else now holds that pid."
    watchdog_parent_start="$(rein_process_start_identity "$$")"
    run_attach_watchdog "$session_id" "$WATCHDOG_SENTINEL" "$$" "$watchdog_parent_start" \
      "$(watchdog_limit_sec)" "$(watchdog_repeat_sec)" \
      >>"${WATCHDOG_SENTINEL}.log" 2>&1 & # record-append-exempt: the destination sits next to this run's own mktemp temp file (not the lineage's records location), not somewhere a clone can bundle in
    WATCHDOG_PID=$!
    # attach alone is never wrapped in a cap (never returning while the user is sitting there is the
    # normal state, and cutting it off on a timer would take the seat out from under them mid-work).
    # Caps only apply to the unattended enumeration, launch, and stop calls.
    (cd "$TARGET_CWD" && claude attach "$attach_handle") # run-limit-exempt: attach normally never returns while the user is sitting there, and cutting it off on a timer would take the seat out from under them mid-work (caps only apply to the unattended enumeration, launch, and stop calls)
    attach_rc=$?
    rm -f "$WATCHDOG_SENTINEL"
    # The watchdog ends on its own once its sentinel disappears (within one poll). This waits for
    # it to finish before reading its log -- reading and removing first would risk a half-written
    # reason line landing on an already-unlinked inode, silently losing the one line meant for
    # the terminal.
    if [ -n "$WATCHDOG_PID" ]; then
      wait "$WATCHDOG_PID" 2>/dev/null
      WATCHDOG_PID=""
    fi
    if [ -s "${WATCHDOG_SENTINEL}.log" ]; then
      cat "${WATCHDOG_SENTINEL}.log" >&2
    fi
    rm -f "${WATCHDOG_SENTINEL}.log"
    WATCHDOG_SENTINEL=""
    # **The closing half of the pair.** Written here, before any of the branches below can return,
    # so that every way out of an attach leaves the same mark: from this line until the next
    # `attach_started`, the seat is connected to nothing. Without it a reader has only "where the
    # seat last went" and has to present that as "where the seat is" -- which reads as a healthy,
    # in-step connection through the whole of an ordinary wait for a handover, a state with no
    # time limit on it at all.
    seat_log "$REIN_SEAT_EVENT_ATTACH_ENDED" \
      "attach returned (rc=${attach_rc}) from session ${session_id}; the seat is not connected to anything until the next attach" \
      "$session_id"

    # If the marker for shutting the lineage down is present, this attach return was triggered on
    # purpose by `rein down`. This is checked before the pointer check -- on a round where the
    # marker is present, both the pointer and the primary session are already gone, so checking
    # it later would mean stepping down only after ringing the "ended but the pointer wasn't
    # updated" notification.
    if seat_stop_mark_present; then
      consume_seat_stop_mark
      return $?
    fi

    next_id="$(read_pointer_session_id)"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      seat_fail "$(pointer_error_reason "$rc")"
      return 1
    fi

    # Treating attach's non-zero exit the same as "the user stepped away" would display "waiting for
    # a handover" even though attach isn't actually working, indistinguishable from a normal wait as
    # far as the user can tell.
    if [ "$attach_rc" -ne 0 ]; then
      printf '%s: claude attach returned non-zero (%s): %s\n' "$SCRIPT_NAME" "$attach_rc" "$attach_handle" >&2
      seat_log attach_failed \
        "claude attach returned non-zero (rc=${attach_rc}) after ${attach_retry} retries: ${attach_handle}" \
        "$session_id"
      if [ "$next_id" != "$session_id" ]; then
        attach_retry=0
        continue
      fi
      rein_is_session_live "$session_id"
      rc=$?
      if [ "$rc" -ne 0 ] || [ "$attach_retry" -ge "$ATTACH_RETRY_MAX" ]; then
        printf -v SEAT_WAIT_REASON 'claude attach failed (rc=%s, %s attempts): %s' \
          "$attach_rc" "$((attach_retry + 1))" "$session_id"
        seat_fail "$SEAT_WAIT_REASON"
        return 1
      fi
      attach_retry=$((attach_retry + 1))
      sleep "$POLL_INTERVAL_SEC"
      continue
    fi
    attach_retry=0
    attach_count=$((attach_count + 1))
    # attach succeeded -- the wait cycle just before it has ended. The heartbeat warning's
    # contract is "at most once per wait," so it's reset here, at the end of that cycle. Not
    # resetting it would effectively make it "at most once per process lifetime," going silent on
    # the watcher's stopping for longer and longer stretches (the second wait onward) the longer
    # this loop keeps re-attaching across handovers. The consecutive-absence count is reset here
    # for the same reason (giving up rests on "absent for consecutive rounds within one wait" --
    # a count from a previous wait never carries over into the next one).
    HEARTBEAT_WARNED=0
    WATCHER_ABSENT_STREAK=0
    WATCHER_ABSENT_DETAIL=""

    if [ "$MAX_ATTACH" -gt 0 ] && [ "$attach_count" -ge "$MAX_ATTACH" ]; then
      return 0
    fi

    if [ "$next_id" != "$session_id" ]; then
      continue
    fi

    # attach returned with the pointer unchanged -- either the user stepped away, or the target
    # died. The former means waiting for a handover is correct; the latter means waiting will never
    # bring it back, so these are handled separately.
    rein_is_session_live "$session_id"
    rc=$?
    if [ "$rc" -eq 1 ]; then
      printf -v SEAT_WAIT_REASON 'session %s ended, but the current pointer was never updated' "$session_id"
      seat_fail "$SEAT_WAIT_REASON"
      return 1
    fi
    if [ "$rc" -eq 2 ]; then
      printf -v SEAT_WAIT_REASON '%s (cannot determine whether the session is alive)' "$(rein_list_agents_error)"
      seat_fail "$SEAT_WAIT_REASON"
      return 1
    fi

    printf '%s: waiting for a handover (Ctrl-C to stop)\n' "$SCRIPT_NAME"
    wait_for_pointer_change "$session_id"
    rc=$?
    if [ "$rc" -eq 2 ]; then
      consume_seat_stop_mark
      return $?
    fi
    if [ "$rc" -ne 0 ]; then
      seat_fail "$SEAT_WAIT_REASON"
      return 1
    fi
  done
}

st_pass_count=0
st_fail_count=0

# Section table (listed in run order); what the layer names mean lives at the top of
# lib/rein-selftest-sections.sh. Both of the seat's sections spawn a real process (a
# cooperatively-terminating holder, the fake CLI, the attach loop), so both are the proc layer.
rein_st_section_table() {
  cat <<'EOF'
proc:safe st_section_safe
proc:seat st_section_seat
EOF
}

st_ok() {
  st_pass_count=$((st_pass_count + 1))
}

st_fail() {
  st_fail_count=$((st_fail_count + 1))
  printf '  FAIL %s: %s\n' "$1" "$2"
}

st_cleanup() {
  local original_status=$? cleanup_status=0
  # Returning from the EXIT trap would still leave the exit 0 from before the trap as the final
  # status. This blocks re-entry, then exits explicitly so a cleanup failure reaches the final
  # non-zero.
  trap - EXIT
  if type rein_st_stop_all_cooperative_holders >/dev/null 2>&1; then
    if ! rein_st_stop_all_cooperative_holders; then
      cleanup_status=1
      printf '  FAIL selftest cleanup: could not wait for a cooperative holder to exit on its own (evidence: %s)\n' \
        "${ST_TMPDIR:-unknown}" >&2
    fi
  fi
  if [ "$cleanup_status" -ne 0 ]; then
    exit 1
  fi
  if [ -n "${ST_TMPDIR:-}" ] && { ! rm -rf "$ST_TMPDIR" || [ -e "$ST_TMPDIR" ]; }; then
    printf '  FAIL selftest cleanup: could not remove the temp directory (evidence: %s)\n' \
      "$ST_TMPDIR" >&2
    exit 1
  fi
  exit "$original_status"
}

st_setup_case() {
  local case_dir="$1"
  mkdir -p "$case_dir"
  ST_CWD="$(cd "$case_dir" && pwd -P)"
  # The default for runtime data is the user's state area, so a selftest must always point somewhere
  # isolated. The default here goes through --runtime-dir; only the cases exercising the
  # environment-variable path override these two.
  ST_RUNTIME="$ST_CWD/runtime"
  ST_RUNTIME_ARGS=(--runtime-dir "$ST_RUNTIME")
  ST_RUNTIME_ENV=""
  mkdir -p "$ST_RUNTIME"
  # The lineage's records (the current pointer) live on the project side. cwd is a per-case temp
  # directory, so this is isolated too.
  ST_RECORDS="$ST_CWD/$REIN_RECORDS_DIRNAME"
  mkdir -p "$ST_RECORDS"
  ST_POINTER="$ST_RECORDS/$REIN_POINTER_BASENAME"
  ST_SEAT_LOG="$ST_RECORDS/$REIN_SEAT_LOG_BASENAME"
  # Now that this reads the config layer, a selftest must always point at an isolated config too.
  ST_USER_CONFIG="$ST_CWD/user-config"
  # Isolation is assembled in one place in the fixtures rather than duplicated per entry point --
  # even one leftover path that fails to unset the surrounding REIN_* variables would let the user's
  # real config sway the selftest's outcome.
  rein_st_isolation_env "$ST_USER_CONFIG" "$ST_CWD/xdg-config" "$ST_CWD/xdg"
  ST_ENV_ARGS=("${REIN_ST_ENV_ARGS[@]}")
  ST_AGENTS="$ST_CWD/agents.json"
  ST_LOG="$ST_CWD/claude-args.log"
  ST_NOTIFY="$ST_CWD/notify.log"
  : >"$ST_LOG"
  : >"$ST_NOTIFY"
  rein_st_write_agents "$ST_AGENTS" "$ST_CWD" "seat-1"
}

# There are two entry points (one in the foreground to receive the result, and one backgrounded
# so a signal can be sent). Env assembly lives in one place -- duplicating it per entry point
# would risk one of them dropping isolation and reading the real config.
ST_SEAT_ENV_ARGS=()
st_seat_env_args() {
  # Environment variables are either passed or not passed, never passed empty (the config layer
  # reads an explicit empty as "disabled at this layer," so always passing an empty string would
  # keep a config-file value from ever reaching it).
  ST_SEAT_ENV_ARGS=(
    "${ST_ENV_ARGS[@]}"
    "PATH=${ST_BROKEN_BIN:+$ST_BROKEN_BIN:}$ST_BIN:$PATH"
    "FAKE_LOG=$ST_LOG"
    "FAKE_NOTIFY_LOG=$ST_NOTIFY"
    "FAKE_AGENTS=$ST_AGENTS"
    "FAKE_ATTACH_CP_SRC=${ST_ATTACH_CP_SRC:-}"
    "FAKE_ATTACH_CP_DST=${ST_ATTACH_CP_DST:-}"
    "FAKE_ATTACH_EXIT=${ST_ATTACH_EXIT:-0}"
    "FAKE_ATTACH_SLEEP_SEC=${ST_ATTACH_SLEEP:-}"
    "FAKE_AGENTS_FAIL=${ST_AGENTS_FAIL:-0}"
    "FAKE_AGENTS_FAIL_ONCE_AT=${ST_AGENTS_FAIL_ONCE_AT:-}"
    # Length of one round. The default is 0.2 seconds to keep selftest fast, but cases that
    # **make something happen mid-wait** (swapping the pointer, dropping a marker, adding or
    # removing a heartbeat) run it longer -- a wait for an absent watcher ends after
    # WATCHER_ABSENT_LIMIT rounds, so slipping the event in needs a full round's worth of room.
    "REIN_POLL_INTERVAL_SEC=${ST_POLL_INTERVAL:-0.2}"
    "REIN_SEAT_WAIT_TIMEOUT_SEC=${ST_WAIT_TIMEOUT:-1}"
    "REIN_SEAT_ATTACH_RETRY_MAX=${ST_ATTACH_RETRY_MAX:-3}"
    "REIN_SEAT_HEARTBEAT_MAX_AGE_SEC=${ST_HEARTBEAT_MAX_AGE:-60}"
    "REIN_EXIT_GRACE_SEC=${ST_EXIT_GRACE:-15}"
    "REIN_STOP_TIMEOUT_SEC=${ST_STOP_TIMEOUT:-60}"
    "REIN_CMD_TIMEOUT_SEC=${ST_CMD_TIMEOUT:-60}"
  )
  if [ -n "${ST_RUNTIME_ENV:-}" ]; then
    ST_SEAT_ENV_ARGS+=("REIN_RUNTIME_DIR=$ST_RUNTIME_ENV")
  fi
}

st_run_seat() {
  st_seat_env_args
  ST_OUT="$(env "${ST_SEAT_ENV_ARGS[@]}" \
    "$REIN_ST_BASH" "$SCRIPT_PATH" --cwd "$ST_CWD" ${ST_RUNTIME_ARGS[@]+"${ST_RUNTIME_ARGS[@]}"} \
    --max-attach "${ST_MAX_ATTACH:-1}" 2>&1 </dev/null)"
  ST_STATUS=$?
}

# The backgrounded entry point (for tests that send a signal). `env` replaces itself with bash,
# so `$!` becomes the seat process's own pid -- the signal sent never gets absorbed by an
# intermediate shell.
ST_SEAT_BG_PID=""
st_run_seat_bg() {
  local out="$1"
  st_seat_env_args
  env "${ST_SEAT_ENV_ARGS[@]}" \
    "$REIN_ST_BASH" "$SCRIPT_PATH" --cwd "$ST_CWD" ${ST_RUNTIME_ARGS[@]+"${ST_RUNTIME_ARGS[@]}"} \
    --max-attach "${ST_MAX_ATTACH:-1}" >"$out" 2>&1 </dev/null &
  ST_SEAT_BG_PID=$!
}

# Waits for the seat lock to be published (sending the signal before it sits down would read a
# round that never cleaned anything up as "cleanup succeeded"). 0=appeared / 1=never appeared
st_wait_for_seat_lock() {
  local i=0
  while [ "$i" -lt 100 ]; do
    [ -d "$ST_RUNTIME/$REIN_SEAT_LOCK_DIRNAME" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# Shared check for the forms that fail at startup (missing prerequisite, bad setting): never
# calls attach, notifies, and ends non-zero. A call with an empty expected string **always
# matches** (`*""*` matches any string) -- banking a pass without looking at the output at all.
# Calls that pass the whole needle through a variable really exist, so a mistyped variable name
# there would turn green. An empty needle is treated as a broken test and fails.
st_expect_startup_reject() {
  local name="$1" needle="$2"
  if [ -z "$needle" ]; then
    st_fail "${name}" "the expected string is empty (a broken test: it would pass without ever looking at the output)"
    return
  fi
  if ! st_expect_status "${name}" 2; then
    return
  fi
  case "$ST_OUT" in
    *"$needle"*) ;;
    *)
      st_fail "${name}" "the reason doesn't mention ${needle}: ${ST_OUT}"
      return
      ;;
  esac
  if [ -s "$ST_LOG" ]; then
    st_fail "${name}" "should have failed before startup, but called claude: $(cat "$ST_LOG")"
    return
  fi
  st_expect_notify "${name}" "rein: cannot start the attach loop" "$needle" || return
  st_ok
}

st_expect_status() {
  local name="$1" expected="$2"
  if [ "$ST_STATUS" -ne "$expected" ]; then
    st_fail "${name}" "exit=${ST_STATUS} (expected ${expected}): ${ST_OUT}"
    return 1
  fi
  return 0
}

# A `date` shim that moves the clock (placed at the front of PATH). It only moves what
# `rein_now_epoch` uses (`-u +%s`); every other invocation (a contract timestamp, an epoch ->
# string conversion) passes straight through to the real binary -- what's being measured is only
# whether the read of the current time drives the deadline, and breaking time conversion too
# would make it impossible to tell that failure apart from a failure for some other reason.
# It advances by an hour on every call (skipping just once would make the result depend on
# whether the skip landed before or after the deadline arithmetic, and a case that lands on the
# wrong side of that would falsely pass even with a clock that never moved).
# This isn't added to the shared fixtures -- only this test uses it, so it lives on the selftest
# side that uses it.
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

st_expect_true() {
  local name="$1"
  shift
  if "$@"; then
    st_ok
  else
    st_fail "${name}" "condition failed: $*"
  fi
}

# Checks a notification verbatim. The title must match exactly, and the message must contain the
# given text ("the notification file isn't empty" alone would let a garbled recipient or reason
# through). A call with an empty expected string **always matches** (`*""*` matches any string)
# -- banking a pass without looking at the output at all. Calls that pass the whole needle
# through a variable really exist, so a mistyped variable name there would turn green. An empty
# needle is treated as a broken test and fails.
st_expect_notify() {
  local name="$1" title="$2" needle="$3" count got_title got_message
  if [ -z "$needle" ]; then
    st_fail "${name}" "the expected string is empty (a broken test: it would pass without ever looking at the output)"
    return 1
  fi
  count="$(rein_st_calls_total "$ST_NOTIFY")"
  if [ "$count" -eq 0 ]; then
    st_fail "${name}" "no notification fired"
    return 1
  fi
  got_title="$(rein_st_notify_field "$ST_NOTIFY" "$count" title)"
  got_message="$(rein_st_notify_field "$ST_NOTIFY" "$count" message)"
  if [ "$got_title" != "$title" ]; then
    st_fail "${name}" "the notification title differs: expected=${title} actual=${got_title}"
    return 1
  fi
  case "$got_message" in
    *"$needle"*) ;;
    *)
      st_fail "${name}" "the notification body is missing ${needle}: ${got_message}"
      return 1
      ;;
  esac
  return 0
}

# Counts the notifications whose body contains the given text. Used for checks that care not
# just whether a notification fired but how many times ("at most once per wait" can only be
# pinned down on one side without a count).
st_count_notify() {
  local needle="$1" total i=1 count=0 message
  # An empty needle matches every body, returning the total notification count -- a check that
  # cares about a count could then match some unrelated notification against its expected value.
  # This returns -1 instead, which matches no expected value, so the caller fails
  # (this function only ever returns a count, so calling st_fail here would double-count).
  if [ -z "$needle" ]; then
    printf '%s\n' "-1"
    return
  fi
  total="$(rein_st_calls_total "$ST_NOTIFY")"
  while [ "$i" -le "$total" ]; do
    message="$(rein_st_notify_field "$ST_NOTIFY" "$i" message)"
    case "$message" in
      *"$needle"*) count=$((count + 1)) ;;
    esac
    i=$((i + 1))
  done
  printf '%s\n' "$count"
}

# Calls the watchdog's threshold (watchdog_limit_sec) **as it's actually implemented** to pin
# down the composition. The cases that fire it in real time can only run with the minimum config
# (681 seconds by default would take too long), so the default value's composition is checked
# here instead. The three settings are global (set by the config layer), so they're saved and
# restored around the call.
st_expect_watchdog_limit() {
  local name="$1" grace="$2" cmd="$3" stop="$4" expected="$5"
  local saved_grace="$EXIT_GRACE_SEC" saved_cmd="$CMD_TIMEOUT_SEC" saved_stop="$STOP_TIMEOUT_SEC"
  local actual
  EXIT_GRACE_SEC="$grace"
  CMD_TIMEOUT_SEC="$cmd"
  STOP_TIMEOUT_SEC="$stop"
  actual="$(watchdog_limit_sec)"
  EXIT_GRACE_SEC="$saved_grace"
  CMD_TIMEOUT_SEC="$saved_cmd"
  STOP_TIMEOUT_SEC="$saved_stop"
  if [ "$actual" = "$expected" ]; then
    st_ok
  else
    st_fail "${name}" "the watchdog threshold is not ${expected} seconds: ${actual} (grace ${grace} / cap ${cmd} / stop confirmation ${stop})"
  fi
}

# The same for the repeat spacing (watchdog_repeat_sec), which is **not** the threshold. The
# real-time cases cannot see the spacing at all any more -- its floor is minutes, deliberately --
# so it is pinned here, at both bounds and in between: the settings that used to produce four
# notifications a minute and the ones that used to produce one every 51 or 101 minutes both land
# inside a range a person can live with, while the default is left where it was.
st_expect_watchdog_repeat() {
  local name="$1" grace="$2" cmd="$3" stop="$4" expected="$5"
  local saved_grace="$EXIT_GRACE_SEC" saved_cmd="$CMD_TIMEOUT_SEC" saved_stop="$STOP_TIMEOUT_SEC"
  local actual
  EXIT_GRACE_SEC="$grace"
  CMD_TIMEOUT_SEC="$cmd"
  STOP_TIMEOUT_SEC="$stop"
  actual="$(watchdog_repeat_sec)"
  EXIT_GRACE_SEC="$saved_grace"
  CMD_TIMEOUT_SEC="$saved_cmd"
  STOP_TIMEOUT_SEC="$saved_stop"
  if [ "$actual" = "$expected" ]; then
    st_ok
  else
    st_fail "${name}" "the repeat spacing is not ${expected} seconds: ${actual} (grace ${grace} / cap ${cmd} / stop confirmation ${stop})"
  fi
}

# The threshold assumes a certain number of steps that run an enumeration
# (REIN_RETIRE_LIST_AGENTS_CALLS), which is exactly how many steps the watcher's
# retire_predecessor runs through serially. That structure lives in another file the seat side
# can't see, so this **recounts it and cross-checks** -- if the step count ever grows, the seat's
# threshold silently falling short is not an option. What's counted is any call that runs an
# enumeration internally (wait_for_exit and rein_resolve_job_handle).
st_expect_retire_list_calls() {
  local watcher="$SCRIPT_DIR/rein-watcher.sh" line inside=0 seen=0 counted=0
  if [ ! -f "$watcher" ]; then
    st_fail "count retire's steps" "cannot find the watcher's real file: ${watcher}"
    return
  fi
  while IFS= read -r line; do
    if [ "$inside" -eq 0 ]; then
      case "$line" in
        'retire_predecessor() {')
          inside=1
          seen=1
          ;;
      esac
      continue
    fi
    case "$line" in
      '}') break ;;
      '  wait_for_exit '*) counted=$((counted + 1)) ;;
      *"=\"\$(rein_resolve_job_handle "*) counted=$((counted + 1)) ;;
    esac
  done <"$watcher"
  if [ "$seen" -eq 0 ]; then
    st_fail "count retire's steps" "cannot extract retire_predecessor's body: ${watcher}"
    return
  fi
  if [ "$counted" = "$REIN_RETIRE_LIST_AGENTS_CALLS" ]; then
    st_ok
  else
    st_fail "count retire's steps" \
      "retire_predecessor runs an enumeration in ${counted} steps, which does not match the ${REIN_RETIRE_LIST_AGENTS_CALLS} the threshold assumes"
  fi
}

# Drops a file (backgrounded) once a given notification is seen to have fired. It's dropped in
# one of two places, the pointer or runtime data (a way to make something happen mid-wait); what
# it watches is the same store st_count_notify reads. Swapping it in on a real-time sleep would
# let a load-delayed seat startup switch to the successor before "the pointer re-read right after
# attach returns" gets a chance -- the seat re-attaches immediately without ever entering the
# wait, so the wait only happens once, and the test fails for reasons unrelated to what it's
# actually checking. The cap is set longer than the caller's own wait cap -- a round that hits the
# cap means the seat has already given up on the wait, so dropping the file wouldn't trigger an
# attach to the successor either way, and the test fails visibly (never passes silently).
st_copy_after_notify() {
  local needle="$1" src="$2" dst="$3" limit_sec="$4"
  local polls=0 max_polls
  max_polls="$((limit_sec * 20))"
  while [ "$(st_count_notify "$needle")" -lt 1 ]; do
    if [ "$polls" -ge "$max_polls" ]; then
      break
    fi
    sleep 0.05
    polls=$((polls + 1))
  done
  # Dropped in one atomic move via rename. Writing straight over it with `cp` would open a window
  # where the reader (the seat's poll) reads a half-written file, falling into the "broken"
  # branch for reasons unrelated to what's actually being tested.
  cp "$src" "${dst}.st-partial" && mv "${dst}.st-partial" "$dst"
}

# The gauge for how many rounds the wait loop has run. The fake CLI counts its own `agents`
# calls, and the wait enumerates exactly once per round, so this count is the only externally
# visible gauge of round number (the startup liveness check and the attach-return liveness check
# both run before the wait, advancing it by 2, so the end of wait round k is 2+k).
# 0=reached / 1=never reached the target within the cap (the seat has already stepped down)
st_wait_for_agents_calls() {
  local want="$1" limit_sec="$2" polls=0 max_polls count
  max_polls="$((limit_sec * 20))"
  while :; do
    count=0
    [ -f "$ST_LOG.agents" ] && count="$(cat "$ST_LOG.agents")"
    case "$count" in
      '' | *[!0-9]*) count=0 ;;
    esac
    [ "$count" -ge "$want" ] && return 0
    [ "$polls" -ge "$max_polls" ] && return 1
    sleep 0.05
    polls=$((polls + 1))
  done
}

# Drops and then removes a heartbeat partway through a wait (backgrounded -- a way to create a
# transient absence). This times itself to the round gauge above, not real time -- aiming for "on
# which round" via a real-time sleep would let a load-shifted round land the event on the wrong
# round, and the test would fail for reasons unrelated to what's actually being tested.
st_heartbeat_between_calls() {
  local put_at="$1" rm_at="$2" limit_sec="$3"
  local file="$ST_RUNTIME/$REIN_HEARTBEAT_BASENAME"
  st_wait_for_agents_calls "$put_at" "$limit_sec" || return 0
  : >"$file"
  st_wait_for_agents_calls "$rm_at" "$limit_sec" || return 0
  rm -f "$file"
}

# Drops a file on the same gauge (backgrounded). The only difference from st_copy_after_notify is
# what it waits on -- use this one when what matters is **which round** of the wait it should
# happen on.
st_copy_after_calls() {
  local at="$1" src="$2" dst="$3" limit_sec="$4"
  st_wait_for_agents_calls "$at" "$limit_sec" || return 0
  # Dropped in one atomic move via rename (never let a half-written file be read -- same reason
  # as st_copy_after_notify).
  cp "$src" "${dst}.st-partial" && mv "${dst}.st-partial" "$dst"
}

# Waits for the backgrounded seat to exit on its own (a way to measure the side that gives up on
# an unlimited wait). Cutting it off on real time would let a broken implementation that never
# steps down pass anyway, so this returns via its exit status whether it ever stepped down at all.
# 0=exited on its own / 1=still alive at the cap (the caller kills it and stops)
st_wait_for_pid_exit() {
  local pid="$1" limit_sec="$2" polls=0 max_polls
  max_polls="$((limit_sec * 10))"
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$polls" -ge "$max_polls" ]; then
      return 1
    fi
    sleep 0.1
    polls=$((polls + 1))
  done
  return 0
}

# Checks the entry point for a value-taking flag (a reason, then exit 2). This fails at a stage
# before either the config layer or startup itself is touched, so it launches directly without
# passing the isolation env (same footing as st_usage_case). An empty expected string **always
# matches** (`*""*` matches any string), so this fails on that.
st_missing_value_case() {
  local name="$1" needle="$2"
  shift 2
  local out status
  if [ -z "$needle" ]; then
    st_fail "${name}" "the expected string is empty (a broken test: it would pass without ever looking at the output)"
    return
  fi
  out="$("$REIN_ST_BASH" "$SCRIPT_PATH" "$@" 2>&1 </dev/null)"
  status=$?
  if [ "$status" -ne 2 ]; then
    st_fail "${name}" "exit=${status} (expected 2): ${out}"
    return
  fi
  case "$out" in
    *"$needle"*) ;;
    *)
      st_fail "${name}" "the reason doesn't mention ${needle}: ${out}"
      return
      ;;
  esac
  st_ok
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
      st_fail "${name}" "usage was not printed: ${out}"
      return
      ;;
  esac
  case "$out" in
    *"unbound variable"* | *"command not found"*)
      st_fail "${name}" "a runtime error leaked in: ${out}"
      return
      ;;
  esac
  st_ok
}

# Every shape of a bad pointer is expected to line up on the same three points: never call attach,
# notify with a reason, exit non-zero. The reason is checked verbatim, because if the user can't
# tell which check failed from the notification, there's nothing to act on.
st_expect_pointer_error() {
  local name="$1" needle="$2"
  if ! st_expect_status "${name}" 1; then
    return
  fi
  if [ "$(rein_st_count_sub "$ST_LOG" attach)" -ne 0 ]; then
    st_fail "${name}" "attached even though the pointer could not be read: $(cat "$ST_LOG")"
    return
  fi
  st_expect_notify "${name}" "rein: cannot keep the seat" "$needle" || return
  st_ok
}

# Checks the seat's own log: line count, event name, the gist of detail, and the column contract
# (schema and target session). What matters about a record is not that it exists but what it
# actually captured, so both event and detail are checked.
st_seat_log_events() {
  jq -r '.event' "$ST_SEAT_LOG" 2>/dev/null | tr '\n' ' '
}

# How many lines the seat log holds for one event. "It was recorded" and "it was recorded every
# time" are different properties, and only the count can tell a repeat apart from a single entry
# that happened to survive.
st_count_seat_log_event() {
  local event="$1" count
  count="$(jq -r --arg e "$event" 'select(.event == $e) | .event' "$ST_SEAT_LOG" 2>/dev/null | wc -l | tr -d ' ')"
  case "$count" in
    '' | *[!0-9]*) count=0 ;;
  esac
  printf '%s\n' "$count"
}

st_expect_seat_log_line() {
  local name="$1" event="$2" needle="$3" line
  if [ -z "$needle" ]; then
    st_fail "${name}" "the expected string is empty (a broken test: it would pass without ever looking at the output)"
    return 1
  fi
  line="$(jq -c --arg e "$event" 'select(.event == $e)' "$ST_SEAT_LOG" 2>/dev/null | tail -1)"
  if [ -z "$line" ]; then
    st_fail "${name}" "no line for ${event}: $(st_seat_log_events)"
    return 1
  fi
  if [ "$(printf '%s' "$line" | jq -r '.schema')" != "$REIN_SEAT_LOG_SCHEMA" ]; then
    st_fail "${name}" "the schema is not the seat's own: ${line}"
    return 1
  fi
  case "$(printf '%s' "$line" | jq -r '.detail')" in
    *"$needle"*) ;;
    *)
      st_fail "${name}" "detail is missing ${needle}: ${line}"
      return 1
      ;;
  esac
  st_ok
  return 0
}

st_cooperative_holder_lifecycle_case() {
  local holder_pid state_dir="$tmp/cooperative-holder"
  if rein_st_start_cooperative_holder "$state_dir"; then
    holder_pid="$REIN_ST_COOPERATIVE_HOLDER_PID"
    st_ok
  else
    holder_pid="${REIN_ST_COOPERATIVE_HOLDER_PID:-unknown}"
    st_fail "the process fixture becomes ready" "pid=${holder_pid}"
  fi
  if rein_st_stop_all_cooperative_holders && [ ! -e "$state_dir" ]; then
    st_ok
  else
    st_fail "the process fixture terminates cooperatively and leaves no temp state" \
      "pid=${holder_pid} state=${state_dir}"
  fi
}

st_cleanup_failure_case() {
  local evidence_root state_dir cleanup_out cleanup_status
  evidence_root="$tmp/cleanup-failure-evidence"
  state_dir="$evidence_root/holder-state"
  cleanup_out="$tmp/cleanup-failure.out"
  mkdir -p "$state_dir"
  printf 'body green\n' >"$state_dir/body-ok"
  (
    # shellcheck disable=SC2030  # The negative-side values are only ever passed into cleanup inside this subshell.
    local REIN_ST_COOPERATIVE_HOLDER_PID=99999999
    local REIN_ST_COOPERATIVE_HOLDER_STATE="$state_dir"
    ST_TMPDIR="$evidence_root"
    st_cleanup
  ) >"$cleanup_out" 2>&1
  cleanup_status=$?
  if [ "$cleanup_status" -eq 1 ]; then
    st_ok
  else
    st_fail "a cleanup failure with a green body still ends non-zero" \
      "exit=${cleanup_status}: $(cat "$cleanup_out")"
  fi
  if [ -f "$state_dir/body-ok" ]; then
    st_ok
  else
    st_fail "leaves the evidence root behind on a cleanup failure" "no evidence: $evidence_root"
  fi
  case "$(cat "$cleanup_out")" in
    *"FAIL selftest cleanup"*"evidence: ${evidence_root}"*) st_ok ;;
    *) st_fail "prints the cleanup failure's reason and evidence root" "$(cat "$cleanup_out")" ;;
  esac
}

st_seat_lock_busy_case() {
  local case_dir holder_pid holder_lock
  case_dir="$tmp/seat-lock-busy"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "successor" "$ST_CWD" 1
  holder_lock="$ST_RUNTIME/$REIN_SEAT_LOCK_DIRNAME"
  if rein_st_start_cooperative_holder "$ST_CWD/holder-state"; then
    # shellcheck disable=SC2031  # A value assigned inside cleanup's negative-side subshell never comes back to this shell.
    holder_pid="$REIN_ST_COOPERATIVE_HOLDER_PID"
    st_ok
  else
    # shellcheck disable=SC2031  # A value assigned inside cleanup's negative-side subshell never comes back to this shell.
    holder_pid="${REIN_ST_COOPERATIVE_HOLDER_PID:-$$}"
    st_fail "the seated fixture becomes ready" "pid=${holder_pid}"
  fi
  mkdir -p "$holder_lock"
  printf '%s\n' "$holder_pid" >"$holder_lock/pid"
  printf '%s\n' "$(rein_process_start_identity "$holder_pid")" >"$holder_lock/start"
  printf '%s\n' "$ST_CWD" >"$holder_lock/cwd"
  printf 'holder-token\n' >"$holder_lock/token"
  st_run_seat
  if st_expect_status "a second attach loop does not start while one is already seated" 1; then
    case "$ST_OUT" in
      *"already has an attach loop seated (pid=${holder_pid})"*) st_ok ;;
      *) st_fail "refuses, naming the seated pid" "$ST_OUT" ;;
    esac
  fi
  if [ -s "$ST_LOG" ]; then
    st_fail "does not attach on a round it refused" "$(cat "$ST_LOG")"
  else
    st_ok
  fi
  if [ "$(head -1 "$holder_lock/token" 2>/dev/null)" = "holder-token" ]; then
    st_ok
  else
    st_fail "never takes someone else's seat lock" "$(cat "$holder_lock/token" 2>/dev/null)"
  fi
  if rein_st_stop_all_cooperative_holders &&
    [ ! -e "$ST_CWD/holder-state" ]; then
    st_ok
  else
    st_fail "the seated fixture terminates cooperatively and leaves no temp state" \
      "pid=${holder_pid} state=$ST_CWD/holder-state"
  fi
}
# The gate for a location that must never be touched (where isolation slipping shows up). This
# fixes **both sides** with fixtures before exercising the predicate -- since every launch in
# this test already sits outside the never-touch root, checking only the side that never trips it
# would turn green whether the predicate is always false or has been removed altogether. The root
# passed is a temp directory -- not a single byte of real state is ever touched.
# This is not named `st_section_*` because that prefix only runs if registered in the section
# table.
st_never_root_case() {
  # The side that never trips it: a launch resolving its location outside the never-touch root
  # passes straight through to the normal attach.
  case_dir="$tmp/never-root-pass"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "successor" "$ST_CWD" 1
  ST_ENV_ARGS=("${ST_ENV_ARGS[@]}" "${REIN_SELFTEST_NEVER_ROOTS_ENV_NAME}=$tmp/never-root-unrelated")
  st_run_seat
  if st_expect_status "a launch that resolves its location outside the never-touch root passes through" 0; then
    if rein_st_has_call "$ST_LOG" attach job-seat-1; then
      st_ok
    else
      st_fail "a launch that passes through reaches attach" "$(cat "$ST_LOG")"
    fi
  fi

  # (1) The runtime-directory branch. The seat lock lives under it, so tripping this must create
  # not even one file there.
  case_dir="$tmp/never-root-runtime"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "successor" "$ST_CWD" 1
  ST_ENV_ARGS=("${ST_ENV_ARGS[@]}" "${REIN_SELFTEST_NEVER_ROOTS_ENV_NAME}=$ST_RUNTIME")
  st_run_seat
  if st_expect_status "a launch that resolves the runtime directory under the never-touch root fails" 2; then
    case "$ST_OUT" in
      *"${ST_RUNTIME} (never-touch root ${ST_RUNTIME})"*) st_ok ;;
      *) st_fail "names both the tripped location and the root in the failure reason" "$ST_OUT" ;;
    esac
  fi
  if [ ! -e "$ST_RUNTIME/$REIN_SEAT_LOCK_DIRNAME" ] && [ ! -s "$ST_LOG" ]; then
    st_ok
  else
    st_fail "a rejected launch neither claims the seat lock nor calls attach" \
      "lock=$(ls -a "$ST_RUNTIME" 2>&1) claude=$(cat "$ST_LOG")"
  fi

  # (2) The records branch. The runtime directory sits outside the never-touch root here, so
  # checking only that side would pass without ever exercising the records side.
  case_dir="$tmp/never-root-records"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "successor" "$ST_CWD" 1
  ST_ENV_ARGS=("${ST_ENV_ARGS[@]}" "${REIN_SELFTEST_NEVER_ROOTS_ENV_NAME}=$ST_RECORDS")
  st_run_seat
  if st_expect_status "a launch that resolves the records location under the never-touch root fails" 2; then
    case "$ST_OUT" in
      *"${ST_RECORDS} (never-touch root ${ST_RECORDS})"*) st_ok ;;
      *) st_fail "the records branch also names the tripped location" "$ST_OUT" ;;
    esac
  fi
  if [ ! -e "$ST_SEAT_LOG" ]; then
    st_ok
  else
    st_fail "a rejected launch writes not one file under the never-touch root" "the seat log exists: $(cat "$ST_SEAT_LOG")"
  fi
}

# The main section (attaching to the pointer's successor, and the contract around it). Its
# locals are shared with selftest() by dynamic scope, so their declarations stay in selftest()
# and are not moved here.
st_section_seat() {
  st_never_root_case

  # The accepting side: attach to whatever session the pointer names.
  case_dir="$tmp/attach"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "successor" "$ST_CWD" 1
  st_run_seat
  if st_expect_status "attach to whatever session the pointer names" 0; then
    # What's passed is the short job ID resolved from enumeration (the pointer's full session_id
    # passed as-is is refused by the real CLI). This checks the entire argv match (also catching
    # an extra argument tacked on, or the ID split across separate arguments).
    if rein_st_has_call "$ST_LOG" attach job-seat-1; then
      st_ok
    else
      st_fail "pass attach the short job ID resolved from enumeration" "$(cat "$ST_LOG")"
    fi
  fi

  # Cross-checks the fake CLI itself: it refuses a full session_id and accepts a short job ID
  # (backs up that the check above is not too loose).
  case_dir="$tmp/fake-cli-contract"
  st_setup_case "$case_dir"
  if FAKE_LOG="$ST_LOG" FAKE_AGENTS="$ST_AGENTS" "$ST_BIN/claude" attach seat-1 >/dev/null 2>&1; then
    st_fail "the fake CLI refuses attach with a full session_id" "it accepted a full session_id"
  elif ! FAKE_LOG="$ST_LOG" FAKE_AGENTS="$ST_AGENTS" "$ST_BIN/claude" attach job-seat-1 >/dev/null 2>&1; then
    st_fail "the fake CLI accepts attach with a short job ID" "it refused the short ID"
  else
    st_ok
  fi

  # The rejecting side: no pointer, a broken one, or one missing session_id.
  case_dir="$tmp/no-pointer"
  st_setup_case "$case_dir"
  st_run_seat
  st_expect_pointer_error "fails immediately when there is no pointer" "there is no current pointer"

  case_dir="$tmp/broken-pointer"
  st_setup_case "$case_dir"
  printf '{"schema":\n' >"$ST_POINTER"
  st_run_seat
  st_expect_pointer_error "fails immediately on a broken pointer" "broken JSON"

  # Firing attach in a directory with no lineage at all (a cwd that was never taken through
  # `rein up`) fails immediately, but that must **create neither records nor runtime data**.
  # One mistyped cwd has no business growing a `.rein/` in an unrelated working tree at all --
  # even though the shared path for writing one record line would drop a `.gitignore` there too
  # (seat_log's own comment above), the stray directory itself still doesn't belong in that
  # repository, and would sit there until the owner cleans it up by hand.
  case_dir="$tmp/no-lineage-no-leftovers"
  st_setup_case "$case_dir"
  rmdir "$ST_RECORDS"
  rmdir "$ST_RUNTIME"
  st_run_seat
  st_expect_pointer_error "fails immediately in a directory with no lineage" "there is no current pointer"
  st_expect_true "never creates the records location for a cwd with no lineage" test ! -e "$ST_RECORDS"
  st_expect_true "never creates the runtime directory for a cwd with no lineage" test ! -e "$ST_RUNTIME"

  # A cwd that exists but can't be resolved (no permission to cd into it). Skipping the
  # resolution-failure check would let the assignment run first and leave TARGET_CWD empty, turning
  # the failure reason into something else entirely (observed: the records location resolves to
  # `/.rein/`, producing "there is no current pointer: /.rein/current.json" -- sending the user off
  # to investigate an unrelated location) -- on top of leaking bash's raw error line into
  # user-facing output.
  local st_nox_parent
  case_dir="$tmp/unresolvable-cwd"
  st_setup_case "$case_dir"
  st_nox_parent="$ST_CWD"
  mkdir -p "$ST_CWD/nox"
  chmod 000 "$ST_CWD/nox"
  ST_CWD="$ST_CWD/nox"
  st_run_seat
  ST_CWD="$st_nox_parent"
  # An unreadable directory can't be cleaned up along with the rest of the test's temp area, so
  # this restores it before the assertions run.
  chmod 755 "$ST_CWD/nox"
  if st_expect_status "fails on a target directory that cannot be resolved" 2; then
    case "$ST_OUT" in
      *"cannot resolve the target directory"*) st_ok ;;
      *) st_fail "prints the resolution failure with its own reason" "$ST_OUT" ;;
    esac
    case "$ST_OUT" in
      *": cd: "*)
        st_fail "never leaks a raw shell error into user-facing output" "$ST_OUT"
        ;;
      *) st_ok ;;
    esac
    case "$ST_OUT" in
      *"current pointer"*)
        st_fail "never disguises the resolution failure as a pointer-side reason" "$ST_OUT"
        ;;
      *) st_ok ;;
    esac
    st_expect_true "never creates runtime data for a cwd that cannot be resolved" \
      test ! -e "$ST_RUNTIME/$REIN_OWNER_BASENAME"
  fi

  case_dir="$tmp/no-session-id"
  st_setup_case "$case_dir"
  jq -nc --arg schema "$REIN_POINTER_SCHEMA" --arg cwd "$ST_CWD" \
    '{schema: $schema, cwd: $cwd, generation: 1}' >"$ST_POINTER"
  st_run_seat
  st_expect_pointer_error "fails immediately on a pointer missing session_id" "has no session_id"

  case_dir="$tmp/bad-schema-pointer"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "successor" "$ST_CWD" 1
  jq -c '.schema = "rein.current.v0"' "$ST_POINTER" >"$ST_POINTER.tmp" && mv "$ST_POINTER.tmp" "$ST_POINTER"
  st_run_seat
  st_expect_pointer_error "fails immediately on a pointer whose schema does not match the contract" "does not match the contract"

  # Getting the location wrong can attach to a different project's session, so cwd is checked too.
  case_dir="$tmp/other-cwd-pointer"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "successor" "/somewhere/else" 1
  st_run_seat
  st_expect_pointer_error "fails immediately on a pointer naming a different cwd" "does not match the target"

  # attach returns non-zero: this never disguises it as a wait, and surfaces it after a bounded
  # number of retries.
  case_dir="$tmp/attach-fails"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "successor" "$ST_CWD" 1
  ST_ATTACH_EXIT=7
  ST_ATTACH_RETRY_MAX=2
  ST_MAX_ATTACH=0
  st_run_seat
  unset ST_ATTACH_EXIT ST_ATTACH_RETRY_MAX ST_MAX_ATTACH
  if st_expect_status "surfaces an attach failure" 1; then
    if ! st_expect_notify "notifies on an attach failure" "rein: cannot keep the seat" "claude attach failed"; then
      :
    elif [ "$(rein_st_count_calls "$ST_LOG" attach job-seat-1)" -ne 3 ]; then
      st_fail "retries attach up to the cap" "the attempt count does not match expectations: $(cat "$ST_LOG")"
    else
      case "$ST_OUT" in
        *"waiting for a handover"*)
          st_fail "never disguises an attach failure as a wait" "entered a wait: ${ST_OUT}"
          ;;
        *"claude attach returned non-zero"*)
          st_ok
          ;;
        *)
          st_fail "prints the attach failure to stderr" "no failure was printed: ${ST_OUT}"
          ;;
      esac
    fi
  fi

  # There's no attaching to an interactive session (the real CLI gives it no id), so this
  # surfaces the failure without waiting.
  case_dir="$tmp/interactive-target"
  st_setup_case "$case_dir"
  rein_st_write_agents_interactive "$ST_AGENTS" "$ST_CWD" "seat-1"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "successor" "$ST_CWD" 1
  st_run_seat
  if st_expect_status "never attaches to an interactive session" 1; then
    if [ "$(rein_st_count_sub "$ST_LOG" attach)" -ne 0 ]; then
      st_fail "never attaches to an interactive session" "attach was called: $(cat "$ST_LOG")"
    elif ! st_expect_notify "notifies that it cannot attach to an interactive session" \
      "rein: cannot keep the seat" "is an interactive session"; then
      :
    else
      st_ok
    fi
  fi

  # When a handover changes the pointer, attach comes back and this re-attaches with the new id.
  case_dir="$tmp/reattach"
  st_setup_case "$case_dir"
  rein_st_write_agents "$ST_AGENTS" "$ST_CWD" "seat-1" "seat-2"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "predecessor" "$ST_CWD" 1
  rein_st_write_pointer "$ST_CWD/next-pointer.json" "seat-2" "successor" "$ST_CWD" 2
  ST_ATTACH_CP_SRC="$ST_CWD/next-pointer.json"
  ST_ATTACH_CP_DST="$ST_POINTER"
  ST_MAX_ATTACH=2
  st_run_seat
  unset ST_ATTACH_CP_SRC ST_ATTACH_CP_DST ST_MAX_ATTACH
  if st_expect_status "re-attaches when the pointer changes" 0; then
    if ! rein_st_has_call "$ST_LOG" attach job-seat-1 || ! rein_st_has_call "$ST_LOG" attach job-seat-2; then
      st_fail "re-attaches to the successor" "attach does not show both the old and the new: $(cat "$ST_LOG")"
    else
      # Entering a wait despite the handover already being done would create a window where the
      # seat sits empty, so this also checks that it re-attaches without waiting.
      case "$ST_OUT" in
        *"waiting for a handover"*)
          st_fail "re-attaches without waiting for the switch" "entered a wait after attach returned: ${ST_OUT}"
          ;;
        *)
          st_ok
          ;;
      esac
      # The watchdog never fires on a handover that's being followed (if it did, every single
      # handover would produce a notification).
      if [ "$(st_count_notify "attach has not returned")" -eq 0 ]; then
        st_ok
      else
        st_fail "never notifies on a handover that was followed successfully" "$(cat "$ST_NOTIFY")"
      fi
    fi
  fi

  # The threshold composition itself. **This breaks if enumeration retries are ever dropped from
  # it again** (the old formula, `grace + cap + stop confirmation` = 135 seconds by default,
  # crosses the threshold while the watcher is still legitimately re-measuring).
  # The default is 681 seconds -- too long for the real-time cases below to run, so this pins the
  # arithmetic directly instead.
  st_expect_watchdog_limit "the default threshold folds in enumeration retries" 15 60 60 681
  # Even the minimal config the real-time cases below use is assembled from the same formula.
  st_expect_watchdog_limit "even the minimal config folds in enumeration retries" 0 1 0 16
  # The repeat spacing is a separate number from the threshold, and **the whole point is that it
  # no longer tracks it at the extremes**. Measured with the same inputs: the minimal config's
  # threshold of 16 seconds would be four notifications a minute, and a `cmd_timeout_sec` of 300
  # or 600 would be one every 51 or 101 minutes -- which for any realistic sitting is the
  # single-shot behaviour the repeat exists to fix. Both ends are clamped; the default (681) is
  # inside the range and is left exactly where it was.
  st_expect_watchdog_repeat "a threshold under the floor still repeats at the floor" 0 1 0 300
  st_expect_watchdog_repeat "the default spacing is the threshold, untouched" 15 60 60 681
  st_expect_watchdog_repeat "a threshold over the ceiling repeats at the ceiling" 15 300 60 900
  st_expect_watchdog_repeat "and still at the ceiling when the cap is doubled again" 15 600 60 900
  # Cross-checks the step count the threshold assumes against the watcher's actual step count.
  st_expect_retire_list_calls

  # The watchdog's parent check. **A pid is not an identity**: now that the watchdog runs for as
  # long as the mismatch lasts instead of returning after one notification, an orphan whose pid
  # gets reused would keep notifying about a seat nobody is in and go on appending to the seat log
  # beside a fresh seat that is also writing it. A real pid handover can't be staged, so the
  # function is called directly with this process standing in for the parent -- a recorded start
  # time that is its own is the live case, and any other value is exactly what a reused pid looks
  # like. The real-time cases below cover the accepting side end to end (a watchdog that answered
  # "gone" would exit at once and none of them would fire).
  if seat_watchdog_parent_present "$$" "$(rein_process_start_identity "$$")"; then
    st_ok
  else
    st_fail "the watchdog sees a live parent as present" "it read its own process as gone"
  fi
  if seat_watchdog_parent_present "$$" "Thu Jan  1 00:00:00 1970"; then
    st_fail "a pid that now holds a different process is not the parent" \
      "a process whose start time differs from the recorded one was accepted as the parent"
  else
    st_ok
  fi
  # Nothing recorded means `ps` could not answer at fork time. There is nothing to compare, so it
  # falls back to liveness instead of reading every round as a mismatch and switching itself off.
  if seat_watchdog_parent_present "$$" ""; then
    st_ok
  else
    st_fail "with no recorded start time it falls back to liveness" "it switched itself off instead"
  fi

  # A handover happened but attach never returned: the watchdog only notifies (touching neither
  # the terminal nor attach). The notification goes to stderr only after attach returns (a
  # terminal mid-attach is occupied by the TUI). How long attach sleeps is set **longer than the
  # threshold** (16 seconds under this config) -- shorter, and attach could return before the
  # watchdog fires, silently collapsing the test into the "it never fires" case.
  case_dir="$tmp/watchdog-fires"
  st_setup_case "$case_dir"
  rein_st_write_agents "$ST_AGENTS" "$ST_CWD" "seat-1" "seat-2"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "predecessor" "$ST_CWD" 1
  rein_st_write_pointer "$ST_CWD/next-pointer.json" "seat-2" "successor" "$ST_CWD" 2
  ST_ATTACH_CP_SRC="$ST_CWD/next-pointer.json"
  ST_ATTACH_CP_DST="$ST_POINTER"
  ST_ATTACH_SLEEP=20
  ST_EXIT_GRACE=0
  ST_STOP_TIMEOUT=0
  ST_CMD_TIMEOUT=1
  ST_MAX_ATTACH=1
  st_run_seat
  unset ST_ATTACH_CP_SRC ST_ATTACH_CP_DST ST_ATTACH_SLEEP ST_EXIT_GRACE ST_STOP_TIMEOUT ST_CMD_TIMEOUT ST_MAX_ATTACH
  if st_expect_status "the watchdog never cuts attach off" 0; then
    if [ "$(st_count_notify "attach has not returned")" -eq 1 ]; then
      st_ok
    else
      st_fail "notifies of a follow-up stall" \
        "notification count is not 1: $(st_count_notify "attach has not returned")"
    fi
    # No active detach -- attach ran exactly once and was never cut off.
    if [ "$(rein_st_count_calls "$ST_LOG" attach job-seat-1)" -eq 1 ]; then
      st_ok
    else
      st_fail "the watchdog never re-attaches on its own" "$(cat "$ST_LOG")"
    fi
    case "$ST_OUT" in
      *"attach has not returned"*)
        st_ok
        ;;
      *)
        st_fail "prints the watchdog's reason to the terminal after attach returns" "${ST_OUT}"
        ;;
    esac
    # A notification is not a record: once it's dismissed, or missed because nobody was at the
    # machine, nothing survives it. The observed accident could be reconstructed at all only
    # because a temp file happened to escape cleanup, so every firing lands in the seat's own log.
    st_expect_seat_log_line "logs that the watchdog fired" handover_stalled "attach has not returned"
    # What the user is told has to be something they can act on. The reason line the accident
    # actually produced said only that the pointer had switched and attach hadn't returned --
    # true, and impossible to do anything with. The one instruction that ends the state is held
    # in the shared library, so this and `rein status`'s seat line can't drift apart.
    if st_expect_notify "the notification says how to get out of it" \
      "rein: the handover is not being followed" "$REIN_SEAT_DETACH_HINT"; then
      st_ok
    fi
    st_expect_seat_log_line "the record carries the way out too" handover_stalled \
      "$REIN_SEAT_DETACH_HINT"
  fi

  # It doesn't go silent after the first one. Firing once and returning (what it used to do) made
  # the whole mechanism single-shot: the observed accident ran over 4 hours, and after the one
  # notification -- fired while nobody was at the machine -- nothing was ever said again.
  # **The second firing is provoked by bringing the pointer back into step and out again**, not by
  # waiting out the spacing: the spacing has a floor of five minutes now (deliberately -- it is no
  # longer the firing threshold, which the minimal config puts at 16 seconds), so a case that
  # waited for it would have to run for minutes. What this still proves is exactly the regression
  # that matters: a watchdog that returned after its first notification produces one firing here,
  # not two, no matter what the pointer does afterwards. The spacing itself is pinned by
  # st_expect_watchdog_repeat above.
  # The count is pinned from **both sides**: at least 2 (it did not return) and at most 4 (it is
  # spaced, not fired every poll -- at a 0.2-second poll interval a watchdog that dropped the
  # spacing would produce something on the order of a hundred inside these 40 seconds).
  case_dir="$tmp/watchdog-repeats"
  st_setup_case "$case_dir"
  rein_st_write_agents "$ST_AGENTS" "$ST_CWD" "seat-1" "seat-2"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "predecessor" "$ST_CWD" 1
  rein_st_write_pointer "$ST_CWD/next-pointer.json" "seat-2" "successor" "$ST_CWD" 2
  rein_st_write_pointer "$ST_CWD/back-pointer.json" "seat-1" "predecessor" "$ST_CWD" 1
  ST_ATTACH_CP_SRC="$ST_CWD/next-pointer.json"
  ST_ATTACH_CP_DST="$ST_POINTER"
  ST_ATTACH_SLEEP=40
  ST_EXIT_GRACE=0
  ST_STOP_TIMEOUT=0
  ST_CMD_TIMEOUT=1
  ST_MAX_ATTACH=1
  # Waits for the first firing rather than sleeping a fixed amount (the seat's own startup time
  # would otherwise have to be guessed), then puts the pointer back where the seat is looking and
  # moves it away again. Each pointer swap is a rename, so the watchdog never reads a half-written
  # file. Runs alongside `st_run_seat`, which is blocked for as long as the fake attach sleeps.
  (
    st_flip_i=0
    while [ "$st_flip_i" -lt 400 ]; do
      [ "$(st_count_seat_log_event handover_stalled)" -ge 1 ] && break
      sleep 0.2
      st_flip_i=$((st_flip_i + 1))
    done
    cp "$ST_CWD/back-pointer.json" "${ST_POINTER}.st-partial" &&
      mv "${ST_POINTER}.st-partial" "$ST_POINTER"
    sleep 1
    cp "$ST_CWD/next-pointer.json" "${ST_POINTER}.st-partial" &&
      mv "${ST_POINTER}.st-partial" "$ST_POINTER"
  ) &
  st_flip_pid=$!
  st_run_seat
  wait "$st_flip_pid" 2>/dev/null
  st_flip_pid=""
  unset ST_ATTACH_CP_SRC ST_ATTACH_CP_DST ST_ATTACH_SLEEP ST_EXIT_GRACE ST_STOP_TIMEOUT ST_CMD_TIMEOUT ST_MAX_ATTACH
  if st_expect_status "the watchdog still never cuts attach off while repeating" 0; then
    st_watchdog_repeat_count="$(st_count_notify "attach has not returned")"
    if [ "$st_watchdog_repeat_count" -ge 2 ] && [ "$st_watchdog_repeat_count" -le 4 ]; then
      st_ok
    else
      st_fail "keeps notifying while the pointer and the connection stay out of step" \
        "notification count is not within 2..4: ${st_watchdog_repeat_count}"
    fi
    # Each firing is recorded, so the trace shows how long the mismatch ran rather than only
    # that it once happened.
    st_watchdog_repeat_logged="$(st_count_seat_log_event handover_stalled)"
    if [ "$st_watchdog_repeat_logged" = "$st_watchdog_repeat_count" ]; then
      st_ok
    else
      st_fail "records every firing, not just the first" \
        "seat log has ${st_watchdog_repeat_logged} handover_stalled lines against ${st_watchdog_repeat_count} notifications"
    fi
    # Still no active detach, even across repeats.
    if [ "$(rein_st_count_calls "$ST_LOG" attach job-seat-1)" -eq 1 ]; then
      st_ok
    else
      st_fail "repeating never re-attaches on its own" "$(cat "$ST_LOG")"
    fi
  fi

  # The accepting side: as long as the pointer hasn't changed, no notification fires no matter
  # how long attach runs (a watchdog that always fires is, to its owner, the same as no watchdog
  # at all).
  case_dir="$tmp/watchdog-silent"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "still-here" "$ST_CWD" 1
  ST_ATTACH_SLEEP=2
  ST_EXIT_GRACE=0
  ST_STOP_TIMEOUT=0
  ST_CMD_TIMEOUT=1
  ST_MAX_ATTACH=1
  st_run_seat
  unset ST_ATTACH_SLEEP ST_EXIT_GRACE ST_STOP_TIMEOUT ST_CMD_TIMEOUT ST_MAX_ATTACH
  if st_expect_status "the watchdog stays silent with no handover" 0; then
    if [ "$(st_count_notify "attach has not returned")" -eq 0 ]; then
      st_ok
    else
      st_fail "never notifies when there was no handover" "$(cat "$ST_NOTIFY")"
    fi
  fi

  # The pointer stays put and the target is dead: this surfaces the failure without waiting.
  case_dir="$tmp/dead-session"
  st_setup_case "$case_dir"
  printf '[]\n' >"$ST_AGENTS"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "gone" "$ST_CWD" 1
  ST_MAX_ATTACH=0
  st_run_seat
  unset ST_MAX_ATTACH
  if st_expect_status "fails when the target is dead and the pointer never advances" 1; then
    if ! st_expect_notify "notifies that the target is gone" "rein: cannot keep the seat" "is not in the claude agents --json enumeration"; then
      :
    elif [ "$(rein_st_count_sub "$ST_LOG" attach)" -ne 0 ]; then
      st_fail "never attaches to a target missing from enumeration" "attach was called: $(cat "$ST_LOG")"
    else
      # Never waits on something that isn't coming back (a wait wouldn't notice until the wait
      # cap).
      case "$ST_OUT" in
        *"waiting for a handover"*)
          st_fail "never waits on a dead target" "entered a wait: ${ST_OUT}"
          ;;
        *)
          st_ok
          ;;
      esac
    fi
  fi

  # The pointer stays put and the target is alive: enters the wait for a handover, and surfaces
  # the failure at the wait cap.
  case_dir="$tmp/waiting"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "still-here" "$ST_CWD" 1
  ST_MAX_ATTACH=0
  st_run_seat
  unset ST_MAX_ATTACH
  if st_expect_status "surfaces the failure at the wait cap when no handover comes" 1; then
    case "$ST_OUT" in
      *"waiting for a handover"*)
        st_ok
        ;;
      *)
        st_fail "enters the wait for a handover" "no sign of entering a wait: ${ST_OUT}"
        ;;
    esac
  fi

  # If the pointer changes mid-wait, this re-attaches (confirms the wait loop is re-reading it).
  case_dir="$tmp/late-change"
  st_setup_case "$case_dir"
  rein_st_write_agents "$ST_AGENTS" "$ST_CWD" "seat-1" "seat-2"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "predecessor" "$ST_CWD" 1
  rein_st_write_pointer "$ST_CWD/next-pointer.json" "seat-2" "successor" "$ST_CWD" 2
  ST_MAX_ATTACH=2
  ST_WAIT_TIMEOUT=5
  # One round is set long because a wait for an absent watcher ends after WATCHER_ABSENT_LIMIT
  # rounds -- the swap needs to be reliably slipped in inside that window.
  ST_POLL_INTERVAL=1
  # Entering the wait shows up as a heartbeat notification (which only ever fires from inside the
  # wait loop). Swapping the file in on a real-time sleep would let a load-delayed seat startup
  # switch before "the pointer re-read right after attach returns" gets a chance -- re-attaching
  # without ever entering the wait, so the check would pass without ever exercising the wait
  # loop's re-read. The 8-second cap is longer than the 5-second wait cap (st_copy_after_notify's
  # rule).
  st_copy_after_notify "the watcher may have stopped" \
    "$ST_CWD/next-pointer.json" "$ST_POINTER" 8 &
  st_run_seat
  wait
  unset ST_MAX_ATTACH ST_WAIT_TIMEOUT ST_POLL_INTERVAL
  if st_expect_status "re-attaches on a switch that lands mid-wait" 0; then
    if rein_st_has_call "$ST_LOG" attach job-seat-2; then
      st_ok
    else
      st_fail "catches a switch that lands mid-wait" "no attach to the successor: $(cat "$ST_LOG")"
    fi
  fi

  # In an environment where a prerequisite doesn't work, pointer validation and liveness checks
  # fail for the wrong reason. This surfaces it at startup.
  for tool in jq date stat perl; do
    case_dir="$tmp/missing-$tool"
    st_setup_case "$case_dir"
    ST_BROKEN_BIN="$tmp/broken-$tool"
    rein_st_write_broken_tool "$ST_BROKEN_BIN" "$tool"
    rein_st_write_pointer "$ST_POINTER" "seat-1" "successor" "$ST_CWD" 1
    st_run_seat
    unset ST_BROKEN_BIN
    st_expect_startup_reject "never starts when the prerequisite ${tool} does not work" "a prerequisite"
  done

  # Validating numeric settings. An invalid wait cap would fall through to deadline=0, an unlimited
  # wait -- indistinguishable, from the user's side, between "waiting" and "broken."
  case_dir="$tmp/bad-max-attach"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "successor" "$ST_CWD" 1
  ST_MAX_ATTACH=abc
  st_run_seat
  unset ST_MAX_ATTACH
  st_expect_startup_reject "never starts on a non-numeric --max-attach" "the setting value is invalid"

  case_dir="$tmp/bad-wait-timeout"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "successor" "$ST_CWD" 1
  ST_WAIT_TIMEOUT=-1
  st_run_seat
  unset ST_WAIT_TIMEOUT
  st_expect_startup_reject "never starts on a negative wait cap" "the setting value is invalid"

  # The watcher stops mid-wait: one absent round never gives up (it would close the seat owner's
  # own terminal) -- it notifies and keeps waiting, but consecutive absence means nobody is there
  # to drive a handover, so it steps down. **Measured with the wait cap at 0 (unlimited,
  # default)** -- measuring it with a cap set would leave it ambiguous whether stepping down was
  # the give-up logic or just hitting the cap. Launched in the background and waited for to exit
  # on its own -- run in the foreground, a broken implementation that never steps down would hang
  # the whole test.
  case_dir="$tmp/heartbeat-missing"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "still-here" "$ST_CWD" 1
  heartbeat_out="$ST_CWD/heartbeat-missing.out"
  ST_MAX_ATTACH=0
  ST_WAIT_TIMEOUT=0
  st_run_seat_bg "$heartbeat_out"
  if st_wait_for_pid_exit "$ST_SEAT_BG_PID" 15; then
    wait "$ST_SEAT_BG_PID"
    ST_STATUS=$?
    ST_OUT="$(cat "$heartbeat_out")"
    st_ok
  else
    kill -TERM "$ST_SEAT_BG_PID" 2>/dev/null
    wait "$ST_SEAT_BG_PID" 2>/dev/null
    ST_STATUS=0
    ST_OUT="$(cat "$heartbeat_out")"
    st_fail "steps down on its own from an unlimited wait when the watcher is absent" \
      "still had not stepped down after 15 seconds: ${ST_OUT}"
  fi
  unset ST_MAX_ATTACH ST_WAIT_TIMEOUT
  if st_expect_status "steps down non-zero when the watcher stays absent" 1; then
    case "$ST_OUT" in
      *"waiting for a handover"*"the watcher may have stopped"*)
        st_ok
        ;;
      *)
        st_fail "notifies that the watcher may have stopped" "${ST_OUT}"
        ;;
    esac
    # The reason for stepping down carries both "why the wait was abandoned" and "what to do
    # next."
    if st_expect_notify "logs why it gave up" "rein: cannot keep the seat" \
      "the watcher's heartbeat has not been updated for 3 consecutive rounds"; then
      st_ok
    fi
    # **Checks even the exact name used.** On a machine with no install, rein isn't on PATH, so
    # the hint prints the real path -- this catches a mutation that reverts it to the bare `rein`
    # (a prefix-only check would let an untypeable line through too).
    if st_expect_notify "includes the restart-hint line" "rein: cannot keep the seat" \
      "restart the watcher: $(rein_shell_quote "$REIN_BIN") --cwd "; then
      st_ok
    fi
    # At most once per wait (firing every poll would make the notification meaningless).
    if [ "$(st_count_notify "the watcher may have stopped")" -eq 1 ]; then
      st_ok
    else
      st_fail "never notifies twice in the same wait" \
        "notification count is not 1: $(st_count_notify "the watcher may have stopped")"
    fi
    # What this give-up logic bounds is **cost** (spawning an external CLI every round), so it's
    # pinned by call count. Caps at 5: 1 startup liveness check + 1 attach-return liveness check +
    # 3 wait rounds.
    if [ "$(rein_st_count_sub "$ST_LOG" agents)" -le 5 ]; then
      st_ok
    else
      st_fail "never keeps spawning the external CLI even during an unlimited wait" \
        "agents was called more than 5 times: $(rein_st_count_sub "$ST_LOG" agents)"
    fi
  fi

  # A transient absence (a watcher restart, the instant a heartbeat is rewritten) never steps the
  # seat down. What's counted is **consecutive** rounds -- a fresh heartbeat read in even one
  # round breaks the streak, so an implementation that counts the running total would step down
  # here regardless. This drops and restores the heartbeat on a schedule that produces "2 rounds
  # absent -> 1 round present -> 1 round absent," so the running total is 3 while the streak
  # never exceeds 2. **No wait cap is set** (0 = unlimited) -- the only two ways this can end are
  # "re-attached to the successor" (correct) or "gave up and stepped down" (a regression), never
  # something a cap-triggered end could be read as either way.
  case_dir="$tmp/heartbeat-transient"
  st_setup_case "$case_dir"
  rein_st_write_agents "$ST_AGENTS" "$ST_CWD" "seat-1" "seat-2"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "predecessor" "$ST_CWD" 1
  rein_st_write_pointer "$ST_CWD/next-pointer.json" "seat-2" "successor" "$ST_CWD" 2
  heartbeat_out="$ST_CWD/heartbeat-transient.out"
  ST_MAX_ATTACH=2
  ST_WAIT_TIMEOUT=0
  ST_POLL_INTERVAL=0.5
  # Drops a heartbeat at the end of wait round 2 (call 4), removes it at the end of round 3
  # (call 5) -- absent again in round 4 -- then triggers a handover at the end of round 4
  # (call 6). If the 15-second cap is never reached, nothing happens: the seat stays up, and the
  # wait below fails.
  st_heartbeat_between_calls 4 5 15 &
  st_copy_after_calls 6 "$ST_CWD/next-pointer.json" "$ST_POINTER" 15 &
  st_run_seat_bg "$heartbeat_out"
  if st_wait_for_pid_exit "$ST_SEAT_BG_PID" 20; then
    wait "$ST_SEAT_BG_PID"
    ST_STATUS=$?
  else
    kill -TERM "$ST_SEAT_BG_PID" 2>/dev/null
    wait "$ST_SEAT_BG_PID" 2>/dev/null
    ST_STATUS=2
  fi
  ST_OUT="$(cat "$heartbeat_out")"
  wait
  unset ST_MAX_ATTACH ST_WAIT_TIMEOUT ST_POLL_INTERVAL
  if st_expect_status "keeps waiting for a handover through a transient absence, never steps down" 0; then
    case "$ST_OUT" in
      *"the watcher's heartbeat has not been updated for"*"consecutive rounds"*)
        st_fail "recounts once the streak breaks" "stepped down counting the running total: ${ST_OUT}"
        ;;
      *)
        if rein_st_has_call "$ST_LOG" attach job-seat-2; then
          st_ok
        else
          st_fail "re-attaches to the successor across a transient absence" "no attach to the successor: $(cat "$ST_LOG")"
        fi
        ;;
    esac
  fi

  # The wait repeats on every handover. Notifying once on the first wait and then staying silent
  # would effectively mean "at most once per process lifetime," going silent on watcher stoppage
  # for longer and longer stretches the more this re-attaches across handovers.
  case_dir="$tmp/heartbeat-second-wait"
  st_setup_case "$case_dir"
  rein_st_write_agents "$ST_AGENTS" "$ST_CWD" "seat-1" "seat-2"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "predecessor" "$ST_CWD" 1
  rein_st_write_pointer "$ST_CWD/next-pointer.json" "seat-2" "successor" "$ST_CWD" 2
  ST_MAX_ATTACH=0
  ST_WAIT_TIMEOUT=2
  # One round is set long because a wait for an absent watcher ends after WATCHER_ABSENT_LIMIT
  # rounds -- the swap needs to be reliably slipped in inside that window (the default 0.2
  # seconds only leaves one round's worth of margin between seeing the notification and dropping
  # the file).
  ST_POLL_INTERVAL=1
  # The 6-second cap is longer than the 2-second wait cap (the rule from the function above).
  st_copy_after_notify "the watcher may have stopped" \
    "$ST_CWD/next-pointer.json" "$ST_POINTER" 6 &
  st_run_seat
  wait
  unset ST_MAX_ATTACH ST_WAIT_TIMEOUT ST_POLL_INTERVAL
  if st_expect_status "surfaces a failure non-zero even on the second wait" 1; then
    if ! rein_st_has_call "$ST_LOG" attach job-seat-2; then
      st_fail "waits twice across a handover" "no attach to the successor: $(cat "$ST_LOG")"
    elif [ "$(st_count_notify "the watcher may have stopped")" -eq 2 ]; then
      st_ok
    else
      st_fail "notifies again on the next wait" \
        "2 waits did not produce 2 notifications: $(st_count_notify "the watcher may have stopped")"
    fi
  fi

  # A heartbeat that's **present but stale** counts the same as absent (the watcher has stopped
  # updating it -- no handover is coming). No wait cap is set -- the wording of the reason is
  # what proves it stepped down from the give-up logic.
  case_dir="$tmp/heartbeat-stale"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "still-here" "$ST_CWD" 1
  printf '1234 stale\n' >"$ST_RUNTIME/$REIN_HEARTBEAT_BASENAME"
  touch -t 202001010000 "$ST_RUNTIME/$REIN_HEARTBEAT_BASENAME"
  heartbeat_out="$ST_CWD/heartbeat-stale.out"
  ST_MAX_ATTACH=0
  ST_WAIT_TIMEOUT=0
  ST_HEARTBEAT_MAX_AGE=5
  st_run_seat_bg "$heartbeat_out"
  if st_wait_for_pid_exit "$ST_SEAT_BG_PID" 15; then
    wait "$ST_SEAT_BG_PID"
    ST_STATUS=$?
    ST_OUT="$(cat "$heartbeat_out")"
    st_ok
  else
    kill -TERM "$ST_SEAT_BG_PID" 2>/dev/null
    wait "$ST_SEAT_BG_PID" 2>/dev/null
    ST_STATUS=0
    ST_OUT="$(cat "$heartbeat_out")"
    st_fail "steps down on its own from an unlimited wait even on a stale heartbeat" \
      "still had not stepped down after 15 seconds: ${ST_OUT}"
  fi
  unset ST_MAX_ATTACH ST_WAIT_TIMEOUT ST_HEARTBEAT_MAX_AGE
  if st_expect_status "steps down non-zero when the heartbeat stays stale" 1; then
    case "$ST_OUT" in
      *"heartbeat is "*" seconds old"*)
        st_ok
        ;;
      *)
        st_fail "notifies of the heartbeat's staleness" "${ST_OUT}"
        ;;
    esac
    case "$ST_OUT" in
      *"the watcher's heartbeat has not been updated for 3 consecutive rounds"*"heartbeat is "*" seconds old"*)
        st_ok
        ;;
      *)
        st_fail "includes the staleness in the give-up reason too" "${ST_OUT}"
        ;;
    esac
  fi

  # The accepting side: with a fresh heartbeat, it waits silently (confirming the check above
  # isn't always true).
  case_dir="$tmp/heartbeat-fresh"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "still-here" "$ST_CWD" 1
  printf '1234 fresh\n' >"$ST_RUNTIME/$REIN_HEARTBEAT_BASENAME"
  ST_MAX_ATTACH=0
  st_run_seat
  unset ST_MAX_ATTACH
  if st_expect_status "never warns on a fresh heartbeat" 1; then
    case "$ST_OUT" in
      *"the watcher may have stopped"*)
        st_fail "never warns on a fresh heartbeat" "${ST_OUT}"
        ;;
      *"waiting for a handover"*)
        st_ok
        ;;
      *)
        st_fail "still enters the wait with a fresh heartbeat" "${ST_OUT}"
        ;;
    esac
  fi

  # Cannot read enumeration at all: this is never treated the same as "the target is missing" --
  # it fails, with a reason, before ever trying attach (firing attach with enumeration unreadable
  # would surface as some other error from the real CLI, losing the actual cause).
  case_dir="$tmp/agents-unreadable"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "successor" "$ST_CWD" 1
  ST_AGENTS_FAIL=1
  st_run_seat
  unset ST_AGENTS_FAIL
  if st_expect_status "never tries attach when enumeration cannot be read" 1; then
    if [ "$(rein_st_count_sub "$ST_LOG" attach)" -ne 0 ]; then
      st_fail "never attaches when enumeration is unreadable" "attach was called: $(cat "$ST_LOG")"
    elif ! st_expect_notify "notifies that enumeration is unreadable" \
      "rein: cannot keep the seat" "cannot read claude agents --json"; then
      :
    else
      st_ok
    fi
  fi

  # A **transient** enumeration failure is never a reason to step down. Enumeration is a capped
  # external command, and the CLI failing to respond once -- right after waking from sleep, say --
  # is realistic. Stepping down on that single failure would break the "zero-action attach to the
  # successor" guarantee every time it happened, recoverable only by the user re-running `rein up`
  # by hand. A persistently unreadable form (the case above) still fails as before.
  case_dir="$tmp/agents-flaky"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "successor" "$ST_CWD" 1
  ST_AGENTS_FAIL_ONCE_AT=1
  st_run_seat
  unset ST_AGENTS_FAIL_ONCE_AT
  if st_expect_status "never steps down on one enumeration failure" 0; then
    if [ "$(rein_st_count_sub "$ST_LOG" attach)" -eq 0 ]; then
      st_fail "measures again and reaches attach" "attach was never called: $(cat "$ST_LOG")"
    else
      st_ok
    fi
  fi

  # Where runtime data lives can also move via an environment variable (a path the contract says
  # is movable). The pointer is a record on the cwd side, so this swap never moves it.
  case_dir="$tmp/runtime-dir-env"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "successor" "$ST_CWD" 1
  ST_RUNTIME_ARGS=()
  ST_RUNTIME_ENV="$ST_RUNTIME"
  st_run_seat
  if st_expect_status "attaches even through REIN_RUNTIME_DIR" 0; then
    if rein_st_has_call "$ST_LOG" attach job-seat-1; then
      st_ok
    else
      st_fail "uses the environment variable's runtime directory" "$(cat "$ST_LOG")"
    fi
  fi

  # The lineage's records are read from the project side's .rein/ (moving runtime data never
  # moves the pointer).
  case_dir="$tmp/records-in-project"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "successor" "$ST_CWD" 1
  st_run_seat
  if st_expect_status "attaches using the pointer on the project side" 0; then
    if [ "$ST_POINTER" = "$ST_CWD/$REIN_RECORDS_DIRNAME/$REIN_POINTER_BASENAME" ] &&
      rein_st_has_call "$ST_LOG" attach job-seat-1; then
      st_ok
    else
      st_fail "reads the pointer from .rein/" "$(cat "$ST_LOG")"
    fi
  fi
  # A pointer placed in the runtime directory is never read (a negative check that the two
  # locations really are kept separate).
  case_dir="$tmp/records-not-in-runtime"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_RUNTIME/$REIN_POINTER_BASENAME" "seat-1" "successor" "$ST_CWD" 1
  st_run_seat
  st_expect_pointer_error "never reads a pointer from the runtime directory" "there is no current pointer"

  # A malformed config fails at startup (never silently falls back to a default).
  case_dir="$tmp/broken-config"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "successor" "$ST_CWD" 1
  printf 'unknown_key=1\n' >"$ST_USER_CONFIG"
  st_run_seat
  st_expect_startup_reject "never starts on an unknown config key" "unknown key"

  # A config value becomes the effective value (the path that never goes through an environment
  # variable).
  case_dir="$tmp/config-runtime-dir"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "successor" "$ST_CWD" 1
  printf 'runtime_dir=%s\n' "$ST_CWD/from-config" >"$ST_USER_CONFIG"
  mkdir -p "$ST_CWD/from-config"
  printf '1234 fresh\n' >"$ST_CWD/from-config/$REIN_HEARTBEAT_BASENAME"
  ST_RUNTIME_ARGS=()
  ST_MAX_ATTACH=0
  ST_WAIT_TIMEOUT=1
  st_run_seat
  unset ST_MAX_ATTACH ST_WAIT_TIMEOUT
  if st_expect_status "enters the wait even with config's runtime_dir" 1; then
    # The fresh heartbeat is placed at config's own location -- if that's what's being read, no
    # warning fires.
    case "$ST_OUT" in
      *"the watcher may have stopped"*)
        st_fail "reads the heartbeat from config's runtime_dir" "${ST_OUT}"
        ;;
      *"waiting for a handover"*)
        st_ok
        ;;
      *)
        st_fail "enters the wait with config's runtime_dir" "${ST_OUT}"
        ;;
    esac
  fi

  # A seat pointed at another lineage's runtime directory never starts. Without checking the
  # owner, it would read another lineage's watcher heartbeat as its own and keep waiting silently
  # even while its own watcher is dead.
  case_dir="$tmp/runtime-owner-mismatch"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "successor" "$ST_CWD" 1
  printf '/somewhere/else\n' >"$ST_RUNTIME/$REIN_OWNER_BASENAME"
  st_run_seat
  st_expect_startup_reject "never starts with a runtime directory belonging to someone else" "belongs to a different target"

  # `<cwd>/.rein` **itself** being a symlink: the seat never sits down. The resolver already
  # refuses that shape, but taken through `$( )` its refusal arrives as the same empty string a
  # success would -- the pointer would become `/current.json` and the seat log `/seat.log`, so the
  # seat would take the filesystem root for its lineage, wait on a pointer that is never there,
  # and report it as an ordinary "no handover yet".
  case_dir="$tmp/records-parent-symlink"
  st_setup_case "$case_dir"
  seat_records_outside="$ST_CWD/records-outside"
  mkdir -p "$seat_records_outside"
  printf 'ORIGINAL\n' >"$seat_records_outside/SENTINEL"
  seat_records_before="$(find "$seat_records_outside" | LC_ALL=C sort)"
  rm -rf "$ST_RECORDS"
  ln -s "$seat_records_outside" "$ST_RECORDS"
  st_run_seat
  st_expect_startup_reject "never starts when the records location is a symlink" "symbolic link"
  st_expect_true "writes not a single file into what the records symlink points at" \
    test "$(find "$seat_records_outside" | LC_ALL=C sort)" = "$seat_records_before"

  # The accepting side: a matching owner is allowed through (checking whether the check isn't
  # too broad and rejecting a legitimate lineage too).
  case_dir="$tmp/runtime-owner-match"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "successor" "$ST_CWD" 1
  printf '%s\n' "$ST_CWD" >"$ST_RUNTIME/$REIN_OWNER_BASENAME"
  st_run_seat
  if st_expect_status "attaches when the runtime directory's owner matches" 0; then
    if rein_st_has_call "$ST_LOG" attach job-seat-1; then
      st_ok
    else
      st_fail "attaches when the owner matches" "$(cat "$ST_LOG")"
    fi
  fi

  # The seat drops the seat lock (a lineage has one seat). Since it leaves a marker at the
  # location, it also records the owner -- runtime data without an owner can't be traced back to
  # which working tree it belongs to from the outside.
  case_dir="$tmp/runtime-owner-readonly"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "successor" "$ST_CWD" 1
  st_run_seat
  if st_expect_status "attaches even with no owner file" 0; then
    if [ "$(head -1 "$ST_RUNTIME/$REIN_OWNER_BASENAME" 2>/dev/null)" = "$ST_CWD" ]; then
      st_ok
    else
      st_fail "the seat records the owner" "$(cat "$ST_RUNTIME/$REIN_OWNER_BASENAME" 2>/dev/null)"
    fi
  fi

  # The lock while seated is pinned with a short-lived fixture confirmed ready. Even a full run
  # of the human gate uses the same cooperative-termination and no-leftover-state check as the
  # targeted section.
  st_seat_lock_busy_case

  # A leftover lock whose owner has disappeared is reclaimed (a dead seat's lock never permanently
  # blocks the seat).
  case_dir="$tmp/seat-lock-stale"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "successor" "$ST_CWD" 1
  holder_lock="$ST_RUNTIME/$REIN_SEAT_LOCK_DIRNAME"
  mkdir -p "$holder_lock"
  # A live pid (this process itself), with a start time that doesn't match -- a form where a
  # reused pid can't be mistaken for the owner.
  printf '%s\n' "$$" >"$holder_lock/pid"
  printf 'Thu Jan  1 00:00:00 2020\n' >"$holder_lock/start"
  printf 'stale-token\n' >"$holder_lock/token"
  st_run_seat
  if st_expect_status "starts by reclaiming a leftover lock" 0; then
    if rein_st_has_call "$ST_LOG" attach job-seat-1; then
      st_ok
    else
      st_fail "attaches after reclaiming" "$(cat "$ST_LOG")"
    fi
  fi
  # On exit, only its own lock is released (leaving it behind would make the next seat read
  # "seated").
  if [ ! -e "$holder_lock" ]; then
    st_ok
  else
    st_fail "releases its own seat lock on exit" "$(ls "$holder_lock")"
  fi

  # Cleanup still runs on an interrupt signal. **INT/TERM/HUP are not trapped separately -- only
  # the EXIT trap is set** (bash runs an EXIT trap even before dying from a signal, if one is
  # set; an explicit trap would delay signal handling until the foreground child returns -- see
  # the note next to run_seat's trap). What's actually being checked here, then, is exactly that
  # cleanup arrives even with no explicit trap. Since a leftover seat lock permanently blocks the
  # seat, this actually creates the shape of being killed mid-attach and observes it.
  local signal_rc signal_out
  case_dir="$tmp/seat-signal"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "successor" "$ST_CWD" 1
  signal_out="$ST_CWD/seat-signal.out"
  ST_ATTACH_SLEEP=5
  st_run_seat_bg "$signal_out"
  if st_wait_for_seat_lock; then
    st_ok
  else
    st_fail "the seat lock is published mid-attach" "$(ls -a "$ST_RUNTIME")"
  fi
  kill -TERM "$ST_SEAT_BG_PID" 2>/dev/null
  wait "$ST_SEAT_BG_PID" 2>/dev/null
  signal_rc=$?
  unset ST_ATTACH_SLEEP
  # Ends at 128+signal number (an interrupt from the user is never reported as a normal exit).
  if [ "$signal_rc" -eq 143 ]; then
    st_ok
  else
    st_fail "TERM ends at 128+signal number" "rc=${signal_rc}: $(cat "$signal_out" 2>/dev/null)"
  fi
  if [ ! -e "$ST_RUNTIME/$REIN_SEAT_LOCK_DIRNAME" ]; then
    st_ok
  else
    st_fail "releases the seat lock even on TERM" "$(ls -a "$ST_RUNTIME/$REIN_SEAT_LOCK_DIRNAME")"
  fi

  # The seat-directed marker `rein down` drops: if the marker is present on the round attach
  # returns, this steps down with exit 0 and no notification (a stop the user actually triggered is
  # never rung as "the session ended but the pointer wasn't updated"). The marker is created in a
  # form that's dropped mid-attach -- dropping it before startup would have it cleared by the
  # pre-seating cleanup, so that path can't be exercised (that clearing itself is checked by the
  # next case).
  case_dir="$tmp/seat-stop-mark"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "still-here" "$ST_CWD" 1
  printf '{"schema":"%s","requested_at":"%s","requested_by_pid":%s}\n' \
    "$REIN_SEAT_STOP_SCHEMA" "$(rein_iso_now)" "$$" >"$ST_CWD/seat-stop.json"
  ST_ATTACH_CP_SRC="$ST_CWD/seat-stop.json"
  ST_ATTACH_CP_DST="$ST_RUNTIME/$REIN_SEAT_STOP_BASENAME"
  # Run with no cap -- if the marker is never read, this enters the wait and ends non-zero at the
  # wait cap (the two sides are distinguishable this way).
  ST_MAX_ATTACH=0
  st_run_seat
  unset ST_ATTACH_CP_SRC ST_ATTACH_CP_DST ST_MAX_ATTACH
  if st_expect_status "steps down with exit 0 when the shutdown marker is present" 0; then
    case "$ST_OUT" in
      *"rein down shut the lineage down"*) st_ok ;;
      *) st_fail "prints one line to the terminal for the shutdown" "$ST_OUT" ;;
    esac
    if [ "$(rein_st_calls_total "$ST_NOTIFY")" -eq 0 ]; then
      st_ok
    else
      st_fail "never notifies on a round it stepped down from the marker" "$(cat "$ST_NOTIFY")"
    fi
    st_expect_true "clears the marker it consumed" test ! -e "$ST_RUNTIME/$REIN_SEAT_STOP_BASENAME"
  fi

  # A marker left over from before sitting down is never consumed (a leftover from a previous
  # `down` never makes the next seat step down silently on its first attach return). It's cleared
  # right after the seat lock is claimed. Since a leftover marker's `down` is no longer around,
  # its requester pid is a dead one.
  case_dir="$tmp/seat-stop-stale"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "successor" "$ST_CWD" 1
  printf '{"schema":"%s","requested_at":"%s","requested_by_pid":%s}\n' \
    "$REIN_SEAT_STOP_SCHEMA" "$(rein_iso_now)" "99999999" >"$ST_RUNTIME/$REIN_SEAT_STOP_BASENAME"
  st_run_seat
  if st_expect_status "sits down even with a leftover marker present" 0; then
    if rein_st_has_call "$ST_LOG" attach job-seat-1; then
      st_ok
    else
      st_fail "clears the leftover marker and attaches" "$(cat "$ST_LOG")"
    fi
    st_expect_true "clears a leftover marker before sitting down" test ! -e "$ST_RUNTIME/$REIN_SEAT_STOP_BASENAME"
    case "$ST_OUT" in
      *"rein down shut the lineage down"*)
        st_fail "never steps down from a leftover marker" "$ST_OUT"
        ;;
      *) st_ok ;;
    esac
  fi

  # The opposite side: a marker whose `down` is still alive is never cleared before sitting down. A
  # seat that sits down inside the window between `down` dropping the marker and the external stop
  # taking effect, and consumes it, would find the marker gone on the very next attach return,
  # ringing the stop the user actually triggered as a failure. Sitting down without clearing it
  # means this seat itself consumes the marker on the first attach return and steps down quietly.
  case_dir="$tmp/seat-stop-live-owner"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "still-here" "$ST_CWD" 1
  printf '{"schema":"%s","requested_at":"%s","requested_by_pid":%s}\n' \
    "$REIN_SEAT_STOP_SCHEMA" "$(rein_iso_now)" "$$" >"$ST_RUNTIME/$REIN_SEAT_STOP_BASENAME"
  # No cap -- clearing the marker would enter the wait and end non-zero at the wait cap (the two
  # sides are distinguishable this way).
  ST_MAX_ATTACH=0
  st_run_seat
  unset ST_MAX_ATTACH
  if st_expect_status "never clears a live request's marker before sitting down" 0; then
    case "$ST_OUT" in
      *"rein down shut the lineage down"*) st_ok ;;
      *) st_fail "consumes the marker it left in place on the first attach return" "$ST_OUT" ;;
    esac
    st_expect_true "gone after being consumed" test ! -e "$ST_RUNTIME/$REIN_SEAT_STOP_BASENAME"
  fi

  # Even a live pid is cleared as a leftover if the marker is outside the window. pids get reused,
  # so going by liveness alone means that the moment some other process reuses the pid on a marker
  # left over from a previous `down`, that marker turns into a "live request": the next seat to sit
  # down consumes it on its first attach return and steps down silently, producing exactly the one
  # line a real `rein down` would produce even though the user never ran it.
  case_dir="$tmp/seat-stop-reused-pid"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "still-here" "$ST_CWD" 1
  # A live pid (this test process itself), with a request timestamp outside the window -- a form
  # where a reused pid can't be mistaken for the marker's owner.
  printf '{"schema":"%s","requested_at":"%s","requested_by_pid":%s}\n' \
    "$REIN_SEAT_STOP_SCHEMA" "2020-01-01T00:00:00Z" "$$" >"$ST_RUNTIME/$REIN_SEAT_STOP_BASENAME"
  # No cap -- sitting down with this marker still in place makes the seat step down at the first
  # attach return with exit 0 (the two sides are distinguishable this way).
  ST_MAX_ATTACH=0
  ST_WAIT_TIMEOUT=2
  st_run_seat
  unset ST_MAX_ATTACH ST_WAIT_TIMEOUT
  if st_expect_status "never steps down on an old marker with a reused pid" 1; then
    case "$ST_OUT" in
      *"rein down shut the lineage down"*)
        st_fail "never steps down on a stop that was never triggered" "$ST_OUT"
        ;;
      *"waiting for a handover"*) st_ok ;;
      *) st_fail "drops the old marker and enters the wait" "$ST_OUT" ;;
    esac
    st_expect_true "clears a marker outside the window before sitting down" test ! -e "$ST_RUNTIME/$REIN_SEAT_STOP_BASENAME"
  fi

  # The window's width comes from settings (the cap from `down` dropping the marker to it
  # finishing = cmd_timeout_sec + stop_timeout_sec). With a total of 1200 seconds configured, a
  # marker from 300 seconds ago is still inside the window -- left in place and consumed. With the
  # default (60 + 60), the same marker is outside it, so this also confirms the width tracks the
  # config.
  case_dir="$tmp/seat-stop-grace-from-config"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "still-here" "$ST_CWD" 1
  printf '{"schema":"%s","requested_at":"%s","requested_by_pid":%s}\n' \
    "$REIN_SEAT_STOP_SCHEMA" \
    "$(date -u -r "$(($(rein_now_epoch) - 300))" +%Y-%m-%dT%H:%M:%SZ)" "$$" \
    >"$ST_RUNTIME/$REIN_SEAT_STOP_BASENAME"
  ST_CMD_TIMEOUT=600
  ST_STOP_TIMEOUT=600
  ST_MAX_ATTACH=0
  ST_WAIT_TIMEOUT=2
  st_run_seat
  unset ST_CMD_TIMEOUT ST_STOP_TIMEOUT ST_MAX_ATTACH ST_WAIT_TIMEOUT
  if st_expect_status "leaves the same marker in place and consumes it once the window is widened" 0; then
    case "$ST_OUT" in
      *"rein down shut the lineage down"*) st_ok ;;
      *) st_fail "leaves a marker inside a config-widened window in place" "$ST_OUT" ;;
    esac
    st_expect_true "gone after being consumed" test ! -e "$ST_RUNTIME/$REIN_SEAT_STOP_BASENAME"
  fi

  # A file that doesn't match the contract's format is never consumed as the marker (never let
  # something with just a matching name make the seat step down silently).
  case_dir="$tmp/seat-stop-not-contract"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "still-here" "$ST_CWD" 1
  printf '{"schema":"rein.seat-stop.v0","requested_at":"2026-01-01T00:00:00Z","requested_by_pid":1}\n' \
    >"$ST_CWD/seat-stop-bad.json"
  ST_ATTACH_CP_SRC="$ST_CWD/seat-stop-bad.json"
  ST_ATTACH_CP_DST="$ST_RUNTIME/$REIN_SEAT_STOP_BASENAME"
  ST_MAX_ATTACH=0
  st_run_seat
  unset ST_ATTACH_CP_SRC ST_ATTACH_CP_DST ST_MAX_ATTACH
  if st_expect_status "never steps down on a marker that does not match the contract's format" 1; then
    case "$ST_OUT" in
      *"waiting for a handover"*) st_ok ;;
      *) st_fail "ignores a marker in the wrong format and enters the wait" "$ST_OUT" ;;
    esac
    st_expect_true "never clears a marker it did not consume" test -f "$ST_RUNTIME/$REIN_SEAT_STOP_BASENAME"
  fi

  # The marker is dropped **before** the external stop, so a waiting seat notices it that same
  # round too and steps down quietly (missing it and continuing to wait would ring a failure
  # right after the primary session disappears).
  case_dir="$tmp/seat-stop-while-waiting"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "still-here" "$ST_CWD" 1
  printf '{"schema":"%s","requested_at":"%s","requested_by_pid":%s}\n' \
    "$REIN_SEAT_STOP_SCHEMA" "$(rein_iso_now)" "$$" >"$ST_CWD/seat-stop.json"
  ST_MAX_ATTACH=0
  ST_WAIT_TIMEOUT=5
  # One round is set long because a wait for an absent watcher ends after WATCHER_ABSENT_LIMIT
  # rounds -- the marker needs to be reliably slipped in inside that window.
  ST_POLL_INTERVAL=1
  # Entering the wait shows up as a heartbeat notification (which only ever fires from inside the
  # wait loop). The 8-second cap is longer than the 5-second wait cap (st_copy_after_notify's
  # rule).
  st_copy_after_notify "the watcher may have stopped" \
    "$ST_CWD/seat-stop.json" "$ST_RUNTIME/$REIN_SEAT_STOP_BASENAME" 8 &
  st_run_seat
  wait
  unset ST_MAX_ATTACH ST_WAIT_TIMEOUT ST_POLL_INTERVAL
  if st_expect_status "steps down with exit 0 even for a marker dropped mid-wait" 0; then
    case "$ST_OUT" in
      *"rein down shut the lineage down"*) st_ok ;;
      *) st_fail "reports the shutdown for a marker dropped mid-wait" "$ST_OUT" ;;
    esac
    st_expect_true "clears a marker consumed mid-wait too" test ! -e "$ST_RUNTIME/$REIN_SEAT_STOP_BASENAME"
  fi

  # The outcome splits on whether the marker is present. `down` drops the marker **before**
  # externally stopping the primary session, so a form where the marker is present and the target
  # has already dropped out of enumeration is **an intended stop** (the seat steps down quietly).
  # The same shape with the marker missing is a real failure (non-zero + notification, as before).
  # The marker is the only distinguishing material, so both sides are checked.
  case_dir="$tmp/stop-mark-before-handle"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_POINTER" "gone-1" "successor" "$ST_CWD" 1
  printf '{"schema":"%s","requested_at":"%s","requested_by_pid":%s}\n' \
    "$REIN_SEAT_STOP_SCHEMA" "$(rein_iso_now)" "$$" >"$ST_RUNTIME/$REIN_SEAT_STOP_BASENAME"
  st_run_seat
  if st_expect_status "steps down quietly with exit 0 even if the target has dropped out of enumeration, when the marker is present" 0; then
    case "$ST_OUT" in
      *"rein down shut the lineage down"*) st_ok ;;
      *) st_fail "prints one line to the terminal for the shutdown" "$ST_OUT" ;;
    esac
    if [ "$(rein_st_calls_total "$ST_NOTIFY")" -eq 0 ]; then
      st_ok
    else
      st_fail "never notifies on an intended stop" "$(cat "$ST_NOTIFY")"
    fi
    st_expect_true "consumes and clears the marker" test ! -e "$ST_RUNTIME/$REIN_SEAT_STOP_BASENAME"
  fi

  # The control (no marker = a real failure): non-zero + notification, as before.
  case_dir="$tmp/no-stop-mark-before-handle"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_POINTER" "gone-1" "successor" "$ST_CWD" 1
  st_run_seat
  st_expect_pointer_error "rings absence from enumeration as a failure when there is no marker" \
    "session gone-1 is not in the claude agents --json enumeration"

  # A round that fails to clear the marker never says "shut down" (since only the seat clears
  # it, an uncleared marker is consumed silently by whichever seat sits down next, on its first
  # attach return).
  case_dir="$tmp/seat-stop-unremovable"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "still-here" "$ST_CWD" 1
  printf '{"schema":"%s","requested_at":"%s","requested_by_pid":%s}\n' \
    "$REIN_SEAT_STOP_SCHEMA" "$(rein_iso_now)" "$$" >"$ST_RUNTIME/$REIN_SEAT_STOP_BASENAME"
  chflags uchg "$ST_RUNTIME/$REIN_SEAT_STOP_BASENAME"
  ST_MAX_ATTACH=0
  st_run_seat
  chflags nouchg "$ST_RUNTIME/$REIN_SEAT_STOP_BASENAME"
  unset ST_MAX_ATTACH
  if st_expect_status "steps down non-zero when the marker cannot be cleared" 1; then
    case "$ST_OUT" in
      *"rein down shut the lineage down"*)
        st_fail "never says \"shut down\" for a marker it could not clear" "$ST_OUT"
        ;;
      *) st_ok ;;
    esac
    st_expect_notify "notifies that the marker cannot be cleared" "rein: cannot keep the seat" \
      "$ST_RUNTIME/$REIN_SEAT_STOP_BASENAME" && st_ok
  fi
  rm -f "$ST_RUNTIME/$REIN_SEAT_STOP_BASENAME"

  # Deadlines are measured on a process-local monotonic clock, so the cap never moves just
  # because the wall clock does.

  # Uses the `date` shim to advance the wall clock while measuring the cap on a wait for a
  # handover. Measuring the cap on the wall clock would read "cap reached" on the very first
  # round that reads the advanced clock, stepping down before the configured number of seconds
  # ever elapsed (and, in reverse, a clock set back would stretch the cap by that much).
  # The heartbeat check is turned off for this run (`0` = never checked) -- with the wall clock
  # advanced, no heartbeat could ever read as fresh, so the wait would give up on watcher absence
  # within a few rounds, and the side that waits all the way to the cap could never be measured.
  # The freshness side (comparing against an mtime on disk, correctly staying on the wall clock)
  # is checked by the next case.
  case_dir="$tmp/monotonic-wait"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "still-here" "$ST_CWD" 1
  : >"$ST_RUNTIME/$REIN_HEARTBEAT_BASENAME"
  ST_BROKEN_BIN="$ST_CWD/clock-shim"
  st_write_clock_shim "$ST_BROKEN_BIN" "$ST_CWD/clock-shim.count"
  ST_MAX_ATTACH=0
  ST_WAIT_TIMEOUT=5
  ST_HEARTBEAT_MAX_AGE=0
  st_clock_started="$(rein_now_epoch)"
  st_run_seat
  st_clock_elapsed="$(($(rein_now_epoch) - st_clock_started))"
  unset ST_BROKEN_BIN ST_MAX_ATTACH ST_WAIT_TIMEOUT ST_HEARTBEAT_MAX_AGE
  if st_expect_status "gives up on waiting for a handover at the cap" 1; then
    if st_expect_notify "logs the cap as the reason" "rein: cannot keep the seat" \
      "the current pointer did not change for 5 seconds"; then
      st_ok
    fi
    if [ "$st_clock_elapsed" -ge 4 ]; then
      st_ok
    else
      st_fail "the wait cap for a handover never shrinks just because the wall clock advances" \
        "real elapsed time: ${st_clock_elapsed} seconds (cap 5 seconds)"
    fi
  fi

  # A heartbeat's freshness is measured **on the wall clock, as-is** (it's compared against an
  # mtime on disk, so a monotonic clock wouldn't even make sense here). With the wall clock
  # advanced, even a freshly dropped heartbeat reads as "old," so watcher absence persists and the
  # wait gives up before the cap. A round that ends up waiting all the way to the cap is a
  # regression on the deadline side, so this also divides by **how many times the wall clock was
  # read** (dividing by real elapsed time would let a load-delayed round that took cap-length time
  # for 3 rounds look identical to a regression, turning red only right at the boundary). The cap
  # is set far past the number of rounds give-up actually needs (3 rounds of heartbeat absence) --
  # a round that waits all the way to the cap differs from that by an order of magnitude in read
  # count.
  case_dir="$tmp/heartbeat-age-wall-clock"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "still-here" "$ST_CWD" 1
  : >"$ST_RUNTIME/$REIN_HEARTBEAT_BASENAME"
  ST_BROKEN_BIN="$ST_CWD/clock-shim"
  st_write_clock_shim "$ST_BROKEN_BIN" "$ST_CWD/clock-shim.count"
  ST_MAX_ATTACH=0
  ST_WAIT_TIMEOUT=60
  st_run_seat
  st_clock_calls="$(cat "$ST_CWD/clock-shim.count" 2>/dev/null)"
  unset ST_BROKEN_BIN ST_MAX_ATTACH ST_WAIT_TIMEOUT
  if st_expect_status "steps down non-zero even on a heartbeat stale by the wall clock" 1; then
    if [ "$(st_count_notify "the watcher may have stopped")" -ge 1 ]; then
      st_ok
    else
      st_fail "heartbeat freshness stays on the wall clock" "$(cat "$ST_NOTIFY")"
    fi
    if st_expect_notify "gives up on the wait once it stays stale" "rein: cannot keep the seat" \
      "the watcher's heartbeat has not been updated for 3 consecutive rounds"; then
      st_ok
    fi
    # Giving up takes effect at round 3 -- the wall clock is read exactly 3 times (observed). A
    # round that waited all the way to the cap (60 seconds) would reach 60 reads even at one
    # second per round.
    if [ -n "$st_clock_calls" ] && [ "$st_clock_calls" -lt 20 ]; then
      st_ok
    else
      st_fail "giving up takes effect before the wait cap" \
        "the wall clock was read ${st_clock_calls:-0} times (that many rounds reaches the 60-second cap)"
    fi
  fi

  # The seat's own log: only the attach loop writes it; the user and rein status read it.

  # The accepting side: one seat taking one attach leaves the three life-cycle lines, in order.
  case_dir="$tmp/seat-log-attached"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "successor" "$ST_CWD" 5
  st_run_seat
  if st_expect_status "an attach with logging ends at exit 0" 0; then
    st_expect_seat_log_line "logs the start of attach" attach_started "attaching to session seat-1"
    if [ "$(jq -r '.successor_session_id' "$ST_SEAT_LOG" 2>/dev/null | tail -1)" = "seat-1" ] &&
      [ "$(jq -r '.generation' "$ST_SEAT_LOG" 2>/dev/null | tail -1)" = "5" ]; then
      st_ok
    else
      st_fail "includes the target session and generation in the record" "$(cat "$ST_SEAT_LOG" 2>/dev/null)"
    fi
    # **The order is the reader's whole contract.** `rein status` answers "is the seat connected
    # right now" by taking whichever life-cycle line came last, so the sequence has to be exactly
    # this: the seat announces itself before it can attach to anything, and the closing line comes
    # after the attach it closes. Pinned as the exact sequence rather than a line count, so that
    # dropping one of the three, or writing them out of order, cannot pass.
    st_expect_true "the log is append-only, one life-cycle line per step, in order" \
      test "$(st_seat_log_events)" = "seated attach_started attach_ended "
    # The closing line names the session the seat has just left. Without it the last line is
    # `attach_started` for as long as the seat sits between attaches -- a wait for a handover has
    # no time limit -- and the reader would keep reporting a connection that does not exist.
    st_expect_seat_log_line "logs that attach returned, naming the session it left" \
      attach_ended "from session seat-1"
    if [ "$(jq -r 'select(.event == "attach_ended") | .successor_session_id' "$ST_SEAT_LOG" 2>/dev/null | tail -1)" = "seat-1" ]; then
      st_ok
    else
      st_fail "the closing line carries the session in the same column" "$(cat "$ST_SEAT_LOG" 2>/dev/null)"
    fi
    # Sitting down is its own line, so a seat that has not attached yet cannot be read as still
    # holding whatever the previous seat was connected to (the log outlives the process).
    st_expect_seat_log_line "logs that a seat sat down" seated "has not entered attach yet"
  fi

  # A round where attach returns non-zero logs rc and the retry count, and finally the reason it
  # failed.
  case_dir="$tmp/seat-log-attach-failed"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "successor" "$ST_CWD" 1
  ST_ATTACH_EXIT=7
  ST_ATTACH_RETRY_MAX=1
  ST_MAX_ATTACH=0
  st_run_seat
  unset ST_ATTACH_EXIT ST_ATTACH_RETRY_MAX ST_MAX_ATTACH
  if st_expect_status "logs an attach failure too before it fails" 1; then
    st_expect_seat_log_line "logs a non-zero attach with its rc" attach_failed "rc=7"
    st_expect_seat_log_line "logs how many retries it took" attach_failed "after 1 retries"
    st_expect_seat_log_line "logs the reason it failed" seat_failed "claude attach failed"
  fi

  # Every failure path goes through the same route (seat_fail logs in one place) -- confirms the
  # reason is still logged even for an unreadable pointer.
  case_dir="$tmp/seat-log-pointer-error"
  st_setup_case "$case_dir"
  printf '{"schema":\n' >"$ST_POINTER"
  st_run_seat
  if st_expect_status "logs the reason it failed even for a broken pointer" 1; then
    st_expect_seat_log_line "logs the pointer's own reason too" seat_failed "broken JSON"
  fi

  # The heartbeat warning (only ever produced mid-wait) is logged too.
  case_dir="$tmp/seat-log-heartbeat"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "still-here" "$ST_CWD" 1
  ST_MAX_ATTACH=0
  ST_WAIT_TIMEOUT=2
  st_run_seat
  unset ST_MAX_ATTACH ST_WAIT_TIMEOUT
  st_expect_seat_log_line "logs the heartbeat warning" heartbeat_warned "the watcher may have stopped"

  # A round that steps down quietly from the marker is logged too (no notification since the user
  # triggered the stop, but it still goes into the log).
  case_dir="$tmp/seat-log-stopped"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "successor" "$ST_CWD" 1
  printf '{"schema":"%s","requested_at":"%s","requested_by_pid":%s}\n' \
    "$REIN_SEAT_STOP_SCHEMA" "$(rein_iso_now)" "1" >"$ST_RUNTIME/$REIN_SEAT_STOP_BASENAME"
  ST_MAX_ATTACH=0
  st_run_seat
  unset ST_MAX_ATTACH
  if st_expect_status "a round that steps down from the marker also ends at exit 0" 0; then
    st_expect_seat_log_line "logs stepping down from the marker" seat_stopped "rein down shut the lineage down" # lineage-cmd-exempt: pins the needle for the event described above
  fi

  # A seating refusal (another seat is present) is logged too. The owner is set to this test
  # process itself (without a live pid, it would be reclaimed as a leftover and never actually
  # exercise the refusal path).
  case_dir="$tmp/seat-log-occupied"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "successor" "$ST_CWD" 1
  rein_claim_lock_dir "$ST_RUNTIME/$REIN_SEAT_LOCK_DIRNAME" \
    start "$(rein_process_start_identity "$$")" cwd "$ST_CWD" token "st-occupied"
  st_run_seat
  rein_release_lock_dir "$ST_RUNTIME/$REIN_SEAT_LOCK_DIRNAME"
  if st_expect_status "never sits down while the seat is occupied" 1; then
    st_expect_seat_log_line "logs the seating refusal" seat_occupied "an attach loop is already seated"
  fi

  # The seat keeps going even when it can't write its log (the log is an observation and never
  # takes priority over keeping the seat). This blocks the location with a directory to make
  # writing fail.
  case_dir="$tmp/seat-log-unwritable"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "successor" "$ST_CWD" 1
  mkdir -p "$ST_SEAT_LOG"
  st_run_seat
  if st_expect_status "attach still goes through even when the log can't be written" 0; then
    if rein_st_has_call "$ST_LOG" attach job-seat-1; then
      st_ok
    else
      st_fail "attaches even on a round the log can't be written" "$(cat "$ST_LOG")"
    fi
    case "$ST_OUT" in
      *"cannot write to the seat log"*) st_ok ;;
      *) st_fail "prints the failure to write to stderr" "$ST_OUT" ;;
    esac
  fi
  rmdir "$ST_SEAT_LOG"

  # An explicit empty value on a CLI flag is never silently folded into "unspecified" (the only
  # way to disable it stays config unset).
  case_dir="$tmp/empty-runtime-dir"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_POINTER" "seat-1" "successor" "$ST_CWD" 1
  ST_RUNTIME_ARGS=(--runtime-dir "")
  st_run_seat
  if st_expect_status "never starts on an empty --runtime-dir" 2; then
    case "$ST_OUT" in
      *"cannot take an empty value"*"config unset --user runtime_dir or config unset --project runtime_dir"*)
        if [ -s "$ST_LOG" ]; then
          st_fail "never calls claude with an empty value" "$(cat "$ST_LOG")"
        else
          st_ok
        fi
        ;;
      *)
        st_fail "prints the reason for the empty value" "${ST_OUT}"
        ;;
    esac
  fi

  # A value-taking flag missing its value ends with a reason, then exit 2 (never a completely silent
  # non-zero -- the user couldn't even tell whether they got seated). This checks all three
  # value-taking flags -- checking only one would let a typo on the others fail silently.
  st_missing_value_case "rejects --cwd with no value, with a reason" "--cwd requires a value" --cwd
  st_missing_value_case "rejects --max-attach with no value, with a reason" \
    "--max-attach requires a value" --cwd "$tmp" --max-attach
  st_missing_value_case "rejects --runtime-dir with no value, with a reason" \
    "--runtime-dir requires a value" --runtime-dir
  # An explicit empty value is never folded into "unspecified" either (folding it would send
  # `--cwd ""` to the shell's own cwd's lineage instead of the intended target). Only
  # --runtime-dir, which has a config-layer key, also prints the hint for how to disable it (the
  # wording's canonical source is the config layer -- never duplicated here).
  st_missing_value_case "rejects an empty --cwd, with a reason" \
    "--cwd cannot take an empty value (not treated as unspecified)" --cwd ""
  st_missing_value_case "rejects an empty --max-attach, with a reason" \
    "--max-attach cannot take an empty value (not treated as unspecified)" --cwd "$tmp" --max-attach ""
  # --cwd left out entirely fails for a different reason (the startup required-field check) --
  # confirms the empty-value check hasn't swallowed "not given at all" too.
  st_missing_value_case "an unspecified --cwd fails for the required-field reason" "--cwd is required" --max-attach 1

  # Printing usage is also an execution path (bash 3.2 crashes when multibyte text follows a
  # variable expansion immediately).
  st_usage_case "prints usage on --help" 0 --help
  st_usage_case "rejects an unknown argument, with usage" 2 --bogus

  # Where the bundled library lives: never delegated to an external command's result.

  # Recreates the attack shape directly: puts a `dirname` that returns empty at the front of
  # PATH, and launches with the current directory set to one carrying a planted
  # `lib/rein-common.sh`. Deciding the location via `$(cd "$(dirname ...)" && pwd)` would let
  # `cd ""` succeed as a no-op, leaving the working directory unchanged, so the trap runs
  # **inside this very process** (observed: exits with the trap's own exit code, 77). This uses
  # the exit code to confirm what's actually read is the bundled real file.
  case_dir="$tmp/lib-path-hijack"
  st_setup_case "$case_dir"
  mkdir -p "$ST_CWD/hijack-bin" "$ST_CWD/lib"
  printf '#!/bin/sh\nprintf ""\n' >"$ST_CWD/hijack-bin/dirname"
  chmod +x "$ST_CWD/hijack-bin/dirname"
  printf 'exit 77\n' >"$ST_CWD/lib/rein-common.sh"
  hijack_out="$(cd "$ST_CWD" && env "${ST_ENV_ARGS[@]}" REIN_NOTIFY_SILENT=1 \
    PATH="$ST_CWD/hijack-bin:$PATH" "$REIN_ST_BASH" "$SCRIPT_PATH" --cwd "$ST_CWD" 2>&1 </dev/null)"
  hijack_rc=$?
  rm -rf "${ST_CWD:?}/lib" "${ST_CWD:?}/hijack-bin"
  if [ "$hijack_rc" -eq 77 ]; then
    st_fail "never loads a same-named library from the working directory" \
      "the trap ran (rc=77): ${hijack_out}"
  else
    st_ok
  fi

  # A relative-path launch is the legitimate path (what the development guide has people type),
  # so this passes rather than failing. Dropping the working-directory prepend would leave the
  # location as just the word `rein-seat.sh`, unable to find the bundled library -- this one case
  # catches that regression. `--help` itself never notifies, but environment isolation (never
  # reading the real HOME or the real config) is kept consistent with the other entry points.
  hijack_out="$(cd "$SCRIPT_DIR" && env "${ST_ENV_ARGS[@]}" REIN_NOTIFY_SILENT=1 \
    "$REIN_ST_BASH" "$SCRIPT_NAME" --help 2>&1 </dev/null)"
  hijack_rc=$?
  if [ "$hijack_rc" -ne 0 ]; then
    st_fail "a relative-path launch also passes" "exit=${hijack_rc} (expected 0): ${hijack_out}"
  else
    case "$hijack_out" in
      *"usage:"*) st_ok ;;
      *) st_fail "a relative-path launch prints usage" "${hijack_out}" ;;
    esac
  fi

}

# The section that measures the test scaffolding itself (how the process fixture is started, and
# the contract that a cleanup failure reaches the final non-zero). This runs before the main
# section because if the scaffolding is broken, it changes how the main section's own failures
# should be read -- separating "the fixture never started" from "the implementation actually
# failed" has to happen first.
st_section_safe() {
  st_cooperative_holder_lifecycle_case
  st_cleanup_failure_case
}

selftest() {
  local tmp case_dir tool st_clock_started st_clock_elapsed st_clock_calls
  local heartbeat_out hijack_out hijack_rc st_flip_pid
  local seat_records_outside seat_records_before
  # shellcheck source-path=SCRIPTDIR
  # shellcheck source=lib/rein-selftest-sections.sh
  . "$SCRIPT_DIR/lib/rein-selftest-sections.sh"
  rein_st_sections_parse "$@" || return $?
  if [ "$REIN_ST_SECTION_MODE" = "list" ]; then
    rein_st_sections_print_list
    return 0
  fi
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/rein-seat-selftest.XXXXXX")" || {
    printf '%s: selftest 0 pass / 1 fail\n' "$SCRIPT_NAME"
    return 1
  }
  ST_TMPDIR="$tmp"
  trap st_cleanup EXIT

  # shellcheck source-path=SCRIPTDIR
  # shellcheck source=lib/rein-selftest-fixtures.sh
  . "$SCRIPT_DIR/lib/rein-selftest-fixtures.sh"

  ST_BIN="$tmp/bin"
  rein_st_write_fake_bin "$ST_BIN"

  rein_st_sections_run

  printf '%s: selftest %d pass / %d fail\n' "$SCRIPT_NAME" "$st_pass_count" "$st_fail_count"
  [ "$st_fail_count" -eq 0 ]
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --selftest)
        shift
        selftest "$@" # test-side-scope-exempt: the one line that launches selftest (not a production writer)
        return $?
        ;;
      --cwd)
        need_value "--cwd" $# "${2:-}" || return 2
        TARGET_CWD="$2"
        shift 2
        ;;
      --runtime-dir)
        check_opt "--runtime-dir" runtime_dir $# "${2:-}" || return 2
        RUNTIME_DIR_OPT="$2"
        shift 2
        ;;
      --max-attach)
        need_value "--max-attach" $# "${2:-}" || return 2
        MAX_ATTACH="$2"
        shift 2
        ;;
      --once)
        MAX_ATTACH=1
        shift
        ;;
      -h | --help)
        usage
        return 0
        ;;
      *)
        printf '%s: unknown argument: %s\n' "$SCRIPT_NAME" "$1" >&2
        usage >&2
        return 2
        ;;
    esac
  done
  run_seat
}

main "$@"
