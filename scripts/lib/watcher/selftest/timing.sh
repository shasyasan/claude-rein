# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034  # selftest state is shared across sections (the caller selftest()'s locals, and the ST_* globals)
# CLI flags with an explicit empty value vs. a missing value; the time math for the grace period
# and the stop confirmation; the shape where the heartbeat can no longer be written partway
# through a handover.
# Variables are shared with the caller selftest()'s locals through dynamic scope. Declaring a
# local inside a section would hide it from later sections, so this section file declares none.
# Not an executable script, so it carries no execute bit (outside the --selftest convention).

st_section_timing() {
  case_dir="$tmp/empty-opts"
  st_setup_case "$case_dir"
  st_empty_opt_case "does not start with an empty --settings" settings --settings ""
  st_empty_opt_case "does not start with an empty --interval" poll_interval_sec --interval ""
  st_empty_opt_case "does not start with an empty --runtime-dir" runtime_dir --runtime-dir ""
  # A missing value fails for a different reason (never conflate a typo with an intentional empty value).
  ST_ARGS=(--settings)
  st_run_watcher
  unset ST_ARGS
  if st_expect_status "does not start with --settings missing its value" 2; then
    case "$ST_OUT" in
      *"--settings requires a value"*)
        st_ok
        ;;
      *)
        st_fail "fails a missing value for a different reason than an empty one" "${ST_OUT}"
        ;;
    esac
  fi

  # "Did it sleep for the whole interval" can't be told apart by the absolute elapsed time alone
  # (a slow startup eats into the margin). Set the polling interval far above the wait cap, and
  # put the elapsed-time cap halfway between: a run that slept the full interval always exceeds
  # the cap, and a run whose startup was slowed a few seconds by load never does.
  # The midpoint is chosen **far from both sides** (this case's measured runtime is around 1
  # second; sleeping the full interval would be 60 seconds -- a 30-second cap is far from either
  # side). Pulling the cap close to the measured runtime would make this cap alone flip
  # pass/fail run to run on a machine running other selftests in parallel.
  grace_interval=60
  grace_limit=30

  # A grace period of 0 means "never sleep even once". Checking the deadline with `>` would
  # overshoot by one polling cycle, and the math the seat's watchdog uses (grace +
  # external-command cap + stop-confirmation cap) would then disagree with actual behavior.
  case_dir="$tmp/grace-zero"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  ST_EXIT_GRACE=0
  ST_INTERVAL="$grace_interval"
  grace_started="$(rein_now_epoch)"
  st_run_watcher
  grace_elapsed="$(($(rein_now_epoch) - grace_started))"
  unset ST_EXIT_GRACE ST_INTERVAL
  if st_expect_status "the handover still completes with a zero grace period" 0; then
    if ! rein_st_has_call "$ST_LOG" stop job-pred-1; then
      st_fail "a zero grace period stops externally right away" "claude stop was never called: $(cat "$ST_LOG")"
    elif [ "$grace_elapsed" -gt "$grace_limit" ]; then
      st_fail "a zero grace period does not wait a full polling interval" \
        "took ${grace_elapsed}s (cap ${grace_limit}s, polling interval ${grace_interval}s)"
    else
      st_ok
    fi
  fi

  # The stop-confirmation cap also does not get stretched by the polling interval (it sleeps in slices capped to the time remaining).
  case_dir="$tmp/stop-timeout-capped"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  ST_EXIT_GRACE=0
  ST_STOP_TIMEOUT=1
  ST_INTERVAL="$grace_interval"
  ST_STOP_INEFFECTIVE=1
  grace_started="$(rein_now_epoch)"
  st_run_watcher
  grace_elapsed="$(($(rein_now_epoch) - grace_started))"
  unset ST_EXIT_GRACE ST_STOP_TIMEOUT ST_INTERVAL ST_STOP_INEFFECTIVE
  if st_expect_status "fails at the cap when the stop doesn't take effect" 1; then
    if ! grep -q -e 'still present 1 seconds after claude stop' "$ST_RECORDS/$REIN_LOG_BASENAME"; then
      st_fail "leaves the stop-confirmation cap as the reason" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    elif [ "$grace_elapsed" -gt "$grace_limit" ]; then
      st_fail "does not stretch the stop-confirmation wait by the polling interval" \
        "took ${grace_elapsed}s (cap ${grace_limit}s, stop-confirmation cap 1s, polling interval ${grace_interval}s)"
    else
      st_ok
    fi
  fi

  # If the heartbeat can no longer be written during a handover, that's a stage failure just like
  # in the watch loop (the contract "record failed and exit non-zero when it can't be written"
  # holds on the mid-handover path too). Break the location during the successor's launch and hit
  # the failure inside the predecessor's exit-confirmation wait loop.
  case_dir="$tmp/heartbeat-breaks-midway"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  ST_SABOTAGE="$ST_RUNTIME/$REIN_HEARTBEAT_BASENAME"
  ST_EXIT_GRACE=2
  st_run_watcher
  unset ST_SABOTAGE ST_EXIT_GRACE
  if st_expect_status "fails when the heartbeat can't be written mid-handover" 1; then
    if [ ! -f "$ST_RECORDS/$REIN_POINTER_BASENAME" ]; then
      st_fail "the heartbeat failure happens inside the wait loop" "the pointer was never written (it failed at a different stage): ${ST_OUT}"
    elif ! grep -q -e 'stage=updating the heartbeat' "$ST_RECORDS/$REIN_LOG_BASENAME"; then
      st_fail "records a mid-handover heartbeat failure with its stage" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    elif st_log_has '"event":"handover_completed"'; then
      st_fail "does not treat it as complete while the heartbeat can't be written" "handover_completed was recorded"
    else
      st_ok
    fi
  fi

  # The same contract on **the wait that confirms the managed marker reached the successor**. That
  # wait runs one step earlier than the case above -- after the launch is confirmed, before the
  # pointer moves -- so a heartbeat that can no longer be written there has to fail the round
  # while the pointer still names the predecessor.
  # Two knobs together: the launched session keeps the temporary launch settings
  # (ST_BG_KEEP_SETTINGS), so the wait actually enters its loop instead of returning on its first
  # check, and the heartbeat location is broken during the launch (ST_SABOTAGE), so the first
  # write inside that loop fails. The grace period is set far above the single cycle this takes,
  # so what ends the wait can only be the heartbeat failure and never the cap running out -- the
  # two exits of the same wait are told apart by the stage recorded below.
  case_dir="$tmp/heartbeat-breaks-in-arrival-wait"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  ST_SABOTAGE="$ST_RUNTIME/$REIN_HEARTBEAT_BASENAME"
  ST_BG_KEEP_SETTINGS=1
  ST_MANAGED_SETTINGS_DROP=30
  st_run_watcher
  unset ST_SABOTAGE ST_BG_KEEP_SETTINGS ST_MANAGED_SETTINGS_DROP
  if st_expect_status "fails when the heartbeat can't be written while confirming the marker arrived" 1; then
    if [ -f "$ST_RECORDS/$REIN_POINTER_BASENAME" ]; then
      st_fail "never advances the pointer when the arrival wait fails" "current.json was written: ${ST_OUT}"
    elif ! grep -q -e 'stage=updating the heartbeat' "$ST_RECORDS/$REIN_LOG_BASENAME"; then
      st_fail "records the arrival wait's heartbeat failure with its stage" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    elif grep -q -e 'the successor came up, but the temporary launch settings were still there' "$ST_RECORDS/$REIN_LOG_BASENAME"; then
      st_fail "does not report the heartbeat failure as the grace period running out" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    elif st_log_has '"event":"handover_completed"'; then
      st_fail "does not treat it as complete while the heartbeat can't be written" "handover_completed was recorded"
    else
      st_ok
    fi
  fi
  # The successor that did come up goes through the same abandon path every other pre-pointer
  # failure uses -- leaving it would put a background session with no pointer to it in the same
  # working tree.
  if st_log_has '"event":"successor_stopped"'; then
    st_ok
  else
    st_fail "steps the successor down when the arrival wait fails on the heartbeat" \
      "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
  fi
  # Nothing is left in the runtime directory afterwards: the session that would have deleted it is
  # the one being stepped down, so the watcher removes it (same cleanup as the undelivered-marker
  # case below -- here the heartbeat failure ends the wait instead of the drop deadline).
  if [ -n "$(find "$ST_RUNTIME" -name "${REIN_MANAGED_SETTINGS_PREFIX}*" -print 2>/dev/null)" ]; then
    st_fail "leaves no temporary launch settings behind after stepping the successor down" \
      "$(find "$ST_RUNTIME" -name "${REIN_MANAGED_SETTINGS_PREFIX}*" -print 2>/dev/null)"
  else
    st_ok
  fi

  # Being unable to read the listing after stopping must not be collapsed into "stopped but didn't disappear" (it's recorded under a different cause).
  case_dir="$tmp/agents-fail-at-stop-check"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  ST_EXIT_GRACE=0
  ST_AGENTS_FAIL_AFTER=4
  st_run_watcher
  unset ST_EXIT_GRACE ST_AGENTS_FAIL_AFTER
  if st_expect_status "fails when the listing can't be read after stopping" 1; then
    if ! grep -q -e "stage=confirming the predecessor's stop" "$ST_RECORDS/$REIN_LOG_BASENAME"; then
      st_fail "fails at the stop-confirmation stage" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    elif grep -q -e 'seconds after claude stop' "$ST_RECORDS/$REIN_LOG_BASENAME"; then
      st_fail "does not call an unreadable listing 'did not disappear'" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    elif ! grep -q -e 'cannot read claude agents --json' "$ST_RECORDS/$REIN_LOG_BASENAME" ||
      ! grep -q -e 'fake agents boom' "$ST_RECORDS/$REIN_LOG_BASENAME"; then
      st_fail "leaves the unreadable-listing failure with its reason and stderr" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    else
      st_ok
    fi
  fi

}
