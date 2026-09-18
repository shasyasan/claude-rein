# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034  # selftest state is shared across sections (the caller selftest()'s locals, and the ST_* globals)
# A rejection must not stop the resident watcher; the resident watcher reports a lineage nobody is
# running; startup must refuse to launch where a prerequisite tool doesn't work; numeric settings
# get validated.
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

  # The gap nobody was watching. The pointer names a session, that session is gone, and no
  # handover request is ever coming -- so the watcher polls on forever and the lineage just sits
  # there. Measured once at about 7 hours of an unattended run with nothing running, and not one
  # line was written about it anywhere.
  case_dir="$tmp/lineage-gap"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_RECORDS/$REIN_POINTER_BASENAME" "pred-1" "predecessor" "$ST_CWD" 1
  # The finished shape: no pid and no status, so it shows up only under `--all` -- which is
  # exactly what the normal enumeration looks like once a session has ended.
  rein_st_write_agents_done "$ST_AGENTS" "$ST_CWD" "pred-1"
  ST_LINEAGE_IDLE=1
  st_run_watcher_daemon_bg "$ST_DAEMON_GUARD_SEC"
  if st_wait_for_log '"event":"lineage_idle"'; then
    st_ok
    # The notification and the log have to carry the same reason word for word (the same rule
    # every other reported event here follows).
    if st_wait_for_notify && st_expect_notify_matches_event "the gap raises a notification too" \
      "rein: nobody is running this lineage" "pred-1" "lineage_idle"; then
      st_ok
    fi
    # Reported once per dark spell. Repeating it every cycle would turn one gap into an unbounded
    # run of identical lines and notifications -- at a one-second threshold and a 0.2-second
    # poll, a per-cycle report would have piled up several by the time the next probe lands.
    idle_calls="$(rein_st_count_sub "$ST_LOG" agents)"
    if st_wait_for_agents_calls "$((idle_calls + 2))"; then
      if [ "$(jq -s -r '[ .[] | select(.event == "lineage_idle") ] | length' \
        "$ST_RECORDS/$REIN_LOG_BASENAME" 2>/dev/null)" = "1" ]; then
        st_ok
      else
        st_fail "reports the gap once, not once per cycle" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
      fi
    else
      st_fail "the gap watch keeps probing after it has reported" "agents calls=$(rein_st_count_sub "$ST_LOG" agents)"
    fi
    # Reporting a gap is not a reason to stop watching -- the successor may still be launched by
    # hand, and a watcher that stepped down here would take the automation with it.
    if st_witness_daemon_alive; then
      st_ok
    fi
  else
    st_fail "reports a lineage with no live session" \
      "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME" 2>/dev/null) / $(cat "$ST_DAEMON_OUT" 2>/dev/null)"
  fi
  st_alarm_watcher_daemon 0
  unset ST_LINEAGE_IDLE

  # The control side: the very same setup with the session still alive. Without this, a gap watch
  # that reported unconditionally would pass the case above.
  case_dir="$tmp/lineage-no-gap"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_RECORDS/$REIN_POINTER_BASENAME" "pred-1" "predecessor" "$ST_CWD" 1
  # The steady state after a turn finishes: state=done but status=idle and a pid -- alive. A gap
  # watch that read `state` alone would call this a gap every single time.
  rein_st_write_agents_idle "$ST_AGENTS" "$ST_CWD" "pred-1"
  ST_LINEAGE_IDLE=1
  st_run_watcher_daemon_bg "$ST_DAEMON_GUARD_SEC"
  if st_wait_for_agents_calls 2; then
    if [ "$(jq -s -r '[ .[] | select(.event == "lineage_idle") ] | length' \
      "$ST_RECORDS/$REIN_LOG_BASENAME" 2>/dev/null)" = "0" ]; then
      st_ok
    else
      st_fail "a lineage whose session is alive is never reported as a gap" \
        "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    fi
    if [ "$(rein_st_calls_total "$ST_NOTIFY")" -eq 0 ]; then
      st_ok
    else
      st_fail "a live lineage raises no notification" "$(cat "$ST_NOTIFY")"
    fi
  else
    st_fail "the gap watch probes a live lineage too" "agents calls=$(rein_st_count_sub "$ST_LOG" agents)"
  fi
  st_alarm_watcher_daemon 0
  unset ST_LINEAGE_IDLE

  # Evidence that cannot be read is not a gap. An enumeration the CLI refuses to answer says
  # nothing about whether the seat is empty, and a gap watch that reported off it would cry wolf
  # on every hiccup -- while the lineage is genuinely fine and the user learns to ignore it.
  case_dir="$tmp/lineage-gap-undecidable"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_RECORDS/$REIN_POINTER_BASENAME" "pred-1" "predecessor" "$ST_CWD" 1
  rein_st_write_agents_done "$ST_AGENTS" "$ST_CWD" "pred-1"
  ST_LINEAGE_IDLE=1
  ST_AGENTS_FAIL=1
  st_run_watcher_daemon_bg "$ST_DAEMON_GUARD_SEC"
  # One probe spends several calls (enumeration retries before giving up), so waiting past that
  # many witnesses a probe that ran to completion and still said nothing.
  if st_wait_for_agents_calls 6; then
    if [ "$(jq -s -r '[ .[] | select(.event == "lineage_idle") ] | length' \
      "$ST_RECORDS/$REIN_LOG_BASENAME" 2>/dev/null)" = "0" ]; then
      st_ok
    else
      st_fail "an unreadable enumeration is never reported as a gap" \
        "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    fi
    if [ "$(rein_st_calls_total "$ST_NOTIFY")" -eq 0 ]; then
      st_ok
    else
      st_fail "an unreadable enumeration raises no notification" "$(cat "$ST_NOTIFY")"
    fi
  else
    st_fail "the gap watch probes even when enumeration is failing" "agents calls=$(rein_st_count_sub "$ST_LOG" agents)"
  fi
  st_alarm_watcher_daemon 0
  unset ST_LINEAGE_IDLE ST_AGENTS_FAIL

  # Turned off (0) never probes at all -- a watcher on a lineage the user is not automating
  # should not be starting an external command on a timer.
  case_dir="$tmp/lineage-gap-off"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_RECORDS/$REIN_POINTER_BASENAME" "pred-1" "predecessor" "$ST_CWD" 1
  rein_st_write_agents_done "$ST_AGENTS" "$ST_CWD" "pred-1"
  ST_LINEAGE_IDLE=0
  st_run_watcher_daemon_bg "$ST_DAEMON_GUARD_SEC"
  # The heartbeat is published asynchronously, so the witness has to wait for it to exist before
  # it can watch it advance. Two advances put the watcher well past several thresholds' worth of
  # cycles, which is the only way "it never probed" means anything.
  if st_wait_for_path "$ST_RUNTIME/$REIN_HEARTBEAT_BASENAME" && st_witness_daemon_alive; then
    st_ok
  fi
  if st_witness_daemon_alive; then
    st_ok
  fi
  if [ "$(jq -s -r '[ .[] | select(.event == "lineage_idle") ] | length' \
    "$ST_RECORDS/$REIN_LOG_BASENAME" 2>/dev/null)" = "0" ]; then
    st_ok
  else
    st_fail "a threshold of 0 turns the gap watch off" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
  fi
  if [ "$(rein_st_count_sub "$ST_LOG" agents)" -eq 0 ]; then
    st_ok
  else
    st_fail "a threshold of 0 never enumerates sessions" \
      "agents calls=$(rein_st_count_sub "$ST_LOG" agents)"
  fi
  st_alarm_watcher_daemon 0
  unset ST_LINEAGE_IDLE

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
