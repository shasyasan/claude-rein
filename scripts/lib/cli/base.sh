# shellcheck shell=bash
# shellcheck disable=SC2034  # the location and judgment results are used by readers (each verb's own file) -- they look unused within this file alone
# The directive above applies to **the whole file** -- so this file also loses detection of unused
# locals inside functions. The globals are initialized in one block stacked at the top, so a
# per-line directive can't be scoped tightly enough.
# The shared foundation the verbs use in common (resolving the location, judging liveness, the operation lock).
# `bin/rein` sources this at startup.
# Not an executable script, so it doesn't get the execute bit (out of scope for the --selftest convention).

# The location and its effective values (prepare_runtime settles these). This only resolves the
# location -- it does not create the directory, so that a read-only verb never creates one.
RUNTIME_DIR_OPT=""
RUNTIME_DIR=""
STATE_ROOT=""
RECORDS_DIR=""
# Why the records location could not be resolved, carried out of prepare_runtime instead of being
# turned into an exit right there (doctor is the verb that reports this state, so it has to be able
# to run with it set -- see prepare_runtime's `--records-optional`).
RECORDS_ERROR=""
POINTER_FILE=""
LOG_FILE=""
SEAT_LOG_FILE=""
MARKER_FILE=""
HEARTBEAT_FILE=""
OP_LOCK_DIR=""
OP_LOCK_HELD=0
# A disposable marker naming this generation (used at release time to check whether what's
# published under the public name still belongs to it).
OP_LOCK_TOKEN=""
SNOOZE_FILE=""
STOP_REQUEST_FILE=""
SEAT_STOP_FILE=""
POLL_INTERVAL_SEC=""
STOP_TIMEOUT_SEC=""
HEARTBEAT_MAX_AGE_SEC=""
SNOOZE_MAX_SEC=""
ARCHIVE_DAYS=""
RUNTIME_DIR_EXPLICIT=0

# Variables that carry judgment results back out (calling with $( ) confines the result to a
# subshell, so results are returned to the caller through variables instead).
WATCHER_PID=""
WATCHER_REASON=""
WATCHER_OVERALL=""
WATCHER_PROCESS_STATE=""
WATCHER_HEARTBEAT_AGE=""
MAIN_SESSION_ID=""
MAIN_SESSION_NAME=""
MAIN_SESSION_REASON=""
MAIN_SESSION_GENERATION=""
SEAT_PID=""
VERB_SHIFT=0

# Options every verb accepts in common. The wording for value problems (missing / explicitly
# empty) belongs to the config layer.
# 0=accepted (consumed VERB_SHIFT args) / 1=unknown option / 2=invalid value
take_verb_opt() {
  VERB_SHIFT=0
  case "$1" in
    --runtime-dir | -D)
      if ! rein_config_check_opt "--runtime-dir" runtime_dir $# "${2:-}"; then
        fail "$REIN_CONFIG_ERROR"
        return 2
      fi
      RUNTIME_DIR_OPT="$2"
      VERB_SHIFT=2
      return 0
      ;;
  esac
  return 1
}

# Prerequisites are checked by "does it work", not "is it there" -- a GNU `date` / `stat` can
# share the same name while lacking -j / -f. Proceeding without them makes pointer
# and enumeration reads fail for the wrong reason.
require_prerequisites() {
  rein_check_prerequisites "$REIN_BIN_PATH" && return 0
  fail "prerequisite tools don't work: ${REIN_MISSING_TOOLS}"
  return 1
}

cli_cleanup() {
  release_op_lock
  rein_close_error_sink
}

# Reads config fully, then settles the location. **This does not create it** -- so that a
# read-only verb never produces the directory -- creation is left to the writing verbs, via
# ensure_runtime_or_fail.
# `--records-optional` keeps going when the records location cannot be resolved, leaving the
# reason in RECORDS_ERROR instead of failing. **The one caller is `doctor`** -- the verb whose
# whole job is to report a broken installation, so failing it here would take away the tool that
# names the breakage (the rest of doctor does not depend on the records location, and every line
# that would use it already guards on empty). Every other verb takes the default and stops.
prepare_runtime() {
  local runtime_opt="" records_optional=0
  case "${1:-}" in
    --records-optional) records_optional=1 ;;
  esac
  prepare_delegation || return 1
  if [ -n "$RUNTIME_DIR_OPT" ] && ! rein_config_override runtime_dir "$RUNTIME_DIR_OPT"; then
    fail "$REIN_CONFIG_ERROR"
    return 1
  fi
  if ! rein_config_bind runtime_opt runtime_dir ||
    ! rein_config_bind CMD_TIMEOUT_SEC cmd_timeout_sec ||
    ! rein_config_bind POLL_INTERVAL_SEC poll_interval_sec ||
    ! rein_config_bind HEARTBEAT_MAX_AGE_SEC seat_heartbeat_max_age_sec ||
    ! rein_config_bind STOP_TIMEOUT_SEC stop_timeout_sec ||
    ! rein_config_bind ARCHIVE_DAYS archive_days ||
    ! rein_config_bind SNOOZE_MAX_SEC snooze_max_sec; then
    fail "$REIN_CONFIG_ERROR"
    return 1
  fi
  # Whether this lineage set its location explicitly (cross-lineage cleanup doesn't apply to a lineage that did).
  RUNTIME_DIR_EXPLICIT=0
  rein_config_is_set runtime_dir && RUNTIME_DIR_EXPLICIT=1
  RUNTIME_DIR="$(rein_resolve_runtime_dir "$TARGET_CWD" "$runtime_opt")"
  if [ -z "$RUNTIME_DIR" ]; then
    # Resolving it needs the lineage key (a shasum), so ending on this reason when a tool is
    # missing would point at a cause unrelated to what actually happened -- check prerequisites
    # first so the reason is the right one.
    require_prerequisites || return 1
    fail "cannot resolve the location of the runtime data (pass --runtime-dir to set it explicitly)"
    return 1
  fi
  STATE_ROOT="$(dirname "$RUNTIME_DIR")"
  # Resolution is called **outside `$( )`** so the rejection reason (REIN_RECORDS_ERROR) is not
  # sealed inside a subshell -- the value itself arrives through REIN_RECORDS_PATH (the same form
  # rein-request.sh's watcher_start_hint uses). Received through `$( )`, a rejection is
  # indistinguishable from success with an empty result, and every path built below would collapse
  # to the filesystem root (`/current.json`), which read back as "no primary session" and exited 0.
  # The resolver's own stderr line is suppressed here because the reason is re-emitted through
  # `fail`, in this script's one-line form.
  RECORDS_DIR=""
  RECORDS_ERROR=""
  if rein_records_dir "$TARGET_CWD" >/dev/null 2>&1; then
    RECORDS_DIR="$REIN_RECORDS_PATH"
  else
    RECORDS_ERROR="${REIN_RECORDS_ERROR:-cannot resolve the lineage records location}"
  fi
  # The gate that applies only to isolation-test children (it kills the process the instant
  # isolation drops).
  # This is **the same predicate, at the same conceptual position**, as the one in
  # rein-hook.sh's hook_prepare. "Stop before writing" can only hold at this point -- once the
  # location (runtime directory, records) is fully resolved but not a single byte has been
  # written yet. The CLI's writing verbs (up / init / prune) all pass through here, so this one
  # spot covers both creating the runtime directory and the owner's writes.
  # **Not placed inside the shared resolver** -- the hook's managed-marker path bypasses the
  # resolver and uses the env value directly, so a check placed there would not cover that branch.
  # The only signal that triggers it is whether the root env var is non-empty (empty in
  # production, so it exits after a single string check). The failure exit is `fail` (a
  # single line to stderr) -- the failing side never writes a single byte to a never-touch root.
  if [ -n "${REIN_SELFTEST_NEVER_ROOTS:-}" ] &&
    rein_selftest_never_root_hit "$RUNTIME_DIR" "$RECORDS_DIR"; then
    fail "resolved a location the selftest child must never touch (isolation has dropped): ${REIN_SELFTEST_NEVER_ROOT_HIT}"
    return 1
  fi
  # Placed **after** the isolation gate so that gate still runs on the runtime directory for a
  # lineage whose records cannot be resolved (nothing is written on either exit, so the ordering
  # only decides which reason gets reported, and isolation is the one that must win).
  if [ -n "$RECORDS_ERROR" ] && [ "$records_optional" -eq 0 ]; then
    fail "$RECORDS_ERROR"
    return 1
  fi
  # Only derived when the location actually resolved. Deriving them from an empty value is what
  # produced paths at the filesystem root -- keeping them empty means even a verb that forgot the
  # gate above reads "nothing there" instead of reading and writing `/`.
  if [ -n "$RECORDS_DIR" ]; then
    POINTER_FILE="$RECORDS_DIR/$REIN_POINTER_BASENAME"
    LOG_FILE="$RECORDS_DIR/$REIN_LOG_BASENAME"
    SEAT_LOG_FILE="$RECORDS_DIR/$REIN_SEAT_LOG_BASENAME"
  fi
  MARKER_FILE="$RUNTIME_DIR/$REIN_MARKER_BASENAME"
  HEARTBEAT_FILE="$RUNTIME_DIR/$REIN_HEARTBEAT_BASENAME"
  OP_LOCK_DIR="$RUNTIME_DIR/$REIN_OP_LOCK_DIRNAME"
  SNOOZE_FILE="$RUNTIME_DIR/$REIN_SNOOZE_BASENAME"
  STOP_REQUEST_FILE="$RUNTIME_DIR/$REIN_STOP_REQUEST_BASENAME"
  SEAT_STOP_FILE="$RUNTIME_DIR/$REIN_SEAT_STOP_BASENAME"
  if ! rein_open_error_sink; then
    fail "cannot create the temp file to capture external command output"
    return 1
  fi
  trap cli_cleanup EXIT
  return 0
}

# Verifies ownership of the runtime directory. A read-only verb verifies (it adds no writes);
# a writing verb ensures (creates it if missing and records itself as owner).
verify_runtime_owner_or_fail() {
  rein_verify_runtime_owner "$RUNTIME_DIR" "$TARGET_CWD" && return 0
  fail "$REIN_RUNTIME_ERROR"
  return 1
}

ensure_runtime_or_fail() {
  rein_ensure_runtime_dir "$RUNTIME_DIR" "$TARGET_CWD" && return 0
  fail "$REIN_RUNTIME_ERROR"
  return 1
}

# The operation lock. up / down each check whether the watcher is running before starting or
# stopping it, so without serializing them, two concurrent `up` calls can both read it as absent
# and start the watcher twice. `mkdir` is atomic even on 3.2, so only one winner proceeds. A lock
# whose owner can't be confirmed is never seized.
acquire_op_lock() {
  local owner rc alive_rc
  OP_LOCK_TOKEN="$(rein_nonce)"
  claim_op_lock
  rc=$?
  if [ "$rc" -eq 0 ]; then
    OP_LOCK_HELD=1
    return 0
  fi
  if [ "$rc" -eq 1 ]; then
    fail "cannot set up the operation lock: ${OP_LOCK_DIR}"
    return 1
  fi
  owner="$(rein_lock_pid "$OP_LOCK_DIR")"
  case "$owner" in
    '' | *[!0-9]*)
      fail "cannot read the operation lock's owner (a lock whose owner can't be confirmed is never seized). Confirm no other rein is running here, then remove it with rmdir $(rein_shell_quote "$OP_LOCK_DIR")"
      return 1
      ;;
  esac
  rein_pid_alive "$owner"
  alive_rc=$?
  if [ "$alive_rc" -eq 2 ]; then
    # A liveness state that can't be confirmed is not the same as "gone" -- treating it as gone
    # would strip the operation lock out from under a live rein, letting two operations run on
    # the same lineage at once.
    fail "ps is not answering, so liveness of the operation lock's owner (pid=${owner}) cannot be confirmed (a lock that cannot be confirmed is never seized): ${OP_LOCK_DIR}"
    return 1
  fi
  # PID liveness alone doesn't decide ownership (PIDs get reused) -- it also checks the declared
  # start time. Deciding by PID liveness alone would let a reused PID be mistaken for the owner
  # and permanently block that lineage's up / down. This check goes through the same one
  # function as the reclaim (rein_claim_lock_dir_or_reclaim).
  if rein_lock_owner_alive "$OP_LOCK_DIR"; then
    fail "another rein operation is in progress (pid=${owner}): ${OP_LOCK_DIR}"
    return 1
  fi
  # The reclaim goes through the shared library and removes **only the lock for the exact pid
  # this process itself judged stale**. In the gap between checking and removing, another rein
  # can already have reclaimed the same stale lock and taken it over; a plain release in that
  # window would strip a lock that was just reclaimed and is alive again (letting two
  # executions hold the lock at once). The release itself is also **atomic** -- doing it in two
  # steps (delete `pid`, then `rmdir`) can leave a published lock with no pid behind if the
  # `rmdir` fails, and from then on every read falls into "cannot read the owner" above, which
  # permanently blocks that lineage's up / down / prune -o short of manual intervention.
  claim_op_lock reclaim
  rc=$?
  if [ "$rc" -eq 0 ]; then
    OP_LOCK_HELD=1
    return 0
  fi
  fail "cannot reclaim the operation lock (saw a lock owned by pid=${owner}): ${OP_LOCK_DIR}"
  return 1
}

# The operation lock's claim. The declaration (start time, cwd, role, token) is attached
# **before publishing** -- attaching it after publishing would let a reader observe the lock in
# the instant between being published and having its declaration filled in, and treat it as a
# lock whose owner can't be confirmed.
# 0=acquired / 1=cannot set up / 2=already owned
claim_op_lock() {
  local claim=rein_claim_lock_dir
  [ "${1:-}" = "reclaim" ] && claim=rein_claim_lock_dir_or_reclaim
  "$claim" "$OP_LOCK_DIR" \
    start "$(rein_process_start_identity "$$")" \
    cwd "$TARGET_CWD" \
    mode "$REIN_LOCK_MODE_OP" \
    token "$OP_LOCK_TOKEN"
}

# Renders the operation lock's current state as one human-readable line (both `doctor` and
# `status` emit it).
op_lock_state_line() {
  local owner
  if [ ! -d "$OP_LOCK_DIR" ]; then
    printf 'none\n'
    return 0
  fi
  owner="$(rein_lock_pid "$OP_LOCK_DIR")"
  case "$owner" in
    '' | *[!0-9]*)
      printf 'a lock with an unreadable owner remains (confirm no other rein is running here, then rmdir %s)\n' \
        "$(rein_shell_quote "$OP_LOCK_DIR")"
      return 1
      ;;
  esac
  rein_pid_alive "$owner"
  case $? in
    0)
      printf 'another operation is in progress (pid=%s)\n' "$owner"
      return 0
      ;;
    2)
      printf 'ps is not answering, so liveness of owner pid=%s cannot be confirmed (not reclaiming)\n' "$owner"
      return 1
      ;;
  esac
  printf 'owner pid=%s is gone (the next up / down will reclaim it)\n' "$owner"
  return 0
}

# The EXIT trap can't see function locals, so the state release needs is kept global.
# The release is also atomic (shared library) -- it never leaves a published lock with no pid
# behind mid-release.
release_op_lock() {
  local rc
  [ "$OP_LOCK_HELD" -eq 1 ] || return 0
  # Removes **only this generation's own lock** (token match). Without the match, exiting here
  # could delete a live lock another rein had already reclaimed -- letting two operations run at
  # once.
  rein_release_lock_dir_if_mine "$OP_LOCK_DIR" "$OP_LOCK_TOKEN"
  rc=$?
  OP_LOCK_HELD=0
  if [ "$rc" -eq 2 ]; then
    warn "did not remove the operation lock -- it had already been replaced by another rein's: ${OP_LOCK_DIR}"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    warn "cannot remove the operation lock (confirm no other rein is running here, then rmdir $(rein_shell_quote "$OP_LOCK_DIR"))"
    return 1
  fi
  return 0
}

# The judgment of whether the watcher is running lives in exactly one place in the shared
# library (the CLI verbs, the handover-request writer, and the hooks all go through the same
# three conditions). This is a thin receiver that moves the result into the variable names the
# verbs read, and fills in the second argument's default (the target cwd) from this side's
# context.
# 0=running (pid is WATCHER_PID) / 1=not running / 2=undetermined (reason is WATCHER_REASON)
watcher_state() {
  local rc
  rein_watcher_state "$1" "${2-$TARGET_CWD}"
  rc=$?
  WATCHER_PID="$REIN_WATCHER_PID"
  WATCHER_REASON="$REIN_WATCHER_REASON"
  return "$rc"
}

watcher_state_label() {
  local rc
  watcher_state "$@"
  rc=$?
  case "$rc" in
    0) printf 'running (pid=%s)\n' "$WATCHER_PID" ;;
    1) printf 'not running (%s)\n' "$WATCHER_REASON" ;;
    *) printf 'undetermined (%s)\n' "$WATCHER_REASON" ;;
  esac
  return "$rc"
}

# Whether the seat is present (the user's own terminal, attached). The material used is **the
# attach lock the seat itself claims first** (created atomically, declaring its own pid and
# start time). Back when this was judged by cross-checking the running-process list, it couldn't close
# the window where the other side vanishes between checking and starting, or where two starts
# race each other. (`ps` is still used, but only to confirm the declared pid is still there --
# it's diagnostic material now.)
find_seat_pid() {
  local lock="$RUNTIME_DIR/$REIN_SEAT_LOCK_DIRNAME"
  SEAT_PID=""
  [ -d "$lock" ] || return 1
  rein_lock_owner_alive "$lock" || return 1
  SEAT_PID="$(rein_lock_pid "$lock")"
  [ -n "$SEAT_PID" ]
}

# Liveness of the primary session the current pointer points at.
# The enumeration can be passed in as an argument (**if given, this never fetches its own**) --
# this exists so a single check doesn't hit the external command twice; the caller may pass an
# enumeration that includes finished sessions too (`--all`) since liveness judged against a
# superset gives the same answer. An empty string means "could not be read" -- undetermined.
#
# The pointer is only read **after passing contract validation (one of the shared library's
# checks)**. Reading it raw would take a `.rein/current.json` copied along with a working tree via
# `cp -r` (whose `cwd` still names the original path) and treat it as this lineage's own
# pointer, making `down` **externally stop a live session belonging to the original lineage**.
# prune and hooks already go through this same validation; only the CLI was missing it (splitting
# the check per reader lets exactly one reader silently pass a broken pointer through).
# 0=alive / 1=absent (the first generation needs starting) / 2=undetermined (reason is MAIN_SESSION_REASON)
main_session_state() {
  local sid rc agents="" have_agents=0
  if [ "$#" -ge 1 ]; then
    have_agents=1
    agents="$1"
  fi
  MAIN_SESSION_ID=""
  MAIN_SESSION_NAME=""
  MAIN_SESSION_REASON=""
  MAIN_SESSION_GENERATION=""
  rein_validate_pointer "$POINTER_FILE" "$TARGET_CWD"
  rc=$?
  if [ "$rc" -eq 1 ]; then
    MAIN_SESSION_REASON="no current pointer"
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    MAIN_SESSION_REASON="${REIN_POINTER_ERROR}: ${POINTER_FILE}"
    return 2
  fi
  sid="$REIN_POINTER_SESSION_ID"
  MAIN_SESSION_ID="$sid"
  MAIN_SESSION_GENERATION="$REIN_POINTER_GENERATION"
  MAIN_SESSION_NAME="$(rein_pointer_field "$POINTER_FILE" "session_name")"
  if [ "$have_agents" -eq 1 ]; then
    if [ -z "$agents" ]; then
      rc=2
    else
      # Passes the answer (0=alive / 1=exited / 2=undetermined) straight through. Collapsing it
      # to a boolean with `if` would make even a non-array enumeration read as "the session the
      # pointer targets has exited".
      rein_agents_has_live "$agents" "$sid"
      rc=$?
    fi
  else
    rein_is_session_live "$sid"
    rc=$?
  fi
  case "$rc" in
    0) return 0 ;;
    1)
      MAIN_SESSION_REASON="the session the pointer targets has exited"
      return 1
      ;;
    *)
      MAIN_SESSION_REASON="$(rein_list_agents_error)"
      return 2
      ;;
  esac
}

# Remaining seconds on a snooze marker (postponed handover). If still within the window, prints
# the remainder and returns 0.
# Increment 3's hooks (the Stop wiring) read this same file in this same format, so selftest
# pins the literal shape too.
snooze_remaining_sec() {
  local until epoch now
  [ -f "$SNOOZE_FILE" ] || return 1
  until="$(jq -r --arg s "$REIN_SNOOZE_SCHEMA" \
    'select(.schema == $s) | .until // empty' "$SNOOZE_FILE" 2>/dev/null)"
  [ -n "$until" ] || return 1
  epoch="$(rein_iso_to_epoch "$until")" || return 1
  now="$(rein_now_epoch)"
  [ "$epoch" -gt "$now" ] || return 1
  printf '%s\n' "$((epoch - now))"
}

# Builds the generation list from the handover log (JSON Lines). A generation is realized by
# the line where the pointer switched over, so rejected or failed lines aren't counted
# (a handover that didn't go through gets no generation number).
log_generations_json() {
  if [ ! -f "$LOG_FILE" ]; then
    printf '[]\n'
    return 0
  fi
  jq -s -c '[ .[] | select(.event == "pointer_updated")
              | {generation: .generation, session_id: .successor_session_id, ts: .ts} ]' \
    "$LOG_FILE" 2>/dev/null
}

log_last_event_json() {
  [ -f "$LOG_FILE" ] || return 1
  tail -1 "$LOG_FILE" 2>/dev/null | jq -c . 2>/dev/null
}

# The last line of the seat's own log (written only by the attach loop). Kept as a separate
# observation point from the handover log, so it's shown as its own line in status -- the
# handover log alone can't tell you that the watcher is running while the seat isn't holding
# its place.
seat_log_last_event_json() {
  [ -f "$SEAT_LOG_FILE" ] || return 1
  tail -1 "$SEAT_LOG_FILE" 2>/dev/null | jq -c . 2>/dev/null
}

# **What the seat is connected to**, as opposed to whether anyone is sitting there. The seat lock
# declares only who is seated (pid, start time, cwd) and carries nothing about the target, so
# presence on its own -- all the seat line used to report -- reads exactly the same whether the
# seat is following the pointer or has been stuck on a session the pointer left behind hours ago
# (observed: over 4 hours of that state reported as a plain "attached").
# The target is taken from the seat's own log, which already records it: the attach loop writes
# REIN_SEAT_EVENT_ATTACH_STARTED, carrying the session id, in the moment before it enters attach,
# so the last such line names the session the seat took its terminal into.
# **Only meaningful next to find_seat_pid.** The log outlives the process that wrote it, so read
# on its own it would name a target for a seat that has already stepped down.
#
# **Reading only `attach_started` cannot answer "is it connected now."** That event says where the
# seat last went, and the gap between that and "is connected" is not a moment: it opens every time
# attach returns and stays open until the next attach begins -- across the successor being
# resolved, and for the entire unbounded stretch a lineage spends waiting for a handover nobody
# has requested yet. Read that way, the ordinary between-attaches state reports as a live
# connection in step with the pointer, which is the very shape of the accident this observation
# point exists to catch. So the scan takes **the last of the three life-cycle events** and reads
# it as a state:
#   attach_started -> connected, to that session
#   attach_ended   -> not connected right now (it names the session just left)
#   seated         -> this seat has sat down but has never entered attach
# 0 always (the answer is a state, never a failure): SEAT_CONNECTION_STATE is one of
# attached / between / none / unreadable, with SEAT_ATTACHED_ID set for the first two and
# SEAT_CONNECTION_DETAIL carrying the reason for the last two.
SEAT_CONNECTION_STATE=""
SEAT_CONNECTION_DETAIL=""
seat_connection_state() {
  local scanned last event
  SEAT_CONNECTION_STATE="none"
  SEAT_ATTACHED_ID=""
  SEAT_CONNECTION_DETAIL="the seat has not entered attach yet"
  if [ ! -f "$SEAT_LOG_FILE" ]; then
    SEAT_CONNECTION_DETAIL="the seat has not entered attach yet (there is no seat log)"
    return 0
  fi
  # **"Could not read it" is kept apart from "nothing is recorded."** jq stops at the first line
  # that isn't contract-shaped, having already emitted everything before it, so discarding its
  # exit code would silently hand back a stale target from before the damage and present it as
  # the current one. The pipe to `tail` is not part of the capture for the same reason (a
  # pipeline reports only its last stage).
  scanned="$(jq -r --arg schema "$REIN_SEAT_LOG_SCHEMA" \
    --arg started "$REIN_SEAT_EVENT_ATTACH_STARTED" \
    --arg ended "$REIN_SEAT_EVENT_ATTACH_ENDED" \
    --arg seated "$REIN_SEAT_EVENT_SEATED" \
    'select(.schema == $schema
            and (.event == $started or .event == $ended or .event == $seated))
     | "\(.event) \(.successor_session_id // "")"' "$SEAT_LOG_FILE" 2>/dev/null)" || {
    SEAT_CONNECTION_STATE="unreadable"
    SEAT_CONNECTION_DETAIL="the seat log holds a line that is not a record in contract form"
    return 0
  }
  last="${scanned##*$'\n'}"
  [ -n "$last" ] || return 0
  event="${last%% *}"
  case "$event" in
    "$REIN_SEAT_EVENT_ATTACH_STARTED") SEAT_CONNECTION_STATE="attached" ;;
    "$REIN_SEAT_EVENT_ATTACH_ENDED") SEAT_CONNECTION_STATE="between" ;;
    *) return 0 ;;
  esac
  SEAT_ATTACHED_ID="${last#* }"
  # A life-cycle line with no session column is a record that violates the contract, not a seat
  # connected to nothing -- reporting it as either "attached" or "not connected" would be an
  # invented answer.
  if [ -z "$SEAT_ATTACHED_ID" ]; then
    SEAT_CONNECTION_STATE="unreadable"
    SEAT_CONNECTION_DETAIL="the last ${event} record names no session"
  fi
  return 0
}


# Whether a directory looks like a rein runtime directory (holds at least one rein-specific
# runtime file). This is the coarse filter applied before verifying ownership, so an unrelated
# directory never becomes a cleanup target.
# Checks only these three: `owner`, `watcher.heartbeat`, `watcher.lock/`:
# - Generic names (processing / processed / rejected) show up in plenty of non-rein directories too.
# - `current.json` / `handover.log` belong to **the lineage's records** (kept under `<cwd>/.rein/`),
#   not the runtime data -- counting these toward "looks like runtime data" would make the
#   handover log of a lineage that never relocated become a cleanup target.
runtime_dir_is_rein() {
  local dir="$1" name
  for name in "$REIN_OWNER_BASENAME" "$REIN_HEARTBEAT_BASENAME" "$REIN_LOCK_DIRNAME"; do
    if [ -e "$dir/$name" ]; then
      return 0
    fi
  done
  return 1
}

# The legacy watcher log (the old nohup redirect target). Now that the watcher writes its own
# .rein/watcher.log, this is leftover debris. **Deciding whether to delete it is left to the
# user** -- identification relies only on the cwd's basename, so an environment with two
# working trees of the same name could point at the wrong lineage's leftovers (an irreversible
# delete is never a default side effect of `up`). `doctor` only points at where it is.
legacy_watcher_log_path() {
  printf '%s/watcher-%s.log\n' "$STATE_ROOT" "$(basename "$TARGET_CWD")"
}

# Decides in one place **what to call rein** inside guidance text. On a machine where it hasn't
# been installed yet, `rein` isn't on PATH yet, so guiding the user to type a bare `rein ...` in
# that state would give a "command not found" the moment it is pasted and run (the same single
# message was saying "rein hasn't been installed yet" while also telling the user to type `rein`).
# The one signal used is the same one the install check uses -- **is the `rein` on PATH this same
# binary** -- if so, guidance uses `rein`; if not, it uses the path to the actual binary.
# **Not left to doctor alone** -- status emits the same guidance, so the decision lives in the
# CLI's shared code (deciding it per-verb would mix "can type it" and "can't" on one machine in
# one state, depending only on which verb happened to run).
# Decided once and reused (`resolve_self` runs a readlink, so this isn't resolved fresh per line).
CLI_REIN_CMD=""
cli_rein_cmd() {
  local found resolved
  [ -z "$CLI_REIN_CMD" ] || return 0
  CLI_REIN_CMD="$REIN_BIN_PATH"
  found="$(command -v "$SCRIPT_NAME" 2>/dev/null)" || return 0
  [ -n "$found" ] || return 0
  resolved="$(resolve_self "$found")" || resolved=""
  [ "$resolved" = "$REIN_BIN_PATH" ] || return 0
  CLI_REIN_CMD="$SCRIPT_NAME"
  return 0
}

# The material for pointing at why only one side of the handover died. doctor and `status`
# both emit the same one sentence, so the single writer lives here (keeping it in two places
# would let one of them go stale after a move). **The verb modules are peer siblings** -- so
# anything used by both belongs to this shared foundation (`bin/rein` sourcing every verb is
# only so common-option parsing can run before the verb is known; it isn't meant to let verbs
# reference each other).
# The watcher instead splices in the raw text of its own handover log -- the material itself
# differs there, so it doesn't go through this.
cli_handover_failure_cause() {
  printf 'the reason it failed is left in the failed line in %s and in %s/%s' \
    "$LOG_FILE" "$RECORDS_DIR" "$REIN_WATCHER_LOG_BASENAME"
}
