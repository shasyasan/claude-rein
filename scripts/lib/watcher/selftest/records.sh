# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034  # selftest state is shared across sections (the caller selftest()'s locals, and the ST_* globals)
# Matching the requester (only the session the current pointer names can request a handover), and
# the lineage records location: split between the project side and the machine side, matching the
# owner, and refusing a lineage that hasn't been migrated yet.
# Variables are shared with the caller selftest()'s locals through dynamic scope. Declaring a
# local inside a section would hide it from later sections, so this section file declares none.
# Not an executable script, so it carries no execute bit (outside the --selftest convention).

st_section_records() {
  # R10: only the session the current pointer names can request a handover. Without this check, a
  # marker placed by a session outside monitoring would go through as soon as it merely passed freshness.
  case_dir="$tmp/requester-mismatch"
  st_setup_case "$case_dir"
  rein_st_write_agents "$ST_AGENTS" "$ST_CWD" "pred-1" "other-1"
  rein_st_write_pointer "$ST_RECORDS/$REIN_POINTER_BASENAME" "pred-1" "predecessor" "$ST_CWD" 1
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "other-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  st_run_watcher
  st_reject_case "rejects a request from a session other than the pointer's" "R10"
  if [ "$(jq -r '.session_id' "$ST_RECORDS/$REIN_POINTER_BASENAME" 2>/dev/null)" = "pred-1" ]; then
    st_ok
  else
    st_fail "a rejection never advances the pointer" "$(cat "$ST_RECORDS/$REIN_POINTER_BASENAME" 2>/dev/null)"
  fi

  # The accepting side: a lineage with no pointer yet (right after a cold start) has no one to
  # match against, so it's accepted. Failing this would mean a lineage's very first handover could
  # never go through.
  case_dir="$tmp/requester-no-pointer"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  ST_EXIT_AFTER_POLLS=2
  st_run_watcher
  unset ST_EXIT_AFTER_POLLS
  if st_expect_status "accepts without matching when there is no pointer" 0; then
    if st_log_has '"event":"handover_completed"'; then
      st_ok
    else
      st_fail "a handover goes through with no pointer present" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    fi
  fi

  # Split locations: lineage records on the project side, runtime data on the machine side. Check
  # both sides' actual files to confirm no path writes back to the old single directory.
  case_dir="$tmp/split-locations"
  st_setup_case "$case_dir"
  rm -rf "$ST_RECORDS"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  ST_EXIT_AFTER_POLLS=2
  st_run_watcher
  unset ST_EXIT_AFTER_POLLS
  if st_expect_status "a handover still goes through with the locations split" 0; then
    if [ -f "$ST_RECORDS/$REIN_POINTER_BASENAME" ] &&
      [ -f "$ST_RECORDS/$REIN_LOG_BASENAME" ] &&
      [ -f "$ST_RECORDS/$REIN_WATCHER_LOG_BASENAME" ]; then
      st_ok
    else
      st_fail "puts lineage records on the project side" "$(ls -a "$ST_RECORDS" 2>&1)"
    fi
    # The records location is never checked into the consumer's VCS.
    if [ "$(cat "$ST_RECORDS/.gitignore" 2>/dev/null)" = "*" ]; then
      st_ok
    else
      st_fail "keeps the records location out of VCS" "$(cat "$ST_RECORDS/.gitignore" 2>/dev/null)"
    fi
    if [ ! -e "$ST_RUNTIME/$REIN_POINTER_BASENAME" ] &&
      [ ! -e "$ST_RUNTIME/$REIN_LOG_BASENAME" ] &&
      [ ! -e "$ST_RUNTIME/$REIN_WATCHER_LOG_BASENAME" ]; then
      st_ok
    else
      st_fail "never writes records to the old location" "$(ls -a "$ST_RUNTIME")"
    fi
    # Runtime data stays on the machine side (never moved to the project side).
    if [ -f "$ST_RUNTIME/$REIN_HEARTBEAT_BASENAME" ] &&
      [ -d "$ST_RUNTIME/$REIN_PROCESSED_DIRNAME" ] &&
      [ ! -e "$ST_RECORDS/$REIN_HEARTBEAT_BASENAME" ] &&
      [ ! -e "$ST_RECORDS/$REIN_PROCESSED_DIRNAME" ]; then
      st_ok
    else
      st_fail "puts runtime data on the machine side" "runtime=$(ls -a "$ST_RUNTIME") records=$(ls -a "$ST_RECORDS")"
    fi
    # The runtime directory self-describes its owner (cwd), so an orphan can be told apart by an existence check.
    if [ "$(cat "$ST_RUNTIME/$REIN_OWNER_BASENAME" 2>/dev/null)" = "$ST_CWD" ]; then
      st_ok
    else
      st_fail "puts an owner file in the runtime directory" "$(cat "$ST_RUNTIME/$REIN_OWNER_BASENAME" 2>/dev/null)"
    fi
  fi

  # The watcher log's write target is held to **the same one check** as the replacement writer
  # (rein_write_json_atomic) and the handover log (rein_log_line). `.rein/`'s contents can ship
  # inside a clone (docs/spec/architecture.md's threat model calls this "outside"), so just making
  # `watcher.log` a symlink is enough to grow any writable path the user who started rein has
  # access to, one append at a time (a run that fails to start goes through this same path too,
  # since startup_reject also writes to the watcher log).
  case_dir="$tmp/watcher-log-symlink"
  st_setup_case "$case_dir"
  printf 'ORIGINAL\n' >"$ST_CWD/outside-victim.txt"
  ln -s "$ST_CWD/outside-victim.txt" "$ST_RECORDS/$REIN_WATCHER_LOG_BASENAME"
  st_run_watcher
  if st_expect_status "monitoring itself still goes through with a symlinked watcher log" 0; then
    if [ "$(cat "$ST_CWD/outside-victim.txt" 2>/dev/null)" != "ORIGINAL" ]; then
      st_fail "never appends through a symlinked watcher log's target" \
        "$(cat "$ST_CWD/outside-victim.txt" 2>/dev/null)"
    elif [ ! -L "$ST_RECORDS/$REIN_WATCHER_LOG_BASENAME" ]; then
      st_fail "never silently deletes a shape it can't accept" \
        "the symlink disappeared: $(ls -l "$ST_RECORDS/$REIN_WATCHER_LOG_BASENAME" 2>&1)"
    else
      st_ok
    fi
  fi
  # Never let being unable to write records pass silently (never let it read to the user as "nothing happened").
  case "$ST_OUT" in
    *"the write target is not a regular file"*"$ST_RECORDS/$REIN_WATCHER_LOG_BASENAME"*)
      st_ok
      ;;
    *)
      st_fail "reports being unable to write the watcher log, with a reason" "${ST_OUT}"
      ;;
  esac

  # A symlink pointing at a nonexistent target **gets created by the append** (both `>>` and `mv`
  # create the target), so "did the real file survive untouched" alone isn't enough -- also check
  # that nothing new was created.
  case_dir="$tmp/watcher-log-dangling-symlink"
  st_setup_case "$case_dir"
  ln -s "$ST_CWD/created-by-symlink.txt" "$ST_RECORDS/$REIN_WATCHER_LOG_BASENAME"
  st_run_watcher
  if [ -e "$ST_CWD/created-by-symlink.txt" ]; then
    st_fail "never creates a dangling symlink's target" \
      "$(cat "$ST_CWD/created-by-symlink.txt" 2>/dev/null)"
  else
    st_ok
  fi

  # Rotation past the cap is held to the same check too. If the destination is a directory, `mv`
  # moves the original file **inside it** and returns 0, so without checking the shape the watcher
  # log ends up at `watcher.log.1/watcher.log` while the caller reads it as success (the same
  # false-success shape the replacement writer names).
  case_dir="$tmp/watcher-log-rotate-dest"
  st_setup_case "$case_dir"
  mkdir -p "$ST_RECORDS/${REIN_WATCHER_LOG_BASENAME}.1"
  printf 'old line\n' >"$ST_RECORDS/$REIN_WATCHER_LOG_BASENAME"
  ST_ENV_EXTRA=("REIN_WATCHER_LOG_MAX_BYTES=1")
  st_run_watcher
  ST_ENV_EXTRA=()
  if [ -e "$ST_RECORDS/${REIN_WATCHER_LOG_BASENAME}.1/$REIN_WATCHER_LOG_BASENAME" ]; then
    st_fail "never rotates into a destination it can't accept" \
      "it was moved inside the rotation destination directory: $(ls -a "$ST_RECORDS/${REIN_WATCHER_LOG_BASENAME}.1")"
  elif [ ! -f "$ST_RECORDS/$REIN_WATCHER_LOG_BASENAME" ]; then
    st_fail "keeps writing the watcher log even on a round it can't rotate" "$(ls -a "$ST_RECORDS" 2>&1)"
  else
    st_ok
  fi

  # The heartbeat follows the same discipline (`>` rewrites a symlink's target). A shape that
  # can't be written surfaces, per the contract, as a stage failure (never treat it as silently written).
  case_dir="$tmp/heartbeat-symlink"
  st_setup_case "$case_dir"
  printf 'ORIGINAL\n' >"$ST_CWD/outside-heartbeat.txt"
  ln -s "$ST_CWD/outside-heartbeat.txt" "$ST_RUNTIME/$REIN_HEARTBEAT_BASENAME"
  st_run_watcher
  if st_expect_status "never enters monitoring with a symlinked heartbeat" 1; then
    if [ "$(cat "$ST_CWD/outside-heartbeat.txt" 2>/dev/null)" != "ORIGINAL" ]; then
      st_fail "never rewrites a symlinked heartbeat's target" \
        "$(cat "$ST_CWD/outside-heartbeat.txt" 2>/dev/null)"
    elif ! st_log_has '"event":"failed"'; then
      st_fail "records a heartbeat that can't be written as a stage failure" \
        "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME" 2>/dev/null)"
    else
      st_ok
    fi
  fi

  # Never enter monitoring on a runtime directory owned by a different cwd (a mixed-up lineage).
  case_dir="$tmp/runtime-owner-mismatch"
  st_setup_case "$case_dir"
  printf '/somewhere/else\n' >"$ST_RUNTIME/$REIN_OWNER_BASENAME"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  st_run_watcher
  st_expect_startup_reject "does not start on a runtime directory owned by someone else" "the runtime directory belongs to a different target"
  # Leave a line in the watcher log even for a run that fails to start (when a watcher started as
  # a daemon never comes up, if the log stops at the previous exit line the user can't tell that apart from "nothing happened").
  if grep -q 'cannot start:' "$ST_RECORDS/$REIN_WATCHER_LOG_BASENAME" 2>/dev/null; then
    st_ok
  else
    st_fail "leaves a run that fails to start in the watcher log too" \
      "$(cat "$ST_RECORDS/$REIN_WATCHER_LOG_BASENAME" 2>/dev/null)"
  fi

  # An owner file that's not a regular file, not one line, or a symlink must never pass the check
  # silently (letting it pass would enter monitoring on a runtime directory with no valid owner).
  case_dir="$tmp/runtime-owner-directory"
  st_setup_case "$case_dir"
  mkdir -p "$ST_RUNTIME/$REIN_OWNER_BASENAME"
  st_run_watcher
  st_expect_startup_reject "does not start with a directory as owner" "the owner file is not a regular file"

  case_dir="$tmp/runtime-owner-multiline"
  st_setup_case "$case_dir"
  printf '%s\n/somewhere/else\n' "$ST_CWD" >"$ST_RUNTIME/$REIN_OWNER_BASENAME"
  st_run_watcher
  st_expect_startup_reject "does not start with a multiline owner" "not exactly one line"

  case_dir="$tmp/runtime-owner-symlink"
  st_setup_case "$case_dir"
  printf '%s\n' "$ST_CWD" >"$ST_CWD/owner-target"
  ln -s "$ST_CWD/owner-target" "$ST_RUNTIME/$REIN_OWNER_BASENAME"
  st_run_watcher
  st_expect_startup_reject "does not start with a symlinked owner" "the owner file is a symlink"

  # `<cwd>/.rein` **itself** being a symlink: the watcher never starts. Records must never be
  # written out through whatever the link points at, which can sit outside the project, and the
  # resolver already refuses that shape. What was open here is the receiving side: taken through
  # `$( )` the refusal arrives as the same empty string a success would, so WATCHER_LOG_FILE
  # became `/watcher.log` -- an append straight into the filesystem root -- and startup carried on
  # from there. The rejection has to land **before** the first wlog line, which is why it sits in
  # resolve_target_cwd rather than in resolve_paths.
  case_dir="$tmp/records-parent-symlink"
  st_setup_case "$case_dir"
  records_outside="$ST_CWD/records-outside"
  mkdir -p "$records_outside"
  printf 'ORIGINAL\n' >"$records_outside/SENTINEL"
  records_outside_before="$(find "$records_outside" | LC_ALL=C sort)"
  rm -rf "$ST_RECORDS"
  ln -s "$records_outside" "$ST_RECORDS"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  st_run_watcher
  st_expect_startup_reject "does not start when the records location is a symlink" "symbolic link"
  if [ "$(find "$records_outside" | LC_ALL=C sort)" = "$records_outside_before" ]; then
    st_ok
  else
    st_fail "writes not a single file into what the records symlink points at" \
      "$(find "$records_outside" | LC_ALL=C sort)"
  fi
  # The marker is never touched either (consuming it would lose the request outright -- the same
  # discipline as the missed-migration rejection above).
  if [ -f "$ST_RUNTIME/$REIN_MARKER_BASENAME" ]; then
    st_ok
  else
    st_fail "never touches the marker when the records location is a symlink" "the marker disappeared"
  fi

  # Never silently pass a records location that can't hold a `.gitignore` (letting it pass would
  # surface the handover log and pointer as untracked files in the consumer's own repository).
  case_dir="$tmp/records-ignore-unwritable"
  st_setup_case "$case_dir"
  rm -f "$ST_RECORDS/.gitignore"
  chmod 555 "$ST_RECORDS"
  st_run_watcher
  chmod 755 "$ST_RECORDS"
  st_expect_startup_reject "does not start when .gitignore can't be placed" "cannot create the lineage records location"

  # Never start on a lineage that hasn't been migrated (records still at the old location).
  # Letting it pass would read a missing pointer as a cold start, silently reset the generation to
  # 1, and lose R10's own matching target along with it.
  case_dir="$tmp/records-not-migrated"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_RUNTIME/$REIN_POINTER_BASENAME" "pred-1" "predecessor" "$ST_CWD" 4
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  st_run_watcher
  st_expect_startup_reject "does not start with records still left at the old location" "lineage records remain at the old location"
  # This only blocks a missed migration -- it never touches the marker (consuming it would lose the request entirely).
  if [ -f "$ST_RUNTIME/$REIN_MARKER_BASENAME" ]; then
    st_ok
  else
    st_fail "never touches the marker on a missed migration" "the marker disappeared"
  fi

  # The accepting side: once migrated (the pointer exists on the project side), it starts no matter what's left at the old location.
  case_dir="$tmp/records-migrated"
  st_setup_case "$case_dir"
  rein_st_write_pointer "$ST_RUNTIME/$REIN_POINTER_BASENAME" "pred-1" "predecessor" "$ST_CWD" 4
  rein_st_write_pointer "$ST_RECORDS/$REIN_POINTER_BASENAME" "pred-1" "predecessor" "$ST_CWD" 4
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  ST_EXIT_AFTER_POLLS=2
  st_run_watcher
  unset ST_EXIT_AFTER_POLLS
  if st_expect_status "a migrated lineage is never blocked by the old location's records" 0; then
    if [ "$(jq -r '.generation' "$ST_RECORDS/$REIN_POINTER_BASENAME" 2>/dev/null)" = "5" ]; then
      st_ok
    else
      st_fail "a migrated lineage carries its generation forward" "$(cat "$ST_RECORDS/$REIN_POINTER_BASENAME" 2>/dev/null)"
    fi
  fi

}
