# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034  # selftest state is shared across sections (the caller selftest()'s locals, and the ST_* globals)
# Every branch of the wait before launching a successor (stage 1's limit, stage 2's window, cancellation, a zero limit).
# Hooks are what place the marker, so this section places the marker directly as a fixture and tests only the watcher's side.
# Variables are shared with the caller selftest()'s locals through dynamic scope. Declaring a
# local inside a section would hide it from later sections, so this section file declares none.
# Not an executable script, so it carries no execute bit (outside the --selftest convention).

st_section_final_output() {
  # (1) If a marker for "done printing its output" is there, launch the successor without waiting out stage 1's limit.
  case_dir="$tmp/final-output-ready"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  printf '%s\n' "pred-1" >"$ST_RUNTIME/$REIN_HANDOVER_READY_BASENAME"
  # Exiting via the marker (not waiting out stage 1's limit) can't be measured from the completion
  # line alone -- an implementation that observes the marker but never redraws the deadline would
  # print the same completion line, just after waiting out the full limit. Splitting on an absolute
  # elapsed-time value would cross the boundary on a loaded machine, so instead set the limit
  # **large enough that waiting it out always gets cut off from outside** (stage 1's limit, 300
  # seconds > the outer cutoff, 60 seconds) and split on exit code instead -- a run that exits
  # returns 0, a run that waits out the limit returns 142 (128+SIGALRM). This case's actual duration
  # is on the order of 1 second, so the 60-second cutoff is a guardrail that only rescues a run so
  # slow that observation itself never arrives.
  ST_FINAL_OUTPUT_TIMEOUT=300
  ST_ALARM_SEC=60
  st_run_watcher
  unset ST_FINAL_OUTPUT_TIMEOUT ST_ALARM_SEC
  st_accept_case "the handover completes when the marker is there"
  if [ "$ST_STATUS" -ne 142 ]; then
    st_ok
  else
    st_fail "does not wait out stage 1's limit once it observes the marker" \
      "waited out stage 1's 300-second limit and was cut off by the outer 60-second cutoff: ${ST_OUT}"
  fi
  # A run that observes the marker leaves no extra record (the time it waited shows up in the gap
  # between marker_accepted's and successor_launching's timestamps).
  if st_log_has '"event":"final_output_wait_expired"'; then
    st_fail "does not record a limit expiring on a run that observed the marker" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
  else
    st_ok
  fi
  # Both get deleted on the way out regardless of the result (leaving one behind lets the next handover read it as this round's).
  if [ ! -e "$ST_RUNTIME/$REIN_HANDOVER_READY_BASENAME" ] &&
    [ ! -e "$ST_RUNTIME/$REIN_HANDOVER_CANCEL_BASENAME" ]; then
    st_ok
  else
    st_fail "deletes the marker once the wait is left" "$(ls -a "$ST_RUNTIME")"
  fi

  # (2) **Stage 2 (the window that accepts a cancellation) actually exists.** Even after observing
  #     the marker, no successor is launched for `final_output_wait_sec` -- without measuring this,
  #     there is no way to distinguish an implementation that proceeds the instant it sees the
  #     marker (a zero-second window) from one that doesn't, and there would be no way to notice
  #     that the very time meant to accept a cancellation doesn't exist.
  case_dir="$tmp/final-output-stage2-dwell"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  printf '%s\n' "pred-1" >"$ST_RUNTIME/$REIN_HANDOVER_READY_BASENAME"
  ST_FINAL_OUTPUT_TIMEOUT=15
  ST_FINAL_OUTPUT_WAIT=4
  fo_started="$(rein_now_epoch)"
  st_run_watcher
  fo_elapsed="$(($(rein_now_epoch) - fo_started))"
  unset ST_FINAL_OUTPUT_TIMEOUT ST_FINAL_OUTPUT_WAIT
  st_accept_case "the handover completes once the window is waited out"
  if [ "$fo_elapsed" -ge 4 ]; then
    st_ok
  else
    st_fail "waits out the window after observing the marker" "took ${fo_elapsed} seconds (shorter than the 4-second window)"
  fi

  # (3) **The shape where a cancellation arrives inside the window.** The marker is placed first,
  #     so the wait enters stage 2 on the first cycle, and riding along `sleep` from there to write
  #     the cancel marker means the observation always lands inside the window (aiming by elapsed
  #     real time would drift outside the window on a loaded machine and produce a false green).
  case_dir="$tmp/final-output-cancel-in-window"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  printf '%s\n' "pred-1" >"$ST_RUNTIME/$REIN_HANDOVER_READY_BASENAME"
  ST_BROKEN_BIN="$ST_CWD/sleep-bin"
  st_write_sleep_mark_shim "$ST_BROKEN_BIN" "$ST_CWD/sleep-calls" \
    "$ST_RUNTIME/$REIN_HANDOVER_CANCEL_BASENAME" "pred-1" 1
  ST_FINAL_OUTPUT_TIMEOUT=15
  ST_FINAL_OUTPUT_WAIT=15
  st_run_watcher
  unset ST_BROKEN_BIN ST_FINAL_OUTPUT_TIMEOUT ST_FINAL_OUTPUT_WAIT
  if st_expect_status "a cancellation inside the window makes a single pass return non-zero" 1; then
    if [ "$(rein_st_count_sub "$ST_LOG" "--bg")" -ne 0 ]; then
      st_fail "does not launch a successor once cancelled inside the window" "claude --bg was called: $(cat "$ST_LOG")"
    elif ! st_log_has '"event":"marker_cancelled"'; then
      st_fail "records a cancellation that arrives inside the window" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    else
      st_ok
    fi
  fi
  # Premise check: the interruption rides along the wait's `sleep` (if it was never called, this
  # measures "the marker was there from the start", not a cancellation inside the window).
  if [ "$(cat "$ST_CWD/sleep-calls" 2>/dev/null)" -ge 1 ]; then
    st_ok
  else
    st_fail "can ride along the waiting sleep" "sleep was never called"
  fi

  # (4) If stage 1's limit is reached with no marker in sight, launch the successor as before. Leave
  #     one line so it doesn't fail silently (a record shows the mechanism didn't fire).
  case_dir="$tmp/final-output-expired"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  ST_FINAL_OUTPUT_TIMEOUT=3
  fo_started="$(rein_now_epoch)"
  st_run_watcher
  fo_elapsed="$(($(rein_now_epoch) - fo_started))"
  unset ST_FINAL_OUTPUT_TIMEOUT
  st_accept_case "the handover proceeds as usual even with no marker"
  if [ "$fo_elapsed" -ge 3 ]; then
    st_ok
  else
    st_fail "waits out the full limit" "took ${fo_elapsed} seconds (shorter than the 3-second limit)"
  fi
  if st_log_has '"event":"final_output_wait_expired"'; then
    st_ok
  else
    st_fail "records that it fell back to the ordinary path" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
  fi

  # (5) A lineage whose limit is 0 does not enter the wait at all (the behavior before this
  #     mechanism was added). **To distinguish this from entering as a zero-second wait**, the only
  #     way is to see that even placing a cancel marker has no effect -- by duration, both take 0
  #     seconds, and whether `final_output_wait_expired` is present alone can't tell "0-second
  #     limit, expired instantly" apart from "never waited" (the latter was chosen so a lineage that
  #     decided not to wait doesn't accumulate "never made it through the wait" in its handover log
  #     every single time).
  case_dir="$tmp/final-output-disabled"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  printf '%s\n' "pred-1" >"$ST_RUNTIME/$REIN_HANDOVER_CANCEL_BASENAME"
  ST_FINAL_OUTPUT_TIMEOUT=0
  st_run_watcher
  unset ST_FINAL_OUTPUT_TIMEOUT
  st_accept_case "a lineage with a zero limit hands over without waiting"
  if st_log_has '"event":"marker_cancelled"'; then
    st_fail "does not even look at the cancel marker with a zero limit" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
  elif st_log_has '"event":"final_output_wait_expired"'; then
    st_fail "does not record a limit expiring for a lineage that chose not to wait" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
  else
    st_ok
  fi

  # (6) On observing a cancel marker, launch no successor at all -- archive it to `cancelled/` and return to monitoring.
  case_dir="$tmp/final-output-cancel"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  printf '%s\n' "pred-1" >"$ST_RUNTIME/$REIN_HANDOVER_CANCEL_BASENAME"
  ST_FINAL_OUTPUT_TIMEOUT=15
  st_run_watcher
  # `--once` is an entry point that returns "did that one thing go through", so a cancellation returns on the side that didn't.
  if st_expect_status "a single pass on a cancelled round returns non-zero" 1; then
    if [ "$(rein_st_count_sub "$ST_LOG" "--bg")" -ne 0 ]; then
      st_fail "launches no successor at all on cancellation" "claude --bg was called: $(cat "$ST_LOG")"
    elif [ -f "$ST_RECORDS/$REIN_POINTER_BASENAME" ]; then
      st_fail "does not advance the pointer on cancellation" "$(cat "$ST_RECORDS/$REIN_POINTER_BASENAME")"
    elif ! st_log_has '"event":"marker_cancelled"'; then
      st_fail "records the cancellation" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    elif st_log_has '"event":"marker_rejected"'; then
      st_fail "does not record a cancellation as a rejection" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    else
      st_ok
    fi
  fi
  # The archive destination is separate from `rejected/` (a rejection is bad input; a cancellation is the user's own choice -- the next step differs).
  fo_archived="$(find "$ST_RUNTIME/$REIN_CANCELLED_DIRNAME" -maxdepth 1 -type f -name '*.json' -print -quit 2>/dev/null)"
  if [ -z "$fo_archived" ]; then
    st_fail "archives the cancelled marker to cancelled" "$(ls -a "$ST_RUNTIME" 2>&1)"
  elif [ -n "$(find "$ST_RUNTIME/$REIN_REJECTED_DIRNAME" -maxdepth 1 -type f -name '*.json' -print -quit 2>/dev/null)" ]; then
    st_fail "does not mix a cancellation into rejected" "$(ls -a "$ST_RUNTIME/$REIN_REJECTED_DIRNAME" 2>&1)"
  elif [ -f "$ST_RUNTIME/$REIN_MARKER_BASENAME" ]; then
    st_fail "consumes the cancelled marker" "the marker is still there (the same judgment would recur forever)"
  else
    st_ok
  fi
  # No reason gets appended to the archived record (unlike a rejection reason, there is no defect to fix).
  if [ -n "$fo_archived" ] &&
    [ "$(jq -r '.rejected_reason // "(none)"' "$fo_archived" 2>/dev/null)" = "(none)" ]; then
    st_ok
  else
    st_fail "does not append a rejection reason to a cancellation's archived record" "$(cat "${fo_archived:-/dev/null}" 2>&1)"
  fi
  # A handover that never took place does not get **a generation-number field** (the same discipline as a rejection line).
  if [ "$(jq -r 'select(.event == "marker_cancelled") | .generation' \
    "$ST_RECORDS/$REIN_LOG_BASENAME" | tr '\n' ' ')" = "null " ]; then
    st_ok
  else
    st_fail "the cancellation line's generation is null" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
  fi
  # But without tracing **which acceptance got undone**, it couldn't be lined up with
  # marker_accepted, so the generation at acceptance goes in the detail (this coexists with the field itself being null).
  if [ "$(jq -r 'select(.event == "marker_cancelled") | .detail' \
    "$ST_RECORDS/$REIN_LOG_BASENAME" | grep -c 'generation at acceptance: 1')" = "1" ]; then
    st_ok
  else
    st_fail "the cancellation's detail carries the generation at acceptance" \
      "$(jq -r 'select(.event == "marker_cancelled") | .detail' "$ST_RECORDS/$REIN_LOG_BASENAME")"
  fi
  if st_expect_notify_matches_event "lets the user know about the cancellation" \
    "rein: cancelled a handover" "cancelled" "marker_cancelled"; then
    st_ok
  fi
  if [ ! -e "$ST_RUNTIME/$REIN_HANDOVER_CANCEL_BASENAME" ]; then
    st_ok
  else
    st_fail "deletes the marker on a run that exits via cancellation too" "$(ls -a "$ST_RUNTIME")"
  fi
  # A cancellation does not stop monitoring -- a request that comes in afterward goes through
  # normally as always (`--once`'s non-zero means "did that one thing go through", not "the lineage
  # stopped"). **Measure with the wait still in the path** (measuring with the limit stripped out
  # would exercise a path that skips the wait entirely, and the case name and what's actually
  # measured would drift apart).
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  printf '%s\n' "pred-1" >"$ST_RUNTIME/$REIN_HANDOVER_READY_BASENAME"
  : >"$ST_LOG"
  rm -f "$ST_LOG.agents"
  st_run_watcher
  unset ST_FINAL_OUTPUT_TIMEOUT
  st_accept_case "a request after a cancellation goes through the wait and completes"

  # (7) A cancellation beats a completion marker (with both present, it does not fall to the side that waits it out and launches).
  case_dir="$tmp/final-output-cancel-wins"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  printf '%s\n' "pred-1" >"$ST_RUNTIME/$REIN_HANDOVER_READY_BASENAME"
  printf '%s\n' "pred-1" >"$ST_RUNTIME/$REIN_HANDOVER_CANCEL_BASENAME"
  ST_FINAL_OUTPUT_TIMEOUT=15
  st_run_watcher
  unset ST_FINAL_OUTPUT_TIMEOUT
  if st_expect_status "the cancellation wins with both markers present" 1; then
    if [ "$(rein_st_count_sub "$ST_LOG" "--bg")" -ne 0 ]; then
      st_fail "launches no successor even on a round the cancellation wins" "claude --bg was called: $(cat "$ST_LOG")"
    elif ! st_log_has '"event":"marker_cancelled"'; then
      st_fail "records the cancellation even on a round it wins" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    else
      st_ok
    fi
  fi

  # (8) A marker left over from a previous handover (whose content doesn't match this round's
  #     requester) is not treated as material. An implementation that reads a cancel marker without
  #     checking its content would lose this round's handover entirely.
  case_dir="$tmp/final-output-foreign-mark"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  printf '%s\n' "someone-else" >"$ST_RUNTIME/$REIN_HANDOVER_READY_BASENAME"
  printf '%s\n' "someone-else" >"$ST_RUNTIME/$REIN_HANDOVER_CANCEL_BASENAME"
  ST_FINAL_OUTPUT_TIMEOUT=3
  st_run_watcher
  unset ST_FINAL_OUTPUT_TIMEOUT
  st_accept_case "someone else's marker neither cancels nor completes the handover"
  if st_log_has '"event":"marker_cancelled"'; then
    st_fail "does not cancel a handover from someone else's cancel marker" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
  elif ! st_log_has '"event":"final_output_wait_expired"'; then
    st_fail "does not read someone else's completion marker as this round's" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
  else
    st_ok
  fi

  # (10) Don't silently let through a round where the marker **cannot be deleted** or **cannot be
  #      read**. Either one directly leads to a misfire on the next handover (a cancel marker left
  #      behind matches on the very first cycle of the next wait; a cancel marker that cannot be
  #      read collapses into "doesn't match", and the shape "the user spoke up, but the handover
  #      goes through anyway" happens silently). Fall to the safe side (the ordinary path) for the
  #      handover itself, and check that one line is left in the operating log.
  case_dir="$tmp/final-output-mark-io"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  # A marker that cannot be deleted = a directory with content in it (`rm -f` always fails on this shape).
  mkdir -p "$ST_RUNTIME/$REIN_HANDOVER_READY_BASENAME"
  : >"$ST_RUNTIME/$REIN_HANDOVER_READY_BASENAME/keep"
  # A marker that cannot be read = a file that exists but can't be opened.
  printf '%s\n' "pred-1" >"$ST_RUNTIME/$REIN_HANDOVER_CANCEL_BASENAME"
  chmod 000 "$ST_RUNTIME/$REIN_HANDOVER_CANCEL_BASENAME"
  ST_FINAL_OUTPUT_TIMEOUT=3
  st_run_watcher
  unset ST_FINAL_OUTPUT_TIMEOUT
  st_accept_case "a cancel marker that can't be read does not stop the handover"
  if grep -q -e 'cannot read the handover marker' "$ST_RECORDS/$REIN_WATCHER_LOG_BASENAME"; then
    st_ok
  else
    st_fail "does not silently collapse an unreadable marker into 'doesn't match'" \
      "$(cat "$ST_RECORDS/$REIN_WATCHER_LOG_BASENAME" 2>/dev/null)"
  fi
  if grep -q -e 'cannot delete the handover marker' "$ST_RECORDS/$REIN_WATCHER_LOG_BASENAME"; then
    st_ok
  else
    st_fail "does not silently let a marker that couldn't be deleted through" \
      "$(cat "$ST_RECORDS/$REIN_WATCHER_LOG_BASENAME" 2>/dev/null)"
  fi
  chmod 644 "$ST_RUNTIME/$REIN_HANDOVER_CANCEL_BASENAME" 2>/dev/null

  # (11) **A cancellation that arrives after the window has closed.** The marker keeps being placed
  #      for the whole span from launching the successor to the pointer moving, but the wait -- the
  #      only step that ever read it -- has already been left, so nothing used to reach the user:
  #      they spoke up, the seat switched over anyway, and no line said whether their words landed.
  #      The handover is **not** rolled back (the pointer has moved and cannot be rolled back); what
  #      is measured here is that the round leaves one line and one notification saying the words
  #      came too late. The marker is placed by riding along the launch call, because a fixture
  #      placed before the run gets deleted on the way out of the wait and would land in a
  #      different case entirely (a cancellation inside the window -> (3)).
  case_dir="$tmp/final-output-cancel-after-window"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  printf '%s\n' "pred-1" >"$ST_RUNTIME/$REIN_HANDOVER_READY_BASENAME"
  ST_BROKEN_BIN="$ST_CWD/bg-bin"
  st_write_bg_mark_shim "$ST_BROKEN_BIN" "$ST_RUNTIME/$REIN_HANDOVER_CANCEL_BASENAME" "pred-1"
  ST_FINAL_OUTPUT_TIMEOUT=15
  ST_FINAL_OUTPUT_WAIT=1
  st_run_watcher
  unset ST_BROKEN_BIN ST_FINAL_OUTPUT_TIMEOUT ST_FINAL_OUTPUT_WAIT
  st_accept_case "a cancellation that arrives after the window does not stop the handover"
  # The vocabulary is kept apart from a cancellation that took effect. marker_cancelled means "no
  # successor was ever launched", so reusing it here would make a completed handover read in the
  # audit log as one that never happened.
  if ! st_log_has '"event":"cancel_after_window"'; then
    st_fail "records a cancellation that arrived after the window" \
      "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
  elif st_log_has '"event":"marker_cancelled"'; then
    st_fail "does not borrow the vocabulary of a cancellation that took effect" \
      "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
  else
    st_ok
  fi
  if st_expect_notify_matches_event "tells the user the cancellation came too late" \
    "rein: the cancellation did not make it in time" "after the window had closed" \
    "cancel_after_window"; then
    st_ok
  fi
  # Left in place, it would match on the very first cycle of the next handover's wait and cancel a
  # handover the user never spoke against.
  if [ ! -e "$ST_RUNTIME/$REIN_HANDOVER_CANCEL_BASENAME" ]; then
    st_ok
  else
    st_fail "does not carry a late cancellation into the next round" "$(ls -a "$ST_RUNTIME")"
  fi

  # (12) **A round where no cancellation was placed says nothing.** Without this side, an
  #      implementation that reports unconditionally -- telling the user "your cancellation came
  #      too late" on every single handover, when they never spoke at all -- passes (11) green.
  case_dir="$tmp/final-output-no-late-cancel"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  printf '%s\n' "pred-1" >"$ST_RUNTIME/$REIN_HANDOVER_READY_BASENAME"
  ST_FINAL_OUTPUT_TIMEOUT=15
  ST_FINAL_OUTPUT_WAIT=1
  st_run_watcher
  unset ST_FINAL_OUTPUT_TIMEOUT ST_FINAL_OUTPUT_WAIT
  st_accept_case "a round with no cancellation hands over exactly as before"
  if st_log_has '"event":"cancel_after_window"'; then
    st_fail "leaves no line on a round where no cancellation was placed" \
      "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
  elif [ "$(rein_st_calls_total "$ST_NOTIFY")" -ne 0 ]; then
    st_fail "sends no notification on a round where no cancellation was placed" \
      "$(cat "$ST_NOTIFY")"
  else
    st_ok
  fi

  # (13) **Someone else's cancel marker is not touched even after the window.** Reading a marker
  #      without checking whose it is would report a cancellation to a user who never spoke, and
  #      deleting it would swallow a marker another lineage's wait is about to read.
  case_dir="$tmp/final-output-late-foreign-mark"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  printf '%s\n' "pred-1" >"$ST_RUNTIME/$REIN_HANDOVER_READY_BASENAME"
  ST_BROKEN_BIN="$ST_CWD/bg-bin"
  st_write_bg_mark_shim "$ST_BROKEN_BIN" "$ST_RUNTIME/$REIN_HANDOVER_CANCEL_BASENAME" "someone-else"
  ST_FINAL_OUTPUT_TIMEOUT=15
  ST_FINAL_OUTPUT_WAIT=1
  st_run_watcher
  unset ST_BROKEN_BIN ST_FINAL_OUTPUT_TIMEOUT ST_FINAL_OUTPUT_WAIT
  st_accept_case "someone else's late cancel marker neither reports nor stops anything"
  if st_log_has '"event":"cancel_after_window"'; then
    st_fail "does not report someone else's cancel marker as this round's" \
      "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
  elif [ ! -e "$ST_RUNTIME/$REIN_HANDOVER_CANCEL_BASENAME" ]; then
    st_fail "does not delete someone else's cancel marker" "$(ls -a "$ST_RUNTIME")"
  else
    st_ok
  fi

  # (9) **Monitoring doesn't stop even as a daemon.** A rejection (bad input from the user) and a
  #     cancellation (the user's own choice) are both the same shape -- "that one round doesn't
  #     go through, but monitoring continues" -- so one daemon case covers both (covering only one
  #     would leave the other branch free to be changed to `return 1` and still stay green).
  case_dir="$tmp/final-output-daemon"
  st_setup_case "$case_dir"
  ST_FINAL_OUTPUT_TIMEOUT=3
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "2026/08/15 04:12" "$ST_HANDOFF" "$ST_CWD"
  st_run_watcher_daemon_bg "$ST_DAEMON_GUARD_SEC"
  if st_wait_for_log '"event":"marker_rejected"'; then
    st_ok
    # Monitoring continues even after a rejection -- the next request that comes in can still be
    # cancelled (the cancel marker is placed first, so it hits on the first cycle of the wait).
    printf '%s\n' "pred-1" >"$ST_RUNTIME/$REIN_HANDOVER_CANCEL_BASENAME"
    rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
    if st_wait_for_log '"event":"marker_cancelled"'; then
      st_ok
    else
      st_fail "keeps monitoring after a rejection" "never proceeded to a cancellation: $(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    fi
    # Monitoring continues even after a cancellation -- the next request that comes in completes the handover.
    printf '%s\n' "pred-1" >"$ST_RUNTIME/$REIN_HANDOVER_READY_BASENAME"
    rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
    if st_wait_for_log '"event":"handover_completed"'; then
      st_ok
    else
      st_fail "keeps monitoring after a cancellation" "a subsequent request did not hand over: $(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    fi
  else
    st_fail "the daemon records a rejection" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME" 2>/dev/null)"
  fi
  st_alarm_watcher_daemon
  daemon_rc="$(cat "$ST_DAEMON_RC_FILE" 2>/dev/null)"
  unset ST_FINAL_OUTPUT_TIMEOUT
  # Cut off from outside by alarm (128+SIGALRM=142) -- confirms monitoring never ended on its own,
  # whether from a rejection or a cancellation.
  if [ "$daemon_rc" = "142" ]; then
    st_ok
  else
    st_fail "does not end a daemon on its own, whether from a rejection or a cancellation" \
      "the watcher exited on its own with exit ${daemon_rc}: $(cat "$ST_DAEMON_OUT" 2>/dev/null)"
  fi
}
