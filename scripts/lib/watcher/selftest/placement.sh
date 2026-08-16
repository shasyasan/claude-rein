# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034  # selftest state is shared across sections (the caller selftest()'s locals, and the ST_* globals)
# The edges of the freshness windows; the freshness thresholds moved from the config layer; the
# runtime location (via an environment variable); an unusable archive destination; and the
# listing becoming unreadable partway through a handover.
# Variables are shared with the caller selftest()'s locals through dynamic scope. Declaring a
# local inside a section would hide it from later sections, so this section file declares none.
# Not an executable script, so it carries no execute bit (outside the --selftest convention).

st_section_placement() {
  # R8: the handoff document's mtime is in the future (past the allowed clock skew) -- it cannot serve as proof the handoff already happened.
  case_dir="$tmp/future-handoff"
  st_setup_case "$case_dir"
  st_touch_epoch "$ST_HANDOFF" "$(($(rein_now_epoch) + 3600))"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  st_run_watcher
  st_reject_case "rejects a handoff document with a future mtime" "R8"

  # R7's lower edge is inclusive (exactly the window's width passes; one second past it fails).
  # Without pinning the boundary to a real value, changing the window's default would shift the
  # accepting side along with it and the test would stop testing anything.
  case_dir="$tmp/window-edge-inside"
  st_setup_case "$case_dir"
  marker_epoch="$(rein_now_epoch)"
  st_touch_epoch "$ST_HANDOFF" "$((marker_epoch - 600))"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" \
    "$(TZ=UTC date -u -r "$marker_epoch" +%Y-%m-%dT%H:%M:%SZ)" "$ST_HANDOFF" "$ST_CWD"
  ST_EXIT_AFTER_POLLS=2
  st_run_watcher
  unset ST_EXIT_AFTER_POLLS
  st_accept_case "a handoff document exactly at the window's edge (600 sec) passes"

  case_dir="$tmp/window-edge-outside"
  st_setup_case "$case_dir"
  marker_epoch="$(rein_now_epoch)"
  st_touch_epoch "$ST_HANDOFF" "$((marker_epoch - 601))"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" \
    "$(TZ=UTC date -u -r "$marker_epoch" +%Y-%m-%dT%H:%M:%SZ)" "$ST_HANDOFF" "$ST_CWD"
  st_run_watcher
  st_reject_case "rejects a handoff document one second past the window (601 sec)" "R7"

  # The 3 freshness thresholds (marker_max_age_sec, max_clock_skew_sec, handoff_fresh_window_sec)
  # are exposed as adjustable settings. Measuring only against the defaults would leave the
  # binding to the config layer unverified -- falling back to the default, or reading some other
  # key's value, would both produce the same test result and pass unnoticed. For every key, set a
  # value that produces the opposite of the default's result, and exercise both the narrowed side
  # (rejects) and the widened side (accepts). On the rejecting side, also check the actual value in the
  # rejection reason, pinning that the value used to judge it really came from the setting.

  # Narrow marker_max_age_sec from its default of 900 to 120 -- 300 elapsed seconds, which passes by default, now fails.
  case_dir="$tmp/marker-age-config-narrow"
  st_setup_case "$case_dir"
  printf 'marker_max_age_sec=120\n' >"$ST_USER_CONFIG"
  marker_epoch="$(($(rein_now_epoch) - 300))"
  st_touch_epoch "$ST_HANDOFF" "$marker_epoch"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" \
    "$(TZ=UTC date -u -r "$marker_epoch" +%Y-%m-%dT%H:%M:%SZ)" "$ST_HANDOFF" "$ST_CWD"
  st_run_watcher
  st_reject_case "rejects a stale marker under the configured cap (120 sec)" "R5" "120 sec cap"

  # Widen marker_max_age_sec to 1800 -- 1200 elapsed seconds, which fails R5 by default, now passes.
  case_dir="$tmp/marker-age-config-wide"
  st_setup_case "$case_dir"
  printf 'marker_max_age_sec=1800\n' >"$ST_USER_CONFIG"
  marker_epoch="$(($(rein_now_epoch) - 1200))"
  st_touch_epoch "$ST_HANDOFF" "$marker_epoch"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" \
    "$(TZ=UTC date -u -r "$marker_epoch" +%Y-%m-%dT%H:%M:%SZ)" "$ST_HANDOFF" "$ST_CWD"
  ST_EXIT_AFTER_POLLS=2
  st_run_watcher
  unset ST_EXIT_AFTER_POLLS
  st_accept_case "a marker from 1200 sec ago passes under the configured cap (1800 sec)"

  # Narrow max_clock_skew_sec from its default of 60 to 10 -- "a handoff document updated 30 sec
  # after the marker", which passes by default, now fails on R7's upper bound.
  case_dir="$tmp/clock-skew-config-narrow"
  st_setup_case "$case_dir"
  printf 'max_clock_skew_sec=10\n' >"$ST_USER_CONFIG"
  marker_epoch="$(($(rein_now_epoch) - 30))"
  st_touch_epoch "$ST_HANDOFF" "$((marker_epoch + 30))"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" \
    "$(TZ=UTC date -u -r "$marker_epoch" +%Y-%m-%dT%H:%M:%SZ)" "$ST_HANDOFF" "$ST_CWD"
  st_run_watcher
  st_reject_case "rejects a handoff document updated later than the configured skew (10 sec)" "R7" "allowed skew 10 sec"

  # Widen max_clock_skew_sec to 600 -- a 300 sec gap, which fails R7's upper bound by default, now passes.
  case_dir="$tmp/clock-skew-config-wide"
  st_setup_case "$case_dir"
  printf 'max_clock_skew_sec=600\n' >"$ST_USER_CONFIG"
  marker_epoch="$(($(rein_now_epoch) - 300))"
  st_touch_epoch "$ST_HANDOFF" "$((marker_epoch + 300))"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" \
    "$(TZ=UTC date -u -r "$marker_epoch" +%Y-%m-%dT%H:%M:%SZ)" "$ST_HANDOFF" "$ST_CWD"
  ST_EXIT_AFTER_POLLS=2
  st_run_watcher
  unset ST_EXIT_AFTER_POLLS
  st_accept_case "a handoff document with a 300 sec gap passes under the configured skew (600 sec)"

  # Narrow handoff_fresh_window_sec from its default of 600 to 120 -- "a handoff document 121 sec
  # before the marker", which passes by default, now fails (the lower edge is inclusive on the
  # configured side too -- it only fails starting at 121 sec).
  case_dir="$tmp/fresh-window-config-narrow"
  st_setup_case "$case_dir"
  printf 'handoff_fresh_window_sec=120\n' >"$ST_USER_CONFIG"
  marker_epoch="$(rein_now_epoch)"
  st_touch_epoch "$ST_HANDOFF" "$((marker_epoch - 121))"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" \
    "$(TZ=UTC date -u -r "$marker_epoch" +%Y-%m-%dT%H:%M:%SZ)" "$ST_HANDOFF" "$ST_CWD"
  st_run_watcher
  st_reject_case "rejects a handoff document one second past the configured window (121 sec)" "R7" "window 120 sec"

  # Widen handoff_fresh_window_sec to 1800 -- a handoff document from 1200 sec before the marker, which fails R7's lower bound by default, now passes.
  case_dir="$tmp/fresh-window-config-wide"
  st_setup_case "$case_dir"
  printf 'handoff_fresh_window_sec=1800\n' >"$ST_USER_CONFIG"
  marker_epoch="$(rein_now_epoch)"
  st_touch_epoch "$ST_HANDOFF" "$((marker_epoch - 1200))"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" \
    "$(TZ=UTC date -u -r "$marker_epoch" +%Y-%m-%dT%H:%M:%SZ)" "$ST_HANDOFF" "$ST_CWD"
  ST_EXIT_AFTER_POLLS=2
  st_run_watcher
  unset ST_EXIT_AFTER_POLLS
  st_accept_case "a handoff document from 1200 sec before the marker passes under the configured window (1800 sec)"

  # The runtime location can also be moved through an environment variable (the contract's own "movable" interface).
  case_dir="$tmp/runtime-dir-env"
  st_setup_case "$case_dir"
  ST_RUNTIME_ARGS=()
  ST_RUNTIME_ENV="$ST_RUNTIME"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  ST_EXIT_AFTER_POLLS=2
  st_run_watcher
  unset ST_EXIT_AFTER_POLLS
  st_accept_case "hands over using the runtime directory from REIN_RUNTIME_DIR"

  # An unusable archive destination: the rejecting side must not be allowed to proceed unconsumed, same as the accepting side.
  case_dir="$tmp/archive-rejected-fails"
  st_setup_case "$case_dir"
  : >"$ST_RUNTIME/$REIN_REJECTED_DIRNAME"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "2026/08/15 04:12" "$ST_HANDOFF" "$ST_CWD"
  st_run_watcher
  if st_expect_status "a failed archive on rejection is a stage failure" 1; then
    if st_log_has '"event":"marker_rejected"'; then
      st_fail "does not record a rejection that couldn't be archived" "marker_rejected was recorded without archiving it: $(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    elif ! grep -q -e 'it remains unconsumed' "$ST_RECORDS/$REIN_LOG_BASENAME"; then
      st_fail "leaves the archive failure with its reason" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    elif ! st_expect_notify_matches_event "notifies on the archive failure" \
      "rein: handover failed" "stage=archiving the marker" "failed"; then
      :
    else
      st_ok
    fi
  fi

  case_dir="$tmp/archive-processed-fails"
  st_setup_case "$case_dir"
  : >"$ST_RUNTIME/$REIN_PROCESSED_DIRNAME"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  st_run_watcher
  if st_expect_status "does not launch a successor when the accepted archive fails" 1; then
    if [ "$(rein_st_count_sub "$ST_LOG" "--bg")" -ne 0 ]; then
      st_fail "does not proceed to the handover without being able to archive it" "claude --bg was called: $(cat "$ST_LOG")"
    elif ! grep -q -e 'cannot move it to processed' "$ST_RECORDS/$REIN_LOG_BASENAME"; then
      st_fail "leaves the accepting-side archive failure with its reason" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    else
      st_ok
    fi
  fi

  # The listing is unreadable from the very start: presence before launch can't be confirmed, so
  # it stops before launching a successor (launching without knowing who was already present would
  # make it impossible to later tell which entries the launch itself added).
  case_dir="$tmp/agents-fail-before-launch"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  ST_AGENTS_FAIL=1
  st_run_watcher
  unset ST_AGENTS_FAIL
  if st_expect_status "stops when the listing can't be read before launch" 1; then
    if [ "$(rein_st_count_sub "$ST_LOG" "--bg")" -ne 0 ]; then
      st_fail "does not launch a successor with the listing unreadable" "claude --bg was called: $(cat "$ST_LOG")"
    elif ! grep -q -e 'cannot confirm who was present before launch' "$ST_RECORDS/$REIN_LOG_BASENAME" ||
      ! grep -q -e 'fake agents boom' "$ST_RECORDS/$REIN_LOG_BASENAME"; then
      st_fail "leaves the pre-launch listing failure with its reason and stderr" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    else
      st_ok
    fi
  fi

  # Partway through a handover (after the pointer is updated), the listing becomes unreadable: the predecessor's exit can't be confirmed, so it's not treated as complete.
  case_dir="$tmp/agents-fail-at-exit-check"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  ST_AGENTS_FAIL_AFTER=2
  st_run_watcher
  unset ST_AGENTS_FAIL_AFTER
  if st_expect_status "fails when the listing can't be read at exit confirmation" 1; then
    if [ ! -f "$ST_RECORDS/$REIN_POINTER_BASENAME" ]; then
      st_fail "exit confirmation is the stage after launch confirmation" "the pointer was never written (it failed at a different stage): ${ST_OUT}"
    elif st_log_has '"event":"handover_completed"'; then
      st_fail "does not treat it as complete while the exit can't be confirmed" "handover_completed was recorded"
    elif ! grep -q -e "stage=confirming the predecessor's exit" "$ST_RECORDS/$REIN_LOG_BASENAME"; then
      st_fail "records the exit-confirmation failure with its stage" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    else
      st_ok
    fi
  fi

}
