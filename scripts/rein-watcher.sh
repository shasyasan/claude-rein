#!/usr/bin/env bash
# Watcher that monitors the handover request marker and runs everything from launching the
# successor session to confirming the predecessor session has exited.
# One instance runs per target project directory (cwd). Contract: docs/spec/architecture.md.
# Runs as a daemon, so errexit is not used (each stage's failure falls through explicitly to a
# notification plus a non-zero exit).
set -uo pipefail

# Normalize the entry-point execution environment. Force the character set to UTF-8 (bash cannot
# parse this file under a non-UTF-8 multibyte locale), and unset CDPATH (otherwise
# `$(cd ... && pwd -P)` can print two lines). Do this **before loading the shared libraries**;
# the canonical reason lives next to the same two lines in bin/rein.
unset LC_ALL CDPATH
export LC_CTYPE=UTF-8

# Resolve this script's own location using **string operations only** (never `dirname` or `cd`).
# Resolving the location by descending into `dirname`'s output and then reading the current
# directory is arbitrary code execution: if `dirname` prints empty, `cd` to an empty string
# **succeeds without changing the working directory**, so the current directory stays the
# caller's working directory, and `lib/rein-common.sh` there gets loaded and run --
# a `dirname` on PATH that prints empty (or a broken `dirname`) lets a same-named file sitting
# in whatever repo the caller is working in run with the resident process's privileges.
# A relative invocation is made absolute by prefixing `$PWD`. At startup the working directory
# has not moved yet, so this is **exactly where this script actually is**
# (unlike the pattern above that falls back to the working directory on a `cd` failure, there is
# no room here to land somewhere else).
# The canonical version of this pattern lives in scripts/rein-hook.sh's location resolution.
SCRIPT_PATH="${BASH_SOURCE[0]}"
case "$SCRIPT_PATH" in
  /*) ;;
  *) SCRIPT_PATH="$PWD/$SCRIPT_PATH" ;;
esac
SCRIPT_DIR="${SCRIPT_PATH%/*}"
SCRIPT_NAME="${SCRIPT_PATH##*/}"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/rein-common.sh
. "$SCRIPT_DIR/lib/rein-common.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/rein-config.sh
. "$SCRIPT_DIR/lib/rein-config.sh"

# Effective values come from the config layer (contract "when it takes effect" -- the watcher
# rereads it every polling cycle). Defaults are canonical in the known-keys table; not kept here.
POLL_INTERVAL_SEC=""
FINAL_OUTPUT_TIMEOUT_SEC=""
FINAL_OUTPUT_WAIT_SEC=""
LAUNCH_TIMEOUT_SEC=""
EXIT_GRACE_SEC=""
STOP_TIMEOUT_SEC=""
MARKER_MAX_AGE_SEC=""
MAX_CLOCK_SKEW_SEC=""
HANDOFF_FRESH_WINDOW_SEC=""
WATCHER_LOG_MAX_BYTES=""
CLAUDE_SETTINGS=""
CLAUDE_MODEL=""
KICKOFF_NOTE_PATH=""

TARGET_CWD=""
RUNTIME_DIR_OPT=""
SETTINGS_OPT=""
INTERVAL_OPT=""
RUN_ONCE=0
BOOTSTRAP=0
BOOTSTRAP_HANDOFF=""
BOOTSTRAP_NAME=""

# The real path of the handover request command that kickoff points to. Resolve it from the repo
# root so a symlinked invocation still points to the same one (the successor is a separate
# process, so a relative path cannot be resolved there). Resolving symlinks needs `pwd -P`, so
# this is the only place that runs it, but **a round that fails to resolve is never silently
# papered over** -- falling back to an empty string as `/bin/rein` would hand the successor
# instructions that name a command that does not exist.
REIN_BIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
if [ -z "$REIN_BIN_ROOT" ]; then
  printf '%s: cannot descend to the repo root (cannot name the handover request command): %s\n' \
    "$SCRIPT_NAME" "$SCRIPT_DIR" >&2
  exit 1
fi
REIN_BIN="$REIN_BIN_ROOT/$REIN_CLI_RELPATH"

RUNTIME_DIR=""
RECORDS_DIR=""
MARKER_FILE=""
HANDOVER_READY_FILE=""
HANDOVER_CANCEL_FILE=""
POINTER_FILE=""
LOG_FILE=""
WATCHER_LOG_FILE=""
HEARTBEAT_FILE=""
STOP_REQUEST_FILE=""
LOCK_DIR=""
LOCK_HELD=0
LOCK_ERROR=""
# A disposable marker naming this run's own generation. Used at release time to check whether what
# is published under the public name still belongs to it -- the pid is not enough: if a different run
# claims the lock in the gap between reading it and releasing it, releasing based on the pid would
# strip the winning lock the other run just claimed (two watchers holding it at once).
LOCK_TOKEN=""
REJECT_REASON=""
POINTER_ERROR=""
POINTER_GENERATION=""
CLAIMED_MARKER=""
SUCCESSOR_ID=""
CONFIG_ERROR_LAST=""
RUNTIME_DIR_DRIFT_LAST=""
STOP_REQUEST_REJECTED=0
EXIT_REASON=""
M_SESSION_ID=""
M_REQUESTED_AT=""
M_HANDOFF_PATH=""
M_SUCCESSOR_NAME=""

# Validate CLI flag values (the wording of the reason lives in the config layer -- don't write it
# three different ways across three scripts).
check_opt() {
  rein_config_check_opt "$@" && return 0
  printf '%s: %s\n' "$SCRIPT_NAME" "$REIN_CONFIG_ERROR" >&2
  return 2
}

# Validate the value of a flag that has no config key. Apply the same discipline as the flags that
# do have one (check_opt) -- silently falling through on a failed `shift 2` would print **not even
# one line of reason before exiting non-zero** (the watcher is started as a daemon, so a silent
# non-zero exit is observed by no one).
# An explicit empty value is not treated as "not given" either: `--cwd ""` would masquerade as
# "not specified" instead of the intended target, `--handoff ""` would silently grab config's
# default, and `--successor-name ""` the default naming -- either way, a different input slips
# through with no signal.
# Keep the wording matching bin/rein's and rein-request.sh's need_value (don't say the same thing
# two different ways).
need_value() {
  local flag="$1" count="$2" value="${3-}"
  if [ "$count" -lt 2 ]; then
    printf '%s: %s requires a value\n' "$SCRIPT_NAME" "$flag" >&2
    return 2
  fi
  if [ -z "$value" ]; then
    printf '%s: %s cannot take an empty value (it is not treated as unspecified)\n' "$SCRIPT_NAME" "$flag" >&2
    return 2
  fi
  return 0
}

usage() {
  cat <<EOF
usage: $SCRIPT_NAME --cwd <target project directory> [options]
       $SCRIPT_NAME --cwd <target project directory> --bootstrap [--handoff <path>]
       $SCRIPT_NAME --selftest [section ...] (list section names with --selftest --list)

  --cwd <path>          the target project directory to watch (required)
  --runtime-dir <path>  where runtime data is kept (default: config's runtime_dir -> XDG state area)
  --settings <value>    the --settings to pass to claude when launching the successor (a file path or a JSON string)
  --interval <seconds>  the polling interval for marker watching (default: config's poll_interval_sec)
  --once                scan once and exit (does not stay resident)
  --bootstrap           start the primary session from a state with no current pointer (exits after one run)
  --handoff <path>      the handoff document to put in the kickoff for --bootstrap (default: config's handoff_path, i.e. handoff.md next to the records)
  --successor-name <name>  the display name for the session --bootstrap starts (optional)

  A lineage's records (the current pointer, the handover log, the watcher log) go under the
  target project directory's ${REIN_RECORDS_DIRNAME}/. Runtime data (the marker, the lock,
  the heartbeat, archived markers) goes in the location above.
EOF
}

# Not being able to write the watcher log is never silenced (this is the only place where the
# record going missing would be noticed at all). **Don't repeat the same reason every time** -- wlog can be
# called every cycle, and one line flooding the terminal drowns out that cycle's real reason.
# The watcher log is diagnostic, so being unable to write it does not bring monitoring down
# (the canonical audit trail -- the handover log -- has its own check, and failing to write
# *that* is a stage failure).
WATCHER_LOG_REJECTED=0
watcher_log_unwritable() {
  [ "$WATCHER_LOG_REJECTED" -eq 0 ] || return 0
  WATCHER_LOG_REJECTED=1
  printf '%s: giving up on the watcher log because it cannot be written (%s)\n' "$SCRIPT_NAME" "$1" >&2
  return 0
}

# The watcher's own operating log. Separate from the handover log (the canonical audit trail,
# append-only) -- only this one has a size cap, so operational diagnostic lines don't pile up
# without bound. Once past the cap, roll one generation into .1 (rolling multiple generations
# would raise a separate question of how many old diagnostics to keep).
wlog() {
  local size dir
  [ -n "$WATCHER_LOG_FILE" ] || return 0
  # Leave a line here even for a run that dies before it can start (when a watcher started as a
  # daemon never comes up, if the watcher log stops at the previous exit line, there is no way for
  # the user to tell that apart from "nothing happened at all").
  # The location itself is created following the records-location discipline (a .gitignore with
  # just `*`).
  dir="${WATCHER_LOG_FILE%/*}"
  [ -d "$dir" ] || rein_ensure_records_dir "$dir" || return 0
  # The append uses `>>`, so if it's a symlink the target (which could be outside the project)
  # grows, and if it's a dangling symlink the target gets **created**, while the caller reads it
  # as success. `.rein/`'s contents can ship inside a clone (the threat model's "outside"), so run
  # this through the **same check** as the replacement writer and the handover log. The rotation
  # `mv` also runs after this check, so it never rotates a file whose shape cannot be accepted.
  if ! rein_dest_shape_ok "$WATCHER_LOG_FILE"; then
    watcher_log_unwritable "$REIN_DEST_SHAPE_ERROR"
    return 0
  fi
  size="$(stat -f %z "$WATCHER_LOG_FILE" 2>/dev/null)"
  case "$size" in
    '' | *[!0-9]*) size=0 ;;
  esac
  if [ -n "$WATCHER_LOG_MAX_BYTES" ] && [ "$size" -ge "$WATCHER_LOG_MAX_BYTES" ]; then
    # The rotation target runs through the same check too. If the destination is a directory,
    # `mv` moves the original file **inside it** and returns 0, so without checking the shape the
    # watcher log could end up at `watcher.log.1/watcher.log` while the caller reads it as
    # success (the same false-success shape the replacement writer names).
    # A round that cannot be rotated keeps writing without rotating (the cap is about the volume
    # of diagnostic lines -- an undeletable destination is not a reason to stop recording at all).
    if rein_dest_shape_ok "${WATCHER_LOG_FILE}.1"; then
      mv -f "$WATCHER_LOG_FILE" "${WATCHER_LOG_FILE}.1" 2>/dev/null
    else
      watcher_log_unwritable "$REIN_DEST_SHAPE_ERROR"
    fi
  fi
  printf '%s %s\n' "$(rein_iso_now)" "$1" >>"$WATCHER_LOG_FILE" 2>/dev/null
  return 0
}

fail_stage() {
  local stage="$1" reason="$2" generation="${3:-}" predecessor="${4:-}" successor="${5:-}"
  local detail
  reason="$(rein_redact_settings "$reason" "$CLAUDE_SETTINGS")"
  printf -v detail 'stage=%s reason=%s' "$stage" "$reason"
  # The handover log is the only audit surface, so not being able to write to it is never
  # silenced either.
  if ! rein_log_event "$LOG_FILE" "failed" "$detail" "$generation" "$predecessor" "$successor"; then
    printf '%s: cannot record "failed" to the handover log: %s\n' "$SCRIPT_NAME" "$LOG_FILE" >&2
  fi
  wlog "$detail"
  EXIT_REASON="$detail"
  rein_notify "rein: handover failed" "$detail"
  return 1
}

# Keep how "cannot write the heartbeat" is handled in one place (the same in the watch loop and in
# a handover's wait loops -- contract: "if it cannot be written, record failed and exit non-zero";
# do not write this differently per path).
fail_heartbeat() {
  local reason
  printf -v reason 'cannot write the heartbeat: %s' "$HEARTBEAT_FILE"
  fail_stage "updating the heartbeat" "$reason" "$@"
  return 1
}

# A watcher that cannot write the audit record must not be allowed to keep running (do not let the
# handover proceed while only the record disappears).
log_event_or_fail() {
  local event="$1" detail="$2" generation="${3:-}" predecessor="${4:-}" successor="${5:-}"
  local reason
  if rein_log_event "$LOG_FILE" "$event" "$detail" "$generation" "$predecessor" "$successor"; then
    return 0
  fi
  printf -v reason 'cannot write %s to the handover log: %s' "$event" "$LOG_FILE"
  fail_stage "recording to the handover log" "$reason" "$generation" "$predecessor" "$successor"
  return 1
}

startup_reject() {
  wlog "cannot start: $1"
  printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2
  rein_notify "rein: cannot start the watcher" "$1"
  return 2
}

# Preflight check at startup. Entering monitoring without the required tools rejects every marker
# for the wrong reason.
validate_runtime() {
  local reason
  if ! rein_check_prerequisites "$SCRIPT_PATH"; then
    printf -v reason 'a prerequisite tool is unavailable: %s' "$REIN_MISSING_TOOLS"
    startup_reject "$reason"
    return 2
  fi
  return 0
}

# Read the config layer and layer CLI flags (stronger than env vars) on top to produce the
# effective values. Type, range, and combination checks are already done by the config layer
# (entering monitoring with an invalid value would make sleep return immediately, turning the loop
# into one that never waits, or would break the freshness-check window).
# 0=readable (effective values updated) / 1=unreadable (effective values untouched, reason in
# REIN_CONFIG_ERROR)
load_config_values() {
  if ! rein_config_prepare "$REIN_BIN" "$TARGET_CWD"; then
    return 1
  fi
  if [ -n "$INTERVAL_OPT" ]; then
    rein_config_override poll_interval_sec "$INTERVAL_OPT" || return 1
  fi
  if [ -n "$SETTINGS_OPT" ]; then
    rein_config_override settings "$SETTINGS_OPT" || return 1
  fi
  if [ -n "$RUNTIME_DIR_OPT" ]; then
    rein_config_override runtime_dir "$RUNTIME_DIR_OPT" || return 1
  fi
  rein_config_check_cross_fields || return 1
  rein_config_bind POLL_INTERVAL_SEC poll_interval_sec || return 1
  rein_config_bind FINAL_OUTPUT_TIMEOUT_SEC final_output_timeout_sec || return 1
  rein_config_bind FINAL_OUTPUT_WAIT_SEC final_output_wait_sec || return 1
  rein_config_bind LAUNCH_TIMEOUT_SEC launch_timeout_sec || return 1
  rein_config_bind EXIT_GRACE_SEC exit_grace_sec || return 1
  rein_config_bind STOP_TIMEOUT_SEC stop_timeout_sec || return 1
  rein_config_bind MARKER_MAX_AGE_SEC marker_max_age_sec || return 1
  rein_config_bind MAX_CLOCK_SKEW_SEC max_clock_skew_sec || return 1
  rein_config_bind HANDOFF_FRESH_WINDOW_SEC handoff_fresh_window_sec || return 1
  rein_config_bind WATCHER_LOG_MAX_BYTES watcher_log_max_bytes || return 1
  rein_config_bind CMD_TIMEOUT_SEC cmd_timeout_sec || return 1
  rein_config_bind CLAUDE_SETTINGS settings || return 1
  rein_config_bind CLAUDE_MODEL model || return 1
  rein_config_bind KICKOFF_NOTE_PATH kickoff_note_path || return 1
  return 0
}

# Reread on every polling cycle (contract "when it takes effect"). Do not stop monitoring just
# because a reread fails -- stopping would mean handovers from here on stop being automated
# silently. Keep running on the previous effective values and leave the reason in a notification
# and the watcher log (never silently fall back to the defaults).
# Do not sound the same reason every cycle -- only when the reason changes (otherwise the
# notification loses meaning).
# 0=reread succeeded (effective values updated) / 1=reread failed (effective values unchanged,
# monitoring continues)
reload_config_for_cycle() {
  local reason
  if load_config_values; then
    if [ -n "$CONFIG_ERROR_LAST" ]; then
      printf -v reason 'config is readable again (previous reason: %s)' "$CONFIG_ERROR_LAST"
      wlog "$reason"
      rein_notify "rein: reread the config" "$reason"
      CONFIG_ERROR_LAST=""
    fi
    return 0
  fi
  if [ "$REIN_CONFIG_ERROR" != "$CONFIG_ERROR_LAST" ]; then
    CONFIG_ERROR_LAST="$REIN_CONFIG_ERROR"
    printf -v reason 'cannot reread config (continuing to monitor on the previous effective values): %s' "$REIN_CONFIG_ERROR"
    wlog "$reason"
    rein_notify "rein: cannot reread config" "$reason"
  fi
  return 1
}

# `runtime_dir` is fixed at startup (rereading it mid-cycle and swapping the location would split
# where the marker, lock, heartbeat, and owner are looked up mid-handover). But silently ignoring
# a change means `rein config list`'s effective value and where the watcher is actually looking
# diverge, and a successor's handover request lands in a different lineage and goes silently
# nowhere. If the effective value has drifted from what it was at startup, sound this only when
# the reason changes.
# **Call this only on a cycle where the reread succeeded.** Even a config that was rejected (e.g.
# one that changed `runtime_dir` while also violating a cross-field rule) still has its values
# loaded into the config layer, so sounding "the effective value changed" for a rejected value
# would make a config that never took effect look like it did.
check_runtime_dir_drift() {
  local runtime_opt resolved reason
  rein_config_bind runtime_opt runtime_dir || return 0
  resolved="$(rein_resolve_runtime_dir "$TARGET_CWD" "$runtime_opt")"
  if [ -z "$resolved" ] || [ "$resolved" = "$RUNTIME_DIR" ]; then
    RUNTIME_DIR_DRIFT_LAST=""
    return 0
  fi
  if [ "$resolved" = "$RUNTIME_DIR_DRIFT_LAST" ]; then
    return 0
  fi
  RUNTIME_DIR_DRIFT_LAST="$resolved"
  printf -v reason 'changing where runtime data is kept requires restarting the watcher (monitoring keeps watching the %s it started with; config effective value is %s)' \
    "$RUNTIME_DIR" "$resolved"
  wlog "$reason"
  rein_notify "rein: a location change requires a restart" "$reason"
  return 0
}

# The watcher lock. Published atomically via rename (shared library), so only the winner enters
# monitoring.
# 0=claimed / 1=another instance is watching / 2=undetermined (a lock whose owner cannot be
# confirmed is never seized)
acquire_watch_lock() {
  local rc owner
  LOCK_ERROR=""
  LOCK_DIR="$RUNTIME_DIR/$REIN_LOCK_DIRNAME"
  LOCK_TOKEN="$(rein_nonce)"
  claim_watch_lock
  rc=$?
  if [ "$rc" -eq 0 ]; then
    LOCK_HELD=1
    return 0
  fi
  if [ "$rc" -eq 1 ]; then
    printf -v LOCK_ERROR 'cannot prepare the watcher lock: %s' "$LOCK_DIR"
    return 2
  fi
  # It already exists. **Read the owner that is about to be stripped before judging it** -- the
  # reader (`rein_watcher_state`) does not carry the pid back when it judges a lock stale, so
  # reading it again after the judgment would pick up **the reclaiming side's live pid** whenever
  # another run stripped that same stale lock and reclaimed it in the gap between reading and
  # stripping, pass the identity check, and strip that live lock (two watchers holding it at
  # once). Reading it first means a round reclaimed in that gap fails
  # the identity match and is not stripped -- it falls to the side that reports a reason instead
  # of claiming.
  owner="$(rein_lock_pid "$LOCK_DIR")"
  # **The claimant and the reader judge through the same one function.** If a reused pid were read
  # by the claimant as "another instance is watching", readers (`status`, the handover request
  # writer, hooks) would read the same state as "not running" -- an asymmetry where only the
  # claimant keeps refusing to start.
  rein_watcher_state "$RUNTIME_DIR" "$TARGET_CWD"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    printf -v LOCK_ERROR 'another instance is already watching (pid=%s): %s' "$REIN_WATCHER_PID" "$LOCK_DIR"
    return 1
  fi
  if [ "$rc" -eq 2 ]; then
    # A lock that cannot be confirmed is never seized (reuse the reader's reason verbatim so the
    # wording does not split into two places).
    LOCK_ERROR="$REIN_WATCHER_REASON"
    return 2
  fi
  # Reaching here means the reader judged "not running (a stale lock)". Strip **only the lock for
  # the pid the judgment itself saw** (release with an identity check) -- pass only the value read
  # above, and never re-read here. The staleness judgment is not handed to the shared library's
  # reclaim (which looks only at pid and start time), so the claimant and the reader never disagree
  # about
  # what "stale" means. A round where the lock had already vanished entirely (the reader returning
  # 1, "no watcher lock") is caught earlier by the existence check.
  if [ ! -e "$LOCK_DIR" ] || rein_release_lock_dir_if_stale "$LOCK_DIR" "$owner"; then
    claim_watch_lock
    rc=$?
    if [ "$rc" -eq 0 ]; then
      LOCK_HELD=1
      return 0
    fi
  fi
  printf -v LOCK_ERROR 'cannot reclaim the watcher lock (saw a lock owned by pid=%s): %s' \
    "${owner:-unknown}" "$LOCK_DIR"
  return 2
}

# Claim the watcher lock. Publish the claim (start time, cwd, role, token) **before** publishing
# the lock itself -- doing it after would leave a moment where the lock is published but the claim
# is not complete yet, and a reader in that gap would treat it as "a lock whose owner cannot be
# confirmed".
# 0=claimed / 1=cannot prepare / 2=already owned
claim_watch_lock() {
  rein_claim_lock_dir "$LOCK_DIR" \
    start "$(rein_process_start_identity "$$")" \
    cwd "$TARGET_CWD" \
    mode "$REIN_LOCK_MODE_WATCH" \
    token "$LOCK_TOKEN"
}

# EXIT traps do not see function locals, so state needed for release lives in globals.
# Release is also atomic (shared library) -- never leave a published lock without a pid mid-release.
# Only **this run's own generation's** lock is stripped (token match). If a different run has reclaimed it,
# leave it alone.
release_watch_lock() {
  local rc
  [ "$LOCK_HELD" -eq 1 ] || return 0
  rein_release_lock_dir_if_mine "$LOCK_DIR" "$LOCK_TOKEN"
  rc=$?
  LOCK_HELD=0
  if [ "$rc" -eq 2 ]; then
    wlog "the watcher lock had already been replaced by a different run, so it was left alone: ${LOCK_DIR}"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    printf '%s: cannot release the watcher lock: %s\n' "$SCRIPT_NAME" "$LOCK_DIR" >&2
    return 1
  fi
  return 0
}

# Mutual exclusion over a handover (launching a successor and repointing the pointer as one
# sequence). **The resident cycle and bootstrap run against the same lineage at the same
# time** -- `rein up` starts the watcher and then, under the same operation lock, fires bootstrap,
# but the watcher does not look at the operation lock. So with an unconsumed handover request
# marker still sitting there, both of these can hold at once: (a) the just-started watcher
# processes that marker on its first cycle and launches a successor, and (b) bootstrap reads "no
# primary session" and launches a successor of the same generation. The pointer is only written
# **after** the successor's launch is confirmed, so bootstrap's own guard (abort if the pointer
# already points at a live session) slips right through that gap. Whichever side loses the pointer
# keeps editing the same working tree with no one to stop it.
# Neither the watcher lock nor the operation lock substitutes for this (the former is held for the
# whole time it stays resident, the latter for the whole `up`, so the watcher started by `up` and
# `up`'s own bootstrap would always collide) -- hence a third lock scoped to just the handover
# window.
HANDOVER_LOCK_HELD=0
HANDOVER_LOCK_ERROR=""
HANDOVER_LOCK_TOKEN=""
# **Never give "cannot prepare" and "already owned" the same wording.** The former is the location
# itself being broken (a mechanism failure that will not resolve next cycle either); the latter is
# just another run in progress (resolves next cycle). Collapsing them into one message would
# report an unwritable location as "another run is handling the handover", and no one goes to fix
# it while handovers stay permanently stuck.
# 0=claimed / 1=cannot prepare (fatal) / 2=already owned (busy)
acquire_handover_lock() {
  local rc lock="$RUNTIME_DIR/$REIN_HANDOVER_LOCK_DIRNAME"
  HANDOVER_LOCK_ERROR=""
  HANDOVER_LOCK_TOKEN="$(rein_nonce)"
  rein_claim_lock_dir_or_reclaim "$lock" \
    start "$(rein_process_start_identity "$$")" \
    cwd "$TARGET_CWD" \
    mode "$REIN_LOCK_MODE_HANDOVER" \
    token "$HANDOVER_LOCK_TOKEN"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    HANDOVER_LOCK_HELD=1
    return 0
  fi
  if [ "$rc" -eq 1 ]; then
    printf -v HANDOVER_LOCK_ERROR 'cannot prepare the handover lock (cannot write to this location): %s' "$lock"
    return 1
  fi
  printf -v HANDOVER_LOCK_ERROR 'cannot claim the handover lock (another run is in the middle of a handover): %s' "$lock"
  return 2
}

# Only this run's own generation's lock is stripped. **The caller must always check the return
# value** -- exiting without releasing leaves the lock holding this run's own live pid, so it never
# goes stale either, and every future claim attempt stays busy forever -- this location stops
# processing handover requests entirely, while the heartbeat keeps updating so it looks healthy.
# 0=released (or was not this run's to begin with) / 1=could not release
release_handover_lock() {
  local rc lock="$RUNTIME_DIR/$REIN_HANDOVER_LOCK_DIRNAME"
  HANDOVER_LOCK_ERROR=""
  [ "$HANDOVER_LOCK_HELD" -eq 1 ] || return 0
  rein_release_lock_dir_if_mine "$lock" "$HANDOVER_LOCK_TOKEN"
  rc=$?
  HANDOVER_LOCK_HELD=0
  if [ "$rc" -eq 2 ]; then
    wlog "the handover lock had already been replaced by a different run, so it was left alone: ${lock}"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    printf -v HANDOVER_LOCK_ERROR 'cannot release the handover lock (leaving it held blocks every handover from here on): %s' "$lock"
    printf '%s: %s\n' "$SCRIPT_NAME" "$HANDOVER_LOCK_ERROR" >&2
    return 1
  fi
  return 0
}

# Leave exactly one line naming why this run exited (a daemon disappearing silently is the norm,
# so without this there is no way to trace the cause of death after the fact). Exiting without ever
# recording a reason only happens when it was stopped from outside by a signal.
cleanup_runtime() {
  wlog "exiting: ${EXIT_REASON:-stopped externally (no reason recorded)}"
  release_handover_lock
  release_watch_lock
  rein_close_error_sink
}

# Consume a stop request from `rein down`. Stopping is done by **handing over a request file** --
# this module has an invariant of never issuing an OS process-stop operation (kill / pkill /
# etc.) itself, so stopping via an external signal is not an option. The request is deleted before
# the exit, so the same request never stops the next startup too.
# 0=there was a stop request (end monitoring) / 1=none
consume_stop_request() {
  local requested_at reason
  [ -n "$STOP_REQUEST_FILE" ] || return 1
  [ -f "$STOP_REQUEST_FILE" ] || return 1
  # Check the schema marker, the timestamp format, and the requesting pid too (do not step down
  # for an empty file or garbage that just happens to have the right filename -- the same "never
  # silently accept a future format change" discipline as the other marker types).
  # An invalid request is **not deleted** -- leave the reason as one line in the watcher log and
  # keep monitoring (deleting it would leave whoever placed it unable to tell whether it was
  # accepted or discarded).
  requested_at="$(jq -r --arg s "$REIN_STOP_REQUEST_SCHEMA" '
    select(.schema == $s)
    | select((.requested_by_pid | type) == "number" and .requested_by_pid > 0
             and (.requested_by_pid | floor) == .requested_by_pid)
    | .requested_at // empty' "$STOP_REQUEST_FILE" 2>/dev/null)"
  if [ -z "$requested_at" ] || ! rein_iso_to_epoch "$requested_at" >/dev/null; then
    if [ "$STOP_REQUEST_REJECTED" -eq 0 ]; then
      STOP_REQUEST_REJECTED=1
      printf -v reason 'the stop request is not in the contracted shape, so it is not accepted (check the schema, requested_at, and requested_by_pid of %s): %s' \
        "$REIN_STOP_REQUEST_SCHEMA" "$STOP_REQUEST_FILE"
      wlog "$reason"
      rein_notify "rein: cannot accept the stop request" "$reason"
    fi
    return 1
  fi
  # Exiting without deleting it means the next watcher started stops right away on the same
  # request (contract: delete the request before exiting). Do not fall through to "stopped
  # successfully" -- surface this as a mechanism error.
  if ! rm -f "$STOP_REQUEST_FILE"; then
    printf -v reason 'cannot delete the stop request file (the next startup will also stop on this same request): %s' "$STOP_REQUEST_FILE"
    wlog "$reason"
    rein_notify "rein: cannot delete the stop request" "$reason"
    EXIT_REASON="$reason"
    return 2
  fi
  printf -v reason 'accepted the stop request and ending monitoring (requested at %s)' "${requested_at:-unknown}"
  EXIT_REASON="$reason"
  return 0
}

# The marker the attach loop watches to see the watcher is alive. The pointer not changing alone
# cannot distinguish "no handover has come yet" from "the watcher is dead".
write_heartbeat() {
  # Run the same check as the replacement writer (`>` overwrites whatever a symlink points to, or
  # creates the target of a dangling one). A shape that cannot be accepted counts as "cannot
  # write" -- surface it as a stage failure per contract (never silently treat it as written).
  # Leave the reason itself in the watcher log -- the caller's composed sentence
  # ("cannot write the heartbeat: <path>") alone does not say what shape it was.
  if ! rein_dest_shape_ok "$HEARTBEAT_FILE"; then
    wlog "$REIN_DEST_SHAPE_ERROR"
    return 1
  fi
  printf '%s %s\n' "$$" "$(rein_iso_now)" >"$HEARTBEAT_FILE" 2>/dev/null
}

# The set of session IDs present before startup. Taken so identifying the successor can be limited
# to "the element that appeared because of this launch".
# 0=got it (JSON array on stdout) / 2=cannot read the list, undetermined
snapshot_session_ids() {
  local agents ids
  agents="$(rein_list_agents)"
  [ -n "$agents" ] || return 2
  ids="$(printf '%s' "$agents" | jq -c '[ .[] | (.sessionId // empty) ]' 2>/dev/null)"
  [ -n "$ids" ] || return 2
  printf '%s\n' "$ids"
}

# Identify the successor from the listing right after launch. Since the format of --bg's stdout is
# never relied on, narrow by name, cwd, and start time (from when the launch command was issued),
# and further check "an ID that was not there before launch", "has a short job ID (i.e. is a
# background session)", "has a pid", and "not in a finished state". Do not let this match a
# different session with the same name -- it only resolves if the candidate set is exactly one.
# The entry check goes through the shared `rein_agents_json_ok` (a body that is valid JSON but not
# an array of objects makes the narrowing jq fail with a runtime error, and an empty match set is
# indistinguishable from "not present yet" -- the one answer that lets the caller stop waiting and
# lets the cleanup of a launched successor conclude there is nothing to clean up).
# 0=identified (session ID on stdout) / 1=not present yet / 2=cannot read the list / 3=multiple candidates
find_successor_session_id() {
  local name="$1" since_ms="$2" before="$3" agents matches count
  agents="$(rein_list_agents)"
  [ -n "$agents" ] || return 2
  rein_agents_json_ok "$agents" || return 2
  matches="$(printf '%s' "$agents" | jq -r \
    --arg name "$name" \
    --arg cwd "$TARGET_CWD" \
    --argjson since "$since_ms" \
    --argjson before "$before" '
    [ .[]
      | select(.name == $name and .cwd == $cwd and ((.startedAt // 0) >= $since))
      | select((.sessionId // "") != "")
      | select((.id // "") != "")
      | select((.pid // null) != null)
      | select(((.status // .state // "") | ascii_downcase) as $s
               | ($s != "done" and $s != "failed" and $s != "stopped"))
      | select((.sessionId) as $s | ($before | index($s)) == null)
      | .sessionId ]
    | unique | .[]' 2>/dev/null)"
  if [ -z "$matches" ]; then
    return 1
  fi
  count="$(printf '%s\n' "$matches" | wc -l | tr -d ' ')"
  if [ "$count" -ne 1 ]; then
    return 3
  fi
  printf '%s\n' "$matches"
}

# Contract validation for the current pointer. Silently rolling a broken pointer back to
# generation 1 would erase the monotonic-increase guarantee. Validation itself lives in the shared
# library (writing it separately per reader would let one reader silently accept a broken pointer
# the other does not).
# The result is returned via variables ($( ) would trap the reason inside a subshell, and a
# failed stage would get recorded with no reason).
# 0=valid (generation is in POINTER_GENERATION) / 1=no pointer / 2=violates the contract (reason in
# POINTER_ERROR)
read_pointer_generation() {
  local rc
  POINTER_ERROR=""
  POINTER_GENERATION=""
  rein_validate_pointer "$POINTER_FILE" "$TARGET_CWD"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    POINTER_ERROR="$REIN_POINTER_ERROR"
    return "$rc"
  fi
  POINTER_GENERATION="$REIN_POINTER_GENERATION"
  return 0
}

# Freshness validation. The reject reason goes in REJECT_REASON (rule name first, then the
# measured value).
validate_marker() {
  local now epoch_requested handoff_mtime marker_json m_schema m_cwd m_cwd_real age

  REJECT_REASON=""
  M_SESSION_ID=""
  M_REQUESTED_AT=""
  M_HANDOFF_PATH=""
  M_SUCCESSOR_NAME=""

  # Only read the file once it has been claimed (moved to processing). Reading the original path
  # and then moving it would risk archiving different content that replaced it in the meantime,
  # while running the handover on the old content.
  marker_json="$(cat "$CLAIMED_MARKER" 2>/dev/null)"
  if ! printf '%s' "$marker_json" | jq -e . >/dev/null 2>&1; then
    REJECT_REASON="R1 cannot be parsed as JSON"
    return 1
  fi

  m_schema="$(printf '%s' "$marker_json" | jq -r '.schema // empty')"
  if [ "$m_schema" != "$REIN_MARKER_SCHEMA" ]; then
    printf -v REJECT_REASON 'R2 schema does not match the contract: %s' "${m_schema:-(none)}"
    return 1
  fi

  M_SESSION_ID="$(printf '%s' "$marker_json" | jq -r '.session_id // empty')"
  if [ -z "$M_SESSION_ID" ]; then
    REJECT_REASON="R3 session_id is empty"
    return 1
  fi
  # The shape check is the shared library's one function (same as the hook's stdin and the
  # writer command). Markers can also arrive via a route that places JSON directly, so the
  # writer's own check alone does not close this off.
  if ! rein_session_id_shape_ok "$M_SESSION_ID" "session_id"; then
    printf -v REJECT_REASON 'R3 %s' "$REIN_SESSION_ID_ERROR"
    return 1
  fi

  M_REQUESTED_AT="$(printf '%s' "$marker_json" | jq -r '.requested_at // empty')"
  epoch_requested="$(rein_iso_to_epoch "$M_REQUESTED_AT")"
  if [ -z "$epoch_requested" ]; then
    printf -v REJECT_REASON 'R4 cannot parse requested_at as UTC, second precision: %s' "${M_REQUESTED_AT:-(none)}"
    return 1
  fi

  now="$(rein_now_epoch)"
  if [ "$epoch_requested" -gt "$((now + MAX_CLOCK_SKEW_SEC))" ]; then
    printf -v REJECT_REASON 'R4 requested_at is in the future: %s' "$M_REQUESTED_AT"
    return 1
  fi

  age="$((now - epoch_requested))"
  if [ "$age" -gt "$MARKER_MAX_AGE_SEC" ]; then
    printf -v REJECT_REASON 'R5 the marker is stale: %s sec elapsed > %s sec cap' "$age" "$MARKER_MAX_AGE_SEC"
    return 1
  fi

  M_HANDOFF_PATH="$(printf '%s' "$marker_json" | jq -r '.handoff_path // empty')"
  case "$M_HANDOFF_PATH" in
    /*) ;;
    *)
      printf -v REJECT_REASON 'R6 handoff_path is not an absolute path: %s' "${M_HANDOFF_PATH:-(none)}"
      return 1
      ;;
  esac
  # Existence, non-emptiness, and regular-file checks go through the one shared function (same as
  # the writer, the template, and launching the primary session). Writing [ -f ] here directly
  # would follow a symlink, and the existence/freshness judgment would end up on whatever the
  # target file's own state is (if the target happens to be a different, recently touched working
  # file, both R6 and R7 would pass).
  if ! rein_handoff_file_ok "$M_HANDOFF_PATH"; then
    printf -v REJECT_REASON 'R6 %s' "$REIN_HANDOFF_ERROR"
    return 1
  fi

  handoff_mtime="$(rein_mtime "$M_HANDOFF_PATH")"
  if [ -z "$handoff_mtime" ]; then
    printf -v REJECT_REASON 'R6 cannot get the handoff document mtime: %s' "$M_HANDOFF_PATH"
    return 1
  fi
  if [ "$handoff_mtime" -lt "$((epoch_requested - HANDOFF_FRESH_WINDOW_SEC))" ]; then
    printf -v REJECT_REASON 'R7 the handoff document was left stale before the marker: diff %s sec > window %s sec' \
      "$((epoch_requested - handoff_mtime))" "$HANDOFF_FRESH_WINDOW_SEC"
    return 1
  fi
  if [ "$handoff_mtime" -gt "$((now + MAX_CLOCK_SKEW_SEC))" ]; then
    printf -v REJECT_REASON 'R8 the handoff document mtime is in the future: %s' "$M_HANDOFF_PATH"
    return 1
  fi
  # The upper bound. A handoff document still being written after the marker means the handoff
  # write is not finished.
  if [ "$handoff_mtime" -gt "$((epoch_requested + MAX_CLOCK_SKEW_SEC))" ]; then
    printf -v REJECT_REASON 'R7 the handoff document was updated after the marker: diff %s sec > allowed skew %s sec' \
      "$((handoff_mtime - epoch_requested))" "$MAX_CLOCK_SKEW_SEC"
    return 1
  fi

  # Normalize both sides through pwd -P before comparing cwd (comparing one resolved side against
  # an unresolved one would drop a legitimate marker that came in via a symlink). A path that
  # cannot be resolved cannot be shown to match the target, so it is rejected.
  m_cwd="$(printf '%s' "$marker_json" | jq -r '.cwd // empty')"
  if [ -n "$m_cwd" ]; then
    m_cwd_real="$(cd "$m_cwd" 2>/dev/null && pwd -P)"
    if [ -z "$m_cwd_real" ] || [ "$m_cwd_real" != "$TARGET_CWD" ]; then
      printf -v REJECT_REASON 'R9 the marker cwd does not match the target: %s' "$m_cwd"
      return 1
    fi
  fi

  M_SUCCESSOR_NAME="$(printf '%s' "$marker_json" | jq -r '.successor_name // empty')"
  return 0
}

# Claim (mv to processing) the marker to take ownership before judging it. `mv` is atomic on the
# same filesystem, so even if started twice only one side can claim it.
claim_marker() {
  local dest_dir dest
  CLAIMED_MARKER=""
  dest_dir="$RUNTIME_DIR/$REIN_PROCESSING_DIRNAME"
  mkdir -p "$dest_dir" || return 1
  printf -v dest '%s/%s-%s.json' "$dest_dir" "$(rein_iso_stamp_for_filename)" "$(rein_nonce)"
  mv "$MARKER_FILE" "$dest" 2>/dev/null || return 1
  CLAIMED_MARKER="$dest"
}

# Confirm the archive destination is usable **before moving anything**. A marker that has been
# accepted is consumed only after the pointer advances (to leave material for a round that dies
# between launch and commit), but launching a successor while the destination is unusable makes
# the handover succeed while the marker never gets consumed, and the same judgment recurs forever.
# The move itself happens in a later stage -- this only confirms the location's shape.
# 0=usable / 1=unusable
ensure_archive_dest() {
  local dest_dir="$RUNTIME_DIR/$1"
  mkdir -p "$dest_dir" || return 1
  [ -w "$dest_dir" ] || return 1
  return 0
}

# Whether accepted or rejected, the marker is archived and consumed either way (leaving it would
# make the same judgment recur forever). The archived name is built from **just a timestamp and a
# nonce**. Second-precision timestamps alone let two entries in the same second overwrite each
# other, hence mixing in a nonce, but **never put the externally-sourced `session_id` in the
# name** -- an ID containing a path separator would make `mv`'s destination point somewhere else,
# dropping the archive (and, if an intermediate directory happens to exist, writing outside the
# location while still reporting success). The ID is already in the marker's JSON and the handover
# log, so dropping it from the filename does not make it untraceable later.
archive_marker() {
  local dir_name="$1" dest_dir dest
  [ -n "$CLAIMED_MARKER" ] || return 1
  dest_dir="$RUNTIME_DIR/$dir_name"
  mkdir -p "$dest_dir" || return 1
  printf -v dest '%s/%s-%s.json' "$dest_dir" "$(rein_iso_stamp_for_filename)" "$(rein_nonce)"
  mv "$CLAIMED_MARKER" "$dest" || return 1
  CLAIMED_MARKER="$dest"
}

# Build a **single object** that layers the two things rein needs for launch on top of the
# caller's settings (a file path or a JSON string, either works). `--settings` passed twice means
# **the later one wins outright** (measured: the earlier one is dropped entirely), so the caller's
# settings and rein's cannot be laid side by side -- they have to be merged.
#
# Only these two get layered in:
#   (1) `worktree.bgIsolation = "none"` -- if the background session rein launches branches into
#       `.claude/worktrees/`, both the successor's edits and the lineage records fall outside the
#       main tree (regardless of the caller's settings).
#   (2) the managed-marker env -- lets hooks confirm the lineage in O(1) without re-deriving it
#       from cwd. **Cannot be delivered via the launch command's environment** (measured: a
#       background session's hook process inherits its environment from the shared background
#       service, so env set after the fact on a later-launched session never arrives). settings'
#       env takes effect per session (measured), so it goes here instead. It carries not just cwd
#       and the runtime directory but **lineage context that cannot be derived from cwd** (the
#       user-scoped config and the records location). A lineage rooted with `--root` has these two
#       differ from the default, and since the hook cannot re-derive them from the process
#       environment, omitting them means the root lineage's hook reads the default config and
#       writes records under `<cwd>/.rein/`.
# 0=built (in MANAGED_SETTINGS_FILE) / 1=cannot build (reason in MANAGED_SETTINGS_ERROR)
MANAGED_SETTINGS_FILE=""
MANAGED_SETTINGS_ERROR=""

# The grace period for the successor's SessionStart to delete the temporary launch settings --
# the one observable proof that the managed marker actually reached it (see
# wait_for_managed_settings_drop).
# **A guardrail, not a target**: on a healthy launch the file is already gone by the time the
# launch is confirmed, so the wait ends on its first check and this value is never spent. It is
# only ever consumed on the failing path, which is why it is set generously rather than tightly:
# 10 seconds is two of the default polling intervals, leaving a hook that is merely slow on a
# loaded machine enough room not to be misread as a marker that never arrived.
# The override point exists **only so selftest can measure this wait running out** without
# spending the real grace period in every run (the same shape as the other selftest override
# points -- the judging logic itself is never swapped).
MANAGED_SETTINGS_DROP_SEC="${REIN_MANAGED_SETTINGS_DROP_SEC:-10}"

build_managed_settings() {
  local file trimmed merged rc filter
  local -a jq_args
  MANAGED_SETTINGS_FILE=""
  MANAGED_SETTINGS_ERROR=""
  # The value being carried only means anything as an absolute path (the receiving hook runs with
  # a different cwd). Surface being unable to pass it before launch rather than passing it
  # relative.
  case "$REIN_CONFIG_USER_FILE" in
    /*) ;;
    *)
      printf -v MANAGED_SETTINGS_ERROR 'the lineage config is not an absolute path (cannot put it in the managed marker): %s' \
        "${REIN_CONFIG_USER_FILE:-(none)}"
      return 1
      ;;
  esac
  case "$RECORDS_DIR" in
    /*) ;;
    *)
      printf -v MANAGED_SETTINGS_ERROR 'the lineage records location is not an absolute path (cannot put it in the managed marker): %s' \
        "${RECORDS_DIR:-(none)}"
      return 1
      ;;
  esac
  # The lineage token the successor's hooks will be checked against. It is **read**, never drawn
  # here: the one place that draws it is the layer that provisions the runtime directory (run at
  # this watcher's own startup), so every generation of a lineage carries the same value and no
  # second writer of the token exists. A lineage with no readable token cannot launch a session
  # whose hooks would work, so this fails before the launch rather than handing over a marker
  # that is going to fail loud in the successor.
  if ! rein_read_runtime_token "$RUNTIME_DIR"; then
    printf -v MANAGED_SETTINGS_ERROR 'cannot read this lineage token (cannot put it in the managed marker): %s' \
      "$REIN_RUNTIME_ERROR"
    return 1
  fi
  file="$RUNTIME_DIR/${REIN_MANAGED_SETTINGS_PREFIX}$(rein_nonce).json"
  # shellcheck disable=SC2016  # jq program body (do not let the shell expand it)
  filter='if ($base | type) != "object" then error("not-object") else
      $base
      | .worktree = ((.worktree // {}) | .bgIsolation = "none")
      | .env = ((.env // {})
                + {($k_managed): "1", ($k_cwd): $cwd, ($k_runtime): $runtime, ($k_file): $file,
                   ($k_config): $config, ($k_records): $records, ($k_token): $token})
    end'
  # Build the managed-marker names and values in one place (writing the same columns separately
  # per input shape would let an added key land on only some of them).
  # The token rides along as one more `--arg`, exactly like the other values. It reaches the
  # successor only through the launch settings file (0600), never through the launch command's
  # own arguments -- which is the property that matters, since that command line is what the
  # settings value is deliberately kept out of.
  jq_args=(
    --arg k_managed "$REIN_MANAGED_ENV_NAME" --arg k_cwd "$REIN_MANAGED_CWD_ENV_NAME"
    --arg k_runtime "$REIN_MANAGED_RUNTIME_ENV_NAME" --arg k_file "$REIN_MANAGED_SETTINGS_ENV_NAME"
    --arg k_config "$REIN_MANAGED_CONFIG_ENV_NAME" --arg k_records "$REIN_MANAGED_RECORDS_ENV_NAME"
    --arg k_token "$REIN_MANAGED_TOKEN_ENV_NAME"
    --arg cwd "$TARGET_CWD" --arg runtime "$RUNTIME_DIR" --arg file "$file"
    --arg config "$REIN_CONFIG_USER_FILE" --arg records "$RECORDS_DIR"
    --arg token "$REIN_RUNTIME_TOKEN"
  )
  trimmed="${CLAUDE_SETTINGS#"${CLAUDE_SETTINGS%%[![:space:]]*}"}"
  # Judge whether it is JSON only after skipping leading whitespace (the settings value is taken
  # verbatim, so ` {"..."}` should still pass). Treating that shape as a file path would put the
  # value in the "file not found" reason -- exposing the value of a key that may hold a secret in
  # both the terminal and the log.
  case "$trimmed" in
    '')
      merged="$(jq -nc --argjson base '{}' "${jq_args[@]}" "$filter" 2>/dev/null)"
      rc=$?
      ;;
    '{'*)
      merged="$(jq -nc --argjson base "$trimmed" "${jq_args[@]}" "$filter" 2>/dev/null)"
      rc=$?
      ;;
    *)
      if [ ! -f "$trimmed" ]; then
        rein_config_get_hint "$REIN_BIN" settings "$TARGET_CWD"
        MANAGED_SETTINGS_ERROR="settings cannot be interpreted as a file path or as JSON (${REIN_CONFIG_GET_HINT})"
        return 1
      fi
      merged="$(jq -c --slurpfile _ /dev/null "${jq_args[@]}" \
        '. as $base | '"$filter" "$trimmed" 2>/dev/null)"
      rc=$?
      ;;
  esac
  if [ "$rc" -ne 0 ] || [ -z "$merged" ]; then
    rein_config_get_hint "$REIN_BIN" settings "$TARGET_CWD"
    MANAGED_SETTINGS_ERROR="cannot read settings as a JSON object (cannot build the launch settings. ${REIN_CONFIG_GET_HINT})"
    return 1
  fi
  # The location is this run's own runtime directory (ownership already checked).
  # **Create-exclusive** plus 0600 = never write to an existing file or a symlink (settings can
  # contain credentials).
  if [ -e "$file" ] || [ -L "$file" ]; then
    MANAGED_SETTINGS_ERROR="the launch settings location is already occupied: ${file}"
    return 1
  fi
  if ! (
    umask 077
    set -o noclobber
    printf '%s\n' "$merged" >"$file"
  ) 2>/dev/null; then
    MANAGED_SETTINGS_ERROR="cannot write the launch settings: ${file}"
    return 1
  fi
  MANAGED_SETTINGS_FILE="$file"
  return 0
}

launch_successor() {
  local name="$1" kickoff="$2" rc
  local -a args
  # Advance the heartbeat before the launch. Everything from here to the CLI returning runs in the
  # foreground -- reading the managed policy, building the launch settings, and `claude --bg`
  # itself, which the capped runner lets take up to `cmd_timeout_sec` -- and **nothing writes the
  # heartbeat while they run**. The wait loops on either side of this write it every cycle, so
  # this was the one stretch of a handover where it stood still, and it can outlast
  # `seat_heartbeat_max_age_sec`: a seat waiting on this very handover then reads a normally
  # processing watcher as stopped and steps down, telling the user to run `rein up` again
  # (contract: docs/spec/runtime.md, "The watcher's heartbeat").
  # A heartbeat that cannot be written is a stage failure, the same as in the wait loops -- its
  # own return code, so the caller does not read it as a CLI exit code.
  write_heartbeat || return 92
  # The check for whether managed settings are forced runs through the shared library's judgment
  # (the same one `rein up` / `rein doctor` use). A round where it cannot be judged (unreadable,
  # broken) **launches anyway, with a warning**. The reason for not refusing is written verbatim
  # at the top of the shared judgment. This is delivered differently than `rein up` because the
  # watcher runs as a daemon and its stderr is discarded -- being unable to read it only reaches
  # the user through the watcher log and a GUI notification.
  rein_managed_policy_conflicts
  rc=$?
  if [ "$rc" -eq 1 ]; then
    printf '%s: %s\n' "$SCRIPT_NAME" "$REIN_MANAGED_POLICY_ERROR" >&2
    return 90
  fi
  if [ "$rc" -eq 2 ]; then
    wlog "$REIN_MANAGED_POLICY_ERROR"
    rein_notify "rein: cannot judge whether isolation is enforced" "$REIN_MANAGED_POLICY_ERROR"
  fi
  if ! build_managed_settings; then
    printf '%s: %s\n' "$SCRIPT_NAME" "$MANAGED_SETTINGS_ERROR" >&2
    return 91
  fi
  args=(--bg --name "$name" --settings "$MANAGED_SETTINGS_FILE")
  # Only a lineage that wants to pin the model across generations specifies this (empty follows
  # the CLI's default).
  if [ -n "$CLAUDE_MODEL" ]; then
    args+=(--model "$CLAUDE_MODEL")
  fi
  args+=("$kickoff")
  # Call it with a cap. --bg is meant to return immediately, but if it does not, an unattended
  # watcher would hang forever.
  # **Drop every REIN_-namespaced env var here** (assembled by the shared library's one function).
  # The managed session's context is carried through the launch settings' `env`
  # (`REIN_MANAGED_*`), so dropping it here does not break resolution on the successor's side.
  rein_env_drop_args
  (cd "$TARGET_CWD" && rein_run_capture "$CMD_TIMEOUT_SEC" \
    env "${REIN_ENV_DROP_ARGS[@]+"${REIN_ENV_DROP_ARGS[@]}"}" claude "${args[@]}" >/dev/null)
  rc=$?
  # For a round where the launch itself failed, no one deletes the temp settings, since the
  # successor's SessionStart never comes. As a trace of it never having come up, the launch
  # failure reason remains, so the cleanup happens here.
  if [ "$rc" -ne 0 ]; then
    rm -f "$MANAGED_SETTINGS_FILE" 2>/dev/null
  fi
  return "$rc"
}

# 0=identified (session ID on stdout) / 1=expired / 2=cannot read the list / 3=multiple candidates
# 4=cannot write the heartbeat
# Treating "cannot read" the same as "not present yet" would keep silently waiting up to the cap
# even when the CLI is broken, and finally fail with a message ("did not appear after N seconds")
# that misattributes the cause.
wait_for_successor() {
  local name="$1" since_ms="$2" before="$3" deadline now found rc
  # Measure the deadline with a monotonic clock (a wall clock would let a mid-run time
  # adjustment stretch or shrink the cap).
  deadline="$(($(rein_now_monotonic) + LAUNCH_TIMEOUT_SEC))"
  while :; do
    found="$(find_successor_session_id "$name" "$since_ms" "$before")"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      printf '%s\n' "$found"
      return 0
    fi
    if [ "$rc" -eq 2 ]; then
      return 2
    fi
    if [ "$rc" -eq 3 ]; then
      return 3
    fi
    now="$(rein_now_monotonic)"
    # Treat exactly hitting the deadline as expired too (using `>` would stretch the cap by one
    # polling interval).
    if [ "$now" -ge "$deadline" ]; then
      return 1
    fi
    # Keep advancing the heartbeat while a handover is in progress (stopping here would let a
    # waiting seat see the heartbeat go stale and wrongly sound "the watcher may have stopped").
    # If it can no longer be written, treat that as a stage failure just like the watch loop
    # (the caller records the reason).
    if ! write_heartbeat; then
      return 4
    fi
    rein_sleep_capped "$POLL_INTERVAL_SEC" "$((deadline - now))"
  done
}

# The kickoff communicates only "which document to read", "how much of it to read", and "the one
# command line to run when it is your turn to request a handover". Making the successor reproduce
# the contract (schema, timestamp format, atomic write) from natural-language prose gets the
# successor's own handover request rejected.
# Do not pad it with extra material (a transcript path and the like) -- the amount the successor
# reads on its first turn is a fixed cost of every handover, and whatever gets included gets read.
# kickoff_note_path only "points to where it lives, in one line" -- its contents are never read
# (rein does not know a project's semantics, so it never carries free-form text as config).
# The no-canonical-document branch (below, the placeholder and "Start work as this project's
# primary session.") still gets reached even after a default handoff document exists -- it is for a lineage where
# config explicitly sets `handoff_path` to empty, and a selftest exercises that path (it is not
# dead code left in place).
build_kickoff() {
  local handoff="$1" head request_cmd handoff_arg note=""
  # Only quote the placeholder that gets replaced (the spot where the successor fills in its own
  # value). A real path is shell-escaped and carried as one token (a path containing whitespace,
  # `;`, or `$( )` would split the argument or get evaluated).
  handoff_arg="<absolute path to the handoff document>"
  if [ -n "$handoff" ]; then
    handoff_arg="$(rein_shell_quote "$handoff")"
  fi
  # Fill the lineage naming (`--root` / `--runtime-dir`) into the effective values so the one-line
  # instructions do not point at a different lineage. **Build it through the same shared function**
  # too (only the verb's suffix is added here) so the same instructions the Stop hook gives for
  # the same operation do not split into two forms.
  rein_lineage_cmd "$REIN_BIN" "$RUNTIME_DIR" "$RECORDS_DIR" "$TARGET_CWD" request \
    "--session-id <your session ID> --handoff ${handoff_arg}"
  request_cmd="$REIN_LINEAGE_CMD"
  if [ -n "$handoff" ]; then
    printf -v head 'You are taking over from a predecessor session. First read the handoff document at %s, then resume work from the "Where things stand" and "Next steps" it records. This is the only handoff document -- do not look for others. Read only the sections you need to resume, and do not re-read it in full or pre-read related documents.' "$handoff"
  else
    head="Start work as this project's primary session."
  fi
  if [ -n "$KICKOFF_NOTE_PATH" ]; then
    printf -v note ' Supplementary notes for this project live at %s (open it only if you need it).' "$KICKOFF_NOTE_PATH"
  fi
  # Separate the command with newlines on both sides (with a sentence attached directly after it,
  # the successor has no way to determine where the command literally ends, and would run it with
  # the trailing punctuation included as part of the path, stalling the handover at that
  # generation). The literal space in the format string is what keeps this sentence from running
  # into the previous one (`note` is either empty or already carries its own leading space).
  printf '%s%s %s\n%s\n%s' "$head" "$note" \
    "When it is your turn to request a handover, run the following line exactly as-is (do not write the handover request JSON yourself):" \
    "$request_cmd" \
    "After you run it, the watcher will launch your successor, so do not start new work until instructed."
}

# 0=exit confirmed / 1=expired, still present / 2=listing failed / 4=cannot write the heartbeat
# 5=the predecessor is still present, but the successor has vanished from the listing (must not step it down)
# The third argument (the successor's session_id) is read from **the same single listing call** as
# the predecessor's liveness -- reading them separately would turn into "the predecessor is
# present and so is the successor" on a transient change or a one-off failure in between, and let
# a stop through that leaves zero live sessions.
wait_for_exit() {
  local session_id="$1" timeout="$2" successor="${3:-}" deadline now rc agents
  # Measure the deadline with a monotonic clock (a wall clock would let a mid-run time adjustment
  # stretch or shrink the cap).
  deadline="$(($(rein_now_monotonic) + timeout))"
  while :; do
    agents="$(rein_list_agents)"
    rein_is_session_live "$session_id" "$agents"
    rc=$?
    if [ "$rc" -eq 1 ]; then
      return 0
    fi
    if [ "$rc" -eq 2 ]; then
      return 2
    fi
    # Reaching here means only "the predecessor is still present" -- the judgment about to step it
    # down. Run it through the same one function (rein_agents_has_live) as the startup adoption
    # path (rein_stranded_predecessor) -- do not let how strict "the successor is present" is
    # split into two forms between the main path and the recovery path.
    if [ -n "$successor" ] && ! rein_agents_has_live "$agents" "$successor"; then
      return 5
    fi
    now="$(rein_now_monotonic)"
    # Treat exactly hitting the deadline as expired too (using `>` would sleep once even with zero
    # grace left, stretching the cap by one polling interval). The extra time would disagree with
    # the math the seat's watchdog uses (grace + external-command cap + stop-confirmation cap),
    # producing a false alarm while the watcher is normally processing.
    if [ "$now" -ge "$deadline" ]; then
      return 1
    fi
    # Keep advancing the heartbeat while a handover is in progress. If it can no longer be
    # written, treat that as a stage failure just like the watch loop (the caller records the
    # reason).
    if ! write_heartbeat; then
      return 4
    fi
    rein_sleep_capped "$POLL_INTERVAL_SEC" "$((deadline - now))"
  done
}

# Whether a handover marker's contents (the ready marker, the cancel marker) belong to this
# request. The content is a single line, session_id, so if the writer has only written half a
# partial line, it reads as "does not match" and the complete line is read on the next cycle
# (falls safe).
# **Only markers that pass this judgment are used as material** -- a marker left over from a
# previous handover is skipped (there is no cleanup stage before entering the wait: both are
# removed unconditionally on the way out regardless of a match, so cleaning up beforehand would
# not change anything).
handover_mark_is() {
  local file="$1" session_id="$2" line=""
  [ -f "$file" ] || return 1
  # **Do not collapse "not placed" and "cannot be confirmed" into the same fall-through.**
  # Silently treating an unreadable marker as "does not match" sends the ready marker down to
  # stage 1's cap expiring loudly, but **the cancel marker gets silently ignored** -- the handover
  # proceeds in silence even though the user spoke up. Fall safe (does not match) either way,
  # but leave a trace in the watcher log that it could not be read. A half-written line is caught
  # by the match below, not here (the complete line is read on the next cycle).
  if [ ! -r "$file" ]; then
    wlog "cannot read the handover marker (treating it as not matching): ${file}"
    return 1
  fi
  # A partial line with no trailing newline makes `read` return non-zero even though the content
  # was read -- pass it through to the match as-is (this is a normal mid-write state; the complete
  # line reads on the next cycle).
  IFS= read -r line <"$file" 2>/dev/null
  [ "$line" = "$session_id" ]
}

# Before launching the successor, wait for the session that requested the handover to finish
# printing its response. That session keeps writing its turn's wrap-up and report even after
# issuing the request, so proceeding without waiting would let the predecessor get stopped
# externally before the user ever reads it.
# Two stages: (1) wait for the "response finished" marker up to `final_output_timeout_sec`,
# (2) once the marker is observed, push the deadline out to "the observed time +
# `final_output_wait_sec`", and cancel if the user speaks up within that window.
# **The cap is split into two** because folding it into one would tie the wait for the marker to
# stage 2's short wait, and a round that writes a long wrap-up after the request (exactly the
# scenario this mechanism targets) would fail to wait long enough for the marker.
# Shaped like the other waits: monotonic-clock deadline, write_heartbeat every cycle, never sleeps
# past the deadline.
# 0=observed the marker and finished waiting / 1=stage 1's cap hit with no marker /
# 2=observed the cancel marker / 4=cannot write the heartbeat
wait_for_final_output() {
  local session_id="$1" deadline now stage=1 rc=0 mark
  # Measure the deadline with a monotonic clock (a wall clock would let a mid-run time adjustment
  # stretch or shrink the cap).
  deadline="$(($(rein_now_monotonic) + FINAL_OUTPUT_TIMEOUT_SEC))"
  while :; do
    # In either stage, **check the cancel marker first, every cycle** (a cancel wins over a
    # ready marker). The marker can be placed at a time not necessarily inside this window, so
    # this check on the very first cycle of the wait also catches "a marker placed before the
    # window".
    if handover_mark_is "$HANDOVER_CANCEL_FILE" "$session_id"; then
      rc=2
      break
    fi
    if [ "$stage" -eq 1 ] && handover_mark_is "$HANDOVER_READY_FILE" "$session_id"; then
      stage=2
      deadline="$(($(rein_now_monotonic) + FINAL_OUTPUT_WAIT_SEC))"
    fi
    now="$(rein_now_monotonic)"
    # Treat exactly hitting the deadline as expired too (using `>` would stretch the cap by one
    # polling interval).
    if [ "$now" -ge "$deadline" ]; then
      [ "$stage" -eq 1 ] && rc=1
      break
    fi
    # Keep advancing the heartbeat while a handover is in progress (stopping here would let a
    # waiting seat see the heartbeat go stale and wrongly sound "the watcher may have stopped").
    # If it can no longer be written, treat that as a stage failure just like the other waits
    # (the caller records the reason).
    if ! write_heartbeat; then
      rc=4
      break
    fi
    rein_sleep_capped "$POLL_INTERVAL_SEC" "$((deadline - now))"
  done
  # On the way out, delete both regardless of the result (not conditioned on a match -- never
  # carry either into the next handover; this one spot is why no cleanup is needed before entering
  # the wait). **Failing to delete is never silently let through** -- a leftover cancel marker
  # would match on the very first cycle of the next handover and cancel it even though the
  # user never spoke up this time. The handover itself proceeds regardless (the outcome is
  # already decided at this point), so leave just one line in the watcher log.
  for mark in "$HANDOVER_READY_FILE" "$HANDOVER_CANCEL_FILE"; do
    [ -e "$mark" ] || continue
    rm -f "$mark" 2>/dev/null
    [ -e "$mark" ] || continue
    wlog "cannot delete the handover marker (the next handover may read this marker): ${mark}"
  done
  return "$rc"
}

# The shape where the successor had already disappeared by the time the predecessor was about to
# be stepped down. **Report it and stop, without fixing it** -- do not relaunch the successor, do
# not roll back the pointer, and do not stop the still-live predecessor (stopping it would take
# live sessions to zero). The one sentence the user reads runs through **the same one** as the
# startup adoption path and doctor -- so the same state is called by the same name wherever it is
# seen. If the watcher from that round left the reason the successor went down in the handover
# log, attach it verbatim (the common case reaching here has no such text on record, so it falls
# through to instructions on where to look).
fail_successor_gone() {
  local generation="$1" predecessor="$2" successor="$3" detail
  detail="$(rein_handover_mismatch_detail "$REIN_BIN" "$successor" "$predecessor" "$TARGET_CWD" \
    "$(handover_failure_cause "$successor")" "$RUNTIME_DIR" "$RECORDS_DIR")"
  fail_stage "confirming the successor is alive before stepping the predecessor down" "$detail" "$generation" "$predecessor" "$successor"
  return 1
}

# The stage that steps the predecessor down (confirm exit within the grace period -> external stop
# if it is still there -> confirm the stop). The predecessor has no means of self-termination
# (measured). If it is gone within the grace period, confirming is enough; if it is still there,
# stop it externally -- waiting long here matters because attach only returns once the predecessor
# stops, so the seat stays vacant for the whole grace period without switching to the successor.
# Both the main handover path and the startup resume (a lineage where only this stage was left
# behind) go through **the same one** -- do not let how strict the stop is split into two forms.
# **Also confirm the successor is alive before stepping the predecessor down.** A successor that
# dies right after its launch is confirmed (a usage cap, an expired credential) does happen in
# practice, and externally stopping the predecessor there would take **live sessions to zero**,
# while handover_completed still gets recorded, making the audit trail look like a normal handover
# (the same loss the startup adoption path names -- only the main path was missing this guard).
# 0=the predecessor is gone / 1=stage failure (reason already recorded by fail_stage)
retire_predecessor() {
  local generation="$1" predecessor="$2" successor_id="$3"
  local exit_rc stop_handle handle_rc stop_rc stop_wait_rc detail
  wait_for_exit "$predecessor" "$EXIT_GRACE_SEC" "$successor_id"
  exit_rc=$?
  case "$exit_rc" in
    0)
      rein_log_event "$LOG_FILE" "predecessor_exited" "exit confirmed within the grace period" "$generation" "$predecessor" "$successor_id"
      return 0
      ;;
    2)
      fail_stage "confirming the predecessor's exit" "$(rein_list_agents_error)" "$generation" "$predecessor" "$successor_id"
      return 1
      ;;
    4)
      fail_heartbeat "$generation" "$predecessor" "$successor_id"
      return 1
      ;;
    5)
      fail_successor_gone "$generation" "$predecessor" "$successor_id"
      return 1
      ;;
  esac
  # The same stretch as the launch: from here to the stop confirmation, external commands run in
  # the foreground -- the enumeration that resolves the job handle, then `claude stop` -- and
  # nothing else writes the heartbeat while they do. wait_for_exit above returns on the cycle it
  # hits its deadline **without** writing, so without these the heartbeat would already be one
  # poll old when this stretch starts. One write before each blocking call.
  if ! write_heartbeat; then
    fail_heartbeat "$generation" "$predecessor" "$successor_id"
    return 1
  fi
  # What the stop is handed is the short job ID resolved from the listing (the CLI does not
  # accept the full session_id).
  stop_handle="$(rein_resolve_job_handle "$predecessor")"
  handle_rc=$?
  if [ "$handle_rc" -eq 3 ]; then
    # An interactive session has no short job ID -- it cannot be the target of claude stop (measured).
    printf -v detail 'an interactive session cannot be stopped externally (did not exit within the %s-second grace period): %s' \
      "$EXIT_GRACE_SEC" "$predecessor"
    fail_stage "stopping the predecessor" "$detail" "$generation" "$predecessor" "$successor_id"
    return 1
  fi
  if [ "$handle_rc" -ne 0 ]; then
    detail="$(rein_job_handle_error "$predecessor" "$handle_rc")"
    fail_stage "stopping the predecessor" "$detail" "$generation" "$predecessor" "$successor_id"
    return 1
  fi
  if ! write_heartbeat; then
    fail_heartbeat "$generation" "$predecessor" "$successor_id"
    return 1
  fi
  (cd "$TARGET_CWD" && rein_run_capture "$CMD_TIMEOUT_SEC" claude stop "$stop_handle" >/dev/null)
  stop_rc=$?
  if [ "$stop_rc" -ne 0 ]; then
    printf -v detail 'claude stop exited non-zero: %s' "$(rein_command_failure_detail "$stop_rc")"
    fail_stage "stopping the predecessor" "$detail" "$generation" "$predecessor" "$successor_id"
    return 1
  fi
  # Do not collapse "cannot read the listing (undetermined)" into "stopping did not make it go
  # away". Collapsing them would record and notify a broken CLI as a different cause (the external
  # stop not taking effect).
  # The successor is not checked here (the third argument is not passed) -- what is being guarded
  # is the "whether to stop" judgment, and the stop has already been issued. Stepping down here
  # over the successor's absence would leave predecessor_stopped unrecorded for a stop that
  # actually happened, and the audit would disagree with what really occurred.
  wait_for_exit "$predecessor" "$STOP_TIMEOUT_SEC"
  stop_wait_rc=$?
  if [ "$stop_wait_rc" -eq 2 ]; then
    printf -v detail '%s (while confirming exit after the external stop)' "$(rein_list_agents_error)"
    fail_stage "confirming the predecessor's stop" "$detail" "$generation" "$predecessor" "$successor_id"
    return 1
  fi
  if [ "$stop_wait_rc" -eq 4 ]; then
    fail_heartbeat "$generation" "$predecessor" "$successor_id"
    return 1
  fi
  if [ "$stop_wait_rc" -ne 0 ]; then
    printf -v detail 'still present %s seconds after claude stop' "$STOP_TIMEOUT_SEC"
    fail_stage "confirming the predecessor's stop" "$detail" "$generation" "$predecessor" "$successor_id"
    return 1
  fi
  printf -v detail 'did not exit within the %s-second grace period, so it was stopped externally' "$EXIT_GRACE_SEC"
  rein_log_event "$LOG_FILE" "predecessor_stopped" "$detail" "$generation" "$predecessor" "$successor_id"
  return 0
}

# Keep the stage that writes the current pointer forward in one place (the main handover path and
# the adoption of a round that died between launch and commit write the same shape -- do not split
# the pointer's writer into two).
# 0=written / 1=cannot write
write_pointer() {
  local generation="$1" successor_id="$2" successor_name="$3" predecessor="$4" handoff="$5"
  local pointer_json
  pointer_json="$(jq -nc \
    --arg schema "$REIN_POINTER_SCHEMA" \
    --arg session_id "$successor_id" \
    --arg session_name "$successor_name" \
    --arg cwd "$TARGET_CWD" \
    --arg updated_at "$(rein_iso_now)" \
    --arg predecessor "$predecessor" \
    --arg handoff_path "$handoff" \
    --argjson generation "$generation" \
    '{
      schema: $schema,
      session_id: $session_id,
      session_name: $session_name,
      cwd: $cwd,
      generation: $generation,
      updated_at: $updated_at,
      predecessor_session_id: (if $predecessor == "" then null else $predecessor end),
      handoff_path: (if $handoff_path == "" then null else $handoff_path end)
    }')"
  rein_write_json_atomic "$POINTER_FILE" "$pointer_json" || return 1
  rein_log_event "$LOG_FILE" "pointer_updated" "$successor_id" "$generation" "$predecessor" "$successor_id"
  return 0
}

# Add "the successor launched on this attempt" to the handover request marker. Launching the
# successor and updating the pointer are not atomic, so if the watcher dies in that gap, nothing
# anywhere records whether "it launched but the pointer has no target" or "it never launched at
# all" (the marker is consumed at acceptance and the pointer does not exist yet). A watcher that
# comes back reads this field, completes the handover if the successor is alive, and leaves a
# reason if it is gone. **A marker without this field is reclaimed as "unknown", the same as
# before** -- migrating markers placed before this version is not required.
# Writing the name first before launch and adding the ID once identified is two separate steps so
# that being unable to write surfaces **before launch** (finding out after launch that it cannot
# be written is too late to undo).
# 0=written (including a bootstrap with no marker) / 1=cannot write
record_launch_attempt() {
  local successor_name="$1" successor_id="$2" marker_json
  [ -n "$CLAIMED_MARKER" ] || return 0
  [ -f "$CLAIMED_MARKER" ] || return 0
  marker_json="$(jq -c \
    --arg name "$successor_name" \
    --arg sid "$successor_id" \
    --arg at "$(rein_iso_now)" \
    '. + {launch_attempt: {
       successor_name: $name,
       launched_at: $at,
       successor_session_id: (if $sid == "" then null else $sid end)
     }}' "$CLAIMED_MARKER" 2>/dev/null)"
  [ -n "$marker_json" ] || return 1
  rein_write_json_atomic "$CLAIMED_MARKER" "$marker_json"
}

# Clean up a successor this run launched, for a round where the handover did not go through. Stop
# **only the one that could be identified**; a candidate that cannot be identified is left alone,
# named, and not stopped ("what cannot be confirmed is never seized"). Exiting without doing
# anything would leave a background session the pointer does not point to sitting in the same
# working tree -- the kickoff instructs "Start work as this project's primary session.", so the
# two could edit the same tree.
# Identification is redone from scratch -- even a round where the launch-confirmation step fell
# through with "cannot read the listing", it can still be stepped down if the listing has come
# back by now (never decide permanently based on whether it was possible at the moment it failed).
# Never notify here **as the last word** (the caller goes on to notify about the stage failure --
# what the user sees last should be that round's actual cause).
# 0=nothing left behind (stopped it, or it never launched) / 1=left unmanaged
abandon_launched_successor() {
  local generation="$1" successor_name="$2" since_ms="$3" before="$4" predecessor="$5" successor="$6"
  local rc detail reason handle
  if [ -z "$successor" ]; then
    successor="$(find_successor_session_id "$successor_name" "$since_ms" "$before")"
    rc=$?
    case "$rc" in
      0) ;;
      1)
        # It never made it to launch -- there is no one to clean up.
        return 0
        ;;
      2) reason="cannot read the listing, so the launched successor cannot be identified" ;;
      *) reason="multiple candidates with the same name and cwd, so which one is the successor cannot be decided" ;;
    esac
    if [ "$rc" -ne 0 ]; then
      printf -v detail 'did not stop the launched successor (%s). The pointer never advanced, so this launch may remain unmanaged in the same working tree: name=%s. Check for a background session with that name via claude agents --json, and stop any extra one with claude stop' \
        "$reason" "$successor_name"
      rein_log_event "$LOG_FILE" "successor_orphaned" "$detail" "$generation" "$predecessor" ""
      wlog "$detail"
      rein_notify "rein: a launched successor was left unmanaged" "$detail"
      return 1
    fi
  fi
  handle="$(rein_resolve_job_handle "$successor")"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf -v detail 'cannot step down the launched successor (it remains unmanaged in the same working tree): %s' \
      "$(rein_job_handle_error "$successor" "$rc")"
    rein_log_event "$LOG_FILE" "successor_orphaned" "$detail" "$generation" "$predecessor" "$successor"
    wlog "$detail"
    rein_notify "rein: a launched successor was left unmanaged" "$detail"
    return 1
  fi
  (cd "$TARGET_CWD" && rein_run_capture "$CMD_TIMEOUT_SEC" claude stop "$handle" >/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf -v detail 'stopping the launched successor exited non-zero (it remains unmanaged in the same working tree): %s' \
      "$(rein_command_failure_detail "$rc")"
    rein_log_event "$LOG_FILE" "successor_orphaned" "$detail" "$generation" "$predecessor" "$successor"
    wlog "$detail"
    rein_notify "rein: a launched successor was left unmanaged" "$detail"
    return 1
  fi
  rein_log_event "$LOG_FILE" "successor_stopped" \
    "the handover did not go through, so the launched successor was stepped down (do not leave a background session with no pointer to it)" \
    "$generation" "$predecessor" "$successor"
  return 0
}

# Wait for the launched successor to delete the temporary launch settings, and thereby confirm
# that the managed marker reached it.
# **The file's location only ever reaches that session through the managed marker** (the launch
# settings' `env` carries it, and the SessionStart hook deletes exactly the path it reads from
# there). So the file still sitting in the runtime directory once the successor is up means the
# marker never arrived -- and a session without the marker is not visibly broken either: it comes
# up and keeps running normally, it simply gets nothing at all from rein's hooks (they act only on
# a session rein launched). Nothing about the session itself makes that visible, and until now the
# only thing that ever noticed was `rein doctor`, whenever someone happened to run it.
# `MANAGED_SETTINGS_FILE` is always set here: `build_managed_settings` assigns it before anything
# can fail, and a round that could not build it never reaches this point (launch_successor returns
# 91 and the caller stops there).
# Shaped like the other waits: monotonic-clock deadline, write_heartbeat every cycle, never sleeps
# past the deadline.
# 0=the marker arrived (the settings are gone) / 1=still there when the grace period ran out /
# 4=cannot write the heartbeat
wait_for_managed_settings_drop() {
  local deadline now
  # Measure the deadline with a monotonic clock (a wall clock would let a mid-run time adjustment
  # stretch or shrink the grace period).
  deadline="$(($(rein_now_monotonic) + MANAGED_SETTINGS_DROP_SEC))"
  while :; do
    # Checked before anything else on every cycle, so the healthy case (already deleted) returns
    # without ever sleeping.
    [ -e "$MANAGED_SETTINGS_FILE" ] || return 0
    now="$(rein_now_monotonic)"
    # Treat exactly hitting the deadline as expired too (using `>` would stretch the grace period
    # by one polling interval).
    if [ "$now" -ge "$deadline" ]; then
      return 1
    fi
    # Keep advancing the heartbeat while a handover is in progress (stopping here would let a
    # waiting seat see the heartbeat go stale and wrongly sound "the watcher may have stopped").
    if ! write_heartbeat; then
      return 4
    fi
    rein_sleep_capped "$POLL_INTERVAL_SEC" "$((deadline - now))"
  done
}

# Launch the successor, confirm the launch, and advance the pointer. On success, SUCCESSOR_ID
# holds the session ID.
# The main handover path and bootstrap go through the same procedure (so how strict launch
# confirmation is does not split into two forms).
# **Every failure after the launch goes through cleaning up the successor** (launching and
# committing are not atomic, so exiting partway through would leave a background session with no
# target).
launch_and_point() {
  local generation="$1" successor_name="$2" kickoff="$3" predecessor="$4" handoff="$5"
  local since_ms before detail rc

  SUCCESSOR_ID=""
  before="$(snapshot_session_ids)"
  if [ -z "$before" ]; then
    printf -v detail '%s (cannot confirm who was present before launch)' "$(rein_list_agents_error)"
    fail_stage "listing before launching the successor" "$detail" "$generation" "$predecessor"
    return 1
  fi

  # Leave the launch declaration before launching (finding out after launch that it cannot be
  # written is too late to undo).
  if ! record_launch_attempt "$successor_name" ""; then
    printf -v detail 'cannot write the successor about to be launched to the handover request marker (a round that dies mid-launch cannot later confirm whether it launched at all): %s' \
      "$CLAIMED_MARKER"
    fail_stage "recording the launch declaration" "$detail" "$generation" "$predecessor"
    return 1
  fi

  since_ms="$((($(rein_now_epoch) - 2) * 1000))"
  rein_log_event "$LOG_FILE" "successor_launching" "$successor_name" "$generation" "$predecessor" ""
  launch_successor "$successor_name" "$kickoff"
  rc=$?
  # A round that stopped before even entering the launch (isolation forced, cannot build launch
  # settings) is never read as a CLI exit code -- misattributing the cause would send the fix to
  # the wrong place.
  if [ "$rc" -eq 90 ]; then
    fail_stage "launching the successor" "$REIN_MANAGED_POLICY_ERROR" "$generation" "$predecessor"
    return 1
  fi
  if [ "$rc" -eq 91 ]; then
    fail_stage "launching the successor" "$MANAGED_SETTINGS_ERROR" "$generation" "$predecessor"
    return 1
  fi
  # The launch never happened (the heartbeat is written before it), so there is no successor to
  # clean up -- this returns through the same handler the wait loops use.
  if [ "$rc" -eq 92 ]; then
    fail_heartbeat "$generation" "$predecessor"
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    printf -v detail 'claude --bg exited non-zero: %s' "$(rein_command_failure_detail "$rc")"
    # Even on a non-zero exit, the session may have come up before failing (arrived, then died).
    abandon_launched_successor "$generation" "$successor_name" "$since_ms" "$before" "$predecessor" ""
    fail_stage "launching the successor" "$detail" "$generation" "$predecessor"
    return 1
  fi

  SUCCESSOR_ID="$(wait_for_successor "$successor_name" "$since_ms" "$before")"
  rc=$?
  if [ "$rc" -eq 2 ]; then
    printf -v detail '%s (while confirming the successor launched)' "$(rein_list_agents_error)"
    abandon_launched_successor "$generation" "$successor_name" "$since_ms" "$before" "$predecessor" ""
    fail_stage "confirming the successor launched" "$detail" "$generation" "$predecessor"
    return 1
  fi
  if [ "$rc" -eq 3 ]; then
    printf -v detail 'multiple candidates with the same name and cwd appeared after launch: %s' "$successor_name"
    abandon_launched_successor "$generation" "$successor_name" "$since_ms" "$before" "$predecessor" ""
    fail_stage "confirming the successor launched" "$detail" "$generation" "$predecessor"
    return 1
  fi
  if [ "$rc" -eq 4 ]; then
    abandon_launched_successor "$generation" "$successor_name" "$since_ms" "$before" "$predecessor" ""
    fail_heartbeat "$generation" "$predecessor"
    return 1
  fi
  if [ "$rc" -ne 0 ] || [ -z "$SUCCESSOR_ID" ]; then
    printf -v detail 'waited %s seconds and still cannot confirm the launch (no new background session appeared in the listing): %s' \
      "$LAUNCH_TIMEOUT_SEC" "$successor_name"
    abandon_launched_successor "$generation" "$successor_name" "$since_ms" "$before" "$predecessor" ""
    fail_stage "confirming the successor launched" "$detail" "$generation" "$predecessor"
    return 1
  fi
  rein_log_event "$LOG_FILE" "successor_launched" "$successor_name" "$generation" "$predecessor" "$SUCCESSOR_ID"
  # Once identified, add the ID to the declaration. Keep going even if it cannot be written (the
  # declaration stays "unknown", and a recovery pass treats it as unidentified -- it never
  # silently falls through to "complete").
  record_launch_attempt "$successor_name" "$SUCCESSOR_ID" ||
    wlog "cannot write the launched successor's ID to the handover request marker (a recovery pass will treat it as unknown): ${CLAIMED_MARKER}"

  # Confirm the managed marker reached the successor, **before the pointer moves**. Placed here
  # for the same reason the final-output wait is placed before the launch: rein has no way to roll
  # the pointer back, so while it still names the predecessor, cleaning up takes nothing more than
  # the existing abandon path -- after it moves, there would be no way to undo this.
  # Both entry points reach here (the first session's launch and a handover's successor), so
  # neither can start out unmanaged without it being said out loud.
  wait_for_managed_settings_drop
  rc=$?
  if [ "$rc" -eq 4 ]; then
    abandon_launched_successor "$generation" "$successor_name" "$since_ms" "$before" "$predecessor" "$SUCCESSOR_ID"
    # Why nobody is left to delete it is written out in the `rc -ne 0` branch's comment below.
    rm -f "$MANAGED_SETTINGS_FILE" 2>/dev/null
    fail_heartbeat "$generation" "$predecessor" "$SUCCESSOR_ID"
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    # Say explicitly that the session **did** come up -- the launch was already confirmed one step
    # earlier, so a reason that read like a launch failure would send the investigation to the
    # wrong place. What is left behind is exactly one thing: the marker never reached its
    # SessionStart hook.
    printf -v detail 'the successor came up, but the temporary launch settings were still there %s seconds later, so the managed marker never reached its SessionStart hook (that session would have kept running outside rein management, getting nothing at all from the hooks): %s' \
      "$MANAGED_SETTINGS_DROP_SEC" "$MANAGED_SETTINGS_FILE"
    abandon_launched_successor "$generation" "$successor_name" "$since_ms" "$before" "$predecessor" "$SUCCESSOR_ID"
    # Nobody is left to delete it (the session that would have is being stepped down), and leaving
    # it would have the next `doctor` name it under a reason that no longer fits ("the session it
    # launched may never have come up"). The reason itself survives in the handover log above.
    rm -f "$MANAGED_SETTINGS_FILE" 2>/dev/null
    fail_stage "confirming the managed marker reached the successor" "$detail" "$generation" "$predecessor" "$SUCCESSOR_ID"
    return 1
  fi

  if ! write_pointer "$generation" "$SUCCESSOR_ID" "$successor_name" "$predecessor" "$handoff"; then
    abandon_launched_successor "$generation" "$successor_name" "$since_ms" "$before" "$predecessor" "$SUCCESSOR_ID"
    fail_stage "updating the pointer" "cannot write current.json" "$generation" "$predecessor" "$SUCCESSOR_ID"
    return 1
  fi
  return 0
}

# Reclaim markers left behind in `processing/`. The watcher can claim a marker (mv it to
# `processing/`) and then go down on a mechanism failure (the pointer cannot be validated), leaving
# that marker sitting there -- this is by design (never move it to a location that reads as
# "rejected"), but **there was no way to reclaim it**. When the Stop hook finds its own session_id
# inside processing, it reads that as "the handover request has already been submitted" and does
# not hold the stop, so that session is never prompted again even after usage crosses the trigger
# point (neither `prune`'s archive sweep nor `status` looks at processing, so there was no way to
# even notice).
# Reclaiming runs **right after the watcher lock is claimed** -- at that point this is the only
# run advancing this lineage's handover, so anything sitting in processing is by definition leftover
# from a previous round. The reclaim destination is rejected (the place for things that were
# consumed but not accepted), and it is left there rather than deleted -- so what happened can be
# traced later.
# 0=reclaimed (including zero) / 1=cannot reclaim
recover_orphan_processing() {
  local dir="$RUNTIME_DIR/$REIN_PROCESSING_DIRNAME" file dest sid count=0
  local attempt attempt_id attempt_name detail
  [ -d "$dir" ] || return 0
  for file in "$dir"/*.json; do
    [ -f "$file" ] || continue
    sid="$(jq -r --arg s "$REIN_MARKER_SCHEMA" \
      'select(.schema == $s) | .session_id // empty' "$file" 2>/dev/null)"
    # The "the successor launched on this attempt" declaration. A marker without the field at all
    # (placed before this version, or a round that died before reaching launch) is **unknown** --
    # just reclaim it as before.
    attempt="$(jq -r --arg s "$REIN_MARKER_SCHEMA" \
      'select(.schema == $s) | if has("launch_attempt") then "1" else "" end' "$file" 2>/dev/null)"
    attempt_id="$(jq -r --arg s "$REIN_MARKER_SCHEMA" \
      'select(.schema == $s) | .launch_attempt.successor_session_id // empty' "$file" 2>/dev/null)"
    attempt_name="$(jq -r --arg s "$REIN_MARKER_SCHEMA" \
      'select(.schema == $s) | .launch_attempt.successor_name // empty' "$file" 2>/dev/null)"
    detail="reclaimed a handover request that was left behind mid-judgment, into rejected (the previous watcher went down on a stage failure)"
    if [ -n "$attempt" ] && [ -n "$sid" ]; then
      if [ -n "$attempt_id" ]; then
        rein_is_session_live "$attempt_id"
        case $? in
          0)
            adopt_launched_successor "$file" "$sid" "$attempt_id" "$attempt_name" || return 1
            count=$((count + 1))
            continue
            ;;
          2)
            # Silently falling through to "the handover did not go through" when liveness cannot
            # be confirmed would drop a live successor into unmanaged status while letting the
            # next handover through (what cannot be confirmed is never seized).
            printf -v detail 'cannot confirm whether the launched successor %s is alive, so the leftover handover request cannot be processed: %s' \
              "$attempt_id" "$(rein_list_agents_error)"
            fail_stage "reclaiming a leftover handover request" "$detail" "" "$sid" "$attempt_id"
            return 1
            ;;
        esac
        printf -v detail 'the previous handover went down right after launching the successor %s, and that successor is now gone (treating the handover as not having gone through -- please request another handover)' \
          "$attempt_id"
      else
        printf -v detail 'the previous handover went down right after launching the successor %s, and it could not be identified (a background session with the same name may remain unmanaged -- check with claude agents --json)' \
          "${attempt_name:-(no name on record)}"
      fi
      rein_notify "rein: a handover broke off partway through" "$detail"
    fi
    if ! mkdir -p "$RUNTIME_DIR/$REIN_REJECTED_DIRNAME"; then
      fail_stage "reclaiming a leftover handover request" \
        "cannot create the reclaim destination (entering monitoring with it left behind would permanently stop this seat's handover triggers): ${RUNTIME_DIR}/${REIN_REJECTED_DIRNAME}" \
        "" "${sid:-}" "${attempt_id:-}"
      return 1
    fi
    # The reclaim destination's name also follows the same discipline as archive_marker -- never
    # expand an externally-sourced ID into a pathname.
    printf -v dest '%s/%s/%s-%s.json' "$RUNTIME_DIR" "$REIN_REJECTED_DIRNAME" \
      "$(rein_iso_stamp_for_filename)" "$(rein_nonce)"
    if ! mv "$file" "$dest"; then
      fail_stage "reclaiming a leftover handover request" \
        "cannot move it to the reclaim destination (entering monitoring with it left behind would permanently stop this seat's handover triggers): ${file}" \
        "" "${sid:-}" "${attempt_id:-}"
      return 1
    fi
    count=$((count + 1))
    rein_log_event "$LOG_FILE" "marker_recovered" "$detail" "" "${sid:-}" "${attempt_id:-}"
  done
  [ "$count" -eq 0 ] && return 0
  wlog "reclaimed ${count} leftover handover request(s)"
  return 0
}

# The watcher that comes back carries through to completion a round that launched but went down
# before the target got written. Material is only the handover request marker's declaration
# (launch_attempt) and the current listing -- no new location is created for recovery (and this is
# not read back as recovery state from the append-only audit log either).
# The generation is re-derived from the current pointer (keeps monotonic increase intact).
# 0=carried through / 1=could not (recorded as a stage failure)
adopt_launched_successor() {
  local marker="$1" predecessor="$2" successor="$3" successor_name="$4"
  local handoff generation pointer_rc
  handoff="$(jq -r '.handoff_path // empty' "$marker" 2>/dev/null)"
  read_pointer_generation
  pointer_rc=$?
  case "$pointer_rc" in
    0)
      # A round where the pointer already points at this successor (the commit went through, but a
      # later stage went down) does not advance the generation. Advancing it would let this one
      # handover consume a generation every time it is adopted.
      if [ "$REIN_POINTER_SESSION_ID" = "$successor" ]; then
        generation="$POINTER_GENERATION"
      else
        generation="$((POINTER_GENERATION + 1))"
      fi
      ;;
    1) generation=1 ;;
    *)
      fail_stage "validating the current pointer" "$POINTER_ERROR" "" "$predecessor" "$successor"
      return 1
      ;;
  esac
  # Even where the declaration has no name (a round where the write-back failed), do not leave the
  # record column empty -- fall to the marker's own preferred name, or failing that the default
  # naming (cannot build it until the generation is settled).
  if [ -z "$successor_name" ]; then
    successor_name="$(jq -r '.successor_name // empty' "$marker" 2>/dev/null)"
  fi
  if [ -z "$successor_name" ]; then
    printf -v successor_name '%s-rein-g%s' "$(basename "$TARGET_CWD")" "$generation"
  fi
  CLAIMED_MARKER="$marker"
  M_SESSION_ID="$predecessor"
  wlog "the previous handover went down right after launching the successor (the launched successor is alive, so it is being adopted): predecessor=${predecessor} successor=${successor}"
  if ! write_pointer "$generation" "$successor" "$successor_name" "$predecessor" "$handoff"; then
    fail_stage "updating the pointer" "cannot write current.json" "$generation" "$predecessor" "$successor"
    return 1
  fi
  if ! archive_marker "$REIN_PROCESSED_DIRNAME"; then
    fail_stage "archiving the marker" "cannot move it to processed" "$generation" "$predecessor" "$successor"
    return 1
  fi
  retire_predecessor "$generation" "$predecessor" "$successor" || return 1
  log_event_or_fail "handover_completed" "$successor_name" "$generation" "$predecessor" "$successor" || return 1
  wlog "adopted a handover that launched a successor but never got a target, and completed it: generation=${generation} predecessor=${predecessor} successor=${successor}"
  rein_notify "rein: adopted a stranded handover" "made generation ${generation}'s successor ${successor} the primary session"
  return 0
}

# Pull the reason the successor went down from that round's handover log. Returns the **text
# verbatim** -- folding it into generic wording here would communicate only that things stopped,
# not why. For a lineage where the original text is not left behind (it went down on a different
# machine, or the record was deleted), point to where to look instead.
handover_failure_cause() {
  local successor="$1" detail
  detail="$(jq -r --arg sid "$successor" \
    'select(.event == "failed" and .successor_session_id == $sid) | .detail' \
    "$LOG_FILE" 2>/dev/null | tail -1)"
  if [ -n "$detail" ]; then
    printf 'the record of when the successor went down (verbatim): %s' "$detail"
    return 0
  fi
  printf 'no record of the successor going down remains in the handover log (check the failed lines in %s and %s)' \
    "$LOG_FILE" "$WATCHER_LOG_FILE"
}

# Resume a handover that failed partway through. A handover proceeds "launch the successor ->
# advance the pointer -> step the predecessor down", so a lineage where only the last stage is left
# gets stuck at "successor alive, predecessor alive, watcher absent" -- there was no way to detect
# or recover from this shape, and the predecessor stays behind while further handover requests
# just keep piling up (the pointer already points at the successor, so the next request keeps
# getting rejected as R10).
# Checked **right after the watcher lock is claimed** -- at that point this is the only run
# advancing this lineage's handover, so if the predecessor is still there it is confirmed to be
# leftover from a previous round (never mixes with the window where both coexist mid-handover).
# The pointer alone (successor, generation, predecessor ID) is enough material.
# Stepping the predecessor down goes through the same one function as the main handover path
# (retire_predecessor).
# 0=judged whether resuming was needed and handled it (including "not needed" and "undetermined") /
# 1=resumed but a stage failed
resume_incomplete_handover() {
  local rc predecessor successor generation name detail cause
  rein_stranded_predecessor "$POINTER_FILE" "$TARGET_CWD"
  rc=$?
  if [ "$rc" -eq 2 ]; then
    # Do not silently fall through to "nothing left behind" when it cannot be judged (falling
    # through would permanently disable this recovery for a lineage where the listing is broken).
    # Monitoring itself keeps going -- a broken listing is named by a later stage.
    wlog "cannot judge whether a handover failed partway through: $(rein_list_agents_error)"
    return 0
  fi
  if [ "$rc" -eq 3 ]; then
    # Only one side of the handover went down (the primary session on record is gone, but the
    # predecessor is alive). Stepping the predecessor down here would take live sessions to
    # **zero**, while the record and notification would still say "the handover completed"
    # (a reproduced loss). **Report it and stop, without fixing it** -- do not relaunch the
    # successor, do not roll back the pointer, and do not stop the still-live predecessor. Give
    # the cause verbatim (folding it into generic wording would leave the user with no way to
    # trace the cause).
    predecessor="$REIN_STRANDED_PREDECESSOR"
    successor="$REIN_STRANDED_SUCCESSOR"
    generation="$REIN_POINTER_GENERATION"
    cause="$(handover_failure_cause "$successor")"
    detail="$(rein_handover_mismatch_detail "$REIN_BIN" "$successor" "$predecessor" "$TARGET_CWD" "$cause" \
      "$RUNTIME_DIR" "$RECORDS_DIR")"
    fail_stage "resuming the handover" "$detail" "$generation" "$predecessor" "$successor"
    return 1
  fi
  [ "$rc" -eq 0 ] || return 0
  predecessor="$REIN_STRANDED_PREDECESSOR"
  successor="$REIN_POINTER_SESSION_ID"
  generation="$REIN_POINTER_GENERATION"
  name="$(rein_pointer_field "$POINTER_FILE" "session_name")"
  wlog "the previous handover left the predecessor-stepdown stage remaining (resuming it): generation=${generation} predecessor=${predecessor} successor=${successor}"
  retire_predecessor "$generation" "$predecessor" "$successor" || return 1
  log_event_or_fail "handover_completed" "$name" "$generation" "$predecessor" "$successor" || return 1
  wlog "resumed the handover and completed it: generation=${generation} predecessor=${predecessor} successor=${successor}"
  rein_notify "rein: resumed a stranded handover" "stepped down generation ${generation}'s predecessor"
  return 0
}

# Add the rejection reason to the record of a rejected handover request (the marker itself,
# archived under `rejected/`).
#
# **This is the handoff to the Stop hook.** In the rejected generation, the requesting session's
# generation latch has already been consumed, and from here on that session's stop is never held
# again (the forced handover is gone). The hook reads the `rejected_reason` written here, holds the
# stop once more for that generation, and attaches the reason verbatim -- with no reason, there is
# no way to know what to fix, and holding it again has no value. The reason lives in the archived
# record rather than the handover log so the hook can get "whose request, and why it failed" from
# **one file** (the log would mean scanning an append-only stream).
#
# A round that cannot write this does not fail the rejection itself (the rejection already went
# through; the reason is in the handover log and the notification). But it is not silently dropped
# either -- leave one line in the watcher log saying the hook cannot hold the stop again.
# A shape unreadable as JSON (R1) always fails here -- that rejection can never be picked up by
# the hook.
record_rejection_reason() {
  local reason="$1" marker_json
  [ -n "$CLAIMED_MARKER" ] || return 0
  [ -f "$CLAIMED_MARKER" ] || return 0
  marker_json="$(jq -c \
    --arg reason "$reason" \
    --arg at "$(rein_iso_now)" \
    '. + {rejected_reason: $reason, rejected_at: $at}' "$CLAIMED_MARKER" 2>/dev/null)"
  if [ -z "$marker_json" ] || ! rein_write_json_atomic "$CLAIMED_MARKER" "$marker_json"; then
    wlog "could not append the rejection reason to the archived record (the requester's Stop cannot be held again for this rejection): ${CLAIMED_MARKER}"
    return 1
  fi
  return 0
}

# Common handling for a rejection (the marker is consumed whether accepted or rejected).
# 0=rejection recorded / 1=archiving failed (treated as a stage failure)
reject_marker() {
  local reason="$1"
  if ! archive_marker "$REIN_REJECTED_DIRNAME"; then
    fail_stage "archiving the marker" "cannot move it to rejected (it remains unconsumed): ${reason}" "" "$M_SESSION_ID"
    return 1
  fi
  record_rejection_reason "$reason"
  # A generation number is assigned only when a handover actually goes through (putting a number
  # on a rejection line would make the audit trail readable as two different handovers).
  rein_log_event "$LOG_FILE" "marker_rejected" "$reason" "" "$M_SESSION_ID" ""
  wlog "rejected a handover request: ${reason}"
  rein_notify "rein: rejected a handover request" "$reason"
  return 0
}

# Common handling for a cancellation (accepted, but the user spoke up before the successor was
# launched).
# **Separating the archive destination from rejection** -- the reason lives with the constant name
# for this runtime data (lib/rein-common.sh's cancelled).
# Do not append a reason to the archived record -- unlike a rejection reason, there is no defect to
# fix.
# 0=cancellation recorded / 1=archiving failed (treated as a stage failure)
cancel_marker() {
  local generation="$1" detail
  if ! archive_marker "$REIN_CANCELLED_DIRNAME"; then
    fail_stage "archiving the marker" "cannot move it to cancelled (it remains unconsumed)" \
      "$generation" "$M_SESSION_ID"
    return 1
  fi
  # A **generation number** is not attached to a handover that did not go through (same discipline
  # as a rejection line -- numbering happens only after acceptance, and a cancelled generation is
  # reused by the next handover that does go through). But **which acceptance was undone** still
  # needs to be traceable to line it up with marker_accepted in the audit, so the accepted
  # generation goes in the detail.
  printf -v detail 'the user spoke up after the handover request was issued, so it was cancelled before launching the successor (generation at acceptance: %s)' \
    "$generation"
  rein_log_event "$LOG_FILE" "marker_cancelled" "$detail" "" "$M_SESSION_ID" ""
  wlog "cancelled a handover: ${detail}"
  rein_notify "rein: cancelled a handover" "$detail"
  return 0
}

# A cancellation that arrived **after the wait was already left**. The marker keeps being placed
# for as long as the pointer still names the predecessor -- the whole launch-to-pointer-move
# window -- but the wait is the only step that ever read it, so a cancellation placed there used
# to be deleted (or left behind) without the user hearing a word: they spoke up, the seat switched
# over anyway, and nothing on screen said whether their words had landed.
# **The handover is not stopped here.** By this point the pointer has advanced and rein has no way
# to roll it back, so turning back after the fact would be a bigger hazard than the silence. All
# this does is say the words arrived too late.
# **Placed at the end of the round rather than right after the wait or right after the pointer
# moved** -- the marker can be placed anywhere in the window that runs to the pointer swap
# (including the race right at the swap, where the hook read the pointer before it moved and
# writes after), so the end of the round is the only position that sees every one of them.
# **The vocabulary is kept apart from marker_cancelled**, which means "the cancellation took
# effect and no successor was launched" -- reusing it would make a completed handover read in the
# audit log as one that never happened.
# **Starts from the existence check** (handover_mark_is returns on `[ -f ]`), so a round where no
# cancellation was placed -- the overwhelming majority -- spends not one extra external command
# and says nothing. A marker naming another session is left untouched, the same discipline as the
# wait.
report_late_cancel() {
  local generation="$1" successor="$2" detail
  # A lineage that chose not to wait (cap 0) has no reader of this marker at all, and the hook
  # stops placing it there too -- reading it here would let a record claim a cancellation on a
  # lineage where a prompt never places one.
  [ "$FINAL_OUTPUT_TIMEOUT_SEC" -ne 0 ] || return 0
  handover_mark_is "$HANDOVER_CANCEL_FILE" "$M_SESSION_ID" || return 0
  printf -v detail 'the cancellation arrived after the window had closed, so the handover completed as scheduled (generation %s): the seat is on the successor session now, so carry on there (this cancellation stopped nothing)' \
    "$generation"
  # The handover itself is already through, so a log write that fails must not turn the round into
  # a failure -- but it is never swallowed either (one line stays in the watcher log).
  rein_log_event "$LOG_FILE" "cancel_after_window" "$detail" "$generation" "$M_SESSION_ID" "$successor" ||
    wlog "cannot write cancel_after_window to the handover log: ${LOG_FILE}"
  wlog "a cancellation arrived after the window: ${detail}"
  rein_notify "rein: the cancellation did not make it in time" "$detail"
  # Do not carry it into the next round -- left in place, it matches on the very first cycle of the
  # next handover's wait and cancels a handover the user never spoke against.
  rm -f "$HANDOVER_CANCEL_FILE" 2>/dev/null
  [ -e "$HANDOVER_CANCEL_FILE" ] || return 0
  wlog "cannot delete the handover marker (the next handover may read this marker): ${HANDOVER_CANCEL_FILE}"
  return 0
}

# 0=handover completed / 1=stage failure (mechanism error) / 2=rejected (a user input error) /
# 3=a different instance consumed it first
# 4=the user spoke up, so it was cancelled (no successor was ever launched)
handle_handover() {
  local generation successor_name kickoff successor_id detail rc
  local pointer_gen pointer_rc pointer_session

  if ! claim_marker; then
    if [ ! -f "$MARKER_FILE" ]; then
      return 3
    fi
    fail_stage "claiming the marker" "cannot move it to processing" "" ""
    return 1
  fi

  if ! validate_marker; then
    reject_marker "$REJECT_REASON" || return 1
    return 2
  fi

  read_pointer_generation
  pointer_rc=$?
  pointer_gen="$POINTER_GENERATION"
  case "$pointer_rc" in
    0)
      generation="$((pointer_gen + 1))"
      # R10: only the session the current pointer is presently pointing at may request a
      # handover. Without this check, a session outside monitoring (a stale marker from a
      # different lineage, a mismatched ID) could place a marker that runs a handover as long as
      # it is fresh, and the seat would get repointed to a session it does not know about.
      pointer_session="$(rein_pointer_field "$POINTER_FILE" "session_id")"
      if [ "$M_SESSION_ID" != "$pointer_session" ]; then
        printf -v detail 'R10 the marker session_id does not match the current pointer: marker=%s pointer=%s' \
          "$M_SESSION_ID" "$pointer_session"
        reject_marker "$detail" || return 1
        return 2
      fi
      ;;
    1)
      generation=1
      ;;
    *)
      # Not a user input error -- a mechanism-side fault. Leave the claimed marker in processing;
      # do not move it to a location (rejected) that reads as "was rejected".
      fail_stage "validating the current pointer" "$POINTER_ERROR" "" "$M_SESSION_ID"
      return 1
      ;;
  esac

  printf -v detail 'handoff=%s requested_at=%s' "$M_HANDOFF_PATH" "$M_REQUESTED_AT"
  rein_log_event "$LOG_FILE" "marker_accepted" "$detail" "$generation" "$M_SESSION_ID" ""

  # Do not launch the successor while the archive location is unusable (the handover would go
  # through while the marker alone stays behind, and the same judgment would recur forever).
  # **The move only happens once the pointer has advanced**, so all that is confirmed before
  # launch is the shape of the location.
  if ! ensure_archive_dest "$REIN_PROCESSED_DIRNAME"; then
    fail_stage "archiving the marker" "cannot move it to processed (will not proceed to the handover with an accepted marker that cannot be consumed)" \
      "$generation" "$M_SESSION_ID"
    return 1
  fi

  successor_name="$M_SUCCESSOR_NAME"
  if [ -z "$successor_name" ]; then
    printf -v successor_name '%s-rein-g%s' "$(basename "$TARGET_CWD")" "$generation"
  fi
  kickoff="$(build_kickoff "$M_HANDOFF_PATH")"

  # **Before launching the successor**, wait for the session that requested the handover to finish
  # printing its response. This is the only window where "accepted, but no successor has been
  # launched yet" holds -- rein has no way to roll back the current pointer, and the existing path
  # for stepping down a launched successor (abandon_launched_successor) is written assuming the
  # pointer has not advanced, so this is the only place a cancellation can still take effect.
  # **A lineage with the cap set to 0 never enters the wait** (accept it and launch right away --
  # the behavior before this mechanism was added). Entering the wait with a 0-second cap would
  # expire immediately every time, piling up a "did not wait long enough" line on every handover --
  # "did not wait long enough" and "decided not to wait" are different facts and should not be
  # mixed.
  if [ "$FINAL_OUTPUT_TIMEOUT_SEC" -ne 0 ]; then
    wait_for_final_output "$M_SESSION_ID"
    rc=$?
    case "$rc" in
      2)
        cancel_marker "$generation" || return 1
        return 4
        ;;
      4)
        fail_heartbeat "$generation" "$M_SESSION_ID"
        return 1
        ;;
      1)
        # Do not stay silent about the mechanism not taking effect and falling back to an
        # immediate handover as before (a round that waited it out shows up in the gap between
        # marker_accepted and successor_launching's timestamps, so no extra record is left for
        # that case).
        printf -v detail 'waited %s seconds and the final-output marker never came (launching the successor as before)' \
          "$FINAL_OUTPUT_TIMEOUT_SEC"
        rein_log_event "$LOG_FILE" "final_output_wait_expired" "$detail" \
          "$generation" "$M_SESSION_ID" ""
        ;;
    esac
  fi

  if ! launch_and_point "$generation" "$successor_name" "$kickoff" "$M_SESSION_ID" "$M_HANDOFF_PATH"; then
    return 1
  fi
  successor_id="$SUCCESSOR_ID"

  # The accepted marker is consumed only **after the pointer has advanced**. Whether the marker is
  # still sitting in processing for a round that dies between launch and commit is the only
  # material for later adopting "launched but has no target" -- moving it to processed at
  # acceptance time would erase that material.
  archive_marker "$REIN_PROCESSED_DIRNAME" || {
    fail_stage "archiving the marker" "cannot move it to processed" "$generation" "$M_SESSION_ID" "$successor_id"
    return 1
  }

  retire_predecessor "$generation" "$M_SESSION_ID" "$successor_id" || return 1

  # Read the cancel marker one last time, **before the completion line** -- the round's terminal
  # line stays handover_completed, and a reader of the log meets the notice as something that
  # happened on the way there.
  report_late_cancel "$generation" "$successor_id"

  log_event_or_fail "handover_completed" "$successor_name" "$generation" "$M_SESSION_ID" "$successor_id" || return 1
  wlog "handover completed: generation=${generation} predecessor=${M_SESSION_ID} successor=${successor_id}"
  return 0
}

# Determine the target cwd (needed before reading the config layer -- where the project config
# lives is decided by cwd).
resolve_target_cwd() {
  local resolved_cwd cwd_error
  if [ -z "$TARGET_CWD" ]; then
    printf '%s: please specify --cwd\n' "$SCRIPT_NAME" >&2
    return 2
  fi
  if [ ! -d "$TARGET_CWD" ]; then
    printf '%s: the target directory does not exist: %s\n' "$SCRIPT_NAME" "$TARGET_CWD" >&2
    return 2
  fi
  # A shape that exists but still cannot be resolved (a cd permission issue, an unresolvable
  # ancestor) can happen, so check for a resolution failure. Without checking, **the assignment
  # would run first**, proceeding with an empty cwd and failing later for a different, misleading
  # reason (cannot create the records location), with bash's raw error line leaking into
  # user-facing output.
  # The reason is captured from cd's stderr and put into this script's own one line (matching the
  # wording rein-request.sh and bin/rein use for the same resolution).
  resolved_cwd="$(cd "$TARGET_CWD" 2>/dev/null && pwd -P)"
  if [ -z "$resolved_cwd" ]; then
    # Here **failure is expected** (only the reason text is wanted), so the exit code is ignored.
    cwd_error="$(cd "$TARGET_CWD" 2>&1 || :)"
    # Drop bash's own prefix (`<script>: line <n>: cd: `) and keep just the reason.
    case "$cwd_error" in
      *": cd: "*) cwd_error="${cwd_error##*": cd: "}" ;;
    esac
    printf '%s: cannot resolve the target directory: %s\n' "$SCRIPT_NAME" "${cwd_error:-$TARGET_CWD}" >&2
    return 2
  fi
  TARGET_CWD="$resolved_cwd"
  # Where the watcher log lives is decided by cwd alone. Settle it before the prerequisite check
  # and config load, so a round that fails there still leaves one line in watcher.log (the records
  # location itself is created by resolve_paths, but wlog creates it too if it is missing).
  # Called **outside `$( )`** so a rejection can be told apart from success (received through
  # `$( )` the two are the same empty string, and WATCHER_LOG_FILE below would become
  # `/watcher.log` -- an append straight into the filesystem root). The reason is carried out
  # through REIN_RECORDS_ERROR; the resolver's own stderr line is suppressed because
  # startup_reject re-emits it in this script's one-line form.
  # startup_reject is usable here even though the watcher log has no location yet: wlog returns
  # immediately while WATCHER_LOG_FILE is still empty, so the rejection reaches stderr and the GUI
  # notification without the rejecting side creating a single file.
  if ! rein_records_dir "$TARGET_CWD" >/dev/null 2>&1; then
    startup_reject "${REIN_RECORDS_ERROR:-cannot resolve the lineage records location}"
    return 2
  fi
  RECORDS_DIR="$REIN_RECORDS_PATH"
  # **The same predicate** as rein-hook.sh's hook_prepare and lib/cli/base.sh's prepare_runtime.
  # The records location is settled here rather than in resolve_paths, and downstream failure paths
  # (startup_reject -> wlog) go create their location from here on, so **the gate belongs here too,
  # not in resolve_paths** (waiting for resolve_paths would let a watcher.log get created under a
  # never-touch root before it ever gets there).
  # The rejection goes straight to stderr, unfiltered -- wlog is not used (going through it would
  # have the rejecting side itself create one file).
  if [ -n "${REIN_SELFTEST_NEVER_ROOTS:-}" ] &&
    rein_selftest_never_root_hit "$RECORDS_DIR"; then
    printf '%s: a selftest child resolved a location it must never touch (isolation is broken): %s\n' \
      "$SCRIPT_NAME" "$REIN_SELFTEST_NEVER_ROOT_HIT" >&2
    return 2
  fi
  WATCHER_LOG_FILE="$RECORDS_DIR/$REIN_WATCHER_LOG_BASENAME"
  return 0
}

# The location splits into two (the two have different lifetime owners).
# Lineage records = the project's .rein/. Runtime data = the machine's.
resolve_paths() {
  local runtime_opt rc
  rein_config_bind runtime_opt runtime_dir || return 2
  RUNTIME_DIR="$(rein_resolve_runtime_dir "$TARGET_CWD" "$runtime_opt")"
  if [ -z "$RUNTIME_DIR" ]; then
    startup_reject "cannot resolve where runtime data is kept (specify it explicitly with --runtime-dir)"
    return 2
  fi
  # Resolved outside `$( )` for the same reason as in resolve_target_cwd. In practice
  # resolve_target_cwd has already rejected everything this can reject, so this is the second
  # layer -- but **RECORDS_DIR is left at the value that already passed** rather than overwritten
  # with an empty one, so startup_reject's watcher-log line still lands where it belongs.
  if ! rein_records_dir "$TARGET_CWD" >/dev/null 2>&1; then
    startup_reject "${REIN_RECORDS_ERROR:-cannot resolve the lineage records location}"
    return 2
  fi
  RECORDS_DIR="$REIN_RECORDS_PATH"
  # This is the first point the runtime directory is fully settled. The rein_ensure_records_dir /
  # rein_ensure_runtime_dir calls right after this are the first writes, so **this is the last
  # place the gate can stop them** (the same predicate as the one above, applied to runtime data).
  # The records location was already checked earlier, in resolve_target_cwd (since wlog can write
  # from there on).
  # Do not pass the state area's root -- it is the runtime directory's literal parent, and if the
  # never-touch-root list has the parent, the runtime directory side is always the one that hits
  # first (it cannot be an input that changes the judgment).
  if [ -n "${REIN_SELFTEST_NEVER_ROOTS:-}" ] &&
    rein_selftest_never_root_hit "$RUNTIME_DIR" "$RECORDS_DIR"; then
    printf '%s: a selftest child resolved a location it must never touch (isolation is broken): %s\n' \
      "$SCRIPT_NAME" "$REIN_SELFTEST_NEVER_ROOT_HIT" >&2
    return 2
  fi
  MARKER_FILE="$RUNTIME_DIR/$REIN_MARKER_BASENAME"
  HANDOVER_READY_FILE="$RUNTIME_DIR/$REIN_HANDOVER_READY_BASENAME"
  HANDOVER_CANCEL_FILE="$RUNTIME_DIR/$REIN_HANDOVER_CANCEL_BASENAME"
  HEARTBEAT_FILE="$RUNTIME_DIR/$REIN_HEARTBEAT_BASENAME"
  STOP_REQUEST_FILE="$RUNTIME_DIR/$REIN_STOP_REQUEST_BASENAME"
  POINTER_FILE="$RECORDS_DIR/$REIN_POINTER_BASENAME"
  LOG_FILE="$RECORDS_DIR/$REIN_LOG_BASENAME"
  WATCHER_LOG_FILE="$RECORDS_DIR/$REIN_WATCHER_LOG_BASENAME"
  if ! rein_ensure_records_dir "$RECORDS_DIR"; then
    startup_reject "cannot create the lineage records location: ${RECORDS_DIR}"
    return 2
  fi
  rein_ensure_runtime_dir "$RUNTIME_DIR" "$TARGET_CWD"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    startup_reject "$REIN_RUNTIME_ERROR"
    return 2
  fi
  # Lineage records moved from the runtime directory to the project side, so starting a
  # pre-migration lineage would read "no pointer" as a cold start and silently roll the generation
  # back to 1 (also losing R10's comparison target), splitting the canonical audit trail across
  # both old and new locations. That is a behavior forbidden for a broken pointer, so records
  # still present at the old location are stopped mechanically (never leave a missed migration to
  # a note in the runbook).
  if [ ! -f "$POINTER_FILE" ] &&
    { [ -f "$RUNTIME_DIR/$REIN_POINTER_BASENAME" ] || [ -f "$RUNTIME_DIR/$REIN_LOG_BASENAME" ]; }; then
    startup_reject "lineage records remain at the old location (${RUNTIME_DIR}). Migrate them to ${RECORDS_DIR} before starting"
    return 2
  fi
  return 0
}

# The entry point for the handover's first cycle (cold start). The attach loop can only attach
# once a current pointer exists, so this module launches the primary session too (kept as the one
# writer of the pointer, the watcher, rather than placed in rein-seat.sh).
run_bootstrap() {
  local rc pointer_gen pointer_rc generation successor_name kickoff session_id live_rc handoff detail
  local strand_rc agents taken

  resolve_target_cwd
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

  validate_runtime
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

  if ! load_config_values; then
    startup_reject "$REIN_CONFIG_ERROR"
    return 2
  fi

  resolve_paths
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

  # Do not take the resident watcher lock (bootstrap is a separate one-shot entry point that can
  # run at the same time as the resident watcher).
  if ! rein_open_error_sink; then
    printf '%s: cannot create a temp file to capture external command output\n' "$SCRIPT_NAME" >&2
    return 2
  fi
  trap cleanup_runtime EXIT

  # If --handoff is not given, use config's handoff_path (default: handoff.md next to the
  # records). It ends up empty only for a lineage that explicitly set it empty in config, in which
  # case start the primary session with no canonical document.
  handoff="$BOOTSTRAP_HANDOFF"
  if [ -z "$handoff" ]; then
    rein_config_bind handoff "handoff_path" || return 2
  fi
  if [ -n "$handoff" ]; then
    case "$handoff" in
      /*) ;;
      *)
        printf '%s: the handoff document must be given as an absolute path: %s\n' "$SCRIPT_NAME" "$handoff" >&2
        return 2
        ;;
    esac
    # Even with a default, the acceptance conditions (a regular file, not a symlink, non-empty)
    # still stand (never start the primary session with an empty document, a leftover placeholder,
    # or a directory) -- checked through the same one function as a handover request. On the very
    # first run no one has written the document yet, so attach how to fix it (the command to
    # create a template) to the reason.
    if ! rein_handoff_file_ok "$handoff"; then
      # The template is needed **per lineage**, so give an instruction that can be run as-is (an
      # instruction without `--cwd` would create the template in whatever lineage it is run from,
      # leaving this lineage still empty and repeating the same failure).
      rein_lineage_cmd "$REIN_BIN" "$RUNTIME_DIR" "$RECORDS_DIR" "$TARGET_CWD" init
      printf '%s: %s (create the template for this lineage before starting: %s)\n' \
        "$SCRIPT_NAME" "$REIN_HANDOFF_ERROR" "$REIN_LINEAGE_CMD" >&2
      return 2
    fi
  fi

  # From here on comes the "read the pointer and launch the successor" window, which runs under
  # the same lock as the resident watcher's handover processing. Proceeding without claiming it (the watcher
  # is currently advancing a handover for the same lineage) would slip through the window before
  # the pointer is written and launch **two successors of the same generation**.
  # The reason splits into busy (resolves next cycle) and fatal (cannot write to the location) on
  # the claiming side -- here whichever reason came back is passed straight through (composing it
  # in two places would leave only one of them holding the real reason).
  if ! acquire_handover_lock; then
    printf '%s: %s\n' "$SCRIPT_NAME" "$HANDOVER_LOCK_ERROR" >&2
    rein_notify "rein: aborted bootstrap" "$HANDOVER_LOCK_ERROR"
    return 1
  fi

  read_pointer_generation
  pointer_rc=$?
  pointer_gen="$POINTER_GENERATION"
  case "$pointer_rc" in
    0)
      session_id="$(rein_pointer_field "$POINTER_FILE" "session_id")"
      # Fetch the listing **once, for both of these two checks**, and pass it to both (both
      # helpers accept a listing argument). Fetching it separately would let just the second call,
      # if it happens to fail transiently, fall through to "undetermined" on the "is the
      # predecessor alive" check below, silently taking the default branch of launching a primary
      # session -- ending up with two primary sessions counting the still-live predecessor.
      # Fetching it once collects every "could not read it" into this one spot, and closes the
      # window where the two checks could disagree.
      agents="$(rein_list_agents)"
      rein_is_session_live "$session_id" "$agents"
      live_rc=$?
      if [ "$live_rc" -eq 0 ]; then
        printf -v detail 'the current pointer already points at a live session, %s (bootstrap is unnecessary)' "$session_id"
        rein_notify "rein: aborted bootstrap" "$detail"
        return 1
      fi
      if [ "$live_rc" -eq 2 ]; then
        # Do not silently fall through to "no predecessor" when it cannot be judged (falling
        # through would launch a primary session while a live predecessor is left behind).
        # **What is shared is only the material for the reason** (rein_list_agents_error -- why
        # the listing could not be read); the sentence itself is written separately from the
        # adopting side (resume_incomplete_handover) -- both hit the same "cannot read", but this
        # one is deciding whether to launch a primary session, the other is deciding whether to
        # adopt leftover work, and what the user does next differs.
        printf -v detail '%s (cannot judge whether the existing pointer is live, or whether a predecessor is left behind either)' "$(rein_list_agents_error)"
        printf '%s: %s\n' "$SCRIPT_NAME" "$detail" >&2
        rein_notify "rein: aborted bootstrap" "$detail"
        return 1
      fi
      # Do not launch when the pointer's target has exited but **its predecessor is still alive**
      # (only one side of the handover went down). Launching a primary session here would leave
      # two primary sessions counting the still-live predecessor, both possibly editing the same
      # working tree. Judged through the same one function as the watcher's startup adoption and
      # doctor -- so the same state is called by the same name wherever it is seen.
      rein_stranded_predecessor "$POINTER_FILE" "$TARGET_CWD" "$agents"
      strand_rc=$?
      if [ "$strand_rc" -eq 3 ]; then
        detail="$(rein_handover_mismatch_detail "$REIN_BIN" "$REIN_STRANDED_SUCCESSOR" "$REIN_STRANDED_PREDECESSOR" \
          "$TARGET_CWD" "$(handover_failure_cause "$REIN_STRANDED_SUCCESSOR")" \
          "$RUNTIME_DIR" "$RECORDS_DIR")"
        printf '%s: %s\n' "$SCRIPT_NAME" "$detail" >&2
        rein_notify "rein: aborted bootstrap" "$detail"
        return 1
      fi
      # The target has already exited -- the lineage has broken off, so continue the generation and
      # re-establish a primary session.
      generation="$((pointer_gen + 1))"
      ;;
    1)
      generation=1
      ;;
    *)
      fail_stage "validating the current pointer" "$POINTER_ERROR"
      return 1
      ;;
  esac

  successor_name="$BOOTSTRAP_NAME"
  if [ -z "$successor_name" ]; then
    printf -v successor_name '%s-rein-g%s' "$(basename "$TARGET_CWD")" "$generation"
  fi
  kickoff="$(build_kickoff "$handoff")"

  # bootstrap has no marker to consume -- there is nowhere to leave a launch declaration
  # (launch_attempt), so if it is killed from outside in the gap between `claude --bg` arriving and
  # the pointer being written, the launched primary session is left with nothing pointing to it (a
  # recovery pass only uses the marker in processing as material, so this launch is never a
  # candidate for adoption). The next cold start would see only "no pointer" and slip right
  # through, launching a second primary session in the same working tree -- the kickoff instructs
  # "Start work as this project's primary session.", so the two could edit the same tree.
  # At least check, before launching, whether a background session under the name about to be
  # claimed is already alive in the target cwd. This judgment goes through **the same one** as
  # identifying a successor (find_successor_session_id) -- do not write the liveness vocabulary a
  # second time here (the set before launch is empty and the floor is 0 -- pull "any background
  # session with this name that exists right now").
  # A round where the listing cannot be read (rc=2) is not stopped here -- the launch_and_point
  # right after always fails with "cannot confirm who was present before launch" anyway, so do not
  # create two reasons for the same state.
  taken="$(find_successor_session_id "$successor_name" 0 '[]')"
  rc=$?
  if [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ]; then
    printf -v detail 'a background session with this name already exists in this working tree (a previous bootstrap that broke off between launch and recording its target may have left this behind): name=%s%s cwd=%s. Check with claude agents --json, stop the extra one with claude stop, then start again' \
      "$successor_name" "${taken:+ session_id=${taken}}" "$TARGET_CWD"
    printf '%s: %s\n' "$SCRIPT_NAME" "$detail" >&2
    rein_notify "rein: aborted bootstrap" "$detail"
    return 1
  fi

  EXIT_REASON="launched the primary session"
  launch_and_point "$generation" "$successor_name" "$kickoff" "" "$handoff" || return 1
  printf '%s: launched the primary session: %s (%s)\n' "$SCRIPT_NAME" "$successor_name" "$SUCCESSOR_ID"
  return 0
}

run_watch() {
  local rc hrc detail

  resolve_target_cwd
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

  validate_runtime
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

  # Never enter monitoring with a config that could not be read at startup (a reread mid-cycle can
  # fall back to "the previous effective value", but at startup there is no previous value to
  # fall back to).
  if ! load_config_values; then
    startup_reject "$REIN_CONFIG_ERROR"
    return 2
  fi

  resolve_paths
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

  if ! rein_open_error_sink; then
    printf '%s: cannot create a temp file to capture external command output\n' "$SCRIPT_NAME" >&2
    return 2
  fi
  trap cleanup_runtime EXIT

  acquire_watch_lock
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s: %s\n' "$SCRIPT_NAME" "$LOCK_ERROR" >&2
    rein_notify "rein: cannot start the watcher" "$LOCK_ERROR"
    EXIT_REASON="$LOCK_ERROR"
    return 1
  fi

  # The version is recorded because the resident watcher keeps running **on the code it started with**
  # (only config gets reread per cycle). `git pull` updating the checkout does not make a running
  # watcher pick up the new code -- without a version on the record, there is no way to later
  # reconstruct which version was running for a given round.
  printf -v detail 'cwd=%s pid=%s started_at=%s version=%s' \
    "$TARGET_CWD" "$$" "$(rein_iso_now)" "$(rein_plugin_version)"
  log_event_or_fail "watch_started" "$detail" || return 1
  wlog "started monitoring: ${detail}"
  # Startup adoption (reclaiming leftovers and resuming a handover's last stage) runs **under the
  # handover lock**. The watcher lock alone is not enough -- `rein up` moves on to the next layer
  # once the watcher lock is visible and goes on to start bootstrap (which takes the handover
  # lock), so adopting without claiming it could write the pointer at the same time as bootstrap.
  acquire_handover_lock
  hrc=$?
  if [ "$hrc" -eq 1 ]; then
    fail_stage "claiming the lock for startup adoption" "$HANDOVER_LOCK_ERROR"
    return 1
  fi
  if [ "$hrc" -eq 2 ]; then
    # A different run is currently advancing the handover -- that run will carry it through.
    # Skipping adoption is never silenced (if it is still there, it is checked again next
    # startup).
    wlog "skipping startup adoption (${HANDOVER_LOCK_ERROR})"
  else
    # Reclaim leftovers from a previous round (leaving them means the Stop hook permanently stops
    # prompting that seat for a handover). **Check the return value** -- not checking it would
    # publish the heartbeat while reclaiming quietly failed.
    recover_orphan_processing
    hrc=$?
    if [ "$hrc" -ne 0 ]; then
      release_handover_lock
      return 1
    fi
    # At the same point, also check whether only the handover's last stage (stepping the
    # predecessor down) is left.
    resume_incomplete_handover
    hrc=$?
    if [ "$hrc" -ne 0 ]; then
      release_handover_lock
      return 1
    fi
    if ! release_handover_lock; then
      fail_stage "releasing the lock for startup adoption" "$HANDOVER_LOCK_ERROR"
      return 1
    fi
  fi
  if ! write_heartbeat; then
    fail_heartbeat
    return 1
  fi

  while :; do
    # Only a cycle that could claim the handover lock processes the marker. **Do not collapse "no
    # marker" and "cannot claim the lock" into the same false** -- collapsing them would let a
    # cycle where the location cannot be written (fatal) skip marker processing without leaving a
    # trace in either the log or a notification, while the heartbeat keeps updating every cycle so
    # it still looks healthy.
    # The only case that resolves next cycle is busy (a different run is advancing the handover).
    if [ -f "$MARKER_FILE" ]; then
      acquire_handover_lock
      hrc=$?
      if [ "$hrc" -eq 1 ]; then
        fail_stage "claiming the handover lock" "$HANDOVER_LOCK_ERROR"
        return 1
      fi
      if [ "$hrc" -eq 2 ]; then
        # busy resolves next cycle, so **resident monitoring never stops**. But this cycle processed zero
        # markers -- `--once` is meant to report whether that one request went through, so return
        # non-zero as the side that did not go through (returning 0 would tell the caller its
        # request was processed).
        if [ "$RUN_ONCE" -eq 1 ]; then
          EXIT_REASON="did not process it because a different run is advancing the handover (--once)"
          return 1
        fi
        hrc=3
      fi
    else
      hrc=3
    fi
    if [ "$hrc" -eq 0 ]; then
      handle_handover
      hrc=$?
      # A cycle that could not release is never treated as a success (a lock left behind holds
      # this run's own live pid, so it never goes stale either, and every future claim stays busy
      # forever -- this location's handovers stop permanently).
      if ! release_handover_lock; then
        fail_stage "releasing the handover lock" "$HANDOVER_LOCK_ERROR"
        return 1
      fi
      case "$hrc" in
        0) ;;
        3)
          # A different instance consumed it first. Since that request is carried through by
          # whichever side got it first, **resident monitoring never stops**, but this cycle did not
          # process this one, so return it as the side that did not go through.
          if [ "$RUN_ONCE" -eq 1 ]; then
            EXIT_REASON="a different instance processed the handover request first (--once)"
            return 1
          fi
          ;;
        2)
          # A rejection is a user input error. Stopping resident monitoring over it too would mean
          # handovers from here on stop being automated silently. The one-shot --once still
          # reports whether that request went through, so it returns non-zero, same as always.
          if [ "$RUN_ONCE" -eq 1 ]; then
            EXIT_REASON="rejected the handover request (--once)"
            return 1
          fi
          ;;
        4)
          # A cancellation is the user's own decision to abort -- different from a rejection
          # (an input defect), but it shares the same **do not stop resident monitoring** rule (no
          # successor was ever launched, so this lineage just continues as-is).
          # `--once` reports whether that one request went through, so return non-zero as the side
          # that did not.
          if [ "$RUN_ONCE" -eq 1 ]; then
            EXIT_REASON="cancelled the handover (--once)"
            return 1
          fi
          ;;
        *)
          return 1
          ;;
      esac
    fi
    if [ "$RUN_ONCE" -eq 1 ]; then
      EXIT_REASON="finished one scan (--once)"
      return 0
    fi
    # Check for a stop request only after marker processing (going down mid-handover would leave
    # the successor launched with the pointer never repointed as the watcher disappears).
    consume_stop_request
    case $? in
      0) return 0 ;;
      2) return 1 ;;
    esac
    if ! write_heartbeat; then
      fail_heartbeat
      return 1
    fi
    sleep "$POLL_INTERVAL_SEC"
    # Contract "when it takes effect" -- reread every cycle, so config edits take effect without
    # bringing the watcher down. A cycle that could not reread keeps the previous effective
    # values, so skip the location check too (the comparison target would become "the value from a
    # rejected config", sounding a config that never took effect as if it had).
    if reload_config_for_cycle; then
      check_runtime_dir_drift
    fi
  done
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --selftest)
        # Only load the selftest implementation here. It is larger than the resident watcher's own
        # code, so loading it on every startup would charge every polling cycle a cost unrelated
        # to monitoring.
        shift
        # shellcheck source-path=SCRIPTDIR
        # shellcheck source=lib/watcher/selftest/selftest.sh
        . "$SCRIPT_DIR/lib/watcher/selftest/selftest.sh"
        selftest "$@" # test-side-scope-exempt: one line that enters the selftest (not a production writer)
        return $?
        ;;
      --cwd)
        need_value "--cwd" $# "${2:-}" || return 2
        TARGET_CWD="$2"
        shift 2
        ;;
      --runtime-dir)
        check_opt "--runtime-dir" runtime_dir $# "${2:-}" || return 2
        RUNTIME_DIR_OPT="$2"
        shift 2
        ;;
      --settings)
        check_opt "--settings" settings $# "${2:-}" || return 2
        SETTINGS_OPT="$2"
        shift 2
        ;;
      --interval)
        check_opt "--interval" poll_interval_sec $# "${2:-}" || return 2
        INTERVAL_OPT="$2"
        shift 2
        ;;
      --once)
        RUN_ONCE=1
        shift
        ;;
      --bootstrap)
        BOOTSTRAP=1
        shift
        ;;
      --handoff)
        need_value "--handoff" $# "${2:-}" || return 2
        BOOTSTRAP_HANDOFF="$2"
        shift 2
        ;;
      --successor-name)
        need_value "--successor-name" $# "${2:-}" || return 2
        BOOTSTRAP_NAME="$2"
        shift 2
        ;;
      -h | --help)
        usage
        return 0
        ;;
      *)
        printf '%s: unknown argument: %s\n' "$SCRIPT_NAME" "$1" >&2
        usage >&2
        return 2
        ;;
    esac
  done
  if [ "$BOOTSTRAP" -eq 1 ]; then
    run_bootstrap
    return $?
  fi
  run_watch
}

main "$@"
