# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034  # selftest state is shared across sections (the caller selftest()'s locals, and the ST_* globals)
# How config-sourced values take effect: the model passed to a successor, the supplementary-notes
# hint, per-cycle rereading, and the runtime location drifting after startup.
# Variables are shared with the caller selftest()'s locals through dynamic scope. Declaring a
# local inside a section would hide it from later sections, so this section file declares none.
# Not an executable script, so it carries no execute bit (outside the --selftest convention).

st_section_config() {
  # config's model carries through to the successor's launch (the way a lineage pins a model across generations).
  case_dir="$tmp/model-from-config"
  st_setup_case "$case_dir"
  printf 'model=opus\n' >"$ST_USER_CONFIG"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  ST_EXIT_AFTER_POLLS=2
  st_run_watcher
  unset ST_EXIT_AFTER_POLLS
  : >"$ST_USER_CONFIG"
  if st_expect_status "a handover goes through with model set" 0; then
    bg_call="$(rein_st_call_index "$ST_LOG" "--bg")"
    if [ "$bg_call" -ne 0 ] &&
      [ "$(rein_st_call_argc "$ST_LOG" "$bg_call")" -eq "$((ST_BG_ARGC_BASE + 2))" ] &&
      [ "$(rein_st_call_arg "$ST_LOG" "$bg_call" 6)" = "--model" ] &&
      [ "$(rein_st_call_arg "$ST_LOG" "$bg_call" 7)" = "opus" ]; then
      st_ok
    else
      st_fail "model carries through to the successor's launch arguments" "the launch arguments weren't as expected: $(cat "$ST_LOG")"
    fi
  fi

  # The accepting side: with model unset, --model is never passed (defer to the CLI's own default).
  case_dir="$tmp/model-unset"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  ST_EXIT_AFTER_POLLS=2
  st_run_watcher
  unset ST_EXIT_AFTER_POLLS
  if st_expect_status "a handover goes through with model unset" 0; then
    bg_call="$(rein_st_call_index "$ST_LOG" "--bg")"
    if [ "$bg_call" -ne 0 ] && [ "$(rein_st_call_argc "$ST_LOG" "$bg_call")" -eq "$ST_BG_ARGC_BASE" ]; then
      st_ok
    else
      st_fail "never passes --model when unset" "$(cat "$ST_LOG")"
    fi
  fi

  # kickoff_note_path only hints where it lives, in one line (rein never reads its contents).
  case_dir="$tmp/kickoff-note"
  st_setup_case "$case_dir"
  printf 'note fixture\n' >"$ST_CWD/note.md"
  printf 'kickoff_note_path=%s\n' "$ST_CWD/note.md" >"$ST_USER_CONFIG"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  ST_EXIT_AFTER_POLLS=2
  st_run_watcher
  unset ST_EXIT_AFTER_POLLS
  : >"$ST_USER_CONFIG"
  if st_expect_status "a handover with a note hint goes through" 0; then
    bg_call="$(rein_st_call_index "$ST_LOG" "--bg")"
    kickoff_line="$(rein_st_call_arg "$ST_LOG" "$bg_call" "$ST_BG_ARGC_BASE")"
    case "$kickoff_line" in
      *"Supplementary notes for this project live at ${ST_CWD}/note.md"*)
        st_ok
        ;;
      *)
        st_fail "puts the note's location in kickoff as one line" "${kickoff_line}"
        ;;
    esac
    case "$kickoff_line" in
      *"note fixture"*)
        st_fail "never puts the note's contents in kickoff" "${kickoff_line}"
        ;;
      *)
        st_ok
        ;;
    esac
  fi

  # Settings are reread on every polling cycle (the contract: "when it takes effect").
  # Covers, in one run: a setting written after startup takes effect, a broken setting does not
  # stop monitoring, and it recovers once fixed.
  case_dir="$tmp/config-reload"
  st_setup_case "$case_dir"
  st_run_watcher_daemon_bg "$ST_DAEMON_GUARD_SEC"
  if st_wait_for_log '"event":"watch_started"'; then
    printf 'unknown_key=1\n' >"$ST_RECORDS/config"
    st_allow_project_config
    if st_wait_for_watcher_log 'cannot reread config'; then
      st_ok
    else
      st_fail "surfaces a broken setting on the next cycle" "$(cat "$ST_RECORDS/$REIN_WATCHER_LOG_BASENAME" 2>/dev/null)"
    fi
    printf 'settings={"env":{"LATE_KEY":"late-value"}}\n' >"$ST_RECORDS/config"
    st_allow_project_config
    if st_wait_for_watcher_log 'config is readable again'; then
      st_ok
    else
      st_fail "recovers once the setting is fixed" "$(cat "$ST_RECORDS/$REIN_WATCHER_LOG_BASENAME" 2>/dev/null)"
    fi
    # The reread value actually takes effect (a --settings absent at startup shows up in the successor's launch arguments).
    sleep 0.5
    rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
    if st_wait_for_log '"event":"handover_completed"'; then
      st_ok
    else
      st_fail "can still hand over after a broken setting" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME" 2>/dev/null)"
    fi
    # A setting written after startup takes effect (a value absent at startup shows up in the
    # launch settings' contents). The launched session's hook deletes the real file (that deletion
    # is what the watcher waits on before advancing the pointer), so the content is read from the
    # copy the fake CLI takes at launch -- what's asserted is unchanged: this is what was handed
    # over at that moment.
    bg_call="$(rein_st_call_index "$ST_LOG" "--bg")"
    if [ "$bg_call" -ne 0 ] &&
      [ "$(rein_st_call_arg "$ST_LOG" "$bg_call" 4)" = "--settings" ] &&
      [ -f "$ST_LOG.settings" ] &&
      jq -e '.env.LATE_KEY == "late-value"' "$ST_LOG.settings" >/dev/null 2>&1; then
      st_ok
    else
      st_fail "a setting written after startup takes effect" "the launch settings weren't as expected: $(cat "$ST_LOG.settings" 2>/dev/null)"
    fi
  else
    st_fail "starts monitoring" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME" 2>/dev/null)"
  fi
  rm -f "$ST_RECORDS/config"
  st_alarm_watcher_daemon
  daemon_rc="$(cat "$ST_DAEMON_RC_FILE" 2>/dev/null)"
  if [ "$daemon_rc" = "142" ]; then
    st_ok
  else
    st_fail "a broken setting does not end the resident watcher" \
      "the watcher exited on its own with exit ${daemon_rc}: $(cat "$ST_DAEMON_OUT" 2>/dev/null)"
  fi

  # Only the runtime location is fixed at startup. Silently rereading and ignoring it on later
  # cycles would let `rein config list`'s effective value diverge from the location the watcher is
  # actually looking at, and a successor's handover request would land in a different lineage and
  # go silently nowhere (this can only happen in a lineage that resolves the location from the
  # config layer -- never one pinned by a CLI flag).
  case_dir="$tmp/runtime-dir-drift"
  st_setup_case "$case_dir"
  ST_RUNTIME_ARGS=()
  st_run_watcher_daemon_bg "$ST_DAEMON_GUARD_SEC"
  if st_wait_for_log '"event":"watch_started"'; then
    # The rejecting side: a cycle whose reread was rejected does not judge the location either.
    # Even a rejected config still has its values loaded into the config layer, so judging it
    # anyway would sound "the effective value changed" for a value that never took effect (this
    # exercises a cross-field violation and a changed runtime_dir together).
    printf 'threshold_notice=45\nthreshold_handover=40\nruntime_dir=%s\n' \
      "$ST_CWD/rejected-runtime" >"$ST_RECORDS/config"
    st_allow_project_config
    if st_wait_for_watcher_log 'cannot reread config'; then
      sleep 0.6
      if grep -q -F 'rejected-runtime' "$ST_RECORDS/$REIN_WATCHER_LOG_BASENAME" 2>/dev/null; then
        st_fail "never sounds the location of a rejected config" \
          "$(cat "$ST_RECORDS/$REIN_WATCHER_LOG_BASENAME" 2>/dev/null)"
      else
        st_ok
      fi
    else
      st_fail "surfaces a cross-field violation on the next cycle" \
        "$(cat "$ST_RECORDS/$REIN_WATCHER_LOG_BASENAME" 2>/dev/null)"
    fi
    printf 'runtime_dir=%s\n' "$ST_CWD/moved-runtime" >"$ST_RECORDS/config"
    st_allow_project_config
    if st_wait_for_watcher_log 'changing where runtime data is kept requires restarting the watcher'; then
      st_ok
    else
      st_fail "surfaces the location change on the next cycle" "$(cat "$ST_RECORDS/$REIN_WATCHER_LOG_BASENAME" 2>/dev/null)"
    fi
    # Monitoring keeps watching the location it started with (it never quietly follows config to a
    # new one -- moving mid-handover would split where the marker, lock, and heartbeat are looked up).
    if [ ! -e "$ST_CWD/moved-runtime" ]; then
      st_ok
    else
      st_fail "the location stays what it was at startup" "it created config's new location: $(ls -a "$ST_CWD/moved-runtime")"
    fi
  else
    st_fail "starts monitoring (location pinned)" "$(cat "$ST_DAEMON_OUT" 2>/dev/null)"
  fi
  rm -f "$ST_RECORDS/config"
  st_alarm_watcher_daemon
  daemon_rc="$(cat "$ST_DAEMON_RC_FILE" 2>/dev/null)"
  # A location change is notified and monitoring continues (stopping would silently end automation for every later handover).
  if [ "$daemon_rc" = "142" ]; then
    st_ok
  else
    st_fail "a location change does not end the resident watcher" \
      "the watcher exited on its own with exit ${daemon_rc}: $(cat "$ST_DAEMON_OUT" 2>/dev/null)"
  fi

}
