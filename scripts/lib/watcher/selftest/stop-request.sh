# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034  # selftest state is shared across sections (the caller selftest()'s locals, and the ST_* globals)
# A stop request from `rein down` (accepted, malformed, undeletable), and the usage display.
# Variables are shared with the caller selftest()'s locals through dynamic scope. Declaring a
# local inside a section would hide it from later sections, so this section file declares none.
# Not an executable script, so it carries no execute bit (outside the --selftest convention).

st_section_stop_request() {
  # A stop request from `rein down`. Stopping happens by handing over a file (this module never
  # runs an OS process-stop operation itself). **Pin that it's checked after the marker too** --
  # an implementation that checks it first would let a handover request that arrived in the same
  # cycle go unprocessed while the watcher steps down.
  case_dir="$tmp/stop-request"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  printf '{"schema":"%s","requested_at":"%s","requested_by_pid":%s}\n' \
    "$REIN_STOP_REQUEST_SCHEMA" "$(rein_iso_now)" "$$" >"$ST_RUNTIME/$REIN_STOP_REQUEST_BASENAME"
  st_run_watcher_daemon_bg 8
  if st_wait_for_log '"event":"handover_completed"'; then
    st_ok
  else
    st_fail "processes the handover request before the stop request" "$(cat "$ST_DAEMON_OUT" 2>/dev/null)"
  fi
  wait "$ST_DAEMON_PID"
  daemon_rc="$(cat "$ST_DAEMON_RC_FILE" 2>/dev/null)"
  # 142 means cut off from outside by the alarm -- it did not step down on its own.
  if [ "$daemon_rc" = "0" ]; then
    st_ok
  else
    st_fail "ends monitoring on a stop request" \
      "exit=${daemon_rc}: $(cat "$ST_DAEMON_OUT" 2>/dev/null)"
  fi
  if [ ! -e "$ST_RUNTIME/$REIN_STOP_REQUEST_BASENAME" ]; then
    st_ok
  else
    st_fail "consumes the stop request" "the request file is still there (the next startup will also stop on it)"
  fi
  if grep -q 'accepted the stop request and ending monitoring' "$ST_RECORDS/$REIN_WATCHER_LOG_BASENAME" 2>/dev/null; then
    st_ok
  else
    st_fail "leaves the reason for stopping in the watcher log" "$(cat "$ST_RECORDS/$REIN_WATCHER_LOG_BASENAME" 2>/dev/null)"
  fi

  # A stop request that isn't in the contracted shape is not accepted (an empty file whose name
  # just happens to match, a different schema, or a missing requesting pid stepping the watcher
  # down would mean the stop request's specification isn't acting as a boundary).
  # It's left in place with only the reason recorded, and monitoring continues (deleting it would
  # leave whoever placed it unable to tell it apart from acceptance).
  case_dir="$tmp/stop-request-invalid"
  st_setup_case "$case_dir"
  : >"$ST_RUNTIME/$REIN_STOP_REQUEST_BASENAME"
  st_run_watcher_daemon_bg "$ST_DAEMON_GUARD_SEC"
  if st_wait_for_watcher_log 'the stop request is not in the contracted shape, so it is not accepted'; then
    st_ok
  else
    st_fail "does not accept a malformed stop request" "$(cat "$ST_RECORDS/$REIN_WATCHER_LOG_BASENAME" 2>/dev/null)"
  fi
  st_alarm_watcher_daemon
  daemon_rc="$(cat "$ST_DAEMON_RC_FILE" 2>/dev/null)"
  # 142 = the mark of being cut off from outside. If it had stepped down on its own, an empty file
  # would have been enough to stop it.
  if [ "$daemon_rc" = "142" ]; then
    st_ok
  else
    st_fail "does not step down on a malformed stop request" "exit=${daemon_rc}: $(cat "$ST_DAEMON_OUT" 2>/dev/null)"
  fi
  if [ -f "$ST_RUNTIME/$REIN_STOP_REQUEST_BASENAME" ]; then
    st_ok
  else
    st_fail "does not delete a malformed stop request" "it disappeared in a way indistinguishable from acceptance"
  fi
  # A request differing only in schema version is the same story (never silently accept a future format change).
  case_dir="$tmp/stop-request-schema"
  st_setup_case "$case_dir"
  printf '{"schema":"rein.watcher-stop.v0","requested_at":"%s","requested_by_pid":%s}\n' \
    "$(rein_iso_now)" "$$" >"$ST_RUNTIME/$REIN_STOP_REQUEST_BASENAME"
  st_run_watcher_daemon_bg "$ST_DAEMON_GUARD_SEC"
  if st_wait_for_watcher_log 'the stop request is not in the contracted shape, so it is not accepted'; then
    st_ok
  else
    st_fail "does not accept a stop request with a different schema version" "$(cat "$ST_RECORDS/$REIN_WATCHER_LOG_BASENAME" 2>/dev/null)"
  fi
  st_alarm_watcher_daemon
  daemon_rc="$(cat "$ST_DAEMON_RC_FILE" 2>/dev/null)"
  if [ "$daemon_rc" = "142" ]; then
    st_ok
  else
    st_fail "does not step down on a stop request with a different schema version" "exit=${daemon_rc}: $(cat "$ST_DAEMON_OUT" 2>/dev/null)"
  fi

  # Stepping down without being able to delete the request means the next watcher started stops
  # right away on the same request (contract: delete the request before exiting). This must not
  # fall through to "stopped successfully" -- surface it as a mechanism error and end non-zero.
  case_dir="$tmp/stop-request-undeletable"
  st_setup_case "$case_dir"
  printf '{"schema":"%s","requested_at":"%s","requested_by_pid":%s}\n' \
    "$REIN_STOP_REQUEST_SCHEMA" "$(rein_iso_now)" "$$" >"$ST_RUNTIME/$REIN_STOP_REQUEST_BASENAME"
  # Build the undeletable shape with the immutable flag (the request file itself can't be deleted -- the directory holding it is still writable).
  if chflags uchg "$ST_RUNTIME/$REIN_STOP_REQUEST_BASENAME" 2>/dev/null; then
    st_run_watcher_daemon_bg 5
    wait "$ST_DAEMON_PID"
    daemon_rc="$(cat "$ST_DAEMON_RC_FILE" 2>/dev/null)"
    if [ "$daemon_rc" = "1" ]; then
      st_ok
    else
      st_fail "an undeletable stop request does not proceed to a successful stop" \
        "exit=${daemon_rc}: $(cat "$ST_DAEMON_OUT" 2>/dev/null)"
    fi
    if grep -q 'cannot delete the stop request file' "$ST_RECORDS/$REIN_WATCHER_LOG_BASENAME" 2>/dev/null; then
      st_ok
    else
      st_fail "leaves the reason for an undeletable stop request" "$(cat "$ST_RECORDS/$REIN_WATCHER_LOG_BASENAME" 2>/dev/null)"
    fi
    chflags nouchg "$ST_RUNTIME/$REIN_STOP_REQUEST_BASENAME" 2>/dev/null
  else
    st_fail "can build the undeletable-stop-request fixture" "chflags uchg does not work in this environment"
  fi

  # Printing usage is also an execution path (bash 3.2 crashes when multibyte text follows a
  # variable expansion immediately).
  st_usage_case "shows usage with --help" 0 --help
  st_usage_case "refuses an unknown argument with usage attached" 2 --bogus

}
