# shellcheck shell=bash
# Implementation of `rein prune` (cleanup).
# Not an executable script, so it doesn't get the execute bit (out of scope for the --selftest convention).

# Cleanup candidates are held in 3 parallel arrays (bash 3.2 has no associative arrays).
# Packing them into one delimited string would let a runtime directory whose name contains
# a newline or tab inject rows -- spoofing the kind and target and deleting outside the
# intended location.
PRUNE_KINDS=()
PRUNE_TARGETS=()
PRUNE_NOTES=()
PRUNE_ERROR=""
# Kinds to scan (space-separated). Defaults to the kinds whose scan and delete both stay
# entirely within its own lineage (archives, and leftover children-ledger entries). The
# cross-lineage scan (orphans) and the delete that shells out to an external CLI (sessions)
# must be added explicitly.
PRUNE_WANTED=""
PRUNE_NOTICES=()
PRUNE_SCAN_ROOT=""
# Candidate counts (`status` reads these). A kind that can't be counted carries an empty
# string plus a reason instead.
PRUNE_COUNT_ARCHIVE=""
PRUNE_COUNT_ORPHAN=""
PRUNE_COUNT_SESSION=""
PRUNE_COUNT_SESSION_REASON=""
PRUNE_COUNT_ORPHAN_REASON=""
PRUNE_COUNT_CHILD=""
PRUNE_COUNT_CHILD_REASON=""
# A disposable marker naming the target lineage's operation lock (checked at release time to
# confirm it still belongs to this generation).
PRUNE_OP_LOCK_TOKEN=""

prune_add() {
  PRUNE_KINDS+=("$1")
  PRUNE_TARGETS+=("$2")
  PRUNE_NOTES+=("$3")
}

# Why something wasn't made a candidate (shown in both the preview and the run). Without a
# visible reason for something not being deleted, the user ends up deleting it by hand --
# undoing the state this mechanism meant to protect.
prune_notice() {
  PRUNE_NOTICES+=("$1")
}

# Sessions of a finished generation. Of the generations that show up in the handover log,
# ones that are no longer pointed to, **whose handover from that generation completed**, and
# that have exited and have a short job ID to look up are targets for `claude rm` (the CLI
# won't accept a full session ID).
# Enumeration can be received as an argument (**if given one, this doesn't fetch its own**).
# `status` looks at the same enumeration for both the primary session's liveness check and
# the candidate count, so this is the hook that keeps one status run from shelling out to the
# external CLI twice -- an empty string means "couldn't be read" (so a machine where it can't
# be read doesn't get hit a second time).
prune_scan_sessions() {
  local agents current current_gen sid gen jid rows rc have_agents=0
  if [ "$#" -ge 1 ]; then
    have_agents=1
    agents="$1"
  fi
  [ -f "$LOG_FILE" ] || return 0
  # The current pointer is the sole input naming "who must not be deleted," so this doesn't
  # proceed with one that can't be read or is corrupt (the same treatment as failing on an
  # unreadable handover log). A missing pointer -- cold start -- is still let through as
  # before (there's no current primary session to exclude yet).
  rein_validate_pointer "$POINTER_FILE" "$TARGET_CWD"
  rc=$?
  if [ "$rc" -eq 2 ]; then
    printf -v PRUNE_ERROR 'cannot validate the current pointer (%s): %s' "$REIN_POINTER_ERROR" "$POINTER_FILE"
    return 1
  fi
  current="$REIN_POINTER_SESSION_ID"
  current_gen="$REIN_POINTER_GENERATION"
  if [ "$have_agents" -eq 0 ]; then
    agents="$(rein_list_agents_all)"
  fi
  # Requires not just "JSON that parses" but **usable as an enumeration** (an array).
  # `{"error":...}` passes `jq -e .`, and would make the liveness check below treat every row
  # alike as "exited" -- putting a live session up as a candidate for `claude rm`. Never build
  # candidates from an enumeration that can't be read.
  if [ -z "$agents" ] || ! printf '%s' "$agents" | jq -e 'type == "array"' >/dev/null 2>&1; then
    PRUNE_ERROR="$(rein_list_agents_error)"
    return 1
  fi
  # Don't treat an unreadable handover log the same as "nothing to do" (that would silence
  # what's left uncleaned). A candidate is limited to one where "the handover from that
  # generation was confirmed complete via `handover_completed`" -- going only by the pointer
  # having advanced (`pointer_updated`) would also mark a generation complete whose handover
  # actually stalled partway. The generation ceiling is the validated pointer's generation
  # (anything at or past that is the current lineage).
  rows="$(jq -s -r --arg cur "$current" --arg curgen "$current_gen" '
    ([ .[] | select(.event == "handover_completed")
           | (.predecessor_session_id // empty) ]) as $done
    | [ .[] | select(.event == "pointer_updated")
            | {gen: .generation, sid: .successor_session_id} ]
    | map(select(.sid != null and .sid != $cur))
    | map(select(. as $row | $done | index($row.sid) != null))
    | (if $curgen == "" then . else map(select((.gen != null) and (.gen < ($curgen | tonumber)))) end)
    | unique_by(.sid)[]
    | "\(.sid)\t\(.gen)"' "$LOG_FILE" 2>/dev/null)" || {
    PRUNE_ERROR="cannot read the handover log: ${LOG_FILE}"
    return 1
  }
  if [ -z "$rows" ]; then
    return 0
  fi
  while IFS="$(printf '\t')" read -r sid gen; do
    [ -n "$sid" ] || continue
    if rein_agents_has_live "$agents" "$sid"; then
      continue
    fi
    jid="$(printf '%s' "$agents" | jq -r --arg sid "$sid" \
      '[ .[] | select(.sessionId == $sid) | (.id // empty) ] | (.[0] // empty)' 2>/dev/null)"
    # Missing from the enumeration means it's already gone (nothing left to delete).
    [ -n "$jid" ] || continue
    prune_add "session" "$jid" "session ${sid} of finished generation ${gen}"
  done <<EOF
$rows
EOF
  return 0
}

# The structural check that a scanned runtime directory is one rein created as a per-lineage
# directory. The scan root (STATE_ROOT) is derived from the runtime directory's
# parent, so the moment the location points somewhere that isn't per-lineage, unrelated
# directories enter the scan. Structurally closing this to the intended targets rests on two
# things: the name is key-shaped (`<basename>-<12 characters>`), and its parent is the scan
# root itself.
prune_dir_is_scannable() {
  local dir="$1" parent
  rein_runtime_key_shaped "${dir##*/}" || return 1
  parent="$(cd "${dir%/*}" 2>/dev/null && pwd -P)" || return 1
  [ "$parent" = "$PRUNE_SCAN_ROOT" ] || return 1
  return 0
}

# A runtime directory that still holds records (the current pointer, the handover log) --
# meaning the location hasn't been moved off of this lineage's own directory. That's where
# the canonical audit trail for handovers lives, so it's never a cleanup target (the watcher
# guards the same state by refusing to start there -- one mechanism doesn't both "guard" and
# "delete" the same state).
prune_dir_holds_records() {
  local dir="$1"
  [ -f "$dir/$REIN_POINTER_BASENAME" ] || [ -f "$dir/$REIN_LOG_BASENAME" ]
}

# Why the cross-lineage orphan scan doesn't apply to this lineage. The "excluded" line in the
# preview and the candidate line in the current-state report both use this one function (two
# different wordings for "not scanning" would drift when only one gets fixed).
prune_orphan_skip_reason() {
  printf 'this lineage names its runtime data location explicitly, so the cross-lineage orphan scan does not run (that scan only covers the XDG default location): %s\n' "$STATE_ROOT"
}

# Orphaned runtime directories: ones whose owner's work tree doesn't exist, and ones whose
# owner can't even be confirmed (owner file missing, empty, or a symlink).
# A running lineage is never a target (checked by whether the watcher lock's and seat lock's
# owners are alive -- read-only).
prune_scan_orphans() {
  local dir owner cwd reason
  # Cross-lineage cleanup only applies to a lineage that doesn't name its runtime data
  # location explicitly. For one that does, the scan root would be that location's parent
  # (not necessarily rein's state area), sweeping through unrelated directories -- so the
  # scan simply doesn't run at all.
  if [ "$RUNTIME_DIR_EXPLICIT" -eq 1 ]; then
    prune_notice "$(prune_orphan_skip_reason)"
    return 0
  fi
  [ -d "$STATE_ROOT" ] || return 0
  PRUNE_SCAN_ROOT="$(cd "$STATE_ROOT" 2>/dev/null && pwd -P)" || return 0
  # `*/` doesn't match names starting with a dot (a lineage targeting something like `~/.claude`
  # has a key that starts with a dot too). Reads NUL-delimited so boundaries hold even for
  # directory names containing a newline.
  while IFS= read -r -d '' dir; do
    [ -d "$dir" ] || continue
    [ "$dir" != "$RUNTIME_DIR" ] || continue
    prune_dir_is_scannable "$dir" || continue
    runtime_dir_is_rein "$dir" || continue
    if prune_dir_holds_records "$dir"; then
      prune_notice "not targeting it because lineage records still remain (${dir}). The handover log is the canonical audit trail -- move it into its owner's .rein/ instead"
      continue
    fi
    # Decide orphan status first, and check the locks after. Doing it the other way around
    # would print "not targeting it because it's locked" even for a lineage whose owner
    # actually exists (which was never going to be a candidate anyway).
    owner="$dir/$REIN_OWNER_BASENAME"
    if [ -L "$owner" ] || [ ! -f "$owner" ]; then
      reason="there is no owner file (which work tree this belongs to can't be traced)"
    else
      cwd="$(head -1 "$owner" 2>/dev/null)"
      if [ -z "$cwd" ]; then
        reason="the owner file is empty"
      elif [ ! -d "$cwd" ]; then
        reason="the owner's work tree doesn't exist: ${cwd}"
      else
        continue
      fi
    fi
    prune_locks_free "$dir" || continue
    prune_add "orphan" "$dir" "$reason"
  done < <(find "$STATE_ROOT" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
  return 0
}

# Looks at whether this lineage is OK to delete, from the locks' side. This module's rule
# (contract) is that a lock whose owner can't be confirmed is **never seized** -- so cleanup
# stays fail-closed too. Reading a lock as orphaned right after a watcher has `mkdir`-ed it,
# or a lock whose pid alone is corrupt, would mean deleting a lineage that's actually running.
# The same treatment applies when the owner is alive: both cases surface a reason in the
# preview (without a visible reason for something not being deleted, the user ends up
# deleting it by hand).
# 0=OK to target from this lock's side / 1=not a target
prune_lock_free() {
  local dir="$1" name="$2" label="$3" lock pid
  lock="$dir/$name"
  [ -e "$lock" ] || return 0
  pid="$(rein_lock_pid "$lock")"
  case "$pid" in
    '' | *[!0-9]*)
      prune_notice "not targeting it because there is a ${label} whose owner can't be confirmed (${lock})"
      return 1
      ;;
  esac
  rein_pid_alive "$pid"
  case $? in
    0)
      prune_notice "not targeting it because there is a ${label} whose owner (pid=${pid}) is alive (${lock})"
      return 1
      ;;
    2)
      # A liveness state that can't be confirmed is not the same as "not there" -- cleanup
      # stays fail-closed too.
      prune_notice "not targeting it because ps isn't answering, so the liveness of the ${label}'s owner (pid=${pid}) can't be confirmed (${lock})"
      return 1
      ;;
  esac
  return 0
}

# Looks at a running lineage from the locks' side. The watcher lock alone isn't enough --
# a lineage whose watcher is down can still have the user's own terminal attached, which the
# seat lock shows -- so the same check runs against both locks (splitting the logic would
# let one side drift from the "never seized" rule).
prune_locks_free() {
  local dir="$1"
  prune_lock_free "$dir" "$REIN_LOCK_DIRNAME" "watcher lock" || return 1
  prune_lock_free "$dir" "$REIN_SEAT_LOCK_DIRNAME" "seat lock" || return 1
  return 0
}

# Old entries in the archives (processed / rejected / cancelled). The age floor for becoming
# a candidate is config `archive_days` (default 30 days -- older than that is a candidate),
# and nothing is actually deleted except on a run with `-f`, so including this in the default
# scan doesn't mean anything gets deleted silently.
# **All 3 are scanned** -- leaving even one of the archive locations out would let it grow
# unbounded forever (with the only way to clear it becoming `prune_remove_runtime_dir`, which
# tears down the whole lineage).
prune_scan_archives() {
  local days="$1" dir file
  [ -n "$days" ] || return 0
  for dir in "$RUNTIME_DIR/$REIN_PROCESSED_DIRNAME" "$RUNTIME_DIR/$REIN_REJECTED_DIRNAME" \
    "$RUNTIME_DIR/$REIN_CANCELLED_DIRNAME"; do
    [ -d "$dir" ] || continue
    while IFS= read -r -d '' file; do
      [ -n "$file" ] || continue
      prune_add "archive" "$file" "older than ${days} days since archiving"
    done < <(find "$dir" -type f -mtime +"$days" -print0 2>/dev/null | LC_ALL=C sort -z)
  done
  return 0
}

# Why the children-ledger scan didn't run for this lineage. The "excluded" line in the preview
# and the candidate line in the current-state report both go through this one function.
PRUNE_CHILD_SKIP_REASON=""
prune_child_skip_reason() {
  if [ "$1" -eq 2 ]; then
    printf 'cannot validate the current pointer, so the children ledger is not scanned (%s): %s\n' \
      "$REIN_POINTER_ERROR" "$POINTER_FILE"
    return 0
  fi
  printf 'no current pointer, so nothing names which session must be kept -- the children ledger is not scanned: %s\n' \
    "$POINTER_FILE"
}

# Entries in the children ledger (`<runtime>/children/<session_id>.<agent_id>`) belonging to a
# session **other than the one the pointer currently names**.
#
# These are inert -- each session reads only its own session_id's entries, so a leftover can
# never refuse a later generation's handover (see the ledger's own note in the shared library).
# They're scanned only so the location doesn't grow without bound: a session stopped externally
# (which is exactly what a handover does to the predecessor) never delivers SubagentStop, so
# every generation can leave entries behind.
#
# **The pointer is the sole input naming who must not be deleted**, so a pointer that can't be
# validated -- or isn't there at all -- means nothing is made a candidate, and the reason is
# shown. Unlike the `session` scan this doesn't fail the whole run: this kind is in the default
# scan, and failing here would take a plain `rein prune` down with it on a lineage that has yet
# to hand over even once.
prune_scan_children() {
  local dir file name current rc
  PRUNE_CHILD_SKIP_REASON=""
  dir="$RUNTIME_DIR/$REIN_CHILDREN_DIRNAME"
  [ -d "$dir" ] || return 0
  rein_validate_pointer "$POINTER_FILE" "$TARGET_CWD"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    PRUNE_CHILD_SKIP_REASON="$(prune_child_skip_reason "$rc")"
    prune_notice "$PRUNE_CHILD_SKIP_REASON"
    return 0
  fi
  current="$REIN_POINTER_SESSION_ID"
  # Enumerated with `find`, the same way the archive scan is -- a `*` glob skips a name beginning
  # with a dot, and a session_id is allowed to start with one, so that entry would never become a
  # candidate and its lineage's ledger would grow without bound.
  while IFS= read -r -d '' file; do
    [ -n "$file" ] || continue
    name="${file##*/}"
    # Matched by **building the current session's prefix**, never by splitting a name on `.` (a
    # session_id may legitimately contain one, so splitting could hand the current session's own
    # entry to the delete side). Quoted, so a metacharacter in the id is compared literally.
    case "$name" in
      "$current".*) continue ;;
    esac
    prune_add "child" "$file" "a children-ledger entry left behind by a session other than the current one"
  done < <(find "$dir" -maxdepth 1 -type f -print0 2>/dev/null | LC_ALL=C sort -z)
  return 0
}

# Re-checked right before the delete (the same discipline every other kind follows): the entry
# still sits directly inside **this lineage's own** ledger, the pointer still validates, and the
# entry still doesn't belong to the session it names.
prune_child_still_valid() {
  local target="$1" name rc
  if [ "${target%/*}" != "$RUNTIME_DIR/$REIN_CHILDREN_DIRNAME" ]; then
    fail "not deleting outside this lineage's children ledger: ${target}"
    return 1
  fi
  rein_validate_pointer "$POINTER_FILE" "$TARGET_CWD"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "$(prune_child_skip_reason "$rc")"
    return 1
  fi
  name="${target##*/}"
  case "$name" in
    "$REIN_POINTER_SESSION_ID".*)
      fail "not deleting a children-ledger entry belonging to the current session: ${target}"
      return 1
      ;;
  esac
  return 0
}

# Tears down a runtime directory by deleting only the **known runtime artifact names**
# individually. `rm -rf <dir>` would also sweep up anything placed there between scanning and
# applying, or anything rein doesn't know about.
# Deleting by counting names means anything unknown left behind surfaces when the final
# rmdir fails.
prune_remove_runtime_dir() {
  local dir="$1" name lock suffix path failed=0 gone=""
  # The canonical list of known names is the shared library's set (writing it out again in
  # this file would leave the cleanup side stranded the day a name is added there). Elements may contain a glob, so only the location is quoted; the name part is left
  # unquoted so that a prefix like `managed-settings.*` expands as intended.
  for name in "${REIN_RUNTIME_ARTIFACT_NAMES[@]}"; do
    for path in "$dir/"$name; do
      [ -e "$path" ] || continue
      if rm -rf "$path"; then
        gone="${gone}${gone:+ }${path##*/}"
      else
        failed=1
      fi
    done
  done
  # Also tears down the temp names locks use while acquiring/releasing (a fixed suffix
  # hanging off the public name). These can be left behind by a crash mid-operation, and are
  # every bit as much rein's own runtime artifact -- they don't count as "unknown."
  for lock in "${REIN_RUNTIME_LOCK_DIRNAMES[@]}"; do
    for suffix in "${REIN_LOCK_TEMP_SUFFIXES[@]}"; do
      for path in "$dir/$lock"$suffix; do
        [ -e "$path" ] || continue
        if rm -rf "$path"; then
          gone="${gone}${gone:+ }${path##*/}"
        else
          failed=1
        fi
      done
    done
  done
  if [ "$failed" -ne 0 ]; then
    fail "cannot delete the runtime artifacts: ${dir}"
    return 1
  fi
  if ! rmdir "$dir" 2>/dev/null; then
    # By this point **the known runtime artifacts are already gone** (deleting the named ones
    # before rmdir is itself the specification -- see docs/spec/runtime.md, "surface it rather
    # than deleting partway"). Claiming "not deleted" here would say the opposite of what
    # happened, and the user would read it as "nothing was deleted" while actually losing the
    # owner file (what every entry point verifies before it reads or writes the location, and
    # `status --all`'s identification) and any unhandled handover requests. This one line carries both what
    # couldn't be torn down and the names of what was deleted.
    fail "could not tear down the location because something rein doesn't recognize remains in the runtime directory (artifacts deleted: ${gone:-none}): ${dir}"
    return 1
  fi
  return 0
}

# Takes the operation lock of the lineage being deleted. `rein up` takes this same lock
# before waking that location's watcher, so holding it closes the window, between
# re-validating and deleting, in which a watcher could get woken (a lock on this lineage's
# own location wouldn't serialize against another lineage starting up -- the lock is per
# location).
# 0=acquired (OK to delete) / 1=not acquired (don't delete)
prune_hold_target_op_lock() {
  local dir="$1" lock owner rc
  lock="$dir/$REIN_OP_LOCK_DIRNAME"
  PRUNE_OP_LOCK_TOKEN="$(rein_nonce)"
  prune_claim_target_op_lock "$dir"
  rc=$?
  case "$rc" in
    0) return 0 ;;
    1)
      fail "cannot prepare the cleanup operation lock: ${lock}"
      return 1
      ;;
  esac
  owner="$(rein_lock_pid "$lock")"
  case "$owner" in
    '' | *[!0-9]*)
      fail "not deleting a lineage whose operation lock's owner can't be read (confirm no other rein is running here, then: rmdir $(rein_shell_quote "$lock"))"
      return 1
      ;;
  esac
  rein_pid_alive "$owner"
  rc=$?
  if [ "$rc" -eq 2 ]; then
    fail "ps is not answering, so not deleting a lineage whose operation lock's owner (pid=${owner}) can't be confirmed alive: ${lock}"
    return 1
  fi
  # Whether it's the owner isn't decided by pid liveness alone (pids get reused) -- the
  # claimed start time is checked too. This goes through the same function used when
  # re-claiming, so "owner is present" doesn't mean two different things between acquisition
  # and cleanup.
  if rein_lock_owner_alive "$lock"; then
    fail "another rein operation is in progress on that lineage (pid=${owner}): ${lock}"
    return 1
  fi
  # A lock whose owner is gone (stale) is re-claimed under the same rule as up / down. Not
  # deleted if it can't be re-claimed. Only the lock stamped with **that specific pid this
  # process judged stale** is removed -- if another rein re-claimed it in the gap between
  # checking and removing, a plain release would strip a lock that's still alive.
  prune_claim_target_op_lock "$dir" reclaim
  rc=$?
  if [ "$rc" -eq 0 ]; then
    return 0
  fi
  fail "cannot re-claim the cleanup operation lock: ${lock}"
  return 1
}

# Claims the cleanup operation lock. The claimed cwd is **that lineage's own owner** (not this
# side's target cwd -- this lock belongs to the location being deleted, so naming this side's
# cwd would write another lineage's claim).
# 0=acquired / 1=cannot prepare / 2=owner present
prune_claim_target_op_lock() {
  local dir="$1" claim=rein_claim_lock_dir owner_cwd=""
  [ "${2:-}" = "reclaim" ] && claim=rein_claim_lock_dir_or_reclaim
  if [ -f "$dir/$REIN_OWNER_BASENAME" ] && [ ! -L "$dir/$REIN_OWNER_BASENAME" ]; then
    owner_cwd="$(head -1 "$dir/$REIN_OWNER_BASENAME" 2>/dev/null)"
  fi
  "$claim" "$dir/$REIN_OP_LOCK_DIRNAME" \
    start "$(rein_process_start_identity "$$")" \
    cwd "$owner_cwd" \
    mode "$REIN_LOCK_MODE_OP" \
    token "$PRUNE_OP_LOCK_TOKEN"
}

prune_release_target_op_lock() {
  local dir="$1" lock rc
  lock="$dir/$REIN_OP_LOCK_DIRNAME"
  [ -e "$lock" ] || return 0
  # Only removes the lock claimed by this generation (leaves it alone if another rein
  # re-claimed it).
  rein_release_lock_dir_if_mine "$lock" "$PRUNE_OP_LOCK_TOKEN"
  rc=$?
  [ "$rc" -eq 0 ] && return 0
  if [ "$rc" -eq 2 ]; then
    warn "not removing the cleanup operation lock -- it had already been replaced by another rein's: ${lock}"
    return 0
  fi
  warn "cannot remove the cleanup operation lock: ${lock}"
  return 1
}

# Re-validates a candidate's premise right before applying it. A watcher can start, or an
# owner can get placed, in the gap between scanning and applying -- deleting on the scan-time
# judgment alone could delete a lineage that's running by the time it happens.
prune_orphan_still_valid() {
  local dir="$1" cwd
  [ -d "$dir" ] || {
    fail "the runtime directory can't be found: ${dir}"
    return 1
  }
  if [ "$RUNTIME_DIR_EXPLICIT" -eq 1 ] || ! prune_dir_is_scannable "$dir" ||
    ! runtime_dir_is_rein "$dir" || prune_dir_holds_records "$dir"; then
    fail "not an orphan directly under the runtime data location: ${dir}"
    return 1
  fi
  if ! prune_locks_free "$dir"; then
    fail "the watcher lock's or seat lock's owner can't be confirmed, or the lineage is running: ${dir}"
    return 1
  fi
  if [ -f "$dir/$REIN_OWNER_BASENAME" ] && [ ! -L "$dir/$REIN_OWNER_BASENAME" ]; then
    cwd="$(head -1 "$dir/$REIN_OWNER_BASENAME" 2>/dev/null)"
    if [ -n "$cwd" ] && [ -d "$cwd" ]; then
      fail "not deleting it because the owner's work tree exists: ${dir}"
      return 1
    fi
  fi
  return 0
}

prune_apply_one() {
  local kind="$1" target="$2" rc
  case "$kind" in
    session)
      prune_wants session || {
        fail "outside the selected kinds, not applying: ${kind}"
        return 1
      }
      # The output is discarded (not sent to the terminal). rc is rein_run_capture's exit code.
      rein_run_capture "$CMD_TIMEOUT_SEC" claude rm "$target" >/dev/null
      rc=$?
      if [ "$rc" -ne 0 ]; then
        fail "claude rm ${target} failed: $(rein_command_failure_detail "$rc")"
        return 1
      fi
      printf 'deleted: session %s\n' "$target"
      ;;
    orphan)
      prune_wants orphan || {
        fail "outside the selected kinds, not applying: ${kind}"
        return 1
      }
      # That lineage's watcher can get woken between re-validating and finishing the delete
      # (`up` takes the same lock before starting up). prune takes the same lock too, to
      # serialize against that and refuse to delete if it can't get it -- closing the window
      # for deleting a lineage that has just started running.
      prune_hold_target_op_lock "$target" || return 1
      if ! prune_orphan_still_valid "$target"; then
        prune_release_target_op_lock "$target"
        return 1
      fi
      if ! prune_remove_runtime_dir "$target"; then
        prune_release_target_op_lock "$target"
        return 1
      fi
      # Nothing is left to release, since the whole location is gone (a no-op if it deleted
      # cleanly).
      prune_release_target_op_lock "$target"
      printf 'deleted: %s\n' "$target"
      ;;
    archive)
      prune_wants archive || {
        fail "outside the selected kinds, not applying: ${kind}"
        return 1
      }
      # Archive deletion is limited to plain files directly under this lineage's own
      # processed / rejected / cancelled (the same 3 as the scan -- adding only one of them
      # here would leave a kind that shows up as a candidate but can't be deleted).
      case "$target" in
        "$RUNTIME_DIR/$REIN_PROCESSED_DIRNAME"/* | "$RUNTIME_DIR/$REIN_REJECTED_DIRNAME"/* | \
          "$RUNTIME_DIR/$REIN_CANCELLED_DIRNAME"/*) ;;
        *)
          fail "not deleting outside the archive locations: ${target}"
          return 1
          ;;
      esac
      if [ -L "$target" ] || [ ! -f "$target" ]; then
        fail "archive deletion only touches plain files: ${target}"
        return 1
      fi
      if ! rm -f "$target"; then
        fail "cannot delete the archived entry: ${target}"
        return 1
      fi
      printf 'deleted: %s\n' "$target"
      ;;
    child)
      prune_wants child || {
        fail "outside the selected kinds, not applying: ${kind}"
        return 1
      }
      prune_child_still_valid "$target" || return 1
      if [ -L "$target" ] || [ ! -f "$target" ]; then
        fail "children-ledger deletion only touches plain files: ${target}"
        return 1
      fi
      if ! rm -f "$target"; then
        fail "cannot delete the children-ledger entry: ${target}"
        return 1
      fi
      printf 'deleted: %s\n' "$target"
      ;;
    *)
      fail "unknown cleanup kind: ${kind}"
      return 1
      ;;
  esac
  return 0
}

# Whether a kind is scanned/applied (defaults to archive and child; `-o` / `-s` / `-a` add more).
prune_wants() {
  case " $PRUNE_WANTED " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# Resets the scan state (so `status`'s count and `prune` proper can each run the same scan).
prune_reset() {
  PRUNE_KINDS=()
  PRUNE_TARGETS=()
  PRUNE_NOTES=()
  PRUNE_NOTICES=()
  PRUNE_ERROR=""
}

# Scans the selected kinds in order. 0=scanned / 1=could not scan (reason in PRUNE_ERROR)
prune_scan_selected() {
  if prune_wants session && ! prune_scan_sessions; then
    return 1
  fi
  if prune_wants orphan; then
    prune_scan_orphans
  fi
  if prune_wants archive; then
    prune_scan_archives "$ARCHIVE_DAYS"
  fi
  if prune_wants child; then
    prune_scan_children
  fi
  return 0
}

# Counts per kind. **The `status` candidate line and `--json` both go through this one
# function** (counting it in two places risks the current-state report saying "0" while
# `prune` lists candidates). **A kind that can't be counted returns an empty string plus a
# reason instead of falling back to 0** (so the display side can say "cannot determine" or
# "not scanned") -- for session, when the enumeration can't be read; for orphan, when the
# cross-lineage scan doesn't apply to this lineage.
# Enumeration can be received as an argument (`status` passes the one it already fetched for
# the primary session's liveness check).
prune_count_candidates() {
  local i total
  prune_reset
  PRUNE_WANTED="archive child orphan session"
  PRUNE_COUNT_ARCHIVE=0
  PRUNE_COUNT_ORPHAN=0
  PRUNE_COUNT_SESSION=0
  PRUNE_COUNT_CHILD=0
  PRUNE_COUNT_SESSION_REASON=""
  PRUNE_COUNT_ORPHAN_REASON=""
  PRUNE_COUNT_CHILD_REASON=""
  if ! prune_scan_sessions "$@"; then
    PRUNE_COUNT_SESSION=""
    # Read by the current-state display side (status.sh) -- looks unused within this file alone.
    # shellcheck disable=SC2034
    PRUNE_COUNT_SESSION_REASON="$PRUNE_ERROR"
  fi
  if [ "$RUNTIME_DIR_EXPLICIT" -eq 1 ]; then
    PRUNE_COUNT_ORPHAN=""
    # shellcheck disable=SC2034
    PRUNE_COUNT_ORPHAN_REASON="$(prune_orphan_skip_reason)"
  fi
  prune_scan_orphans
  prune_scan_archives "$ARCHIVE_DAYS"
  prune_scan_children
  if [ -n "$PRUNE_CHILD_SKIP_REASON" ]; then
    PRUNE_COUNT_CHILD=""
    # Read by the current-state display side (status.sh) -- looks unused within this file alone.
    # shellcheck disable=SC2034
    PRUNE_COUNT_CHILD_REASON="$PRUNE_CHILD_SKIP_REASON"
  fi
  total="${#PRUNE_KINDS[@]}"
  i=0
  while [ "$i" -lt "$total" ]; do
    case "${PRUNE_KINDS[$i]}" in
      archive) PRUNE_COUNT_ARCHIVE=$((PRUNE_COUNT_ARCHIVE + 1)) ;;
      orphan) [ -z "$PRUNE_COUNT_ORPHAN" ] || PRUNE_COUNT_ORPHAN=$((PRUNE_COUNT_ORPHAN + 1)) ;;
      session) [ -z "$PRUNE_COUNT_SESSION" ] || PRUNE_COUNT_SESSION=$((PRUNE_COUNT_SESSION + 1)) ;;
      child) [ -z "$PRUNE_COUNT_CHILD" ] || PRUNE_COUNT_CHILD=$((PRUNE_COUNT_CHILD + 1)) ;;
    esac
    i=$((i + 1))
  done
  return 0
}

# The preview's subtotal line (shows only the kinds that were scanned -- so a kind that
# wasn't scanned doesn't get read as "0 means none").
prune_subtotal_line() {
  local kind out="" count total i
  for kind in archive child orphan session; do
    prune_wants "$kind" || continue
    count=0
    total="${#PRUNE_KINDS[@]}"
    i=0
    while [ "$i" -lt "$total" ]; do
      [ "${PRUNE_KINDS[$i]}" != "$kind" ] || count=$((count + 1))
      i=$((i + 1))
    done
    printf -v out '%s%s%s %s' "$out" "${out:+ / }" "$kind" "$count"
  done
  printf '%s\n' "$out"
}

cmd_prune() {
  local force=0 want_orphan=0 want_session=0 rc i failed=0 removed=0 count=0 notice
  while [ $# -gt 0 ]; do
    case "$1" in
      --force | -f)
        force=1
        shift
        ;;
      --orphan | -o)
        want_orphan=1
        shift
        ;;
      --session | -s)
        want_session=1
        shift
        ;;
      --all | -a)
        want_orphan=1
        want_session=1
        shift
        ;;
      *)
        take_verb_opt "$@"
        rc=$?
        case "$rc" in
          0) shift "$VERB_SHIFT" ;;
          2) return 2 ;;
          *)
            fail_usage "unknown argument to prune: $1"
            return 2
            ;;
        esac
        ;;
    esac
  done
  # Defaults to the two kinds whose scan and delete both stay inside this lineage and touch only
  # plain files: archives, and leftover children-ledger entries. Orphans (the cross-lineage scan)
  # and sessions (deletion via an external CLI) only enter the scan once their flag asks for them.
  PRUNE_WANTED="archive child"
  [ "$want_orphan" -eq 0 ] || PRUNE_WANTED="$PRUNE_WANTED orphan"
  [ "$want_session" -eq 0 ] || PRUNE_WANTED="$PRUNE_WANTED session"
  prune_reset

  prepare_runtime || return 1
  require_prerequisites || return 1
  if [ -d "$RUNTIME_DIR" ]; then
    verify_runtime_owner_or_fail || return 1
  fi

  if ! prune_scan_selected; then
    fail "$PRUNE_ERROR"
    return 1
  fi

  for notice in ${PRUNE_NOTICES[@]+"${PRUNE_NOTICES[@]}"}; do
    printf '  excluded: %s\n' "$notice"
  done

  count="${#PRUNE_KINDS[@]}"
  i=0
  while [ "$i" -lt "$count" ]; do
    printf '  %s\t%s\t%s\n' "${PRUNE_KINDS[$i]}" "${PRUNE_TARGETS[$i]}" "${PRUNE_NOTES[$i]}"
    if [ "$force" -eq 1 ]; then
      if prune_apply_one "${PRUNE_KINDS[$i]}" "${PRUNE_TARGETS[$i]}"; then
        removed=$((removed + 1))
      else
        failed=$((failed + 1))
      fi
    fi
    i=$((i + 1))
  done

  if [ "$force" -eq 1 ]; then
    printf 'deleted %s / excluded %s\n' "$removed" "${#PRUNE_NOTICES[@]}"
  else
    printf 'candidates: %s\n' "$(prune_subtotal_line)"
    if [ "$count" -eq 0 ]; then
      printf 'nothing to clean up\n'
    else
      printf 'add -f to actually delete (nothing was deleted)\n'
    fi
  fi
  if [ "$failed" -ne 0 ]; then
    fail "${failed} cleanup items failed"
    return 1
  fi
  return 0
}
