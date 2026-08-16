# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034  # selftest state is shared across sections (the caller selftest()'s locals, and the ST_* globals)
# Marker acceptance judgment: the predecessor is already gone from the start, the lower edge of the
# timestamp format rule, a broken current pointer, uniqueness of a successor candidate, and the
# connection between the writer command and the marker it wrote.
# Variables are shared with the caller selftest()'s locals through dynamic scope. Declaring a
# local inside a section would hide it from later sections, so this section file declares none.
# Not an executable script, so it carries no execute bit (outside the --selftest convention).

st_section_marker() {
  # The predecessor is already gone from the start: complete without issuing a stop command.
  case_dir="$tmp/already-gone"
  st_setup_case "$case_dir"
  printf '[]\n' >"$ST_AGENTS"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  st_run_watcher
  if st_expect_status "completes immediately when the predecessor is already gone" 0; then
    if [ "$(rein_st_count_sub "$ST_LOG" stop)" -ne 0 ]; then
      st_fail "does not issue an unnecessary stop" "claude stop was called: $(cat "$ST_LOG")"
    elif ! st_log_has '"event":"predecessor_exited"'; then
      st_fail "leaves a record confirming the self-exit" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    else
      st_ok
    fi
  fi

  # R4 is "only the prescribed format". Also reject shapes BSD date silently accepts (trailing junk, a nonexistent date).
  case_dir="$tmp/garbage-time"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" \
    "$(rein_iso_now)garbage" "$ST_HANDOFF" "$ST_CWD"
  st_run_watcher
  st_reject_case "rejects a timestamp with trailing junk" "R4"

  case_dir="$tmp/impossible-date"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "2026-02-30T00:00:00Z" "$ST_HANDOFF" "$ST_CWD"
  st_run_watcher
  st_reject_case "rejects a nonexistent date" "R4"

  # R7's upper side: the handoff document was rewritten after the marker too -- the write to it never finished.
  case_dir="$tmp/handoff-after-marker"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" \
    "$(TZ=UTC date -u -r "$(($(rein_now_epoch) - 300))" +%Y-%m-%dT%H:%M:%SZ)" "$ST_HANDOFF" "$ST_CWD"
  touch "$ST_HANDOFF"
  st_run_watcher
  st_reject_case "rejects a handoff document updated after the marker" "R7" "allowed skew 60 sec"

  # R9: even if the marker's cwd goes through a symlink, accept it as long as the real path matches (normalizing only one side would fail this).
  case_dir="$tmp/symlink-cwd"
  st_setup_case "$case_dir"
  ln -s "$ST_CWD" "$tmp/symlink-cwd-link"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$tmp/symlink-cwd-link"
  ST_EXIT_AFTER_POLLS=2
  st_run_watcher
  unset ST_EXIT_AFTER_POLLS
  st_accept_case "the handover goes through even with cwd via a symlink"

  # A broken current pointer: don't silently roll back to generation 1 -- stop before entering a handover.
  case_dir="$tmp/broken-pointer"
  st_setup_case "$case_dir"
  jq -nc '{schema: "rein.current.v0", session_id: "x", cwd: "/elsewhere", generation: "abc"}' \
    >"$ST_RECORDS/$REIN_POINTER_BASENAME"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  st_run_watcher
  if st_expect_status "stops on a broken pointer" 1; then
    if [ "$(rein_st_count_sub "$ST_LOG" "--bg")" -ne 0 ]; then
      st_fail "does not launch a successor on a broken pointer" "claude --bg was called: $(cat "$ST_LOG")"
    elif [ "$(jq -r '.schema' "$ST_RECORDS/$REIN_POINTER_BASENAME")" != "rein.current.v0" ]; then
      st_fail "does not overwrite the broken pointer" "$(cat "$ST_RECORDS/$REIN_POINTER_BASENAME")"
    elif ! st_log_has '"event":"failed"'; then
      st_fail "logs the invalid pointer" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    elif [ -f "$ST_RUNTIME/$REIN_MARKER_BASENAME" ] ||
      [ -z "$(find "$ST_RUNTIME/$REIN_PROCESSING_DIRNAME" -name '*.json' -print -quit 2>/dev/null)" ]; then
      # If it claimed (mv to processing) before judging, a stage failure would not leave it at the original path.
      st_fail "claims the marker before judging it" "still at the original path, or missing from processing: $(ls -R "$ST_RUNTIME")"
    else
      st_ok
    fi
  fi

  # Multiple candidates with the same name and cwd appeared after launch: which one is the successor can't be decided, so the pointer doesn't advance.
  case_dir="$tmp/ambiguous-successor"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  ST_BG_DUPLICATE=1
  st_run_watcher
  unset ST_BG_DUPLICATE
  if st_expect_status "fails when there are multiple successor candidates" 1; then
    if [ -f "$ST_RECORDS/$REIN_POINTER_BASENAME" ]; then
      st_fail "does not advance the pointer with multiple candidates" "current.json was written"
    elif ! st_log_has '"event":"failed"'; then
      st_fail "leaves multiple candidates as failed" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    else
      st_ok
    fi
  fi
  # A round with multiple candidates is **not auto-stopped** (which one is the successor can't be
  # decided -- what cannot be confirmed is never seized). But quietly stepping down while it's still
  # running would leave an unmanaged session, not pointed to, in the same working tree (kickoff
  # instructs it to "Start work as this project's primary session."). Not stopping it and naming
  # what's left behind, with a path to clean it up, are compatible.
  if [ "$(rein_st_count_sub "$ST_LOG" stop)" -ne 0 ]; then
    st_fail "does not issue a stop with multiple candidates" "claude stop was called: $(cat "$ST_LOG")"
  elif ! st_log_has '"event":"successor_orphaned"'; then
    st_fail "records leaving it running unmanaged" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
  elif ! grep -q -e 'did not stop the launched successor' "$ST_RECORDS/$REIN_LOG_BASENAME"; then
    st_fail "gives not stopping it as the reason" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
  else
    st_ok
  fi

  # A marker the writer command wrote is accepted as-is by the reader (the connection between both sides).
  case_dir="$tmp/written-by-request"
  st_setup_case "$case_dir"
  touch -t 202001010000 "$ST_HANDOFF"
  # A handover request can only be written on a lineage where the watcher is running (writing it
  # where none is running would leave a marker behind with no one to consume it). What this section
  # tests is the connection between the writer and the reader, so start the daemon fixture before
  # letting it write.
  rein_st_start_fake_watcher "$ST_RUNTIME" "$ST_CWD"
  if env "${ST_ENV_ARGS[@]}" PATH="$ST_BIN:$PATH" FAKE_NOTIFY_LOG="$ST_NOTIFY" \
    "$REIN_ST_BASH" "$SCRIPT_DIR/rein-request.sh" --cwd "$ST_CWD" --runtime-dir "$ST_RUNTIME" \
    --session-id "pred-1" --handoff "$ST_HANDOFF" >/dev/null 2>&1; then
    # The real watcher takes this location's watcher lock itself, so release the fixture's lock after
    # letting it write (without releasing it, it would step down as "already running" and the
    # acceptance side would never be tested).
    rein_st_stop_fake_watcher "$ST_RUNTIME"
    ST_EXIT_AFTER_POLLS=2
    st_run_watcher
    unset ST_EXIT_AFTER_POLLS
    if st_expect_status "accepts a marker from rein-request.sh" 0; then
      if st_log_has '"event":"marker_accepted"'; then
        st_ok
      else
        st_fail "accepts the writer command's marker" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
      fi
    fi
  else
    st_fail "the writer command can write a marker" "rein-request.sh exited non-zero"
  fi

  # The writer side: the marker's pathname is a directory. If this reports "placed" and exits 0
  # here, the session that issued the handover request would stop believing the request is awaiting
  # acceptance, while the watcher only ever sees an empty directory, so no handover happens (the
  # seat just vanishes).
  # This caller already fails earlier, at the pre-atomic-write check for an unconsumed marker
  # (`-e`) -- the writer's shape check is duplicated here, but the point is to pin down that the
  # message and exit code stay the same even though the failing layer changed.
  case_dir="$tmp/request-marker-is-dir"
  st_setup_case "$case_dir"
  rein_st_start_fake_watcher "$ST_RUNTIME" "$ST_CWD"
  mkdir -p "$ST_RUNTIME/$REIN_MARKER_BASENAME"
  probe_out="$(env "${ST_ENV_ARGS[@]}" PATH="$ST_BIN:$PATH" FAKE_NOTIFY_LOG="$ST_NOTIFY" \
    "$REIN_ST_BASH" "$SCRIPT_DIR/rein-request.sh" --cwd "$ST_CWD" --runtime-dir "$ST_RUNTIME" \
    --session-id "pred-1" --handoff "$ST_HANDOFF" 2>&1 </dev/null)"
  request_rc=$?
  if [ "$request_rc" -eq 0 ]; then
    st_fail "does not treat the handover request as successful when the marker's pathname is a directory" \
      "exited with 0: ${probe_out}"
  else
    case "$probe_out" in
      *"placed a handover request"*)
        st_fail "does not say a handover request was placed when it wasn't" "${probe_out}"
        ;;
      *)
        if [ -n "$(find "$ST_RUNTIME/$REIN_MARKER_BASENAME" -mindepth 1 -print)" ]; then
          st_fail "does not write into the marker's pathname" \
            "$(find "$ST_RUNTIME/$REIN_MARKER_BASENAME" -print)"
        else
          st_ok
        fi
        ;;
    esac
  fi
  rein_st_stop_fake_watcher "$ST_RUNTIME"

  # A marker left behind in `processing/` is reclaimed the next time a watcher starts up.
  # A watcher can go down from a mechanism failure after claim (mv into processing), leaving that
  # round's marker in processing (by design). When the Stop hook finds its own session_id inside
  # processing, it reads that as "the handover request has already been submitted" and doesn't
  # block the stop, so without a way to reclaim it, **this seat's handover trigger is permanently
  # disabled** (neither prune's archive scan nor status looks inside processing).
  case_dir="$tmp/orphan-processing"
  st_setup_case "$case_dir"
  mkdir -p "$ST_RUNTIME/$REIN_PROCESSING_DIRNAME"
  rein_st_write_marker "$ST_RUNTIME/$REIN_PROCESSING_DIRNAME/orphan.json" "pred-1" \
    "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  st_run_watcher
  if st_expect_status "monitoring starts even with a leftover marker present" 0; then
    if [ -n "$(find "$ST_RUNTIME/$REIN_PROCESSING_DIRNAME" -name '*.json' -print -quit 2>/dev/null)" ]; then
      st_fail "does not leave the leftover in processing" \
        "$(ls -a "$ST_RUNTIME/$REIN_PROCESSING_DIRNAME" 2>&1)"
    elif [ -z "$(find "$ST_RUNTIME/$REIN_REJECTED_DIRNAME" -name '*.json' -print -quit 2>/dev/null)" ]; then
      st_fail "reclaims the leftover into rejected" \
        "$(ls -a "$ST_RUNTIME/$REIN_REJECTED_DIRNAME" 2>&1)"
    elif ! st_log_has '"event":"marker_recovered"'; then
      st_fail "records the reclaim" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME" 2>/dev/null)"
    else
      st_ok
    fi
  fi
  # Reclaiming **is not itself a handover** (no successor is launched) -- folding it into the
  # acceptance path would advance the generation while the predecessor is gone.
  if [ "$(rein_st_count_sub "$ST_LOG" "--bg")" -eq 0 ]; then
    st_ok
  else
    st_fail "does not launch a successor while reclaiming" "claude --bg was called: $(cat "$ST_LOG")"
  fi

  # A round that went down right after launching a successor (launch and the current pointer update
  # aren't atomic). The marker's `launch_attempt` declares "the successor launched on this attempt",
  # so if that successor is alive, the watcher that comes back carries the handover through to
  # completion (never relaunches, never leaves it unmanaged).
  case_dir="$tmp/orphan-launched-alive"
  st_setup_case "$case_dir"
  mkdir -p "$ST_RUNTIME/$REIN_PROCESSING_DIRNAME"
  rein_st_write_marker "$ST_RUNTIME/$REIN_PROCESSING_DIRNAME/orphan.json" "pred-1" \
    "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  probe_out="$(jq -c --arg at "$(rein_iso_now)" \
    '. + {launch_attempt: {successor_name: "adopted", launched_at: $at, successor_session_id: "succ-1"}}' \
    "$ST_RUNTIME/$REIN_PROCESSING_DIRNAME/orphan.json")"
  printf '%s\n' "$probe_out" >"$ST_RUNTIME/$REIN_PROCESSING_DIRNAME/orphan.json"
  rein_st_write_agents "$ST_AGENTS" "$ST_CWD" "pred-1" "succ-1"
  st_run_watcher
  if st_expect_status "adopts a launched successor if it's alive" 0; then
    if [ "$(jq -r '.session_id' "$ST_RECORDS/$REIN_POINTER_BASENAME" 2>/dev/null)" != "succ-1" ]; then
      st_fail "points the pointer at the launched successor" "$(cat "$ST_RECORDS/$REIN_POINTER_BASENAME" 2>/dev/null)"
    elif [ "$(rein_st_count_sub "$ST_LOG" "--bg")" -ne 0 ]; then
      st_fail "does not relaunch a successor when adopting" "claude --bg was called: $(cat "$ST_LOG")"
    elif ! rein_st_has_call "$ST_LOG" stop job-pred-1; then
      st_fail "steps down the predecessor even on an adopted handover" "$(cat "$ST_LOG")"
    elif ! st_log_has '"event":"handover_completed"'; then
      st_fail "records completion of the adopted handover" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    elif [ -n "$(find "$ST_RUNTIME/$REIN_PROCESSING_DIRNAME" -name '*.json' -print -quit 2>/dev/null)" ]; then
      st_fail "does not leave the adopted marker in processing" "$(ls -a "$ST_RUNTIME/$REIN_PROCESSING_DIRNAME" 2>&1)"
    elif [ -z "$(find "$ST_RUNTIME/$REIN_PROCESSED_DIRNAME" -name '*.json' -print -quit 2>/dev/null)" ]; then
      st_fail "archives the adopted marker to processed" "$(ls -a "$ST_RUNTIME" 2>&1)"
    elif [ "$(jq -r '.session_name' "$ST_RECORDS/$REIN_POINTER_BASENAME" 2>/dev/null)" != "adopted" ]; then
      st_fail "carries the declared name through to the record unchanged" "$(cat "$ST_RECORDS/$REIN_POINTER_BASENAME" 2>/dev/null)"
    else
      st_ok
    fi
  fi

  # The shape where the declaration has no name (a round where writing the ID failed partway
  # through). Don't fill the record's name field with empty -- fall back to the default naming
  # (which can only be built once the generation is known, so getting the order wrong leaves a name
  # missing `-rein-g` in the record).
  case_dir="$tmp/orphan-launched-alive-unnamed"
  st_setup_case "$case_dir"
  mkdir -p "$ST_RUNTIME/$REIN_PROCESSING_DIRNAME"
  rein_st_write_marker "$ST_RUNTIME/$REIN_PROCESSING_DIRNAME/orphan.json" "pred-1" \
    "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  probe_out="$(jq -c --arg at "$(rein_iso_now)" \
    '. + {launch_attempt: {launched_at: $at, successor_session_id: "succ-1"}}' \
    "$ST_RUNTIME/$REIN_PROCESSING_DIRNAME/orphan.json")"
  printf '%s\n' "$probe_out" >"$ST_RUNTIME/$REIN_PROCESSING_DIRNAME/orphan.json"
  rein_st_write_agents "$ST_AGENTS" "$ST_CWD" "pred-1" "succ-1"
  st_run_watcher
  if st_expect_status "adopts it even with no name declared" 0; then
    if [ "$(jq -r '.session_name' "$ST_RECORDS/$REIN_POINTER_BASENAME" 2>/dev/null)" = "${ST_CWD##*/}-rein-g1" ]; then
      st_ok
    else
      st_fail "falls back to the default naming when there's no name" "$(cat "$ST_RECORDS/$REIN_POINTER_BASENAME" 2>/dev/null)"
    fi
  fi

  # The counterpart: a round where the declared successor is already gone is **not adopted** (does
  # not relaunch, does not stop the predecessor). Consumes it as a handover that never took place,
  # leaves a reason, and keeps monitoring (returning the predecessor to a state where it can request
  # a handover again).
  case_dir="$tmp/orphan-launched-dead"
  st_setup_case "$case_dir"
  mkdir -p "$ST_RUNTIME/$REIN_PROCESSING_DIRNAME"
  rein_st_write_marker "$ST_RUNTIME/$REIN_PROCESSING_DIRNAME/orphan.json" "pred-1" \
    "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  probe_out="$(jq -c --arg at "$(rein_iso_now)" \
    '. + {launch_attempt: {successor_name: "gone", launched_at: $at, successor_session_id: "succ-gone"}}' \
    "$ST_RUNTIME/$REIN_PROCESSING_DIRNAME/orphan.json")"
  printf '%s\n' "$probe_out" >"$ST_RUNTIME/$REIN_PROCESSING_DIRNAME/orphan.json"
  st_run_watcher
  if st_expect_status "monitoring starts even when the declared successor is gone" 0; then
    if [ -f "$ST_RECORDS/$REIN_POINTER_BASENAME" ]; then
      st_fail "does not advance the pointer for a handover that never took place" "$(cat "$ST_RECORDS/$REIN_POINTER_BASENAME")"
    elif [ "$(rein_st_count_sub "$ST_LOG" stop)" -ne 0 ]; then
      st_fail "does not stop the predecessor for a handover that never took place" "$(cat "$ST_LOG")"
    elif [ "$(rein_st_count_sub "$ST_LOG" "--bg")" -ne 0 ]; then
      st_fail "does not relaunch a successor for a handover that never took place" "$(cat "$ST_LOG")"
    elif ! grep -q -e 'treating the handover as not having gone through' "$ST_RECORDS/$REIN_LOG_BASENAME"; then
      st_fail "records that it never took place, with a reason" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    elif [ -z "$(find "$ST_RUNTIME/$REIN_REJECTED_DIRNAME" -name '*.json' -print -quit 2>/dev/null)" ]; then
      st_fail "reclaims the never-completed marker into rejected" "$(ls -a "$ST_RUNTIME" 2>&1)"
    else
      st_ok
    fi
  fi

  # The shape where reclaiming itself **fails**. Blocking the reclaim destination with a regular
  # file makes `mkdir -p` fail. If monitoring starts here without acting on the return value, the
  # leftover stays in processing while only the heartbeat gets published, and the Stop hook keeps
  # reading that session's handover request as "already submitted" (the handover trigger stays
  # permanently disabled).
  case_dir="$tmp/orphan-recover-fails"
  st_setup_case "$case_dir"
  mkdir -p "$ST_RUNTIME/$REIN_PROCESSING_DIRNAME"
  rein_st_write_marker "$ST_RUNTIME/$REIN_PROCESSING_DIRNAME/orphan.json" "pred-1" \
    "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  : >"$ST_RUNTIME/$REIN_REJECTED_DIRNAME"
  st_run_watcher
  if st_expect_status "does not enter monitoring when reclaiming fails" 1; then
    if [ -e "$ST_RUNTIME/$REIN_HEARTBEAT_BASENAME" ]; then
      st_fail "does not publish the heartbeat when reclaiming fails" "a heartbeat was placed: $(ls -a "$ST_RUNTIME")"
    elif ! st_log_has '"event":"failed"'; then
      st_fail "records the reclaim failure to the handover log" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME" 2>/dev/null)"
    elif ! st_expect_notify "notifies about the reclaim failure" \
      "rein: handover failed" "stage=reclaiming a leftover handover request"; then
      :
    elif [ ! -f "$ST_RUNTIME/$REIN_PROCESSING_DIRNAME/orphan.json" ]; then
      st_fail "leaves the marker that failed to reclaim in place" "$(ls -a "$ST_RUNTIME/$REIN_PROCESSING_DIRNAME" 2>&1)"
    else
      st_ok
    fi
  fi
  rm -f "$ST_RUNTIME/$REIN_REJECTED_DIRNAME"

  # An archive name is unique from timestamp and nonce alone -- **never expand an externally-sourced
  # raw ID into a pathname**. Expanding it would either make the archiving itself fail on an ID
  # containing a separator (leaving it behind unconsumed) or, when an intermediate directory happens
  # to exist, let it write outside the intended location. The ID is already on record in the JSON
  # and the handover log, so dropping it from the name loses no traceability.
  case_dir="$tmp/archive-name-no-raw-id"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" \
    "$(TZ=UTC date -u -r "$(($(rein_now_epoch) - 100000))" +%Y-%m-%dT%H:%M:%SZ)" "$ST_HANDOFF" "$ST_CWD"
  st_run_watcher
  if st_expect_status "rejects and archives a stale marker" 1; then
    if [ -z "$(find "$ST_RUNTIME/$REIN_REJECTED_DIRNAME" -maxdepth 1 -type f -name '*.json' -print -quit 2>/dev/null)" ]; then
      st_fail "archives the rejected marker to rejected" "$(ls -a "$ST_RUNTIME/$REIN_REJECTED_DIRNAME" 2>&1)"
    elif [ -n "$(find "$ST_RUNTIME/$REIN_REJECTED_DIRNAME" -maxdepth 1 -type f -name '*pred-1*' -print -quit 2>/dev/null)" ]; then
      st_fail "does not mix the raw session_id into the archive name" \
        "$(ls -a "$ST_RUNTIME/$REIN_REJECTED_DIRNAME" 2>&1)"
    else
      st_ok
    fi
  fi

  # The escape shape itself: pre-creating an intermediate directory named `<timestamp>-x` at the
  # archive destination makes `session_id='x/../../../escaped'`'s archive destination land
  # **outside** the runtime data location (right under the case's cwd), and the watcher reports it
  # as a success. Even without that setup, `mv` fails and it's left behind in processing (either way
  # is a loss). The archive name's timestamp is second-precision, so prepare 3 seconds' worth to
  # cover a run that straddles a boundary.
  case_dir="$tmp/archive-name-escape"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "x/../../../escaped" \
    "$(TZ=UTC date -u -r "$(($(rein_now_epoch) - 100000))" +%Y-%m-%dT%H:%M:%SZ)" "$ST_HANDOFF" "$ST_CWD"
  ST_ARCHIVE_NOW="$(rein_now_epoch)"
  mkdir -p \
    "$ST_RUNTIME/$REIN_REJECTED_DIRNAME/$(TZ=UTC date -u -r "$ST_ARCHIVE_NOW" +%Y%m%dT%H%M%SZ)-x" \
    "$ST_RUNTIME/$REIN_REJECTED_DIRNAME/$(TZ=UTC date -u -r "$((ST_ARCHIVE_NOW + 1))" +%Y%m%dT%H%M%SZ)-x" \
    "$ST_RUNTIME/$REIN_REJECTED_DIRNAME/$(TZ=UTC date -u -r "$((ST_ARCHIVE_NOW + 2))" +%Y%m%dT%H%M%SZ)-x"
  st_run_watcher
  if [ -n "$(find "$ST_CWD" -maxdepth 1 -type f -name 'escaped-*.json' -print -quit 2>/dev/null)" ]; then
    st_fail "the archive destination does not escape the runtime data location" "$(find "$ST_CWD" -maxdepth 1 -type f -name 'escaped-*.json')"
  elif [ -n "$(find "$ST_RUNTIME/$REIN_PROCESSING_DIRNAME" -name '*.json' -print -quit 2>/dev/null)" ]; then
    st_fail "does not leave it behind unconsumed when archiving fails" "$(ls -a "$ST_RUNTIME/$REIN_PROCESSING_DIRNAME" 2>&1)"
  elif [ -z "$(find "$ST_RUNTIME/$REIN_REJECTED_DIRNAME" -maxdepth 1 -type f -name '*.json' -print -quit 2>/dev/null)" ]; then
    st_fail "archives to rejected even for an ID containing a separator" "$(ls -a "$ST_RUNTIME/$REIN_REJECTED_DIRNAME" 2>&1)"
  else
    st_ok
  fi

  # Reclaiming a leftover follows the same one rule too (don't build the reclaim destination's name from an externally-sourced ID).
  case_dir="$tmp/orphan-archive-name"
  st_setup_case "$case_dir"
  mkdir -p "$ST_RUNTIME/$REIN_PROCESSING_DIRNAME"
  rein_st_write_marker "$ST_RUNTIME/$REIN_PROCESSING_DIRNAME/orphan.json" "a/b" \
    "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  st_run_watcher
  if st_expect_status "monitoring starts even with a leftover whose ID contains a separator" 0; then
    if [ -n "$(find "$ST_RUNTIME/$REIN_PROCESSING_DIRNAME" -name '*.json' -print -quit 2>/dev/null)" ]; then
      st_fail "does not leave a leftover with a separator in its ID in processing" \
        "$(ls -a "$ST_RUNTIME/$REIN_PROCESSING_DIRNAME" 2>&1)"
    elif [ -z "$(find "$ST_RUNTIME/$REIN_REJECTED_DIRNAME" -maxdepth 1 -type f -name '*.json' -print -quit 2>/dev/null)" ]; then
      st_fail "reclaims a leftover with a separator in its ID into rejected" \
        "$(ls -a "$ST_RUNTIME/$REIN_REJECTED_DIRNAME" 2>&1)"
    else
      st_ok
    fi
  fi

  # A **retry** after a handover went down at the pointer update. Carrying a second attempt through
  # without cleaning up the successor launched on the first would leave an unmanaged session with
  # the same name and cwd sitting in the same working tree while a new primary session starts up
  # (two of them could edit the same tree).
  case_dir="$tmp/relaunch-no-orphan"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  # Block the pointer's pathname with a directory in step with running the launch command -- the
  # atomic write fails (the successor is already launched -- this is the window "launched it, but
  # the pointer has nowhere to land").
  ST_SABOTAGE="$ST_RECORDS/$REIN_POINTER_BASENAME"
  st_run_watcher
  unset ST_SABOTAGE
  if st_expect_status "the first attempt fails when it can't write the pointer" 1; then
    st_ok
  fi
  rm -rf "${ST_RECORDS:?}/$REIN_POINTER_BASENAME"
  : >"$ST_LOG"
  rm -f "$ST_LOG.agents"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  ST_SUCC_ID="succ-2"
  st_run_watcher
  unset ST_SUCC_ID
  if st_expect_status "clearing the obstacle lets the second attempt go through" 0; then
    if [ "$(jq -r '[ .[] | select((.pid // null) != null) | .sessionId ] | sort | join(",")' "$ST_AGENTS" 2>/dev/null)" = "succ-2" ]; then
      st_ok
    else
      st_fail "a retry does not add an extra unmanaged session" "live enumeration: $(cat "$ST_AGENTS")"
    fi
  fi

}
