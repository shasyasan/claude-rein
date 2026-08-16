#!/usr/bin/env bash
# rein's hook runner (the actual program the plugin's hooks run).
#
# The path is 3 stages: the registry (hooks/hooks.json) -> a tiny launcher inside the
# plugin (written so that it never needs updating) -> **here** (next to the real file the
# command on PATH resolves to). This is kept separate from the CLI proper (bin/rein) because
# hooks run on every tool call, and paying the fixed cost of parsing a 4000+ line dispatcher on
# every call would show up as latency. This file loads only the config-layer parser and the
# shared library.
#
# On the no-op path (a call that emits nothing and exits 0), the only external command allowed is
# **one call to jq to parse the payload**. To keep that true:
#   - read standard input with the `read` builtin, not `cat`
#   - get "what time is it" from jq's own output when it parses the payload (never spawn `date`)
#   - judge usage-state freshness from the writer's own `at` timestamp (never `stat`; fall back
#     to mtime only when needed)
#   - judge the cooldown from the **contents (expiry)** of the fire marker (never `stat`)
#   - for sessions rein itself launched, get the lineage's location from the environment
#     (never compute the key, which would mean spawning `shasum`)
#   - never create a temp file (don't touch `${TMPDIR}`; never spawn `mktemp`)
#
# Why push this through the hook at all: context usage never arrives on the hook's stdin, and
# the model has no way to observe its own usage percentage. The judgment call to start wrapping
# up only fires once additionalContext injects the fact that a threshold was crossed, from
# outside the model.
#
# Why this stays silent in a subagent context: even for a subagent's tool calls, the hook runs
# with the **same session_id as the parent**, but additionalContext is delivered to **whichever
# agent invoked that tool** and never appears in the primary session's transcript. The primary
# session is the one that has to decide (wrap up or keep going), so nothing fires and no marker
# is touched in a subagent context. The two are told apart by the payload's **agent_id** alone
# -- `agent_type` alone won't do, because it's also present on the **primary session** when
# launched with `claude --agent <name>` (observed), and staying silent on that would drop the
# whole primary session out of monitoring.
#
# Why a cooldown instead of "once per session": a one-shot would mean that once a crossed
# threshold is let go unheeded, nothing ever prompts again. The cooldown is how long has to
# pass before the same notice may fire again.
#
# Why there's a delivery confirmation: firing (the injection went out) and delivery (the model
# read it) are different things, and a delivery failure fails silently. PostToolBatch injections
# get recorded on the transcript side under a **synthetic tool_use_id** of the form
# `hook-<uuid>` (which the hook side has no way to know -- observed), so delivery is
# confirmed by matching a nonce mixed into the injected text.
set -uo pipefail

# Normalize the entry environment. Force the character set to UTF-8 (bash can't parse this file
# at all in a non-UTF-8 multibyte locale) and unset `CDPATH` (it makes `$(cd ... && pwd -P)`
# print two lines instead of one). This must happen **before loading the shared library**.
# The rationale is written once, next to the same two lines in bin/rein.
unset LC_ALL CDPATH
export LC_CTYPE=UTF-8

SCRIPT_NAME="rein-hook.sh"
# Derive this script's own location with pure string operations (never spawn dirname / pwd).
# The launcher starts this runner as a child using the symlink-resolved absolute real path, so
# there's no need to resolve a symlink again here.
REIN_HOOK_PATH="${BASH_SOURCE[0]}"
case "$REIN_HOOK_PATH" in
  /*) ;;
  *) REIN_HOOK_PATH="$PWD/$REIN_HOOK_PATH" ;;
esac
SCRIPTS_DIR="${REIN_HOOK_PATH%/*}"
REPO_ROOT="${SCRIPTS_DIR%/*}"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/rein-config.sh
. "$SCRIPTS_DIR/lib/rein-config.sh"

# The CLI entry point embedded in advisory text. Rationale and the exact shape live next to the
# same line in scripts/rein-seat.sh. **This doesn't add to the no-op path's fixed cost** -- it's
# pure parameter expansion, no external command spawned.
REIN_BIN="$REPO_ROOT/$REIN_CLI_RELPATH"

# Grace period in seconds between injecting and checking delivery. Checking before the
# transcript is written would misread it as "not delivered", so it waits, in case the next tool
# call comes too soon.
HOOK_VERIFY_DELAY_SEC=30
# Grace period (seconds) before a claim on the right to notify (the `mkdir` exclusive lock) is
# treated as abandoned. The hook itself gets cut off by the registration timeout (10 seconds),
# so this is set well beyond that -- a still-live claim must never be seized out from under it.
HOOK_CLAIM_STALE_SEC=60

HOOK_INPUT=""
HOOK_INPUT_REJECT=""
HOOK_SESSION_ID=""
HOOK_AGENT_ID=""
# The child's kind (`agent_type`). Only the two child events use it -- it goes into the ledger
# entry so the handover request can name **which** children are still running. It is never used
# to decide whether this is a subagent context (a primary session launched with `claude --agent`
# carries one too -- see hook_is_subagent).
HOOK_AGENT_TYPE=""
HOOK_TRANSCRIPT=""
HOOK_PAYLOAD_CWD=""
HOOK_NOW=""
HOOK_EVENT=""
HOOK_DIR=""
HOOK_HEALTH_DIR=""
HOOK_STATE_FILE=""
HOOK_PENDING_FILE=""
HOOK_LOG_FILE=""
HOOK_THRESHOLD_NOTICE=""
HOOK_THRESHOLD_HANDOVER=""
HOOK_COOLDOWN_SEC=""
HOOK_STALE_SEC=""
HOOK_FINAL_OUTPUT_TIMEOUT_SEC=""
HOOK_FINAL_OUTPUT_WAIT_SEC=""
# This run's watcher-liveness judgment, filled in on the first call and shared from then on
# (the reasoning sits on hook_watcher_resident). Empty means "not judged yet on this run."
HOOK_WATCHER_RC=""
HOOK_USAGE_DIR=""
HOOK_HANDOFF_PATH=""
HOOK_PCT=""
HOOK_AT=""
# The payload's background_tasks (the primary evidence for a child's liveness). Kept as two
# separate values: whether the key is present, and how many entries are running. "Key absent"
# (the evidence itself is gone) and "0 entries" (no children) are different states -- treating
# the former as the latter would silently turn "lost the evidence" into "no children."
HOOK_BG_TASKS_PRESENT=0
HOOK_BG_TASKS_RUNNING=0

# The lineage (its locations).
TARGET_CWD=""
RUNTIME_DIR=""
STATE_ROOT=""
RECORDS_DIR=""
MANAGED_CONFIG_FILE=""
POINTER_FILE=""
MARKER_FILE=""
SNOOZE_FILE=""
HANDOVER_READY_FILE=""
HANDOVER_CANCEL_FILE=""
CHILDREN_DIR=""

usage() {
  cat <<EOF
usage: $SCRIPT_NAME --protocol <version> <event>
       $SCRIPT_NAME --selftest

  The program the plugin's hooks call. Events: post-tool-batch / post-tool-use / stop /
  session-start / user-prompt-submit.
  Reads the hook payload from stdin, so don't invoke it by hand (registry:
  ${REIN_HOOKS_JSON_RELPATH}).
  Acts only on sessions rein itself launched: the lineage comes from the managed marker env
  (${REIN_MANAGED_ENV_NAME}), and without it every event does nothing and exits 0.
EOF
}

fail() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2
  return 1
}

# Surface a write failure in the record layer (the fire log, health state) as a single line.
# **This never changes the exit code** -- a record-layer failure must never move the session's
# stop decision (that would break the hook's non-blocking contract). When this used to fail
# silently as success, the record layer and diagnostics **died silently at the same time**: a
# missing log line was read by doctor as "the registration isn't working" or "the injection
# isn't being delivered", when in fact it was being emitted fine and only failing to be written.
hook_record_failed() {
  fail "$1"
  return 0
}

# The exit code for an internal error is **1 for every event** (a non-blocking failure). 2 means
# something different per event (PostToolUse returns stderr to the model; Stop is itself the
# stop being blocked), and PostToolBatch has no official meaning for it at all -- so no
# malfunction in the mechanism is allowed to turn into an unknown control signal.
hook_die() {
  fail "$1"
  hook_health_note error "$1"
  exit 1
}

# Binds this hook's lineage from the managed marker env (present only for sessions rein itself
# launched, which is the only kind of session the hooks act on at all -- see the gate in
# hook_main). **The validation itself lives in the shared library**
# (rein_verify_managed_marker): a marker's other reader, the usage-record writer
# (rein-statusline.sh), has to arrive at the same verdict from the same env, and a second copy
# of the checks here would let the two drift apart without either side being able to see it.
# What stays here is only what is the hook's own: a rejection is **fail-loud** (there is no
# "resolve it some other way" path left -- a marker that is present but broken means the launch
# handed over a lineage that cannot be trusted, and guessing one would mean writing into a
# different lineage's pointer and markers), and the marker's user-scope config becomes this
# process's config file.
hook_bind_managed_lineage() {
  local rc
  rein_verify_managed_marker
  rc=$?
  # **2 (no marker at all) never reaches here** -- that is an unmanaged window, and hook_main
  # returns 0 in silence before this, reading the very same env. It is still routed into the
  # same fail-loud exit rather than a silent 0: were that gate ever to stop covering this, a
  # hook resolving a lineage out of nothing is the outcome that must not happen quietly. The
  # reason for that verdict is deliberately empty in the shared library (it is not a rejection
  # there), so the wording for it is supplied here, at the caller that treats it as one.
  if [ "$rc" -ne 0 ]; then
    hook_die "${REIN_MANAGED_MARKER_ERROR:-managed marker ${REIN_MANAGED_ENV_NAME} is not set, so this event should never have reached lineage resolution}"
  fi
  TARGET_CWD="$REIN_MANAGED_MARKER_CWD"
  RUNTIME_DIR="$REIN_MANAGED_MARKER_RUNTIME_DIR"
  RECORDS_DIR="$REIN_MANAGED_MARKER_RECORDS_DIR"
  MANAGED_CONFIG_FILE="$REIN_MANAGED_MARKER_CONFIG_FILE"
  # The config layer reads the user scope through this one channel (REIN_CONFIG_FILE). What
  # takes effect is the marker's value, not whatever's left over in the process, so a lineage's
  # config resolves the same way across generations.
  REIN_CONFIG_FILE="$MANAGED_CONFIG_FILE"
  return 0
}

# Resolve config and locations. Config is reread **on every call** (per the contract's "point
# of effect"). Config is searched from the lineage's cwd, which comes from the marker (moving
# the working tree doesn't change which project config applies -- it's always the lineage's).
# Every call that reaches here carries the marker (hook_main returns in silence without one),
# so **there is exactly one lineage-resolution path**: the marker. The records location comes
# from it too, and is never re-derived from the environment (for the reason above).
hook_prepare() {
  hook_bind_managed_lineage
  hook_load_config
  STATE_ROOT="${RUNTIME_DIR%/*}"
  # The gate below applies only to isolation-test children (isolation failing dies right here).
  # The locations (runtime directory, records) are settled and not a single byte has been
  # written yet -- this is the only point where "stop before writing" can hold. Every write
  # target (the fire log, health's last-seen, the lineage's hooks.log, the generation-tagged
  # stop latch) is derived from these two, so even as write targets grow, this one place still
  # covers them all. **Don't add a check per write target** -- a target that gets forgotten
  # becomes a silent hole, and that hole is invisible to a "count how many fingerprints grew"
  # style check (an overwrite that keeps the same name, a location outside the state area, and a
  # generation-tagged marker all leave the count unchanged).
  # The state area's root (STATE_ROOT) is not passed -- it's the literal parent of the runtime
  # directory, so whichever root-list entry would match, the runtime directory itself is always
  # matched first; there's no input that passing it could change the outcome for. (The root
  # list having a parent's entry serves a different purpose: catching a runtime directory under
  # a **different key** in the same state area, which only the parent entry can catch.)
  # **The signal that arms this gate is the root env itself** (non-empty means this is an
  # isolation-test child); REIN_HOOK_SELFTEST is not consulted. That root env is set only by
  # the one channel that builds isolation envs (lib/rein-selftest-fixtures.sh) -- it's empty in
  # production, so this `if` exits on a single string check. Using two signals instead of one
  # would double what has to stay in sync, and would also block extending the same gate to
  # other entry points (bin/rein, rein-watcher.sh) besides the hook.
  # HOOK_HEALTH_DIR is still empty at this point, so the write to health that hook_die calls
  # below makes is a no-op (so the rejecting side never leaves a file under a never-touch
  # root).
  if [ -n "${REIN_SELFTEST_NEVER_ROOTS:-}" ] &&
    rein_selftest_never_root_hit "$RUNTIME_DIR" "$RECORDS_DIR"; then
    hook_die "resolved a location the selftest child must never touch (isolation has failed): ${REIN_SELFTEST_NEVER_ROOT_HIT}"
  fi
  POINTER_FILE="$RECORDS_DIR/$REIN_POINTER_BASENAME"
  MARKER_FILE="$RUNTIME_DIR/$REIN_MARKER_BASENAME"
  SNOOZE_FILE="$RUNTIME_DIR/$REIN_SNOOZE_BASENAME"
  HANDOVER_READY_FILE="$RUNTIME_DIR/$REIN_HANDOVER_READY_BASENAME"
  HANDOVER_CANCEL_FILE="$RUNTIME_DIR/$REIN_HANDOVER_CANCEL_BASENAME"
  CHILDREN_DIR="$RUNTIME_DIR/$REIN_CHILDREN_DIRNAME"
  HOOK_DIR="$RUNTIME_DIR/$REIN_HOOK_STATE_DIRNAME"
  HOOK_HEALTH_DIR="$HOOK_DIR/$REIN_HOOK_HEALTH_DIRNAME"
  HOOK_STATE_FILE="$HOOK_USAGE_DIR/$HOOK_SESSION_ID.json"
  HOOK_PENDING_FILE="$HOOK_DIR/$HOOK_SESSION_ID.pending-verify"
  HOOK_LOG_FILE="$RECORDS_DIR/$REIN_HOOK_LOG_BASENAME"
  return 0
}

hook_load_config() {
  # Pass the records location into the config layer too. When the config layer resolves a
  # cwd-relative default (handoff_path), a managed hook has **no way for the root
  # (REIN_RECORDS_ROOT) to reach the environment** -- if it re-derived from the environment,
  # only a lineage rooted elsewhere would point at `<cwd>/.rein/handoff.md`, which doesn't match
  # the handoff document at the root's records location that kickoff, handover
  # requests, and `rein init` all look at. It always has a value here -- the marker is the only
  # way a hook resolves a lineage, and it carries the records location.
  rein_config_resolve_files "$REIN_BIN" "$TARGET_CWD" "$RECORDS_DIR"
  # Hooks run in a passive context -- **an unapproved project config must never break the
  # session**. Proceed without applying the project layer, and surface the fact that it wasn't
  # applied to stderr (this is never rung through an injection every 30 minutes -- it's about a
  # config the user never placed themselves, and it shouldn't fill up the conversation).
  REIN_CONFIG_PROJECT_MODE="skip"
  rein_config_load_files || hook_die "$REIN_CONFIG_ERROR"
  # Ring **only when there is a notice (i.e. a setting not yet decided)**. Ringing even for a
  # setting the user has deliberately chosen not to apply would turn their own decision into
  # noise.
  if [ -n "$REIN_CONFIG_PROJECT_NOTICE" ]; then
    printf '%s: %s\n' "$SCRIPT_NAME" "$REIN_CONFIG_PROJECT_NOTICE" >&2
  fi
  rein_config_check_cross_fields || hook_die "$REIN_CONFIG_ERROR"
  if ! rein_config_bind HOOK_THRESHOLD_NOTICE threshold_notice ||
    ! rein_config_bind HOOK_THRESHOLD_HANDOVER threshold_handover ||
    ! rein_config_bind HOOK_COOLDOWN_SEC notice_cooldown_sec ||
    ! rein_config_bind HOOK_STALE_SEC usage_stale_sec ||
    ! rein_config_bind HOOK_FINAL_OUTPUT_TIMEOUT_SEC final_output_timeout_sec ||
    ! rein_config_bind HOOK_FINAL_OUTPUT_WAIT_SEC final_output_wait_sec ||
    ! rein_config_bind HOOK_HANDOFF_PATH handoff_path ||
    ! rein_config_bind HOOK_USAGE_DIR usage_state_dir; then
    hook_die "$REIN_CONFIG_ERROR"
  fi
  # No location means no way to read usage -- monitoring can't work. Never silently fall back
  # to a default.
  [ -n "$HOOK_USAGE_DIR" ] ||
    hook_die "the session usage location isn't configured (config's usage_state_dir)"
  return 0
}

# Only prepare the location right before writing runtime data (so a no-op hook doesn't create
# it even for a project that never uses rein). The owner is recorded on the first write.
hook_ensure_dir() {
  [ -d "$HOOK_DIR" ] && return 0
  rein_ensure_runtime_dir "$RUNTIME_DIR" "$TARGET_CWD" || hook_die "$REIN_RUNTIME_ERROR"
  mkdir -p "$HOOK_DIR" || hook_die "cannot create the hooks location: ${HOOK_DIR}"
  return 0
}

# Since extraction reads one value per line, **a value that itself contains a newline shifts
# every line after it** -- the following value lands in a different field's slot, and a newline
# in `session_id` pushes its tail into `agent_id`, which makes the subagent check true (all
# monitoring goes silent even past a crossed threshold -- indistinguishable, byte for byte, from
# a real subagent's silence). The same holds for a non-string value: jq pretty-prints by
# default, so a single object shifts two lines, and whether `background_tasks` is present (`0`)
# lands where `now` should be, **making the current time epoch 0** (0 is a digit, so it passes
# the check below, and the last-seen value shared across sessions gets smeared to 1970).
# All of this is closed within the same single jq call: (a) **reject any field that isn't a
# string**, (b) `tostring` everything that's left (matching statusline), (c) put the rejection
# flag on **the output's first line**. Because it comes before any user-derived data, the check
# itself never shifts even when the values do.
# **Values are only blanked out when one of them contains a newline** (not uniformly on every
# rejection). The point of blanking is to preserve line position, which is only at risk for a
# value with a newline in it -- a value that's merely the wrong type always fits on one line
# after `tostring`, so leaving it in place doesn't shift anything after it. Blanking
# unconditionally would mean **a type rejection in one field throws away every other field**,
# including the payload's `cwd` that the fire log records alongside the lineage -- the one
# column that shows a rejected call came in from a moved working tree. Nothing is bought by
# discarding values that never shifted position. When both type and newline are broken
# at once, the newline case wins (checked via `$bad_lf`) -- the reported code can say
# `field-type:` while the fields are still blanked.
# **`tostring` alone isn't enough** -- a non-string value that fits on one line (`agent_id: 0`)
# doesn't shift any line, so it never trips the newline check and comes out as the non-empty
# string `"0"`. `hook_is_subagent` looks only at whether agent_id is non-empty, so this reads as
# true, and **every event goes silent and exits 0** (nothing on stderr, nothing recorded --
# indistinguishable, byte for byte, from a real subagent's silence). The route differs from the
# one that shifts values, but the endpoint is the same, and squashing a type in silence is a
# silent type conversion -- a fail-loud violation.
# Replacing the delimiter with NUL or base64 is not an option -- NUL gets dropped by bash
# command substitution, and base64 would add an external command per field, blowing the "no-op
# path spawns only one jq call" budget.
# **`//` can't be used to blank out a missing field** -- jq's `//` returns its right-hand side
# for both `null` and `false`, so `cwd: false` would turn into the string `""`, sail past check
# (a)'s type check, and silently collapse the explicit value `false` into the same meaning as
# "the key is missing." Only true absence is blanked out, using `has` and `!= null`, and
# `false` reaches the type check still as a `boolean` (statusline follows the same shape).
hook_input_reject_reason() {
  case "$HOOK_INPUT_REJECT" in
    field-type:*)
      printf 'the hook stdin field %s is not a string (coercing the type and letting it through would be the same loss as a shifted value)' \
        "${HOOK_INPUT_REJECT#field-type:}"
      ;;
    field-newline:*)
      printf 'the hook stdin field %s cannot contain a newline (it would break the value delimiter and push the following value into the wrong field)' \
        "${HOOK_INPUT_REJECT#field-newline:}"
      ;;
    *)
      printf 'cannot read the hook stdin (%s)' "$HOOK_INPUT_REJECT"
      ;;
  esac
}

# The caller (the prerequisite gate in hook_run) has already confirmed `jq` exists.
hook_read_input() {
  local fields
  # Read all of stdin without spawning `cat` (using NUL as the delimiter reads to EOF -- `read`
  # returns 1 but the value is still populated).
  IFS= read -r -d '' HOOK_INPUT || :
  [ -n "$HOOK_INPUT" ] || hook_die "the hook's stdin is empty"
  # background_tasks only counts as "evidence present" when it's an array (neither a missing
  # key nor a non-array value is usable evidence -- both fall to the degraded path).
  # Get `now` in this **same single call** (never spawn `date` for the current time).
  fields="$(jq -r '
    ([{k: "session_id", v: (if has("session_id") and .session_id != null then .session_id else "" end)},
      {k: "agent_id", v: (if has("agent_id") and .agent_id != null then .agent_id else "" end)},
      {k: "transcript_path",
       v: (if has("transcript_path") and .transcript_path != null then .transcript_path else "" end)},
      {k: "cwd", v: (if has("cwd") and .cwd != null then .cwd else "" end)},
      {k: "agent_type", v: (if has("agent_type") and .agent_type != null then .agent_type else "" end)}]
     | map(.t = (.v | type)) | map(.v = (.v | tostring))) as $f
    | ((($f | map(select(.t != "string")))[0].k) // "") as $bad_type
    | ((($f | map(select(((.v | index("\n")) != null) or ((.v | index("\r")) != null))))[0].k) // "") as $bad_lf
    | (if $bad_type != "" then "field-type:" + $bad_type
       elif $bad_lf != "" then "field-newline:" + $bad_lf
       else "" end) as $bad
    | (if $bad_lf == "" then ($f | map(.v)) else ["", "", "", "", ""] end) as $v
    | $bad,
      $v[0], $v[1], $v[2], $v[3], $v[4],
      (if (.background_tasks | type) == "array" then "1" else "0" end),
      (if (.background_tasks | type) == "array"
       then ([ .background_tasks[] | select((.status? // "") == "running") ] | length)
       else 0 end),
      (now | floor)' <<<"$HOOK_INPUT")" ||
    hook_die "cannot parse the hook's stdin as JSON"
  {
    read -r HOOK_INPUT_REJECT
    read -r HOOK_SESSION_ID
    read -r HOOK_AGENT_ID
    read -r HOOK_TRANSCRIPT
    read -r HOOK_PAYLOAD_CWD
    read -r HOOK_AGENT_TYPE
    read -r HOOK_BG_TASKS_PRESENT
    read -r HOOK_BG_TASKS_RUNNING
    read -r HOOK_NOW
  } <<EOF
$fields
EOF
  return 0
}

# Validate what was extracted (fail-loud). **Called after the managed-marker gate** -- the
# plugin is enabled at user scope and hooks run in every project, so placing this ahead of that
# gate would print stderr and exit 1 for a broken payload **in a window rein never launched**
# (no runtime data would be created there, so the symptom is just noise and a non-zero exit --
# but a mechanism that is supposed to be doing nothing at all should not be heard from).
hook_validate_input() {
  [ -z "$HOOK_INPUT_REJECT" ] || hook_die "$(hook_input_reject_reason)"
  [ -n "$HOOK_SESSION_ID" ] || hook_die "the hook's stdin has no session_id"
  # session_id can be expanded into record and archive pathnames. Letting a path separator or
  # whitespace through would allow writing outside the intended location. This check goes
  # through one shared-library function (writing it out separately per entry point would leave
  # whichever one nobody rewrote open).
  rein_session_id_shape_ok "$HOOK_SESSION_ID" "the hook's stdin session_id" ||
    hook_die "$REIN_SESSION_ID_ERROR"
  case "$HOOK_NOW" in
    '' | *[!0-9]*) hook_die "cannot obtain the current time (cannot read jq's now)" ;;
  esac
  return 0
}

# Is this a subagent context? Judged **solely by whether agent_id is present** (agent_type is
# also present on a primary session launched with `claude --agent` -- observed; staying silent
# on that would drop the primary session out of monitoring).
hook_is_subagent() {
  [ -n "$HOOK_AGENT_ID" ]
}

# Usage state is a machine-generated, single-line JSON file placed by a writer outside rein
# (statusline). It's read here **without spawning jq** -- the only external command the no-op
# path is allowed is the one call that parses the payload, and adding a second one here would
# double that fixed cost. Extraction is written to match only a narrow shape, and falls back to
# jq for an authoritative read the moment anything is even slightly off (a key appearing twice,
# a non-numeric value).
# Returns 0 = read successfully (HOOK_PCT, HOOK_AT) / 1 = state missing or value unreadable
hook_read_usage() {
  local content=""
  HOOK_PCT=""
  HOOK_AT=""
  [ -f "$HOOK_STATE_FILE" ] || return 1
  IFS= read -r -d '' content <"$HOOK_STATE_FILE" 2>/dev/null || :
  [ -n "$content" ] || return 1
  hook_scan_json_string "$content" 'at'
  HOOK_AT="$HOOK_SCANNED"
  hook_scan_json_number "$content" 'used_percentage'
  HOOK_PCT="$HOOK_SCANNED"
  if [ -z "$HOOK_PCT" ]; then
    # Only spawn jq when the shape is off (repeated key, non-numeric value, multiple lines).
    HOOK_PCT="$(jq -r '.context_window.used_percentage // empty | floor' "$HOOK_STATE_FILE" 2>/dev/null)"
    case "$HOOK_PCT" in
      '' | *[!0-9]*)
        HOOK_PCT=""
        return 1
        ;;
    esac
  fi
  return 0
}

# Where an extraction result lands (received without spawning a `$( )` subshell).
HOOK_SCANNED=""

# Extract `"<key>":<number>` from single-line JSON (rounded to an integer). If the key appears
# more than once, there's no way to know which value is right, so it's left empty (the caller
# falls back to jq). Some writers put a space after the `:` and some don't (same JSON meaning
# either way -- putting only one shape on the fast path would make the fixed cost spike just by
# switching writers).
hook_scan_json_number() {
  local content="$1" needle="\"$2\":" rest value
  HOOK_SCANNED=""
  case "$content" in
    *"$needle "*) needle="${needle} " ;;
    *"$needle"*) ;;
    *) return 0 ;;
  esac
  rest="${content#*"$needle"}"
  case "$rest" in
    *"$needle"*) return 0 ;;
  esac
  # **Require a terminator (`,` or `}`) after the value.** The writer is outside rein, and a
  # non-atomic write (truncate with `>`, then append) is possible -- reading a half-written
  # `..."used_percentage":4` without checking for a terminator would take "everything that's
  # left" as the value, turning 41% into 4% (that Stop call would then judge it below threshold
  # and never push a handover). Unterminated input is never settled on the fast path; it falls
  # back to the caller's jq (the same treatment given to any malformed shape needing an
  # authoritative re-read).
  case "$rest" in
    *,* | *\}*) ;;
    *) return 0 ;;
  esac
  value="${rest%%,*}"
  value="${value%%\}*}"
  value="${value// /}"
  value="${value%%.*}"
  case "$value" in
    '' | *[!0-9]*) return 0 ;;
  esac
  HOOK_SCANNED="$value"
}

# Extract `"<key>":"<string>"` from single-line JSON (a value containing an escape is not
# handled -- left empty).
hook_scan_json_string() {
  local content="$1" needle="\"$2\":\"" rest value
  HOOK_SCANNED=""
  case "$content" in
    *"\"$2\": \""*) needle="\"$2\": \"" ;;
    *"$needle"*) ;;
    *) return 0 ;;
  esac
  rest="${content#*"$needle"}"
  case "$rest" in
    *"$needle"*) return 0 ;;
  esac
  value="${rest%%\"*}"
  case "$value" in
    *\\*) return 0 ;;
  esac
  HOOK_SCANNED="$value"
}

# Is usage stale (a sign the writer has stopped)? The primary evidence is state's `at` (the UTC
# time the writer stamps). Only a writer with no `at` falls back to mtime (which spawns `stat`
# once).
hook_usage_is_stale() {
  if [ -n "$HOOK_AT" ] && rein_iso_to_epoch "$HOOK_AT" >/dev/null; then
    [ "$((HOOK_NOW - REIN_ISO_EPOCH))" -gt "$HOOK_STALE_SEC" ]
    return $?
  fi
  hook_older_than "$HOOK_STATE_FILE" "$HOOK_STALE_SEC"
}

# Has the elapsed time passed the threshold (mtime version)? When mtime can't be obtained, this
# falls to the "it has" side (better to surface it for confirmation than to stay silent because
# it couldn't be determined).
hook_older_than() {
  local mtime
  mtime="$(rein_mtime "$1")"
  [ -n "$mtime" ] || return 0
  [ "$((HOOK_NOW - mtime))" -gt "$2" ]
}

# May this kind of notice fire right now? Judged by the marker's **contents (the expiry
# epoch)** -- judging by mtime would require a `stat` (external command) on every no-op path.
# Unreadable contents fall to the "may fire" side (better to surface it for confirmation than to
# stay silent).
hook_should_fire() {
  local marker expires=""
  [ -n "$HOOK_DIR" ] || return 0
  marker="$HOOK_DIR/$HOOK_SESSION_ID.$1"
  [ -e "$marker" ] || return 0
  IFS= read -r expires <"$marker" 2>/dev/null || :
  case "$expires" in
    '' | *[!0-9]*) return 0 ;;
  esac
  [ "$HOOK_NOW" -ge "$expires" ]
}

# **Claim** the right to notify (so that even if two paths -- PostToolUse and PostToolBatch --
# run in the same turn, the injection still fires only once). Only the side that wins the
# noclobber exclusive create fires; the loser stays silent. The marker is placed **before** the
# injection -- if the injection went through while the marker failed to be placed, the same
# notice would keep firing. The name never encodes the threshold's **value** (changing the
# threshold in config would otherwise effectively reset the cooldown).
# Returns 0 = claimed (may fire) / 1 = another run claimed it first (stay silent)
hook_claim_notice() {
  local kind="$1" marker claim
  hook_ensure_dir
  marker="$HOOK_DIR/$HOOK_SESSION_ID.$kind"
  claim="${marker}.claim"
  # The claim uses `mkdir`'s exclusivity (only one directory of a given name can ever be
  # created -- atomic). "Delete the marker, then recreate it with noclobber" would let another
  # run slip in during the gap between delete and recreate, so **both would get to place it and
  # both would fire** (whichever deletes second would delete the other's freshly placed marker).
  if ! mkdir "$claim" 2>/dev/null; then
    # Don't let a claim from a run that died mid-claim block the right to notify forever (clear
    # it after a grace period well beyond the hook's own cap, the registration timeout).
    if [ -d "$claim" ] && hook_older_than "$claim" "$HOOK_CLAIM_STALE_SEC"; then
      rmdir "$claim" 2>/dev/null
      mkdir "$claim" 2>/dev/null || return 1
    else
      return 1
    fi
  fi
  # Check the cooldown **again** after winning the claim. Proceeding on the result checked
  # before claiming would mean that even if another run finished firing during the wait, this
  # one would still read it as "hasn't fired yet" and fire a duplicate (the gap between checking
  # and claiming can only be closed by re-checking after the claim is won).
  if ! hook_should_fire "$kind"; then
    rmdir "$claim" 2>/dev/null
    return 1
  fi
  if ! printf '%s\n' "$((HOOK_NOW + HOOK_COOLDOWN_SEC))" >"$marker" 2>/dev/null; then
    rmdir "$claim" 2>/dev/null
    hook_die "cannot update the fire marker: ${marker}"
  fi
  rmdir "$claim" 2>/dev/null
  return 0
}

# True only when both "may fire" (cooldown) and the right to notify (exclusivity) succeed.
hook_take_notice() {
  hook_should_fire "$1" || return 1
  hook_claim_notice "$1"
}

# Revert a cooldown this run consumed back to expired (a rollback). If a run consumed the
# cooldown but failed to emit anything (output or the log write failed), leaving the marker in
# place would mean that fact never becomes loud again until the next interval -- so a failure
# after placing a persistent marker rolls the marker back before dying.
hook_expire_notice() {
  local marker
  [ -n "$HOOK_DIR" ] || return 0
  marker="$HOOK_DIR/$HOOK_SESSION_ID.$1"
  printf '%s\n' "1" >"$marker" 2>/dev/null
}

# Record the fact of exactly one injection, to check delivery later. The deadline for that
# check is also written into the contents (never spawn `stat`).
hook_pending_write() {
  local nonce="$1"
  hook_ensure_dir
  printf '%s\n%s\n%s\n' "$nonce" "$HOOK_TRANSCRIPT" "$((HOOK_NOW + HOOK_VERIFY_DELAY_SEC))" \
    >"$HOOK_PENDING_FILE" ||
    hook_die "cannot update the pending delivery-confirmation file: ${HOOK_PENDING_FILE}"
}

# Did the pending injection show up in the transcript? If not, report it. This is only checked
# once the grace period has passed, and the pending record is cleared once judged, regardless of
# the outcome.
# Matching is done with the **nonce mixed into the injected text** (PostToolBatch injections are
# recorded under a synthetic ID, and the hook side has no way to know the real tool_use_id --
# observed).
hook_verify_pending() {
  local event="$1" nonce="" transcript="" deadline=""
  [ -n "$HOOK_DIR" ] || return 0
  [ -f "$HOOK_PENDING_FILE" ] || return 0
  {
    IFS= read -r nonce
    IFS= read -r transcript
    IFS= read -r deadline
  } <"$HOOK_PENDING_FILE" 2>/dev/null || :
  case "$deadline" in
    '' | *[!0-9]*) deadline=0 ;;
  esac
  [ "$HOOK_NOW" -ge "$deadline" ] || return 0
  rm -f "$HOOK_PENDING_FILE"
  [ -n "$nonce" ] && [ -n "$transcript" ] || return 0
  # An unreadable location also counts as "can't confirm delivery" -- fall to the broken side
  # (never silently let it pass).
  if [ -r "$transcript" ] &&
    grep -q -e "hook_additional_context.*${nonce}" -e "${nonce}.*hook_additional_context" \
      "$transcript"; then
    return 0
  fi
  hook_health_note undelivered "$nonce"
  hook_emit_undelivered "$event" "$nonce"
  hook_fire_log "$event" advisory "undelivered:${nonce}"
  exit 0
}

#
# The injected text is fixed (only the numbers, the nonce, and the canonical writing-rules text
# are actual values). The text is written directly into the printf format string rather than
# assembled inside a `$()` substitution.
# The trailing `[rein:<nonce>]` is the delivery-confirmation verification token (checked for its
# literal presence in the transcript).
#
# Why the advisory text goes as far as saying "don't rush the wrap-up work itself": the trigger
# is not the context running out but **the rising per-token cost**, so the only thing that
# should be rushed is the judgment call on when to wrap up -- there's no reason to let that
# degrade the quality of the wrap-up work itself. In practice, though, sessions that received
# this advisory have rushed it anyway, in ways such as **abandoning a running delegation
# mid-flight to hand over before its results were collected** (time and tokens already spent
# even just reading its output get thrown away) and **finishing the handoff document cheaply**
# (the whole point of this mechanism is an accurate handoff, so cutting corners there makes the
# mechanism pointless). The sentence giving the user's explicit instructions top priority is
# likewise there because that same session inverted the user's own instruction under its own
# interpretation. The thresholds and firing conditions are unchanged here -- this is wording only.
#
# Why the advisory carries **the rules for writing the handoff document**: that discipline used
# to live only in the template (`rein init`), and the template only takes effect on creation --
# so **it never once reached a session editing an already-existing document** (and got violated
# as a result). It's placed at a trigger point that's guaranteed to be hit right before the
# document gets written, rather than inventing a new trigger point. The wording is never copied
# by hand; it's filled in via `%s` from the shared library's canonical text
# (REIN_HANDOFF_WRITING_RULES) -- if each place that hands this off had its own wording, the
# recipient would have no way to know which one to follow.
#
# **Carrying this on the advisory alone isn't enough.** Threshold judgment is if/elif between
# the advisory and the handover trigger, so a run that jumps straight to the handover trigger
# without ever crossing the advisory threshold never sees this advisory at all, and it also
# consumes the lower cooldown at the same time, so it won't see it later either. That very run is
# exactly the "session editing an already-existing document" case, so the same text is also
# carried by the handover trigger (hook_emit_handover) and the stop-block text
# (hook_emit_stop_block) -- all three carry it. The thresholds, firing conditions, and branch
# structure are unchanged -- this is wording only.

hook_emit_notice() {
  printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"[rein] Context usage has passed %d%% (currently %d%%). From here on, the per-token cost rises, so decide when to wrap up: look at how much work remains, push to a clean completion point, then finish writing the handoff document and wrap up. If you are close to done, it is fine to prioritize finishing over a modest overrun. Judge it by whether usage is likely to go well past the %d%% line. If the task itself is far too large to finish, hand it over at the nearest good breakpoint. Only the timing decision is urgent -- do not rush the wrap-up work itself: collect the results of any running delegation before wrapping up (time and tokens are already spent even if all you did was read its output, and cancelling throws that away), and do not finish the handoff document cheaply (accuracy is the whole point of this mechanism). Explicit instructions from the user take priority over this advisory. %s[rein:%s]"}}\n' \
    "$1" "$HOOK_THRESHOLD_NOTICE" "$2" "$HOOK_THRESHOLD_HANDOVER" "$REIN_HANDOFF_WRITING_RULES" "$3"
}

# The handover-trigger text carries the same **conditional clause** as the advisory ("this is a
# call to decide, not a forced termination" -- meaning finishing takes priority when close to
# done). Without that clause it reads as an unconditional order to wrap up, and a session has in
# fact wrongly started wrapping up while one item still remained. The thresholds and firing
# conditions are unchanged here -- this is wording only.
#
# **The branches are numbered and ordered by priority.** Even with the conditional clause in
# place, if an imperative sentence sits at the top, the reader acts on it the moment they read
# it and never evaluates the remaining branches (this actually happened: a session that had been
# told by the user to "just finish making the call" skipped past the conditional clause naming
# which branch applied and executed the wrap-up instruction at the top instead). The failure was
# not "judged wrong" but "never judged at all," so the ordering itself is the fix. Branch (1),
# "the user's explicit instructions take priority," is not new -- it's a restoration: it was
# already present in the advisory (hook_emit_notice), but had gone missing from exactly this
# highest-pressure channel and from the stop-block text. The order is pinned by selftest
# (st_expect_order) -- a wording check alone only sees "is it present," so it would silently
# regress the next time someone touched the wording.
hook_emit_handover() {
  printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"[rein] Context usage has reached %d%% (currently %d%%). %d%% is not a forced termination -- it is a call to make a decision. Decide in this order: (1) If the user gave explicit instructions, those take priority over this. (2) If you are close to done, it is fine to prioritize finishing over a modest overrun. (3) If there is no clean breakpoint yet and you cannot finish the handoff document, push to the nearest breakpoint and then finish it. (4) Otherwise, finish the handoff document and wrap up before usage goes much further past this line (if the task itself is far too large to finish, wrap up now). %s[rein:%s]"}}\n' \
    "$1" "$HOOK_THRESHOLD_HANDOVER" "$2" "$HOOK_THRESHOLD_HANDOVER" "$REIN_HANDOFF_WRITING_RULES" "$3"
}

hook_emit_missing() {
  printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"[rein] The usage state file was not found. Monitoring is not working (statusline is not configured, or its writer is malfunctioning). Please check the cause. [rein:%s]"}}\n' \
    "$1" "$2"
}

# These two carry a **path** in the body (`<usage_state_dir>/<session_id>.json`). The path is a
# literal value from the config layer and can contain `"` or `\` (both legal in a macOS
# filename). Embedding it directly in a printf format string would corrupt the JSON --
# **exactly the injection meant to report an anomaly would be the one that silently fails, and
# precisely when the config itself is broken.** The body is built into a variable and JSON
# encoding is left to jq (the same discipline used on the stop-block side).
hook_emit_invalid() {
  local text
  printf -v text '[rein] Cannot read used_percentage from the state file (%s). This points to a problem with the writer or its payload. Please check the cause. [rein:%s]' \
    "$2" "$3"
  jq -nc --arg event "$1" --arg context "$text" \
    '{hookSpecificOutput: {hookEventName: $event, additionalContext: $context}}'
}

# The minute count comes from the effective freshness threshold (so the wording and the config
# can never drift apart).
hook_emit_stale() {
  local text
  printf -v text '[rein] The state file has not been updated in over %d minutes. statusline may have stopped (%s). [rein:%s]' \
    "$((HOOK_STALE_SEC / 60))" "$2" "$3"
  jq -nc --arg event "$1" --arg context "$text" \
    '{hookSpecificOutput: {hookEventName: $event, additionalContext: $context}}'
}

hook_emit_undelivered() {
  printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"[rein] The notice just sent did not reach the transcript (verification token %s). The monitoring injection path may be broken. Please check the cause. [rein:%s]"}}\n' \
    "$1" "$2" "$(rein_nonce)"
}

# A handover request has been placed, but no watcher is around. There's no one to clear the
# marker, so leaving it alone means nobody ever advances the handover while the context keeps
# running out. The recovery action (starting the watcher) can only be done by the user, so the
# model is asked to relay that request to them. The reason behind that judgment is deliberately
# not included -- a `ps` command line, if it made it in verbatim, could corrupt the JSON string,
# so carrying the reason at all is left to the stop-block side, which builds JSON via jq.
# **The message is split between "not running" (rc=1) and "can't determine whether it's
# running" (rc=2)** -- falling to "please start it" for a case that can't be determined
# (unreadable watcher-lock owner, non-numeric value) would risk starting a second one against a
# lineage that's actually being watched. A case where identity itself was checked (a stale lock
# from a reused PID) belongs on the rc=1 side, where "please start it" resolves it (the next
# acquire performs the same check and reclaims that lock).
# The body is built into a variable rather than inside a `$()`.
# JSON encoding is left to jq, so the reason for that determination (which can contain a `ps`
# command line) can be carried verbatim without corrupting the string.
HOOK_WATCHER_TEXT=""
hook_watcher_missing_text() {
  local rc="$1"
  # Fill the lineage's name into the message from its effective value, so the one-liner never
  # points at the wrong lineage. **Building it also goes through one shared function** --
  # sharing only the options and hand-assembling the wording would let the way the command is
  # quoted, or where the verb sits, drift between call sites.
  if [ "$rc" -eq 1 ]; then
    rein_lineage_cmd "$REIN_BIN" "$RUNTIME_DIR" "$RECORDS_DIR" "$TARGET_CWD" up
    printf -v HOOK_WATCHER_TEXT '[rein] A handover request has been placed, but the watcher is not running (%s). There is no one to process the request, so continuing will not produce a handover. Ask the user to run the following:\n\n%s\n\nOnce it starts, the handover request already in place will be processed as-is (no need to place it again).' \
      "$REIN_WATCHER_REASON" "$REIN_LINEAGE_CMD"
    return 0
  fi
  printf -v HOOK_WATCHER_TEXT '[rein] A handover request has been placed, but whether the watcher is running cannot be determined (%s). There is no guarantee the request will be processed, so ask the user to check the owner of the watcher lock at %s.' \
    "$REIN_WATCHER_REASON" "$RUNTIME_DIR/$REIN_LOCK_DIRNAME"
}

hook_emit_watcher_missing() {
  jq -nc --arg event "$1" --arg context "$HOOK_WATCHER_TEXT [rein:$2]" \
    '{hookSpecificOutput: {hookEventName: $event, additionalContext: $context}}'
}

# The side that blocks the stop (the official Stop shape) over the same fact. The generation
# latch is not consumed here -- the normal handover trigger, once the watcher comes back, still
# has one use left for that generation.
hook_emit_watcher_missing_block() {
  jq -nc --arg reason "$HOOK_WATCHER_TEXT" '{decision: "block", reason: $reason}'
}

# The one line telling the user "the wait before the handover has started."
#
# **This goes to `systemMessage`, not to the model's channels** (`additionalContext` /
# `reason`). The reader is the user sitting at the seat, deciding within the wait window
# whether to skim the response that just landed or speak up and cancel -- routing it through
# the model would neither reach them at that moment nor say anything the model can act on. A
# Stop hook's `systemMessage` reaches the screen **even on a run that doesn't block the stop**
# (measured; the official documentation states no display condition for this field).
#
# **The number is `final_output_wait_sec`'s effective value as-is, with no correction.** The
# real remaining time is always longer than what's shown -- the watcher only notices the marker
# on one of its later polls, and the marker is typically placed before the request has even been
# accepted, so the accepting work sits inside the gap too. No bound is put on the gap; the error
# is on the safe side (the user always has at least as long as the line claims). The
# time of day is deliberately absent: a person can't read the current second off their own
# head, and going to look for a clock spends the very window this line is about.
hook_emit_handover_wait() {
  jq -nc --arg sec "$HOOK_FINAL_OUTPUT_WAIT_SEC" \
    '{systemMessage: ("[rein] Handover in " + $sec + " s. Talk to this session to cancel.")}'
}

# The reason given for blocking a stop (the official Stop shape: decision / reason). The path is
# shell-escaped and carried as a single token (so a cwd containing whitespace or `;` never
# splits the argument). JSON assembly is left to jq.
#
# **The session ID is always filled with its real value** (leaving a placeholder would force the
# recipient to either guess their own ID without knowing it, or stop and ask a person). **The
# handoff document is likewise always filled with its real value** (there's a default, so an
# effective value is always defined) -- this matches the handover-request command the watcher's
# kickoff message carries, so the same operation is never explained two different ways. The only
# case where it can't be resolved is a lineage that has explicitly set `handoff_path` empty in
# config, and only then is the placeholder shown, with one clause explicitly telling the reader
# to replace it.
#
# **Passing the second argument (a rejection reason) changes only the lead-in, into the
# rejection framing.** The one-liner to run (a handover request, or a snooze) has to be
# identical between the two call sites, so the wording is never written out twice in full --
# doing that would let one site's real-value substitution go stale while the other stayed
# current.
hook_emit_stop_block() {
  local pct="$1" rejected="${2:-}" reason lead request_cmd snooze_cmd
  local handoff=" --handoff <absolute path to the handoff document>"
  local note=$'(Replace `<absolute path to the handoff document>` with the absolute path of the document you just finished writing.)\n\n'
  if [ -n "$HOOK_HANDOFF_PATH" ]; then
    printf -v handoff ' --handoff %s' "$(rein_shell_quote "$HOOK_HANDOFF_PATH")"
    note=""
  fi
  # Fill the lineage's name into the message from its effective value, so the one-liner never
  # points at the wrong lineage. **Building it also goes through one shared function** (this
  # site only owns the text appended after the verb).
  rein_lineage_cmd "$REIN_BIN" "$RUNTIME_DIR" "$RECORDS_DIR" "$TARGET_CWD" request \
    "--session-id ${HOOK_SESSION_ID}${handoff}"
  request_cmd="$REIN_LINEAGE_CMD"
  rein_lineage_cmd "$REIN_BIN" "$RUNTIME_DIR" "$RECORDS_DIR" "$TARGET_CWD" snooze "30m"
  snooze_cmd="$REIN_LINEAGE_CMD"
  if [ -n "$rejected" ]; then
    # **Carrying the reason verbatim is the whole point.** Every rejection reason is a defect in
    # the request itself (see the watcher's freshness checks R1-R10), so resubmitting the same
    # content just fails for the same reason -- only once the reason is known can a fixed
    # request be sent. The reason is carried verbatim, never summarized -- the observed value
    # itself is the next actionable step.
    printf -v lead '[rein] The handover request you just made was not accepted (rejection reason: %s). The rejection reason is a defect in the request itself, so fixing it will let the same request through. Context usage is %d%% (the handover trigger point is %d%%). This is the only time the stop will be blocked for this rejected generation.' \
      "$rejected" "$pct" "$HOOK_THRESHOLD_HANDOVER"
  else
    printf -v lead '[rein] Context usage has reached %d%% (the handover trigger point is %d%%). This is the only time the stop will be blocked for this generation.' \
      "$pct" "$HOOK_THRESHOLD_HANDOVER"
  fi
  # **This is the one trigger point that says "write the document now,"** so the canonical
  # writing-rules text is carried in this same message too (the advisory channel is never
  # reached by a run that jumps straight past its threshold -- carrying the rules only there
  # would mean a session editing an already-existing document never sees them). The wording is
  # never copied by hand; it's filled in from the shared library's value.
  #
  # **The branches are numbered and ordered by priority** (same reasoning as the handover
  # trigger -- written out verbatim in that function's own comment). This text used to lead with
  # the imperative "run the handover request command" and tack the other two branches on
  # afterward as caveats -- the reader would act on the lead the moment they read it and never
  # evaluate the caveat naming which branch actually applied to them. The imperative is moved
  # to the end (4), with (1)-(3) placed first as parallel judgment steps. `note` (the reminder
  # to replace the placeholder path) is attached right after request_cmd -- moving a branch
  # means moving its note along with it. The order is pinned by selftest (st_expect_order).
  printf -v reason '%sDecide in this order.\n\n(1) If the user gave explicit instructions, those take priority over this block.\n\n(2) If you are close to done, it is fine to prioritize finishing over a modest overrun -- but even then, finish writing the handoff document before you wrap up.\n\n(3) If there is no clean breakpoint yet and you cannot finish the document, you can snooze for just that period:\n\n%s\n\n(4) Otherwise, finish the handoff document, then run the handover request command:\n\n%s\n\n%s%s' \
    "$lead" "$snooze_cmd" "$request_cmd" "$note" "$REIN_HANDOFF_WRITING_RULES"
  jq -nc --arg reason "$reason" '{decision: "block", reason: $reason}'
}

# The fire log and health state are kept in different locations because they track different
# things.

# The log that records only firings (a branch that actually emitted an injection or blocked a
# stop). The no-op path is never recorded -- the line count is itself the firing record. It
# lives in rein's own state (the runtime directory's parent), not in the user's own log
# (`~/.claude/state/`) -- that one gates writes on "is the running script in the location the
# user's own harness treats as canonical," and rein's own binary sits outside that, so writing
# there would produce nothing but a warning banner on stderr with not a single line actually
# recorded.
# The payload itself is never stored (it can contain secrets). A single-line append is atomic
# via O_APPEND, so no lock is needed for that; a lock is only taken **for rotation**.
hook_fire_log() {
  local event="$1" decision="$2" reason="$3" file line selftest=false
  [ -n "$STATE_ROOT" ] || return 0
  file="$STATE_ROOT/$REIN_FIRE_LOG_BASENAME"
  mkdir -p "$STATE_ROOT" 2>/dev/null ||
    hook_record_failed "cannot create the fire log location (this firing will not be recorded): ${STATE_ROOT}"
  [ -d "$STATE_ROOT" ] || return 0
  # Since the append uses `>>`, a symlink would grow whatever it points to (possibly outside the
  # project), and a dangling symlink would **create** its target -- while the caller still reads
  # it as success. This runs through **the same one check** used by the watcher log, the handover
  # log, and the hooks log (so this log doesn't become the one asymmetric exception that skips
  # it). The rotation `mv` is likewise placed after this check, so a file in an unacceptable
  # shape is never rotated. The failure text matches this log's existing wording ("cannot write
  # to the fire log (this firing will not be recorded)"), with the shared predicate's own line
  # naming the shape attached as-is (never phrased two different ways for the same situation).
  if ! rein_dest_shape_ok "$file"; then
    hook_record_failed "cannot write to the fire log (this firing will not be recorded): ${REIN_DEST_SHAPE_ERROR}"
    return 0
  fi
  [ "${REIN_HOOK_SELFTEST:-0}" = "1" ] && selftest=true
  hook_fire_log_rotate "$file"
  line="$(jq -nc \
    --arg schema "$REIN_HOOK_FIRE_SCHEMA" \
    --arg at "$(rein_iso_now)" \
    --arg event "$event" \
    --arg decision "$decision" \
    --arg reason "$reason" \
    --arg session_id "$HOOK_SESSION_ID" \
    --arg lineage "$TARGET_CWD" \
    --arg cwd "$HOOK_PAYLOAD_CWD" \
    --arg protocol "$REIN_HOOK_PROTOCOL" \
    --argjson selftest "$selftest" \
    --slurpfile manifest "$REPO_ROOT/$REIN_PLUGIN_MANIFEST_RELPATH" \
    '{schema: $schema, at: $at, event: $event, decision: $decision, reason: $reason,
      session_id: $session_id, lineage_cwd: $lineage, cwd: $cwd,
      runner: {version: ($manifest[0].version // "unknown"), protocol: $protocol},
      selftest: $selftest}' 2>/dev/null)" || line=""
  if [ -z "$line" ]; then
    hook_record_failed "cannot assemble a fire log line (this firing will not be recorded): ${file}"
    return 0
  fi
  printf '%s\n' "$line" >>"$file" 2>/dev/null ||
    hook_record_failed "cannot write to the fire log (this firing will not be recorded): ${file}"
  return 0
}

# Rotate exactly one generation once the size cap is hit (never grow unbounded; only one old
# generation is ever kept). Rotation runs under a lock (if two hooks `mv` at the same time, one
# of their appends lands in the generation that just got rotated away).
# **A lock whose owner is gone gets reclaimed** (the same discipline as up / down / watcher /
# prune). A hook can be cut off from outside by the registration timeout (10 seconds), so if
# that happens mid-rotation the lock is left behind -- without reclaiming it, this one file,
# shared across every lineage, would never be rotated again past the cap and would just keep
# growing (doctor only emits a WARN; it doesn't resolve this on its own).
hook_fire_log_rotate() {
  local file="$1" size lock="$1.lock" token
  size="$(rein_file_size "$file")"
  [ -n "$size" ] || return 0
  [ "$size" -ge "$REIN_HOOK_FIRE_LOG_MAX_BYTES" ] || return 0
  token="$(rein_nonce)"
  rein_claim_lock_dir_or_reclaim "$lock" \
    start "$(rein_process_start_identity "$$")" \
    mode "$REIN_LOCK_MODE_FIRE_LOG" \
    token "$token" || return 0
  size="$(rein_file_size "$file")"
  if [ -n "$size" ] && [ "$size" -ge "$REIN_HOOK_FIRE_LOG_MAX_BYTES" ]; then
    # Silently returning when rotation fails would let the log keep growing past the cap
    # (with no way to notice, since the next hook would fail the same way).
    mv "$file" "$file.1" 2>/dev/null ||
      hook_record_failed "cannot rotate the fire log (it will keep growing past the cap): ${file}"
  fi
  # Release only the lock for this run's own generation (leave it alone if a different, cut-off
  # hook already reclaimed it).
  rein_release_lock_dir_if_mine "$lock" "$token"
  return 0
}

# State used to check from outside whether rein's own hooks are alive. This targets something
# different from the fire log (which records what was emitted) -- an anomaly in **not** emitting
# anything (the registration isn't working, the launcher can't resolve the real file, an
# injection isn't being delivered) can't be judged from a log's line count, so it's kept in a
# separate location.
# One file, one fact (concurrent reads and writes never get mixed together; no lock, no reread
# needed).
hook_health_touch() {
  hook_health_dir_ready || return 0
  printf '%s\n' "$HOOK_NOW" >"$HOOK_HEALTH_DIR/last-seen.$1" 2>/dev/null ||
    hook_record_failed "cannot write hooks state (doctor will read this lineage's hooks as not delivering): ${HOOK_HEALTH_DIR}/last-seen.$1"
  return 0
}

# Record one fact (an undelivered injection, an internal error). Time, kind, and detail on a
# single line.
hook_health_note() {
  local kind="$1" detail="$2"
  hook_health_dir_ready || return 0
  printf '%s\t%s\t%s\n' "${HOOK_NOW:-0}" "${HOOK_EVENT:-unknown}" "$detail" \
    >"$HOOK_HEALTH_DIR/$kind" 2>/dev/null ||
    hook_record_failed "cannot write hooks state (${kind}) (this fact will not show up in doctor): ${HOOK_HEALTH_DIR}/${kind}"
  return 0
}

# The location is only prepared **when this lineage is actually using rein** (i.e. when a
# runtime directory exists) -- state is never created for a project that doesn't use rein. If it
# already exists, `mkdir` is never spawned (adding one external command to the no-op path
# becomes a fixed cost on every single tool call).
hook_health_dir_ready() {
  [ -n "$HOOK_HEALTH_DIR" ] || return 1
  [ -d "$HOOK_HEALTH_DIR" ] && return 0
  # No runtime directory means this lineage isn't using rein. That's not an anomaly, so this
  # returns silently (kept separate from "the location couldn't be created" -- only the latter
  # is surfaced).
  [ -d "$RUNTIME_DIR" ] || return 1
  if ! mkdir -p "$HOOK_HEALTH_DIR" 2>/dev/null; then
    hook_record_failed "cannot create the hooks state location (doctor will read this lineage's hooks as not delivering): ${HOOK_HEALTH_DIR}"
    return 1
  fi
  return 0
}

# The lineage-wide log that hooks write to. This is kept separate because the handover log
# (handover.log) and the watcher log (watcher.log) both have exactly one contractual writer: the
# watcher.
# **Assembly is kept separate from the write** -- if the line isn't built before a persistent
# marker (a latch, a dedup guard) is placed, there's no way to roll back a case where "the
# marker was consumed but the log couldn't be written."
hook_log_line() {
  jq -nc \
    --arg schema "$REIN_HOOK_LOG_SCHEMA" \
    --arg ts "$(rein_iso_now)" \
    --arg event "$1" \
    --arg detail "$2" \
    --arg session_id "$HOOK_SESSION_ID" \
    '{schema: $schema, ts: $ts, event: $event, detail: $detail, session_id: $session_id}'
}

hook_log_append() {
  rein_ensure_records_dir "$RECORDS_DIR" || return 1
  # Since the append uses `>>`, a symlink would grow whatever it points to (possibly outside the
  # project). The reason is reported here -- the caller, hook_die, can only say "cannot write
  # the log."
  if ! rein_dest_shape_ok "$HOOK_LOG_FILE"; then
    printf '%s: %s\n' "$SCRIPT_NAME" "$REIN_DEST_SHAPE_ERROR" >&2
    return 1
  fi
  printf '%s\n' "$1" >>"$HOOK_LOG_FILE" || return 1
  return 0
}

# A marker naming this run (only the run that placed it may revoke it -- never delete a latch or
# dedup guard that a different run placed).
hook_token() {
  printf '%s:%s\n' "$HOOK_SESSION_ID" "$(rein_nonce)"
}

# Revoke a persistent marker this run placed ($1=file, $2=line to match, $3=this run's token).
hook_revoke() {
  [ -f "$1" ] || return 0
  [ "$(sed -n "${2}p" "$1" 2>/dev/null)" = "$3" ] || return 0
  rm -f "$1" 2>/dev/null
  return 0
}

# A dedup guard that stops the same fact from adding a line on every single turn (Stop runs at
# every turn boundary). The marker records what it's a record of (an expiry for a snooze, a
# generation for a deferred handover) -- when that changes, one new line is written again. The
# marker is updated first -- if only the log went through while the marker could not be updated,
# the same line would keep piling up. But **when the log couldn't be written, the marker this
# run just placed is rolled back** -- if only the marker were left in place, that fact would go
# unrecorded and never become loud again.
hook_log_once() {
  local kind="$1" token="$2" event="$3" detail="$4" mark line owner
  mark="$HOOK_DIR/$HOOK_SESSION_ID.${kind}-logged"
  if [ -f "$mark" ] && [ "$(head -1 "$mark" 2>/dev/null)" = "$token" ]; then
    return 0
  fi
  line="$(hook_log_line "$event" "$detail")"
  [ -n "$line" ] || hook_die "cannot assemble a hooks log line"
  owner="$(hook_token)"
  hook_ensure_dir
  # Line 1 = the dedup marker (only this is checked next time); line 2 = the marker of the run
  # that placed it (used to match on revocation).
  printf '%s\n%s\n' "$token" "$owner" >"$mark" ||
    hook_die "cannot update the dedup marker: ${mark}"
  if ! hook_log_append "$line"; then
    hook_revoke "$mark" 2 "$owner"
    hook_die "cannot write the hooks log: ${HOOK_LOG_FILE}"
  fi
}

hook_snooze_remaining() {
  local until epoch
  [ -f "$SNOOZE_FILE" ] || return 1
  until="$(hook_snooze_until)"
  [ -n "$until" ] || return 1
  epoch="$(rein_iso_to_epoch "$until")" || return 1
  [ "$epoch" -gt "$HOOK_NOW" ] || return 1
  printf '%s\n' "$((epoch - HOOK_NOW))"
}

hook_snooze_until() {
  jq -r --arg s "$REIN_SNOOZE_SCHEMA" \
    'select(.schema == $s) | .until // empty' "$SNOOZE_FILE" 2>/dev/null
}

# Judges "this session has not submitted a handover request." If the pending marker's
# session_id is this session's own, the request is already submitted. It shares its format with
# the marker's writer (rein request) but only reads it -- never adds a second writer.
hook_marker_is_mine() {
  local sid
  [ -f "$MARKER_FILE" ] || return 1
  sid="$(jq -r --arg s "$REIN_MARKER_SCHEMA" \
    'select(.schema == $s) | .session_id // empty' "$MARKER_FILE" 2>/dev/null)"
  [ "$sid" = "$HOOK_SESSION_ID" ]
}

# A claimed marker (one the watcher moved into `processing/` while it's being judged) also
# counts as submitted if it belongs to this session. The watcher `mv`s a marker into
# `processing/` **before reading it** (part of the contract), so looking only at the pending
# marker would read "not
# submitted" for the entire time it's being judged, and push a session that already
# submitted to request a handover again.
hook_processing_is_mine() {
  local dir="$RUNTIME_DIR/$REIN_PROCESSING_DIRNAME" file sid
  [ -d "$dir" ] || return 1
  for file in "$dir"/*.json; do
    [ -f "$file" ] || continue
    sid="$(jq -r --arg s "$REIN_MARKER_SCHEMA" \
      'select(.schema == $s) | .session_id // empty' "$file" 2>/dev/null)"
    if [ "$sid" = "$HOOK_SESSION_ID" ]; then
      return 0
    fi
  done
  return 1
}

hook_request_submitted() {
  hook_marker_is_mine && return 0
  hook_processing_is_mine
}

# Place the single-line marker the watcher reads while waiting on a handover (final-output
# marker, cancel marker). **If one is already there with this session's own contents, it's never
# rewritten** -- both channels run on every turn for as long as the session that submitted the
# request keeps talking to the user, so rewriting would let writes pile up on the no-op path.
# The write uses a plain `>`; it deliberately does not go through the atomic-replace pattern
# (mktemp + mv) -- the reason is written out verbatim next to the marker constants
# (lib/rein-common.sh).
# **Returns whether this call newly placed it** (0 = placed / 1 = this session's own marker was
# already there) -- even if the write itself is a no-op, the recording side would still grow
# with every prompt, so the caller only records on the call that actually placed it.
hook_place_mark() {
  local file="$1" current=""
  if [ -f "$file" ]; then
    IFS= read -r current <"$file" 2>/dev/null || current=""
    if [ "$current" = "$HOOK_SESSION_ID" ]; then
      return 1
    fi
  fi
  hook_ensure_dir
  printf '%s\n' "$HOOK_SESSION_ID" >"$file" ||
    hook_die "cannot place the handover marker: ${file}"
  return 0
}

# Is this a lineage where the final-output marker and cancel marker may be placed at all? (A
# lineage with `final_output_timeout_sec` set to 0 has no waiting step for the watcher to begin
# with -- placing the marker would have no one to read it.)
hook_final_output_enabled() {
  [ "$HOOK_FINAL_OUTPUT_TIMEOUT_SEC" != "0" ]
}

# **This run's one and only watcher-liveness judgment**, cached after the first call.
#
# Stop asks the same question in two places -- the handover-wait notice below, and the
# watcher-missing block further down -- and both must get **the same answer**. Judging twice
# independently is what would let a watcher dying in between put both branches in the emitting
# state on the same run, and a Stop hook's output is a single JSON object. With one shared
# judgment, "exactly one object" follows from the branch structure itself: if the notice went
# out the answer was "resident," so the block's own `rc == 0` branch always exits before
# printing anything. It also keeps the `ps` this spawns to at most one per run.
#
# The reason text (REIN_WATCHER_REASON) is set by the underlying judgment and stays set for the
# rest of the run, so the block below still reports exactly the reason it was judged on.
# 0=resident / 1=not resident / 2=cannot be determined (rein_watcher_state's own categories)
hook_watcher_resident() {
  if [ -z "$HOOK_WATCHER_RC" ]; then
    rein_watcher_state "$RUNTIME_DIR" "$TARGET_CWD"
    HOOK_WATCHER_RC=$?
  fi
  return "$HOOK_WATCHER_RC"
}

# Tell the user, exactly once per generation, that the wait before the handover has started.
#
# **What holds this to once is a latch of its own, placed only when a line actually went out.**
# It used to ride on hook_place_mark's "this run newly placed the marker," but the two do not
# share a condition: the marker goes down whether or not a watcher is around, while this line
# is only true when one is. So on a lineage whose watcher was gone when the request was made,
# the marker -- placed first -- consumed the single chance to speak, and every later turn found
# the marker already this session's own and took the no-op path. Bringing the watcher back with
# `rein up` then handed over with the terminal switching under the user with no warning at all.
# With a latch of its own, the first turn after the watcher is back says the line, and no turn
# after that says it again.
#
# **The latch is per generation, and the same shape as stop-latch.g<generation>** -- so
# hook_prune_old_latches folds it away with the others rather than leaking one file per
# handover.
#
# **The latch is read before the watcher judgment.** Every turn after the line has gone out
# folds on a single `[ -e ]` and spawns nothing, so the no-op path's fixed cost is untouched
# (the header's budget for it still holds: one jq for the payload, nothing else). The turns
# that do pay one `ps` are the ones where a request is submitted and this generation has not
# been told yet -- the same cost the advisory channel already accepts on a submitted turn, and
# it stops the moment the line goes out.
#
# **A lineage whose wait is 0 seconds says nothing.** The watcher leaves the wait on the same
# poll that sees the marker, so "Handover in 0 s. Talk to this session to cancel." would be
# false in both halves at once -- there is no window, and nothing to speak up into. Note this
# is a condition on **the line only**: the marker keeps being placed exactly as before (its own
# gate is the cap, hook_final_output_enabled -- a different setting).
#
# **The watcher being resident is a condition here, unlike for the marker itself.** With no
# watcher, nothing ever picks the marker up and no handover ever starts -- a countdown line
# would simply be false. This asks the run's single shared judgment (hook_watcher_resident --
# the lock's pid is alive and cross-checked as this location's watcher), the same one the
# watcher-missing block below reads.
#
# **Returns whether it emitted** (0 = a line went out / 1 = nothing did).
hook_handover_wait_notice() {
  local notice latch token
  [ "$HOOK_FINAL_OUTPUT_WAIT_SEC" != "0" ] || return 1
  latch="$HOOK_DIR/handover-wait.g${REIN_POINTER_GENERATION}"
  [ -e "$latch" ] && return 1
  hook_watcher_resident || return 1
  notice="$(hook_emit_handover_wait)"
  [ -n "$notice" ] || hook_die "cannot assemble the handover-wait notice"
  # **Assemble first, then consume the latch, then print** -- the order every other emitting
  # branch uses. Consuming it earlier would let a failure in between mark this generation as
  # told with not one character having reached the screen, and nothing would ever say it again.
  token="$(hook_token)"
  hook_claim_latch "$latch" "$token" || return 1
  # The output goes out **before** the firing is recorded, matching every other emitting branch
  # (a run cut off by the registration timeout must never leave a record of a line that never
  # reached the screen).
  printf '%s\n' "$notice"
  hook_fire_log Stop notice "handover-wait"
  return 0
}

# If this session's handover request was **rejected**, return the reason for it on stdout.
#
# The watcher moves a rejected marker into `<runtime>/rejected/` and appends the rejection
# reason (`rejected_reason`) to that record (see rein-watcher.sh's
# `record_rejection_reason`). The archive name starts with a UTC timestamp, so **the glob
# order is already chronological** -- read from the newest end and return the first one that's
# ours (the most recently rejected reason is the one to act on now).
#
# `jq` is spawned once per file rather than reading several at once, because the archive can
# contain a record that doesn't parse as JSON (an R1 rejection) -- reading multiple files in one
# call would let that single bad one fail the whole scan and lose the valid record next to it.
# The caller checks the marker (the rejection generation latch) first, so a generation that's
# already been re-blocked never reaches this.
# Returns 0 = returned a reason / 1 = no rejection of ours, or unreadable
hook_rejection_reason() {
  local dir="$RUNTIME_DIR/$REIN_REJECTED_DIRNAME" file i reason
  local files=()
  [ -d "$dir" ] || return 1
  for file in "$dir"/*.json; do
    [ -f "$file" ] || continue
    files+=("$file")
  done
  [ "${#files[@]}" -gt 0 ] || return 1
  for ((i = ${#files[@]} - 1; i >= 0; i--)); do
    reason="$(jq -r --arg s "$REIN_MARKER_SCHEMA" --arg sid "$HOOK_SESSION_ID" \
      'select(.schema == $s) | select(.session_id == $sid) | .rejected_reason // empty' \
      "${files[$i]}" 2>/dev/null)"
    if [ -n "$reason" ]; then
      printf '%s\n' "$reason"
      return 0
    fi
  done
  return 1
}

# Are there running children (subagents) under this session?
#
# The primary evidence is **the Stop payload's `background_tasks`** (observed: while a child is
# running, its entry's `status` is `running`, and this reverts to an empty array once it
# completes). This is undocumented, so a missing key or a non-array value are both possible --
# only then does this fall back to transcript freshness. Freshness is the time of the last
# write, not liveness itself, so it's never treated as the primary evidence.
hook_children_active() {
  if [ "$HOOK_BG_TASKS_PRESENT" -eq 1 ]; then
    [ "$HOOK_BG_TASKS_RUNNING" -gt 0 ]
    return $?
  fi
  hook_log_once bg-tasks-missing missing "children_probe_degraded" \
    "the hook's stdin has no background_tasks (falling back to transcript freshness for child liveness)"
  hook_children_active_by_mtime
}

# The fallback judgment. A child's transcript lives at
# `<transcript location>/<session_id>/subagents/agent-*.jsonl` (observed). An
# unreadable or missing location is treated as "no children" (fail-open) -- a missing location
# is indistinguishable from the normal case of having no children. A false positive only costs a
# delay of the latch until the next stop.
hook_children_active_by_mtime() {
  local dir file
  dir="$(rein_child_records_dir "$HOOK_TRANSCRIPT" "$HOOK_SESSION_ID")" || return 1
  [ -d "$dir" ] || return 1
  while IFS= read -r -d '' file; do
    [ -n "$file" ] || continue
    # The expiry cutoff goes through the shared judgment (the same one the handover request
    # applies to a ledger entry) -- two readers expiring a child at different moments would let
    # a handover be refused by one and allowed by the other for the very same child.
    if rein_child_active_at "$(rein_mtime "$file")" "$HOOK_NOW"; then
      return 0
    fi
  done < <(find "$dir" -maxdepth 1 -type f -name 'agent-*.jsonl' -print0 2>/dev/null)
  return 1
}

# The ledger of running children -- one file per child, placed by SubagentStart and removed by
# SubagentStop.
#
# **Why a ledger exists at all**: the Stop payload's `background_tasks` is evidence that reaches
# the hooks and nothing else. `rein request` is a separate process with no payload, so it had no
# way to see a child at all, and a handover requested mid-run replaced the parent and took its
# children down with it (observed: of 3 children running, 2 ended having written nothing).
#
# **Why the parent's session_id is part of the name**: stopping the predecessor externally is
# exactly what a handover does, and a session stopped that way never delivers SubagentStop
# (observed), so leftover entries are unavoidable. Each session reads only the entries carrying
# its own session_id, so residue from an earlier generation is inert by construction -- it can
# never be the thing that blocks the next generation's handover. (Sweeping it away is `rein
# prune`'s job, and only so the location doesn't grow without bound.)
#
# Both events carry an `agent_id` **always** (observed), and for these two it names the subject,
# not the context -- so they are the one pair exempted from the subagent silence gate (see
# hook_run).
CHILD_ENTRY_FILE=""
hook_child_prepare() {
  hook_prepare
  # Fail loud rather than fall back to a shared name: without agent_id there is no way to tell
  # one child from another, and a single shared entry would have the first child to finish erase
  # the record of every sibling still running.
  [ -n "$HOOK_AGENT_ID" ] ||
    hook_die "the ${HOOK_EVENT} payload has no agent_id (the running child cannot be identified)"
  # agent_id is expanded into a filename, so the same shape check session_id goes through applies
  # here too -- a path separator or whitespace would let the entry land outside the ledger.
  rein_session_id_shape_ok "$HOOK_AGENT_ID" "the hook's stdin agent_id" ||
    hook_die "$REIN_SESSION_ID_ERROR"
  CHILD_ENTRY_FILE="$CHILDREN_DIR/$HOOK_SESSION_ID.$HOOK_AGENT_ID"
  return 0
}

# Only prepare the location right before writing (the same discipline as hook_ensure_dir -- a
# project that never uses rein has no state created for it).
hook_ensure_children_dir() {
  [ -d "$CHILDREN_DIR" ] && return 0
  rein_ensure_runtime_dir "$RUNTIME_DIR" "$TARGET_CWD" || hook_die "$REIN_RUNTIME_ERROR"
  mkdir -p "$CHILDREN_DIR" || hook_die "cannot create the children ledger location: ${CHILDREN_DIR}"
  return 0
}

# 3 lines: the child's kind, the moment it was registered, and where its own record lives.
# **The registration moment is content, not the entry's mtime** -- the reader prints how long the
# child has been running, and reading it from the content costs no external command.
# **The record's location is carried too**, because the reader (`rein request`) never receives a
# payload and so has no other way to find `<transcript location>/...`; the reader needs it to
# apply the same expiry cutoff the hooks apply.
# A write failure is loud: an unrecorded child is one a handover would replace the parent
# underneath.
hook_subagent_start() {
  local record
  hook_child_prepare
  hook_ensure_children_dir
  record="$(rein_child_record_path "$HOOK_TRANSCRIPT" "$HOOK_SESSION_ID" "$HOOK_AGENT_ID")" || record=""
  printf '%s\n%s\n%s\n' "$HOOK_AGENT_TYPE" "$HOOK_NOW" "$record" >"$CHILD_ENTRY_FILE" ||
    hook_die "cannot record the running child (a handover could then replace the parent while it is still running): ${CHILD_ENTRY_FILE}"
  exit 0
}

# A failure to remove is loud too -- an entry that stays behind refuses this session's handover
# for as long as the expiry cutoff, with no other channel reporting why.
hook_subagent_stop() {
  hook_child_prepare
  [ -e "$CHILD_ENTRY_FILE" ] || exit 0
  rm -f "$CHILD_ENTRY_FILE" ||
    hook_die "cannot remove the finished child's ledger entry (this session's handover stays refused until it expires): ${CHILD_ENTRY_FILE}"
  exit 0
}

# A per-generation persistent latch. Only the one call that manages to create it via noclobber
# blocks the stop (if it already exists, this passes through). If it can't be placed (a write
# failure), the stop is not blocked, and the failure is surfaced -- blocking the stop without
# leaving a latch behind would mean the same block repeats every single turn. Its
# contents are **this run's token** (used to match on revocation).
# Returns 0 = claimed (may block) / 1 = already present (pass through)
hook_claim_latch() {
  local latch="$1" token="$2"
  [ -e "$latch" ] && return 1
  hook_ensure_dir
  if ! (
    set -o noclobber
    printf '%s\n' "$token" >"$latch"
  ) 2>/dev/null; then
    [ -e "$latch" ] && return 1
    fail "cannot place the stop latch (the stop will not be blocked): ${latch}"
    exit 1
  fi
  return 0
}

# Prune latches from earlier generations. Only the current generation's name is ever checked,
# so anything past its generation is never referenced again and would just accumulate across
# sessions. A cleanup failure is ignored.
# **There are three kinds of generation latch** (the normal stop block, the one-time re-block
# for a rejected generation, and the handover-wait notice), so this same one function prunes
# them all -- pruning only one would split cleanup per kind, and each new kind added would leak
# until someone remembered to extend it.
hook_prune_old_latches() {
  local current="$1" file gen
  for file in "$HOOK_DIR"/stop-latch.g* "$HOOK_DIR"/stop-latch-rejected.g* \
    "$HOOK_DIR"/handover-wait.g*; do
    [ -f "$file" ] || continue
    gen="${file##*.g}"
    case "$gen" in
      '' | *[!0-9]*) continue ;;
    esac
    [ "$gen" -lt "$current" ] || continue
    rm -f "$file" 2>/dev/null
  done
  return 0
}

#
# The firing channel is PostToolBatch (fires once per **batch of tools that ran in parallel**,
# so it never scales with the number of tools, and concurrent firings can't structurally
# race). PostToolUse is the migration-era compatibility path -- it shares the claim on the
# right to notify (hook_claim_notice), so it never double-fires.
hook_advisory() {
  local event="$1" nonce rc
  hook_prepare
  hook_health_touch "$event"
  hook_verify_pending "$event"
  rein_nonce >/dev/null
  nonce="$REIN_NONCE"

  # (1) State is missing -- monitoring can't work. Silently letting it pass would be
  # indistinguishable from "all quiet."
  if ! hook_read_usage; then
    if [ ! -f "$HOOK_STATE_FILE" ]; then
      hook_take_notice state-missing-warned || exit 0
      hook_emit_missing "$event" "$nonce"
      hook_fire_log "$event" advisory "state-missing"
      hook_pending_write "$nonce"
      exit 0
    fi
    # (3) The value is corrupt. Unlike stdin itself failing to parse (a broken hook precondition),
    # this is an anomaly on the writer's side, so it's reported with a cooldown rather than
    # failing every single time.
    hook_take_notice pct-invalid-warned || exit 0
    hook_emit_invalid "$event" "$HOOK_STATE_FILE" "$nonce"
    hook_fire_log "$event" advisory "pct-invalid"
    hook_pending_write "$nonce"
    exit 0
  fi

  # (2) A suspected stopped writer. The value itself is still there, so after one warning, this
  # falls through to (4) during the cooldown and keeps doing the normal threshold check.
  if hook_usage_is_stale && hook_take_notice stale-warned; then
    hook_emit_stale "$event" "$HOOK_STATE_FILE" "$nonce"
    hook_fire_log "$event" advisory "stale"
    hook_pending_write "$nonce"
    exit 0
  fi

  # (4a) A submitted request with no watcher around, reported **regardless of usage**.
  # `rein request` runs at any usage, so a request placed below the trigger point can strand
  # exactly the same way -- and this used to sit inside the threshold branch below, which left
  # every channel silent for precisely that case while the advisory kept telling the session to
  # "finish the handoff document and wrap up," advice the session had already acted on. Only the
  # user starting the watcher resolves it, so a separate cooldown says exactly that, once.
  # **The check order is "already submitted?" -> "is the watcher alive?" -> "cooldown."** The
  # advisory channel emits something different depending on whether the watcher is around (if
  # it is, this falls through to the threshold check below; if not, no trigger is emitted at
  # all -- only "ask the user to start the watcher"). Checking the cooldown first and folding on
  # it would mean **the normal trigger gets silenced too, as collateral, on a turn where the
  # watcher is actually alive** -- the suppression window right after a watcher-missing notice
  # is exactly the middle of <the user starts it -> the handover proceeds>, i.e. exactly where
  # the mechanism is needed most. The cost this order accepts is one identity check (`ps`) on a
  # submitted turn -- limited to the window after a handover request has been made.
  # The Stop side does not use this same ordering (there, every branch is silent regardless of
  # whether the watcher is around, so folding on the cooldown there loses nothing).
  # A stranded request outranks both threshold messages, so this exits either way once it
  # applies: emitting the notice on top of the wrap-up advice would put two calls to action on
  # the same screen, and staying in the cooldown means the same misdirection would go out under
  # a different name.
  if hook_request_submitted; then
    rein_watcher_state "$RUNTIME_DIR" "$TARGET_CWD"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      if hook_take_notice watcher-missing; then
        hook_watcher_missing_text "$rc"
        hook_emit_watcher_missing "$event" "$nonce"
        hook_fire_log "$event" advisory "watcher-missing"
        hook_pending_write "$nonce"
      fi
      exit 0
    fi
  fi

  # (4) Threshold check. Display and comparison use the same rounded integer (letting the
  # rounding diverge would produce something like "passed 30% (currently 29%)").
  if [ "$HOOK_PCT" -ge "$HOOK_THRESHOLD_HANDOVER" ]; then
    if hook_take_notice handover; then
      # If the advisory threshold was skipped straight past on the way to the handover trigger,
      # also consume the lower threshold's cooldown at the same time, so the weak advisory
      # doesn't undo the strong trigger afterward.
      hook_claim_notice notice
      hook_emit_handover "$event" "$HOOK_PCT" "$nonce"
      hook_fire_log "$event" advisory "handover:${HOOK_PCT}"
      hook_pending_write "$nonce"
    fi
  elif [ "$HOOK_PCT" -ge "$HOOK_THRESHOLD_NOTICE" ]; then
    if hook_take_notice notice; then
      hook_emit_notice "$event" "$HOOK_PCT" "$nonce"
      hook_fire_log "$event" advisory "notice:${HOOK_PCT}"
      hook_pending_write "$nonce"
    fi
  fi
  exit 0
}

hook_stop() {
  local remaining until latch token block line rc submitted
  hook_prepare
  hook_health_touch Stop

  # Scope: only the primary session under rein's management. Pushing for a handover with no
  # lineage, or with the pointer naming a different session, would only produce a request that
  # gets rejected by the freshness check (matching the requester against the pointer) -- i.e. a
  # request that can never be accepted. A case that can't be determined is likewise let through
  # silently.
  rein_validate_pointer "$POINTER_FILE" "$TARGET_CWD" || exit 0
  [ "$REIN_POINTER_SESSION_ID" = "$HOOK_SESSION_ID" ] || exit 0

  # The final-output marker is set here, ahead of every gate below.
  # **This must never sit below the gate that decides whether to push for a handover.** That gate
  # decides whether to push; this marker records a separate fact -- "did this session finish
  # producing its final output." Placing it lower would silently disable the mechanism in any of
  # the following cases: (a) the user requested a handover themselves at usage below the trigger
  # point (`rein request` can be run regardless of usage), (b) usage has no record, or a stale
  # one, (c) within a snooze period, (d) the suppression window right after a watcher-missing
  # notice fired once. Case (d) in particular is **exactly the designed recovery path**
  # <watcher-missing notice -> the user starts it -> the request is resubmitted>, so it would
  # always be missed exactly where the mechanism is needed most.
  # **The watcher's liveness is likewise not a condition either** -- the marker represents only
  # the fact "this session finished producing output," independent of whether anyone is around
  # to read it (if not, it simply goes unread).
  # This adds no cost -- when no marker exists, checking "already submitted" returns as soon as
  # it sees the file is absent, without spawning `jq` even once. On a turn where a request does
  # exist, the `jq` call this needs is shared with the gate below (judged only once).
  # The marker's placement itself stays unconditional on the watcher; **only the one line that
  # tells the user the wait has begun is gated on it** (a countdown with nobody to run it would
  # be a lie -- the reasoning sits on hook_handover_wait_notice).
  # **The two are asked separately**, and the notice is not chained onto the marker's return
  # value. Chaining them tied the line to a condition it does not share: the marker is placed
  # with no watcher around, so it consumed the one chance to speak, and the watcher-recovery
  # path then handed over in silence. The notice carries its own per-generation latch instead.
  hook_request_submitted
  submitted=$?
  if [ "$submitted" -eq 0 ] && hook_final_output_enabled; then
    hook_place_mark "$HANDOVER_READY_FILE" || :
    hook_handover_wait_notice
  fi

  # The escape hatch (rein snooze). Pass through within the period, and leave one line about it
  # in the lineage log.
  if remaining="$(hook_snooze_remaining)"; then
    until="$(hook_snooze_until)"
    hook_log_once snooze "$until" "stop_snoozed" "snoozed until ${until} (${remaining} seconds remaining)"
    exit 0
  fi

  hook_read_usage || exit 0
  # Stale usage means pushing without knowing the current percentage (if statusline has
  # stopped, this would mean blocking stops indefinitely on a value from hours ago). This passes
  # through silently -- the latch is not consumed, so once the writer comes back, the next stop
  # re-evaluates from scratch. The same state is reported loudly by the advisory channel.
  hook_usage_is_stale && exit 0

  # If a handover request is already out, don't push again (one that's being judged -- i.e.
  # claimed -- also counts as submitted). But **this doesn't go silent if no watcher is
  # around** -- there's no one to clear the marker, so silently passing through would mean
  # nobody ever advances the handover while the context runs out. The identity check (`ps`) is
  # spawned only once the marker is known to be this session's own -- the no-op path's fixed
  # cost stays the same. This blocks once, not via the generation latch but via a different
  # cooldown (leaving the normal handover trigger, once the watcher comes back, still available
  # for that generation).
  # **This sits above the trigger-point comparison, not inside it.** `rein request` runs at any
  # usage, so a request placed below the trigger point strands the same way -- and with the
  # comparison first, that lineage went silent on every channel at once. What stays below the
  # comparison is the normal push (blocking a stop because usage got high), which is the only
  # judgment the trigger point is actually about. The gates this still sits under -- snooze, and
  # a usage record that is present and fresh -- are unchanged: a snooze is the user's own
  # explicit "leave me alone," and a missing or stale record is reported loudly by the advisory
  # channel under its own name.
  if [ "$submitted" -eq 0 ]; then
    # During the cooldown, this stays silent regardless of whether the watcher is around, so
    # **before spawning `ps`**, this folds as soon as it reads the fire marker's own contents
    # (never adding an external command to a submitted no-op path).
    hook_should_fire watcher-missing || exit 0
    # **The same judgment the handover-wait notice above asked**, not a second one. That is what
    # keeps this run's output to a single JSON object without a flag to carry the fact: a run
    # that emitted the notice was judged "resident," so it exits at the `rc == 0` line below,
    # before assembling anything (see hook_watcher_resident).
    hook_watcher_resident
    rc=$?
    # Submitted, and the watcher is around too -- pass through silently as before (the marker
    # was already placed above).
    [ "$rc" -eq 0 ] && exit 0
    # Assemble the output and the log line before consuming the marker (the cooldown). Doing it
    # in the reverse order would mean a failure after consuming it leaves nothing emitted until
    # the next interval.
    hook_watcher_missing_text "$rc"
    block="$(hook_emit_watcher_missing_block)"
    [ -n "$block" ] || hook_die "cannot assemble the stop-block response"
    line="$(hook_log_line "stop_blocked_watcher_missing" "usage ${HOOK_PCT}% / generation ${REIN_POINTER_GENERATION} / ${REIN_WATCHER_REASON}")"
    [ -n "$line" ] || hook_die "cannot assemble a hooks log line"
    hook_take_notice watcher-missing || exit 0
    if ! hook_log_append "$line"; then
      hook_expire_notice watcher-missing
      hook_die "cannot write the hooks log: ${HOOK_LOG_FILE}"
    fi
    # Once the marker is consumed, **write the output first** (ahead of the record layer, which
    # needs no rollback). Same reasoning as the normal stop block below -- limit the window where
    # a cut-off run could consume the marker alone to layers that can be rolled back.
    printf '%s\n' "$block"
    hook_fire_log Stop block "watcher-missing"
    exit 0
  fi

  # The trigger-point comparison. Everything below it is the normal push, which is the only
  # judgment usage decides; the stranded-request report above deliberately runs regardless.
  [ "$HOOK_PCT" -ge "$HOOK_THRESHOLD_HANDOVER" ] || exit 0

  # Don't hand over while children (subagents) are running (replacing the parent takes the
  # children down with it). The latch is not consumed -- **once the children are gone, this
  # pushes again on the next stop** (a child finishing does restart the parent and refire Stop,
  # observed). Deferring is logged once per generation (never silent).
  if hook_children_active; then
    hook_log_once children "g${REIN_POINTER_GENERATION}" "handover_deferred" \
      "deferred the handover for generation ${REIN_POINTER_GENERATION} because children are still running (will re-evaluate on the next stop)"
    exit 0
  fi

  # **Assemble the output and the log line first, then** consume the persistent marker (the
  # latch). In the reverse order, a failure after placing the latch (e.g. the log can't be
  # written) would leave that generation consumed with nothing emitted -- the stop could never
  # be blocked for that generation again. On failure, only this run's own latch is rolled back
  # before dying.
  # **Between consuming the marker and writing the output, only layers that can be rolled back
  # are allowed.** A hook can be cut off from outside by the registration timeout (10 seconds --
  # the same premise hook_fire_log_rotate also states), so inserting an unrollbackable layer here
  # would mean a cut-off run consumes only the latch with not one character of the block
  # reaching the model -- the lineage log would show stop_blocked while the model never saw it,
  # and that generation would pass through silently from then on (the record says "blocked" when
  # it wasn't). The only layer that needs rollback is the lineage log (roll the latch back if it
  # can't be written), so only that goes ahead of the output; layers that need no rollback -- old
  # generation cleanup, the fire log (whose rotation can spawn a lock acquisition and `ps`, the
  # longest layer in this window) -- are pushed after the output.
  latch="$HOOK_DIR/stop-latch.g${REIN_POINTER_GENERATION}"
  # If the generation latch is already consumed, the normal handover trigger no longer fires for
  # this generation. But **if that request was rejected, this re-blocks once** (the function
  # below judges it). The branch happens before paying assembly's cost, since every turn passes
  # through here once a generation's latch is consumed.
  if [ -e "$latch" ]; then
    hook_stop_after_rejection
    exit 0
  fi
  block="$(hook_emit_stop_block "$HOOK_PCT")"
  [ -n "$block" ] || hook_die "cannot assemble the stop-block response"
  line="$(hook_log_line "stop_blocked" "usage ${HOOK_PCT}% / generation ${REIN_POINTER_GENERATION}")"
  [ -n "$line" ] || hook_die "cannot assemble a hooks log line"
  token="$(hook_token)"
  hook_claim_latch "$latch" "$token" || exit 0
  if ! hook_log_append "$line"; then
    hook_revoke "$latch" 1 "$token"
    hook_die "cannot write the hooks log: ${HOOK_LOG_FILE}"
  fi
  printf '%s\n' "$block"
  hook_prune_old_latches "$REIN_POINTER_GENERATION"
  hook_fire_log Stop block "handover:${HOOK_PCT}"
  exit 0
}

# For a generation whose handover request was rejected, re-block the stop **exactly once**.
#
# Why this is needed: the normal generation latch is consumed the moment a push happens. If the
# watcher then rejects the request that followed, the marker is archived to `rejected/` and
# reverts to "not submitted" -- but the latch stays consumed, so the stop for that generation can
# never be blocked again, and the forced handover disappears entirely.
#
# Why only once: every rejection reason is a defect in the request itself, and resubmitting the
# same content just fails for the same reason. Restoring this without limit would mean a lineage
# that can't fix the defect gets blocked on every single turn. Blocking once, while **showing the
# reason verbatim**, opens a path to sending a fixed request (a re-block with no reason attached
# has no value -- there'd be no way to know what to fix, so carrying the reason is the whole
# point).
#
# The order of consuming the marker, writing output, and the record layer matches the normal
# stop block (spelled out in the comment above). Writing this second, structurally identical
# site in a different order would leave this one channel silently dropped by a cut-off run.
hook_stop_after_rejection() {
  local latch reason block line token
  latch="$HOOK_DIR/stop-latch-rejected.g${REIN_POINTER_GENERATION}"
  # Never read the rejection archive for a generation that's already been re-blocked (don't add
  # an external command to the no-op path).
  [ -e "$latch" ] && return 0
  reason="$(hook_rejection_reason)" || return 0
  [ -n "$reason" ] || return 0
  block="$(hook_emit_stop_block "$HOOK_PCT" "$reason")"
  [ -n "$block" ] || hook_die "cannot assemble the stop-block response"
  line="$(hook_log_line "stop_blocked_request_rejected" \
    "usage ${HOOK_PCT}% / generation ${REIN_POINTER_GENERATION} / ${reason}")"
  [ -n "$line" ] || hook_die "cannot assemble a hooks log line"
  token="$(hook_token)"
  hook_claim_latch "$latch" "$token" || return 0
  if ! hook_log_append "$line"; then
    hook_revoke "$latch" 1 "$token"
    hook_die "cannot write the hooks log: ${HOOK_LOG_FILE}"
  fi
  printf '%s\n' "$block"
  hook_prune_old_latches "$REIN_POINTER_GENERATION"
  hook_fire_log Stop block "request-rejected:${HOOK_PCT}"
  return 0
}

#
# If the user speaks up after a handover request has gone out, place a marker canceling that
# handover. The user speaking up means they're present, so there's no reason to force a
# handover. The watcher reads this marker during the wait before launching a successor, moves
# the handover request into `cancelled/`, and returns to watching.
#
# **The "already submitted" check comes first** -- a turn with no handover request out (the vast
# majority of turns where the user speaks up) returns cheaply right there. Validating the
# pointer's contract spawns `jq` five times, so reversing the order would make ordinary
# conversation that much heavier.
#
# **The generation latch is left untouched** -- Stop's handover trigger for the canceled
# generation stays consumed, and rein never pushes for a handover again for that generation on
# its own (having a handover happen while the user has stepped away would be a problem, and a
# cancellation is itself a statement of "let this session finish it" -- the user's own request
# outranks rein's). If the user wants a handover after all, the session can simply submit a new
# request.
hook_user_prompt_submit() {
  local line
  hook_prepare
  hook_health_touch UserPromptSubmit
  hook_request_submitted || exit 0
  # A lineage where the watcher has no waiting step to begin with (cap 0) gets neither the
  # marker nor a record -- never let the record alone claim "a cancellation was requested."
  hook_final_output_enabled || exit 0
  # Scope: only the primary session under rein's management (the same check as Stop). Canceling
  # while the pointer names a different session would mean the handover the watcher is waiting
  # on isn't even this session's own.
  rein_validate_pointer "$POINTER_FILE" "$TARGET_CWD" || exit 0
  [ "$REIN_POINTER_SESSION_ID" = "$HOOK_SESSION_ID" ] || exit 0
  # The log line is **assembled before the marker is placed** (placing only the marker while it
  # can't be assembled would let the cancellation succeed with not a single line left in the
  # lineage log). The marker is written first -- reversed, a run that fails to place the marker
  # would leave a record that alone claims "canceled" (a record must never claim something that
  # didn't happen). A run that places the marker but fails to write the log leaves the
  # cancellation unrecorded, but that path dies non-zero via hook_die reporting the reason to
  # stderr -- it's never silently lost.
  line="$(hook_log_line "handover_cancel_requested" \
    "canceling the handover for generation ${REIN_POINTER_GENERATION} (the user spoke up)")"
  [ -n "$line" ] || hook_die "cannot assemble a hooks log line"
  # **A turn where this session's own marker is already there returns with neither a record nor
  # a log entry** -- one request is enough, and while that same state persists, writing two logs
  # per prompt would just keep growing them (the existing discipline of folding an identical
  # repeat into one).
  hook_place_mark "$HANDOVER_CANCEL_FILE" || exit 0
  hook_log_append "$line" || hook_die "cannot write the hooks log: ${HOOK_LOG_FILE}"
  # What's emitted here is neither an injection to the model nor a blocked stop, but a marker
  # for the watcher, so the fire log's decision is recorded under a distinct value too (so
  # someone reading the breakdown never mistakes what kind of call this was).
  hook_fire_log UserPromptSubmit mark "handover-cancel"
  exit 0
}

hook_session_start() {
  local path_rein
  hook_prepare
  hook_health_touch SessionStart
  # The handover-request command runs `rein` from PATH (the hooks themselves run via the
  # launcher inside the plugin, so they don't depend on PATH). Where it can't be run, this makes
  # that clear right away.
  printf '[rein] To look up context usage for this session: cat %s\n' \
    "$(rein_shell_quote "$HOOK_STATE_FILE")"
  path_rein="$(command -v rein 2>/dev/null)"
  if [ -z "$path_rein" ]; then
    printf '[rein] rein is not on PATH (the handover-request command cannot be run; see rein doctor for install instructions)\n' # lineage-cmd-exempt: message shown exactly when rein is not on PATH -- this line itself can never be pasted and run (doctor prints a runnable form once it is installed)
  else
    printf '[rein] Command location: %s\n' "$path_rein"
  fi
  # A project setting not yet decided has not been applied. stderr isn't visible in the session,
  # so this surfaces it to the user once, at the start of the session (never as a recurring
  # injection). A setting the user has deliberately chosen not to apply carries no notice, so
  # this stays silent for that case too.
  if [ -n "$REIN_CONFIG_PROJECT_NOTICE" ]; then
    printf '[rein] %s\n' "$REIN_CONFIG_PROJECT_NOTICE"
  fi
  # The usage writer's (statusline's) location. Without it, the threshold check itself can't work.
  if [ ! -d "$HOOK_USAGE_DIR" ]; then
    printf '[rein] No session usage location exists (threshold monitoring cannot work): %s\n' "$HOOK_USAGE_DIR"
  fi
  # Only add this line when a lineage exists (silent for a project that doesn't use rein).
  if rein_validate_pointer "$POINTER_FILE" "$TARGET_CWD"; then
    printf '[rein] Lineage: generation %s (%s)\n' "$REIN_POINTER_GENERATION" "$TARGET_CWD"
  fi
  # Cleanup that only applies to a session rein itself launched: remove the temporary settings
  # created for the launch once this session is up (leaving it behind would have the next
  # doctor pick it up as stale).
  hook_drop_managed_settings
  exit 0
}

# Remove the temporary settings file (created by rein to disable worktree isolation). Only
# **something rein itself created** may be removed, so this is checked against both the
# location (under this lineage's runtime directory) and the prefix.
#
# **This never relies on a glob's prefix match** -- a trailing `*` also matches `/`, so
# `<location>/managed-settings.x/../../../../<any regular file>` would pass a prefix match and
# let a regular file outside the location be deleted (the path's source is the managed marker's
# env, so the pieces can be made to line up). This is checked as two conditions instead:
# "the parent directory exactly equals the location" AND "the name starts with the prefix" -- a
# path containing `..` no longer has a parent equal to the location, so these two conditions
# alone close the gap.
hook_drop_managed_settings() {
  local file="${REIN_MANAGED_SETTINGS_FILE:-}"
  [ -n "$file" ] || return 0
  [ "${file%/*}" = "$RUNTIME_DIR" ] || return 0
  case "${file##*/}" in
    "$REIN_MANAGED_SETTINGS_PREFIX"*) ;;
    *) return 0 ;;
  esac
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  rm -f "$file" 2>/dev/null
  return 0
}

# The mapping from the registry's (hooks/hooks.json's) verbs to hook event names. Kept in one
# place, and checked by selftest against the registry **in both directions** (a spelling drift
# would either make the hook fail every time with "unknown event", or make a registration vanish
# and silently stop firing).
hook_event_for_verb() {
  case "$1" in
    post-tool-batch) printf 'PostToolBatch\n' ;;
    post-tool-use) printf 'PostToolUse\n' ;;
    stop) printf 'Stop\n' ;;
    session-start) printf 'SessionStart\n' ;;
    user-prompt-submit) printf 'UserPromptSubmit\n' ;;
    subagent-start) printf 'SubagentStart\n' ;;
    subagent-stop) printf 'SubagentStop\n' ;;
    *) return 1 ;;
  esac
}

# The two events whose subject **is** the child. Every other event goes silent the moment the
# payload carries an agent_id (that means the call came from inside a child, where an injection
# would reach the child instead of the primary session) -- but these two always carry one, and
# for them it names which child to record, not who is calling. Wiring them up without this
# exemption would make them go silent the instant they were registered, and the ledger would stay
# empty forever while every check based on it read "no children."
hook_verb_subject_is_child() {
  case "$1" in
    subagent-start | subagent-stop) return 0 ;;
  esac
  return 1
}

# The verbs that belong in the registry (PostToolUse is the migration-era compatibility path, so
# it is **deliberately excluded** -- an existing registration for it keeps working until removed,
# but the new registry only lists PostToolBatch).
hook_registered_verbs() {
  printf '%s\n' post-tool-batch stop session-start user-prompt-submit subagent-start subagent-stop
}

hook_run() {
  local verb="${1:-}" protocol=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --protocol)
        [ $# -ge 2 ] || {
          fail "--protocol requires a value"
          return 1
        }
        protocol="$2"
        shift 2
        ;;
      -*)
        fail "unknown option: $1"
        usage >&2
        return 1
        ;;
      *)
        verb="$1"
        shift
        ;;
    esac
  done
  # The calling-convention version. If the launcher (cached inside the plugin, which can lag
  # behind) and the runner (the symlink target -- always current) disagree while still running,
  # the meaning of the arguments silently drifts.
  if [ -z "$protocol" ]; then
    fail "no calling-convention version (--protocol) was passed (update the registry and the launcher)"
    return 1
  fi
  if [ "$protocol" != "$REIN_HOOK_PROTOCOL" ]; then
    fail "calling-convention version mismatch (launcher ${protocol} / runner ${REIN_HOOK_PROTOCOL}). Update the plugin: claude plugin update $(rein_plugin_exact_id)"
    return 1
  fi
  if [ -z "$verb" ]; then
    fail "specify a hook event"
    usage >&2
    return 1
  fi
  HOOK_EVENT="$(hook_event_for_verb "$verb")" || {
    fail "unknown hook event: ${verb}"
    return 1
  }
  # **A window rein didn't launch gets nothing from the hooks at all.** The plugin is enabled at
  # user scope, so hooks run for every project and every session -- but everything this
  # mechanism does is addressed to a session rein itself launched: the marker is what carries
  # that session's lineage, and the handover wiring only ever moves for **the primary session
  # the pointer names**. Without this gate, a plain `claude` window still got the usage advisory
  # and the handover push, while `Stop` (limited to the primary session) stayed silent there --
  # so the only thing that arrived was **the text telling the user to finish the handoff
  # document and hand over, in a window where nothing can carry a handover out**.
  # **The marker being entirely absent is the one and only signal for this.** A marker that is
  # present but malformed is an anomaly, and fails loud in hook_prepare as before (never
  # silenced). Failing to deliver the marker is caught at launch time now -- the watcher
  # confirms it reached the successor before the pointer moves -- so "no marker at all" can only
  # mean a session rein never launched.
  # **Silence is exit 0 with nothing on stdout**, which is the same do-nothing for all 4
  # registered events. It deliberately isn't any other shape: a non-zero exit or anything on
  # stdout is a control signal (2 means something different per event, and for `Stop` it is the
  # stop block itself), so the mechanism not acting never becomes an unknown signal.
  # It sits ahead of `jq` and extraction because its evidence is the environment alone -- an
  # unmanaged window returns without spawning a single external process.
  [ -n "${REIN_MANAGED:-}" ] || exit 0
  # Order: **extraction -> validation -> the subagent check -> dispatch**. Placing the subagent
  # check before validation would let `agent_id: 0` coerce to the string `"0"` via `tostring`
  # and read as true, so **every event goes silent and exits 0 even for a managed session** (the
  # hole the type check closed would reopen just by moving the position).
  #
  # Ahead of all of that sits **whether `jq` exists**. Extraction needs `jq` to parse the
  # payload, so on a machine without it every event of a managed session would get stderr and
  # exit 1 -- for a session that is otherwise working fine. A single missing tool shouldn't turn
  # into noise on every tool batch, so this returns 0 without printing anything.
  # **This is not swallowing the error** -- `jq` is a prerequisite tool, and its absence is
  # named and failed by install (`rein init`), launch (`rein up`), and diagnostics (`rein
  # doctor`) via the shared library's `rein_check_prerequisites`. The hook is a layer with no
  # channel to report anything -- shouting here has nowhere to land, and would just become noise
  # on a machine unrelated to rein.
  # **This never auto-installs anything** (never silently install software on the user's
  # machine -- this stays limited to a message).
  command -v jq >/dev/null 2>&1 || exit 0
  hook_read_input
  hook_validate_input
  # In a subagent context, every hook stays silent -- markers are never touched either. **The two
  # child events are outside this gate** (hook_verb_subject_is_child): they always carry an
  # agent_id, and there it identifies the child being recorded rather than saying the call came
  # from inside one. The managed-marker gate above still applies to them unchanged.
  if ! hook_verb_subject_is_child "$verb" && hook_is_subagent; then
    exit 0
  fi
  case "$verb" in
    post-tool-batch | post-tool-use) hook_advisory "$HOOK_EVENT" ;;
    stop) hook_stop ;;
    session-start) hook_session_start ;;
    user-prompt-submit) hook_user_prompt_submit ;;
    subagent-start) hook_subagent_start ;;
    subagent-stop) hook_subagent_stop ;;
  esac
}

#
# This never touches real state, real config, or a real `~/.claude` (locations are isolated via
# environment variables). **The fire log's location is deliberately not isolated** -- this runs
# it under the same conditions as production (rein's own state side) specifically to confirm it
# never writes into the user's own log (i.e. that no warning banner appears on stderr).

st_pass_count=0
st_fail_count=0
ST_TMPDIR=""
ST_OUT=""
ST_ERR=""
ST_STATUS=0
ST_ENV=()
# The list of **locations the test must never touch** (ones that would only exist if isolation
# had failed). Populated by selftest after it creates a temp directory.
ST_NEVER_PATHS=()
ST_NEVER_TOUCH_REPORTED=0
# **The user's real state** (their own location). `ST_NEVER_PATHS` only checks whether a
# location that shouldn't exist now does, so it catches nothing about a write into a location
# that **already exists** -- writing to an absolute path named by the managed marker (the leak
# that actually happened) sails right past that blind spot, and 98 lines landed in the real
# production log while isolation was silently broken.
# This is checked not by existence but by **whether this test's own fingerprint count grew** --
# so it never gets tangled up with writes from a real session running concurrently. There are
# two fingerprints (the log's `"selftest":true` lines, and pending `sess-*` entries in runtime
# data -- both are strings only this test ever produces; a real session's session_id is a UUID
# and never starts with `sess-`).
#
# **This is not a duplicate of the structural gate** (hook_prepare's never-touch-root check).
# That one lives inside the code under test, so it does nothing about a write path that bypasses
# location resolution entirely (building a location ahead of hook_prepare), or about a write
# something other than the hook makes during this test.
# This one lives outside the code under test -- the parent process measures it once per launch,
# catching whatever that one misses.
# The tree it checks is **the same list of never-touch roots the structural gate hands its
# child** (building them separately would let one of the two miss a `--root` lineage -- which is
# exactly what had happened).
ST_REAL_ROOTS=()
# The order of roots as shown in the failure text (kept as a separate string, since an empty
# array can't be expanded with `[*]` under `set -u`).
ST_REAL_ROOTS_LABEL=""
ST_REAL_FINGERPRINTS=0

# The number of this test's fingerprints present in real state. 0 on a machine with no real
# state (e.g. CI).
st_real_fingerprints() {
  local n=0 count entry root fire_log
  for root in ${ST_REAL_ROOTS[@]+"${ST_REAL_ROOTS[@]}"}; do
    fire_log="$root/$REIN_FIRE_LOG_BASENAME"
    if [ -f "$fire_log" ]; then
      count="$(grep -c '"selftest":true' "$fire_log" 2>/dev/null)"
      case "$count" in
        '' | *[!0-9]*) count=0 ;;
      esac
      n=$((n + count))
    fi
    for entry in "$root"/*/"$REIN_HOOK_STATE_DIRNAME"/sess-*; do
      [ -e "$entry" ] || continue
      n=$((n + 1))
    done
  done
  printf '%s\n' "$n"
}

st_ok() {
  st_pass_count=$((st_pass_count + 1))
}

st_fail() {
  st_fail_count=$((st_fail_count + 1))
  printf '  FAIL %s: %s\n' "$1" "$2"
}

st_cleanup() {
  [ -n "$ST_TMPDIR" ] && rm -rf "$ST_TMPDIR"
}

# Launch the hook with a payload. Stdout and stderr are **never merged** -- the hook is judged
# separately on "did it emit an injection" (stdout) and "did it print a fail-loud reason"
# (stderr); merging them would let a silence check pass on a stray reason line.
st_run() {
  local payload="$1"
  shift
  printf '%s' "$payload" | env ${ST_ENV[@]+"${ST_ENV[@]}"} \
    "$ST_BASH" "$REIN_HOOK_PATH" "$@" >"$ST_TMPDIR/out" 2>"$ST_TMPDIR/err"
  ST_STATUS=$?
  ST_OUT="$(cat "$ST_TMPDIR/out")"
  ST_ERR="$(cat "$ST_TMPDIR/err")"
  st_check_never_touched "$@"
}

# Check that isolation hasn't broken, **once per launch**. A break only ever shows up as "a
# location that shouldn't exist now does," and checking that only at the end would leave no way
# to tell which of 200+ launches caused it (only the very last case would turn red, with every
# actual culprit still green). This fails immediately, with the offending launch's argv
# attached. Later launches stay silent -- once a never-touch location exists it stays there, so
# failing on every subsequent launch would turn everything after it red for the same reason and
# bury **the first** launch that actually broke it.
st_check_never_touched() {
  local path now
  [ "$ST_NEVER_TOUCH_REPORTED" -eq 0 ] || return 0
  for path in ${ST_NEVER_PATHS[@]+"${ST_NEVER_PATHS[@]}"}; do
    [ -e "$path" ] || continue
    ST_NEVER_TOUCH_REPORTED=1
    st_fail "never touches a location it should not use" "${path} was created (last launch: $*)"
    return 0
  done
  now="$(st_real_fingerprints)"
  # A growth and a shrink are **different kinds of breakage** (the former means isolation broke
  # and something was written; the latter means the user's own location was deleted). Folding
  # both into the same message would report a shrink as "grew" too, pointing the cause the wrong
  # way.
  if [ "$now" -gt "$ST_REAL_FINGERPRINTS" ]; then
    ST_NEVER_TOUCH_REPORTED=1
    st_fail "never writes to the user's real state" \
      "this test's fingerprint count grew (${ST_REAL_FINGERPRINTS} -> ${now}; roots checked: ${ST_REAL_ROOTS_LABEL}; last launch: $*)"
  elif [ "$now" -lt "$ST_REAL_FINGERPRINTS" ]; then
    ST_NEVER_TOUCH_REPORTED=1
    st_fail "never deletes from the user's real state" \
      "this test's fingerprint count shrank (${ST_REAL_FINGERPRINTS} -> ${now}; roots checked: ${ST_REAL_ROOTS_LABEL}; last launch: $*)"
  fi
  return 0
}

# The default call shape (matching the registry: with a version).
st_hook() {
  local verb="$1" payload="$2"
  st_run "$payload" --protocol "$REIN_HOOK_PROTOCOL" "$verb"
}

# A no-op pass (emits nothing, exits 0). stderr is checked too, so a run that prints a
# fail-loud reason while still exiting 0 is never read as "silent."
st_expect_silent() {
  if [ "$ST_STATUS" -eq 0 ] && [ -z "$ST_OUT" ] && [ -z "$ST_ERR" ]; then
    st_ok
  else
    st_fail "$1" "not silent: exit=${ST_STATUS} out=[${ST_OUT}] err=[${ST_ERR}]"
  fi
}

st_expect_status() {
  if [ "$ST_STATUS" -eq "$2" ]; then
    st_ok
    return 0
  fi
  st_fail "$1" "exit=${ST_STATUS} (expected $2): out=[${ST_OUT}] err=[${ST_ERR}]"
  return 1
}

# Stdout matching (`st_expect_contains` / `st_expect_not_contains`) is not defined here --
# both this file and the CLI-side selftest use the one shared version, defined in
# lib/rein-selftest-fixtures.sh (the rationale for keeping it there is written out verbatim at
# the top of that file). It's loaded inside selftest() below, so it's already defined by the
# time it's called.

# Stderr matching (some call sites pass the whole needle via a variable). This exists only in
# the hook -- there's no shared counterpart to fold it into -- but the check for a malformed
# needle still goes through the one shared function.
st_expect_err_contains() {
  local escape
  if [ -z "$2" ]; then
    st_fail "$1" "the expected string is empty (a broken test -- it would pass without checking output)"
    return
  fi
  if escape="$(rein_st_needle_escape_literal "$2")"; then
    st_fail "$1" "the expected string writes ${escape} as a literal backslash escape (a broken test -- it can never match the real output; write \$'${escape}' for the actual character): $2"
    return
  fi
  case "$ST_ERR" in
    *"$2"*) st_ok ;;
    *) st_fail "$1" "$2 did not appear on stderr: ${ST_ERR}" ;;
  esac
}

# Check that the decision branches appear **in this order**. `st_expect_contains` only checks
# "is it present," so a regression that moves a leading imperative back to the top (where the
# ordering itself is the fix) would silently pass the next time someone touched the wording. The
# second argument is the one body of text to check (the caller extracts just that field via jq,
# so "order" is never counted across other JSON fields). What follows are the branch markers,
# and **even one missing branch fails this** -- a branch that never appears is never misread as
# "in order."
st_expect_order() {
  local name="$1" text="$2" rest="$2" needle
  shift 2
  if [ -z "$text" ]; then
    st_fail "$name" "the body to check is empty (a broken test -- it would pass without checking order)"
    return
  fi
  for needle in "$@"; do
    if [ -z "$needle" ]; then
      st_fail "$name" "the expected string is empty (a broken test -- it would pass without checking output)"
      return
    fi
    case "$rest" in
      *"$needle"*)
        rest="${rest#*"$needle"}"
        ;;
      *)
        st_fail "$name" "${needle} does not appear after the previous branch (wrong order, or missing entirely): ${text}"
        return
        ;;
    esac
  done
  st_ok
}

st_expect_json() {
  if printf '%s' "$ST_OUT" | jq -e "$2" >/dev/null 2>&1; then
    st_ok
  else
    st_fail "$1" "not the expected JSON: ${ST_OUT}"
  fi
}

# **How many JSON values the run printed.** A hook's response is a single JSON object, and
# `st_expect_json` is structurally blind to that: `jq -e` decides its exit status from the
# **last** value of the stream, so a run that printed a second object satisfies every filter
# written against the first one. This is the only way that dimension gets measured.
# Output that doesn't parse counts as 0 (no run is allowed to print that shape either, and the
# filter-based assertions are what report it).
st_out_json_count() {
  printf '%s' "$ST_OUT" | jq -s 'length' 2>/dev/null || printf '0\n'
}

st_expect_true() {
  local name="$1"
  shift
  if "$@"; then
    st_ok
  else
    st_fail "$name" "condition failed: $*"
  fi
}

st_log_lines() {
  awk 'END { print NR + 0 }' "$1" 2>/dev/null || printf '0\n'
}

# Extract the verification token (`[rein:<nonce>]`) mixed into an injected message.
st_nonce_of() {
  local text="$1" rest
  rest="${text##*\[rein:}"
  printf '%s\n' "${rest%%\]*}"
}

selftest() {
  local tmp proj usage transcripts runtime state_root records hook_state health children
  local fire_log hook_log pointer marker processing rejected payload nonce before
  local json pairs event verb registered known plain_proj plain_runtime log_before
  local quoted_usage quoted unquoted
  local never_state never_home never_xdg_config never_root hook_now_before
  local never_roots_seen never_roots_want fp_root fp_before fp_after
  local sess_start_bin sess_start_path_bare
  local handover_ready handover_cancel mark_mtime wait_latch
  local runtime_token plain_token runtime2_token runtime3_token

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/rein-hook-selftest.XXXXXX")" || {
    printf '%s: selftest 0 pass / 1 fail\n' "$SCRIPT_NAME"
    return 1
  }
  ST_TMPDIR="$tmp"
  trap st_cleanup EXIT
  tmp="$(cd "$tmp" && pwd -P)"
  # shellcheck source-path=SCRIPTDIR
  # shellcheck source=lib/rein-selftest-fixtures.sh
  . "$SCRIPTS_DIR/lib/rein-selftest-fixtures.sh"
  ST_BASH="$REIN_ST_BASH"

  proj="$tmp/proj"
  usage="$tmp/usage"
  transcripts="$tmp/transcripts"
  state_root="$tmp/state/rein"
  mkdir -p "$proj/$REIN_RECORDS_DIRNAME" "$usage" "$transcripts" "$state_root"
  proj="$(cd "$proj" && pwd -P)"
  runtime="$state_root/$(rein_cwd_key "$proj")"
  mkdir -p "$runtime"
  printf '%s\n' "$proj" >"$runtime/$REIN_OWNER_BASENAME"
  # The lineage token goes through the shared provisioning function rather than being written
  # here by hand -- the fixture must hold **whatever that function actually places**, so that a
  # change to how a token is drawn or shaped can never leave this test passing against a value
  # only the test knows how to make.
  if ! rein_ensure_runtime_token "$runtime"; then
    printf '%s: cannot place a lineage token in the fixture: %s\n' "$SCRIPT_NAME" "$REIN_RUNTIME_ERROR" >&2
    printf '%s: selftest 0 pass / 1 fail\n' "$SCRIPT_NAME"
    return 1
  fi
  runtime_token="$REIN_RUNTIME_TOKEN"
  records="$proj/$REIN_RECORDS_DIRNAME"
  hook_state="$runtime/$REIN_HOOK_STATE_DIRNAME"
  health="$hook_state/$REIN_HOOK_HEALTH_DIRNAME"
  children="$runtime/$REIN_CHILDREN_DIRNAME"
  processing="$runtime/$REIN_PROCESSING_DIRNAME"
  rejected="$runtime/$REIN_REJECTED_DIRNAME"
  pointer="$records/$REIN_POINTER_BASENAME"
  marker="$runtime/$REIN_MARKER_BASENAME"
  handover_ready="$runtime/$REIN_HANDOVER_READY_BASENAME"
  # The handover-wait notice's own per-generation latch (every fixture below runs on generation
  # 1, the same generation stop-latch.g1 uses). Held in a variable so that no check spells the
  # name out a second time -- a rename that missed one site would leave that check quietly
  # clearing a file nobody writes, and it would go green without ever exercising the notice.
  wait_latch="$runtime/$REIN_HOOK_STATE_DIRNAME/handover-wait.g1"
  handover_cancel="$runtime/$REIN_HANDOVER_CANCEL_BASENAME"
  hook_log="$records/$REIN_HOOK_LOG_BASENAME"
  fire_log="$state_root/$REIN_FIRE_LOG_BASENAME"
  # The threshold, cooldown, freshness, and usage locations come from config (this catches any
  # default value hardcoded here instead). Freshness is given a value different from the
  # cooldown specifically so the checks can tell which key the wording and the judgment actually
  # came from (with the same value, a regression back to reusing one for the other would still
  # pass both checks).
  printf 'threshold_notice=10\nthreshold_handover=20\nnotice_cooldown_sec=120\nusage_stale_sec=180\nusage_state_dir=%s\n' \
    "$usage" >"$records/config"
  : >"$tmp/user-config"
  # The project config this test places (`<cwd>/.rein/config`) is subject to the allow gate. The
  # allow record calls the config layer's own channel as-is (never adding a second writer to
  # that log). The log sits next to the user config passed to the launch channel -- contained
  # inside this one temp directory.
  REIN_CONFIG_USER_FILE="$tmp/user-config"
  st_allow_records_config() {
    rein_config_allow_record "$records/config" ||
      st_fail "the test fixture can be allowed" "$REIN_PROJECT_ALLOW_ERROR"
  }
  st_allow_records_config
  # The managed marker env names are built from the shared library's own constants (the test
  # never keeps a copy of the names -- so renaming a constant can never leave the test alone
  # watching the old name).
  # Test isolation **never depends on the correctness of the code under test**. Even a test that
  # passes a managed marker falls back to the "derive from the payload's cwd" path the instant
  # its own resolution breaks, so XDG's state is always pointed at a temp directory regardless
  # (without that, a run measuring a broken implementation would write into the user's real
  # state). What it's pointed at is **a location none of this test's launches may ever create**
  # -- the name is kept in one place, and st_run checks whether it exists after every single
  # launch (so a launch that broke isolation can be named on the spot).
  never_state="$tmp/never-state"
  never_home="$tmp/never-home"
  never_xdg_config="$tmp/never-xdg-config"
  ST_NEVER_PATHS=("$never_state" "$never_home" "$never_xdg_config")
  # Clearing the surrounding environment goes through **one shared channel** (writing this out
  # per launch site would let whatever env got left off the list become an isolation hole -- and
  # in fact, six managed-marker vars, the full set of config keys, and XDG_CONFIG_HOME had all
  # leaked through exactly that way). Values specific to this test are appended afterward (`env`
  # lets the later setting win).
  # The return value is not checked (this function never returns failure -- an unmet
  # precondition is instead handled by an `exit 1` at source time).
  rein_st_isolation_env "$tmp/user-config" "$never_xdg_config" "$never_state" "$never_home"
  ST_ENV_BASE=("${REIN_ST_ENV_ARGS[@]}" "REIN_HOOK_SELFTEST=1")
  # The tree used to count fingerprints comes from **the same list of never-touch roots** the
  # channel above hands to the child (resolved in the parent's own environment -- since the
  # child maps both HOME and XDG to a temp directory, the default location as seen from the
  # child is never real state).
  # Checking only the roots resolved from XDG would miss the tree of a lineage rooted elsewhere
  # via `--root` (outside XDG) entirely -- meaning a write to a location named by the managed
  # marker would leave the fingerprint count at 0 and stay green.
  while IFS= read -r never_root; do
    [ -n "$never_root" ] || continue
    ST_REAL_ROOTS+=("$never_root")
    if [ -z "$ST_REAL_ROOTS_LABEL" ]; then
      ST_REAL_ROOTS_LABEL="$never_root"
    else
      ST_REAL_ROOTS_LABEL="${ST_REAL_ROOTS_LABEL} ${never_root}"
    fi
  done <<EOF
$REIN_ST_NEVER_ROOTS
EOF
  ST_REAL_FINGERPRINTS="$(st_real_fingerprints)"
  # The env for a fully managed-marker session is assembled in one place (so that when a new
  # field is added, it's never left stale in just some of the hand-written cases). Only the
  # cases specifically measuring a missing or mismatched field are written out individually.
  ST_ENV_MANAGED=("${ST_ENV_BASE[@]}"
    "${REIN_MANAGED_ENV_NAME}=1"
    "${REIN_MANAGED_CWD_ENV_NAME}=$proj"
    "${REIN_MANAGED_RUNTIME_ENV_NAME}=$runtime"
    "${REIN_MANAGED_CONFIG_ENV_NAME}=$tmp/user-config"
    "${REIN_MANAGED_RECORDS_ENV_NAME}=$records"
    "${REIN_MANAGED_TOKEN_ENV_NAME}=$runtime_token"
  )
  ST_ENV=("${ST_ENV_MANAGED[@]}")

  # Entry point: the calling convention.
  st_hook post-tool-batch '{}'
  st_expect_status "rejects broken stdin even with a matching version" 1
  st_run '{}' post-tool-batch
  if st_expect_status "rejects a call with no version" 1; then
    st_expect_err_contains "says the version is required" "calling-convention version"
  fi
  st_run '{}' --protocol 99 post-tool-batch
  if st_expect_status "rejects a call with a mismatched version" 1; then
    st_expect_err_contains "states the mismatch with both values" "launcher 99"
  fi
  st_run '{}' --protocol "$REIN_HOOK_PROTOCOL" bogus
  st_expect_status "rejects an unknown event" 1
  st_run '{}' --protocol "$REIN_HOOK_PROTOCOL"
  st_expect_status "rejects a call with no event" 1

  # Pin the mapping between the registry (hooks/hooks.json) and its verbs **in both
  # directions**. Checking only one direction would let either a verb dropped from the registry
  # (the hook silently stops firing) or a verb added with no registration pass silently.
  json="$REPO_ROOT/$REIN_HOOKS_JSON_RELPATH"
  if [ ! -f "$json" ]; then
    st_fail "the registry exists" "$json"
  else
    st_ok
    # Before reading the registry, pin **both sides** of the shared function that judges its
    # shape, using fixtures. A missing quote means a space in the plugin's location breaks the
    # command apart by word splitting and no hook ever fires again -- without first confirming
    # the rejecting side actually works, the check below could stay green while silently passing
    # through nothing.
    # shellcheck disable=SC2016  # exactly the literal text that appears in the registry (must not expand)
    quoted='"${CLAUDE_PLUGIN_ROOT}/'"${REIN_HOOK_LAUNCHER_RELPATH}"'" stop'
    # shellcheck disable=SC2016
    unquoted='${CLAUDE_PLUGIN_ROOT}/'"${REIN_HOOK_LAUNCHER_RELPATH} stop"
    if [ "$(rein_hook_command_launcher_relpath "$quoted")" = "$REIN_HOOK_LAUNCHER_RELPATH" ]; then
      st_ok
    else
      st_fail "extracts the launcher from a quoted registry command" "$quoted"
    fi
    if rein_hook_command_launcher_relpath "$unquoted" >/dev/null; then
      st_fail "never accepts an unquoted registry command as the expected shape" "$unquoted"
    else
      st_ok
    fi
    pairs="$(jq -r '.hooks | to_entries[] | .key as $event
      | .value[].hooks[] | "\($event)\t\(.command)"' "$json" 2>/dev/null)"
    while IFS="$(printf '\t')" read -r event verb; do
      [ -n "$event" ] || continue
      # The registry's command calls the tiny launcher inside the plugin (whose implementation
      # is the runner it symlinks to) **quoted**. Checked through the one shared function (the
      # same shape doctor checks).
      if [ "$(rein_hook_command_launcher_relpath "$verb")" != "$REIN_HOOK_LAUNCHER_RELPATH" ]; then
        st_fail "the registry's command quotes the launcher inside the plugin" "$verb"
        continue
      fi
      verb="${verb##* }"
      if [ "$(hook_event_for_verb "$verb")" = "$event" ]; then
        st_ok
      else
        st_fail "the registry's event matches its verb" "${event} / ${verb}"
      fi
    done <<EOF
$pairs
EOF
    registered="$(jq -r '[ .hooks[][].hooks[].command ] | .[]' "$json" 2>/dev/null |
      sed 's/^.* //' | LC_ALL=C sort)"
    known="$(hook_registered_verbs | LC_ALL=C sort)"
    if [ "$registered" = "$known" ]; then
      st_ok
    else
      st_fail "the registry's verb set matches the known set" "registered=[${registered}] / known=[${known}]"
    fi
    # PostToolBatch has no matcher (observed shape -- one firing per batch with no matcher at
    # all).
    if [ "$(jq -r '[ .hooks.PostToolBatch[] | select(has("matcher")) ] | length' "$json" 2>/dev/null)" = "0" ]; then
      st_ok
    else
      st_fail "PostToolBatch has no matcher" "$(jq -c '.hooks.PostToolBatch' "$json")"
    fi
    if [ "$(jq -r '[ .hooks[][].hooks[] | select((.type != "command") or (.timeout == null)) ] | length' \
      "$json" 2>/dev/null)" = "0" ]; then
      st_ok
    else
      st_fail "every registration has type=command and a timeout" "$(jq -c '.hooks' "$json")"
    fi
  fi

  # The managed marker env: resolving the lineage.
  # (a) Below threshold, silence. No location is created either (never leave state behind for a
  # project that isn't using rein).
  rein_st_write_usage "$usage" sess-a 5
  payload="$(rein_st_hook_payload sess-a "$proj" "$transcripts/sess-a.jsonl")"
  st_hook post-tool-batch "$payload"
  st_expect_silent "stays silent below threshold"
  st_expect_true "a no-op pass never creates the fire marker" test ! -e "$hook_state/sess-a.notice"
  # For a lineage where a location actually exists (i.e. rein is in use), even a no-op pass
  # still leaves behind the fact that it "ran" -- an anomaly in not emitting anything (the
  # registration isn't working) can't be judged from a log's line count.
  st_expect_true "a no-op pass still leaves the last firing" test -f "$health/last-seen.PostToolBatch"

  # The never-touch-root gate, where isolation would first fail.
  # Before using the predicate, pin **both sides** with fixtures. Every one of this test's 200+
  # launches sits outside every never-touch root, so checking only the "never touches" side would
  # read the same green whether the check "is always false" or was "removed entirely." The roots
  # passed are temp directories, so both sides can be measured without touching real state by a
  # single byte.
  ST_ENV=("${ST_ENV_MANAGED[@]}" "${REIN_SELFTEST_NEVER_ROOTS_ENV_NAME}=$tmp/unrelated-root")
  st_hook post-tool-batch "$payload"
  st_expect_silent "a launch that resolves a location outside every never-touch root passes through"
  # (1) The runtime-directory path. Forbidding the state area's root means the runtime directory
  # underneath it trips it. health's error is cleared first, specifically to confirm **the
  # rejecting side never writes it in the first place** -- the check runs right after the
  # location is resolved (before any write channel is built), so a rejected run leaves not a
  # single file under the never-touch root.
  rm -f "$health/error"
  ST_ENV=("${ST_ENV_MANAGED[@]}" "${REIN_SELFTEST_NEVER_ROOTS_ENV_NAME}=$tmp/state")
  st_hook post-tool-batch "$payload"
  if st_expect_status "rejects a launch that resolves the runtime directory under a never-touch root" 1; then
    st_expect_err_contains "the rejection reason names both the location and the root" "${runtime} (never-touch root ${tmp}/state)"
  fi
  st_expect_true "the rejecting side writes not a single file under the never-touch root" test ! -e "$health/error"
  # (2) The records path. The runtime directory sits outside the never-touch root, so checking
  # only records would let this pass through if it weren't also checked.
  ST_ENV=("${ST_ENV_MANAGED[@]}" "${REIN_SELFTEST_NEVER_ROOTS_ENV_NAME}=$proj")
  st_hook post-tool-batch "$payload"
  if st_expect_status "rejects a launch that resolves the records location under a never-touch root" 1; then
    st_expect_err_contains "the records path also names the location it hit" "${records} (never-touch root ${proj})"
  fi
  ST_ENV=("${ST_ENV_MANAGED[@]}")
  # Separate from whether the predicate itself works (the two checks above), pin **what actually
  # ends up in the root list**. Breaking just one lineage would leave both the "hits" and
  # "doesn't hit" sides green, with a write into the broken tree passing silently -- exactly what
  # had happened when only roots resolved from XDG were listed, missing a lineage rooted
  # elsewhere via `--root` (outside XDG) entirely.
  # The builder function is called **directly, with constructed values**, so the result never
  # depends on whether this session happens to be under rein's management.
  never_roots_seen="$(
    export REIN_MANAGED_RUNTIME_DIR="$tmp/fake-root/state/rein/k1"
    export REIN_MANAGED_RECORDS_DIR="$tmp/fake-root/records/rein/k1"
    export XDG_STATE_HOME="$tmp/fake-xdg"
    # HOME is also mapped to a constructed value -- the default path for usage records never
    # lets this test's real HOME move the result.
    export HOME="$tmp/fake-home"
    rein_st_never_roots
    # **Sort both sides before comparing.** What's being pinned is which roots end up listed,
    # not the order they were appended in -- comparing the newline-joined text as-is would fail
    # this check on any reordering that changes nothing about the actual behavior.
    printf '%s\n' "$REIN_ST_NEVER_ROOTS" | LC_ALL=C sort
  )"
  never_roots_want="$(printf '%s\n' \
    "$tmp/fake-root/state/rein/k1" \
    "$tmp/fake-root/state/rein" \
    "$tmp/fake-root/records/rein/k1" \
    "$tmp/fake-xdg/rein" \
    "$tmp/fake-home/.claude/state/context-usage" | LC_ALL=C sort)"
  if [ "$never_roots_seen" = "$never_roots_want" ]; then
    st_ok
  else
    st_fail "the never-touch roots cover the marker's lineage (runtime, its parent, records), XDG real state, and the usage-record default" \
      "built=[${never_roots_seen}] / expected=[${never_roots_want}]"
  fi

  # **Pin the counting layer itself.** Now that the structural gate is in place, a real leak
  # would never reach this layer again (the gate rejects it first) -- so if the counting itself
  # broke (a changed string being counted, a changed glob, an empty root list), it would just
  # stay silently green. So the tree is swapped for a temp directory here, and one of each of
  # the two fingerprint kinds is created to directly confirm **the count actually moves**.
  # The tree is only swapped inside `$( )` (an array assignment never leaks outside a
  # subshell) -- so after this check, the real tree and the baseline value it saved stay intact,
  # and every check-per-launch after this keeps working.
  fp_root="$tmp/fingerprint-probe"
  mkdir -p "$fp_root/k1/$REIN_HOOK_STATE_DIRNAME"
  fp_before="$(
    ST_REAL_ROOTS=("$fp_root")
    st_real_fingerprints
  )"
  # One log line (the fire log sits directly under the state area's root) and one pending entry
  # (`<key>/hooks/sess-*`).
  printf '{"schema":"probe","selftest":true}\n' >"$fp_root/$REIN_FIRE_LOG_BASENAME"
  : >"$fp_root/k1/$REIN_HOOK_STATE_DIRNAME/sess-x"
  fp_after="$(
    ST_REAL_ROOTS=("$fp_root")
    st_real_fingerprints
  )"
  if [ "$fp_before" = "0" ] && [ "$fp_after" = "2" ]; then
    st_ok
  else
    st_fail "the fingerprint count counts one log line and one pending entry" \
      "before=${fp_before} (expected 0) / after=${fp_after} (expected 2)"
  fi

  # **A window rein didn't launch gets nothing from the hooks at all.** The managed marker is
  # the only thing that says "rein launched this session," and it is the only lineage a hook can
  # act on -- the injection channel talks to that session, and the handover wiring only ever
  # moves for the primary session the pointer names. Before this gate, a plain `claude` window
  # still received the usage advisory and the handover push while `Stop` stayed silent there:
  # the only thing that arrived was **the text saying "finish the handoff document and hand
  # over," in a window where nothing could carry a handover out**.
  # Measured with **no usage record at all**, which is the strongest case -- silence below the
  # threshold would prove nothing (a managed session is silent there too), whereas a missing
  # record is exactly what would ring "Monitoring is not working" in every window on every
  # cooldown if the gate were gone.
  ST_ENV=("${ST_ENV_BASE[@]}" "REIN_USAGE_STATE_DIR=$usage")
  mkdir -p "$tmp/no-rein-proj"
  # **All 4 registered events**, so no single event can keep a channel of its own open into an
  # unmanaged window (each has separate wiring: the injection, the stop block, the opening line,
  # the cancellation marker). What is required of each is exactly "emits nothing and exits 0" --
  # any other exit code or anything on stdout would be a control signal (2 means something
  # different per event, and for `Stop` it is the stop block itself).
  for verb in post-tool-batch stop session-start user-prompt-submit; do
    st_hook "$verb" "$(rein_st_hook_payload sess-nomarker "$tmp/no-rein-proj" "$transcripts/sess-none.jsonl")"
    st_expect_silent "${verb} emits nothing and exits 0 with no managed marker"
  done
  # Nothing is created either -- neither where an unmanaged cwd would once have resolved to, nor
  # the records location inside that project.
  st_expect_true "creates no runtime data with no managed marker" test ! -e "$tmp/never-state"
  st_expect_true "creates no records location with no managed marker" \
    test ! -e "$tmp/no-rein-proj/$REIN_RECORDS_DIRNAME"
  # **Nothing a clone can ship substitutes for the marker.** `<cwd>/.rein/` and the config inside
  # it are things **a repo's author can bundle**, and that used to be enough to produce
  # injections, runtime directory creation, per-batch stderr, and reinjection on every cooldown
  # (observed). This is measured on **a machine where the user is actually using rein** (a state
  # area exists), specifically so the silence can only come from this window having no marker,
  # not from rein never having been used at all.
  mkdir -p "$tmp/clone-proj/$REIN_RECORDS_DIRNAME"
  printf 'threshold_notice=1\nthreshold_handover=2\nusage_state_dir=%s\n' \
    "$tmp/clone-usage" >"$tmp/clone-proj/$REIN_RECORDS_DIRNAME/config"
  ST_ENV=("${ST_ENV_BASE[@]}" "REIN_USAGE_STATE_DIR=$usage" "XDG_STATE_HOME=$tmp/state")
  st_hook post-tool-batch "$(rein_st_hook_payload sess-clone "$tmp/clone-proj" "$transcripts/sess-none.jsonl")"
  st_expect_silent "injects nothing for a bundled records location"
  st_expect_true "creates no runtime directory from a bundled config" \
    test ! -e "$tmp/state/rein/$(rein_cwd_key "$tmp/clone-proj")"
  st_hook session-start "$(rein_st_hook_payload sess-clone "$tmp/clone-proj" "$transcripts/sess-none.jsonl")"
  st_expect_silent "SessionStart also stays silent for a bundled records location"
  # The counterpart (measuring both sides): **the same payload, byte for byte**, handed to a
  # session that does carry the marker rings loudly -- so the gate cannot have collapsed into
  # "always silent." The only difference between the two runs is the marker env.
  ST_ENV=("${ST_ENV_MANAGED[@]}")
  st_hook post-tool-batch "$(rein_st_hook_payload sess-nomarker "$tmp/no-rein-proj" "$transcripts/sess-none.jsonl")"
  st_expect_contains "the same call rings once the managed marker is present" "Monitoring is not working"
  rm -f "$hook_state"/sess-nomarker.*

  # **On a machine with no `jq`**, this does nothing and returns 0 before ever reading input.
  # Extraction requires `jq` to parse the payload, so without it every event of **a managed
  # session** would print stderr and exit 1 -- turning one missing tool into noise on every tool
  # batch of a session that is otherwise working fine.
  # PATH is built by symlinking **everything** in `/usr/bin` and `/bin` into one location and
  # then removing only `jq` (hand-picking "the ones that seem needed" would make one missing
  # tool that got left off the list indistinguishable from "silent because jq is missing").
  mkdir -p "$tmp/nojq-bin"
  ln -sf /usr/bin/* /bin/* "$tmp/nojq-bin/"
  rm -f "$tmp/nojq-bin/jq"
  st_expect_true "jq is missing from the jq-stripped PATH (test scaffolding)" \
    test ! -e "$tmp/nojq-bin/jq"
  st_expect_true "other commands still exist on the jq-stripped PATH (test scaffolding)" \
    test -x "$tmp/nojq-bin/dirname"
  # Measured on **a managed session** (the same one that rings loudly with jq present, since it
  # has no usage record), so this specifically checks **that something that should fire, does
  # not**. Running it without a marker would measure nothing: the gate above would swallow the
  # call first, and the case would stay green no matter what the jq rule did.
  ST_ENV=("${ST_ENV_MANAGED[@]}" "PATH=$tmp/nojq-bin")
  for verb in post-tool-batch stop session-start user-prompt-submit; do
    st_hook "$verb" "$(rein_st_hook_payload sess-nostate "$proj" "$transcripts/sess-none.jsonl")"
    st_expect_silent "with no jq, ${verb} stays silent even for a managed session"
  done
  st_expect_true "with no jq, no fire marker is placed either" \
    test -z "$(find "$hook_state" -maxdepth 1 -name 'sess-nostate.*' -print -quit)"
  # The counterpart (measuring both sides): **the same session, same payload**, with PATH
  # restored, rings loudly as before -- confirming this hasn't collapsed to "always silent."
  ST_ENV=("${ST_ENV_MANAGED[@]}")
  st_hook post-tool-batch "$(rein_st_hook_payload sess-nostate "$proj" "$transcripts/sess-none.jsonl")"
  st_expect_contains "the same session rings as before once jq is present" "Monitoring is not working"
  rm -f "$hook_state"/sess-nostate.*
  ST_ENV=("${ST_ENV_MANAGED[@]}")

  # (b) **Even when cwd doesn't match the lineage**, this runs on the managed marker's lineage
  # (moving the working tree via EnterWorktree leaves recall and records on the original
  # lineage).
  mkdir -p "$tmp/worktree"
  rein_st_write_usage "$usage" sess-a 12
  st_hook post-tool-batch "$(rein_st_hook_payload sess-a "$tmp/worktree" "$transcripts/sess-a.jsonl")"
  st_expect_contains "judges by the lineage's config even when cwd has moved" "10%"
  st_expect_true "places the marker at the original lineage" test -f "$hook_state/sess-a.notice"
  rm -f "$hook_state/sess-a.notice" "$hook_state/sess-a.pending-verify"

  # (c) A marker that is present but has a missing or malformed field fails loud (there is no
  # other way to resolve a lineage left, so guessing one would mean writing into a different
  # lineage's markers).
  ST_ENV=("${ST_ENV_BASE[@]}"
    "${REIN_MANAGED_ENV_NAME}=1"
    "${REIN_MANAGED_CWD_ENV_NAME}=$proj"
    "${REIN_MANAGED_CONFIG_ENV_NAME}=$tmp/user-config"
    "${REIN_MANAGED_RECORDS_ENV_NAME}=$records"
  )
  st_hook post-tool-batch "$payload"
  if st_expect_status "rejects a missing managed marker value" 1; then
    st_expect_err_contains "names the missing field" "$REIN_MANAGED_RUNTIME_ENV_NAME"
  fi
  ST_ENV=("${ST_ENV_BASE[@]}"
    "${REIN_MANAGED_ENV_NAME}=yes"
    "${REIN_MANAGED_CWD_ENV_NAME}=$proj"
    "${REIN_MANAGED_RUNTIME_ENV_NAME}=$runtime"
    "${REIN_MANAGED_CONFIG_ENV_NAME}=$tmp/user-config"
    "${REIN_MANAGED_RECORDS_ENV_NAME}=$records"
  )
  st_hook post-tool-batch "$payload"
  st_expect_status "rejects a managed marker whose value isn't 1" 1
  # A malformed value (a relative path) is likewise rejected -- never silently falls back to
  # deriving from the payload's cwd (falling back would let a session that meant to name a
  # lineage explicitly end up running on a different one).
  ST_ENV=("${ST_ENV_BASE[@]}"
    "${REIN_MANAGED_ENV_NAME}=1"
    "${REIN_MANAGED_CWD_ENV_NAME}=relative/path"
    "${REIN_MANAGED_RUNTIME_ENV_NAME}=$runtime"
    "${REIN_MANAGED_CONFIG_ENV_NAME}=$tmp/user-config"
    "${REIN_MANAGED_RECORDS_ENV_NAME}=$records"
  )
  st_hook post-tool-batch "$payload"
  if st_expect_status "rejects a managed marker whose cwd isn't absolute" 1; then
    st_expect_err_contains "says an absolute path is required" "$REIN_MANAGED_CWD_ENV_NAME"
  fi
  # The same discipline covers the lineage's context (config, records location). Falling back to
  # a default when it's missing would let a hook for a lineage rooted elsewhere read the default
  # config and write records to `<cwd>/.rein/` (mixing two lineages together).
  ST_ENV=("${ST_ENV_BASE[@]}"
    "${REIN_MANAGED_ENV_NAME}=1"
    "${REIN_MANAGED_CWD_ENV_NAME}=$proj"
    "${REIN_MANAGED_RUNTIME_ENV_NAME}=$runtime"
    "${REIN_MANAGED_RECORDS_ENV_NAME}=$records"
  )
  st_hook post-tool-batch "$payload"
  if st_expect_status "rejects a missing managed marker config field" 1; then
    st_expect_err_contains "names the missing config field" "$REIN_MANAGED_CONFIG_ENV_NAME"
  fi
  ST_ENV=("${ST_ENV_BASE[@]}"
    "${REIN_MANAGED_ENV_NAME}=1"
    "${REIN_MANAGED_CWD_ENV_NAME}=$proj"
    "${REIN_MANAGED_RUNTIME_ENV_NAME}=$runtime"
    "${REIN_MANAGED_CONFIG_ENV_NAME}=relative/config"
    "${REIN_MANAGED_RECORDS_ENV_NAME}=$records"
  )
  st_hook post-tool-batch "$payload"
  st_expect_status "rejects a managed marker config field that isn't absolute" 1
  ST_ENV=("${ST_ENV_BASE[@]}"
    "${REIN_MANAGED_ENV_NAME}=1"
    "${REIN_MANAGED_CWD_ENV_NAME}=$proj"
    "${REIN_MANAGED_RUNTIME_ENV_NAME}=$runtime"
    "${REIN_MANAGED_CONFIG_ENV_NAME}=$tmp/user-config"
  )
  st_hook post-tool-batch "$payload"
  if st_expect_status "rejects a missing managed marker records field" 1; then
    st_expect_err_contains "names the missing records field" "$REIN_MANAGED_RECORDS_ENV_NAME"
  fi
  # A relative path is likewise rejected. **Deliberately chosen so the lineage-match check would
  # otherwise pass** (a relative path that still ends in the same key as the runtime directory)
  # -- so that dropping the absolute-path check couldn't be silently covered for by the
  # match check instead.
  ST_ENV=("${ST_ENV_BASE[@]}"
    "${REIN_MANAGED_ENV_NAME}=1"
    "${REIN_MANAGED_CWD_ENV_NAME}=$proj"
    "${REIN_MANAGED_RUNTIME_ENV_NAME}=$runtime"
    "${REIN_MANAGED_CONFIG_ENV_NAME}=$tmp/user-config"
    "${REIN_MANAGED_RECORDS_ENV_NAME}=records/${runtime##*/}"
  )
  st_hook post-tool-batch "$payload"
  if st_expect_status "rejects a relative records location" 1; then
    st_expect_err_contains "the records field also requires an absolute path" \
      "${REIN_MANAGED_RECORDS_ENV_NAME} is not an absolute path"
  fi
  # A records location that names a different lineage than the runtime directory is likewise
  # rejected (if only one of the two got swapped in the env, the hook would read one lineage's
  # markers while writing another lineage's records).
  ST_ENV=("${ST_ENV_BASE[@]}"
    "${REIN_MANAGED_ENV_NAME}=1"
    "${REIN_MANAGED_CWD_ENV_NAME}=$proj"
    "${REIN_MANAGED_RUNTIME_ENV_NAME}=$runtime"
    "${REIN_MANAGED_CONFIG_ENV_NAME}=$tmp/user-config"
    "${REIN_MANAGED_RECORDS_ENV_NAME}=$tmp/records/other-lineage-0123456789ab"
  )
  st_hook post-tool-batch "$payload"
  if st_expect_status "rejects a records location that mismatches the lineage" 1; then
    st_expect_err_contains "states the mismatch with both values" "$REIN_MANAGED_RECORDS_ENV_NAME"
  fi
  st_expect_true "writes nothing to the mismatched location" test ! -e "$tmp/records"
  # **The same key under a different root** is likewise rejected. Since the key is determined by
  # cwd alone, checking only whether the trailing key matches would let an env with a swapped
  # root sail through (using `--root` to run a second lineage, that pass-through would become a
  # write into the first lineage's records). The runtime directory passed is the correct
  # lineage's own, confirming what actually rejects this is **the records location's own
  # derivation**, not the owner check.
  ST_ENV=("${ST_ENV_BASE[@]}"
    "${REIN_MANAGED_ENV_NAME}=1"
    "${REIN_MANAGED_CWD_ENV_NAME}=$proj"
    "${REIN_MANAGED_RUNTIME_ENV_NAME}=$runtime"
    "${REIN_MANAGED_CONFIG_ENV_NAME}=$tmp/user-config"
    "${REIN_MANAGED_RECORDS_ENV_NAME}=$tmp/other-root/$REIN_ROOT_RECORDS_RELDIR/${runtime##*/}"
  )
  st_hook post-tool-batch "$payload"
  if st_expect_status "rejects the same key under a different root's records" 1; then
    st_expect_err_contains "the rejection reason names the location it almost passed through to" \
      "$tmp/other-root/$REIN_ROOT_RECORDS_RELDIR/${runtime##*/}"
  fi
  st_expect_true "writes nothing to the different root's location" test ! -e "$tmp/other-root"
  # A location whose recorded owner mismatches is also rejected (never read or write another
  # lineage's markers and latches).
  mkdir -p "$tmp/alien-runtime"
  printf '%s\n' "$tmp/somebody-else" >"$tmp/alien-runtime/$REIN_OWNER_BASENAME"
  ST_ENV=("${ST_ENV_BASE[@]}"
    "${REIN_MANAGED_ENV_NAME}=1"
    "${REIN_MANAGED_CWD_ENV_NAME}=$proj"
    "${REIN_MANAGED_RUNTIME_ENV_NAME}=$tmp/alien-runtime"
    "${REIN_MANAGED_CONFIG_ENV_NAME}=$tmp/user-config"
    "${REIN_MANAGED_RECORDS_ENV_NAME}=$records"
  )
  st_hook post-tool-batch "$payload"
  if st_expect_status "rejects a location with a mismatched owner" 1; then
    st_expect_err_contains "gives the owner mismatch as the reason" "belongs to a different target"
  fi
  st_expect_true "writes nothing to a location with a mismatched owner" \
    test ! -e "$tmp/alien-runtime/$REIN_HOOK_STATE_DIRNAME"
  # **A runtime directory that has never been claimed is rejected too** -- the shape a forged
  # marker would use. rein_verify_runtime_owner answers 0 for a directory with no owner file (its
  # contract, so the writers can run before the first claim), so without the hook's own "the owner
  # file has to exist" rule this marker resolves cleanly and the hook acts on the lineage it
  # names: the records field below is **the real project's own records location**, which is
  # exactly the `<cwd>/<records dirname>` shape rein_records_dir_matches_lineage accepts, so the
  # hook would go on to append to that project's hooks.log for a window rein never launched.
  # The marker arrives through the session's settings env, which a repository can supply and which
  # Claude Code applies in a folder that was never trusted itself, so this is reachable from a
  # clone rather than only from a hand-set environment.
  mkdir -p "$tmp/unowned-runtime"
  ST_ENV=("${ST_ENV_BASE[@]}"
    "${REIN_MANAGED_ENV_NAME}=1"
    "${REIN_MANAGED_CWD_ENV_NAME}=$proj"
    "${REIN_MANAGED_RUNTIME_ENV_NAME}=$tmp/unowned-runtime"
    "${REIN_MANAGED_CONFIG_ENV_NAME}=$tmp/user-config"
    "${REIN_MANAGED_RECORDS_ENV_NAME}=$records"
  )
  st_hook post-tool-batch "$payload"
  if st_expect_status "rejects a runtime directory with no owner file" 1; then
    st_expect_err_contains "gives the missing owner file as the reason" "no owner file"
  fi
  # Nothing reaches the session, and nothing is recorded anywhere the forged marker named. Each
  # of the three is measured separately: the marker's own lineage would have received the
  # advisory on stdout, its runtime directory would have gained the hooks location, and the state
  # area **worked back out from that runtime directory** would have gained a fire log -- three
  # different places, so no single one of them passing can stand in for the others.
  st_expect_true "injects nothing for a runtime directory with no owner file" \
    test -z "$ST_OUT"
  st_expect_true "writes nothing under a runtime directory with no owner file" \
    test ! -e "$tmp/unowned-runtime/$REIN_HOOK_STATE_DIRNAME"
  st_expect_true "leaves no fire log for a runtime directory with no owner file" \
    test ! -e "$tmp/$REIN_FIRE_LOG_BASENAME"
  # **The owner check and the token check have to stay separately measurable.** The unowned
  # directory above has no token either, so if the token comparison ran first, that case would
  # start failing on the token and the owner rule would go untested while still looking green.
  # This pins the reason it actually failed on: the owner file, naming no token env at all.
  case "$ST_ERR" in
    *"$REIN_MANAGED_TOKEN_ENV_NAME"*)
      st_fail "the missing-owner refusal is not absorbed into the token check" \
        "the reason named the token env instead of the owner file: ${ST_ERR}"
      ;;
    *) st_ok ;;
  esac
  # **A marker naming a real lineage, with the owner file matching, and no token.** This is the
  # forgery the owner rule alone cannot stop: `owner` holds nothing but the cwd, which the
  # marker states anyway, so a settings `env` that names an existing lineage passes every check
  # above. What it cannot state is the lineage's token -- that value is drawn from
  # /dev/urandom when the lineage is provisioned and kept 0600 inside the runtime directory,
  # which a project's own settings file can neither read nor write.
  # All three shapes a marker without the real value can take are refused: the field absent,
  # the field empty, and the field holding a well-formed value that is simply not this
  # lineage's. Empty is written out separately because "unset" and "set to nothing" reach the
  # code as the same expansion only if the check is written to treat them alike -- and a check
  # that let empty through would be satisfied by every marker that just omits the field.
  local forged_token forged
  forged_token="0000000000000000000000000000000000000000000000000000000000000000"
  rein_st_write_usage "$usage" sess-forged-token 12
  for forged in absent empty other; do
    ST_ENV=("${ST_ENV_BASE[@]}"
      "${REIN_MANAGED_ENV_NAME}=1"
      "${REIN_MANAGED_CWD_ENV_NAME}=$proj"
      "${REIN_MANAGED_RUNTIME_ENV_NAME}=$runtime"
      "${REIN_MANAGED_CONFIG_ENV_NAME}=$tmp/user-config"
      "${REIN_MANAGED_RECORDS_ENV_NAME}=$records"
    )
    case "$forged" in
      empty) ST_ENV+=("${REIN_MANAGED_TOKEN_ENV_NAME}=") ;;
      other) ST_ENV+=("${REIN_MANAGED_TOKEN_ENV_NAME}=$forged_token") ;;
    esac
    log_before="$(st_log_lines "$hook_log")"
    st_hook post-tool-batch "$(rein_st_hook_payload sess-forged-token "$proj" "$transcripts/sess-a.jsonl")"
    if st_expect_status "rejects a marker whose token is ${forged}" 1; then
      st_expect_err_contains "the reason for a ${forged} token names the token env" \
        "$REIN_MANAGED_TOKEN_ENV_NAME"
    fi
    # The value itself never reaches stderr. The reason lands in the session's own output and in
    # the health record, so printing it would publish the secret to the very side being refused.
    case "$ST_ERR" in
      *"$runtime_token"*)
        st_fail "the refusal for a ${forged} token never prints the token itself" "$ST_ERR"
        ;;
      *) st_ok ;;
    esac
    # Nothing reaches the session and nothing is recorded -- measured at the three separate
    # places the same way the owner case above is (stdout, the lineage's own runtime state, and
    # the lineage's records).
    st_expect_true "injects nothing for a ${forged} token" test -z "$ST_OUT"
    st_expect_true "places no advisory marker for a ${forged} token" \
      test ! -e "$hook_state/sess-forged-token.notice"
    st_expect_true "appends no record for a ${forged} token" \
      test "$(st_log_lines "$hook_log")" -eq "$log_before"
  done
  # The counterpart, on exactly the same session and usage record: with the real token in place
  # the very same call fires. Without this, "always reject" would pass every case above.
  ST_ENV=("${ST_ENV_MANAGED[@]}")
  st_hook post-tool-batch "$(rein_st_hook_payload sess-forged-token "$proj" "$transcripts/sess-a.jsonl")"
  st_expect_contains "the same call fires once the marker carries the real token" "10%"
  st_expect_true "the notice marker lands in the lineage the real token names" \
    test -f "$hook_state/sess-forged-token.notice"
  rm -f "$hook_state"/sess-forged-token.*
  # The counterpart (measuring both sides): a marker whose runtime directory **does** carry a
  # matching owner file still acts exactly as before -- so the rule above cannot have collapsed
  # into "always reject." The only difference between the two runs is whether the runtime
  # directory the marker names has been claimed.
  rein_st_write_usage "$usage" sess-owner-present 12
  ST_ENV=("${ST_ENV_MANAGED[@]}")
  st_hook post-tool-batch "$(rein_st_hook_payload sess-owner-present "$proj" "$transcripts/sess-a.jsonl")"
  st_expect_contains "a marker whose runtime directory is claimed still fires" "10%"
  st_expect_true "the claimed lineage is where the notice marker lands" \
    test -f "$hook_state/sess-owner-present.notice"
  rm -f "$hook_state"/sess-owner-present.*

  # **A runtime directory that sits under the lineage cwd is refused.** This is the forgery both
  # checks above accept: a clone that ships its own runtime directory **inside itself**, `owner`
  # and `token` included. Both are ordinary files a repository can carry, so the owner file holds
  # the cwd the marker states and the token matches the file beside it; the records field is that
  # cwd's own `.rein`, which is exactly the shape the lineage-match check accepts. Nothing else in
  # the validation objects, and the hook would act for a window rein never launched -- inside the
  # clone's own tree, on that clone's own config.
  # The fixture is a self-contained lineage of its own (its own cwd, records, and state area), so
  # the writes a broken implementation would make land where this section can measure them and
  # nowhere near the main fixture's.
  local in_tree_proj in_tree_records in_tree_runtime in_tree_token sibling_runtime sibling_token
  in_tree_proj="$tmp/in-tree/proj"
  mkdir -p "$in_tree_proj/$REIN_RECORDS_DIRNAME"
  in_tree_proj="$(cd "$in_tree_proj" && pwd -P)"
  in_tree_records="$in_tree_proj/$REIN_RECORDS_DIRNAME"
  in_tree_runtime="$in_tree_proj/.rein-fake"
  mkdir -p "$in_tree_runtime"
  printf '%s\n' "$in_tree_proj" >"$in_tree_runtime/$REIN_OWNER_BASENAME"
  # The token goes in through the shared provisioning function, the same as the main fixture --
  # so this case is refused for the placement, never for a token this test wrote by hand in a
  # shape the reader would reject anyway.
  rein_ensure_runtime_token "$in_tree_runtime" ||
    st_fail "the in-tree runtime fixture can hold a lineage token" "$REIN_RUNTIME_ERROR"
  in_tree_token="$REIN_RUNTIME_TOKEN"
  rein_st_write_usage "$usage" sess-in-tree 12
  ST_ENV=("${ST_ENV_BASE[@]}"
    "REIN_USAGE_STATE_DIR=$usage"
    "${REIN_MANAGED_ENV_NAME}=1"
    "${REIN_MANAGED_CWD_ENV_NAME}=$in_tree_proj"
    "${REIN_MANAGED_RUNTIME_ENV_NAME}=$in_tree_runtime"
    "${REIN_MANAGED_CONFIG_ENV_NAME}=$tmp/user-config"
    "${REIN_MANAGED_RECORDS_ENV_NAME}=$in_tree_records"
    "${REIN_MANAGED_TOKEN_ENV_NAME}=$in_tree_token"
  )
  st_hook post-tool-batch "$(rein_st_hook_payload sess-in-tree "$in_tree_proj" "$transcripts/sess-in-tree.jsonl")"
  if st_expect_status "rejects a runtime directory that sits under the lineage cwd" 1; then
    st_expect_err_contains "the reason names both the runtime directory and the cwd it sits under" \
      "${in_tree_runtime} (under ${in_tree_proj})"
  fi
  # Nothing reaches the session and nothing is recorded -- measured at the three separate places
  # this marker named (its own runtime directory, its own records, and the state area worked back
  # out from that runtime directory, which for this shape is the project itself).
  st_expect_true "injects nothing for a runtime directory under the cwd" test -z "$ST_OUT"
  st_expect_true "writes nothing under a runtime directory that sits under the cwd" \
    test ! -e "$in_tree_runtime/$REIN_HOOK_STATE_DIRNAME"
  st_expect_true "appends no record for a runtime directory that sits under the cwd" \
    test ! -e "$in_tree_records/$REIN_HOOK_LOG_BASENAME"
  st_expect_true "leaves no fire log for a runtime directory that sits under the cwd" \
    test ! -e "$in_tree_proj/$REIN_FIRE_LOG_BASENAME"
  # **The same forgery, spelled so that the two values do not textually nest.** Both values come
  # from one settings file, so their author picks the spelling: a comparison made on the marker's
  # own text is evaded by a trailing `/` or a `.` segment on the cwd, or by a symlink shipped in
  # the tree and named as the cwd -- in all three, `<clone>/.rein-fake` is not textually under the
  # cwd as stated, while being exactly the same directory inside exactly the same tree.
  # **Each of the three is a fully self-consistent marker**: the owner file is rewritten to hold
  # the cwd in that spelling, and the records field is that spelling's own `<cwd>/.rein` (the
  # shape the lineage-match check accepts), so nothing else in the validation objects to them.
  # That is what makes the case measure the placement rule -- which is also why the reason is
  # pinned, not just the exit code: were the rule to stop reaching these, a marker rejected a
  # step later for some other reason would still exit 1 and look identical here.
  local evade evade_cwd in_tree_link
  in_tree_link="self"
  ln -s . "$in_tree_proj/$in_tree_link"
  rein_st_write_usage "$usage" sess-in-tree 12
  for evade in trailing-slash dot-segment symlink; do
    case "$evade" in
      trailing-slash) evade_cwd="$in_tree_proj/" ;;
      dot-segment) evade_cwd="$in_tree_proj/." ;;
      symlink) evade_cwd="$in_tree_proj/$in_tree_link" ;;
    esac
    printf '%s\n' "$evade_cwd" >"$in_tree_runtime/$REIN_OWNER_BASENAME"
    ST_ENV=("${ST_ENV_BASE[@]}"
      "REIN_USAGE_STATE_DIR=$usage"
      "${REIN_MANAGED_ENV_NAME}=1"
      "${REIN_MANAGED_CWD_ENV_NAME}=$evade_cwd"
      "${REIN_MANAGED_RUNTIME_ENV_NAME}=$in_tree_runtime"
      "${REIN_MANAGED_CONFIG_ENV_NAME}=$tmp/user-config"
      "${REIN_MANAGED_RECORDS_ENV_NAME}=$evade_cwd/$REIN_RECORDS_DIRNAME"
      "${REIN_MANAGED_TOKEN_ENV_NAME}=$in_tree_token"
    )
    st_hook post-tool-batch "$(rein_st_hook_payload sess-in-tree "$in_tree_proj" "$transcripts/sess-in-tree.jsonl")"
    if st_expect_status "rejects the in-tree runtime directory with the cwd spelled as ${evade}" 1; then
      st_expect_err_contains "the ${evade} spelling is refused for the placement, not a step later" \
        "sits under the lineage cwd"
    fi
    st_expect_true "injects nothing for the ${evade} spelling" test -z "$ST_OUT"
    st_expect_true "writes nothing under the runtime directory for the ${evade} spelling" \
      test ! -e "$in_tree_runtime/$REIN_HOOK_STATE_DIRNAME"
    st_expect_true "appends no record for the ${evade} spelling" \
      test ! -e "$in_tree_records/$REIN_HOOK_LOG_BASENAME"
  done
  printf '%s\n' "$in_tree_proj" >"$in_tree_runtime/$REIN_OWNER_BASENAME"
  # The counterpart, placed **right on the boundary the rule has to respect**: a runtime
  # directory that merely shares a prefix with the cwd (`<cwd>-outside`) is a different
  # directory and still acts. Written without the separator, the same rule would reject this one
  # too -- and every other case in this file sits far enough away from its cwd that none of them
  # would notice.
  # It acts silently here (usage 12 against the default 30% threshold, since this lineage has no
  # config of its own), so what proves it got past validation is the record a no-op pass still
  # leaves: the last-firing file under the runtime directory the marker named.
  sibling_runtime="${in_tree_proj}-outside"
  mkdir -p "$sibling_runtime"
  printf '%s\n' "$in_tree_proj" >"$sibling_runtime/$REIN_OWNER_BASENAME"
  rein_ensure_runtime_token "$sibling_runtime" ||
    st_fail "the prefix-sharing runtime fixture can hold a lineage token" "$REIN_RUNTIME_ERROR"
  sibling_token="$REIN_RUNTIME_TOKEN"
  ST_ENV=("${ST_ENV_BASE[@]}"
    "REIN_USAGE_STATE_DIR=$usage"
    "${REIN_MANAGED_ENV_NAME}=1"
    "${REIN_MANAGED_CWD_ENV_NAME}=$in_tree_proj"
    "${REIN_MANAGED_RUNTIME_ENV_NAME}=$sibling_runtime"
    "${REIN_MANAGED_CONFIG_ENV_NAME}=$tmp/user-config"
    "${REIN_MANAGED_RECORDS_ENV_NAME}=$in_tree_records"
    "${REIN_MANAGED_TOKEN_ENV_NAME}=$sibling_token"
  )
  st_hook post-tool-batch "$(rein_st_hook_payload sess-in-tree "$in_tree_proj" "$transcripts/sess-in-tree.jsonl")"
  st_expect_silent "a runtime directory that only shares a prefix with the cwd still passes"
  st_expect_true "the prefix-sharing lineage is where the pass leaves its last firing" \
    test -f "$sibling_runtime/$REIN_HOOK_STATE_DIRNAME/$REIN_HOOK_HEALTH_DIRNAME/last-seen.PostToolBatch"
  ST_ENV=("${ST_ENV_MANAGED[@]}")

  # (d) The strongest form of the gate above: **everything that used to make it fire is in place
  # except the marker**. The payload's cwd is this test's own fully set-up lineage (owner file,
  # config, runtime directory), and the usage record is past the threshold -- the exact call
  # that fires when the marker is present. The single window still gets nothing.
  ST_ENV=("${ST_ENV_BASE[@]}" "XDG_STATE_HOME=$tmp/state")
  rein_st_write_usage "$usage" sess-unmanaged 12
  st_hook post-tool-batch "$(rein_st_hook_payload sess-unmanaged "$proj" "$transcripts/sess-unmanaged.jsonl")"
  st_expect_silent "a set-up lineage still gets nothing without the marker"
  st_expect_true "places no marker for a session without the managed marker" \
    test ! -e "$hook_state/sess-unmanaged.notice"
  # The counterpart: the same session and the same usage record, with the marker present, fires
  # at the threshold -- so the case above is measuring the marker, not a broken fixture.
  ST_ENV=("${ST_ENV_MANAGED[@]}")
  st_hook post-tool-batch "$(rein_st_hook_payload sess-unmanaged "$proj" "$transcripts/sess-unmanaged.jsonl")"
  st_expect_contains "the same session fires once the marker is present" "10%"
  st_expect_true "the marker's lineage is where the notice marker lands" \
    test -f "$hook_state/sess-unmanaged.notice"
  # The lineage cwd the marker names is never silently mapped to something else when it doesn't
  # exist (judging against another lineage's pointer and markers).
  ST_ENV=("${ST_ENV_BASE[@]}"
    "${REIN_MANAGED_ENV_NAME}=1"
    "${REIN_MANAGED_CWD_ENV_NAME}=$tmp/never-exists"
    "${REIN_MANAGED_RUNTIME_ENV_NAME}=$runtime"
    "${REIN_MANAGED_CONFIG_ENV_NAME}=$tmp/user-config"
    # The records location has to be that same cwd's own (`<cwd>/.rein`), or the lineage-match
    # check rejects it first and this case ends up measuring that check instead.
    "${REIN_MANAGED_RECORDS_ENV_NAME}=$tmp/never-exists/$REIN_RECORDS_DIRNAME"
  )
  st_hook post-tool-batch "$(rein_st_hook_payload sess-unmanaged "$proj" "$transcripts/x.jsonl")"
  if st_expect_status "rejects a lineage cwd that does not exist" 1; then
    st_expect_err_contains "names the missing lineage cwd" "$tmp/never-exists"
  fi

  # Everything from here runs with a managed marker (the path for a session rein launched).
  ST_ENV=("${ST_ENV_MANAGED[@]}")
  rm -f "$hook_state"/sess-*

  # PostToolBatch: the advisory.
  rein_st_write_usage "$usage" sess-a 12
  payload="$(rein_st_hook_payload sess-a "$proj" "$transcripts/sess-a.jsonl")"
  st_hook post-tool-batch "$payload"
  if st_expect_status "fires at the advisory threshold" 0; then
    st_expect_json "the injection is PostToolBatch's additionalContext" \
      '.hookSpecificOutput.hookEventName == "PostToolBatch" and (.hookSpecificOutput.additionalContext | length) > 0'
    st_expect_contains "fills in config's threshold" "10%"
    st_expect_contains "keeps the conditional clause per the ruling" "If you are close to done"
    st_expect_not_contains "never hardcodes the default value into the wording" "30%"
    st_expect_contains "mixes the delivery-confirmation verification token into the text" "[rein:"
    # The advisory fills in the canonical rules text **as-is**. Copying the wording here would
    # leave this check alone showing green with stale wording once the canonical text is edited
    # (matching the template is covered separately by selftest's init section).
    # Since this goes through the path that builds raw JSON via printf, a mistaken format
    # specifier or quote is caught by this check together with the st_expect_json check right
    # above it (that jq can parse it at all).
    st_expect_contains "the advisory carries the canonical handoff-writing rules" "$REIN_HANDOFF_WRITING_RULES"
  fi
  # There are two paths that **fill the canonical text into raw JSON via printf** (the advisory
  # and the handover trigger), so this mechanically confirms the canonical text itself is written
  # using only characters safe for that path. A `"`, a `\`, or a newline would corrupt the
  # injected JSON and **make it fail silently on the reader's side** -- if this check fails the
  # moment such wording is added, it stops a case that only looked at the jq-built path (the
  # stop-block text) from being misread as "it passed." `%` is fine -- the canonical text is
  # passed as `%s`'s **argument**, not as the format string, so it's never reinterpreted as a
  # format specifier.
  local rules_bad=""
  case "$REIN_HANDOFF_WRITING_RULES" in
    *'"'*) rules_bad="a double quote" ;;
    *\\*) rules_bad="a backslash" ;;
    *$'\n'*) rules_bad="a newline" ;;
  esac
  if [ -z "$rules_bad" ]; then
    st_ok
  else
    st_fail "the canonical rules text uses only characters safe to embed in raw JSON" "contains ${rules_bad}"
  fi
  nonce="$(st_nonce_of "$ST_OUT")"
  st_expect_true "an injection records a pending delivery confirmation" test -f "$hook_state/sess-a.pending-verify"
  st_expect_true "the pending record starts with the verification token" \
    test "$(head -1 "$hook_state/sess-a.pending-verify")" = "$nonce"

  # Silent within the cooldown, and fires again at the same threshold once the deadline passes.
  # Judged by the marker's **contents** (the expiry epoch) -- a regression back to checking mtime
  # would fail this check, since it never touches mtime.
  st_hook post-tool-batch "$payload"
  st_expect_silent "stays silent within the cooldown"
  printf '%s\n' "1" >"$hook_state/sess-a.notice"
  st_hook post-tool-batch "$payload"
  st_expect_contains "fires again once the deadline passes" "10%"
  st_expect_true "resets the deadline on every firing" \
    test "$(head -1 "$hook_state/sess-a.notice")" -gt "$(rein_now_epoch)"

  # Even if two channels run in the same turn (the PostToolUse compatibility path and
  # PostToolBatch), the right to notify is claimed once -- so the injection fires only once
  # (stops migration-era double injection).
  printf '%s\n' "1" >"$hook_state/sess-a.notice"
  st_hook post-tool-use "$payload"
  st_expect_contains "the compatibility channel injects too" "10%"
  st_hook post-tool-batch "$payload"
  st_expect_silent "a second channel in the same turn stays silent"

  # Even concurrent hooks of the same kind inject only once (the right to notify is claimed
  # atomically). A sequential check can't tell this apart from "delete, then place" -- so this
  # actually launches them concurrently to measure it.
  rm -f "$hook_state"/sess-race.*
  rein_st_write_usage "$usage" sess-race 12
  local race_out race_hits i
  race_out="$tmp/race"
  mkdir -p "$race_out"
  for i in 1 2 3 4 5 6 7 8; do
    (
      printf '%s' "$(rein_st_hook_payload sess-race "$proj" "$transcripts/sess-race.jsonl")" |
        env ${ST_ENV[@]+"${ST_ENV[@]}"} "$ST_BASH" "$REIN_HOOK_PATH" \
          --protocol "$REIN_HOOK_PROTOCOL" post-tool-batch >"$race_out/$i.out" 2>"$race_out/$i.err"
    ) &
  done
  wait
  race_hits="$(grep -l 'additionalContext' "$race_out"/*.out 2>/dev/null | awk 'END { print NR + 0 }')"
  if [ "$race_hits" = "1" ]; then
    st_ok
  else
    st_fail "injects only once even under concurrency" "times injected=${race_hits}"
  fi
  if [ -z "$(cat "$race_out"/*.err)" ]; then
    st_ok
  else
    st_fail "prints nothing to stderr even under concurrency" "$(cat "$race_out"/*.err)"
  fi
  st_expect_true "leaves no claim marker behind" test ! -e "$hook_state/sess-race.notice.claim"

  # Stays silent while another run's claim is active (a concurrency test can only hit this
  # sometimes, timing-dependent -- so this creates the "a claim marker exists" state directly to
  # measure it **deterministically**).
  rm -f "$hook_state"/sess-claim.*
  rein_st_write_usage "$usage" sess-claim 12
  mkdir -p "$hook_state/sess-claim.notice.claim"
  st_hook post-tool-batch "$(rein_st_hook_payload sess-claim "$proj" "$transcripts/sess-claim.jsonl")"
  st_expect_silent "stays silent while another run's claim is active"
  st_expect_true "places no marker either while a claim is active" test ! -e "$hook_state/sess-claim.notice"
  # A claim left behind by a run that died mid-claim is cleared and reclaimed once its grace
  # period passes (the right to notify never stays blocked forever).
  touch -t 202001010000 "$hook_state/sess-claim.notice.claim"
  st_hook post-tool-batch "$(rein_st_hook_payload sess-claim "$proj" "$transcripts/sess-claim.jsonl")"
  st_expect_contains "clears an abandoned claim and fires" "10%"
  st_expect_true "leaves no trace of the abandoned claim" test ! -e "$hook_state/sess-claim.notice.claim"

  # The handover trigger point. The advisory wording is never emitted (a weak advisory never
  # undoes a strong trigger).
  rm -f "$hook_state"/sess-a.*
  rein_st_write_usage "$usage" sess-a 25
  st_hook post-tool-batch "$payload"
  if st_expect_status "fires at the handover trigger point" 0; then
    st_expect_contains "fills in the trigger point's value" "20%"
    st_expect_contains "says this is a call to decide" "a call to make a decision"
    st_expect_not_contains "never emits the advisory threshold's wording" "10%"
    # A run that jumps straight here without crossing the advisory threshold never enters the
    # advisory channel at all (the check is if/elif and mutually exclusive; the lower cooldown is
    # also consumed here). That very run is exactly **the session editing an already-existing
    # document**, so the canonical writing-rules text is carried on this channel too.
    st_expect_contains "the handover trigger also carries the canonical handoff-writing rules" "$REIN_HANDOFF_WRITING_RULES"
    # The branches must appear **in priority order** (that they're present is already checked by
    # the contains checks above -- this checks order alone). The failure this fixes was "the
    # reader acts on a leading imperative without ever judging the remaining branches," so
    # nothing confirms the fix unless "running the handover request command" is checked to come
    # last.
    st_expect_order "the handover trigger's branches are ordered by priority" \
      "$(printf '%s' "$ST_OUT" | jq -r '.hookSpecificOutput.additionalContext')" \
      "explicit instructions" "close to done" "no clean breakpoint yet" \
      "Otherwise, finish the handoff document"
  fi
  st_expect_true "also consumes the lower threshold's cooldown" \
    test "$(head -1 "$hook_state/sess-a.notice")" -gt "$(rein_now_epoch)"

  # Already submitted, but no watcher around. Pushing for a handover wouldn't resolve anything
  # (the request is already placed), so the advisory channel likewise says, once via a separate
  # cooldown, only "ask the user to start the watcher."
  local payload_wm
  rm -f "$hook_state"/sess-wm.*
  rein_st_write_usage "$usage" sess-wm 25
  rein_st_write_marker "$marker" "sess-wm" "$(rein_iso_now)" "$tmp/handoff.md" "$proj"
  payload_wm="$(rein_st_hook_payload sess-wm "$proj" "$transcripts/sess-wm.jsonl")"
  st_hook post-tool-batch "$payload_wm"
  if st_expect_status "the advisory channel also reports a missing watcher" 0; then
    st_expect_contains "carries the operation to start the watcher (advisory)" "$(rein_shell_quote "$REIN_BIN") --cwd '${proj}' up"
    st_expect_not_contains "never turns into the handover trigger" "a call to make a decision"
  fi
  st_hook post-tool-batch "$payload_wm"
  st_expect_silent "the advisory's watcher-missing report also honors its cooldown"

  # **Usage is not a condition for this report.** `rein request` runs at any usage, so a request
  # placed below the trigger point strands exactly the same way -- and this used to sit inside
  # the trigger-point branch, so such a lineage got the ordinary advisory instead: "decide when
  # to wrap up ... finish writing the handoff document," aimed at a session that had already
  # done both and was waiting on a watcher nobody had restarted. Measured **between the two
  # thresholds**, which is where that advisory fires -- so this can't pass on silence, only on
  # the right message replacing the wrong one.
  rm -f "$hook_state"/sess-wm.*
  rein_st_write_usage "$usage" sess-wm 12
  st_hook post-tool-batch "$payload_wm"
  if st_expect_status "reports a missing watcher below the trigger point too" 0; then
    st_expect_contains "the below-threshold report carries the operation to start the watcher" \
      "$(rein_shell_quote "$REIN_BIN") --cwd '${proj}' up"
    st_expect_not_contains "never sends the wrap-up advisory to a session already waiting" \
      "decide when to wrap up"
  fi
  # The cooldown consumed is the watcher-missing one, not the advisory threshold's -- consuming
  # the wrong one would silence the ordinary advisory for the next 30 minutes as collateral.
  st_expect_true "the below-threshold report consumes the watcher-missing cooldown" \
    test -f "$hook_state/sess-wm.watcher-missing"
  st_expect_true "the below-threshold report leaves the advisory cooldown alone" \
    test ! -e "$hook_state/sess-wm.notice"
  # Usage goes back to the at-threshold fixture, and the watcher-missing cooldown is left
  # **consumed** -- that is exactly the state the cost checks below measure from.
  rein_st_write_usage "$usage" sess-wm 25

  # The advisory channel **checks identity (`ps`) before the cooldown, even during the
  # cooldown**. It emits something different depending on whether the watcher is around (if it
  # is, this falls through to the normal handover trigger), so folding on the cooldown first
  # would erase the trigger too, on a turn where the watcher is actually alive -- a regression
  # back to "cooldown first" fails on this line together with its counterpart below ("fires
  # even during the suppression window, if the watcher is around"). The state measured matches
  # the Stop side: a watcher lock that exists but whose owner is gone (identity has to be checked),
  # with only the cooldown varied.
  rein_st_write_counting_ps "$tmp/ps-bin"
  ST_ENV=("${ST_ENV_MANAGED[@]}" "PATH=$tmp/ps-bin:$PATH" "FAKE_PS_LOG=$tmp/ps.log")
  mkdir -p "$runtime/$REIN_LOCK_DIRNAME"
  printf '99998\n' >"$runtime/$REIN_LOCK_DIRNAME/pid"
  : >"$tmp/ps.log"
  st_hook post-tool-batch "$payload_wm"
  st_expect_silent "the advisory also stays silent during the cooldown (through the ps shim)"
  st_expect_true "the advisory checks the watcher's liveness first, even during the cooldown" \
    test "$(st_log_lines "$tmp/ps.log")" -eq 1
  # The counterpart to that cost: **a turn with no submitted request never spawns `ps` at all**.
  # The cost this order accepts is that identity checking is paid for only during the short
  # submitted window, so without checking this, a regression to "`ps` runs on every tool call for
  # an unsubmitted session" would stay green (the advisory channel runs on every tool call). Only
  # the presence of the handover-request marker is varied -- the lock and threshold are left
  # alone, so nothing else could account for the count being 0.
  rm -f "$marker"
  rm -f "$hook_state"/sess-wm.*
  : >"$tmp/ps.log"
  st_hook post-tool-batch "$payload_wm"
  st_expect_true "an unsubmitted turn never spawns ps at all" \
    test "$(st_log_lines "$tmp/ps.log")" -eq 0
  rein_st_write_marker "$marker" "sess-wm" "$(rein_iso_now)" "$tmp/handoff.md" "$proj"
  # A case that can't be determined (a lock whose owner can't be read) never gets the same
  # message as "not running."
  rm -f "$hook_state"/sess-wm.*
  rm -f "$runtime/$REIN_LOCK_DIRNAME/pid"
  : >"$tmp/ps.log"
  st_hook post-tool-batch "$payload_wm"
  if st_expect_status "the advisory also reports an undetermined case" 0; then
    st_expect_contains "the advisory also says it cannot be determined" "cannot be determined"
    st_expect_contains "the advisory also carries the watcher lock's location" "$runtime/$REIN_LOCK_DIRNAME"
    st_expect_not_contains "the advisory never turns into the missing-watcher message" "$(rein_shell_quote "$REIN_BIN") --cwd '${proj}' up"
  fi
  ST_ENV=("${ST_ENV_MANAGED[@]}")
  rm -rf "${runtime:?}/$REIN_LOCK_DIRNAME"
  rm -f "$hook_state"/sess-wm.*

  # If the watcher is around, the handover trigger's wording fires as before (the advisory
  # channel is never silenced even when already submitted).
  rein_st_start_fake_watcher "$runtime" "$proj"
  rm -f "$hook_state"/sess-wm.*
  st_hook post-tool-batch "$payload_wm"
  st_expect_contains "emits the normal trigger when the watcher is around" "a call to make a decision"
  # **The same holds even during a live watcher-missing cooldown** (if the watcher is around,
  # this falls through to the normal trigger). Checking the cooldown before liveness would erase
  # the trigger entirely here -- the suppression window sits right after a watcher-missing notice
  # fires, exactly the middle of <the user starts it -> the handover proceeds>, exactly where the
  # mechanism is needed most. The earlier case measured this with the suppression window already
  # expired; this is its counterpart. Only the watcher-missing suppression window is varied --
  # the handover trigger's own cooldown is cleared before measuring (without clearing it, this
  # would pass as a false green thanks to the `handover` cooldown the firing right above it just
  # placed).
  rm -f "$hook_state"/sess-wm.*
  printf '%s\n' "$(($(rein_now_epoch) + 3600))" >"$hook_state/sess-wm.watcher-missing"
  st_hook post-tool-batch "$payload_wm"
  st_expect_contains "fires the trigger even during a live watcher-missing suppression window, if the watcher is around" "a call to make a decision"
  rein_st_stop_fake_watcher "$runtime"
  rm -f "$marker" "$hook_state"/sess-wm.*

  # State missing means monitoring can't work. Silently letting it pass would be
  # indistinguishable from "all quiet."
  st_hook post-tool-batch "$(rein_st_hook_payload sess-missing "$proj" "$transcripts/sess-missing.jsonl")"
  st_expect_contains "reports missing state" "statusline"
  st_hook post-tool-batch "$(rein_st_hook_payload sess-missing "$proj" "$transcripts/sess-missing.jsonl")"
  st_expect_silent "the missing-state warning also honors its cooldown"

  # A corrupt value (unreadable even after falling back to jq). Unlike stdin itself failing to
  # parse, this is an anomaly on the writer's side, so it's reported with a cooldown rather than
  # failing every single time.
  rein_st_write_usage "$usage" sess-bad '"NaN"'
  st_hook post-tool-batch "$(rein_st_hook_payload sess-bad "$proj" "$transcripts/sess-bad.jsonl")"
  if st_expect_status "does not fail even on a corrupt value" 0; then
    st_expect_contains "reports the corrupt value" "used_percentage"
  fi

  # A half-written state file (an unterminated value). The writer is outside rein, so a
  # non-atomic write (truncate with `>`, then append) is possible. A fast path that doesn't
  # require a terminator (`,` or `}`) would take "everything that's left" as the value, turning
  # 25% into 2% -- reading it as below threshold and never pushing a handover. Unterminated input
  # is never settled on the fast path; it falls back to jq for an authoritative re-read (which
  # also can't read it here, so this reports the "value unreadable" -- i.e. corrupt -- case).
  printf '{"at":"%s","session_id":"sess-torn","context_window":{"used_percentage":2' \
    "$(rein_iso_now)" >"$usage/sess-torn.json"
  st_hook post-tool-batch "$(rein_st_hook_payload sess-torn "$proj" "$transcripts/sess-torn.jsonl")"
  if st_expect_status "does not fail even on a half-written state file" 0; then
    st_expect_contains "never uses the half-written value as the threshold" "used_percentage"
  fi
  rm -f "$hook_state"/sess-torn.*
  # The counterpart on the "let it through" side: once terminated with `}` (even with no
  # trailing comma), the fast path reads it.
  printf '{"at":"%s","session_id":"sess-tail","context_window":{"used_percentage":25}}\n' \
    "$(rein_iso_now)" >"$usage/sess-tail.json"
  st_hook post-tool-batch "$(rein_st_hook_payload sess-tail "$proj" "$transcripts/sess-tail.jsonl")"
  st_expect_contains "reads the value once terminated" "currently 25%"
  rm -f "$hook_state"/sess-tail.*

  # A location whose path contains a JSON metacharacter (`"`). `usage_state_dir` is a literal
  # value from the config layer, and it's legal in a macOS filename. Embedding the injection's
  # body directly in a printf format string would corrupt the output as JSON --
  # **exactly the injection meant to report an anomaly would be the one that silently fails, and
  # precisely when the config itself is broken.** This checks both the unreadable-value side and
  # the freshness side (a regression that fixes assembly on only one of them fails this).
  quoted_usage="$tmp/usage\"q"
  mkdir -p "$quoted_usage"
  rein_st_write_usage "$quoted_usage" sess-quoted '"NaN"'
  ST_ENV=("${ST_ENV_MANAGED[@]}" "REIN_USAGE_STATE_DIR=$quoted_usage")
  st_hook post-tool-batch "$(rein_st_hook_payload sess-quoted "$proj" "$transcripts/sess-quoted.jsonl")"
  st_expect_json "the injection stays valid JSON even for a location with a JSON metacharacter in its path" \
    '.hookSpecificOutput.additionalContext | contains("used_percentage") and contains("sess-quoted.json")'
  rein_st_write_usage "$quoted_usage" sess-quoted2 12 \
    "$(TZ=UTC date -u -r "$(($(rein_now_epoch) - 3600))" +%Y-%m-%dT%H:%M:%SZ)"
  st_hook post-tool-batch "$(rein_st_hook_payload sess-quoted2 "$proj" "$transcripts/sess-quoted2.jsonl")"
  st_expect_json "the freshness warning is also valid JSON for the same location" \
    '.hookSpecificOutput.additionalContext | contains("sess-quoted2.json")'
  ST_ENV=("${ST_ENV_MANAGED[@]}")

  # Freshness is judged from the writer's own `at` timestamp (never spawns `stat`). This checks
  # both sides of the threshold.
  rein_st_write_usage "$usage" sess-stale 12 "$(TZ=UTC date -u -r "$(($(rein_now_epoch) - 3600))" +%Y-%m-%dT%H:%M:%SZ)"
  st_hook post-tool-batch "$(rein_st_hook_payload sess-stale "$proj" "$transcripts/sess-stale.jsonl")"
  if st_expect_status "emits the freshness warning" 0; then
    # The minute count comes from the freshness key (usage_stale_sec=180). If it were reusing
    # the cooldown (120) instead, this would read "over 2 minutes" -- a regression back to that
    # reuse fails on this one line.
    st_expect_contains "the freshness warning includes the minute count" "over 3 minutes"
    st_expect_not_contains "freshness is never derived from the cooldown" "over 2 minutes"
  fi
  st_hook post-tool-batch "$(rein_st_hook_payload sess-stale "$proj" "$transcripts/sess-stale.jsonl")"
  st_expect_contains "falls through to the normal threshold check after the freshness warning" "10%"
  # Staleness **between** the cooldown (120 seconds) and freshness (180 seconds) -- tells apart
  # which key is actually being checked.
  rein_st_write_usage "$usage" sess-midage 12 "$(TZ=UTC date -u -r "$(($(rein_now_epoch) - 150))" +%Y-%m-%dT%H:%M:%SZ)"
  st_hook post-tool-batch "$(rein_st_hook_payload sess-midage "$proj" "$transcripts/sess-midage.jsonl")"
  st_expect_contains "falls through to the normal threshold check within the freshness window" "10%"
  st_expect_not_contains "emits no warning within the freshness window" "has not been updated in over"
  # A writer that puts a space after `: ` is read from the same evidence (`at`, `used_percentage`)
  # just the same. This combines an old `at` with a new mtime, so this check fails if `at` isn't
  # actually being read.
  rein_st_write_usage_spaced "$usage" sess-spaced 12 \
    "$(TZ=UTC date -u -r "$(($(rein_now_epoch) - 3600))" +%Y-%m-%dT%H:%M:%SZ)"
  st_hook post-tool-batch "$(rein_st_hook_payload sess-spaced "$proj" "$transcripts/sess-spaced.jsonl")"
  st_expect_contains "reads freshness from at even for a spaced writer" "over 3 minutes"
  rein_st_write_usage_spaced "$usage" sess-spaced2 12
  st_hook post-tool-batch "$(rein_st_hook_payload sess-spaced2 "$proj" "$transcripts/sess-spaced2.jsonl")"
  st_expect_contains "reads the usage percentage even for a spaced writer" "10%"

  # A writer that stamps no timestamp falls back to mtime (both sides: new and old).
  rein_st_write_usage_without_at "$usage" sess-noat 12
  st_hook post-tool-batch "$(rein_st_hook_payload sess-noat "$proj" "$transcripts/sess-noat.jsonl")"
  st_expect_contains "the threshold check still runs with no at" "10%"
  st_expect_not_contains "never rings freshness with a fresh mtime" "has not been updated in over"
  rein_st_write_usage_without_at "$usage" sess-noat-old 12
  touch -t 202001010000 "$usage/sess-noat-old.json"
  st_hook post-tool-batch "$(rein_st_hook_payload sess-noat-old "$proj" "$transcripts/sess-noat-old.jsonl")"
  st_expect_contains "falls back to mtime for freshness with no at" "over 3 minutes"

  # In a subagent context (**agent_id present**), stays silent, markers untouched. A case with
  # only `agent_type` present is the **primary session** launched with `claude --agent <name>`
  # (observed) -- staying silent there would drop the whole primary session out of
  # monitoring, so this does not stay silent.
  rein_st_write_usage "$usage" sess-sub 12
  st_hook post-tool-batch "$(rein_st_hook_payload sess-sub "$proj" "$transcripts/sess-sub.jsonl" '{"agent_id":"a-1","agent_type":"Explore"}')"
  st_expect_silent "stays silent in a subagent context (agent_id)"
  st_expect_true "creates no marker in a subagent context either" test ! -e "$hook_state/sess-sub.notice"
  st_hook post-tool-batch "$(rein_st_hook_payload sess-sub "$proj" "$transcripts/sess-sub.jsonl" '{"agent_type":"Explore"}')"
  st_expect_contains "fires for agent_type alone (a primary session launched via --agent)" "10%"

  # Delivery confirmation: silently clears the pending record once the verification token appears in
  # the transcript.
  rein_st_write_usage "$usage" sess-ok 12
  st_hook post-tool-batch "$(rein_st_hook_payload sess-ok "$proj" "$transcripts/sess-ok.jsonl")"
  nonce="$(st_nonce_of "$ST_OUT")"
  rein_st_write_transcript_nonce "$transcripts/sess-ok.jsonl" "$nonce"
  printf '%s\n%s\n%s\n' "$nonce" "$transcripts/sess-ok.jsonl" "1" >"$hook_state/sess-ok.pending-verify"
  st_hook post-tool-batch "$(rein_st_hook_payload sess-ok "$proj" "$transcripts/sess-ok.jsonl")"
  st_expect_silent "silently clears the pending record once delivered"
  st_expect_true "clears the pending record once judged" test ! -f "$hook_state/sess-ok.pending-verify"
  # Reports it when not delivered (a mechanical check for "fired, but never reached anyone").
  rein_st_write_usage "$usage" sess-lost 12
  st_hook post-tool-batch "$(rein_st_hook_payload sess-lost "$proj" "$transcripts/sess-lost.jsonl")"
  rein_st_write_transcript_nonce "$transcripts/sess-lost.jsonl" "rein-other"
  printf '%s\n%s\n%s\n' "rein-lost" "$transcripts/sess-lost.jsonl" "1" >"$hook_state/sess-lost.pending-verify"
  st_hook post-tool-batch "$(rein_st_hook_payload sess-lost "$proj" "$transcripts/sess-lost.jsonl")"
  st_expect_contains "reports a non-delivery" "rein-lost"
  st_expect_true "records the non-delivery in health state" test -f "$health/undelivered"
  # Never checks within the grace period (never says "not delivered" before it's even had a
  # chance to be written to the transcript).
  rein_st_write_usage "$usage" sess-young 5
  printf '%s\n%s\n%s\n' "rein-young" "$transcripts/none.jsonl" "$(($(rein_now_epoch) + 600))" \
    >"$hook_state/sess-young.pending-verify"
  st_hook post-tool-batch "$(rein_st_hook_payload sess-young "$proj" "$transcripts/sess-young.jsonl")"
  st_expect_silent "never judges delivery within the grace period"
  st_expect_true "never clears the pending record within the grace period" test -f "$hook_state/sess-young.pending-verify"
  rm -f "$hook_state/sess-young.pending-verify"

  # Broken stdin fails loud (internal errors are exit code 1 for every event -- a non-blocking
  # failure).
  st_hook post-tool-batch 'not json'
  if st_expect_status "rejects broken stdin" 1; then
    st_expect_true "injects nothing on a rejected turn" test -z "$ST_OUT"
    st_expect_true "the reason goes to stderr" test -n "$ST_ERR"
  fi
  st_hook stop 'not json'
  st_expect_status "Stop's internal error is also 1 (never blocks the stop)" 1
  st_hook post-tool-batch '{"cwd":"/x"}'
  st_expect_status "rejects when session_id is missing" 1
  st_hook post-tool-batch "$(rein_st_hook_payload 'a/../b' "$proj" "$transcripts/x.jsonl")"
  st_expect_status "never lets a path separator through in session_id" 1

  # A newline in a value shifts every field's position by one, **pushing the following value
  # into the wrong slot**. A newline in session_id pushes its tail into agent_id, making the
  # subagent check true, so monitoring goes silent entirely even past a crossed threshold
  # (indistinguishable, byte for byte, from a real subagent's silence -- output alone can't tell
  # them apart). Rejection is decided **ahead of any user-derived data**, so the check itself
  # never shifts even when the values do.
  rein_st_write_usage "$usage" sess-lf 12
  st_hook post-tool-batch \
    "$(rein_st_hook_payload "$(printf 'sess-lf\nINJECTED')" "$proj" "$transcripts/sess-lf.jsonl")"
  if st_expect_status "rejects a session_id containing a newline" 1; then
    st_expect_true "injects nothing on a turn shifted by a newline" test -z "$ST_OUT"
    st_expect_err_contains "the newline-rejection reason names the field" "session_id"
  fi
  # The counterpart (measuring both sides): a real subagent (agent_id given explicitly) still
  # stays silent as before -- confirming the newline rejection never gets tangled up with
  # subagent silence.
  rein_st_write_usage "$usage" sess-lf-ctl 12
  st_hook post-tool-batch \
    "$(rein_st_hook_payload sess-lf-ctl "$proj" "$transcripts/sess-lf-ctl.jsonl" '{"agent_id":"a-lf"}')"
  st_expect_silent "a real subagent still stays silent as before"

  # A **non-string value** is rejected by type. Coercing it and letting it through would (a) let
  # a multi-line value shift line positions, landing whether background_tasks is present (`0`)
  # into HOOK_NOW and **making the current time epoch 0** (smearing last-seen, shared across
  # sessions, to 0 -- the hooks liveness that doctor reads reverts to 1970), and (b) let a
  # value that fits on one line (`agent_id: 0`) become the non-empty string `"0"` without
  # shifting any line, so **the hook goes silent and exits 0 on every event**. Both are closed
  # by this one type check at the entry point.
  rein_st_write_usage "$usage" sess-obj 12
  st_hook post-tool-batch "$(jq -nc --arg sid sess-obj --arg t "$transcripts/sess-obj.jsonl" \
    '{session_id: $sid, cwd: {a: 1}, transcript_path: $t}')"
  if st_expect_status "rejects a non-string cwd" 1; then
    st_expect_err_contains "the type-rejection reason names the field" "cwd"
  fi
  # The silent side (agent_id). **A no-op pass and this output are indistinguishable, byte for
  # byte**, so this checks not just the exit code but that a reason actually appears on stderr
  # (the inverse of `st_expect_silent`).
  rein_st_write_usage "$usage" sess-num 12
  st_hook post-tool-batch "$(jq -nc --arg sid sess-num --arg t "$transcripts/sess-num.jsonl" \
    --arg cwd "$proj" '{session_id: $sid, cwd: $cwd, agent_id: 0, transcript_path: $t}')"
  if st_expect_status "rejects a non-string agent_id (never ends silently)" 1; then
    st_expect_err_contains "the type-rejection reason names agent_id" "agent_id"
  fi
  # `false` is not the same as absent. Leaving the "blank out missing" logic as jq's `//` would
  # let `//` return its right-hand side for both null and false, turning `cwd: false` into the
  # string `""`, sailing past the type check, and **silently collapsing an explicit value into
  # the same meaning as "the key is missing"** (cwd is used to resolve the location and config).
  rein_st_write_usage "$usage" sess-false 12
  st_hook post-tool-batch "$(jq -nc --arg sid sess-false --arg t "$transcripts/sess-false.jsonl" \
    '{session_id: $sid, cwd: false, transcript_path: $t}')"
  if st_expect_status "rejects a false cwd" 1; then
    st_expect_err_contains "rejects false with the type reason" "cwd is not a string"
  fi

  # **Where validation sits**: the type check runs **after** the managed-marker gate -- a window
  # rein didn't launch emits nothing and exits 0 even for a broken payload. The plugin is enabled
  # at user scope and hooks run in every project, so if validation sat ahead of the gate, a
  # broken payload in any unrelated window would print stderr and exit 1 (no runtime data would
  # grow there, so the symptom is only noise and a non-zero exit -- but a mechanism that is
  # supposed to be doing nothing at all should not be heard from).
  # The three cases above (cwd, agent_id, false) all ran with the marker present, so they are on
  # the fail-loud side. This measures the opposite side with **the exact same payload, byte for
  # byte** -- the only difference between the two runs is the marker env.
  st_nomarker_payload="$(jq -nc --arg cwd "$tmp/no-rein-proj" --arg t "$transcripts/sess-none.jsonl" \
    '{session_id: "sess-broken-nomarker", cwd: $cwd, agent_id: 0, transcript_path: $t}')"
  ST_ENV=("${ST_ENV_BASE[@]}" "REIN_USAGE_STATE_DIR=$usage")
  st_hook post-tool-batch "$st_nomarker_payload"
  st_expect_silent "even a broken payload stays silent with no managed marker"
  st_expect_true "creates no location either for a broken payload with no managed marker" \
    test ! -e "$tmp/never-state"
  st_hook stop "$st_nomarker_payload"
  st_expect_silent "Stop also stays silent for a broken payload with no managed marker"
  # The counterpart (measuring both sides): the same payload handed to a managed session fails
  # loud as before -- confirming this hasn't collapsed into "always silent," using the exact
  # payload whose position in the check order was just moved.
  ST_ENV=("${ST_ENV_MANAGED[@]}")
  st_hook post-tool-batch "$st_nomarker_payload"
  if st_expect_status "rejects the same payload once the marker is present" 1; then
    st_expect_err_contains "a managed session names agent_id in the rejection" "agent_id"
  fi
  # **A value containing a newline fails loud rather than being let through blanked** (handled
  # differently from a type rejection). Blanking preserves line position so the remaining fields
  # still land where they belong, but the cut-off fragment before the newline could itself name a
  # real directory, and it would be recorded as this call's cwd -- a corrupted, user-supplied
  # value is never allowed to stand in for the real one. This is measured on a managed session:
  # without the marker the call returns before extraction ever runs, so there is nowhere else
  # this rule can be observed. The env is set here rather than inherited from the block above, so
  # that reordering the cases can never quietly turn this into a measurement of the unmanaged path
  # (where it would pass by staying silent, without the newline rule running at all).
  ST_ENV=("${ST_ENV_MANAGED[@]}")
  st_hook post-tool-batch "$(jq -nc --arg cwd "$(printf '%s\nSUFFIX' "$proj")" \
    --arg t "$transcripts/sess-none.jsonl" \
    '{session_id: "sess-lfcwd-out", cwd: $cwd, transcript_path: $t}')"
  if st_expect_status "rejects a cwd containing a newline" 1; then
    st_expect_err_contains "the newline-rejection reason names cwd" "cwd cannot contain a newline"
  fi
  ST_ENV=("${ST_ENV_MANAGED[@]}")

  # The counterpart (measuring both sides): a string value still passes through as before, and
  # records the current time **for this call**.
  # The expected value is checked as a range against a baseline taken just before this. A single
  # point comparison against `!= "0"` would pass even when this call's hook never reached
  # hook_health_touch, since `$health` is shared across the whole selftest run and a prior case's
  # valid epoch would still be sitting there (that failure to reach it does happen -- hook_die
  # never updates last-seen). Clearing the field first and checking with `-ge` fails on an empty
  # string, `0`, or a carried-over value alike.
  rein_st_write_usage "$usage" sess-str 12
  hook_now_before="$(rein_now_epoch)"
  : >"$health/last-seen.PostToolBatch"
  st_hook post-tool-batch "$(rein_st_hook_payload sess-str "$proj" "$transcripts/sess-str.jsonl")"
  st_expect_true "a string value never turns the current time into epoch 0" \
    test "$(cat "$health/last-seen.PostToolBatch" 2>/dev/null)" -ge "$hook_now_before"

  # Stop.
  rein_st_write_usage "$usage" sess-stop 25
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl")"
  st_expect_silent "never blocks the stop with no pointer"
  rein_st_write_pointer "$pointer" "sess-other" "other" "$proj" 1
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl")"
  st_expect_silent "never blocks the stop when the pointer names a different session"
  rein_st_write_pointer "$pointer" "sess-stop" "current" "$proj" 1

  rein_st_write_usage "$usage" sess-stop 15
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl")"
  st_expect_silent "never blocks the stop below the trigger point"
  rein_st_write_usage "$usage" sess-stop 25 "$(TZ=UTC date -u -r "$(($(rein_now_epoch) - 3600))" +%Y-%m-%dT%H:%M:%SZ)"
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl")"
  st_expect_silent "never blocks the stop when usage is stale"
  st_expect_true "a turn deferred by staleness never consumes the latch" test ! -e "$hook_state/stop-latch.g1"
  rein_st_write_usage "$usage" sess-stop 25 "$(TZ=UTC date -u -r "$(($(rein_now_epoch) - 150))" +%Y-%m-%dT%H:%M:%SZ)"
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl" '{"background_tasks":[]}')"
  st_expect_json "blocks the stop within the freshness window" '.decision == "block"'
  rm -f "$hook_state/stop-latch.g1"
  rein_st_write_usage "$usage" sess-stop 25

  # Never pushes while children are running (replacing the parent takes the children down with
  # it). The primary evidence is the payload's background_tasks (while running, its entry's
  # status is running -- observed).
  before="$(st_log_lines "$hook_log")"
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl" \
    '{"background_tasks":[{"id":"a1","type":"subagent","status":"running","agent_type":"Explore"}]}')"
  st_expect_silent "never blocks the stop while children are running"
  st_expect_true "never consumes the latch while children are running" test ! -e "$hook_state/stop-latch.g1"
  st_expect_true "leaves one line in the lineage log for the deferral" \
    test "$(jq -r 'select(.event == "handover_deferred") | .event' "$hook_log" | head -1)" = "handover_deferred"
  st_expect_true "the deferral is recorded once per generation" \
    test "$(st_log_lines "$hook_log")" -eq "$((before + 1))"
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl" \
    '{"background_tasks":[{"id":"a1","type":"subagent","status":"running"}]}')"
  st_expect_true "never piles up the log for the same generation's deferral" \
    test "$(st_log_lines "$hook_log")" -eq "$((before + 1))"
  # A background_tasks with only non-running entries counts as "no children" -- pushes even if
  # the transcript is fresh.
  mkdir -p "$transcripts/sess-stop/subagents"
  : >"$transcripts/sess-stop/subagents/agent-1.jsonl"
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl" \
    '{"background_tasks":[{"id":"a1","type":"subagent","status":"completed"}]}')"
  st_expect_json "pushes once no children are running" '.decision == "block"'
  st_expect_true "never falls back to the transcript even for a non-empty background_tasks" \
    test "$(jq -r 'select(.event == "children_probe_degraded") | .event' "$hook_log" | head -1)" = ""
  rm -f "$hook_state/stop-latch.g1"
  before="$(st_log_lines "$hook_log")"
  # Only a case where the evidence itself is missing (no key) falls back to transcript freshness,
  # leaving one line about it.
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl")"
  st_expect_silent "never blocks the stop with no evidence and a fresh transcript"
  st_expect_true "a fallback turn never consumes the latch either" test ! -e "$hook_state/stop-latch.g1"
  st_expect_true "leaves the fallback in the lineage log" \
    test "$(jq -r 'select(.event == "children_probe_degraded") | .event' "$hook_log" | head -1)" = "children_probe_degraded"
  touch -t 202001010000 "$transcripts/sess-stop/subagents/agent-1.jsonl"

  # Once every condition is met, blocks the stop **once per generation**.
  before="$(st_log_lines "$hook_log")"
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl")"
  if st_expect_status "the stop-block branch exits 0" 0; then
    st_expect_json "blocks the stop in the official shape" '.decision == "block" and (.reason | length) > 0'
    st_expect_contains "carries the handover-request command" "request --runtime-dir '${runtime}' --session-id sess-stop"
    st_expect_not_contains "never leaves the session ID as a placeholder" "<your session ID>"
    st_expect_contains "fills in the handoff document path with a real value too" "--handoff '$records/$REIN_HANDOFF_BASENAME'"
    st_expect_contains "carries the escape hatch" "snooze --runtime-dir '${runtime}' 30m"
    # This is the one channel that says "write the document now," so the canonical
    # writing-rules text is also carried here (the wording is never copied by hand -- so this
    # check alone never shows green with stale wording once the canonical text is edited).
    st_expect_contains "the stop-block text also carries the canonical handoff-writing rules" "$REIN_HANDOFF_WRITING_RULES"
    st_expect_contains "the target path is quoted and carried as a single token" "'${proj}'"
    # The branches must appear **in priority order**. This fails if the imperative (running the
    # handover request) moves back to the top -- the contains checks above only see "is it
    # present," so this is the only check with order.
    st_expect_order "the stop-block text's branches are ordered by priority" \
      "$(printf '%s' "$ST_OUT" | jq -r '.reason')" \
      "explicit instructions" "close to done" "no clean breakpoint yet" "run the handover request command"
  fi
  st_expect_true "places the generation latch" test -f "$hook_state/stop-latch.g1"
  st_expect_true "leaves the block in the lineage log" \
    test "$(st_log_lines "$hook_log")" -eq "$((before + 1))"
  before="$(st_log_lines "$hook_log")"
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl" '{"stop_hook_active":true}')"
  st_expect_silent "passes through on the second call for the same generation"
  st_expect_true "a pass-through never grows the lineage log" \
    test "$(st_log_lines "$hook_log")" -eq "$before"

  # A generation whose handover request was **rejected** reverts to "not submitted" while the
  # normal latch stays consumed -- meaning the stop for that generation can never be blocked
  # again (the forced handover disappears entirely). If the rejection archive has a reason
  # written, this re-blocks once for that generation, carrying the reason verbatim.
  # The archive shape used here (a marker with `rejected_reason`) is written by the watcher,
  # and **the writer's own side is pinned by the watcher's own check (st_reject_case)** --
  # measuring both sides separately means either one alone changing shape fails one of the two
  # checks.
  mkdir -p "$rejected"
  # (1) Never re-blocked by someone else's rejection (a rejection is matched to this session's
  # own session_id alone).
  rein_st_write_marker "$rejected/20260101T000000Z-a.json" "sess-other" \
    "$(rein_iso_now)" "$tmp/handoff.md" "$proj"
  json="$(jq -c '. + {rejected_reason: "R3 session_id is empty"}' "$rejected/20260101T000000Z-a.json")"
  printf '%s\n' "$json" >"$rejected/20260101T000000Z-a.json"
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl")"
  st_expect_silent "never re-blocks the stop for someone else's rejection"
  # (2) Never re-blocked by an archive entry with no reason (a recovered leftover) either -- the
  # condition for re-blocking is that a reason exists.
  rein_st_write_marker "$rejected/20260101T000001Z-b.json" "sess-stop" \
    "$(rein_iso_now)" "$tmp/handoff.md" "$proj"
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl")"
  st_expect_silent "never re-blocks the stop for an archive entry with no reason"
  st_expect_true "a turn that was not re-blocked never consumes the rejection latch" \
    test ! -e "$hook_state/stop-latch-rejected.g1"
  # (3) Given this session's own rejection with a reason, re-blocks once and carries the reason
  # verbatim.
  # The reason is deliberately given a value containing characters that could corrupt JSON
  # (`"` and `\`) -- if the body were changed to be embedded directly into JSON via printf
  # instead, this check would fail.
  rein_st_write_marker "$rejected/20260101T000002Z-c.json" "sess-stop" \
    "$(rein_iso_now)" "$tmp/handoff.md" "$proj"
  json="$(jq -c '. + {rejected_reason: "R6 handoff_path is not an absolute path: \"a\\b\""}' \
    "$rejected/20260101T000002Z-c.json")"
  printf '%s\n' "$json" >"$rejected/20260101T000002Z-c.json"
  before="$(st_log_lines "$hook_log")"
  log_before="$(st_log_lines "$fire_log")"
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl")"
  if st_expect_json "re-blocks the stop for a rejected generation" '.decision == "block"'; then
    st_expect_json "names the rejection up front" \
      '.reason | startswith("[rein] The handover request you just made was not accepted")'
    st_expect_json "carries the rejection reason verbatim" \
      '.reason | contains("R6 handoff_path is not an absolute path: \"a\\b\"")'
    st_expect_json "states that the re-block happens only once" \
      '.reason | contains("This is the only time the stop will be blocked for this rejected generation")'
    st_expect_contains "the handover-request command matches the normal stop block" \
      "request --runtime-dir '${runtime}' --session-id sess-stop"
  fi
  st_expect_true "places the rejection generation latch" test -f "$hook_state/stop-latch-rejected.g1"
  st_expect_true "leaves the normal generation latch consumed" test -f "$hook_state/stop-latch.g1"
  st_expect_true "leaves the re-block in the lineage log" \
    test "$(st_log_lines "$hook_log")" -eq "$((before + 1))"
  st_expect_true "the lineage log's event tells it apart from a normal stop block (rejected)" \
    test "$(jq -r 'select(.event == "stop_blocked_request_rejected") | .event' "$hook_log" | head -1)" = "stop_blocked_request_rejected"
  st_expect_true "leaves the re-block's firing in the fire log" \
    test "$(st_log_lines "$fire_log")" -eq "$((log_before + 1))"
  # (4) Never unbounded -- a second turn for the same generation is never blocked (a lineage
  # rejected for the same defect on every attempt is never blocked every single turn).
  before="$(st_log_lines "$hook_log")"
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl")"
  st_expect_silent "never blocks a second turn for the same rejected generation"
  st_expect_true "a second turn never grows the lineage log" \
    test "$(st_log_lines "$hook_log")" -eq "$before"
  # (5) Even with a rejection present, a generation whose normal latch is still unconsumed still
  # pushes with **the normal wording** (the rejection path never hijacks the normal handover
  # trigger).
  rm -f "$hook_state/stop-latch.g1" "$hook_state/stop-latch-rejected.g1"
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl")"
  if st_expect_json "still blocks normally for an unconsumed generation" '.decision == "block"'; then
    st_expect_json "a normal generation never emits the rejection lead-in" \
      '.reason | startswith("[rein] Context usage has reached")'
  fi
  st_expect_true "a normal generation places no rejection latch" \
    test ! -e "$hook_state/stop-latch-rejected.g1"
  # (6) Cleanup for a past generation prunes **every** kind (never leaves one behind). Each kind
  # is planted for the old generation before the advance, so a cleanup that folds only the kinds
  # it was originally written for is named on the spot rather than leaking one file per handover
  # for the life of the lineage.
  : >"$hook_state/stop-latch-rejected.g1"
  : >"$hook_state/handover-wait.g1"
  rein_st_write_pointer "$pointer" "sess-stop" "current" "$proj" 2
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl")"
  st_expect_json "blocks again once the generation advances (even with a rejection archived)" '.decision == "block"'
  st_expect_true "prunes the previous generation's rejection latch too" test ! -e "$hook_state/stop-latch-rejected.g1"
  st_expect_true "prunes the previous generation's handover-wait latch too" \
    test ! -e "$hook_state/handover-wait.g1"
  rein_st_write_pointer "$pointer" "sess-stop" "current" "$proj" 1
  rm -f "$hook_state"/stop-latch.g* "$hook_state"/stop-latch-rejected.g* "$hook_state"/handover-wait.g*
  rm -rf "$rejected"

  # The stop-block output is written **after the persistent marker is consumed, but before
  # entering any layer that cannot be rolled back**. A hook can be cut off from outside by the
  # registration timeout (hooks/hooks.json's 10 seconds), so inserting the fire log (whose
  # rotation can spawn a lock acquisition and `ps`) between consuming the marker and writing the
  # output would mean a cut-off run consumes only the latch with not one character of the block
  # reaching anyone (the lineage log would show stop_blocked while it passed through silently).
  # This order isn't visible from outside directly, so **a shim is placed on `date`** (which
  # stamps timestamps) to record how many bytes of stdout exist at the moment it's called. The
  # `date` that runs before the latch is placed (building the lineage log line) should be 0; the
  # `date` that builds the fire log entry should be non-zero -- meaning the output sits ahead of
  # the record layer. **Both are measured**, so a regression that moves the output after the log
  # fails on "the last one is 0."
  rm -f "$hook_state/stop-latch.g1"
  mkdir -p "$tmp/date-bin"
  cat >"$tmp/date-bin/date" <<'DATESHIM'
#!/bin/sh
# Records, on one line, how many bytes are on the hook's stdout at the moment this is called,
# then hands off to the real command.
size="$(wc -c <"$REIN_ST_STDOUT_FILE" 2>/dev/null | tr -d ' ')"
[ -n "$size" ] || size=0
printf '%s\n' "$size" >>"$REIN_ST_DATE_LOG"
exec "$REIN_ST_REAL_DATE" "$@"
DATESHIM
  chmod +x "$tmp/date-bin/date"
  : >"$tmp/date-order.log"
  ST_ENV=("${ST_ENV_MANAGED[@]}" "PATH=$tmp/date-bin:$PATH"
    "REIN_ST_REAL_DATE=$(command -v date)"
    "REIN_ST_STDOUT_FILE=$ST_TMPDIR/out"
    "REIN_ST_DATE_LOG=$tmp/date-order.log")
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl" '{"background_tasks":[]}')"
  ST_ENV=("${ST_ENV_MANAGED[@]}")
  st_expect_json "blocks the stop even through the date shim" '.decision == "block"'
  st_expect_true "stamps the time on both sides of the marker (order can be measured)" \
    test "$(st_log_lines "$tmp/date-order.log")" -ge 2
  st_expect_true "nothing is output yet before the latch is placed" \
    test "$(head -1 "$tmp/date-order.log")" -eq 0
  st_expect_true "the stop-block response is already out by the time the fire log is assembled" \
    test "$(tail -1 "$tmp/date-order.log")" -gt 0
  rm -f "$hook_state/stop-latch.g1"

  # Once the generation advances, pushes again exactly once. Prunes the latch for a past
  # generation.
  rein_st_write_pointer "$pointer" "sess-stop" "current" "$proj" 2
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl")"
  st_expect_json "blocks again once the generation advances" '.decision == "block"'
  st_expect_true "places a latch per generation" test -f "$hook_state/stop-latch.g2"
  st_expect_true "prunes the previous generation's latch" test ! -e "$hook_state/stop-latch.g1"
  rein_st_write_pointer "$pointer" "sess-stop" "current" "$proj" 1
  rm -f "$hook_state/stop-latch.g1"

  # For a lineage at the default location, the message never names the lineage explicitly
  # (never lengthen the one-liner needlessly). This uses **the same runtime directory** as the
  # case above, with only XDG pointed at its parent -- so the only variable is whether this is
  # the default location, pinning both the naming and non-naming sides here.
  ST_ENV=("${ST_ENV_MANAGED[@]}" "XDG_STATE_HOME=$tmp/state")
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl")"
  if st_expect_json "still blocks for a lineage at the default location" '.decision == "block"'; then
    st_expect_contains "never names the lineage at the default location" "request --session-id sess-stop"
    st_expect_not_contains "never adds a location flag for the default location" "--runtime-dir"
    st_expect_contains "the snooze one-liner also never names the lineage" "snooze 30m"
  fi
  ST_ENV=("${ST_ENV_MANAGED[@]}")
  rm -f "$hook_state/stop-latch.g1"

  # Never pushes once a handover request is already out. Someone else's marker means this
  # session is itself unsubmitted, so it's on the pushing side. Staying silent while submitted
  # requires **the watcher to be around**, so this section runs on top of the running-watcher
  # fixture.
  rein_st_start_fake_watcher "$runtime" "$proj"
  rein_st_write_marker "$marker" "sess-other" "$(rein_iso_now)" "$tmp/handoff.md" "$proj"
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl")"
  st_expect_json "never reads someone else's marker as this session's own submission" '.decision == "block"'
  # An unsubmitted turn never places the final-output marker (the condition for placing it is
  # "this session's own handover request is submitted," on a lineage whose cap isn't 0 -- the
  # watcher's liveness is deliberately **not** part of it, which is what the run further down
  # with no watcher around pins).
  st_expect_true "an unsubmitted turn never places the final-output marker" test ! -e "$handover_ready"
  # No marker placed means no wait announced either -- an ordinary stop (no handover request of
  # this session's own) never tells the user a handover is coming. Asserted on the **shape**
  # (this run blocks, and carries no user-facing line at all) rather than on the wording, so
  # rephrasing the notice can never silently disable this.
  st_expect_json "an unsubmitted turn never announces a wait" \
    '.decision == "block" and .systemMessage == null'
  rm -f "$hook_state/stop-latch.g1"
  rein_st_write_marker "$marker" "sess-stop" "$(rein_iso_now)" "$tmp/handoff.md" "$proj"
  before="$(st_log_lines "$fire_log")"
  log_before="$(st_log_lines "$hook_log")"
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl")"
  # The first submitted turn on a lineage with a watcher around is where "the wait has started"
  # becomes true, so that turn tells the user -- on `systemMessage`, which reaches the screen
  # even though this run doesn't block the stop. **The stop itself is still not pushed** (no
  # `decision`), so the notice never doubles as a block.
  # The exit status is asserted first, and the shape only underneath it: a run that fails loudly
  # while still printing something (the fire log's own write failure exits 0 and puts its reason
  # on stderr, so both dimensions have to be named separately) would otherwise pass on stdout
  # alone.
  if st_expect_status "the run that emits the handover-wait notice exits 0" 0; then
    st_expect_true "the handover-wait notice run says nothing on stderr" test -z "$ST_ERR"
    if st_expect_json "the run that newly places the marker emits only the handover-wait notice" \
      '.decision == null and (.systemMessage | type == "string")'; then
      st_expect_contains "the notice names the wait from final_output_wait_sec and how to cancel" \
        "[rein] Handover in 10 s. Talk to this session to cancel."
    fi
  fi
  # **Exactly one JSON value comes out.** `st_expect_json` cannot see this dimension at all --
  # `jq -e` takes its exit status from the **last** value in the stream, so a second object
  # printed on the same run would satisfy every filter written above. A Stop hook's output is one
  # JSON object, so counting the values is the only thing that holds that shape.
  st_expect_true "the handover-wait notice run prints exactly one JSON value" \
    test "$(st_out_json_count)" -eq 1
  st_expect_true "never consumes the latch while submitted" test ! -e "$hook_state/stop-latch.g1"
  # **The notice's own latch is what holds it to once**, and it is placed only by a run that
  # actually printed a line. Measuring the file directly (rather than only "the next turn is
  # silent") is what tells "the latch was placed" apart from "some other gate happened to fold"
  # -- the two are indistinguishable from the output alone.
  st_expect_true "the run that announced the wait consumes the notice's generation latch" \
    test -e "$wait_latch"
  # Nothing is written to the lineage log: its `event` values are all about blocking a stop or
  # letting one through, and this run does neither. The watcher-missing block further down is
  # measured the other way around (it must add exactly one line), so the pair pins both sides.
  st_expect_true "the handover-wait notice leaves no line in the lineage log" \
    test "$(st_log_lines "$hook_log")" -eq "$log_before"
  # Emitting a line is a firing, so it lands in the firing log like every other one (the no-op
  # path rule only covers a run that emits nothing).
  st_expect_true "the handover-wait notice leaves one line in the fire log" \
    test "$(st_log_lines "$fire_log")" -eq "$((before + 1))"
  st_expect_true "the fire log records it as a notice, with reason handover-wait" \
    test "$(jq -s -r '[ .[] | select(.decision == "notice" and .reason == "handover-wait") ] | length' "$fire_log")" -ge 1
  # Before passing through silently, places the "finished producing output" marker (the watcher
  # waits on this before launching a successor). Its contents are a single line, session_id --
  # the watcher uses it to judge whether the marker belongs to its own request.
  st_expect_true "a submitted Stop places the final-output marker" test -f "$handover_ready"
  st_expect_true "the marker's contents are this session's own session_id" \
    test "$(cat "$handover_ready" 2>/dev/null)" = "sess-stop"
  # **Never rewritten if this session's own marker is already there** (this runs on every turn,
  # so rewriting on the no-op path would let writes pile up). This can't be measured by contents
  # (rewriting the same value leaves the contents unchanged), so mtime is set into the past to
  # check it instead.
  touch -t 200001010000 "$handover_ready"
  mark_mtime="$(rein_mtime "$handover_ready")"
  before="$(st_log_lines "$fire_log")"
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl")"
  # Every later turn folds on the notice's latch, so the line never repeats itself while the
  # user keeps talking -- and nothing is recorded either.
  st_expect_silent "stays silent on a turn where the marker already exists too"
  st_expect_true "never records a firing on the turn where the marker already exists" \
    test "$(st_log_lines "$fire_log")" -eq "$before"
  st_expect_true "never rewrites this session's own marker if it is already there" \
    test "$(rein_mtime "$handover_ready")" = "$mark_mtime"
  # **The latch, not the marker, is what silences the repeat.** Removing the marker and running
  # again puts the run back on the "newly placed it" branch the notice used to hang off -- if it
  # still rang there, it would ring on every turn of a lineage whose marker keeps being cleared.
  before="$(st_log_lines "$fire_log")"
  rm -f "$handover_ready"
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl")"
  st_expect_silent "stays silent on a re-placed marker once this generation has been told"
  st_expect_true "records no firing when the notice folds on its latch" \
    test "$(st_log_lines "$fire_log")" -eq "$before"
  st_expect_true "the re-placed marker is still written" test -f "$handover_ready"
  # The number comes from the settings layer, not from a literal (a lineage that stretched the
  # window would otherwise be told the default, and speak up too late). The notice's latch is
  # cleared first -- this generation has already been told, and without clearing it the check
  # would go green on silence rather than on the wording.
  rm -f "$handover_ready" "$wait_latch"
  ST_ENV=("${ST_ENV_MANAGED[@]}" "REIN_FINAL_OUTPUT_WAIT_SEC=45")
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl")"
  st_expect_contains "the notice carries the lineage's own configured wait" \
    "[rein] Handover in 45 s. Talk to this session to cancel."
  ST_ENV=("${ST_ENV_MANAGED[@]}")
  rm -f "$handover_ready" "$wait_latch"
  # **A lineage whose wait is 0 seconds says nothing.** The watcher leaves the wait on the same
  # poll that sees the marker, so "Handover in 0 s. Talk to this session to cancel." would be
  # false in both halves at once -- there is no window, and nothing to speak up into.
  ST_ENV=("${ST_ENV_MANAGED[@]}" "REIN_FINAL_OUTPUT_WAIT_SEC=0")
  before="$(st_log_lines "$fire_log")"
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl")"
  st_expect_silent "announces nothing for a lineage whose wait is 0 seconds"
  st_expect_true "records no firing for a lineage whose wait is 0 seconds" \
    test "$(st_log_lines "$fire_log")" -eq "$before"
  # **Nothing was said, so nothing is latched.** The latch records that a line went out, so a
  # `0` lineage consuming it would leave the generation marked as told after saying nothing --
  # and raising the wait back above 0 mid-generation would then stay silent forever.
  st_expect_true "a lineage whose wait is 0 seconds consumes no notice latch" \
    test ! -e "$wait_latch"
  # **The marker is still placed** -- the 0 withholds the line, not the mechanism (the marker's
  # own gate is a different setting, `final_output_timeout_sec`, measured further down).
  st_expect_true "still places the final-output marker for a lineage whose wait is 0 seconds" \
    test "$(cat "$handover_ready" 2>/dev/null)" = "sess-stop"
  ST_ENV=("${ST_ENV_MANAGED[@]}")
  rm -f "$handover_ready"
  # Someone else's marker (left behind from a previous handover) is overwritten with this
  # session's own.
  printf '%s\n' "sess-other" >"$handover_ready"
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl")"
  # Overwriting someone else's marker is a separate branch of the placement, and the notice is
  # measured on it too -- with the latch untouched from the `0` run above, this generation has
  # still not been told, so the line is due here.
  st_expect_json "announces the wait on the run that overwrote someone else's marker" \
    '.decision == null and (.systemMessage | type == "string")'
  st_expect_true "overwrites someone else's marker with this session's own" \
    test "$(cat "$handover_ready" 2>/dev/null)" = "sess-stop"

  # The marker is placed **ahead of every gate that decides whether to push for a handover**.
  # Placing it lower would silently disable it exactly where the mechanism is needed most (the
  # user requesting a handover at low usage, a session with no usage record, within a snooze
  # period, the suppression window after a watcher-missing notice). This confirms only that the
  # marker still gets placed, with each gate raised one at a time.
  rm -f "$handover_ready" "$wait_latch"
  rein_st_write_usage "$usage" sess-stop 5
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl")"
  # Each of the gates below carries the notice with it, so each one is measured for the line as
  # well as for the marker -- a gate that silently swallowed the notice while still placing the
  # marker would otherwise pass. **The notice's latch is cleared before each of them**, since
  # this whole run is one generation: without that, every case after the first would go green on
  # the latch and never reach the gate it means to measure.
  if st_expect_status "the run below the trigger point exits 0" 0; then
    st_expect_json "never pushes below the trigger point (submitted, marker turn)" \
      '.decision == null and (.systemMessage | type == "string")'
  fi
  st_expect_true "still places the marker below the trigger point" test -f "$handover_ready"
  rm -f "$handover_ready" "$wait_latch"
  rein_st_write_usage "$usage" sess-stop 25 \
    "$(TZ=UTC date -u -r "$(($(rein_now_epoch) - 3600))" +%Y-%m-%dT%H:%M:%SZ)"
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl")"
  st_expect_json "still announces the wait even with stale usage" \
    '.decision == null and (.systemMessage | type == "string")'
  st_expect_true "still places the marker even with stale usage" test -f "$handover_ready"
  rm -f "$handover_ready" "$wait_latch" "$usage/sess-stop.json"
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl")"
  st_expect_json "still announces the wait even with no usage record" \
    '.decision == null and (.systemMessage | type == "string")'
  st_expect_true "still places the marker even with no usage record" test -f "$handover_ready"
  rein_st_write_usage "$usage" sess-stop 25
  rm -f "$handover_ready" "$wait_latch"
  jq -nc --arg s "$REIN_SNOOZE_SCHEMA" \
    --arg until "$(TZ=UTC date -u -r "$(($(rein_now_epoch) + 900))" +%Y-%m-%dT%H:%M:%SZ)" \
    '{schema: $s, until: $until}' >"$runtime/$REIN_SNOOZE_BASENAME"
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl")"
  st_expect_json "still announces the wait within a snooze period" \
    '.decision == null and (.systemMessage | type == "string")'
  st_expect_true "still places the marker within a snooze period" test -f "$handover_ready"
  rm -f "$runtime/$REIN_SNOOZE_BASENAME" "$hook_state/sess-stop.snooze-logged" "$handover_ready" "$wait_latch"
  # **A turn with a live watcher-missing suppression window** (i.e. the middle of <notice ->
  # the user starts it -> resubmit>). This measures with the deadline kept in the future -- if
  # the marker isn't placed here, this always fails exactly where the mechanism is needed most.
  # The other cases above measured this with the deadline already expired; this is their
  # counterpart.
  printf '%s\n' "$(($(rein_now_epoch) + 3600))" >"$hook_state/sess-stop.watcher-missing"
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl")"
  if st_expect_status "the run within the suppression window exits 0" 0; then
    st_expect_json "never pushes within the suppression window (only the notice)" \
      '.decision == null and (.systemMessage | type == "string")'
  fi
  st_expect_true "still places the marker with a live suppression window" test -f "$handover_ready"
  rm -f "$hook_state/sess-stop.watcher-missing" "$handover_ready" "$wait_latch"
  # A lineage with no waiting step (cap 0) never places it -- never keeps placing a marker that
  # has no one to read it.
  ST_ENV=("${ST_ENV_MANAGED[@]}" "REIN_FINAL_OUTPUT_TIMEOUT_SEC=0")
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl")"
  st_expect_true "never places the marker for a lineage with cap 0" test ! -e "$handover_ready"
  # No marker means no wait for the user to be told about either -- the existing condition
  # carries the notice with it, and nothing separate has to be turned off. This run emits
  # nothing at all, so **silence is what has to be asserted**: a "does not contain" against
  # empty output is true no matter what the mechanism does.
  st_expect_silent "never announces a wait for a lineage with cap 0"
  ST_ENV=("${ST_ENV_MANAGED[@]}")
  rm -f "$marker" "$handover_ready" "$wait_latch"
  # A claimed marker (one the watcher moved into `processing/` while judging it) also counts as
  # submitted.
  mkdir -p "$processing"
  rein_st_write_marker "$processing/20260101T000000Z-1.json" "sess-other" \
    "$(rein_iso_now)" "$tmp/handoff.md" "$proj"
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl")"
  st_expect_json "never reads someone else's claimed marker as this session's own submission" '.decision == "block"'
  rm -f "$hook_state/stop-latch.g1"
  rein_st_write_marker "$processing/20260101T000000Z-2.json" "sess-stop" \
    "$(rein_iso_now)" "$tmp/handoff.md" "$proj"
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl")"
  if st_expect_status "the run with a claimed marker exits 0" 0; then
    st_expect_json "never pushes while claimed (only the notice)" \
      '.decision == null and (.systemMessage | type == "string")'
  fi
  st_expect_true "still places the final-output marker even while claimed" \
    test "$(cat "$handover_ready" 2>/dev/null)" = "sess-stop"
  rm -f "$processing"/*.json "$handover_ready"

  # Even when submitted, never stays silent if no watcher is around (there's no one to clear the
  # marker, so nobody ever advances the handover while the context runs out). The generation
  # latch is not consumed; this blocks once via a different kind of cooldown.
  rein_st_stop_fake_watcher "$runtime"
  rein_st_write_marker "$marker" "sess-stop" "$(rein_iso_now)" "$tmp/handoff.md" "$proj"
  # The notice's latch is cleared so that **the watcher is what withholds the line here.** With
  # the latch left in place from an earlier case, "no wait was announced" would hold no matter
  # what the watcher condition did.
  rm -f "$wait_latch"
  before="$(st_log_lines "$fire_log")"
  log_before="$(st_log_lines "$hook_log")"
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl")"
  if st_expect_json "blocks even when submitted, if no watcher is around" '.decision == "block"'; then
    st_expect_contains "carries the operation to start the watcher" "$(rein_shell_quote "$REIN_BIN") --cwd '${proj}' up"
    st_expect_contains "also carries the judgment reason" "no watcher lock"
    st_expect_contains "adds the caveat for a lineage naming its own location" "--runtime-dir"
    # **This run newly places the marker too, and still announces no wait** -- with no watcher
    # there is nobody to run the countdown, so the line would be false. Asserted on the
    # **shape** (this run blocks and carries no user-facing line), not on the wording, so
    # rephrasing the notice can never silently disable this.
    st_expect_json "never announces a wait with no watcher around" \
      '.decision == "block" and .systemMessage == null'
    # This is the run where the two branches compete for the same output: the notice's condition
    # is met (its latch is unconsumed) and the block's is too. Both read the one shared watcher
    # judgment, so exactly one JSON value comes out -- counted, because `jq -e` takes its status
    # from the last value and cannot see a second one printed before it.
    st_expect_true "the watcher-missing run prints exactly one JSON value" \
      test "$(st_out_json_count)" -eq 1
  fi
  # **A line that never went out latches nothing.** If the notice consumed its latch on the run
  # where the watcher was missing, the recovery path further down would have nothing left to
  # ring with -- exactly the defect this latch exists to close.
  st_expect_true "a withheld notice consumes no latch" test ! -e "$wait_latch"
  st_expect_true "never consumes the latch when the watcher is missing" test ! -e "$hook_state/stop-latch.g1"
  # **The watcher's liveness is not a condition for the marker either** -- the marker represents
  # only the fact "output finished," independent of whether anyone is around to read it. If it
  # weren't placed here, the mechanism would fail exactly on the handover right after the watcher
  # is restarted.
  st_expect_true "still places the marker even with no watcher" test -f "$handover_ready"
  st_expect_true "places the watcher-missing cooldown" test -f "$hook_state/sess-stop.watcher-missing"
  st_expect_true "leaves the watcher-missing firing in the fire log" \
    test "$(st_log_lines "$fire_log")" -eq "$((before + 1))"
  st_expect_true "the fire log's reason is watcher-missing" \
    test "$(jq -s -r '[ .[] | select(.reason == "watcher-missing") ] | length' "$fire_log")" -ge 1
  # Also left in the lineage log (reaches both a reader who only watches the fire log and one who
  # only watches the lineage log).
  st_expect_true "leaves the watcher-missing stop block in the lineage log" \
    test "$(st_log_lines "$hook_log")" -eq "$((log_before + 1))"
  st_expect_true "the lineage log's event tells it apart from a normal stop block" \
    test "$(jq -r 'select(.event == "stop_blocked_watcher_missing") | .event' "$hook_log" | head -1)" = "stop_blocked_watcher_missing"

  # **Usage is not a condition for this block.** `rein request` runs at any usage, so a request
  # placed below the trigger point strands exactly the same way -- and with the trigger-point
  # comparison sitting ahead of this branch, that lineage went silent on Stop as well as on the
  # advisory channel, leaving nothing anywhere to say the request was stuck. Measured **below
  # the trigger point** with everything else held as in the case above, so only the comparison's
  # position can account for the difference.
  printf '%s\n' "1" >"$hook_state/sess-stop.watcher-missing"
  rein_st_write_usage "$usage" sess-stop 5
  log_before="$(st_log_lines "$hook_log")"
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl")"
  if st_expect_json "blocks below the trigger point too, if no watcher is around" '.decision == "block"'; then
    st_expect_contains "the below-threshold block carries the operation to start the watcher" \
      "$(rein_shell_quote "$REIN_BIN") --cwd '${proj}' up"
  fi
  st_expect_true "the below-threshold block consumes no generation latch" \
    test ! -e "$hook_state/stop-latch.g1"
  st_expect_true "the below-threshold block leaves its line in the lineage log" \
    test "$(st_log_lines "$hook_log")" -eq "$((log_before + 1))"
  # **The counterpart: the normal push stays inside the trigger point.** On the same
  # below-threshold turn with no request submitted, the stop passes through in silence -- had
  # the comparison been dragged out along with the branch above, the ordinary handover trigger
  # would fire at any usage at all.
  rm -f "$marker" "$hook_state/sess-stop.watcher-missing"
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl")"
  st_expect_silent "an unsubmitted turn below the trigger point still passes through silently"
  st_expect_true "an unsubmitted below-threshold turn consumes no generation latch" \
    test ! -e "$hook_state/stop-latch.g1"
  rein_st_write_marker "$marker" "sess-stop" "$(rein_iso_now)" "$tmp/handoff.md" "$proj"
  rein_st_write_usage "$usage" sess-stop 25

  # There are two channels that block a stop. **The structurally identical second one** must
  # also write in the same order (consume the marker -> output -> record layer) -- fixing only
  # one would leave this channel alone silently dropped by a cut-off run. Measured the same way
  # as above.
  printf '%s\n' "1" >"$hook_state/sess-stop.watcher-missing"
  : >"$tmp/date-order.log"
  ST_ENV=("${ST_ENV_MANAGED[@]}" "PATH=$tmp/date-bin:$PATH"
    "REIN_ST_REAL_DATE=$(command -v date)"
    "REIN_ST_STDOUT_FILE=$ST_TMPDIR/out"
    "REIN_ST_DATE_LOG=$tmp/date-order.log")
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl")"
  ST_ENV=("${ST_ENV_MANAGED[@]}")
  st_expect_json "blocks for a missing watcher even through the date shim" '.decision == "block"'
  st_expect_true "the watcher-missing channel also stamps the time on both sides of the marker" \
    test "$(st_log_lines "$tmp/date-order.log")" -ge 2
  st_expect_true "the watcher-missing channel outputs nothing before consuming the cooldown" \
    test "$(head -1 "$tmp/date-order.log")" -eq 0
  st_expect_true "the watcher-missing channel's response is already out by the time the fire log is assembled" \
    test "$(tail -1 "$tmp/date-order.log")" -gt 0
  log_before="$(st_log_lines "$hook_log")"
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl")"
  st_expect_silent "a second watcher-missing turn stays silent via the cooldown"
  st_expect_true "a silent turn never grows the lineage log" \
    test "$(st_log_lines "$hook_log")" -eq "$log_before"

  # Silence during the cooldown happens **without spawning `ps`** (never add an external command
  # for a submitted turn). Since this can only be measured by a count, both sides (silent turn,
  # emitting turn) are measured through a shim that counts `ps` calls. The state measured is a
  # watcher lock that exists but whose owner's pid is gone (stale) -- a case that requires
  # identity to be checked. Only the cooldown is varied to measure both sides (splitting on
  # whether the lock exists would mix in a path that never needs `ps` at all).
  # **The free turn is the one where this generation has already been told the wait started.**
  # That is the steady state -- the notice fires on the first watched turn after the request
  # goes out, and every turn after it folds on the latch before asking anything. A turn where
  # the notice is still owed does pay the one shared judgment, and it has to: whether the
  # watcher came back is the very fact that turn has to establish, and the cooldown is silent
  # about it. Both sides are measured, so the free case can never quietly widen into the paid
  # one or the reverse.
  rein_st_write_counting_ps "$tmp/ps-bin"
  ST_ENV=("${ST_ENV_MANAGED[@]}" "PATH=$tmp/ps-bin:$PATH" "FAKE_PS_LOG=$tmp/ps.log")
  mkdir -p "$runtime/$REIN_LOCK_DIRNAME"
  # A pid near the numbering ceiling (a value `ps` can confirm doesn't exist).
  printf '99998\n' >"$runtime/$REIN_LOCK_DIRNAME/pid"
  : >"$tmp/ps.log"
  : >"$wait_latch"
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl")"
  st_expect_silent "Stop also stays silent during the cooldown (through the ps shim)"
  st_expect_true "never spawns ps during the cooldown once the wait has been announced" \
    test "$(st_log_lines "$tmp/ps.log")" -eq 0
  # The paid counterpart: same cooldown, same silence, but this generation has not been told
  # yet, so the one shared judgment is asked. Still exactly one -- the notice and the
  # watcher-missing branch share it (hook_watcher_resident caches it for the run).
  rm -f "$wait_latch"
  : >"$tmp/ps.log"
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl")"
  st_expect_silent "a turn that still owes the notice is silent during the cooldown too"
  st_expect_true "a turn that still owes the notice asks the watcher exactly once" \
    test "$(st_log_lines "$tmp/ps.log")" -eq 1
  st_expect_true "a turn that owed the notice but found no watcher latches nothing" \
    test ! -e "$wait_latch"
  # Once the deadline passes, fires again once in the same state (the cooldown is not "never
  # again").
  printf '%s\n' "1" >"$hook_state/sess-stop.watcher-missing"
  : >"$tmp/ps.log"
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl")"
  if st_expect_json "blocks again once the deadline passes" '.decision == "block"'; then
    st_expect_contains "a stale lock is also handled on the not-running side" "stale"
  fi
  st_expect_true "checks identity once the deadline expires" test "$(st_log_lines "$tmp/ps.log")" -gt 0
  ST_ENV=("${ST_ENV_MANAGED[@]}")
  rm -rf "${runtime:?}/$REIN_LOCK_DIRNAME"

  # An undetermined case (the watcher lock exists but its owner can't be read) never gets the
  # same message as "not running." Falling to the "please start it" message would risk starting
  # a second one against a lineage actually being watched, or fail to resolve anything even
  # once started.
  mkdir -p "$runtime/$REIN_LOCK_DIRNAME"
  printf '%s\n' "1" >"$hook_state/sess-stop.watcher-missing"
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl")"
  if st_expect_json "blocks the stop even for a lock whose owner cannot be read" '.decision == "block"'; then
    st_expect_contains "says it cannot be determined" "cannot be determined"
    st_expect_contains "carries the watcher lock's location" "$runtime/$REIN_LOCK_DIRNAME"
    st_expect_not_contains "never turns into the missing-watcher message" "$(rein_shell_quote "$REIN_BIN") --cwd '${proj}' up"
  fi
  rm -rf "${runtime:?}/$REIN_LOCK_DIRNAME"

  # **The watcher-recovery turn.** The block stops once the watcher is back (measuring only one
  # side can't tell that apart from "always blocks"), and this is also the turn that finally
  # tells the user the wait has started. Everything about this state was already true before
  # the watcher came back except one thing: the marker has been this session's own since the
  # very first turn with no watcher around. So "this run newly placed the marker" -- the
  # judgment the notice used to hang off -- is false here and stays false for the rest of the
  # generation, and the handover went ahead with the terminal switching under the user and no
  # line at all. The notice's own latch is what is still unconsumed, and this turn consumes it.
  rein_st_start_fake_watcher "$runtime" "$proj"
  printf '%s\n' "1" >"$hook_state/sess-stop.watcher-missing"
  # The precondition the defect lived in, asserted rather than assumed: the marker is already
  # this session's own going into the recovery turn, so nothing here can be passing on the
  # "newly placed" branch.
  st_expect_true "the marker is already this session's own before the recovery turn" \
    test "$(cat "$handover_ready" 2>/dev/null)" = "sess-stop"
  st_expect_true "this generation has not been told the wait started yet" test ! -e "$wait_latch"
  before="$(st_log_lines "$fire_log")"
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl")"
  if st_expect_status "the recovery turn exits 0" 0; then
    # The stop is no longer blocked, and the notice is the only thing on this run.
    if st_expect_json "announces the wait on the first turn after the watcher is back" \
      '.decision == null and (.systemMessage | type == "string")'; then
      st_expect_contains "the recovery turn's line is the handover-wait notice" \
        "[rein] Handover in 10 s. Talk to this session to cancel."
    fi
  fi
  st_expect_true "the recovery turn consumes the notice's generation latch" test -e "$wait_latch"
  st_expect_true "the recovery turn records one firing" \
    test "$(st_log_lines "$fire_log")" -eq "$((before + 1))"
  # **And it rings exactly once.** Ringing every turn was explicitly not the fix -- from here on
  # this is an ordinary submitted-and-watched turn, silent as it always was.
  before="$(st_log_lines "$fire_log")"
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl")"
  st_expect_silent "once the watcher is back and the line has gone out, a submitted turn is silent"
  st_expect_true "the turn after the recovery records no firing" \
    test "$(st_log_lines "$fire_log")" -eq "$before"
  st_expect_true "the marker is placed once the watcher is back too" test -f "$handover_ready"
  rm -f "$marker" "$hook_state/sess-stop.watcher-missing" "$handover_ready" "$wait_latch"

  # Passes through within a snooze period, leaving exactly one line about it in the lineage log.
  before="$(st_log_lines "$hook_log")"
  jq -nc --arg s "$REIN_SNOOZE_SCHEMA" \
    --arg until "$(TZ=UTC date -u -r "$(($(rein_now_epoch) + 1800))" +%Y-%m-%dT%H:%M:%SZ)" \
    '{schema: $s, until: $until}' >"$runtime/$REIN_SNOOZE_BASENAME"
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl")"
  st_expect_silent "passes through within a snooze period"
  st_expect_true "a pass-through never consumes the latch" test ! -e "$hook_state/stop-latch.g1"
  st_expect_true "leaves one line in the lineage log for the pass-through" \
    test "$(st_log_lines "$hook_log")" -eq "$((before + 1))"
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl")"
  st_expect_true "never piles up the log for the same snooze" \
    test "$(st_log_lines "$hook_log")" -eq "$((before + 1))"
  st_expect_true "the pass-through's event is stop_snoozed" \
    test "$(jq -r 'select(.event == "stop_snoozed") | .event' "$hook_log" | head -1)" = "stop_snoozed"
  # An expired snooze is never passed through.
  jq -nc --arg s "$REIN_SNOOZE_SCHEMA" \
    --arg until "$(TZ=UTC date -u -r "$(($(rein_now_epoch) - 60))" +%Y-%m-%dT%H:%M:%SZ)" \
    '{schema: $s, until: $until}' >"$runtime/$REIN_SNOOZE_BASENAME"
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl" '{"background_tasks":[]}')"
  st_expect_json "blocks the stop for an expired snooze" '.decision == "block"'
  rm -f "$runtime/$REIN_SNOOZE_BASENAME" "$hook_state/stop-latch.g1"

  # A case where the log can't be written **never ends with the persistent marker left
  # consumed** (rolls it back before dying).
  before="$(st_log_lines "$hook_log")"
  mv "$hook_log" "$tmp/hook-log-backup"
  mkdir -p "$hook_log"
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl" '{"background_tasks":[]}')"
  if st_expect_status "a stop block that cannot write the log fails" 1; then
    st_expect_true "injects nothing on a turn that could not block" test -z "$ST_OUT"
  fi
  st_expect_true "a turn that could not write never consumes the latch" test ! -e "$hook_state/stop-latch.g1"
  rmdir "$hook_log"
  mv "$tmp/hook-log-backup" "$hook_log"

  # The append target is a symlink. Since `>>` follows it and writes to **whatever it points
  # to**, the point of anchoring the records location to the project side is defeated (the
  # target is whatever the clone's author chose).
  printf 'sentinel\n' >"$tmp/outside-hook.log"
  mv "$hook_log" "$tmp/hook-log-backup"
  ln -s "$tmp/outside-hook.log" "$hook_log"
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl" '{"background_tasks":[]}')"
  if st_expect_status "a stop block with a symlinked append target fails" 1; then
    st_expect_true "injects nothing on a turn that could not block (symlink)" test -z "$ST_OUT"
  fi
  st_expect_true "never appends to what the symlink points to" \
    test "$(st_log_lines "$tmp/outside-hook.log")" -eq 1
  st_expect_true "a turn that could not write never consumes the latch (symlink)" \
    test ! -e "$hook_state/stop-latch.g1"
  rm -f "$hook_log"
  mv "$tmp/hook-log-backup" "$hook_log"
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl" '{"background_tasks":[]}')"
  st_expect_json "blocks again on the next stop after the rollback" '.decision == "block"'
  st_expect_true "only then does the latch actually get consumed" test -f "$hook_state/stop-latch.g1"
  st_expect_true "leaves one line in the log for the turn that blocked" \
    test "$(st_log_lines "$hook_log")" -eq "$((before + 1))"
  rm -f "$hook_state/stop-latch.g1"

  # The handover-request command carries the handoff document's actual effective value (a
  # lineage that named it in config).
  printf 'threshold_notice=10\nthreshold_handover=20\nnotice_cooldown_sec=120\nusage_stale_sec=180\nhandoff_path=%s\nusage_state_dir=%s\n' \
    "$tmp/handoff.md" "$usage" >"$records/config"
  st_allow_records_config
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl" '{"background_tasks":[]}')"
  st_expect_json "still blocks with a configured document" '.decision == "block"'
  st_expect_contains "carries the configured document in --handoff" "--handoff '$tmp/handoff.md'"
  st_expect_not_contains "never emits the replacement caveat once filled with a real value" \
    "Replace \`<absolute path to the handoff document>\`"
  printf 'threshold_notice=10\nthreshold_handover=20\nnotice_cooldown_sec=120\nusage_stale_sec=180\nusage_state_dir=%s\n' \
    "$usage" >"$records/config"
  st_allow_records_config
  rm -f "$hook_state/stop-latch.g1"

  # Even a lineage with nothing configured still gets an effective value (the default: the
  # document next to records). Showing the placeholder as-is would let the successor's handover
  # request fail on "the literal text nobody replaced."
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl" '{"background_tasks":[]}')"
  st_expect_json "still blocks with nothing configured" '.decision == "block"'
  st_expect_contains "carries the default document in --handoff" "--handoff '$records/$REIN_HANDOFF_BASENAME'"
  st_expect_not_contains "never shows the placeholder when a default exists" "<absolute path to the handoff document>"
  rm -f "$hook_state/stop-latch.g1"

  # Only a lineage that explicitly emptied it in config gets no effective value -- shows the
  # placeholder and the replacement caveat (never silently falls back to the default).
  printf 'threshold_notice=10\nthreshold_handover=20\nnotice_cooldown_sec=120\nusage_stale_sec=180\nhandoff_path=\nusage_state_dir=%s\n' \
    "$usage" >"$records/config"
  st_allow_records_config
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl" '{"background_tasks":[]}')"
  st_expect_json "still blocks for a lineage that disabled the document" '.decision == "block"'
  st_expect_contains "a lineage that disabled it shows the placeholder" "--handoff <absolute path to the handoff document>"
  st_expect_contains "the placeholder carries the replacement caveat" \
    "Replace \`<absolute path to the handoff document>\`"
  printf 'threshold_notice=10\nthreshold_handover=20\nnotice_cooldown_sec=120\nusage_stale_sec=180\nusage_state_dir=%s\n' \
    "$usage" >"$records/config"
  st_allow_records_config
  rm -f "$hook_state/stop-latch.g1"

  # Stop in a subagent context also stays silent (a child's stop never pushes the parent to hand
  # over).
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl" '{"agent_id":"a-9"}')"
  st_expect_silent "Stop in a subagent context stays silent"

  # The children ledger. **These two events always carry an agent_id**, and there it names the
  # child being recorded rather than saying the call came from inside one -- so they are exempt
  # from the silence gate every other event obeys (the case just above pins the other side of
  # that: the gate still applies to Stop). Wired up without the exemption, both would go silent
  # the instant they were registered and the ledger would stay empty forever, so **every case
  # below fails on a run without it.**
  st_hook subagent-start "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl" \
    '{"agent_id":"a-1","agent_type":"Explore"}')"
  st_expect_silent "SubagentStart emits nothing"
  st_expect_true "SubagentStart records the running child" test -f "$children/sess-stop.a-1"
  st_expect_true "the entry names the child's kind" \
    test "$(sed -n 1p "$children/sess-stop.a-1" 2>/dev/null)" = "Explore"
  st_expect_true "the entry carries the moment it was registered" \
    test "$(sed -n 2p "$children/sess-stop.a-1" 2>/dev/null)" -ge "$hook_now_before"
  # The record's location is carried because the reader (`rein request`) gets no payload and has
  # no other way to reach it -- it needs it to apply the same expiry cutoff.
  st_expect_true "the entry carries where that child's own record lives" \
    test "$(sed -n 3p "$children/sess-stop.a-1" 2>/dev/null)" = "$transcripts/sess-stop/subagents/agent-a-1.jsonl"
  # Siblings each get their own entry -- one shared name would have the first child to finish
  # erase the record of every sibling still running.
  st_hook subagent-start "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl" \
    '{"agent_id":"a-2","agent_type":"Plan"}')"
  st_expect_true "a sibling child gets its own entry" test -f "$children/sess-stop.a-2"
  # The ledger is partitioned by the **parent's** session_id, which is what makes leftovers inert.
  st_hook subagent-start "$(rein_st_hook_payload sess-other "$proj" "$transcripts/sess-other.jsonl" \
    '{"agent_id":"a-1","agent_type":"Explore"}')"
  st_expect_true "another session's child is a separate entry" test -f "$children/sess-other.a-1"
  st_hook subagent-stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl" \
    '{"agent_id":"a-1","agent_type":"Explore"}')"
  st_expect_silent "SubagentStop emits nothing"
  st_expect_true "SubagentStop removes that child's entry" test ! -e "$children/sess-stop.a-1"
  st_expect_true "SubagentStop leaves a sibling alone" test -f "$children/sess-stop.a-2"
  st_expect_true "SubagentStop leaves another session's entry alone" test -f "$children/sess-other.a-1"
  # Stopping something already gone is not an anomaly (a stop can arrive for a child this
  # lineage never recorded -- a session started before the registration landed).
  st_hook subagent-stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl" \
    '{"agent_id":"never-recorded"}')"
  st_expect_silent "SubagentStop for an entry that isn't there passes through"
  # A payload with no agent_id fails loud rather than falling back to a shared name.
  st_hook subagent-start "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl" \
    '{"agent_type":"Explore"}')"
  if st_expect_status "SubagentStart with no agent_id fails loud" 1; then
    st_expect_err_contains "the reason names the missing agent_id" "has no agent_id"
  fi
  # agent_id is expanded into a filename, so it goes through the same shape check session_id
  # does -- a path separator would let the entry land outside the ledger.
  st_hook subagent-start "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl" \
    '{"agent_id":"../escape","agent_type":"Explore"}')"
  if st_expect_status "SubagentStart rejects an agent_id shaped like a path" 1; then
    st_expect_err_contains "the reason names the shape" "cannot contain a path separator"
  fi
  st_expect_true "nothing is written outside the ledger" test ! -e "$runtime/escape"
  rm -f "$children/sess-stop.a-2" "$children/sess-other.a-1"

  # UserPromptSubmit: canceling a handover.
  # (a) A turn with no handover request out (the vast majority of turns where the user speaks
  #     up) passes through silently. Placing the marker here would make the watcher's next
  #     handover disappear on "a cancellation nobody ever placed."
  rm -f "$handover_cancel"
  st_hook user-prompt-submit "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl")"
  st_expect_silent "an unsubmitted UserPromptSubmit stays silent"
  st_expect_true "never places the cancel marker when unsubmitted" test ! -e "$handover_cancel"
  # A no-op pass still leaves behind the fact that it "ran" (an anomaly in the registration not
  # working can't be judged from a log's line count).
  st_expect_true "leaves UserPromptSubmit's last firing" test -f "$health/last-seen.UserPromptSubmit"

  # (b) Even when submitted, if the pointer doesn't name this session, it passes through
  #     silently (the handover the watcher is waiting on isn't this session's).
  rein_st_write_marker "$marker" "sess-stop" "$(rein_iso_now)" "$tmp/handoff.md" "$proj"
  rein_st_write_pointer "$pointer" "sess-other" "other" "$proj" 1
  st_hook user-prompt-submit "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl")"
  st_expect_silent "stays silent when the pointer does not name this session"
  st_expect_true "never places the marker when the pointer does not name this session" test ! -e "$handover_cancel"
  rein_st_write_pointer "$pointer" "sess-stop" "current" "$proj" 1

  # (c) Submitted, and the pointer names this session -- places the cancel marker. There is no
  #     output since the stop is not blocked, but it is a firing, so one line lands in each of
  #     the fire log and the lineage log.
  before="$(st_log_lines "$fire_log")"
  log_before="$(st_log_lines "$hook_log")"
  st_hook user-prompt-submit "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl")"
  st_expect_silent "a cancellation turn also emits no output"
  st_expect_true "places the cancel marker" test -f "$handover_cancel"
  st_expect_true "the cancel marker's contents are this session's own session_id" \
    test "$(cat "$handover_cancel" 2>/dev/null)" = "sess-stop"
  st_expect_true "leaves the cancellation in the fire log" \
    test "$(st_log_lines "$fire_log")" -eq "$((before + 1))"
  st_expect_true "the fire log's reason is a cancellation" \
    test "$(jq -s -r '[ .[] | select(.reason == "handover-cancel") ] | length' "$fire_log")" -ge 1
  st_expect_true "leaves the cancellation in the lineage log" \
    test "$(st_log_lines "$hook_log")" -eq "$((log_before + 1))"
  st_expect_true "the lineage log's event identifies it as a cancellation" \
    test "$(jq -r 'select(.event == "handover_cancel_requested") | .event' "$hook_log" | head -1)" = "handover_cancel_requested"
  # **The generation latch is left untouched** (rein never pushes for the canceled generation
  # again on its own).
  st_expect_true "a cancellation never consumes the generation latch" test ! -e "$hook_state/stop-latch.g1"

  # (d) If the marker is already this session's own, **neither the write nor a record is
  #     emitted**. Folding only the write would let a lineage where the watcher died while still
  #     submitted, still talking, grow two logs per prompt and let the fire log balloon.
  touch -t 200001010000 "$handover_cancel"
  mark_mtime="$(rein_mtime "$handover_cancel")"
  before="$(st_log_lines "$fire_log")"
  log_before="$(st_log_lines "$hook_log")"
  st_hook user-prompt-submit "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl")"
  st_expect_silent "UserPromptSubmit stays silent on a turn where the marker already exists too"
  st_expect_true "never rewrites this session's own cancel marker" \
    test "$(rein_mtime "$handover_cancel")" = "$mark_mtime"
  st_expect_true "a turn with the marker already present never grows the fire log" \
    test "$(st_log_lines "$fire_log")" -eq "$before"
  st_expect_true "a turn with the marker already present never grows the lineage log" \
    test "$(st_log_lines "$hook_log")" -eq "$log_before"

  # (d2) A lineage with no waiting step (cap 0) gets neither the marker nor a record -- since the
  #      watcher has no step reading a cancellation to begin with, the record alone must never
  #      claim "a cancellation was requested."
  rm -f "$handover_cancel"
  before="$(st_log_lines "$fire_log")"
  log_before="$(st_log_lines "$hook_log")"
  ST_ENV=("${ST_ENV_MANAGED[@]}" "REIN_FINAL_OUTPUT_TIMEOUT_SEC=0")
  st_hook user-prompt-submit "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl")"
  ST_ENV=("${ST_ENV_MANAGED[@]}")
  st_expect_silent "UserPromptSubmit with cap 0 stays silent"
  st_expect_true "never places the cancel marker with cap 0" test ! -e "$handover_cancel"
  st_expect_true "never leaves anything in the fire log with cap 0" \
    test "$(st_log_lines "$fire_log")" -eq "$before"
  st_expect_true "never leaves anything in the lineage log with cap 0" \
    test "$(st_log_lines "$hook_log")" -eq "$log_before"

  # (e) Does nothing in a subagent context (a child's prompt never cancels the parent's
  #     handover).
  rm -f "$handover_cancel"
  st_hook user-prompt-submit \
    "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl" '{"agent_id":"a-9"}')"
  st_expect_silent "UserPromptSubmit in a subagent context stays silent"
  st_expect_true "never places the cancel marker in a subagent context" test ! -e "$handover_cancel"
  rm -f "$marker" "$handover_cancel"

  # SessionStart.
  # PATH is **built specifically for this case** (never left to the surrounding PATH). Leaving
  # it would mean a machine that already has rein installed only ever runs the installed branch,
  # letting a regression that drops the not-installed message entirely, or one that inverts the
  # condition, pass green either way.
  # The not-installed side uses a PATH with any directory that resolves `rein` removed; the
  # installed side puts a fixture bin ahead of it -- pinning both branches.
  sess_start_bin="$tmp/sess-start-bin"
  mkdir -p "$sess_start_bin"
  # The real command is never actually run (SessionStart only resolves its location via
  # `command -v`). If it ever were run, that alone would be a regression, so this is set up to
  # fail loud with a reason rather than silently return 0.
  printf '#!/usr/bin/env bash\nprintf "fixture rein was executed\\n" >&2\nexit 97\n' \
    >"$sess_start_bin/rein"
  chmod +x "$sess_start_bin/rein"
  sess_start_path_bare="$(rein_st_path_without_cmd rein)"

  rein_st_write_usage "$usage" sess-start 12
  ST_ENV=("${ST_ENV_MANAGED[@]}" "PATH=$sess_start_bin:$sess_start_path_bare")
  st_hook session-start "$(rein_st_hook_payload sess-start "$proj" "$transcripts/sess-start.jsonl")"
  if st_expect_status "SessionStart exits 0" 0; then
    st_expect_contains "prints the usage-lookup line" "$usage/sess-start.json"
    st_expect_contains "prints the lineage's generation" "Lineage: generation 1"
    # An installed machine prints **the real command's absolute path** (merely saying it exists
    # would not name which command actually runs the handover request).
    st_expect_contains "prints the real absolute path once installed" \
      "[rein] Command location: $sess_start_bin/rein"
    st_expect_not_contains "never shows the not-installed message once installed" "rein is not on PATH"
  fi
  st_expect_true "SessionStart never touches the advisory marker" test ! -e "$hook_state/sess-start.notice"
  st_expect_true "leaves SessionStart's firing in health state" test -f "$health/last-seen.SessionStart"

  # A machine with no install: makes it clear on the spot that the handover-request command
  # can't be run.
  ST_ENV=("${ST_ENV_MANAGED[@]}" "PATH=$sess_start_path_bare")
  st_hook session-start "$(rein_st_hook_payload sess-start "$proj" "$transcripts/sess-start.jsonl")"
  if st_expect_status "SessionStart still exits 0 with no install" 0; then
    st_expect_contains "says the command cannot be run with no install" \
      "[rein] rein is not on PATH (the handover-request command cannot be run; see rein doctor for install instructions)" # lineage-cmd-exempt: needle pinning the message shown exactly when rein is not on PATH (a line that can never be pasted and run)
    st_expect_not_contains "never shows the command's location with no install" "[rein] Command location:"
    # This is advisory (fail-open), not a stop -- the rest of the message is still printed in
    # full on the same turn.
    st_expect_contains "still prints the usage-lookup line with no install" "$usage/sess-start.json"
  fi
  ST_ENV=("${ST_ENV_MANAGED[@]}")
  # A project with no lineage never prints the lineage line (never rings for a project not using
  # rein).
  plain_proj="$tmp/plain"
  plain_runtime="$tmp/plain-runtime"
  mkdir -p "$plain_proj" "$plain_runtime"
  printf '%s\n' "$plain_proj" >"$plain_runtime/$REIN_OWNER_BASENAME"
  rein_ensure_runtime_token "$plain_runtime" ||
    st_fail "the no-lineage fixture can hold a lineage token" "$REIN_RUNTIME_ERROR"
  plain_token="$REIN_RUNTIME_TOKEN"
  ST_ENV=("${ST_ENV_BASE[@]}"
    "REIN_USAGE_STATE_DIR=$usage"
    "${REIN_MANAGED_ENV_NAME}=1"
    "${REIN_MANAGED_CWD_ENV_NAME}=$plain_proj"
    "${REIN_MANAGED_RUNTIME_ENV_NAME}=$plain_runtime"
    "${REIN_MANAGED_CONFIG_ENV_NAME}=$tmp/user-config"
    "${REIN_MANAGED_RECORDS_ENV_NAME}=$plain_proj/$REIN_RECORDS_DIRNAME"
    "${REIN_MANAGED_TOKEN_ENV_NAME}=$plain_token"
  )
  st_hook session-start "$(rein_st_hook_payload sess-start "$plain_proj" "$transcripts/sess-start.jsonl")"
  st_expect_not_contains "never prints the lineage line with no lineage" "Lineage: generation"
  # The temporary settings created for launch are cleaned up by the launched session's own
  # SessionStart.
  printf '{}\n' >"$plain_runtime/${REIN_MANAGED_SETTINGS_PREFIX}test.json"
  ST_ENV+=("${REIN_MANAGED_SETTINGS_ENV_NAME}=$plain_runtime/${REIN_MANAGED_SETTINGS_PREFIX}test.json")
  st_hook session-start "$(rein_st_hook_payload sess-start "$plain_proj" "$transcripts/sess-start.jsonl")"
  st_expect_true "cleans up the temporary launch settings" \
    test ! -e "$plain_runtime/${REIN_MANAGED_SETTINGS_PREFIX}test.json"
  # A file outside the location, or with a different prefix, is never removed (only something
  # rein itself created may be removed).
  printf '{}\n' >"$tmp/not-managed-settings.json"
  ST_ENV=("${ST_ENV[@]:0:${#ST_ENV[@]}-1}")
  ST_ENV+=("${REIN_MANAGED_SETTINGS_ENV_NAME}=$tmp/not-managed-settings.json")
  st_hook session-start "$(rein_st_hook_payload sess-start "$plain_proj" "$transcripts/sess-start.jsonl")"
  st_expect_true "never removes a file outside the lineage" test -f "$tmp/not-managed-settings.json"
  # A matching prefix but a path that escapes the location via `..` (a prefix-match glob also
  # matches `/`, letting this through -- which would delete a regular file outside the
  # location). The intermediate element is made to actually exist -- never a check that would
  # pass on an unresolvable path.
  printf '{}\n' >"$tmp/escaped-settings.json"
  mkdir -p "$plain_runtime/${REIN_MANAGED_SETTINGS_PREFIX}dir"
  ST_ENV=("${ST_ENV[@]:0:${#ST_ENV[@]}-1}")
  ST_ENV+=("${REIN_MANAGED_SETTINGS_ENV_NAME}=$plain_runtime/${REIN_MANAGED_SETTINGS_PREFIX}dir/../../escaped-settings.json")
  st_hook session-start "$(rein_st_hook_payload sess-start "$plain_proj" "$transcripts/sess-start.jsonl")"
  st_expect_true "never removes a path that escapes the location via .." test -f "$tmp/escaped-settings.json"
  rmdir "$plain_runtime/${REIN_MANAGED_SETTINGS_PREFIX}dir"
  ST_ENV=("${ST_ENV_MANAGED[@]}")
  # A lineage that explicitly disabled the usage location fails loud (silently falling back to a
  # default would read a different location entirely). Passing empty at the environment-variable
  # layer means the setting is explicitly disabled at that layer (distinct from unset).
  ST_ENV+=("REIN_USAGE_STATE_DIR=")
  st_hook post-tool-batch "$(rein_st_hook_payload sess-a "$proj" "$transcripts/sess-a.jsonl")"
  if st_expect_status "rejects a disabled usage location" 1; then
    st_expect_err_contains "names the disabled field" "usage_state_dir"
  fi
  ST_ENV=("${ST_ENV[@]:0:${#ST_ENV[@]}-1}")

  # An unapproved project config: how the passive context handles it.
  #
  # A `<cwd>/.rein/config` bundled by a cloned repo **has no effect in any context** until
  # approved. Hooks run in a passive context, so this never fails; it proceeds without applying
  # the project layer -- meaning the advisory threshold here is decided up through the user layer
  # (the default 30%), so it never rings even past the project's own 10%. Only the usage location
  # is pinned at the environment layer, specifically to isolate the threshold difference alone
  # (if the location also fell back to a default, the "state missing" injection would mix in and
  # obscure what's actually being measured).
  ST_ENV=("${ST_ENV_MANAGED[@]}" "REIN_USAGE_STATE_DIR=$usage")
  rein_st_write_usage "$usage" sess-unallowed 12
  printf '# changing the content drops the approval (approval is checked by a content hash)\nthreshold_notice=10\nthreshold_handover=20\nnotice_cooldown_sec=120\nusage_stale_sec=180\nusage_state_dir=%s\n' \
    "$usage" >"$records/config"
  st_hook post-tool-batch "$(rein_st_hook_payload sess-unallowed "$proj" "$transcripts/sess-unallowed.jsonl")"
  if st_expect_status "an unapproved project config never breaks the session" 0; then
    st_expect_err_contains "prints to stderr that it was not applied" "the project settings are not applied"
    st_expect_true "never rings on an unapproved project config's threshold" test -z "$ST_OUT"
  fi
  # SessionStart shows this to the user directly, once (stderr is never visible in the session).
  st_hook session-start "$(rein_st_hook_payload sess-unallowed "$proj" "$transcripts/sess-unallowed.jsonl")"
  st_expect_contains "SessionStart also tells the user about the unapproved config" "the project settings are not applied"
  # The decision message is checked as **the full literal text**. A managed session gets the
  # config's location via the marker, so it's named with `--config` (the `config allow` log
  # sits next to this file, so a one-liner with the naming dropped would approve it in the
  # user's own default log, leaving this lineage unapproved).
  st_expect_contains "the unapproved message names the lineage" \
    "to review the content and allow it, run $(rein_shell_quote "$REIN_BIN") --config $(rein_shell_quote "$tmp/user-config") --cwd $(rein_shell_quote "$proj") config allow; to decide against applying it, run $(rein_shell_quote "$REIN_BIN") --config $(rein_shell_quote "$tmp/user-config") --cwd $(rein_shell_quote "$proj") config deny"
  st_expect_not_contains "never shows a one-liner with the lineage naming dropped" "$(rein_shell_quote "$REIN_BIN") --cwd"
  # A setting the user has decided not to apply is **silently** excluded from the layers (never
  # rings every time for the very person who made that decision).
  rein_config_decision_record deny "$records/config" ||
    st_fail "can deny the test fixture" "$REIN_PROJECT_ALLOW_ERROR"
  rein_st_write_usage "$usage" sess-denied 12
  st_hook post-tool-batch "$(rein_st_hook_payload sess-denied "$proj" "$transcripts/sess-denied.jsonl")"
  if st_expect_status "a denied config never breaks the session either" 0; then
    st_expect_silent "a denied config rings nothing at all"
  fi
  st_hook session-start "$(rein_st_hook_payload sess-denied "$proj" "$transcripts/sess-denied.jsonl")"
  st_expect_not_contains "SessionStart stays quiet once denied too" "the project settings are not applied"
  # The counterpart on the "let it through" side: the same content still takes effect once
  # approved.
  st_allow_records_config
  st_hook post-tool-batch "$(rein_st_hook_payload sess-unallowed "$proj" "$transcripts/sess-unallowed.jsonl")"
  st_expect_contains "once approved, rings at the project config's threshold" "10%"
  st_hook session-start "$(rein_st_hook_payload sess-unallowed "$proj" "$transcripts/sess-unallowed.jsonl")"
  st_expect_not_contains "SessionStart stays quiet once approved" "the project settings are not applied"
  rm -f "$hook_state"/sess-unallowed.*
  ST_ENV=("${ST_ENV_MANAGED[@]}")

  # Two lineages sharing one cwd: the default root and a `--root`.
  #
  # Running two lineages side by side on the same working tree (e.g. running backend / frontend
  # in separate sessions) requires both records and config to stay separated per lineage. Since
  # **the managed marker carries the entire lineage context**, this varies only the location for
  # the same cwd and payload, pinning both that **neither writes into the other's records** and
  # that **each one's own config takes effect**.
  # Config taking effect is checked by placing `handoff_path` only on the rooted side and reading
  # the document path carried in the handover-request command -- project config is shared between
  # the two lineages, so only the user scope can actually differ between them.
  local root2 runtime2 records2 user_config2 key2 hook_log2 before2
  key2="$(rein_cwd_key "$proj")"
  root2="$tmp/root2"
  runtime2="$root2/state/rein/$key2"
  records2="$root2/records/rein/$key2"
  user_config2="$root2/config/rein/config"
  hook_log2="$records2/$REIN_HOOK_LOG_BASENAME"
  mkdir -p "$runtime2" "$records2" "$root2/config/rein"
  printf '%s\n' "$proj" >"$runtime2/$REIN_OWNER_BASENAME"
  rein_ensure_runtime_token "$runtime2" ||
    st_fail "the rooted lineage fixture can hold a lineage token" "$REIN_RUNTIME_ERROR"
  runtime2_token="$REIN_RUNTIME_TOKEN"
  printf 'handoff_path=%s\n' "$tmp/handoff.md" >"$user_config2"
  # Project config is shared between the two lineages, but the approval record sits next to the
  # user config -- required per lineage.
  REIN_CONFIG_USER_FILE="$user_config2"
  st_allow_records_config
  REIN_CONFIG_USER_FILE="$tmp/user-config"
  rein_st_write_pointer "$records2/$REIN_POINTER_BASENAME" "sess-root" "current" "$proj" 1
  rein_st_write_usage "$usage" sess-root 25
  rm -f "$hook_state/stop-latch.g1"
  ST_ENV=("${ST_ENV_BASE[@]}"
    "${REIN_MANAGED_ENV_NAME}=1"
    "${REIN_MANAGED_CWD_ENV_NAME}=$proj"
    "${REIN_MANAGED_RUNTIME_ENV_NAME}=$runtime2"
    "${REIN_MANAGED_CONFIG_ENV_NAME}=$user_config2"
    "${REIN_MANAGED_RECORDS_ENV_NAME}=$records2"
    "${REIN_MANAGED_TOKEN_ENV_NAME}=$runtime2_token"
  )
  before="$(st_log_lines "$hook_log")"
  st_hook stop "$(rein_st_hook_payload sess-root "$proj" "$transcripts/sess-root.jsonl" '{"background_tasks":[]}')"
  st_expect_json "still blocks the stop for a lineage rooted elsewhere" '.decision == "block"'
  st_expect_contains "the rooted lineage's own user config takes effect" "--handoff '$tmp/handoff.md'"
  # The message's one-liner points at **this lineage**. Without naming it explicitly for a
  # rooted lineage, a line pasted inside the session would resolve the default location instead
  # -- the request would fail, and a snooze would show success while never taking effect for even
  # a second. With `--runtime-dir`, the records location reverts to `<cwd>/.rein/`, so this has
  # to be `--root` (this also confirms neither of the two shows up together).
  st_expect_contains "a rooted lineage names the root in its message" \
    "$(rein_shell_quote "$REIN_BIN") --root '$root2' --cwd '$proj' request --session-id sess-root"
  st_expect_contains "the snooze one-liner also names the root" \
    "$(rein_shell_quote "$REIN_BIN") --root '$root2' --cwd '$proj' snooze 30m"
  st_expect_not_contains "never adds a location flag on top for a rooted lineage" "--runtime-dir"
  st_expect_true "the rooted lineage's log is written to the rooted side" test -s "$hook_log2"
  st_expect_true "the rooted lineage's latch is placed on the rooted side" \
    test -f "$runtime2/$REIN_HOOK_STATE_DIRNAME/stop-latch.g1"
  st_expect_true "never grows the default lineage's log" \
    test "$(st_log_lines "$hook_log")" -eq "$before"
  st_expect_true "never consumes the default lineage's latch" test ! -e "$hook_state/stop-latch.g1"

  # The reverse direction (running the default lineage never writes to the rooted side either).
  # Without checking this, an implementation where only one side is correctly separated (with
  # the other writing to both) would pass.
  ST_ENV=("${ST_ENV_MANAGED[@]}")
  rein_st_write_usage "$usage" sess-stop 25
  before="$(st_log_lines "$hook_log")"
  before2="$(st_log_lines "$hook_log2")"
  st_hook stop "$(rein_st_hook_payload sess-stop "$proj" "$transcripts/sess-stop.jsonl" '{"background_tasks":[]}')"
  st_expect_json "still blocks the stop for the default lineage" '.decision == "block"'
  st_expect_not_contains "the default lineage never reads the rooted config" "$tmp/handoff.md"
  st_expect_contains "the default lineage points at its own records" "--handoff '$records/$REIN_HANDOFF_BASENAME'"
  st_expect_true "only the default lineage's log grows" \
    test "$(st_log_lines "$hook_log")" -eq "$((before + 1))"
  st_expect_true "the rooted lineage's log never grows" \
    test "$(st_log_lines "$hook_log2")" -eq "$before2"
  rm -f "$hook_state/stop-latch.g1"

  # A `--root` lineage with no handoff_path configured: the default resolution.
  #
  # Both lineages above set `handoff_path` on the rooted side, so neither exercised **the default
  # resolution**. The hook receives the records location via the managed marker, while the root
  # (REIN_RECORDS_ROOT) never reaches the environment -- so if the default were re-derived from
  # the environment, only the hook would show `<cwd>/.rein/handoff.md`, mismatching the document
  # the handover request, kickoff, and `rein init` all actually look at at the root (pasting the
  # shown command would then fail with "does not exist"). **The match is confirmed by actually
  # running both sides**, not by copying an expected value -- writing it out by hand would still
  # pass even if both sides shared the same mistake.
  local root3 runtime3 records3 hook_handoff req_handoff
  root3="$tmp/root3"
  runtime3="$root3/$REIN_ROOT_STATE_RELDIR/$key2"
  records3="$root3/$REIN_ROOT_RECORDS_RELDIR/$key2"
  mkdir -p "$runtime3" "$records3"
  printf '%s\n' "$proj" >"$runtime3/$REIN_OWNER_BASENAME"
  rein_ensure_runtime_token "$runtime3" ||
    st_fail "the default-resolution lineage fixture can hold a lineage token" "$REIN_RUNTIME_ERROR"
  runtime3_token="$REIN_RUNTIME_TOKEN"
  rein_st_write_pointer "$records3/$REIN_POINTER_BASENAME" "sess-root3" "current" "$proj" 1
  rein_st_write_usage "$usage" sess-root3 25
  ST_ENV=("${ST_ENV_BASE[@]}"
    "${REIN_MANAGED_ENV_NAME}=1"
    "${REIN_MANAGED_CWD_ENV_NAME}=$proj"
    "${REIN_MANAGED_RUNTIME_ENV_NAME}=$runtime3"
    "${REIN_MANAGED_CONFIG_ENV_NAME}=$tmp/user-config"
    "${REIN_MANAGED_RECORDS_ENV_NAME}=$records3"
    "${REIN_MANAGED_TOKEN_ENV_NAME}=$runtime3_token"
  )
  st_hook stop "$(rein_st_hook_payload sess-root3 "$proj" "$transcripts/sess-root3.jsonl" '{"background_tasks":[]}')"
  st_expect_json "still blocks the stop for a lineage with the default document" '.decision == "block"'
  hook_handoff="$(printf '%s' "$ST_OUT" | jq -r '.reason // ""' |
    sed -n "s/.*--handoff '\([^']*\)'.*/\1/p")"
  # The handover-request side's resolution is read from the path that appears in its reason
  # text when run with no document in place (the existence check runs right after resolving the
  # location, before writing anything to runtime data).
  req_handoff="$(env "${ST_ENV_BASE[@]}" \
    "REIN_RECORDS_ROOT=$root3/$REIN_ROOT_RECORDS_RELDIR" \
    "$ST_BASH" "$SCRIPTS_DIR/rein-request.sh" --cwd "$proj" --runtime-dir "$runtime3" \
    --session-id sess-root3 2>&1 </dev/null |
    sed -n 's/^.*the handoff document does not exist: //p')"
  st_expect_true "the hook's message and the handover request resolve to the same document" \
    test -n "$hook_handoff" -a "$hook_handoff" = "$req_handoff"
  st_expect_true "that document sits next to records on the rooted side" \
    test "$hook_handoff" = "$records3/$REIN_HANDOFF_BASENAME"
  rm -f "$runtime3/$REIN_HOOK_STATE_DIRNAME/stop-latch.g1"
  ST_ENV=("${ST_ENV_MANAGED[@]}")

  # The fire log (what was emitted) and health state (is it running).
  st_expect_true "leaves firings in rein's own log" test -s "$fire_log"
  if jq -e -s --arg schema "$REIN_HOOK_FIRE_SCHEMA" --arg lineage "$proj" \
    'any(.[]; .schema == $schema and .lineage_cwd == $lineage and (.at // "") != ""
        and (.runner.version // "") != "" and .runner.protocol == "1" and .selftest == true
        and (.session_id // "") != "" and (has("payload") | not))' \
    "$fire_log" >/dev/null 2>&1; then
    st_ok
  else
    st_fail "the fire log's columns match the contract" "$(tail -1 "$fire_log")"
  fi
  if jq -e -s 'any(.[]; .event == "Stop" and .decision == "block")' "$fire_log" >/dev/null 2>&1; then
    st_ok
  else
    st_fail "a stop block also lands in the fire log" "$(tail -3 "$fire_log")"
  fi
  st_expect_true "a no-op pass never piles up in the fire log" \
    test "$(jq -s -r '[ .[] | select(.decision == "silent") ] | length' "$fire_log")" = "0"
  # Once the cap is exceeded, rotates exactly one generation (never grows unbounded).
  before="$(st_log_lines "$fire_log")"
  head -c "$REIN_HOOK_FIRE_LOG_MAX_BYTES" /dev/zero | tr '\0' 'x' >>"$fire_log"
  rein_st_write_usage "$usage" sess-rot 12
  st_hook post-tool-batch "$(rein_st_hook_payload sess-rot "$proj" "$transcripts/sess-rot.jsonl")"
  st_expect_true "rotates once the cap is exceeded" test -f "${fire_log}.1"
  st_expect_true "the log after rotation holds only the new line" test "$(st_log_lines "$fire_log")" -le 2
  rm -f "${fire_log}.1"
  # A rotation lock whose owner is gone is still reclaimed. A hook can be cut off from outside
  # by the registration timeout, so if that happens mid-rotation the lock is left behind --
  # without reclaiming it, this one file, shared across every lineage, would never be rotated
  # again past the cap and would just keep growing (doctor's WARN alone never resolves this).
  head -c "$REIN_HOOK_FIRE_LOG_MAX_BYTES" /dev/zero | tr '\0' 'x' >>"$fire_log"
  mkdir -p "${fire_log}.lock"
  printf '%s\n' 999999 >"${fire_log}.lock/pid"
  rein_st_write_usage "$usage" sess-rot2 12
  st_hook post-tool-batch "$(rein_st_hook_payload sess-rot2 "$proj" "$transcripts/sess-rot2.jsonl")"
  st_expect_true "reclaims a rotation lock whose owner is gone" test -f "${fire_log}.1"
  st_expect_true "leaves no trace of the reclaimed lock" test ! -e "${fire_log}.lock"
  rm -f "${fire_log}.1"
  # The counterpart on the rejecting side: a lock with a live owner is never seized (if two
  # hooks `mv` at the same time, one of their appends lands in the generation that just got
  # rotated away).
  head -c "$REIN_HOOK_FIRE_LOG_MAX_BYTES" /dev/zero | tr '\0' 'x' >>"$fire_log"
  mkdir -p "${fire_log}.lock"
  printf '%s\n' "$$" >"${fire_log}.lock/pid"
  rein_st_write_usage "$usage" sess-rot3 12
  st_hook post-tool-batch "$(rein_st_hook_payload sess-rot3 "$proj" "$transcripts/sess-rot3.jsonl")"
  st_expect_true "never seizes a lock with a live owner" test ! -e "${fire_log}.1"
  rm -rf "${fire_log}.lock"
  : >"$fire_log"
  # Health state keeps a last-seen value per event (doctor reads this).
  st_expect_true "leaves PostToolBatch's last firing" test -f "$health/last-seen.PostToolBatch"
  st_expect_true "leaves Stop's last firing" test -f "$health/last-seen.Stop"
  st_expect_true "the last firing is an epoch" \
    test "$(head -1 "$health/last-seen.Stop")" -gt 0
  # Never writes to the user's own log (~/.claude/state) -- confirms no warning banner appears.
  st_expect_true "never trips the user log's own-location check" \
    test "$(printf '%s' "$ST_ERR" | grep -c 'fire_log')" = "0"

  # A write failure in the record layer **is surfaced** (silently treating it as success would
  # let the record layer and diagnostics die silently at the same time, with doctor reading a
  # missing log line as "the registration isn't working"). The exit code is unchanged -- a
  # record-layer failure never moves the session's stop decision (the non-blocking contract).
  # The log is turned into **a directory** so only the append fails (failing the whole location
  # would let some other write ahead of this line fail first, obscuring the cause).
  rm -f "$fire_log"
  mkdir -p "$fire_log"
  rein_st_write_usage "$usage" sess-unwritable 12
  st_hook post-tool-batch "$(rein_st_hook_payload sess-unwritable "$proj" "$transcripts/sess-unwritable.jsonl")"
  st_expect_status "the hook never fails just because the log cannot be written" 0
  st_expect_err_contains "surfaces that the log cannot be written" "cannot write to the fire log"
  st_expect_contains "still emits the injection itself even when the log cannot be written" "additionalContext"
  rmdir "$fire_log"
  : >"$fire_log"
  # The counterpart on the "let it through" side (a writable location emits not a single line) --
  # tells this apart from a check that "always emits" regardless.
  rein_st_write_usage "$usage" sess-writable 12
  st_hook post-tool-batch "$(rein_st_hook_payload sess-writable "$proj" "$transcripts/sess-writable.jsonl")"
  st_expect_true "a writable location never surfaces this line" \
    test "$(printf '%s' "$ST_ERR" | grep -c 'cannot write to the fire log')" = "0"
  : >"$fire_log"

  # A no-op pass creates no temp file.
  # Points `${TMPDIR}` at an empty directory and runs a no-op pass once, confirming nothing is
  # left behind (a path that sneaks in a use of mktemp would create a temp file on every single
  # tool call).
  mkdir -p "$tmp/tmpdir-probe"
  rein_st_write_usage "$usage" sess-quiet 5
  ST_ENV+=("TMPDIR=$tmp/tmpdir-probe")
  st_hook post-tool-batch "$(rein_st_hook_payload sess-quiet "$proj" "$transcripts/sess-quiet.jsonl")"
  st_expect_silent "a no-op pass is quiet"
  st_expect_true "a no-op pass creates no temp file" \
    test -z "$(ls -A "$tmp/tmpdir-probe")"
  ST_ENV=("${ST_ENV[@]:0:${#ST_ENV[@]}-1}")

  # Confirms this test **never writes outside its own location**. Isolation is grounded by
  # pointing XDG's state and HOME at "names that should never be used" under the temp
  # directory, so anything created there is a sign that "a path fell through to the default
  # location at runtime" (this did happen once -- a run measuring a broken implementation wrote
  # one line into the user's real state -- isolation is never allowed to depend on the
  # correctness of the code under test).
  st_expect_true "no path falls through to the default state location" test ! -e "$tmp/never-state"
  st_expect_true "no path falls through to the default HOME" test ! -e "$tmp/never-home"

  rm -rf "$ST_TMPDIR"
  st_expect_true "leaves no temp directory behind for this test" test ! -e "$ST_TMPDIR"
  ST_TMPDIR=""

  printf '%s: selftest %d pass / %d fail\n' "$SCRIPT_NAME" "$st_pass_count" "$st_fail_count"
  [ "$st_fail_count" -eq 0 ]
}

main() {
  case "${1:-}" in
    --selftest)
      selftest # test-side-scope-exempt: the one line that invokes the selftest entry point (not a production writer)
      return $?
      ;;
    --help | -h)
      usage
      return 0
      ;;
  esac
  hook_run "$@"
}

main "$@"
