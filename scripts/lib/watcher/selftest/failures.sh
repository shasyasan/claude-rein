# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034  # selftest state is shared across sections (the caller selftest()'s locals, and the ST_* globals)
# Don't let a stage failure go silent: an external command that never returns, a failed stop
# command, an unwritable handover log, a failed notification path, unreadable enumeration.
# Variables are shared with the caller selftest()'s locals through dynamic scope. Declaring a
# local inside a section would hide it from later sections, so this section file declares none.
# Not an executable script, so it carries no execute bit (outside the --selftest convention).

st_section_failures() {
  # Only the variables used solely in this section stay local to this function (anything shared
  # across sections goes in selftest()'s locals, as above).
  local handover_lock
  # The shape where the external command itself never returns. Without a cap, an unattended watcher would hang here forever.
  case_dir="$tmp/bg-hangs"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  ST_BG_HANG=5
  ST_CMD_TIMEOUT=1
  st_run_watcher
  unset ST_BG_HANG ST_CMD_TIMEOUT
  if st_expect_status "cuts off a launch command that never returns, at the cap" 1; then
    if [ -f "$ST_RECORDS/$REIN_POINTER_BASENAME" ]; then
      st_fail "does not advance the pointer on exceeding the cap" "current.json was written"
    elif ! grep -q -e 'exceeded the 1-second cap' "$ST_RECORDS/$REIN_LOG_BASENAME"; then
      st_fail "leaves exceeding the cap as the reason" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    else
      st_ok
    fi
  fi

  # A failed stop command also leaves the exit code and stderr's last line on record.
  case_dir="$tmp/stop-fails"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  ST_STOP_FAIL=1
  st_run_watcher
  unset ST_STOP_FAIL
  if st_expect_status "stops on a failed stop command" 1; then
    if st_log_has '"event":"handover_completed"'; then
      st_fail "does not treat a failed stop as completed" "handover_completed was recorded"
    elif ! grep -q -e 'rc=4' "$ST_RECORDS/$REIN_LOG_BASENAME" ||
      ! grep -q -e 'fake stop boom' "$ST_RECORDS/$REIN_LOG_BASENAME"; then
      st_fail "leaves the stop failure's reason in the handover log" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    else
      st_ok
    fi
  fi

  # A watcher that can't write the handover log can't be audited. Fail it before entering monitoring (don't quietly let the handover proceed anyway).
  case_dir="$tmp/log-unwritable"
  st_setup_case "$case_dir"
  rm -f "$ST_RECORDS/$REIN_LOG_BASENAME"
  mkdir -p "$ST_RECORDS/$REIN_LOG_BASENAME"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  st_run_watcher
  if st_expect_status "does not enter monitoring when the handover log can't be written" 1; then
    if [ -s "$ST_LOG" ]; then
      st_fail "does not launch a successor when the log can't be written" "claude was called: $(cat "$ST_LOG")"
    elif ! st_expect_notify "notifies about the log being unwritable" \
      "rein: handover failed" "cannot write watch_started to the handover log"; then
      :
    else
      case "$ST_OUT" in
        *"cannot write watch_started to the handover log"*)
          st_ok
          ;;
        *)
          st_fail "gives a reason for the log being unwritable" "${ST_OUT}"
          ;;
      esac
    fi
  fi

  # The shape where the pointer's pathname is a directory. `mv` moves the temp file **into** the
  # destination when it's a directory and returns 0, so if the writer doesn't check the shape,
  # `current.json` stays a directory while the handover reads as completed (the reader parses
  # `current.json` as JSON, so the lineage's pointer never resolves again from then on, even though
  # the record shows the generation advanced).
  case_dir="$tmp/pointer-is-dir"
  st_setup_case "$case_dir"
  mkdir -p "$ST_RECORDS/$REIN_POINTER_BASENAME"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  st_run_watcher
  if st_expect_status "does not treat the handover as completed when the pointer's pathname is a directory" 1; then
    if st_log_has '"event":"pointer_updated"'; then
      st_fail "does not record an unwritten pointer as updated" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    elif st_log_has '"event":"handover_completed"'; then
      st_fail "does not treat a round that couldn't write the pointer as completed" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    elif [ ! -d "$ST_RECORDS/$REIN_POINTER_BASENAME" ] ||
      [ -n "$(find "$ST_RECORDS/$REIN_POINTER_BASENAME" -mindepth 1 -print)" ]; then
      st_fail "does not write into the pointer's pathname" \
        "$(find "$ST_RECORDS/$REIN_POINTER_BASENAME" -print)"
    elif ! grep -q -e 'cannot write current.json' "$ST_RECORDS/$REIN_LOG_BASENAME"; then
      st_fail "leaves not being able to write the pointer as the reason" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    else
      st_ok
    fi
  fi

  # Even if where the log writes to breaks partway through a handover, don't treat it as completed
  # while unable to write the completion event.
  case_dir="$tmp/log-breaks-midway"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  ST_SABOTAGE="$ST_RECORDS/$REIN_LOG_BASENAME"
  ST_EXIT_AFTER_POLLS=2
  st_run_watcher
  unset ST_SABOTAGE ST_EXIT_AFTER_POLLS
  if st_expect_status "fails when the completion event can't be written" 1; then
    if [ ! -f "$ST_RECORDS/$REIN_POINTER_BASENAME" ]; then
      st_fail "a failure to record completion happens at the final stage" "the pointer was never written (it failed at a different stage): ${ST_OUT}"
    elif ! st_expect_notify "notifies about the failure to record completion" \
      "rein: handover failed" "cannot write handover_completed to the handover log"; then
      :
    else
      case "$ST_OUT" in
        *"cannot write handover_completed to the handover log"*)
          st_ok
          ;;
        *)
          st_fail "gives a reason for the failure to record completion" "${ST_OUT}"
          ;;
      esac
    fi
  fi

  # Don't stay silent when the notification path itself fails either (a GUI notification's delivery can't be confirmed).
  case_dir="$tmp/notify-fails"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "2026/08/15 04:12" "$ST_HANDOFF" "$ST_CWD"
  ST_OSASCRIPT_FAIL=1
  st_run_watcher
  unset ST_OSASCRIPT_FAIL
  if st_expect_status "still returns a rejection even when notification fails" 1; then
    case "$ST_OUT" in
      *"rein: GUI notification failed"*"fake osascript boom"*)
        st_ok
        ;;
      *)
        st_fail "appends the notification failure to stderr" "${ST_OUT}"
        ;;
    esac
  fi

  # The accepting side: a round where notification succeeds prints no failure line (making sure the check above isn't vacuously true).
  case_dir="$tmp/notify-succeeds"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "2026/08/15 04:12" "$ST_HANDOFF" "$ST_CWD"
  st_run_watcher
  case "$ST_OUT" in
    *"rein: GUI notification failed"*)
      st_fail "prints no failure line when notification goes through" "${ST_OUT}"
      ;;
    *)
      st_ok
      ;;
  esac

  # Don't collapse the handover's mutual exclusion being "impossible to prepare" (can't write to
  # the location -- won't resolve next cycle either) into the same wording as "another run holding
  # it" (resolves next cycle). Collapsing them turns a broken location into "another run is
  # handling the handover", and no one goes to fix it while the handover just stays stuck.
  case_dir="$tmp/handover-lock-unusable"
  st_setup_case "$case_dir"
  printf 'handoff fixture\n' >"$ST_RECORDS/$REIN_HANDOFF_BASENAME"
  # Prepare the location **completely** first (make it a read-only shape before making it
  # unwritable -- pin down the failure to the handover's mutual exclusion, not to "can't prepare
  # the location"). Provisioning goes through the shared function rather than writing the owner
  # file by hand, so that as what a claimed location holds grows (it now holds a lineage token
  # too), this fixture can never be left half-prepared and quietly start measuring a different
  # failure.
  if ! rein_ensure_runtime_dir "$ST_RUNTIME" "$ST_CWD"; then
    st_fail "the fixture's runtime location can be fully prepared" "$REIN_RUNTIME_ERROR"
  fi
  ST_MODE_ARGS=(--bootstrap --once)
  chmod 500 "$ST_RUNTIME"
  st_run_watcher
  chmod 700 "$ST_RUNTIME"
  ST_MODE_ARGS=(--once)
  if st_expect_status "stops bootstrap when the location can't be written" 1; then
    case "$ST_OUT" in
      *"another run is in the middle of a handover"*)
        st_fail "does not pass off an unpreparable lock as busy" "${ST_OUT}"
        ;;
      *"cannot prepare the handover lock"*)
        st_ok
        ;;
      *)
        st_fail "gives a reason for the unpreparable lock" "${ST_OUT}"
        ;;
    esac
  fi

  # Don't leave behind a daemon that pretends to have succeeded on a round that **failed to release**
  # the handover's mutual exclusion. If it can't be released, the lock stays behind holding its own
  # live pid, so it never goes stale either -- every future claim reads "someone holds it" forever
  # (that location stops processing handover requests entirely, while only the heartbeat keeps
  # updating so it looks healthy). Create the release failure by making the location unwritable right
  # at the handover's last external command (stopping the predecessor) -- blocking exactly one point,
  # after the lock is claimed and before it's released.
  case_dir="$tmp/handover-release-fails"
  st_setup_case "$case_dir"
  handover_lock="$ST_RUNTIME/$REIN_HANDOVER_LOCK_DIRNAME"
  ST_BROKEN_BIN="$tmp/lock-freeze-bin"
  mkdir -p "$ST_BROKEN_BIN"
  {
    printf '#!/usr/bin/env bash\n'
    # shellcheck disable=SC2016  # the shim's own body (expanding $1 is up to whoever launches the shim, not here)
    printf 'if [ "${1:-}" = "stop" ]; then chmod 500 "%s"; fi\n' "$ST_RUNTIME"
    printf 'exec "%s/claude" "$@"\n' "$ST_BIN"
  } >"$ST_BROKEN_BIN/claude"
  chmod +x "$ST_BROKEN_BIN/claude"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  st_run_watcher
  unset ST_BROKEN_BIN
  chmod 700 "$ST_RUNTIME"
  if st_expect_status "does not end a round that couldn't release the lock as a success" 1; then
    if [ ! -e "$handover_lock" ]; then
      st_fail "can create a release failure" "the handover's mutual exclusion isn't still there (this case failed to trigger a release failure)"
    elif ! st_expect_notify "notifies that the lock couldn't be released" \
      "rein: handover failed" "stage=releasing the handover lock"; then
      :
    else
      st_ok
    fi
  fi
  rm -rf "${handover_lock:?}"

  # Don't equate "can't read enumeration" with "the successor hasn't shown up yet" (the shape where it silently waits out the limit and fails for the wrong reason).
  case_dir="$tmp/agents-unreadable"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  ST_AGENTS_FAIL_AFTER=1
  ST_LAUNCH_TIMEOUT=30
  st_run_watcher
  unset ST_AGENTS_FAIL_AFTER ST_LAUNCH_TIMEOUT
  if st_expect_status "fails immediately, without waiting, when enumeration can't be read" 1; then
    if [ -f "$ST_RECORDS/$REIN_POINTER_BASENAME" ]; then
      st_fail "does not advance the pointer when enumeration can't be read" "current.json was written"
    elif grep -q -e 'and still cannot confirm the launch' "$ST_RECORDS/$REIN_LOG_BASENAME"; then
      st_fail "does not call unreadable enumeration an expired limit" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    elif ! grep -q -e 'cannot read claude agents --json' "$ST_RECORDS/$REIN_LOG_BASENAME" ||
      ! grep -q -e 'fake agents boom' "$ST_RECORDS/$REIN_LOG_BASENAME"; then
      st_fail "leaves unreadable enumeration on record with a reason and stderr" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    else
      st_ok
    fi
  fi
  # A round where enumeration is permanently unreadable can't identify the launched successor --
  # can't even issue a stop. **Not stepping down silently** is the requirement -- name explicitly
  # that it's left running, and leave a path to clean it up.
  if [ "$(rein_st_count_sub "$ST_LOG" stop)" -ne 0 ]; then
    st_fail "does not issue a stop to a successor it can't identify" "claude stop was called: $(cat "$ST_LOG")"
  elif ! st_log_has '"event":"successor_orphaned"'; then
    st_fail "records leaving it running unmanaged" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
  else
    st_ok
  fi

  # The shape where enumeration is only unreadable for one round of launch confirmation (the CLI
  # briefly not responding, right after waking from sleep). The successor is already launched, so
  # stepping down as-is would leave an unmanaged session the pointer doesn't name. If enumeration is
  # back and the successor can be uniquely identified, step it down on the spot before failing.
  case_dir="$tmp/launch-abandon-after-agents-blip"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  # The 1st enumeration call is who's present before launch (the before set). The 2nd call onward is
  # launch confirmation, and the enumeration entry point retries a transient failure up to 3 times,
  # so fail exactly those 3 calls to leave launch confirmation ending in 2 (unreadable). Make it
  # readable again after that -- to catch the shape "could have re-identified it, but left it as is".
  ST_BROKEN_BIN="$ST_CWD/agents-blip-bin"
  mkdir -p "$ST_BROKEN_BIN"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'blip_count_file="%s"\n' "$ST_CWD/agents-blip.count"
    printf 'blip_real_claude="%s"\n' "$ST_BIN/claude"
    cat <<'SHIM'
if [ "${1:-}" = "agents" ]; then
  blip_n=0
  [ -f "$blip_count_file" ] && blip_n="$(cat "$blip_count_file")"
  blip_n=$((blip_n + 1))
  printf '%s' "$blip_n" >"$blip_count_file"
  if [ "$blip_n" -ge 2 ] && [ "$blip_n" -le 4 ]; then
    printf 'fake agents blip\n' >&2
    exit 1
  fi
fi
exec "$blip_real_claude" "$@"
SHIM
  } >"$ST_BROKEN_BIN/claude"
  chmod +x "$ST_BROKEN_BIN/claude"
  st_run_watcher
  unset ST_BROKEN_BIN
  if st_expect_status "exits non-zero when launch confirmation fails" 1; then
    if [ -f "$ST_RECORDS/$REIN_POINTER_BASENAME" ]; then
      st_fail "does not advance the pointer when launch confirmation fails" "current.json was written"
    elif ! rein_st_has_call "$ST_LOG" stop job-succ-1; then
      st_fail "steps down the launched successor" "claude stop job-succ-1 was never called: $(cat "$ST_LOG")"
    elif [ "$(rein_st_count_sub "$ST_LOG" stop)" -ne 1 ]; then
      st_fail "only the successor gets stepped down" "stop wasn't called exactly once (the predecessor got stopped too): $(cat "$ST_LOG")"
    elif ! st_log_has '"event":"successor_stopped"'; then
      st_fail "records having stepped it down" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    else
      st_ok
    fi
  fi

  # A round that can't write the pointer. The successor is already launched, and only the pointer is
  # missing -- leaving this shape as is leaves an unmanaged session behind. Step down a successor
  # that can be identified, on the spot.
  case_dir="$tmp/launch-abandon-after-pointer-fail"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  ST_SABOTAGE="$ST_RECORDS/$REIN_POINTER_BASENAME"
  st_run_watcher
  unset ST_SABOTAGE
  if st_expect_status "exits non-zero when the pointer can't be written" 1; then
    if ! grep -q -e 'stage=updating the pointer' "$ST_RECORDS/$REIN_LOG_BASENAME"; then
      st_fail "records the failed stage as updating the pointer" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    elif ! rein_st_has_call "$ST_LOG" stop job-succ-1; then
      st_fail "steps down a successor with nowhere to point" "claude stop job-succ-1 was never called: $(cat "$ST_LOG")"
    elif [ "$(rein_st_count_sub "$ST_LOG" stop)" -ne 1 ]; then
      st_fail "only the successor gets stepped down" "stop wasn't called exactly once (the predecessor got stopped too): $(cat "$ST_LOG")"
    elif ! st_log_has '"event":"successor_stopped"'; then
      st_fail "records having stepped it down" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    else
      st_ok
    fi
  fi
  rm -rf "${ST_RECORDS:?}/$REIN_POINTER_BASENAME"

}
