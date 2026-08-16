# shellcheck shell=bash
# Implementation of `rein down` (shut the lineage down). By default stops the watcher and the
# primary session (two layers) and leaves the seat a marker so it goes down on its own.
# `--watcher-only` stops just the watcher.
# Not an executable script, so it doesn't get the execute bit (out of scope for the --selftest convention).

# Stops the watcher (by handing off a stop-request file).
# 0=stopped, or wasn't running to begin with / 1=couldn't stop it (reason already shown)
stop_watcher_layer() {
  local rc deadline remaining content alive_rc
  watcher_state "$RUNTIME_DIR"
  rc=$?
  case "$rc" in
    1)
      printf 'watcher is not running (%s)\n' "$WATCHER_REASON"
      # Even on the "not running" branch, it's not "stopped" until any leftover request file is
      # also checked -- leaving it there would make the next watcher to start go back down on
      # its very first loop.
      clear_stale_stop_request || return 1
      return 0
      ;;
    2)
      fail "$WATCHER_REASON"
      return 1
      ;;
  esac

  # Stopping is done by **handing off a request file**. This module never runs an OS
  # process-stop operation (kill / pkill / etc. -- an invariant of the contract), so the watcher
  # itself reads the request on its own loop and goes down. Ownership is verified (watcher_state)
  # first, so the stop request is never left for a reused PID.
  printf -v content '{"schema":"%s","requested_at":"%s","requested_by_pid":%s}' \
    "$REIN_STOP_REQUEST_SCHEMA" "$(rein_iso_now)" "$$"
  if ! rein_write_json_atomic "$STOP_REQUEST_FILE" "$content"; then
    fail "cannot write the stop request: ${STOP_REQUEST_FILE}"
    return 1
  fi

  # The pid disappearing alone isn't enough for success -- if the request file is still there,
  # the next watcher to start consumes the same request and immediately goes back down (the
  # state meant to be "stopped" would carry forward into the next run).
  # The deadline is measured on the monotonic clock (a wall clock would let the cap stretch or
  # shrink across a mid-run clock adjustment).
  deadline=$(($(rein_now_monotonic) + CMD_TIMEOUT_SEC))
  while :; do
    rein_pid_alive "$WATCHER_PID"
    alive_rc=$?
    # **Never collapses "gone" and "can't be confirmed" into the same exit.** Collapsing them
    # would report "stopped" even on a run where liveness can't be confirmed, letting the next
    # `up` pile a new watcher on top of one that's still alive.
    if [ "$alive_rc" -eq 1 ] && [ ! -f "$STOP_REQUEST_FILE" ]; then
      break
    fi
    remaining=$((deadline - $(rein_now_monotonic)))
    if [ "$remaining" -le 0 ]; then
      if [ "$alive_rc" -eq 2 ]; then
        fail "ps is not answering, so it can't be confirmed whether watcher (pid=${WATCHER_PID}) went down (stop request: ${STOP_REQUEST_FILE}. watcher log: ${RECORDS_DIR}/${REIN_WATCHER_LOG_BASENAME})"
        return 1
      fi
      if [ "$alive_rc" -eq 0 ]; then
        fail "placed the stop request, but watcher (pid=${WATCHER_PID}) is still there (the stop request is still there: ${STOP_REQUEST_FILE}. this module never stops a process directly. watcher log: ${RECORDS_DIR}/${REIN_WATCHER_LOG_BASENAME})"
        return 1
      fi
      fail "watcher (pid=${WATCHER_PID}) is gone, but the stop request is still there (it may have exited before accepting it -- check ${STOP_REQUEST_FILE} so the next start doesn't go straight back down)"
      return 1
    fi
    rein_sleep_capped "$POLL_INTERVAL_SEC" "$remaining"
  done
  printf 'watcher stopped (pid=%s)\n' "$WATCHER_PID"
  return 0
}

# The seat-stop marker. When attach returns, the attach loop quietly exits with 0 if this is
# there. Written only by this verb (only the seat reads and consumes it) -- a one-way handoff,
# same as the stop request.
write_seat_stop_mark() {
  local content
  printf -v content '{"schema":"%s","requested_at":"%s","requested_by_pid":%s}' \
    "$REIN_SEAT_STOP_SCHEMA" "$(rein_iso_now)" "$$"
  if ! rein_write_json_atomic "$SEAT_STOP_FILE" "$content"; then
    fail "cannot write the seat-stop marker: ${SEAT_STOP_FILE}"
    return 1
  fi
  return 0
}

# Waits for an externally-stopped primary session to drop out of enumeration. Doesn't reuse the
# watcher's own `wait_for_exit` -- that function belongs to the handover path and folds in
# refreshing the heartbeat as it goes (the CLI is never a heartbeat writer).
# 0=gone / 1=still there when the deadline hits / 2=couldn't read the enumeration, undetermined
wait_session_gone() {
  local session_id="$1" deadline now rc
  # The deadline is measured on the monotonic clock (a wall clock would let the cap stretch or
  # shrink across a mid-run clock adjustment).
  deadline=$(($(rein_now_monotonic) + STOP_TIMEOUT_SEC))
  while :; do
    rein_is_session_live "$session_id"
    rc=$?
    if [ "$rc" -eq 1 ]; then
      return 0
    fi
    if [ "$rc" -eq 2 ]; then
      return 2
    fi
    now="$(rein_now_monotonic)"
    # Treats hitting the deadline exactly the same as exceeding it (`>` would sleep once more
    # even at a zero-second cap, stretching the cap by one extra poll).
    if [ "$now" -ge "$deadline" ]; then
      return 1
    fi
    rein_sleep_capped "$POLL_INTERVAL_SEC" "$((deadline - now))"
  done
}

# Stops the primary session (an external stop). Places the seat-stop marker before stopping --
# placing it after would open a window where a seat whose attach just returned reads no marker
# there and reports the intentional stop as an anomaly.
# 0=stopped, or wasn't there to begin with / 1=couldn't fully stop it (reason already shown)
stop_main_session_layer() {
  local rc handle handle_rc stop_rc
  main_session_state
  rc=$?
  case "$rc" in
    1)
      printf 'no primary session (%s)\n' "$MAIN_SESSION_REASON"
      return 0
      ;;
    2)
      fail "$MAIN_SESSION_REASON"
      return 1
      ;;
  esac

  printf 'stopping primary session %s (%s)\n' "$MAIN_SESSION_ID" "${MAIN_SESSION_NAME:-unnamed}"
  if find_seat_pid; then
    printf 'seat is attached (pid=%s). Stopping the primary session makes attach return, and the seat will go down on its own\n' "$SEAT_PID"
  fi

  # What gets passed to the stop is the short job ID resolved from enumeration (the CLI doesn't
  # accept the full session_id). An interactive session has no short job ID -- meaning no way to
  # stop it externally -- so this doesn't silently report success.
  handle="$(rein_resolve_job_handle "$MAIN_SESSION_ID")"
  handle_rc=$?
  if [ "$handle_rc" -ne 0 ]; then
    fail "cannot stop the primary session: $(rein_job_handle_error "$MAIN_SESSION_ID" "$handle_rc")"
    return 1
  fi
  # A lineage with no runtime directory has no seat either (the attach lock only ever gets
  # created under it) -- a marker with nobody to read it is never left behind, and the location
  # is never created just to hold one as a side effect of stopping.
  if [ -d "$RUNTIME_DIR" ]; then
    write_seat_stop_mark || return 1
  fi
  (cd "$TARGET_CWD" && rein_run_capture "$CMD_TIMEOUT_SEC" claude stop "$handle" >/dev/null)
  stop_rc=$?
  if [ "$stop_rc" -ne 0 ]; then
    fail "claude stop exited non-zero: $(rein_command_failure_detail "$stop_rc")"
    return 1
  fi
  # Doesn't collapse "can't read the enumeration (undetermined)" into "stopping didn't make it go
  # away" -- collapsing them would report a run where the CLI is simply broken as a different
  # kind of failure. The marker is left in place -- same discipline as the stop request: the
  # next `up` clears it, before the next seat attaches.
  wait_session_gone "$MAIN_SESSION_ID"
  rc=$?
  case "$rc" in
    1)
      fail "claude stop succeeded, but primary session ${MAIN_SESSION_ID} didn't drop out of enumeration within ${STOP_TIMEOUT_SEC} seconds"
      return 1
      ;;
    2)
      fail "$(rein_list_agents_error) (while confirming exit after external stop)"
      return 1
      ;;
  esac
  printf 'primary session stopped: %s\n' "$MAIN_SESSION_ID"
  return 0
}

cmd_down() {
  local watcher_only=0 rc
  while [ $# -gt 0 ]; do
    case "$1" in
      --watcher-only)
        watcher_only=1
        shift
        ;;
      *)
        take_verb_opt "$@"
        rc=$?
        case "$rc" in
          0) shift "$VERB_SHIFT" ;;
          2) return 2 ;;
          *)
            fail_usage "unknown argument to down: $1"
            return 2
            ;;
        esac
        ;;
    esac
  done

  prepare_runtime || return 1
  require_prerequisites || return 1
  # A lineage with no location has neither a watcher nor a seat (the watcher lock, the attach
  # lock, and the operation lock can only ever exist under it), so the watcher layer just
  # reports that and stops here -- stopping never creates the location as a side effect (the rule
  # that a read-only verb never produces the location). **The primary-session layer is never
  # skipped** -- the current pointer lives on the records side, independent of the runtime
  # directory, so "there's no location" and "there's no primary session" are different facts
  # (silently skipping a layer would make a partial shutdown read as a full one).
  if [ -d "$RUNTIME_DIR" ]; then
    verify_runtime_owner_or_fail || return 1
    acquire_op_lock || return 1
    # Stops the watcher before the primary session (the reason for the order): if a handover
    # runs while the stop is still in progress, a successor starts up and the lineage can't be
    # shut down.
    stop_watcher_layer || return 1
  else
    printf 'watcher is not running (no runtime data location: %s)\n' "$RUNTIME_DIR"
  fi
  if [ "$watcher_only" -eq 1 ]; then
    report_seat_if_present
    return 0
  fi
  stop_main_session_layer || return 1
  return 0
}

# `--watcher-only` never stops the seat (it's a separate thing from the watcher -- the user's
# own terminal). It only reports its presence and leaves how to step away to the user.
report_seat_if_present() {
  if find_seat_pid; then
    printf 'seat is attached (pid=%s). Press Ctrl-C in the terminal to step away\n' "$SEAT_PID"
  fi
  return 0
}
