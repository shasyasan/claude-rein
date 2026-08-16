# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034  # selftest state is shared across sections (the caller selftest()'s locals, and the ST_* globals)
# The watcher log's size cap and recording the exit reason; the external stop after the grace
# period; what `--once` returns (whether that one item went through), and that changing the return
# value doesn't move resident behavior.
# Variables are shared with the caller selftest()'s locals through dynamic scope. Declaring a
# local inside a section would hide it from later sections, so this section file declares none.
# Not an executable script, so it carries no execute bit (outside the --selftest convention).

st_section_exit() {
  # Only the watcher log has a size cap (the handover log is the canonical audit trail -- append-only, never truncated).
  case_dir="$tmp/watcher-log-rotation"
  st_setup_case "$case_dir"
  # Put a watcher log over the cap, and a handover log even bigger than that, in place first.
  printf '%0999d\n' 0 >"$ST_RECORDS/$REIN_WATCHER_LOG_BASENAME"
  printf '{"schema":"rein.handover-log.v1","event":"placeholder"}\n' >"$ST_RECORDS/$REIN_LOG_BASENAME"
  printf '%01999d\n' 0 >>"$ST_RECORDS/$REIN_LOG_BASENAME"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  printf 'watcher_log_max_bytes=500\n' >"$ST_USER_CONFIG"
  ST_EXIT_AFTER_POLLS=2
  st_run_watcher
  unset ST_EXIT_AFTER_POLLS
  : >"$ST_USER_CONFIG"
  if st_expect_status "the handover still goes through when it rotates" 0; then
    if [ -f "$ST_RECORDS/${REIN_WATCHER_LOG_BASENAME}.1" ] &&
      [ "$(stat -f %z "$ST_RECORDS/$REIN_WATCHER_LOG_BASENAME" 2>/dev/null)" -lt 500 ]; then
      st_ok
    else
      st_fail "rotates the watcher log to one generation at the cap" \
        "$(find "$ST_RECORDS" -maxdepth 1 -exec stat -f "%N %z" {} + | tr "\n" " ")"
    fi
    # The handover log stays over the cap, neither rotated nor truncated.
    if [ ! -e "$ST_RECORDS/${REIN_LOG_BASENAME}.1" ] &&
      grep -q 'placeholder' "$ST_RECORDS/$REIN_LOG_BASENAME" &&
      [ "$(stat -f %z "$ST_RECORDS/$REIN_LOG_BASENAME" 2>/dev/null)" -gt 500 ]; then
      st_ok
    else
      st_fail "the handover log is append-only and never truncated" "$(find "$ST_RECORDS" -maxdepth 1 -exec stat -f "%N %z" {} + | tr "\n" " ")"
    fi
  fi

  # Leave the exit reason as one line (a daemon disappearing silently is the norm, so without this the cause of death can never be traced back).
  case_dir="$tmp/watcher-log-exit-reason"
  st_setup_case "$case_dir"
  st_run_watcher
  if st_expect_status "a single scan with no marker ends with 0" 0; then
    if grep -q 'exiting:' "$ST_RECORDS/$REIN_WATCHER_LOG_BASENAME" 2>/dev/null &&
      grep -q 'started monitoring' "$ST_RECORDS/$REIN_WATCHER_LOG_BASENAME" 2>/dev/null; then
      st_ok
    else
      st_fail "leaves the start and exit reasons in the watcher log" "$(cat "$ST_RECORDS/$REIN_WATCHER_LOG_BASENAME" 2>/dev/null)"
    fi
  fi

  # The predecessor has no means to end itself (measured), so it's stopped externally after the
  # grace period. Treating the grace period itself as "the cap to wait for self-exit" would leave
  # attach never returning and the seat stuck empty.
  case_dir="$tmp/exit-grace-then-stop"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  ST_EXIT_GRACE=3
  grace_started="$(rein_now_epoch)"
  st_run_watcher
  grace_elapsed="$(($(rein_now_epoch) - grace_started))"
  unset ST_EXIT_GRACE
  if st_expect_status "stops externally after the grace period and completes" 0; then
    if ! rein_st_has_call "$ST_LOG" stop job-pred-1; then
      st_fail "stops externally after the grace period" "claude stop was never called: $(cat "$ST_LOG")"
    elif ! grep -q -e 'did not exit within the 3-second grace period, so it was stopped externally' "$ST_RECORDS/$REIN_LOG_BASENAME"; then
      st_fail "leaves the grace value in the stop reason" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    else
      st_ok
    fi
    # The wait's length comes from exit_grace_sec. If it were wired to some other cap, the reason
    # text alone would claim "grace period" while the actual time taken diverged from the
    # configured value (the old "wait 300 sec for self-exit" shape would also fail this check).
    if [ "$grace_elapsed" -ge 3 ]; then
      st_ok
    else
      st_fail "the grace period's length is set by exit_grace_sec" "took ${grace_elapsed}s (shorter than the 3-second grace period)"
    fi
    # The heartbeat keeps advancing during a handover too (`--once` never runs the watch loop's
    # own update, so an advance here is proof it was written from inside the wait loop). If it
    # stopped, a waiting seat would see the heartbeat go stale by however long the handover took
    # and wrongly sound "the watcher may have stopped".
    # Compare it against **a different marker the watcher itself placed on this same run** (the
    # pointer, written before entering the grace-period wait). Comparing against the test's own
    # start time as a second-granularity difference can shrink to "grace period minus rounding
    # down to the second" instead of a full grace period, and a fast machine can land right on that boundary.
    hb_first="$(rein_mtime "$ST_RUNTIME/$REIN_HEARTBEAT_BASENAME")"
    hb_pointer="$(rein_mtime "$ST_RECORDS/$REIN_POINTER_BASENAME")"
    if [ -n "$hb_first" ] && [ -n "$hb_pointer" ] && [ "$hb_first" -gt "$hb_pointer" ]; then
      st_ok
    else
      st_fail "the heartbeat keeps advancing during a handover" \
        "the heartbeat did not advance past the pointer update: heartbeat=${hb_first} pointer=${hb_pointer}"
    fi
  fi

  # The accepting side: no stop is issued when the predecessor has already disappeared within the grace period (it must not always stop unconditionally).
  case_dir="$tmp/exits-within-grace"
  st_setup_case "$case_dir"
  printf '[]\n' >"$ST_AGENTS"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  st_run_watcher
  if st_expect_status "no stop is issued when it exits within the grace period" 0; then
    if [ "$(rein_st_count_sub "$ST_LOG" stop)" -ne 0 ]; then
      st_fail "never issues an unneeded stop" "claude stop was called: $(cat "$ST_LOG")"
    elif ! grep -q -e 'exit confirmed within the grace period' "$ST_RECORDS/$REIN_LOG_BASENAME"; then
      st_fail "records an exit confirmed within the grace period" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    else
      st_ok
    fi
  fi

  # `--once` is an interface for "did that one item go through", so **a cycle that processed no
  # marker at all returns non-zero**. Returning 0 would let the caller read its own request as
  # having been processed. There are two shapes of "processed nothing": (1) a different run held
  # the handover's mutual exclusion (busy), (2) another instance consumed it right before this run
  # could claim it (lost the race). In both, **resident monitoring never stops** (the first
  # resolves on the next cycle; the second was already carried through to completion by whichever
  # instance claimed it first) -- what it returns and whether it stops are independent axes. Only
  # a cycle with no marker at all still returns 0, as before (there was never one item to
  # process) -- pinned separately by "a single scan with no marker ends with 0" above.
  case_dir="$tmp/once-handover-busy"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  # Build the mutual-exclusion holder as a "live process" -- the discipline of never seizing a lock whose pid is alive is what drops this into busy.
  mkdir -p "$ST_RUNTIME/$REIN_HANDOVER_LOCK_DIRNAME"
  printf '%s\n' "$$" >"$ST_RUNTIME/$REIN_HANDOVER_LOCK_DIRNAME/pid"
  st_run_watcher
  if st_expect_status "a single scan that can't get the mutual exclusion returns non-zero" 1; then
    if [ ! -f "$ST_RUNTIME/$REIN_MARKER_BASENAME" ]; then
      st_fail "a cycle that can't get the mutual exclusion never touches the marker" "the marker disappeared (consumed without being processed)"
    elif [ "$(rein_st_count_sub "$ST_LOG" "--bg")" -ne 0 ]; then
      st_fail "a cycle that can't get the mutual exclusion never launches a successor" "claude --bg was called: $(cat "$ST_LOG")"
    elif ! grep -q -e 'did not process it because a different run is advancing the handover' \
      "$ST_RECORDS/$REIN_WATCHER_LOG_BASENAME"; then
      st_fail "leaves the mutual-exclusion reason for the return value" "$(cat "$ST_RECORDS/$REIN_WATCHER_LOG_BASENAME" 2>/dev/null)"
    else
      st_ok
    fi
  fi
  # The accepting side's counterpart: confirm the non-zero came from the mutual exclusion (a marker
  # merely being present does not itself cause non-zero). With the same marker still in place,
  # releasing the mutual exclusion lets the next single scan succeed as usual and return 0.
  rm -rf "${ST_RUNTIME:?}/$REIN_HANDOVER_LOCK_DIRNAME"
  st_run_watcher
  if st_expect_status "the same request goes through with 0 once the mutual exclusion clears" 0; then
    if ! st_log_has '"event":"handover_completed"'; then
      st_fail "the handover completes once the mutual exclusion clears" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    else
      st_ok
    fi
  fi

  # The resident watcher is not stopped by the mutual exclusion (changing the return value must not move resident behavior too).
  case_dir="$tmp/daemon-handover-busy"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  mkdir -p "$ST_RUNTIME/$REIN_HANDOVER_LOCK_DIRNAME"
  printf '%s\n' "$$" >"$ST_RUNTIME/$REIN_HANDOVER_LOCK_DIRNAME/pid"
  st_run_watcher_daemon_bg "$ST_DAEMON_GUARD_SEC"
  # Startup adoption also runs under the mutual exclusion, so seeing this line confirms it dropped
  # into busy -- a run that dies at 142 without this line appearing never exercised the mutual
  # exclusion at all, so name that and fail it explicitly.
  if ! st_wait_for_watcher_log 'skipping startup adoption'; then
    st_fail "this test exercises the mutual exclusion's busy path" \
      "$(cat "$ST_RECORDS/$REIN_WATCHER_LOG_BASENAME" 2>/dev/null)"
  else
    st_ok
  fi
  st_alarm_watcher_daemon
  daemon_rc="$(cat "$ST_DAEMON_RC_FILE" 2>/dev/null)"
  if [ "$daemon_rc" = "142" ]; then
    st_ok
  else
    st_fail "not getting the mutual exclusion does not end the resident watcher" \
      "the watcher exited on its own with exit ${daemon_rc}: $(cat "$ST_DAEMON_OUT" 2>/dev/null)"
  fi
  rm -rf "${ST_RUNTIME:?}/$REIN_HANDOVER_LOCK_DIRNAME"

  # A cycle that lost the race (another instance consumed the marker right before claim).
  case_dir="$tmp/once-handover-lost-race"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  ST_BROKEN_BIN="$ST_CWD/vanish-bin"
  st_write_marker_vanish_shim "$ST_BROKEN_BIN" "$ST_RUNTIME/$REIN_MARKER_BASENAME"
  st_run_watcher
  unset ST_BROKEN_BIN
  if st_expect_status "a single scan for an already-consumed marker returns non-zero" 1; then
    if [ "$(rein_st_count_sub "$ST_LOG" "--bg")" -ne 0 ]; then
      st_fail "a cycle that lost the race never launches a successor" "claude --bg was called: $(cat "$ST_LOG")"
    elif st_log_has '"event":"handover_completed"'; then
      st_fail "never records a cycle it never processed as complete" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    elif ! grep -q -e 'a different instance processed the handover request first' \
      "$ST_RECORDS/$REIN_WATCHER_LOG_BASENAME"; then
      st_fail "leaves losing the race as the reason" "$(cat "$ST_RECORDS/$REIN_WATCHER_LOG_BASENAME" 2>/dev/null)"
    else
      st_ok
    fi
  fi
  # Sanity-check the premise: claim was actually reached. Only claim creates `processing/`, so its
  # presence is proof that the mutual exclusion was held and the marker disappeared right before
  # claim -- the exact window this is meant to exercise (its absence would mean the marker
  # disappeared too early, and this ran a no-marker cycle instead).
  if [ -d "$ST_RUNTIME/$REIN_PROCESSING_DIRNAME" ]; then
    st_ok
  else
    st_fail "this test exercises the window right before claim" \
      "processing/ was never created (the marker disappeared before claim): $(ls -a "$ST_RUNTIME" 2>&1)"
  fi

  # The resident watcher does not stop even after losing the race.
  case_dir="$tmp/daemon-handover-lost-race"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  ST_BROKEN_BIN="$ST_CWD/vanish-bin"
  st_write_marker_vanish_shim "$ST_BROKEN_BIN" "$ST_RUNTIME/$REIN_MARKER_BASENAME"
  st_run_watcher_daemon_bg "$ST_DAEMON_GUARD_SEC"
  if ! st_wait_for_path "$ST_RUNTIME/$REIN_PROCESSING_DIRNAME"; then
    st_fail "this test exercises the window right before claim (resident)" \
      "processing/ was never created: $(cat "$ST_DAEMON_OUT" 2>/dev/null)"
  else
    st_ok
  fi
  st_alarm_watcher_daemon
  unset ST_BROKEN_BIN
  daemon_rc="$(cat "$ST_DAEMON_RC_FILE" 2>/dev/null)"
  if [ "$daemon_rc" = "142" ]; then
    st_ok
  else
    st_fail "losing the race does not end the resident watcher" \
      "the watcher exited on its own with exit ${daemon_rc}: $(cat "$ST_DAEMON_OUT" 2>/dev/null)"
  fi

}
