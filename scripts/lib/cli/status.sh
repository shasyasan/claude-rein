# shellcheck shell=bash
# Implementation of `rein status` (the lineage's current state). The only machine-readable form
# is `status --json` (the verb that returned watcher liveness via exit code is retired).
# Not an executable script, so it doesn't get the execute bit (out of scope for the --selftest convention).

# The watcher's overall state. Process state (is the watcher lock's owner alive, and is it really
# the watcher) and heartbeat freshness are separate facts, so both are gathered before folding
# them together -- a hung watcher is still alive as a process, so judging "running" from process
# state alone would report a state where handover never arrives as normal.
# Results: WATCHER_OVERALL (running / stale / stopped / unknown), WATCHER_PROCESS_STATE,
# WATCHER_HEARTBEAT_AGE (empty = no heartbeat), WATCHER_PID, WATCHER_REASON.
watcher_overall_state() {
  local rc mtime
  WATCHER_OVERALL=""
  WATCHER_PROCESS_STATE=""
  WATCHER_HEARTBEAT_AGE=""
  watcher_state "$RUNTIME_DIR"
  rc=$?
  case "$rc" in
    0) WATCHER_PROCESS_STATE="running" ;;
    1) WATCHER_PROCESS_STATE="stopped" ;;
    *) WATCHER_PROCESS_STATE="unknown" ;;
  esac
  mtime="$(rein_mtime "$HEARTBEAT_FILE")"
  case "$mtime" in
    '' | *[!0-9]*) ;;
    *) WATCHER_HEARTBEAT_AGE=$(($(rein_now_epoch) - mtime)) ;;
  esac
  WATCHER_OVERALL="$WATCHER_PROCESS_STATE"
  if [ "$WATCHER_PROCESS_STATE" != "running" ]; then
    return 0
  fi
  if [ -z "$WATCHER_HEARTBEAT_AGE" ]; then
    WATCHER_OVERALL="unknown"
    WATCHER_REASON="no heartbeat (can't confirm the watch loop is turning over): ${HEARTBEAT_FILE}"
    return 0
  fi
  if [ -n "$HEARTBEAT_MAX_AGE_SEC" ] && [ "$HEARTBEAT_MAX_AGE_SEC" -gt 0 ] &&
    [ "$WATCHER_HEARTBEAT_AGE" -gt "$HEARTBEAT_MAX_AGE_SEC" ]; then
    WATCHER_OVERALL="stale"
    printf -v WATCHER_REASON 'heartbeat is %s seconds old (cap %s seconds)' \
      "$WATCHER_HEARTBEAT_AGE" "$HEARTBEAT_MAX_AGE_SEC"
  fi
  return 0
}

watcher_overall_line() {
  local heartbeat="no heartbeat"
  [ -z "$WATCHER_HEARTBEAT_AGE" ] || printf -v heartbeat '%s seconds ago' "$WATCHER_HEARTBEAT_AGE"
  case "$WATCHER_OVERALL" in
    running) printf 'running (pid=%s) / heartbeat %s\n' "$WATCHER_PID" "$heartbeat" ;;
    stale) printf 'stalled (pid=%s, %s) / heartbeat %s\n' "$WATCHER_PID" "$WATCHER_REASON" "$heartbeat" ;;
    stopped) printf 'not running (%s) / heartbeat %s\n' "$WATCHER_REASON" "$heartbeat" ;;
    *) printf 'undetermined (%s) / heartbeat %s\n' "$WATCHER_REASON" "$heartbeat" ;;
  esac
}

status_stop_request_line() {
  local at
  if [ ! -f "$STOP_REQUEST_FILE" ]; then
    printf 'none\n'
    return 0
  fi
  at="$(jq -r --arg s "$REIN_STOP_REQUEST_SCHEMA" \
    'select(.schema == $s) | .requested_at // empty' "$STOP_REQUEST_FILE" 2>/dev/null)"
  if [ -z "$at" ]; then
    printf 'present (not in contract form -- the watcher will not accept it): %s\n' "$STOP_REQUEST_FILE"
    return 0
  fi
  printf 'present (requested at %s)\n' "$at"
}

# The seat-stop marker (left by `down` when it folds the lineage down). If a seat attaches while
# it's still there, that seat quietly goes down on its first attach return, so this makes it
# visible from status too.
status_seat_stop_line() {
  local at
  if [ ! -f "$SEAT_STOP_FILE" ]; then
    printf 'none\n'
    return 0
  fi
  at="$(jq -r --arg s "$REIN_SEAT_STOP_SCHEMA" \
    'select(.schema == $s) | .requested_at // empty' "$SEAT_STOP_FILE" 2>/dev/null)"
  if [ -z "$at" ]; then
    printf 'present (not in contract form -- the seat will not consume it; the next seat to attach, or up, will clean it up): %s\n' "$SEAT_STOP_FILE"
    return 0
  fi
  printf 'present (requested at %s)\n' "$at"
}

# The enumeration status fetches **exactly once**. Both the primary session's liveness and the
# cleanup candidates read this same result -- fetching it per-reader would hit the external
# command twice per `status` call, doubling the wait in an environment where enumeration is slow
# or hangs. It fetches with `--all` (including finished sessions) because that's the only form
# that can count sessions from completed generations (liveness judged against a superset gives
# the same answer).
# Output = the enumeration (empty = couldn't be read; each reader falls back to its own
# 'undetermined').
status_agents_snapshot() {
  local agents
  agents="$(rein_list_agents_all)"
  [ -n "$agents" ] || return 0
  printf '%s' "$agents" | jq -e . >/dev/null 2>&1 || return 0
  printf '%s' "$agents"
}

# The cleanup-candidate count. Counted through the same implementation `prune` uses (so status
# never says "0 candidates" while `prune` turns up some). **A kind that can't be counted is never
# forced to 0** -- session, when enumeration can't be read; orphan, when a cross-lineage scan
# doesn't apply to this lineage; child, when the current pointer can't be validated (nothing
# names which session's entries must be kept) -- each comes back with its own reason instead.
status_prune_line() {
  local orphan session child note=""
  prune_count_candidates "$@"
  orphan="$PRUNE_COUNT_ORPHAN"
  session="$PRUNE_COUNT_SESSION"
  child="$PRUNE_COUNT_CHILD"
  if [ -z "$orphan" ]; then
    orphan="not scanned"
    note="${note}${note:+, }orphan: ${PRUNE_COUNT_ORPHAN_REASON}"
  fi
  if [ -z "$session" ]; then
    session="undetermined"
    note="${note}${note:+, }session: ${PRUNE_COUNT_SESSION_REASON}"
  fi
  if [ -z "$child" ]; then
    child="not scanned"
    note="${note}${note:+, }child: ${PRUNE_COUNT_CHILD_REASON}"
  fi
  # The guidance for listing is shaped so **it can be typed as-is for this lineage** (cleanup
  # candidates are per-lineage, so a bare `rein prune` counts the lineage of wherever it was typed).
  # Assembled through one shared function.
  rein_lineage_cmd "$CLI_REIN_CMD" "$RUNTIME_DIR" "$RECORDS_DIR" "$TARGET_CWD" prune
  printf 'archive %s / child %s / orphan %s / session %s (list with %s%s)\n' \
    "$PRUNE_COUNT_ARCHIVE" "$child" "$orphan" "$session" "$REIN_LINEAGE_CMD" "${note:+. $note}"
}

# Whether the last step of a handover (stepping the predecessor session aside) is still
# outstanding. **A handover in progress normally passes through this exact shape** -- after the
# successor starts and the pointer advances, the successor and the predecessor coexist during
# the grace period -- so this reads the watcher's own running state to tell the two apart (running
# means that step is actively in progress; not running means nobody is left to carry it forward).
# The judgment goes through the same one shared-library function the watcher's own resume uses.
# It reads WATCHER_PROCESS_STATE, so call it after watcher_overall_state.
STATUS_STRANDED_STATE=""
STATUS_STRANDED_ID=""
STATUS_STRANDED_SUCCESSOR=""
status_stranded_state() {
  local rc
  STATUS_STRANDED_STATE=""
  STATUS_STRANDED_ID=""
  STATUS_STRANDED_SUCCESSOR=""
  rein_stranded_predecessor "$POINTER_FILE" "$TARGET_CWD" "$1"
  rc=$?
  case "$rc" in
    0)
      STATUS_STRANDED_ID="$REIN_STRANDED_PREDECESSOR"
      # What's checked is **process state** (not heartbeat freshness) -- the same material as
      # doctor's own judgment. Reading a hung watcher as "not there" would fire "stranded" for
      # that state alone, splitting the same cause into two reports (a stalled response is
      # reported separately, on the watcher line).
      if [ "$WATCHER_PROCESS_STATE" = "running" ]; then
        STATUS_STRANDED_STATE="in_progress"
      else
        STATUS_STRANDED_STATE="stranded"
      fi
      ;;
    # The shape where only one side of a handover died (the primary session on record isn't in
    # enumeration, but the predecessor is alive). Without this branch it used to fall into `*)`'s
    # `none`, so `status` reported this exact state as 'none' -- since this is a state that was
    # deliberately decided never to be auto-repaired, having only doctor, `up`, and the GUI
    # notification as the three places that surface it meant anyone reading `status` alone would
    # read it as normal.
    3)
      STATUS_STRANDED_STATE="handover_mismatch"
      STATUS_STRANDED_ID="$REIN_STRANDED_PREDECESSOR"
      STATUS_STRANDED_SUCCESSOR="$REIN_STRANDED_SUCCESSOR"
      ;;
    2) STATUS_STRANDED_STATE="unknown" ;;
    *) STATUS_STRANDED_STATE="none" ;;
  esac
  return 0
}

status_stranded_line() {
  case "$STATUS_STRANDED_STATE" in
    in_progress)
      printf 'none (handover in progress -- predecessor session %s is coexisting during the grace period)\n' "$STATUS_STRANDED_ID"
      ;;
    stranded)
      rein_lineage_cmd "$CLI_REIN_CMD" "$RUNTIME_DIR" "$RECORDS_DIR" "$TARGET_CWD" up
      printf 'present (predecessor session %s is still there with no watcher running. Starting the watcher will resume it on startup: %s)\n' \
        "$STATUS_STRANDED_ID" "$REIN_LINEAGE_CMD"
      ;;
    # The explanation and the fix both come from one place in the shared library (the same one
    # sentence watcher and doctor use). Composing a different message here would scatter the fix
    # for the same state across three places, and one of them would go stale.
    handover_mismatch)
      printf '%s\n' "$(rein_handover_mismatch_detail "$CLI_REIN_CMD" "$STATUS_STRANDED_SUCCESSOR" \
        "$STATUS_STRANDED_ID" "$TARGET_CWD" "$(cli_handover_failure_cause)" \
        "$RUNTIME_DIR" "$RECORDS_DIR")"
      ;;
    unknown) printf 'undetermined (%s)\n' "$(rein_list_agents_error)" ;;
    *) printf 'none\n' ;;
  esac
}

status_marker_line() {
  local sid at
  if [ ! -f "$MARKER_FILE" ]; then
    printf 'none\n'
    return 0
  fi
  sid="$(jq -r '.session_id // empty' "$MARKER_FILE" 2>/dev/null)"
  at="$(jq -r '.requested_at // empty' "$MARKER_FILE" 2>/dev/null)"
  printf 'present (requested by %s / %s)\n' "${sid:-unknown}" "${at:-unknown time}"
}

status_snooze_line() {
  local remaining
  remaining="$(snooze_remaining_sec)" || {
    printf 'none\n'
    return 0
  }
  printf '%s seconds remaining\n' "$remaining"
}

# The handoff document's **effective value** and origin (if unset, the default -- next to the
# records). This is shown in status so both the user and the successor can confirm, in one
# place, which file a handover request will look at (the current pointer's handoff_path is the
# value the predecessor declared, and stays stale after a move).
# Also checks existence -- a document that can't be accepted fails just before the handover (the
# R6 / bootstrap acceptance check), so this shows "config points somewhere, but handover alone
# stalls" at the status stage. **Judged through the same one function as the acceptance check** --
# checking status with looser conditions would report a symlink or a directory at that location
# as "there", right up until handover fails on it.
# A section-structure mismatch is shown **for display only** (never folded into the acceptance
# judgment, STATUS_HANDOFF_PRESENT) -- folding it in would change the meaning for every other
# path that uses status's own present/absent as material, not just handover requests.
# It's shown because a section-structure deviation is otherwise only discoverable **at the
# moment of a handover request itself** -- noticing it there means noticing it right when context
# is running out, just before a handover. Showing "config points somewhere, but handover alone
# stalls" at the status stage is the exact same reason this function is routed through the same
# one function as the acceptance check.
STATUS_HANDOFF_PATH=""
STATUS_HANDOFF_ORIGIN=""
STATUS_HANDOFF_PRESENT=0
STATUS_HANDOFF_SECTIONS_OK=1
STATUS_HANDOFF_SECTIONS_DETAIL=""
status_handoff_state() {
  STATUS_HANDOFF_PATH=""
  STATUS_HANDOFF_ORIGIN=""
  STATUS_HANDOFF_PRESENT=0
  STATUS_HANDOFF_SECTIONS_OK=1
  STATUS_HANDOFF_SECTIONS_DETAIL=""
  rein_config_fetch handoff_path || return 1
  STATUS_HANDOFF_PATH="$REIN_CONFIG_VALUE"
  STATUS_HANDOFF_ORIGIN="$REIN_CONFIG_ORIGIN"
  if [ -n "$STATUS_HANDOFF_PATH" ] && rein_handoff_file_ok "$STATUS_HANDOFF_PATH"; then
    STATUS_HANDOFF_PRESENT=1
    # Sections are only checked once it's known to be in an acceptable shape (never read as a
    # directory or a symlink).
    if ! rein_handoff_sections_ok "$STATUS_HANDOFF_PATH"; then
      STATUS_HANDOFF_SECTIONS_OK=0
      STATUS_HANDOFF_SECTIONS_DETAIL="$REIN_HANDOFF_SECTION_DETAIL"
    fi
  fi
  return 0
}

status_handoff_line() {
  status_handoff_state || {
    printf 'undetermined (%s)\n' "$REIN_CONFIG_ERROR"
    return 0
  }
  if [ -z "$STATUS_HANDOFF_PATH" ]; then
    printf 'disabled (the handoff_path in config is explicitly empty)\n'
    return 0
  fi
  if [ "$STATUS_HANDOFF_PRESENT" -eq 1 ]; then
    if [ "$STATUS_HANDOFF_SECTIONS_OK" -eq 0 ]; then
      printf '%s (origin %s, section structure does not match the template -- a handover request in this shape will be rejected: %s)\n' \
        "$STATUS_HANDOFF_PATH" "$STATUS_HANDOFF_ORIGIN" "$STATUS_HANDOFF_SECTIONS_DETAIL"
    else
      printf '%s (origin %s)\n' "$STATUS_HANDOFF_PATH" "$STATUS_HANDOFF_ORIGIN"
    fi
  else
    rein_lineage_cmd "$CLI_REIN_CMD" "$RUNTIME_DIR" "$RECORDS_DIR" "$TARGET_CWD" init
    printf '%s (origin %s, missing, empty, or not an acceptable shape -- the template for this lineage can be created with %s)\n' \
      "$STATUS_HANDOFF_PATH" "$STATUS_HANDOFF_ORIGIN" "$REIN_LINEAGE_CMD"
  fi
}

# The seat line. Presence and **what the seat is connected to** are two separate observations, and
# the line reports the pair -- a seat can be perfectly present while still holding a session the
# pointer moved off, which is exactly the state that used to read as a bare "attached (pid=N)"
# with nothing to act on. The pointer's id is handed in from the **same contract-validated read**
# the rest of the table already did (re-reading it raw here would let two readers of one file
# disagree, and would compare against a pointer that violates the contract as though it were
# authoritative); an empty one means that read didn't produce an id, so the line says the
# comparison couldn't be made instead of quietly reporting a mismatch against nothing.
# **Four states, not three.** "Connected and in step" and "connected but the pointer moved on" are
# joined by "there is nothing to compare against" (an unreadable pointer must never be reported as
# a mismatch against nothing) and by the several ways there is no connection at all right now --
# which the seat log can only distinguish because it records the end of an attach as well as the
# start (see seat_connection_state in lib/cli/base.sh).
# shellcheck disable=SC2153  # SEAT_PID / SEAT_ATTACHED_ID come from the foundation (lib/cli/base.sh) -- different variables from the same-named locals
status_seat_line() {
  local pointer_id="$1"
  if ! find_seat_pid; then
    printf 'none\n'
    return 0
  fi
  seat_connection_state
  case "$SEAT_CONNECTION_STATE" in
    unreadable)
      printf 'attached (pid=%s, connection state unknown -- %s: %s)\n' \
        "$SEAT_PID" "$SEAT_CONNECTION_DETAIL" "$SEAT_LOG_FILE"
      return 0
      ;;
    none)
      printf 'attached (pid=%s, not connected yet -- %s)\n' "$SEAT_PID" "$SEAT_CONNECTION_DETAIL"
      return 0
      ;;
    between)
      printf 'attached (pid=%s, not connected right now -- attach last returned from %s, so the seat is between attaches: resolving the successor, or waiting for a handover)\n' \
        "$SEAT_PID" "$SEAT_ATTACHED_ID"
      return 0
      ;;
  esac
  if [ -z "$pointer_id" ]; then
    printf 'attached (pid=%s, connected to %s, cannot be compared against the current pointer)\n' \
      "$SEAT_PID" "$SEAT_ATTACHED_ID"
    return 0
  fi
  if [ "$SEAT_ATTACHED_ID" = "$pointer_id" ]; then
    printf 'attached (pid=%s, connected to %s, matches the current pointer)\n' \
      "$SEAT_PID" "$SEAT_ATTACHED_ID"
    return 0
  fi
  printf 'attached (pid=%s, connected to %s, but the current pointer is %s -- %s)\n' \
    "$SEAT_PID" "$SEAT_ATTACHED_ID" "$pointer_id" "$REIN_SEAT_DETACH_HINT"
  return 0
}

status_human() {
  local rc generation main_line watcher_line seat_line event seat_event agents
  agents="$(status_agents_snapshot)"
  # `generation` also comes from the **same one contract-validated read** as the primary session's
  # judgment. Reading it raw would show the generation of a pointer that violates the contract
  # (e.g. a copy from a different lineage) as though it were readable.
  main_session_state "$agents"
  rc=$?
  generation="${MAIN_SESSION_GENERATION:--}"
  case "$rc" in
    0) printf -v main_line '%s (%s) -- present' "$MAIN_SESSION_ID" "${MAIN_SESSION_NAME:-unnamed}" ;;
    1)
      if [ -n "$MAIN_SESSION_ID" ]; then
        printf -v main_line '%s (%s) -- %s' "$MAIN_SESSION_ID" "${MAIN_SESSION_NAME:-unnamed}" "$MAIN_SESSION_REASON"
      else
        printf -v main_line 'none (%s)' "$MAIN_SESSION_REASON"
      fi
      ;;
    *) printf -v main_line 'undetermined (%s)' "$MAIN_SESSION_REASON" ;;
  esac
  watcher_overall_state
  watcher_line="$(watcher_overall_line)"
  status_stranded_state "$agents"
  seat_line="$(status_seat_line "$MAIN_SESSION_ID")"
  event="$(log_last_event_json)" || event=""
  seat_event="$(seat_log_last_event_json)" || seat_event=""

  printf 'target: %s\n' "$TARGET_CWD"
  printf 'records: %s\n' "$RECORDS_DIR"
  printf 'handoff: %s\n' "$(status_handoff_line)"
  printf 'runtime: %s\n' "$RUNTIME_DIR"
  printf 'generation: %s\n' "$generation"
  printf 'primary session: %s\n' "$main_line"
  printf 'watcher: %s\n' "$watcher_line"
  printf 'stranded: %s\n' "$(status_stranded_line)"
  printf 'seat: %s\n' "$seat_line"
  printf 'pending marker: %s\n' "$(status_marker_line)"
  printf 'stop request: %s\n' "$(status_stop_request_line)"
  printf 'seat stop: %s\n' "$(status_seat_stop_line)"
  printf 'operation lock: %s\n' "$(op_lock_state_line)"
  printf 'snooze: %s\n' "$(status_snooze_line)"
  printf 'cleanup candidates: %s\n' "$(status_prune_line "$agents")"
  if [ -n "$event" ]; then
    printf 'last event: %s %s\n' \
      "$(printf '%s' "$event" | jq -r '.event // "unknown"')" \
      "$(printf '%s' "$event" | jq -r '.ts // "unknown time"')"
  else
    printf 'last event: none\n'
  fi
  if [ -n "$seat_event" ]; then
    printf 'seat log: %s %s\n' \
      "$(printf '%s' "$seat_event" | jq -r '.event // "unknown"')" \
      "$(printf '%s' "$seat_event" | jq -r '.ts // "unknown time"')"
  else
    printf 'seat log: none\n'
  fi
  return 0
}

# The list of files that couldn't be read as contract-shaped (a single JSON value). **Reduced to
# this before being passed to `--argjson`** -- `jq -c .` prints two lines when a file holds two
# JSON values, and those two lines slip past the empty check (`[ -n ]`) and blow up the final
# assembly with `jq: invalid JSON text passed to --argjson`. In exactly the scenario where you'd
# want to diagnose a broken record, the machine-readable path used to come back with **empty
# stdout and rc=2** (the same code as an argument error) -- even though the human-readable status
# can report the reason with rc=0 for the same state.
STATUS_UNREADABLE_JSON="[]"
STATUS_JSON_VALUE="null"

status_note_unreadable() {
  local next
  next="$(jq -nc --argjson acc "$STATUS_UNREADABLE_JSON" \
    --arg field "$1" --arg path "$2" --arg reason "$3" \
    '$acc + [{field: $field, path: $path, reason: $reason}]' 2>/dev/null)" || return 0
  [ -n "$next" ] || return 0
  STATUS_UNREADABLE_JSON="$next"
  return 0
}

# Narrows `jq -c .`'s output down to **a single JSON value** safe to pass straight to
# `--argjson`. A single value always prints as exactly one line, so the moment a newline shows up
# it's "not a single JSON value." Anything that doesn't pass becomes null, and the file is instead
# named explicitly in the unreadable list -- giving the machine reader the same material (what's
# actually sitting there) that human-readable status already reports.
# **What an empty result means is the caller's to declare** (4th argument), because the two things
# it can mean are indistinguishable from in here. `jq` prints nothing at all when it gives up on
# its input, so for a record file the caller already found on disk, empty is the most ordinary
# corruption there is -- a record caught half-written. For a log's last event, empty is instead
# "this log holds no event yet," which is not a fault at all. Folding both into a silent `null`
# reported that corruption as "there is nothing here," and only to the machine-readable reader:
# the human-readable view calls the very same file present, so `--json` was the one form answering
# "no stop request is outstanding" for a stop request sitting right there unreadable.
#   `unreadable` = empty means it could not be read (name the file)
#   `absent`     = empty means nothing has been recorded yet (say nothing)
# An unknown value is not resolved to either one: it lands in the unreadable list naming itself,
# so a call site added without deciding this shows up instead of silently picking a meaning.
status_take_json_text() {
  local field="$1" path="$2" text="$3" empty="$4"
  STATUS_JSON_VALUE="null"
  case "$empty" in
    unreadable | absent) ;;
    *)
      status_note_unreadable "$field" "$path" "cannot say what an empty read means here (the caller declared \"${empty}\", which is not one of unreadable / absent)"
      return 0
      ;;
  esac
  if [ -z "$text" ]; then
    if [ "$empty" = "unreadable" ]; then
      status_note_unreadable "$field" "$path" "cannot be read as JSON (not a record in contract form)"
    fi
    return 0
  fi
  case "$text" in
    *$'\n'*)
      status_note_unreadable "$field" "$path" "not a single JSON value (not a record in contract form)"
      return 0
      ;;
  esac
  STATUS_JSON_VALUE="$text"
  return 0
}

status_json() {
  local rc main_state generation pointer marker snooze event seat_event generations watcher_json
  local seat_pid="" seat_attached_id="" seat_connection="" heartbeat_age="" remaining stop_request seat_stop op_lock_pid op_lock_state
  local prune_json agents
  STATUS_UNREADABLE_JSON="[]"
  agents="$(status_agents_snapshot)"
  main_session_state "$agents"
  rc=$?
  case "$rc" in
    0) main_state="live" ;;
    1) main_state="exited" ;;
    *) main_state="unknown" ;;
  esac
  # Doesn't collapse "the target isn't there" and "can't be judged at all" together -- it folds to
  # none **only on absence (rc=1)**. Folding an undetermined case (a pointer that violates the
  # contract, an enumeration that can't be read) into none too would let a machine reader conclude
  # "no primary session" and proceed to start the first generation.
  if [ "$rc" -eq 1 ] && [ -z "$MAIN_SESSION_ID" ]; then
    main_state="none"
  fi
  # `generation` reports only a value that passed contract validation (the same single judgment as
  # the human-readable table). `pointer` is **the file itself**, not the validation result, so it's
  # included as-is even when it violates the contract -- letting a machine reader diagnose what's
  # actually sitting there.
  generation="$MAIN_SESSION_GENERATION"
  pointer="null"
  if [ -f "$POINTER_FILE" ]; then
    status_take_json_text pointer "$POINTER_FILE" "$(jq -c . "$POINTER_FILE" 2>/dev/null)" unreadable
    pointer="$STATUS_JSON_VALUE"
  fi
  marker="null"
  if [ -f "$MARKER_FILE" ]; then
    status_take_json_text marker "$MARKER_FILE" "$(jq -c . "$MARKER_FILE" 2>/dev/null)" unreadable
    marker="$STATUS_JSON_VALUE"
  fi
  snooze="null"
  remaining="$(snooze_remaining_sec)" && {
    status_take_json_text snooze "$SNOOZE_FILE" \
      "$(jq -c --argjson remaining "$remaining" '. + {remaining_sec: $remaining}' \
        "$SNOOZE_FILE" 2>/dev/null)" unreadable
    snooze="$STATUS_JSON_VALUE"
  }
  # **The two log lines are the ones where empty is not a fault**: a lineage that has not handed
  # over yet, and a seat that has not been sat in yet, both legitimately have no last event, and
  # naming those files as unreadable would put a permanent entry in the list for a lineage with
  # nothing wrong with it. The human-readable form answers `none` for the same state, so the two
  # forms stay in step. Every other record here is one the caller already found on disk.
  status_take_json_text last_event "$LOG_FILE" "$(log_last_event_json)" absent
  event="$STATUS_JSON_VALUE"
  status_take_json_text seat_last_event "$SEAT_LOG_FILE" "$(seat_log_last_event_json)" absent
  seat_event="$STATUS_JSON_VALUE"
  generations="$(log_generations_json)"
  if [ -z "$generations" ]; then
    fail "cannot read the handover log: ${LOG_FILE}"
    return 1
  fi
  # Process state and heartbeat freshness are reported as separate fields (with only the overall
  # state, a reader can't tell "it's hung" apart from "it was never there").
  watcher_overall_state
  heartbeat_age="$WATCHER_HEARTBEAT_AGE"
  watcher_json="$(jq -nc \
    --arg state "$WATCHER_OVERALL" \
    --arg process_state "$WATCHER_PROCESS_STATE" \
    --arg pid "$WATCHER_PID" \
    --arg reason "$WATCHER_REASON" \
    --arg max_age "$HEARTBEAT_MAX_AGE_SEC" \
    '{state: $state,
      process_state: $process_state,
      pid: (if $pid == "" then null else ($pid | tonumber) end),
      reason: (if $reason == "" then null else $reason end),
      heartbeat_max_age_sec: (if $max_age == "" then null else ($max_age | tonumber) end)}')"
  status_stranded_state "$agents"
  stop_request="null"
  if [ -f "$STOP_REQUEST_FILE" ]; then
    status_take_json_text stop_request "$STOP_REQUEST_FILE" \
      "$(jq -c . "$STOP_REQUEST_FILE" 2>/dev/null)" unreadable
    stop_request="$STATUS_JSON_VALUE"
  fi
  seat_stop="null"
  if [ -f "$SEAT_STOP_FILE" ]; then
    status_take_json_text seat_stop "$SEAT_STOP_FILE" \
      "$(jq -c . "$SEAT_STOP_FILE" 2>/dev/null)" unreadable
    seat_stop="$STATUS_JSON_VALUE"
  fi
  op_lock_pid="$(rein_lock_pid "$OP_LOCK_DIR")" || op_lock_pid=""
  case "$op_lock_pid" in
    *[!0-9]*) op_lock_pid="" ;;
  esac
  op_lock_state="none"
  if [ -d "$OP_LOCK_DIR" ]; then
    if [ -z "$op_lock_pid" ]; then
      op_lock_state="unreadable"
    else
      rein_pid_alive "$op_lock_pid"
      case $? in
        0) op_lock_state="held" ;;
        # A liveness state that can't be confirmed is not "the owner is gone (the next up / down
        # will reclaim it)" -- since the acquiring side never reclaims it, the reader doesn't call
        # it stale either (the classification isn't split apart).
        2) op_lock_state="unreadable" ;;
        *) op_lock_state="stale" ;;
      esac
    fi
  fi
  if find_seat_pid; then
    # shellcheck disable=SC2153  # SEAT_PID / SEAT_ATTACHED_ID / SEAT_CONNECTION_STATE come from the foundation (lib/cli/base.sh) -- different variables from the same-named locals
    seat_pid="$SEAT_PID"
    # The machine reader gets the same triple the human line reports (presence, the connection's
    # state, and what it is connected to). Reporting presence to one reader and the full state to
    # the other would let an automated check keep concluding "the seat is fine" in exactly the
    # state the human line now calls out.
    seat_connection_state
    seat_connection="$SEAT_CONNECTION_STATE"
    # shellcheck disable=SC2153  # SEAT_ATTACHED_ID is the foundation's, filled in by the call above
    seat_attached_id="$SEAT_ATTACHED_ID"
    # "The seat log could not be read" rides the same list every other unreadable record does,
    # instead of being folded into "nothing recorded yet" -- a reader that cannot tell those two
    # apart is back to being unable to say whether the seat is in step.
    if [ "$SEAT_CONNECTION_STATE" = "unreadable" ]; then
      status_note_unreadable seat_connection "$SEAT_LOG_FILE" "$SEAT_CONNECTION_DETAIL"
    fi
  fi
  if ! status_handoff_state; then
    fail "$REIN_CONFIG_ERROR"
    return 1
  fi
  # The candidate count goes through the same scan `prune` uses (the counting logic isn't kept in
  # two places). The enumeration is the one fetched once above.
  prune_count_candidates "$agents"
  prune_json="$(jq -nc \
    --arg archive "$PRUNE_COUNT_ARCHIVE" \
    --arg orphan "$PRUNE_COUNT_ORPHAN" \
    --arg orphan_reason "$PRUNE_COUNT_ORPHAN_REASON" \
    --arg session "$PRUNE_COUNT_SESSION" \
    --arg session_reason "$PRUNE_COUNT_SESSION_REASON" \
    --arg child "$PRUNE_COUNT_CHILD" \
    --arg child_reason "$PRUNE_COUNT_CHILD_REASON" \
    '{archive: ($archive | tonumber),
      orphan: (if $orphan == "" then null else ($orphan | tonumber) end),
      orphan_reason: (if $orphan_reason == "" then null else $orphan_reason end),
      session: (if $session == "" then null else ($session | tonumber) end),
      session_reason: (if $session_reason == "" then null else $session_reason end),
      child: (if $child == "" then null else ($child | tonumber) end),
      child_reason: (if $child_reason == "" then null else $child_reason end)}')"

  # Section structure is reported under a **separate key** from `present` (the same discipline as
  # status and doctor -- never folded into the acceptance judgment). A machine reader that reads
  # only `present` would read "the document is there" and then fail at handover -- a handover
  # request is always rejected when the section structure doesn't match the template, and this
  # warning, present in both the human-readable line and doctor, used to be missing from `--json`
  # alone. A run where it was never checked (not present in an acceptable shape, so sections were
  # never read) reports neither true nor false but null -- **not having measured it** is never
  # mixed with a measured result (why it wasn't measured is already in the same object's own
  # `present`, so the reason isn't duplicated).
  jq -nc \
    --arg cwd "$TARGET_CWD" \
    --arg records "$RECORDS_DIR" \
    --arg handoff_path "$STATUS_HANDOFF_PATH" \
    --arg handoff_origin "$STATUS_HANDOFF_ORIGIN" \
    --argjson handoff_present "$STATUS_HANDOFF_PRESENT" \
    --argjson handoff_sections_ok "$STATUS_HANDOFF_SECTIONS_OK" \
    --arg handoff_sections_reason "$STATUS_HANDOFF_SECTIONS_DETAIL" \
    --arg runtime "$RUNTIME_DIR" \
    --arg generation "$generation" \
    --arg session_id "$MAIN_SESSION_ID" \
    --arg session_name "$MAIN_SESSION_NAME" \
    --arg main_state "$main_state" \
    --arg seat_pid "$seat_pid" \
    --arg seat_attached_id "$seat_attached_id" \
    --arg seat_connection "$seat_connection" \
    --arg heartbeat_age "$heartbeat_age" \
    --argjson pointer "$pointer" \
    --argjson marker "$marker" \
    --argjson snooze "$snooze" \
    --argjson event "$event" \
    --argjson seat_event "$seat_event" \
    --argjson generations "$generations" \
    --argjson watcher "$watcher_json" \
    --argjson stop_request "$stop_request" \
    --argjson seat_stop "$seat_stop" \
    --argjson prune_candidates "$prune_json" \
    --arg op_lock_state "$op_lock_state" \
    --arg op_lock_pid "$op_lock_pid" \
    --arg stranded_state "$STATUS_STRANDED_STATE" \
    --arg stranded_id "$STATUS_STRANDED_ID" \
    --argjson unreadable "$STATUS_UNREADABLE_JSON" \
    '{
      schema: "rein.status.v1",
      cwd: $cwd,
      records_dir: $records,
      runtime_dir: $runtime,
      handoff: {path: (if $handoff_path == "" then null else $handoff_path end),
                origin: $handoff_origin,
                present: ($handoff_present == 1),
                sections_ok: (if $handoff_present == 1 then ($handoff_sections_ok == 1) else null end),
                sections_reason: (if $handoff_sections_reason == "" then null else $handoff_sections_reason end)},
      generation: (if $generation == "" then null else ($generation | tonumber) end),
      main_session: {
        session_id: (if $session_id == "" then null else $session_id end),
        session_name: (if $session_name == "" then null else $session_name end),
        state: $main_state
      },
      watcher: ($watcher + {heartbeat_age_sec: (if $heartbeat_age == "" then null else ($heartbeat_age | tonumber) end)}),
      seat: {state: (if $seat_pid == "" then "none" else "attached" end),
             pid: (if $seat_pid == "" then null else ($seat_pid | tonumber) end),
             connection: (if $seat_connection == "" then null else $seat_connection end),
             attached_session_id: (if $seat_attached_id == "" then null else $seat_attached_id end),
             pointer_match: (if $seat_connection != "attached" or $session_id == ""
                             then null else ($seat_attached_id == $session_id) end)},
      incomplete_handover: {state: $stranded_state,
                            predecessor_session_id: (if $stranded_id == "" then null else $stranded_id end)},
      pointer: $pointer,
      marker: $marker,
      stop_request: $stop_request,
      seat_stop: $seat_stop,
      op_lock: {state: $op_lock_state,
                pid: (if $op_lock_pid == "" then null else ($op_lock_pid | tonumber) end)},
      snooze: $snooze,
      prune_candidates: $prune_candidates,
      last_event: $event,
      seat_last_event: $seat_event,
      generations: $generations,
      unreadable_files: $unreadable
    }'
}

# All lineages. There's no cross-lineage registry (the owner file's own self-declaration is the
# only source of ownership), so this walks the runtime-data locations and reads each owner file.
status_all_rows() {
  local dir owner cwd exists gen pointer
  [ -d "$STATE_ROOT" ] || return 0
  # `*/` doesn't match names starting with a dot (a lineage targeting something like `~/.claude`
  # has a key that starts with a dot too). Reads NUL-delimited so boundaries hold even for
  # leftover debris whose name contains a newline.
  while IFS= read -r -d '' dir; do
    [ -d "$dir" ] || continue
    runtime_dir_is_rein "$dir" || continue
    cwd=""
    exists="unknown"
    owner="$dir/$REIN_OWNER_BASENAME"
    if [ -f "$owner" ] && [ ! -L "$owner" ]; then
      cwd="$(head -1 "$owner" 2>/dev/null)"
    fi
    if [ -n "$cwd" ]; then
      if [ -d "$cwd" ]; then
        exists="present"
      else
        exists="none"
      fi
    fi
    gen="-"
    # The records location differs per lineage (default = the owner's own .rein/; a `--root`
    # lineage = keyed, on the root side).
    pointer="$(rein_records_dir_for_runtime "$dir" "$cwd")/$REIN_POINTER_BASENAME"
    if [ -n "$cwd" ] && [ -f "$pointer" ]; then
      gen="$(rein_pointer_field "$pointer" "generation")"
      [ -n "$gen" ] || gen="-"
    fi
    # The identity check's counterpart is that lineage's own owner -- checking against this
    # lineage's own cwd would read another lineage's watcher as "a different thing".
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$dir" "${cwd:-(owner unknown)}" "$exists" "$(watcher_state_label "$dir" "$cwd")" "$gen"
  done < <(find "$STATE_ROOT" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
  return 0
}

status_all_json() {
  local dir owner cwd gen pointer rows="" row
  [ -d "$STATE_ROOT" ] || {
    jq -nc '{schema: "rein.status-all.v1", systems: []}'
    return 0
  }
  while IFS= read -r -d '' dir; do
    [ -d "$dir" ] || continue
    runtime_dir_is_rein "$dir" || continue
    cwd=""
    owner="$dir/$REIN_OWNER_BASENAME"
    if [ -f "$owner" ] && [ ! -L "$owner" ]; then
      cwd="$(head -1 "$owner" 2>/dev/null)"
    fi
    gen=""
    # The records location is resolved through the same one path as the human-readable table
    # (status_all_rows) -- assembling `<cwd>/.rein/` directly here would make the JSON output
    # alone drop the generation for a lineage rooted elsewhere.
    pointer="$(rein_records_dir_for_runtime "$dir" "$cwd")/$REIN_POINTER_BASENAME"
    if [ -n "$cwd" ] && [ -f "$pointer" ]; then
      gen="$(rein_pointer_field "$pointer" "generation")"
    fi
    watcher_state "$dir" "$cwd"
    row="$(jq -nc \
      --arg runtime "$dir" \
      --arg cwd "$cwd" \
      --arg gen "$gen" \
      --arg pid "$WATCHER_PID" \
      --arg reason "$WATCHER_REASON" \
      --argjson exists "$(if [ -n "$cwd" ] && [ -d "$cwd" ]; then printf 'true'; else printf 'false'; fi)" \
      '{
        runtime_dir: $runtime,
        owner_cwd: (if $cwd == "" then null else $cwd end),
        owner_cwd_exists: $exists,
        generation: (if $gen == "" then null else ($gen | tonumber) end),
        watcher: {pid: (if $pid == "" then null else ($pid | tonumber) end),
                  reason: (if $reason == "" then null else $reason end)}
      }')"
    rows="${rows}${rows:+,}${row}"
  done < <(find "$STATE_ROOT" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
  printf '{"schema":"rein.status-all.v1","systems":[%s]}\n' "$rows"
  return 0
}

cmd_status() {
  local as_json=0 all=0 rc
  while [ $# -gt 0 ]; do
    case "$1" in
      --json | -j)
        as_json=1
        shift
        ;;
      --all | -a)
        all=1
        shift
        ;;
      *)
        take_verb_opt "$@"
        rc=$?
        case "$rc" in
          0) shift "$VERB_SHIFT" ;;
          2) return 2 ;;
          *)
            fail_usage "unknown argument to status: $1"
            return 2
            ;;
        esac
        ;;
    esac
  done
  prepare_runtime || return 1
  require_prerequisites || return 1
  # The name used in guidance stays **the same throughout this one output** (the same discipline as doctor).
  cli_rein_cmd
  if [ "$all" -eq 1 ]; then
    if [ "$as_json" -eq 1 ]; then
      status_all_json
      return $?
    fi
    printf 'runtime\towner\towner exists\twatcher\tgeneration\n'
    status_all_rows
    return $?
  fi
  # A single lineage's status is only reported after confirming the location actually belongs to the target.
  if [ -d "$RUNTIME_DIR" ]; then
    verify_runtime_owner_or_fail || return 1
  fi
  if [ "$as_json" -eq 1 ]; then
    status_json
    return $?
  fi
  status_human
}
