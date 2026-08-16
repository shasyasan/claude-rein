# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034  # selftest state is shared across sections (the caller selftest()'s locals, and the ST_* globals)
# A rejection must not stop the resident watcher; startup must refuse to launch where a prerequisite tool doesn't work; numeric settings get validated.
# Variables are shared with the caller selftest()'s locals through dynamic scope. Declaring a
# local inside a section would hide it from later sections, so this section file declares none.
# Not an executable script, so it carries no execute bit (outside the --selftest convention).

st_section_startup() {
  # A rejection is a user input error: the resident watcher keeps running and hands over on
  # whatever correct marker arrives later.
  case_dir="$tmp/reject-keeps-watching"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "2026/08/15 04:12" "$ST_HANDOFF" "$ST_CWD"
  st_run_watcher_daemon_bg "$ST_DAEMON_GUARD_SEC"
  if st_wait_for_log '"event":"marker_rejected"'; then
    rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
    if st_wait_for_log '"event":"handover_completed"'; then
      st_ok
    else
      st_fail "keeps watching after a rejection" "did not hand over on the later marker: $(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    fi
    # The heartbeat advances on every poll (the attach loop uses this freshness to tell whether
    # the watcher has stopped). **Never wait on the wall clock and compare** -- "sleep 1.2s then
    # reread" reads a stale value on a loaded machine whose polling cycle falls behind, and fails.
    # Wait until it advances (exit the moment it does) through the witness call instead.
    if st_witness_daemon_alive; then
      st_ok
    fi
  else
    st_fail "records a rejection" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME" 2>/dev/null)"
  fi
  # The heartbeat observation just above (watching the cycle advance directly) already serves as
  # the witness, so this doesn't witness a second time.
  st_alarm_watcher_daemon 0
  daemon_rc="$(cat "$ST_DAEMON_RC_FILE" 2>/dev/null)"
  # Cut off from outside by the alarm (128+SIGALRM=142) -- confirms the watcher did not exit on its own.
  if [ "$daemon_rc" = "142" ]; then
    st_ok
  else
    st_fail "a rejection does not end the resident watcher" "the watcher exited on its own with exit ${daemon_rc}: $(cat "$ST_DAEMON_OUT" 2>/dev/null)"
  fi

  # Where a prerequisite tool doesn't work, freshness validation rejects every marker for the
  # wrong reason (R1/R4/R6). Put a "present but broken" form on PATH (a GNU date/stat, a broken
  # jq/perl) and confirm startup fails.
  for tool in jq date stat perl; do
    case_dir="$tmp/missing-$tool"
    st_setup_case "$case_dir"
    ST_BROKEN_BIN="$tmp/broken-$tool"
    rein_st_write_broken_tool "$ST_BROKEN_BIN" "$tool"
    rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
    st_run_watcher
    unset ST_BROKEN_BIN
    st_expect_startup_reject "does not start when the prerequisite tool ${tool} doesn't work" "prerequisite tool"
  done

  # Numeric-setting validation. If sleep returns immediately on an invalid value, the loop never
  # waits and hammers the enumeration at full speed.
  case_dir="$tmp/bad-interval"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  ST_ARGS=(--interval abc)
  st_run_watcher
  unset ST_ARGS
  st_expect_startup_reject "does not start with a non-numeric --interval" "the setting value is invalid"

  case_dir="$tmp/zero-interval"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  ST_ARGS=(--interval 0)
  st_run_watcher
  unset ST_ARGS
  st_expect_startup_reject "does not start with a zero-second --interval" "the setting value is invalid"

  case_dir="$tmp/bad-exit-grace"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  ST_EXIT_GRACE=-1
  st_run_watcher
  unset ST_EXIT_GRACE
  st_expect_startup_reject "does not start with a negative grace period" "the setting value is invalid"

  # The accepting side: a correct fractional polling interval is accepted (is validation too
  # broad, rejecting even a legitimate value?).
  case_dir="$tmp/valid-interval"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  ST_ARGS=(--interval 0.3)
  ST_EXIT_AFTER_POLLS=2
  st_run_watcher
  unset ST_ARGS ST_EXIT_AFTER_POLLS
  if st_expect_status "accepts a fractional polling interval" 0; then
    if st_log_has '"event":"handover_completed"'; then
      st_ok
    else
      st_fail "handover goes through with a fractional polling interval" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    fi
  fi

}
