# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034  # selftest state is shared across sections (the caller selftest()'s locals, and the ST_* globals)
# Confirming the successor launched and stopping the predecessor. Sanity checks on the fake CLI's
# listing shapes and on the ID-acceptance rule itself live here too (to tell a pass caused by a
# too-loose tool apart from an actual stop-check failure).
# Variables are shared with the caller selftest()'s locals through dynamic scope. Declaring a
# local inside a section would hide it from later sections, so this section file declares none.
# Not an executable script, so it carries no execute bit (outside the --selftest convention).

st_section_successor() {
  # The successor never shows up in the listing: stop at the launch-confirmation timeout, and never advance the pointer.
  case_dir="$tmp/silent-bg"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  ST_BG_SILENT=1
  st_run_watcher
  unset ST_BG_SILENT
  if st_expect_status "fails when the successor never appears" 1; then
    if [ -f "$ST_RECORDS/$REIN_POINTER_BASENAME" ]; then
      st_fail "never advances the pointer without launch confirmation" "current.json was written"
    elif ! st_expect_notify_matches_event "notifies on a launch-confirmation timeout" \
      "rein: handover failed" "stage=confirming the successor launched" "failed"; then
      : # the notification check already covers the reason -- no need to re-judge it here
    elif ! st_log_has '"event":"failed"'; then
      st_fail "leaves the launch-confirmation timeout in the log" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    elif ! grep -q -e 'seconds and still cannot confirm the launch' "$ST_RECORDS/$REIN_LOG_BASENAME"; then
      # The wording for "the listing was readable, but the successor never showed up" -- also
      # confirm it isn't confused with the unreadable-listing wording (below).
      st_fail "the launch-confirmation timeout's reason is that it expired" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    else
      st_ok
    fi
  fi

  # `--bg` itself failing also stops the same way.
  case_dir="$tmp/bg-fail"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  ST_BG_FAIL=1
  st_run_watcher
  unset ST_BG_FAIL
  if st_expect_status "stops on a non-zero exit from the launch command" 1; then
    if [ -f "$ST_RECORDS/$REIN_POINTER_BASENAME" ]; then
      st_fail "never advances the pointer on a launch failure" "current.json was written"
    elif ! grep -q -e 'rc=3' "$ST_RECORDS/$REIN_LOG_BASENAME" ||
      ! grep -q -e 'fake bg boom' "$ST_RECORDS/$REIN_LOG_BASENAME"; then
      # Leaves the failed external command's exit code and stderr's last line (can't be reproduced under daemon operation otherwise).
      st_fail "leaves the launch-failure reason in the handover log" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    else
      st_ok
    fi
  fi

  # The predecessor does not end itself: stop it externally with claude stop after the deadline.
  case_dir="$tmp/stop-recovers"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  st_run_watcher
  if st_expect_status "stops externally a predecessor that never self-exits" 0; then
    # Check the whole argv match (also catches an extra argument tacked on, or the ID split across arguments).
    if ! rein_st_has_call "$ST_LOG" stop job-pred-1; then
      st_fail "passes the listing's short job ID to the stop" "claude stop was not called with the short ID: $(cat "$ST_LOG")"
    elif ! st_log_has '"event":"predecessor_stopped"'; then
      st_fail "leaves the stop in the log" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    else
      st_ok
    fi
  fi

  # Stopping doesn't make it disappear: notify and end non-zero (never treat it as silently complete).
  case_dir="$tmp/stop-ineffective"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  ST_STOP_INEFFECTIVE=1
  st_run_watcher
  unset ST_STOP_INEFFECTIVE
  if st_expect_status "fails when the stop doesn't take effect" 1; then
    if ! st_expect_notify_matches_event "notifies when it can't be stopped" \
      "rein: handover failed" "stage=confirming the predecessor's stop" "failed"; then
      :
    elif st_log_has '"event":"handover_completed"'; then
      st_fail "never treats it as complete when it can't be stopped" "handover_completed was recorded"
    else
      st_ok
    fi
  fi

  # The predecessor is an interactive session (has no id under the real CLI): the stop can't be
  # issued at all, so after the grace period expires, fail with "cannot stop it externally" stated explicitly.
  case_dir="$tmp/interactive-predecessor"
  st_setup_case "$case_dir"
  rein_st_write_agents_interactive "$ST_AGENTS" "$ST_CWD" "pred-1"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  st_run_watcher
  if st_expect_status "never attempts to stop an interactive predecessor" 1; then
    if [ "$(rein_st_count_sub "$ST_LOG" stop)" -ne 0 ]; then
      st_fail "never issues a stop against an interactive session" "claude stop was called: $(cat "$ST_LOG")"
    elif ! grep -q -e 'an interactive session cannot be stopped externally' "$ST_RECORDS/$REIN_LOG_BASENAME"; then
      st_fail "states explicitly that an interactive session can't be stopped" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    elif ! st_expect_notify_matches_event "notifies when it can't be stopped" \
      "rein: handover failed" "an interactive session cannot be stopped externally" "failed"; then
      :
    else
      st_ok
    fi
  fi

  # Sanity-check the fake CLI's listing shapes themselves: as measured, an interactive entry
  # carries no id and only a background one does. If this breaks, "an interactive session can't be
  # stopped externally" is permanently hidden from selftest. A live entry carries the real values
  # (busy / idle) in status and a pid, and state may only use the words the real CLI returns
  # (working / done / stopped / blocked). An entry that has exited carries neither a pid nor a
  # status key at all -- building this with a word the real CLI never returns, or a null-filled
  # status, would let the liveness judgment go green without ever exercising the branch real
  # operation actually takes.
  case_dir="$tmp/fixture-shape"
  st_setup_case "$case_dir"
  rein_st_write_agents_interactive "$ST_CWD/interactive.json" "$ST_CWD" "i-1"
  rein_st_write_agents_idle "$ST_CWD/idle.json" "$ST_CWD" "idle-1"
  rein_st_write_agents_done "$ST_CWD/past.json" "$ST_CWD" "past-1"
  # Check the 4 shapes individually, never folded into one (folding them would leave a person
  # diffing raw JSON by eye to find which shape broke).
  st_shape="$(jq -r '.[0] | [(has("id")), (has("state")), (.status // "")] | @csv' "$ST_CWD/interactive.json")"
  if [ "$st_shape" = 'false,false,"busy"' ]; then
    st_ok
  else
    st_fail "the interactive fixture has no id or state, but has status" "$st_shape / $(cat "$ST_CWD/interactive.json")"
  fi
  st_shape="$(jq -r '.[0] | [(has("id")), (.state // ""), (.status // ""), (.pid != null)] | @csv' "$ST_AGENTS")"
  if [ "$st_shape" = 'true,"working","busy",true' ]; then
    st_ok
  else
    st_fail "the running background fixture has id, state=working, status=busy, and pid" "$st_shape / $(cat "$ST_AGENTS")"
  fi
  st_shape="$(jq -r '.[0] | [(.state // ""), (.status // ""), (.pid != null)] | @csv' "$ST_CWD/idle.json")"
  if [ "$st_shape" = '"done","idle",true' ]; then
    st_ok
  else
    st_fail "the fixture after a turn ends has state=done, status=idle, and pid" "$st_shape / $(cat "$ST_CWD/idle.json")"
  fi
  st_shape="$(jq -r '.[0] | [(has("pid")), (has("status")), (.state // "")] | @csv' "$ST_CWD/past.json")"
  if [ "$st_shape" = 'false,false,"done"' ]; then
    st_ok
  else
    st_fail "an exited fixture has neither pid nor status keys, with state=done" "$st_shape / $(cat "$ST_CWD/past.json")"
  fi

  # Reads liveness after a turn ends (state=done, status=idle, pid present) as **alive**. This
  # shape shows up in the real CLI's normal listing routinely (every time a turn ends), so
  # checking the exit vocabulary "done" against state first would turn a primary session in
  # ordinary operation into "has exited" every single time.
  if rein_agents_has_live "$(cat "$ST_CWD/idle.json")" "idle-1"; then
    st_ok
  else
    st_fail "reads liveness after a turn ends as alive" "$(cat "$ST_CWD/idle.json")"
  fi
  # The opposite side: an exited entry that has lost pid and status reads as dead (pins, with the
  # same material, that the above isn't just "reads everything as alive").
  if rein_agents_has_live "$(cat "$ST_CWD/past.json")" "past-1"; then
    st_fail "never reads an exited entry as alive" "$(cat "$ST_CWD/past.json")"
  else
    st_ok
  fi

  # Pin the branch that reads the exit vocabulary (done / failed / stopped) as dead by calling the
  # predicate directly, bypassing the listing shim. The real CLI never returns an entry that has a
  # pid and a status in the exit vocabulary at once (an exited entry drops the pid key entirely),
  # so rather than build a shape the real CLI never produces into the fake CLI's fixture, this
  # hands the input straight to rein's own contract (treat these 3 words as exited). This branch
  # only matters on the side that reads an `--all` listing once and judges several sessions at once
  # (the candidate judgment behind `rein prune`) -- that's the only place exited entries get mixed
  # into the same material.
  # Quote the words (an unquoted `done` reads as a for-loop terminator -- SC1010).
  for st_dead in "done" "failed" "stopped"; do
    if rein_agents_has_live "[{\"sessionId\":\"x\",\"kind\":\"background\",\"pid\":1,\"status\":\"$st_dead\"}]" "x"; then
      st_fail "reads the exit vocabulary ${st_dead} as dead" "read an entry with status=${st_dead} and a pid as alive"
    else
      st_ok
    fi
  done

  # **Valid JSON that isn't an array** (an external CLI printing an error instead of the listing
  # body). The check upstream of the caller only goes as far as `jq -e .`, so this reaches all the
  # way here, and running it through `any(.[]; ...)` makes jq exit with a runtime error, coming
  # out as **the same non-zero as "absent"** -- bootstrap would launch a first-generation session
  # even though a live predecessor may exist. Check that it identifies itself as 2 (undetermined),
  # not 1 (absent).
  for st_nonarray in '{"error":"not logged in"}' '"plain string"' '42' 'null'; do
    rein_agents_has_live "$st_nonarray" "x"
    st_rc=$?
    if [ "$st_rc" -eq 2 ]; then
      st_ok
    else
      st_fail "identifies a non-array listing as undetermined (${st_nonarray})" "rc=${st_rc} (1 means \"absent\" -- a first generation would launch)"
    fi
  done
  # The control (measuring both sides): an empty array is **a listing that was read** -- "absent"
  # (1), not undetermined.
  rein_agents_has_live '[]' "x"
  st_rc=$?
  if [ "$st_rc" -eq 1 ]; then
    st_ok
  else
    st_fail "identifies an empty listing as absent" "rc=${st_rc}"
  fi

  # Sanity-check that the fake CLI's listing **distinguishes** the plain listing from `--all`. As
  # measured, the real CLI never surfaces an exited entry in the plain listing at all -- only
  # `--all` shows it. Under a shim that doesn't distinguish them, swapping `rein prune`'s listing
  # interface (which can only pull candidates from exited entries) for the plain listing would
  # still pass this test, while in the real environment the candidate count would silently stay at
  # zero and it would never get cleaned up.
  case_dir="$tmp/agents-all"
  st_setup_case "$case_dir"
  rein_st_write_agents "$ST_CWD/live.json" "$ST_CWD" "live-1"
  rein_st_write_agents_done "$ST_CWD/past.json" "$ST_CWD" "past-1"
  jq -s 'add' "$ST_CWD/live.json" "$ST_CWD/past.json" >"$ST_CWD/mixed.json"
  st_plain_ids="$(FAKE_LOG="$ST_LOG" FAKE_AGENTS="$ST_CWD/mixed.json" \
    "$ST_BIN/claude" agents --json | jq -r '[ .[].sessionId ] | join(",")')"
  st_all_ids="$(FAKE_LOG="$ST_LOG" FAKE_AGENTS="$ST_CWD/mixed.json" \
    "$ST_BIN/claude" agents --json --all | jq -r '[ .[].sessionId ] | join(",")')"
  if [ "$st_plain_ids" = "live-1" ] && [ "$st_all_ids" = "live-1,past-1" ]; then
    st_ok
  else
    st_fail "the fake CLI's plain listing returns only live entries" \
      "plain=${st_plain_ids} / --all=${st_all_ids}"
  fi

  # A stop **never deletes** an entry (it drops from the plain listing and stays in `--all` as
  # exited -- measured). Only rm actually clears it; treating these two the same would make the
  # generation `rein prune` is meant to pick up right after `rein down` disappear from selftest.
  FAKE_LOG="$ST_LOG" FAKE_AGENTS="$ST_CWD/mixed.json" \
    "$ST_BIN/claude" stop job-live-1 >/dev/null 2>&1
  st_plain_ids="$(FAKE_LOG="$ST_LOG" FAKE_AGENTS="$ST_CWD/mixed.json" \
    "$ST_BIN/claude" agents --json | jq -r '[ .[].sessionId ] | join(",")')"
  st_all_ids="$(FAKE_LOG="$ST_LOG" FAKE_AGENTS="$ST_CWD/mixed.json" \
    "$ST_BIN/claude" agents --json --all | jq -r '[ .[].sessionId ] | join(",")')"
  if [ -z "$st_plain_ids" ] && [ "$st_all_ids" = "live-1,past-1" ]; then
    st_ok
  else
    st_fail "a stopped entry drops from the plain listing and stays in --all" \
      "plain=${st_plain_ids} / --all=${st_all_ids}"
  fi
  FAKE_LOG="$ST_LOG" FAKE_AGENTS="$ST_CWD/mixed.json" \
    "$ST_BIN/claude" rm job-live-1 >/dev/null 2>&1
  st_all_ids="$(FAKE_LOG="$ST_LOG" FAKE_AGENTS="$ST_CWD/mixed.json" \
    "$ST_BIN/claude" agents --json --all | jq -r '[ .[].sessionId ] | join(",")')"
  if [ "$st_all_ids" = "past-1" ]; then
    st_ok
  else
    st_fail "rm also removes it from --all" "--all=${st_all_ids}"
  fi

  # Sanity-check the fake CLI itself: if, matching real behavior, it "refuses a full session_id
  # and accepts a short job ID", the stop cases above can genuinely detect an ID mix-up (the
  # accepting side alone can't tell a real check apart from a too-loose tool).
  case_dir="$tmp/fake-cli-contract"
  st_setup_case "$case_dir"
  if FAKE_LOG="$ST_LOG" FAKE_AGENTS="$ST_AGENTS" "$ST_BIN/claude" stop pred-1 >/dev/null 2>&1; then
    st_fail "the fake CLI refuses a stop by full session_id" "it accepted the full session_id"
  elif ! FAKE_LOG="$ST_LOG" FAKE_AGENTS="$ST_AGENTS" "$ST_BIN/claude" stop job-pred-1 >/dev/null 2>&1; then
    st_fail "the fake CLI accepts a stop by short job ID" "it refused the short ID"
  else
    st_ok
  fi

  st_successor_listing_shape
}

# Hands one enumeration body straight to the successor identification. The listing fetch is
# replaced **inside a subshell**, so the replacement never reaches a later section, and
# TARGET_CWD is supplied here because the identification narrows by it.
# The identified session ID goes to stdout; the caller reads the return value.
st_successor_for_listing() {
  (
    ST_LISTING_BODY="$1"
    TARGET_CWD="$2"
    # shellcheck disable=SC2329  # called indirectly, from find_successor_session_id below
    rein_list_agents() { printf '%s' "$ST_LISTING_BODY"; }
    find_successor_session_id "$3" 0 '[]' 2>/dev/null
  )
}

# The entry check on the enumeration the successor is identified from. `jq -e .` alone only asks
# "is this valid JSON", so a body that is valid JSON but is not an array of objects reaches the
# narrowing jq, which fails with a runtime error; the match set comes out empty and, without the
# shared entry check, that is returned as **1 -- "not present yet"**. That one value is what makes
# the cleanup of a launched successor return "there is no one to clean up" without a word (leaving
# a background session running in the same working tree the kickoff tells it to work in), and what
# makes bootstrap's "is this name already taken" probe read a broken CLI as "nobody is here".
st_successor_listing_shape() {
  case_dir="$tmp/successor-listing-shape"
  st_setup_case "$case_dir"
  for st_nonarray in '{"error":"not logged in"}' '[1,2,3]' '["str"]' '[null]' '"plain string"'; do
    st_successor_for_listing "$st_nonarray" "$ST_CWD" predecessor >/dev/null 2>&1
    st_rc=$?
    if [ "$st_rc" -eq 2 ]; then
      st_ok
    else
      st_fail "reads a listing that is not an array of objects as unreadable (${st_nonarray})" \
        "rc=${st_rc} (1 means \"not present yet\" -- a launched successor would be left unmanaged)"
    fi
  done
  # The accepting side, off the same fixture the real cases use (so none of the above can be
  # passing because identification simply stopped resolving anything).
  rein_st_write_agents "$ST_CWD/one.json" "$ST_CWD" "succ-1"
  st_found="$(st_successor_for_listing "$(cat "$ST_CWD/one.json")" "$ST_CWD" predecessor)"
  st_rc=$?
  if [ "$st_rc" -eq 0 ] && [ "$st_found" = "succ-1" ]; then
    st_ok
  else
    st_fail "a listing that can be read still identifies the successor" "rc=${st_rc} / [${st_found}]"
  fi
  # An empty enumeration is **a listing that was read** -- "not present yet" (1), not unreadable
  # (this is the value the launch-confirmation wait keeps polling on, so widening the entry check
  # onto it would turn every pre-launch round into a stage failure).
  st_successor_for_listing '[]' "$ST_CWD" predecessor >/dev/null 2>&1
  st_rc=$?
  if [ "$st_rc" -eq 1 ]; then
    st_ok
  else
    st_fail "reads an empty listing as not present yet" "rc=${st_rc}"
  fi
  # And more than one candidate under the same name is still 3 (the caller refuses to pick).
  rein_st_write_agents "$ST_CWD/two.json" "$ST_CWD" "succ-1" "succ-2"
  st_successor_for_listing "$(cat "$ST_CWD/two.json")" "$ST_CWD" predecessor >/dev/null 2>&1
  st_rc=$?
  if [ "$st_rc" -eq 3 ]; then
    st_ok
  else
    st_fail "reads several candidates under one name as undecidable" "rc=${st_rc}"
  fi
}
