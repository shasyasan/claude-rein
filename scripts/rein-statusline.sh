#!/usr/bin/env bash
# The usage writer bundled with rein (registered as Claude Code's `statusLine` command).
#
# Why rein bundles this: the material a handover decision needs is the session's context usage,
# but that value never reaches a hook's stdin, and the model can't observe its own usage either.
# **statusLine's stdin is the only official field that carries it**, so this is made the sole
# writer, landing it at `<usage_state_dir>/<session_id>.json`. In an environment with no writer,
# neither the threshold judgment nor a Stop handover ever fires (hooks only read).
#
# Why the display is always printed in full before writing: so a write failure or delay never
# drags down the user's own screen (the status bar).
#
# Why `context_window` is carried whole: the reader (hooks) only looks at `used_percentage`,
# but thinning the raw data out would make it impossible to read back later from a different
# angle (remaining tokens, window size).
#
# Why this never writes state with no `context_window` in the payload: a record with no usage
# value in it would leave the reader unable to tell a live writer whose value can't be read
# from no writer at all. Rather than silently falling back to a default, this writes nothing,
# prints the reason to stderr, and ends non-zero (fail-loud).
set -uo pipefail

# Normalizes the entry environment. Forces the character set to UTF-8 (bash can't parse
# this file's syntax under a non-UTF-8 multibyte locale) and unsets `CDPATH` (it makes
# `$(cd ... && pwd -P)` print two lines). Placed **before loading the shared library**. The
# canonical explanation lives next to the same two lines in bin/rein.
unset LC_ALL CDPATH
export LC_CTYPE=UTF-8

SCRIPT_NAME="rein-statusline.sh"
# Works out its own location with string operations only (keeps the shared library's load
# path absolute).
REIN_STATUSLINE_PATH="${BASH_SOURCE[0]}"
case "$REIN_STATUSLINE_PATH" in
  /*) ;;
  *) REIN_STATUSLINE_PATH="$PWD/$REIN_STATUSLINE_PATH" ;;
esac
SCRIPTS_DIR="${REIN_STATUSLINE_PATH%/*}"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/rein-config.sh
. "$SCRIPTS_DIR/lib/rein-config.sh"

# The CLI's real path, embedded into the one-line hint. The rationale and how it's cut out
# live next to the same line in scripts/rein-seat.sh.
REIN_BIN="${SCRIPTS_DIR%/*}/$REIN_CLI_RELPATH"

statusline_fail() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2
}

# Pulls the values needed out of the payload with **one jq call** (statusline runs on every
# one of the user's turns, so the number of external commands directly becomes display
# latency). The current time is folded into that same call too -- `date` is never started.
# The 6 lines pulled out are, in order: **the code for why a record couldn't be assembled** /
# session_id / cwd / the model's display name / the integer usage / the record itself to write.
# **The reject code sits on the first line**, because one line carries one value: a value that
# itself contains a newline shifts every line after it into the wrong slot -- a single newline
# in cwd once left only the usage string in the record's slot, and a file that wasn't even
# JSON got placed as `<session_id>.json` (the writer claimed success with exit 0 --
# a fail-loud violation). Since it sits ahead of any user-sourced data, the check itself never
# shifts even when a value does. On rejection, the value slots are also knocked to empty -- a
# shifted fragment is never carried into the display or the record.
# **A field that isn't a string is rejected through the same slot** (never smoothed over with
# `tostring`). A non-string value that fits on one line doesn't shift any line, so it never
# trips the newline check, and `session_id: 0` would land in the record's pathname as `"0"`.
# The reader (hooks) builds the same pathname from the same payload, so if only one side
# rejected on type, the result is either **a record nobody reads** or **fail-loud on only one
# side** -- the judgment is placed here at the same time, in the same shape, as the hook's.
# **Only the fields that actually go into the record are type-checked** (`typed: true` =
# session_id, cwd). `model` goes into neither the pathname nor the record's contents, and has
# no corresponding reader on the hook side -- failing here over its type would mean **a display
# decoration stops the entire record write** (indistinguishable, from the reader's point of
# view, from the writer being absent). The newline check alone still runs on `model` too --
# with one line carrying one value, a newline in any field shifts every slot after it.
# **`//` can't be used to knock a missing value to empty** -- jq's `//` returns its right side
# for both `null` and `false`, so `cwd: false` would turn into `""` (a string) and sail right
# through the type check. `has` combined with `!= null` knocks only "the key is missing / null"
# to empty, letting `false` reach the type check still as `boolean`.
# The record is assembled as one-line JSON (`tojson`) -- the reader reads it as one line so it
# never grabs a write in progress.
# **The condition for assembling a record is that `context_window.used_percentage` matches the
# spec (a number, 0-100, decimals allowed -- docs/spec/usage-state.md)**. Checking type alone
# lets `NaN` and `1e400` sail through as the number type (turning into `null` / `1E+400` under
# `tojson`), breaking the very point of rejecting the string `"20"` at the same gate. Since the
# reader folds this value as a number, a record that's out of range or non-finite would leave
# a writer that is alive but whose value can't be read -- so this fails right here instead.
# The reject code is kept to **alphanumerics only** on the jq side.
STATUSLINE_SESSION_ID=""
STATUSLINE_CWD=""
STATUSLINE_MODEL=""
STATUSLINE_PCT=""
STATUSLINE_RECORD=""
STATUSLINE_REJECT=""
statusline_parse() {
  local input="$1" out
  STATUSLINE_SESSION_ID=""
  STATUSLINE_CWD=""
  STATUSLINE_MODEL=""
  STATUSLINE_PCT=""
  STATUSLINE_RECORD=""
  STATUSLINE_REJECT=""
  out="$(printf '%s' "$input" | jq -r '
    (now | gmtime | strftime("%Y-%m-%dT%H:%M:%SZ")) as $at
    | ([{k: "session_id", typed: true,
         v: (if has("session_id") and .session_id != null then .session_id else "" end)},
        {k: "cwd", typed: true,
         v: (if has("cwd") and .cwd != null then .cwd else "" end)},
        {k: "model", typed: false,
         v: (if (.model | type) == "object" and (.model | has("display_name"))
                and .model.display_name != null
             then .model.display_name else "" end)}]
       | map(.t = (.v | type)) | map(.v = (.v | tostring))) as $f
    | ((($f | map(select(.typed and .t != "string")))[0].k) // "") as $bad_type
    | ((($f | map(select(((.v | index("\n")) != null) or ((.v | index("\r")) != null))))[0].k) // "") as $bad_lf
    | (if $bad_type != "" then "field-type:" + $bad_type
       elif $bad_lf != "" then "field-newline:" + $bad_lf
       else "" end) as $bad
    | (if $bad != "" then $bad
       else ((.context_window? // null) as $cw
         | if $cw == null then "no-context-window"
           elif ($cw | type) != "object" then "context-window-type:" + ($cw | type)
           elif (($cw.used_percentage? // null) == null) then "no-used-percentage"
           elif (($cw.used_percentage | type) != "number") then
             "used-percentage-type:" + ($cw.used_percentage | type)
           elif (($cw.used_percentage | isnan) or ($cw.used_percentage | isinfinite)) then
             "used-percentage-nonfinite"
           elif ($cw.used_percentage < 0 or $cw.used_percentage > 100) then
             "used-percentage-range:" + ($cw.used_percentage | tostring)
           else "" end)
       end) as $reject
    | (if $bad == "" then ($f | map(.v)) else ["", "", ""] end) as $v
    | [ $reject,
        $v[0], $v[1], $v[2],
        (if $reject == "" then (.context_window.used_percentage | floor | tostring) else "" end),
        (if $reject == "" then
          ({ at: $at, session_id: $v[0] }
           + (if $v[1] == "" then {} else { cwd: $v[1] } end)
           + { context_window: .context_window } | tojson)
         else "" end) ]
    | .[]' 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  {
    IFS= read -r STATUSLINE_REJECT
    IFS= read -r STATUSLINE_SESSION_ID
    IFS= read -r STATUSLINE_CWD
    IFS= read -r STATUSLINE_MODEL
    IFS= read -r STATUSLINE_PCT
    IFS= read -r STATUSLINE_RECORD
  } <<EOF
$out
EOF
  return 0
}

# The reason a record couldn't be assembled (code -> one line the user reads). The text goes
# straight into the printf format string.
statusline_reject_reason() {
  case "$STATUSLINE_REJECT" in
    no-context-window)
      printf 'no context_window in the payload (usage cannot be read, so no state will be written)'
      ;;
    context-window-type:*)
      printf 'context_window in the payload is not an object (type %s)' \
        "${STATUSLINE_REJECT#context-window-type:}"
      ;;
    no-used-percentage)
      printf 'context_window in the payload has no used_percentage (usage cannot be read, so no state will be written)'
      ;;
    used-percentage-type:*)
      printf 'context_window.used_percentage in the payload is not a number (type %s; the reader folds it as a number, so a record of this shape is never placed)' \
        "${STATUSLINE_REJECT#used-percentage-type:}"
      ;;
    used-percentage-nonfinite)
      printf 'context_window.used_percentage in the payload is not a finite number (NaN or infinite; the reader folds it as a number, so a record of this shape is never placed)'
      ;;
    used-percentage-range:*)
      printf 'context_window.used_percentage in the payload is outside 0-100 (%s; the spec allows 0-100 with decimals)' \
        "${STATUSLINE_REJECT#used-percentage-range:}"
      ;;
    field-newline:*)
      printf 'field %s in the payload cannot contain a newline (it would break the value boundaries, shifting a later value into the wrong slot)' \
        "${STATUSLINE_REJECT#field-newline:}"
      ;;
    field-type:*)
      printf 'field %s in the payload is not a string (smoothing the type over is the same loss as a shifted value)' \
        "${STATUSLINE_REJECT#field-type:}"
      ;;
    *)
      printf 'cannot assemble a usage record from the payload'
      ;;
  esac
}

# One line for the status bar (kept plain -- just the model's display name and the integer
# usage). No decoration, so that a user already running a different statusline can easily
# judge whether to replace it with this one.
statusline_render() {
  local model="$STATUSLINE_MODEL"
  [ -n "$model" ] || model="?"
  if [ -n "$STATUSLINE_PCT" ]; then
    printf '%s %s%%\n' "$model" "$STATUSLINE_PCT"
  else
    printf '%s\n' "$model"
  fi
}

# Which user-scope config file the location is resolved through. In a session rein launched
# that is **the one the managed marker names** -- the same file the reader (hooks) resolves
# through, which is what makes the writer and the reader see one effective `usage_state_dir`
# (docs/spec/usage-state.md). Re-deriving it from the default user path instead splits the two
# apart for any lineage whose config does not sit there (a lineage relocated with `--root`):
# the writer would place the record at the default location while the reader looked inside the
# lineage's own, and monitoring would read as "there is no writer" while a writer was running
# fine. The marker is the only channel that can carry it -- a background session's processes
# inherit their environment from the shared background service, so REIN_CONFIG_FILE set at
# launch time never reaches them.
# **statusLine's command does receive the `env` block of the settings file the session was
# launched with.** Measured with `claude --bg --name <name> --settings <file>`, which is exactly
# the shape rein launches a primary session in. This is **an observation, not a documented
# guarantee**: the statusLine documentation names only COLUMNS and LINES. Under `claude -p` no
# statusLine runs at all (also measured), so print mode is not a case here.
# The three verdicts, and what each means for a writer that must never break the user's turn:
#   - **no marker at all is the normal state.** statusline is registered once in the user's own
#     settings and runs in every plain `claude` session too, so this resolves exactly as it did
#     before and says nothing. Treating it as a failure would put a line on the status bar's
#     stderr in every session on the machine.
#   - verified: the marker's user-scope config file becomes this process's config file -- the
#     same single assignment the hook makes out of the same verdict.
#   - present but not verified: **the marker is not used.** The default resolution stands, and
#     the reason goes out through the one failure channel this writer already has (one line to
#     stderr). Falling back in silence would let a clone move where the record lands, or make it
#     vanish from the lineage's own location, without anything ever saying so.
statusline_bind_managed_config() {
  local rc
  rein_verify_managed_marker
  rc=$?
  case "$rc" in
    0) REIN_CONFIG_FILE="$REIN_MANAGED_MARKER_CONFIG_FILE" ;;
    2) ;;
    *)
      statusline_fail "the managed marker is not used for this record, falling back to the default config resolution: ${REIN_MANAGED_MARKER_ERROR}"
      ;;
  esac
  return 0
}

# The location is resolved through **the config layer's effective value** (`usage_state_dir`)
# -- the same single resolution the reader (hooks, doctor) goes through. To let the project
# config take effect, the cwd this config resolution targets is the payload's own `cwd`. Only
# when the payload has no `cwd` does this fall back to its own cwd (statusline runs with that
# session's own cwd, so the value comes out the same -- not a silent fallback to a default).
STATUSLINE_STATE_DIR=""
statusline_resolve_dir() {
  local cwd="$STATUSLINE_CWD"
  STATUSLINE_STATE_DIR=""
  case "$cwd" in
    /*) ;;
    *) cwd="$PWD" ;;
  esac
  # The user scope is settled **before the config layer resolves anything** -- the layer reads
  # REIN_CONFIG_FILE at resolution time, so an assignment made afterwards would not take effect
  # until a later call that no longer exists on this path.
  statusline_bind_managed_config
  # statusline is a passive context too -- **an unallowed project config never breaks the
  # user's own turn**. The project layer isn't applied (writing goes to the user-layer
  # location instead), and not applying it goes to stderr.
  REIN_CONFIG_PROJECT_MODE="skip"
  if ! rein_config_prepare "$REIN_BIN" "$cwd"; then
    statusline_fail "$REIN_CONFIG_ERROR"
    return 1
  fi
  # Only sounds off **when there's a notice (i.e. a setting still undecided)**. Sounding off
  # every turn about a setting the user already decided not to apply would turn their own
  # decision into noise.
  if [ -n "$REIN_CONFIG_PROJECT_NOTICE" ]; then
    statusline_fail "$REIN_CONFIG_PROJECT_NOTICE"
  fi
  if ! rein_config_bind STATUSLINE_STATE_DIR usage_state_dir; then
    statusline_fail "$REIN_CONFIG_ERROR"
    return 1
  fi
  if [ -z "$STATUSLINE_STATE_DIR" ]; then
    statusline_fail "the usage location is empty (set config's usage_state_dir)"
    return 1
  fi
  # The gate that only a selftest child hits (a break in isolation dies right here, the moment
  # it happens). **The same predicate, the same role** as hook_prepare in rein-hook.sh and
  # prepare_runtime in lib/cli/base.sh. statusline looks read-heavy but is itself a writer (the
  # sole writer of `<usage_state_dir>/<session_id>.json`), and this function resolves the one
  # and only location involved. The caller (statusline_write) goes straight into `mkdir -p`
  # right after this -- **'stop before writing' only holds at this one position.**
  # The check sits at resolution's exit rather than in the caller, so even if more paths that
  # resolve a location get added, this one spot still covers them.
  # **Not split into stages, because settling the location is itself just one stage** -- neither
  # the runtime directory nor the records are used, and every path before this (interpreting the
  # payload, rendering, checking session_id's shape) writes only to stdout and stderr, never to
  # disk (the watcher needs two of these because its own location resolves in two stages).
  # The gate to fail through is statusline_fail (one line to stderr) -- the rejecting side
  # never even reaches `mkdir -p`.
  if [ -n "${REIN_SELFTEST_NEVER_ROOTS:-}" ] &&
    rein_selftest_never_root_hit "$STATUSLINE_STATE_DIR"; then
    statusline_fail "a selftest child resolved a location it must never touch (isolation is broken): ${REIN_SELFTEST_NEVER_ROOT_HIT}"
    return 1
  fi
  return 0
}

# Writes to a temp file at the same location and swaps it in with a rename, so the reader
# never grabs a write in progress. The temp file's name starts with `.` and does not end with
# `.json`, so that whatever scans the location (doctor's format check, the writer's own
# cleanup) never reads a write in progress as state.
statusline_write() {
  local state tmp
  # A run with broken boundaries or a wrong type is failed **before the value slots are even
  # looked at**. Deferring this would look at an empty session_id (knocked to empty on reject)
  # and say 'no session_id in the payload,' with no way for the user to trace it back to a
  # newline or a type problem.
  case "$STATUSLINE_REJECT" in
    field-newline:* | field-type:*)
      statusline_fail "$(statusline_reject_reason)"
      return 1
      ;;
  esac
  if [ -z "$STATUSLINE_SESSION_ID" ]; then
    statusline_fail "no session_id in the payload (the usage record cannot be tied to a session)"
    return 1
  fi
  # session_id expands into the record's pathname. The judgment goes through one
  # shared-library function -- writing the check for the same risk separately per entry point
  # lets them drift when only one side gets updated (the same one function used by the hook's
  # stdin, `rein request --session-id`, and the watcher's freshness validation).
  if ! rein_session_id_shape_ok "$STATUSLINE_SESSION_ID" "the payload's session_id"; then
    statusline_fail "$REIN_SESSION_ID_ERROR"
    return 1
  fi
  if [ -z "$STATUSLINE_RECORD" ]; then
    statusline_fail "$(statusline_reject_reason)"
    return 1
  fi
  statusline_resolve_dir || return 1
  if ! mkdir -p "$STATUSLINE_STATE_DIR"; then
    statusline_fail "cannot create the usage location: ${STATUSLINE_STATE_DIR}"
    return 1
  fi
  state="$STATUSLINE_STATE_DIR/${STATUSLINE_SESSION_ID}.json"
  # The replacement target's shape is checked **before writing** (goes through the same one
  # predicate the atomic-write writer uses). If the destination is a directory, `mv` moves the
  # temp file inside it and returns 0, so without checking the shape, only the display would
  # come out while the record silently failed -- indistinguishable, from the reader's (hooks')
  # point of view, from the writer being absent.
  if ! rein_dest_shape_ok "$state"; then
    statusline_fail "$REIN_DEST_SHAPE_ERROR"
    return 1
  fi
  tmp="$STATUSLINE_STATE_DIR/.${SCRIPT_NAME}.${STATUSLINE_SESSION_ID}.$$"
  if ! printf '%s\n' "$STATUSLINE_RECORD" >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    statusline_fail "cannot write the usage record: ${tmp}"
    return 1
  fi
  if ! mv "$tmp" "$state" 2>/dev/null; then
    rm -f "$tmp"
    statusline_fail "cannot replace the usage record: ${state}"
    return 1
  fi
  return 0
}

statusline_main() {
  local input=""
  # stdin is drained with a builtin (never starts `cat`). read returns non-zero at EOF, but
  # the value is still populated.
  IFS= read -r -d '' input || :
  if [ -z "$input" ]; then
    statusline_fail "no statusline payload on stdin (register this as statusLine's command)"
    return 1
  fi
  if ! statusline_parse "$input"; then
    statusline_fail "cannot read the statusline payload as JSON"
    return 1
  fi
  statusline_render
  statusline_write || return 1
  return 0
}

# --selftest is the convention for runnable scripts (check.sh's gate runs it for every one).
# Never touches real config or real state -- measures using only a temp directory and an
# isolated config layer.
selftest() {
  local pass=0 fail=0 tmp proj state content lines pct bad_pct good_pct sid nr_proj
  local nr_home nr_roots nr_default_proj
  local mk_proj mk_state mk_runtime mk_token mk_forged_token
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/rein-statusline-selftest.XXXXXX")" || {
    printf '%s: selftest 0 pass / 1 fail\n' "$SCRIPT_NAME"
    return 1
  }
  tmp="$(cd "$tmp" && pwd -P)"
  # shellcheck source-path=SCRIPTDIR
  # shellcheck source=lib/rein-selftest-fixtures.sh
  . "$SCRIPTS_DIR/lib/rein-selftest-fixtures.sh"

  # Defines the pass/fail entry points **before** assembling the isolation env (assembly calls
  # st_fail whenever the guard couldn't arm, so defining it later would turn that into
  # `command not found`, silently swallowing that one result).
  st_ok() {
    pass=$((pass + 1))
  }
  st_fail() {
    fail=$((fail + 1))
    printf '  FAIL %s: %s\n' "$1" "$2"
  }
  # Drops the surrounding REIN_* and stands up only the check's own entry point (assembly stays
  # in one place, the shared fixture).
  rein_st_isolation_env "$tmp/user-config" "$tmp/xdg-config" "$tmp/xdg-state"
  # Per-launch additions (`env` lets a later setting win). An entry point for layering
  # case-specific values on top, while keeping isolation's own assembly in one place.
  ST_EXTRA_ENV=()
  st_run() {
    ST_OUT="$(printf '%s' "$1" | env "${REIN_ST_ENV_ARGS[@]}" ${ST_EXTRA_ENV[@]+"${ST_EXTRA_ENV[@]}"} \
      "$REIN_ST_BASH" "$REIN_STATUSLINE_PATH" 2>&1)"
    ST_STATUS=$?
  }

  # The project config the check places is subject to the allow gate. Recording an allow calls
  # the config layer's own entry point as-is (never adding a second writer of the decision
  # ledger). The ledger sits right next to the user config passed to the launch entry
  # point -- closed inside this one temp directory.
  REIN_CONFIG_USER_FILE="$tmp/user-config"
  st_allow_project_config() {
    rein_config_allow_record "$proj/.rein/config" ||
      st_fail "can allow the check's own fixture" "$REIN_PROJECT_ALLOW_ERROR"
  }

  proj="$tmp/proj"
  mkdir -p "$proj/.rein"
  printf 'usage_state_dir=%s\n' "$tmp/usage" >"$proj/.rein/config"
  st_allow_project_config

  # The accepting side: a payload matching the contract.
  st_run "$(printf '{"session_id":"sess-1","cwd":"%s","model":{"display_name":"TestModel"},"context_window":{"used_percentage":20.4,"context_window_size":1000000,"total_input_tokens":204000}}' "$proj")"
  if [ "$ST_STATUS" -eq 0 ]; then
    st_ok
  else
    st_fail "a payload matching the contract ends with 0" "exit=${ST_STATUS}: ${ST_OUT}"
  fi
  case "$ST_OUT" in
    *"TestModel 20%"*) st_ok ;;
    *) st_fail "shows usage on the status bar" "$ST_OUT" ;;
  esac
  # The location is the project config's effective value (writes to the default location if
  # this never went through the config layer).
  state="$tmp/usage/sess-1.json"
  if [ -f "$state" ]; then
    st_ok
  else
    st_fail "writes to the config layer's effective location" "${state} is missing: $(ls -a "$tmp/usage" 2>&1)"
  fi
  # The shape the reader (hooks) reads: one line of JSON.
  lines="$(awk 'END { print NR + 0 }' "$state" 2>/dev/null)"
  if [ "$lines" = "1" ]; then
    st_ok
  else
    st_fail "state is one line of JSON" "line count=${lines}"
  fi
  # The contract's keys (the reader only looks at .context_window.used_percentage and at).
  pct="$(jq -r '.context_window.used_percentage // empty' "$state" 2>/dev/null)"
  if [ "$pct" = "20.4" ]; then
    st_ok
  else
    st_fail "carries the raw usage without rounding" "used_percentage=${pct}"
  fi
  if [ "$(jq -r '.context_window.context_window_size // empty' "$state" 2>/dev/null)" = "1000000" ] &&
    [ "$(jq -r '.context_window.total_input_tokens // empty' "$state" 2>/dev/null)" = "204000" ]; then
    st_ok
  else
    st_fail "never thins out context_window" "$(cat "$state" 2>/dev/null)"
  fi
  if [ "$(jq -r '.session_id // empty' "$state" 2>/dev/null)" = "sess-1" ] &&
    [ "$(jq -r '.cwd // empty' "$state" 2>/dev/null)" = "$proj" ]; then
    st_ok
  else
    st_fail "carries session_id and cwd" "$(cat "$state" 2>/dev/null)"
  fi
  # The time follows the contract's format (UTC, second precision) -- the reader's freshness
  # validation only accepts this one format.
  content="$(jq -r '.at // empty' "$state" 2>/dev/null)"
  if rein_iso_to_epoch "$content" >/dev/null; then
    st_ok
  else
    st_fail "at follows the contract's time format" "at=${content}"
  fi
  # Never leaves a write's temp file behind (leaving one would let whatever scans the location
  # pick up a record still in progress).
  if [ "$(find "$tmp/usage" -type f ! -name '*.json' 2>/dev/null | wc -l | tr -d ' ')" = "0" ]; then
    st_ok
  else
    st_fail "leaves no temp file behind" "$(find "$tmp/usage" -type f ! -name '*.json' 2>/dev/null)"
  fi

  # The rejecting side: a payload with no context_window fails with a reason and no state
  # written.
  st_run "$(printf '{"session_id":"sess-2","cwd":"%s","model":{"display_name":"TestModel"}}' "$proj")"
  if [ "$ST_STATUS" -ne 0 ]; then
    st_ok
  else
    st_fail "fails on a payload with no context_window" "exit=${ST_STATUS}: ${ST_OUT}"
  fi
  case "$ST_OUT" in
    *"no context_window in the payload"*) st_ok ;;
    *) st_fail "gives a reason for the missing context_window" "$ST_OUT" ;;
  esac
  if [ ! -e "$tmp/usage/sess-2.json" ]; then
    st_ok
  else
    st_fail "writes no state with no context_window" "$(cat "$tmp/usage/sess-2.json" 2>/dev/null)"
  fi
  # Still prints the display in full (a writer failure never drags down the user's own
  # screen).
  case "$ST_OUT" in
    *"TestModel"*) st_ok ;;
    *) st_fail "shows the status bar even on a run that can't write" "$ST_OUT" ;;
  esac

  # context_window is there but has no usage. A gate that only checks whether the key exists
  # would let this through and place a record the reader can't get a value out of.
  st_run "$(printf '{"session_id":"sess-5","cwd":"%s","model":{"display_name":"TestModel"},"context_window":{"context_window_size":1000000}}' "$proj")"
  if [ "$ST_STATUS" -ne 0 ]; then
    st_ok
  else
    st_fail "fails on a payload with no usage" "exit=${ST_STATUS}: ${ST_OUT}"
  fi
  case "$ST_OUT" in
    *"has no used_percentage"*) st_ok ;;
    *) st_fail "gives a reason for the missing usage" "$ST_OUT" ;;
  esac
  if [ ! -e "$tmp/usage/sess-5.json" ]; then
    st_ok
  else
    st_fail "writes no state with no usage" "$(cat "$tmp/usage/sess-5.json" 2>/dev/null)"
  fi
  # Usage that is **not a number** (the string "20"). The reader folds it as a number, so
  # letting it through would place a state whose writer is alive but whose value can't be
  # read (the spec is a number, 0-100).
  st_run "$(printf '{"session_id":"sess-6","cwd":"%s","model":{"display_name":"TestModel"},"context_window":{"used_percentage":"20"}}' "$proj")"
  if [ "$ST_STATUS" -ne 0 ]; then
    st_ok
  else
    st_fail "fails on a string usage" "exit=${ST_STATUS}: ${ST_OUT}"
  fi
  case "$ST_OUT" in
    *"used_percentage in the payload is not a number (type string"*) st_ok ;;
    *) st_fail "gives a reason for usage's type" "$ST_OUT" ;;
  esac
  if [ ! -e "$tmp/usage/sess-6.json" ]; then
    st_ok
  else
    st_fail "writes no state with a non-number usage" "$(cat "$tmp/usage/sess-6.json" 2>/dev/null)"
  fi
  # A context_window that isn't an object also fails the same way (the record's own container
  # is the wrong shape).
  st_run "$(printf '{"session_id":"sess-7","cwd":"%s","context_window":42}' "$proj")"
  if [ "$ST_STATUS" -ne 0 ] && [ ! -e "$tmp/usage/sess-7.json" ]; then
    st_ok
  else
    st_fail "writes nothing when context_window isn't an object" "exit=${ST_STATUS}: ${ST_OUT}"
  fi

  # With no session_id, the record can't be tied to a session.
  st_run "$(printf '{"cwd":"%s","context_window":{"used_percentage":10}}' "$proj")"
  if [ "$ST_STATUS" -ne 0 ]; then
    st_ok
  else
    st_fail "fails on a payload with no session_id" "exit=${ST_STATUS}: ${ST_OUT}"
  fi
  case "$ST_OUT" in
    *"no session_id in the payload"*) st_ok ;;
    *) st_fail "gives a reason for the missing session_id" "$ST_OUT" ;;
  esac
  # A session_id containing a path separator can point outside the location, so it's never
  # accepted.
  st_run "$(printf '{"session_id":"../escape","cwd":"%s","context_window":{"used_percentage":10}}' "$proj")"
  if [ "$ST_STATUS" -ne 0 ]; then
    st_ok
  else
    st_fail "fails on a session_id with a path separator" "exit=${ST_STATUS}: ${ST_OUT}"
  fi
  if [ ! -e "$tmp/escape.json" ]; then
    st_ok
  else
    st_fail "never writes outside the location" "$tmp/escape.json got created"
  fi
  # A session_id with whitespace fails at the same gate (the judgment goes through one
  # shared-library function -- accepting only the same shape as the hook's stdin, `rein
  # request`, and the watcher's R3).
  st_run "$(printf '{"session_id":"sess a","cwd":"%s","context_window":{"used_percentage":10}}' "$proj")"
  if [ "$ST_STATUS" -ne 0 ]; then
    st_ok
  else
    st_fail "fails on a session_id with whitespace" "exit=${ST_STATUS}: ${ST_OUT}"
  fi
  case "$ST_OUT" in
    *"cannot contain a path separator or whitespace"*) st_ok ;;
    *) st_fail "gives a reason for session_id's shape" "$ST_OUT" ;;
  esac

  # A newline inside a value shifts the one jq call's output lines, and **a later value lands
  # in the wrong slot**. A single newline in cwd once left only the usage string in the record's
  # slot, and **a file that wasn't even JSON** got placed as `<session_id>.json` (the reader
  # can't read it, and the writer claimed success with exit 0 -- a fail-loud violation). Since
  # rejection is decided **ahead of any user-sourced data**, the check itself never shifts even
  # when a value does.
  st_run "$(jq -nc --arg sid sess-lfcwd --arg cwd "$(printf '%s\nSUFFIX' "$proj")" \
    '{session_id: $sid, cwd: $cwd, model: {display_name: "TestModel"},
      context_window: {used_percentage: 20.4}}')"
  if [ "$ST_STATUS" -ne 0 ]; then
    st_ok
  else
    st_fail "fails on a cwd containing a newline" "exit=${ST_STATUS}: ${ST_OUT}"
  fi
  if [ ! -e "$tmp/usage/sess-lfcwd.json" ]; then
    st_ok
  else
    st_fail "writes no record on a run shifted by a newline" "$(cat "$tmp/usage/sess-lfcwd.json" 2>/dev/null)"
  fi
  # The same holds for a newline on the session_id side (the filename just becomes the
  # fragment before the newline, so it doesn't land outside the location, but the record's
  # content still ends up belonging to the wrong slot).
  st_run "$(jq -nc --arg sid "$(printf 'sess-lfsid\nB')" --arg cwd "$proj" \
    '{session_id: $sid, cwd: $cwd, context_window: {used_percentage: 20.4}}')"
  if [ "$ST_STATUS" -ne 0 ]; then
    st_ok
  else
    st_fail "fails on a session_id containing a newline" "exit=${ST_STATUS}: ${ST_OUT}"
  fi
  if [ ! -e "$tmp/usage/sess-lfsid.json" ]; then
    st_ok
  else
    st_fail "writes no record on a session_id containing a newline" "$(cat "$tmp/usage/sess-lfsid.json" 2>/dev/null)"
  fi

  # **A value that isn't a string** doesn't shift any line, so it never trips the newline check
  # (`session_id: 0` becomes `"0"`). The reader (hooks) rejects the same field on type from the
  # same payload, so smoothing it over and writing here would place **a record nobody reads**
  # (`0.json`) -- this closes it off on the writer and reader sides at the same time.
  st_run "$(jq -nc --arg cwd "$proj" \
    '{session_id: 0, cwd: $cwd, context_window: {used_percentage: 20.4}}')"
  if [ "$ST_STATUS" -ne 0 ]; then
    st_ok
  else
    st_fail "fails on a non-string session_id" "exit=${ST_STATUS}: ${ST_OUT}"
  fi
  if [ ! -e "$tmp/usage/0.json" ]; then
    st_ok
  else
    st_fail "writes no record for a non-string session_id" "$(cat "$tmp/usage/0.json" 2>/dev/null)"
  fi
  case "$ST_OUT" in
    *"session_id in the payload is not a string"*) st_ok ;;
    *) st_fail "names the field in a type-rejection reason" "$ST_OUT" ;;
  esac
  # The cwd side falls into the same slot (it's the value used to resolve the location, so
  # smoothing it over could pull in a different lineage's config).
  st_run "$(jq -nc '{session_id: "sess-objcwd", cwd: {a: 1}, context_window: {used_percentage: 20.4}}')"
  if [ "$ST_STATUS" -ne 0 ] && [ ! -e "$tmp/usage/sess-objcwd.json" ]; then
    st_ok
  else
    st_fail "writes no record for a non-string cwd" \
      "exit=${ST_STATUS}: ${ST_OUT} / $(cat "$tmp/usage/sess-objcwd.json" 2>/dev/null)"
  fi
  # jq's `//` can't tell `false` apart from a missing value (`//` returns its right side for
  # both null and false). Leaving the missing-to-empty logic as `//` would turn `cwd: false`
  # into `""` (a string) that sails right through the type check -- **only this one case would
  # stay green while a hole opened up**.
  st_run "$(jq -nc '{session_id: "sess-falsecwd", cwd: false, context_window: {used_percentage: 20.4}}')"
  if [ "$ST_STATUS" -ne 0 ] && [ ! -e "$tmp/usage/sess-falsecwd.json" ]; then
    st_ok
  else
    st_fail "writes no record for a false cwd" \
      "exit=${ST_STATUS}: ${ST_OUT} / $(cat "$tmp/usage/sess-falsecwd.json" 2>/dev/null)"
  fi
  case "$ST_OUT" in
    *"cwd in the payload is not a string"*) st_ok ;;
    *) st_fail "fails a false cwd on its type" "$ST_OUT" ;;
  esac

  # **`model` is never type-checked** -- it goes into neither the pathname nor the record's
  # contents, and has no corresponding reader on the hook side. Failing here would mean a
  # display decoration stops the entire record write (indistinguishable, from the reader's
  # point of view, from the writer being absent). Even if the display falls back to `?`, the
  # record still gets placed per spec.
  st_run "$(jq -nc --arg cwd "$proj" \
    '{session_id: "sess-modelnum", cwd: $cwd, model: {display_name: 0},
      context_window: {used_percentage: 20.4}}')"
  if [ "$ST_STATUS" -eq 0 ] && [ -f "$tmp/usage/sess-modelnum.json" ]; then
    st_ok
  else
    st_fail "still places a record with a non-string model display name" "exit=${ST_STATUS}: ${ST_OUT}"
  fi
  # The same holds when `model` itself isn't an object (jq's indexing doesn't fail outright).
  st_run "$(jq -nc --arg cwd "$proj" \
    '{session_id: "sess-modelstr", cwd: $cwd, model: "Opus",
      context_window: {used_percentage: 20.4}}')"
  if [ "$ST_STATUS" -eq 0 ] && [ -f "$tmp/usage/sess-modelstr.json" ]; then
    st_ok
  else
    st_fail "still places a record with a non-object model" "exit=${ST_STATUS}: ${ST_OUT}"
  fi
  # The newline check alone still runs on `model` too (with one line carrying one value, a
  # newline in any field shifts every slot after it).
  st_run "$(jq -nc --arg cwd "$proj" --arg name "$(printf 'Opus\nB')" \
    '{session_id: "sess-modellf", cwd: $cwd, model: {display_name: $name},
      context_window: {used_percentage: 20.4}}')"
  if [ "$ST_STATUS" -ne 0 ] && [ ! -e "$tmp/usage/sess-modellf.json" ]; then
    st_ok
  else
    st_fail "writes no record for a model containing a newline" \
      "exit=${ST_STATUS}: ${ST_OUT} / $(cat "$tmp/usage/sess-modellf.json" 2>/dev/null)"
  fi

  # Usage **outside** the spec (`docs/spec/usage-state.md` = a number, 0-100, decimals
  # allowed). A gate that only checks type lets `NaN` and `1e400` sail through as the number
  # type, breaking the very point of rejecting the string `"20"` at the same gate. Never places
  # an unreadable record and claims success with exit 0.
  sid=0
  for bad_pct in NaN 1e400; do
    sid=$((sid + 1))
    st_run "$(printf '{"session_id":"sess-nf%s","cwd":"%s","context_window":{"used_percentage":%s}}' \
      "$sid" "$proj" "$bad_pct")"
    if [ "$ST_STATUS" -ne 0 ] && [ ! -e "$tmp/usage/sess-nf${sid}.json" ]; then
      st_ok
    else
      st_fail "writes no record for a non-finite usage (${bad_pct})" \
        "exit=${ST_STATUS}: ${ST_OUT} / $(cat "$tmp/usage/sess-nf${sid}.json" 2>/dev/null)"
    fi
    case "$ST_OUT" in
      *"is not a finite number"*) st_ok ;;
      *) st_fail "gives a reason for a non-finite usage (${bad_pct})" "$ST_OUT" ;;
    esac
  done
  sid=0
  for bad_pct in -0.1 100.1 99999; do
    sid=$((sid + 1))
    st_run "$(printf '{"session_id":"sess-rng%s","cwd":"%s","context_window":{"used_percentage":%s}}' \
      "$sid" "$proj" "$bad_pct")"
    if [ "$ST_STATUS" -ne 0 ] && [ ! -e "$tmp/usage/sess-rng${sid}.json" ]; then
      st_ok
    else
      st_fail "writes no record for usage outside 0-100 (${bad_pct})" \
        "exit=${ST_STATUS}: ${ST_OUT} / $(cat "$tmp/usage/sess-rng${sid}.json" 2>/dev/null)"
    fi
    case "$ST_OUT" in
      *"is outside 0-100"*) st_ok ;;
      *) st_fail "gives a reason for out-of-range usage (${bad_pct})" "$ST_OUT" ;;
    esac
  done
  # The accepting side (the boundary itself): 0 and 100 are inside the spec, so these are
  # accepted and recorded as before. Writing the range check as "greater than 0" / "less than
  # 100" would fail this.
  sid=0
  for good_pct in 0 100 20.4; do
    sid=$((sid + 1))
    st_run "$(printf '{"session_id":"sess-ok%s","cwd":"%s","context_window":{"used_percentage":%s}}' \
      "$sid" "$proj" "$good_pct")"
    if [ "$ST_STATUS" -eq 0 ] &&
      [ "$(jq -r '.context_window.used_percentage // empty' "$tmp/usage/sess-ok${sid}.json" 2>/dev/null)" = "$good_pct" ]; then
      st_ok
    else
      st_fail "accepts usage inside the spec (${good_pct})" \
        "exit=${ST_STATUS}: ${ST_OUT} / $(cat "$tmp/usage/sess-ok${sid}.json" 2>/dev/null)"
    fi
  done

  # Never silently passes stdin that isn't readable as JSON, or empty stdin.
  st_run 'not json at all'
  if [ "$ST_STATUS" -ne 0 ]; then
    st_ok
  else
    st_fail "fails on a payload that isn't JSON" "exit=${ST_STATUS}: ${ST_OUT}"
  fi
  st_run ''
  if [ "$ST_STATUS" -ne 0 ]; then
    st_ok
  else
    st_fail "fails on empty stdin" "exit=${ST_STATUS}: ${ST_OUT}"
  fi

  # The location is decided by the config layer (swapping the project config moves the write
  # destination too).
  printf 'usage_state_dir=%s\n' "$tmp/usage-moved" >"$proj/.rein/config"
  st_allow_project_config
  st_run "$(printf '{"session_id":"sess-3","cwd":"%s","context_window":{"used_percentage":30}}' "$proj")"
  if [ -f "$tmp/usage-moved/sess-3.json" ]; then
    st_ok
  else
    st_fail "the location follows the config layer's effective value" "exit=${ST_STATUS}: ${ST_OUT}"
  fi
  # A config with an unknown key or an invalid value never silently falls back to the default
  # (the same fail-loud as the config layer).
  printf 'usage_state_dir=relative/path\n' >"$proj/.rein/config"
  st_allow_project_config
  st_run "$(printf '{"session_id":"sess-4","cwd":"%s","context_window":{"used_percentage":30}}' "$proj")"
  if [ "$ST_STATUS" -ne 0 ]; then
    st_ok
  else
    st_fail "fails on an invalid config" "exit=${ST_STATUS}: ${ST_OUT}"
  fi

  # An unallowed project config is **never applied** (this is a passive context, so it never
  # fails outright). Writes go to the user-layer location instead, and not applying it goes to
  # stderr.
  # Whether an allow is needed is judged by **content**, so simply rewriting the content that's
  # currently allowed reverts it to unallowed. A value is placed at the user layer before
  # measuring this -- without it, this would fall back to the default (under the real HOME) and
  # the check would write into the user's own location.
  printf 'usage_state_dir=%s\n' "$tmp/usage-user" >"$tmp/user-config"
  printf 'usage_state_dir=%s\n' "$tmp/usage-unallowed" >"$proj/.rein/config"
  st_run "$(printf '{"session_id":"sess-8","cwd":"%s","model":{"display_name":"TestModel"},"context_window":{"used_percentage":30}}' "$proj")"
  if [ "$ST_STATUS" -eq 0 ]; then
    st_ok
  else
    st_fail "an unallowed project config never breaks the user's own turn" "exit=${ST_STATUS}: ${ST_OUT}"
  fi
  case "$ST_OUT" in
    *"the project settings are not applied"*) st_ok ;;
    *) st_fail "sends not-applied to stderr" "$ST_OUT" ;;
  esac
  if [ ! -e "$tmp/usage-unallowed" ]; then
    st_ok
  else
    st_fail "never writes to an unallowed project config's own location" "$tmp/usage-unallowed got created"
  fi
  if [ -f "$tmp/usage-user/sess-8.json" ]; then
    st_ok
  else
    st_fail "writes to the user-layer location when unallowed" "$(ls -a "$tmp/usage-user" 2>&1)"
  fi
  # A setting with a decision on record not to apply it drops the layer **silently** (never
  # sounds off every turn to the user who already decided).
  rein_config_decision_record deny "$proj/.rein/config" ||
    st_fail "can deny the check's own fixture" "$REIN_PROJECT_ALLOW_ERROR"
  st_run "$(printf '{"session_id":"sess-10","cwd":"%s","model":{"display_name":"TestModel"},"context_window":{"used_percentage":30}}' "$proj")"
  if [ "$ST_STATUS" -eq 0 ]; then
    st_ok
  else
    st_fail "a denied config never breaks the user's own turn either" "exit=${ST_STATUS}: ${ST_OUT}"
  fi
  case "$ST_OUT" in
    *"the project settings"*) st_fail "never sounds off for a denied config" "$ST_OUT" ;;
    *) st_ok ;;
  esac
  if [ -f "$tmp/usage-user/sess-10.json" ]; then
    st_ok
  else
    st_fail "writes to the user-layer location for a denied config too" "$(ls -a "$tmp/usage-user" 2>&1)"
  fi

  # The counterpart to the rejecting side (allowing it makes the same content take effect
  # as-is).
  st_allow_project_config
  st_run "$(printf '{"session_id":"sess-9","cwd":"%s","context_window":{"used_percentage":30}}' "$proj")"
  if [ -f "$tmp/usage-unallowed/sess-9.json" ]; then
    st_ok
  else
    st_fail "allowing it makes the project config take effect" "exit=${ST_STATUS}: ${ST_OUT}"
  fi

  # The gate for a location that must never be touched (where isolation would break).
  # **Both sides** are pinned with fixtures before using the predicate -- since every launch
  # this check makes sits outside the never-touch root, looking only at the side that doesn't
  # trip it would look the same green whether the judgment always returns false or the
  # judgment was deleted outright. The root passed is a temp directory, so both sides are
  # measured without touching a single byte of real state.
  nr_proj="$tmp/never-root-proj"
  mkdir -p "$nr_proj/.rein"
  # The side that doesn't trip it: a launch that resolved the location outside the never-touch
  # root sails through and writes the record too.
  printf 'usage_state_dir=%s\n' "$tmp/nr-usage-pass" >"$nr_proj/.rein/config"
  rein_config_allow_record "$nr_proj/.rein/config" ||
    st_fail "can allow the check's own fixture" "$REIN_PROJECT_ALLOW_ERROR"
  ST_EXTRA_ENV=("${REIN_SELFTEST_NEVER_ROOTS_ENV_NAME}=$tmp/nr-unrelated")
  st_run "$(printf '{"session_id":"sess-nr-pass","cwd":"%s","model":{"display_name":"TestModel"},"context_window":{"used_percentage":30}}' "$nr_proj")"
  if [ "$ST_STATUS" -eq 0 ] && [ -f "$tmp/nr-usage-pass/sess-nr-pass.json" ]; then
    st_ok
  else
    st_fail "a launch that resolved the location outside the never-touch root sails through" "exit=${ST_STATUS}: ${ST_OUT}"
  fi
  # The side that trips it: if the usage location is under the never-touch root, this fails
  # right before `mkdir -p`.
  printf 'usage_state_dir=%s\n' "$tmp/nr-usage-hit" >"$nr_proj/.rein/config"
  rein_config_allow_record "$nr_proj/.rein/config" ||
    st_fail "can allow the check's own fixture" "$REIN_PROJECT_ALLOW_ERROR"
  ST_EXTRA_ENV=("${REIN_SELFTEST_NEVER_ROOTS_ENV_NAME}=$tmp/nr-usage-hit")
  st_run "$(printf '{"session_id":"sess-nr-hit","cwd":"%s","model":{"display_name":"TestModel"},"context_window":{"used_percentage":30}}' "$nr_proj")"
  if [ "$ST_STATUS" -ne 0 ]; then
    st_ok
  else
    st_fail "fails a launch that resolved the location under the never-touch root" "exit=${ST_STATUS}: ${ST_OUT}"
  fi
  case "$ST_OUT" in
    *"${tmp}/nr-usage-hit (never-touch root ${tmp}/nr-usage-hit)"*) st_ok ;;
    *) st_fail "the failing reason names the tripped location and the root" "$ST_OUT" ;;
  esac
  # The rejecting side never even creates the location itself (directly observing that it
  # never reaches `mkdir -p`).
  if [ ! -e "$tmp/nr-usage-hit" ]; then
    st_ok
  else
    st_fail "the rejecting side writes not even one file under the never-touch root" "$(ls -a "$tmp/nr-usage-hit" 2>&1)"
  fi
  # The contract of printing the display first still holds (a write rejection never drags
  # down the user's own screen).
  case "$ST_OUT" in
    *"TestModel 30%"*) st_ok ;;
    *) st_fail "still shows one status-bar line even on a run that fails" "$ST_OUT" ;;
  esac
  # The side that trips it, in the form that actually matters: **falling back to the default
  # with nothing configured of its own**. The two cases above pass the root as
  # literal text, so neither one has actually checked whether the default location is on the
  # never-touch list -- forgetting to add it there would leave both sides green anyway. Only
  # here is the root **assembled through the same builder function** and passed in, checking
  # all the way through to whether a child whose HOME was knocked to a made-up value fails when
  # it resolves the default (`${HOME}/.claude/state/context-usage`).
  nr_home="$tmp/nr-home"
  nr_default_proj="$tmp/never-root-default-proj"
  mkdir -p "$nr_default_proj"
  nr_roots="$(
    export HOME="$nr_home"
    export XDG_STATE_HOME="$tmp/xdg-state"
    unset REIN_MANAGED_RUNTIME_DIR REIN_MANAGED_RECORDS_DIR
    rein_st_never_roots
    printf '%s' "$REIN_ST_NEVER_ROOTS"
  )"
  # The user layer is also removed (what this branch wants to see is **the default with no
  # value set at any layer**).
  ST_EXTRA_ENV=("HOME=$nr_home" "REIN_CONFIG_FILE=$tmp/nr-empty-user-config"
    "${REIN_SELFTEST_NEVER_ROOTS_ENV_NAME}=$nr_roots")
  st_run "$(printf '{"session_id":"sess-nr-default","cwd":"%s","model":{"display_name":"TestModel"},"context_window":{"used_percentage":30}}' "$nr_default_proj")"
  if [ "$ST_STATUS" -ne 0 ]; then
    st_ok
  else
    st_fail "a launch that fell back to the default location is also failed by the never-touch root" "exit=${ST_STATUS}: ${ST_OUT}"
  fi
  case "$ST_OUT" in
    *"${nr_home}/.claude/state/context-usage (never-touch root ${nr_home}/.claude/state/context-usage)"*) st_ok ;;
    *) st_fail "the default branch also names the tripped location and the root" "$ST_OUT" ;;
  esac
  if [ ! -e "$nr_home" ]; then
    st_ok
  else
    st_fail "the default branch also writes not even one file under the never-touch root" "$(ls -aR "$nr_home" 2>&1)"
  fi
  ST_EXTRA_ENV=()

  # The managed marker decides which user-scope config file this record's location is resolved
  # through. All three cases below run **the same payload shape against the same project**, so
  # the only thing that differs between them is the marker env -- if the record still landed in
  # the same place across all three, nothing about the marker would be under test.
  # The lineage's own config and the user-layer config name **different** locations
  # ($tmp/usage-marker vs the $tmp/usage-user already set above), which is what makes "resolved
  # through the marker" and "resolved through the default" tell each other apart. Every case
  # checks both locations, since a record appearing in the right one proves nothing on its own
  # if it appears in the other one as well.
  mk_proj="$tmp/marker-proj"
  mk_state="$tmp/marker-state/rein"
  mkdir -p "$mk_proj" "$mk_state"
  # The runtime directory is laid out the way a real lineage's is (the state area, keyed by
  # cwd), because the validation rejects a runtime directory that sits under the lineage cwd.
  # The key comes from the shared function rather than being spelled out here, so a change to
  # how it is derived can never leave this check passing against a shape only it can build.
  mk_runtime="$mk_state/$(rein_cwd_key "$mk_proj")"
  mkdir -p "$mk_runtime"
  printf '%s\n' "$mk_proj" >"$mk_runtime/$REIN_OWNER_BASENAME"
  # The lineage token goes through the shared provisioning function, never written here by
  # hand -- the fixture has to hold **whatever that function actually places**.
  if rein_ensure_runtime_token "$mk_runtime"; then
    mk_token="$REIN_RUNTIME_TOKEN"
  else
    mk_token=""
    st_fail "can place a lineage token in the check's own fixture" "$REIN_RUNTIME_ERROR"
  fi
  # A well-formed token that simply is not this lineage's (the shape passes, the value does
  # not) -- the forgery an attacker who knows the marker's shape can actually build.
  mk_forged_token="0000000000000000000000000000000000000000000000000000000000000000"
  printf 'usage_state_dir=%s\n' "$tmp/usage-marker" >"$tmp/marker-config"

  # A marker that verifies: the record goes to the location the **lineage's own** config names.
  ST_EXTRA_ENV=(
    "${REIN_MANAGED_ENV_NAME}=1"
    "${REIN_MANAGED_CWD_ENV_NAME}=$mk_proj"
    "${REIN_MANAGED_RUNTIME_ENV_NAME}=$mk_runtime"
    "${REIN_MANAGED_RECORDS_ENV_NAME}=$mk_proj/$REIN_RECORDS_DIRNAME"
    "${REIN_MANAGED_CONFIG_ENV_NAME}=$tmp/marker-config"
    "${REIN_MANAGED_TOKEN_ENV_NAME}=$mk_token"
  )
  st_run "$(printf '{"session_id":"sess-marker-ok","cwd":"%s","model":{"display_name":"TestModel"},"context_window":{"used_percentage":30}}' "$mk_proj")"
  if [ "$ST_STATUS" -eq 0 ]; then
    st_ok
  else
    st_fail "a verified marker ends with 0" "exit=${ST_STATUS}: ${ST_OUT}"
  fi
  if [ -f "$tmp/usage-marker/sess-marker-ok.json" ]; then
    st_ok
  else
    st_fail "a verified marker writes to the location its own config names" "exit=${ST_STATUS}: ${ST_OUT}"
  fi
  if [ ! -e "$tmp/usage-user/sess-marker-ok.json" ]; then
    st_ok
  else
    st_fail "a verified marker never also writes to the default location" "$(ls -a "$tmp/usage-user" 2>&1)"
  fi

  # No marker at all: **the normal state.** statusline is registered once in the user's own
  # settings and runs in every plain `claude` session, so this resolves through the user layer
  # exactly as before -- and says nothing, since a missing marker is not a failure.
  ST_EXTRA_ENV=()
  st_run "$(printf '{"session_id":"sess-marker-none","cwd":"%s","model":{"display_name":"TestModel"},"context_window":{"used_percentage":30}}' "$mk_proj")"
  if [ "$ST_STATUS" -eq 0 ]; then
    st_ok
  else
    st_fail "a session with no marker ends with 0" "exit=${ST_STATUS}: ${ST_OUT}"
  fi
  if [ -f "$tmp/usage-user/sess-marker-none.json" ]; then
    st_ok
  else
    st_fail "with no marker the record goes to the default location" "exit=${ST_STATUS}: ${ST_OUT}"
  fi
  if [ ! -e "$tmp/usage-marker/sess-marker-none.json" ]; then
    st_ok
  else
    st_fail "with no marker nothing is written to the lineage location" "$(ls -a "$tmp/usage-marker" 2>&1)"
  fi
  case "$ST_OUT" in
    *"marker"*) st_fail "never sounds off about a marker that simply is not there" "$ST_OUT" ;;
    *) st_ok ;;
  esac

  # A marker that is present but does not verify (a well-formed token that is not this
  # lineage's). The marker is **not used**: the default resolution stands, the reason is said
  # out loud, and the user's own turn is not broken.
  ST_EXTRA_ENV=(
    "${REIN_MANAGED_ENV_NAME}=1"
    "${REIN_MANAGED_CWD_ENV_NAME}=$mk_proj"
    "${REIN_MANAGED_RUNTIME_ENV_NAME}=$mk_runtime"
    "${REIN_MANAGED_RECORDS_ENV_NAME}=$mk_proj/$REIN_RECORDS_DIRNAME"
    "${REIN_MANAGED_CONFIG_ENV_NAME}=$tmp/marker-config"
    "${REIN_MANAGED_TOKEN_ENV_NAME}=$mk_forged_token"
  )
  st_run "$(printf '{"session_id":"sess-marker-bad","cwd":"%s","model":{"display_name":"TestModel"},"context_window":{"used_percentage":30}}' "$mk_proj")"
  if [ "$ST_STATUS" -eq 0 ]; then
    st_ok
  else
    st_fail "an unverified marker never breaks the user's own turn" "exit=${ST_STATUS}: ${ST_OUT}"
  fi
  if [ ! -e "$tmp/usage-marker/sess-marker-bad.json" ]; then
    st_ok
  else
    st_fail "an unverified marker never writes to the location it names" "$(ls -a "$tmp/usage-marker" 2>&1)"
  fi
  if [ -f "$tmp/usage-user/sess-marker-bad.json" ]; then
    st_ok
  else
    st_fail "an unverified marker falls back to the default location" "exit=${ST_STATUS}: ${ST_OUT}"
  fi
  # The reason is pinned, not just "something was said" -- an exit code cannot tell one
  # rejection apart from another, and falling back in silence is the outcome this case exists
  # to rule out.
  case "$ST_OUT" in
    *"the managed marker is not used for this record"*"$REIN_MANAGED_TOKEN_ENV_NAME"*) st_ok ;;
    *) st_fail "an unverified marker says why it was not used" "$ST_OUT" ;;
  esac
  # The display contract still holds on this path (the status bar is never dragged down by
  # anything happening on the record side).
  case "$ST_OUT" in
    *"TestModel 30%"*) st_ok ;;
    *) st_fail "still shows one status-bar line when the marker is not used" "$ST_OUT" ;;
  esac
  ST_EXTRA_ENV=()

  rm -rf "$tmp"
  printf '%s: selftest %d pass / %d fail\n' "$SCRIPT_NAME" "$pass" "$fail"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --selftest)
    selftest # test-side-scope-exempt: the one line that starts the selftest entry point (not a production writer)
    exit $?
    ;;
esac
statusline_main "$@"
