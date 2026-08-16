# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034  # selftest state is shared across sections (the caller selftest()'s locals, and the ST_* globals)
# Every stage of the accepting side: a fresh marker launches the successor, the pointer, handover log,
# and lock all end up matching the contract, through the generation advancing on the 2nd generation.
# Variables are shared with the caller selftest()'s locals through dynamic scope. Declaring a
# local inside a section would hide it from later sections, so this section file declares none.
# Not an executable script, so it carries no execute bit (outside the --selftest convention).

st_section_handover() {
  # The accepting side: a fresh marker launches the successor, with arguments, pointer, and log matching the contract.
  case_dir="$tmp/happy"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  ST_EXIT_AFTER_POLLS=2
  st_run_watcher
  unset ST_EXIT_AFTER_POLLS
  if st_expect_status "the handover completes with a fresh marker" 0; then
    # Check the recorded arguments one at a time, at their exact positions (a substring grep can't
    # detect "kickoff got split across multiple arguments" or "an extra argument got tacked on").
    bg_call="$(rein_st_call_index "$ST_LOG" "--bg")"
    if [ "$bg_call" -eq 0 ]; then
      st_fail "the successor's launch arguments include --bg" "claude was never called with --bg: $(cat "$ST_LOG")"
    elif [ "$(rein_st_call_argc "$ST_LOG" "$bg_call")" -ne "$ST_BG_ARGC_BASE" ] ||
      [ "$(rein_st_call_arg "$ST_LOG" "$bg_call" 2)" != "--name" ] ||
      [ "$(rein_st_call_arg "$ST_LOG" "$bg_call" 3)" != "${ST_CWD##*/}-rein-g1" ] ||
      [ "$(rein_st_call_arg "$ST_LOG" "$bg_call" 4)" != "--settings" ]; then
      st_fail "the successor's launch arguments include --name" "the launch arguments don't match the contract: $(cat "$ST_LOG")"
    else
      # kickoff is one argument (argc=4, the last one). If it's split into more than one, the real CLI would get a truncated body.
      kickoff_line="$(rein_st_call_arg "$ST_LOG" "$bg_call" "$ST_BG_ARGC_BASE")"
      case "$kickoff_line" in
        *"$ST_HANDOFF"*)
          st_ok
          ;;
        *)
          st_fail "kickoff carries the handoff document's absolute path" "kickoff has no document path: ${kickoff_line}"
          ;;
      esac
      # Does it hand over the writer command itself, so the successor can write the next handover
      # request (only telling it the location, without this, it can't reproduce the contract from
      # natural-language prose, and the 2nd generation's request would get rejected)?
      # Pin down the terminator too (the command ends right before the newline -- RS, on the
      # records side). Leaving this open and matching only a substring would also let a period or
      # another sentence run directly into the command, leaving the successor unable to tell where
      # the command actually ends.
      case "$kickoff_line" in
        *"'${REIN_BIN}' --cwd '${ST_CWD}' request --runtime-dir '${ST_RUNTIME}' --session-id <your session ID> --handoff '${ST_HANDOFF}'${REIN_ST_RS}"*)
          st_ok
          ;;
        *)
          st_fail "kickoff carries the handover request command" "the writer command was not given" "${kickoff_line}"
          ;;
      esac
      # Restraint in how much to read (the first read is a fixed cost of every handover, so kickoff narrows the scope).
      case "$kickoff_line" in
        *"Read only the sections you need to resume, and do not re-read it in full or pre-read related documents"*)
          st_ok
          ;;
        *)
          st_fail "kickoff carries restraint about how much to read" "no restraint guidance: ${kickoff_line}"
          ;;
      esac
      # Doesn't add extra material (no transcript path or the like, no extra places to read).
      case "$kickoff_line" in
        *"transcript"* | *"rein-request.sh"*)
          st_fail "does not load kickoff with extra material" "${kickoff_line}"
          ;;
        *)
          st_ok
          ;;
      esac
      # No note about supplementary material when kickoff_note_path is unset (the case where it's set is checked separately).
      case "$kickoff_line" in
        *"Supplementary notes for this project live at"*)
          st_fail "the supplementary-notes note only appears when configured" "${kickoff_line}"
          ;;
        *)
          st_ok
          ;;
      esac
    fi
    # Also check enumeration's arguments (don't let it pass with a bare `claude agents` or a different subcommand substituted).
    if rein_st_has_call "$ST_LOG" agents --json; then
      st_ok
    else
      st_fail "queries enumeration via claude agents --json" "$(cat "$ST_LOG")"
    fi
    if [ "$(jq -r '.session_id' "$ST_RECORDS/$REIN_POINTER_BASENAME" 2>/dev/null)" = "succ-1" ] &&
      [ "$(jq -r '.generation' "$ST_RECORDS/$REIN_POINTER_BASENAME" 2>/dev/null)" = "1" ] &&
      [ "$(jq -r '.predecessor_session_id' "$ST_RECORDS/$REIN_POINTER_BASENAME" 2>/dev/null)" = "pred-1" ]; then
      st_ok
    else
      st_fail "the pointer switches over to the successor" "current.json doesn't match what's expected: $(cat "$ST_RECORDS/$REIN_POINTER_BASENAME" 2>/dev/null)"
    fi
    if st_log_has '"event":"handover_completed"' && st_log_has '"event":"predecessor_exited"'; then
      st_ok
    else
      st_fail "every transition is left in the handover log" "no completion event: $(cat "$ST_RECORDS/$REIN_LOG_BASENAME" 2>/dev/null)"
    fi
    if [ -f "$ST_RUNTIME/$REIN_MARKER_BASENAME" ]; then
      st_fail "consumes the accepted marker" "the marker is still there"
    elif [ -n "$(find "$ST_RUNTIME/$REIN_PROCESSED_DIRNAME" -name '*.json' -print -quit 2>/dev/null)" ]; then
      st_ok
    else
      st_fail "archives the accepted marker to processed" "no archived file"
    fi
    # Puts pid and start time on the monitoring-started line, so a duplicate launch can be distinguished from the log side.
    # Also puts the version (a resident watcher keeps running on the code it started with, so this is the only clue for recovering "which version was that round" from the record).
    case "$(jq -r 'select(.event == "watch_started") | .detail' "$ST_RECORDS/$REIN_LOG_BASENAME" 2>/dev/null)" in
      *"pid="[0-9]*"started_at="[0-9]*"version="?*)
        st_ok
        ;;
      *)
        st_fail "watch_started carries pid, start time, and version" "the detail doesn't match what's expected: $(jq -r 'select(.event == "watch_started") | .detail' "$ST_RECORDS/$REIN_LOG_BASENAME" 2>/dev/null)"
        ;;
    esac
    # The marker the attach loop uses to see the watcher is alive.
    if [ -f "$ST_RUNTIME/$REIN_HEARTBEAT_BASENAME" ]; then
      st_ok
    else
      st_fail "places a heartbeat" "${REIN_HEARTBEAT_BASENAME} is missing: $(ls -a "$ST_RUNTIME")"
    fi
    # Release the watcher lock on a normal exit (leaving it would block the next instance from starting).
    if [ ! -d "$ST_RUNTIME/$REIN_LOCK_DIRNAME" ]; then
      st_ok
    else
      st_fail "releases the lock on a normal exit" "the lock is still there: $(ls -a "$ST_RUNTIME/$REIN_LOCK_DIRNAME")"
    fi
  fi

  # The 2nd generation advances the generation number (the pointer's own carryover).
  # Only the session the current pointer names (i.e. the 1st generation's successor) can request a handover (R10).
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "succ-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  rein_st_write_agents "$ST_AGENTS" "$ST_CWD" "succ-1"
  : >"$ST_LOG"
  rm -f "$ST_LOG.agents"
  ST_EXIT_AFTER_POLLS=2
  ST_PRED_ID="succ-1"
  ST_SUCC_ID="succ-2"
  st_run_watcher
  unset ST_EXIT_AFTER_POLLS ST_PRED_ID ST_SUCC_ID
  if [ "$(jq -r '.generation' "$ST_RECORDS/$REIN_POINTER_BASENAME" 2>/dev/null)" = "2" ]; then
    st_ok
  else
    st_fail "the generation advances" "generation is not 2: $(cat "$ST_RECORDS/$REIN_POINTER_BASENAME" 2>/dev/null)"
  fi

  # The shape where the successor dies right after launch confirmation (dying within a few seconds
  # from a usage cap or an expired credential does happen in practice).
  # Externally stopping the predecessor session here would take **live sessions to zero**, while the
  # record still ends up with handover_completed, making the audit look like a normal handover.
  # Before stepping it down, confirm the successor's liveness through the same one enumeration call
  # used to check the predecessor's, and if it's gone, stop without issuing a stop.
  # The accepting side's counterpart is the happy case above (a live successor steps the predecessor down as usual and completes).
  case_dir="$tmp/successor-dies-before-retire"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  ST_BROKEN_BIN="$ST_CWD/successor-death-bin"
  st_write_successor_death_shim "$ST_BROKEN_BIN" "$ST_CWD/successor-death.state" "succ-1"
  st_run_watcher
  unset ST_BROKEN_BIN
  if st_expect_status "does not step the predecessor down once the successor is gone" 1; then
    if [ "$(rein_st_count_sub "$ST_LOG" stop)" -ne 0 ]; then
      st_fail "does not issue a stop that would leave zero live sessions" "claude stop was called: $(cat "$ST_LOG")"
    elif st_log_has '"event":"predecessor_stopped"' || st_log_has '"event":"predecessor_exited"'; then
      st_fail "does not record stepping it down when it never did" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME" 2>/dev/null)"
    elif st_log_has '"event":"handover_completed"'; then
      st_fail "does not record a zero-live-sessions handover as completed" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME" 2>/dev/null)"
    else
      st_ok
    fi
  fi
  # Premise check: the successor **did clear launch confirmation** (the pointer names the
  # successor). If this doesn't hold, what's being measured is "a round that failed launch
  # confirmation", not the guard on the step-down stage.
  if [ "$(jq -r '.session_id' "$ST_RECORDS/$REIN_POINTER_BASENAME" 2>/dev/null)" = "succ-1" ]; then
    st_ok
  else
    st_fail "launch confirmation cleared, with the pointer naming the successor" \
      "$(cat "$ST_RECORDS/$REIN_POINTER_BASENAME" 2>/dev/null)"
  fi
  # Report how it stopped with **the same one sentence** used for adoption at startup (the shape
  # where only one side died) -- the same state is called by the same name wherever it's seen.
  if st_expect_notify "reports it as the shape where only one side died" \
    "rein: handover failed" "only one side of the handover died"; then
    st_ok
  fi

  # A lineage left with only the handover's last stage (stepping the predecessor down) outstanding
  # is **resumed when the watcher starts up**. There is no way to detect the state where the
  # successor is alive, the predecessor is alive, and no watcher is running, and no way to recover
  # from it, so it stays stuck -- since the pointer already names the successor, any handover
  # request from then on keeps getting rejected by R10.
  case_dir="$tmp/resume-handover"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_RECORDS/$REIN_POINTER_BASENAME" "succ-1" "successor" "$ST_CWD" 2 "pred-1"
  rein_st_write_agents "$ST_AGENTS" "$ST_CWD" "succ-1" "pred-1"
  st_run_watcher
  if st_expect_status "monitoring starts even with unfinished work left over" 0; then
    if ! rein_st_has_call "$ST_LOG" stop job-pred-1; then
      st_fail "steps the predecessor down at startup" "$(cat "$ST_LOG")"
    elif ! st_log_has '"event":"predecessor_stopped"'; then
      st_fail "records having stepped it down" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME" 2>/dev/null)"
    elif ! st_log_has '"event":"handover_completed"'; then
      st_fail "records completion of the resumed handover" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME" 2>/dev/null)"
    else
      st_ok
    fi
  fi
  # Resuming **is not itself a handover** (no successor is launched) -- folding it into the
  # acceptance path would advance the generation with no request behind it.
  if [ "$(rein_st_count_sub "$ST_LOG" "--bg")" -eq 0 ]; then
    st_ok
  else
    st_fail "does not launch a successor while resuming" "claude --bg was called: $(cat "$ST_LOG")"
  fi
  # The accepting side's counterpart: if the predecessor is already gone from enumeration, do nothing even
  # with the same-shaped pointer (always falling to "resume" would record one more completion line
  # every time, for a handover that's already done).
  case_dir="$tmp/resume-not-needed"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_RECORDS/$REIN_POINTER_BASENAME" "succ-1" "successor" "$ST_CWD" 2 "pred-gone"
  rein_st_write_agents "$ST_AGENTS" "$ST_CWD" "succ-1"
  st_run_watcher
  if st_expect_status "enters ordinary monitoring when there's nothing left over" 0; then
    if st_log_has '"event":"handover_completed"'; then
      st_fail "does not record a completion when there's nothing left over" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME" 2>/dev/null)"
    elif [ "$(rein_st_count_sub "$ST_LOG" stop)" -ne 0 ]; then
      st_fail "does not stop externally when there's nothing left over" "$(cat "$ST_LOG")"
    else
      st_ok
    fi
  fi

  # The shape where only one side died: the successor the pointer names is already gone, and only the predecessor is alive.
  # Stepping the predecessor down here would take **live sessions to zero**, while the record and
  # notification alone say "the handover completed". No automatic recovery (does not relaunch a
  # successor, does not roll back the pointer, does not stop the live predecessor) -- it stops with the cause readable.
  case_dir="$tmp/resume-successor-dead"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_RECORDS/$REIN_POINTER_BASENAME" "succ-1" "successor" "$ST_CWD" 2 "pred-1"
  rein_st_write_agents "$ST_AGENTS" "$ST_CWD" "pred-1"
  # The reason the successor went down is left in the handover log by the watcher from the round
  # that dropped it. Instead of recovering, output **that text verbatim** (folding it into a generic
  # message would leave the user with no way to trace the cause).
  rein_log_event "$ST_RECORDS/$REIN_LOG_BASENAME" "failed" \
    "stage=confirming the successor launched reason=claude --bg exited non-zero: rc=3 output=fake bg boom" \
    2 "pred-1" "succ-1"
  st_run_watcher
  if st_expect_status "does not enter monitoring when only one side is dead" 1; then
    if [ "$(rein_st_count_sub "$ST_LOG" stop)" -ne 0 ]; then
      st_fail "does not stop the live predecessor" "claude stop was called: $(cat "$ST_LOG")"
    elif st_log_has '"event":"handover_completed"'; then
      st_fail "does not record a zero-live-sessions state as completed" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME" 2>/dev/null)"
    elif [ "$(rein_st_count_sub "$ST_LOG" "--bg")" -ne 0 ]; then
      st_fail "does not relaunch a successor" "claude --bg was called: $(cat "$ST_LOG")"
    elif [ "$(jq -r '.session_id' "$ST_RECORDS/$REIN_POINTER_BASENAME" 2>/dev/null)" != "succ-1" ]; then
      st_fail "does not roll back the pointer on its own" "$(cat "$ST_RECORDS/$REIN_POINTER_BASENAME" 2>/dev/null)"
    elif [ -e "$ST_RUNTIME/$REIN_HEARTBEAT_BASENAME" ]; then
      st_fail "does not publish a heartbeat in this shape" "a heartbeat was placed: $(ls -a "$ST_RUNTIME")"
    else
      st_ok
    fi
  fi
  # The cause, verbatim. Folding this into a generic message like "cannot obtain the handover's
  # mutual exclusion" would leave the user with no way to know what actually happened.
  if st_expect_notify "gives the cause the successor died from verbatim" \
    "rein: handover failed" "rc=3 output=fake bg boom"; then
    st_ok
  fi
  # Name both sides explicitly: "the primary session on record" and "the predecessor actually
  # alive" (missing either one leaves the user unable to decide which ID to fix).
  if grep -q -e 'succ-1' "$ST_RECORDS/$REIN_WATCHER_LOG_BASENAME" &&
    grep -q -e 'pred-1' "$ST_RECORDS/$REIN_WATCHER_LOG_BASENAME"; then
    st_ok
  else
    st_fail "names both sides of the mismatch explicitly" "$(cat "$ST_RECORDS/$REIN_WATCHER_LOG_BASENAME" 2>/dev/null)"
  fi

  # A lineage with no cause on record (it died on a different machine, or the record was deleted).
  # When there's no verbatim text to give, point at **where to look instead** (never silently fold
  # this into a generic message).
  case_dir="$tmp/resume-successor-dead-no-cause"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_RECORDS/$REIN_POINTER_BASENAME" "succ-1" "successor" "$ST_CWD" 2 "pred-1"
  rein_st_write_agents "$ST_AGENTS" "$ST_CWD" "pred-1"
  st_run_watcher
  if st_expect_status "stops even with no cause on record" 1; then
    if [ "$(rein_st_count_sub "$ST_LOG" stop)" -ne 0 ]; then
      st_fail "does not stop the predecessor even when the cause can't be read" "$(cat "$ST_LOG")"
    elif ! st_expect_notify "points at where to look" \
      "rein: handover failed" "$ST_RECORDS/$REIN_WATCHER_LOG_BASENAME"; then
      :
    elif ! grep -qF -e \
      "$(rein_shell_quote "$REIN_BIN") --cwd $(rein_shell_quote "$ST_CWD") up --runtime-dir $(rein_shell_quote "$ST_RUNTIME")" \
      "$ST_RECORDS/$REIN_WATCHER_LOG_BASENAME" ||
      ! grep -qF -e \
        "$(rein_shell_quote "$REIN_BIN") --cwd $(rein_shell_quote "$ST_CWD") init --runtime-dir $(rein_shell_quote "$ST_RUNTIME")" \
        "$ST_RECORDS/$REIN_WATCHER_LOG_BASENAME"; then
      st_fail "gives both the fix and the last resort" "$(cat "$ST_RECORDS/$REIN_WATCHER_LOG_BASENAME" 2>/dev/null)"
    else
      st_ok
    fi
  fi

  # **The heartbeat keeps advancing across the handover's blocking external calls.** Between the
  # wait loops (which write it every cycle) the watcher runs external commands in the foreground:
  # `claude --bg` to launch the successor, and -- once the predecessor outlasts the grace period --
  # the enumeration resolving its job handle followed by `claude stop`. Nothing writes the
  # heartbeat while one of those is running, and each can take up to its own cap, which reaches
  # past `seat_heartbeat_max_age_sec`: a seat waiting on this very handover then reads a normally
  # processing watcher as stopped, steps down, and tells the user to run `rein up` again
  # (contract: docs/spec/runtime.md, "The watcher's heartbeat").
  # The shim deletes the heartbeat on every enumeration and records, at each blocking call,
  # whether it is back -- so this measures the gap itself rather than waiting out a real minute.
  # The predecessor is left alive (no ST_EXIT_AFTER_POLLS), which is what carries the run through
  # the external-stop stretch as well as the launch.
  case_dir="$tmp/heartbeat-across-blocking-calls"
  st_setup_case "$case_dir"
  hb_probe="$ST_CWD/hb-probe"
  ST_BROKEN_BIN="$ST_CWD/hb-probe-bin"
  st_write_heartbeat_probe_shim "$ST_BROKEN_BIN" "$ST_RUNTIME/$REIN_HEARTBEAT_BASENAME" "$hb_probe"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  st_run_watcher
  unset ST_BROKEN_BIN
  if st_expect_status "the handover completes while the heartbeat is being watched" 0; then
    st_expect_heartbeat_probe "the heartbeat is written before launching the successor" "$hb_probe/bg"
    st_expect_heartbeat_probe "the heartbeat is written before the external stop" "$hb_probe/stop"
    # The enumeration that resolves the job handle is a blocking external call too, and the
    # widest of the three (its cap is `cmd_timeout_sec x 3 + 2 seconds`). It is measured through
    # what that enumeration itself saw, since it deletes the heartbeat on its way through and the
    # record at the stop above therefore cannot reach behind it.
    st_expect_heartbeat_probe "the heartbeat is written before resolving the job handle" \
      "$hb_probe/stop-prev-agents"
  fi
}
