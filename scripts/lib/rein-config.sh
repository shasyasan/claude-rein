# shellcheck shell=bash
# shellcheck disable=SC2034  # variables built dynamically from the known-keys table look unused in this file alone
# rein's config layer. Folds config files, environment variables, and CLI flags into one
# priority order, and fails loud on anything outside the known-key set or an invalid value.
# hooks source this directly too (spawning `rein config get` on every call would turn its
# startup cost into user-visible latency, since hooks run on every tool call).
# Not an executable script, so it does not carry the execute bit (out of scope for the
# --selftest convention).
#
# The file format's literal specification (readers and writers follow only this rule set):
#   - One setting per line. Never `source`d (so a value can never run as arbitrary shell
#     code).
#   - Blank lines and lines whose **first character** is `#` are comments. An indented `#` is
#     not a comment -- it's a format violation.
#   - Split on the first `=`: the left side is the key, the right side is the value. The
#     value is taken verbatim to end of line -- no shell expansion, no `~` expansion, no
#     quote interpretation, no trimming of surrounding whitespace.
#   - A value never contains a newline (LF or CR). Rejected in every layer, including values
#     that came from an environment variable. Anything that might contain a newline travels
#     as a path instead.
#   - A duplicate key within the same file is a format violation (letting the last one win
#     would leave a line the user thought they deleted still in effect).
#
# Priority order (later wins): default < user config < project config < environment
# variable < CLI flag.
#
# "Unset" and "explicitly empty" are distinct: if a value is empty but its origin is
# recorded, that's read as explicitly empty (i.e. disabled at that layer), and it does not
# fall through to a lower layer's value. Lose that distinction and a project that thinks it
# turned a feature off comes back to life through the user's value.

# Work out this file's own location with **string operations only** (never spawn dirname /
# pwd). A hook reads this file on every tool call, and that read happens before payload
# validation. Spawning `dirname` means that on a machine where `dirname`
# returns empty (no /usr/bin on PATH, or a direnv / npm setup that puts a repo-bundled bin
# directory ahead on PATH), `cd "" && pwd` returns **the hook process's cwd** (the repo being
# worked on), and it would then source and run whatever rein-common.sh is bundled there
# (arbitrary code execution reproduced in an isolated environment).
# Being sourced with a relative path fails **right here** (fail-loud). Falling back to the
# current directory would recreate the exact "reads whatever is bundled in cwd" hole this
# just closed -- keeping the load path absolute is the caller's responsibility, so this
# surfaces the violation instead of silently correcting it (the same discipline as
# REIN_WATCHER_SCRIPT_PATH in rein-common.sh).
REIN_CONFIG_LIB_DIR="${BASH_SOURCE[0]}"
case "$REIN_CONFIG_LIB_DIR" in
  /*) ;;
  *)
    printf 'rein: the config layer was loaded with a relative path (cannot resolve the bundled shared library to an absolute path): %s\n' \
      "$REIN_CONFIG_LIB_DIR" >&2
    exit 1
    ;;
esac
REIN_CONFIG_LIB_DIR="${REIN_CONFIG_LIB_DIR%/*}"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=rein-common.sh
. "$REIN_CONFIG_LIB_DIR/rein-common.sh"

REIN_CONFIG_ERROR=""
REIN_CONFIG_WARNING=""
REIN_CONFIG_VALUE=""
REIN_CONFIG_ORIGIN=""
REIN_CONFIG_USER_FILE=""
REIN_CONFIG_PROJECT_FILE=""
# The target cwd for settings. Kept so that a default that tracks cwd (handoff_path) can be
# resolved when fetching the effective value.
REIN_CONFIG_CWD=""
# The lineage's records location (optional). When a lineage is passed in, this value resolves
# the default instead of re-deriving it from cwd -- so that a reader who knows the records
# location but has no REIN_RECORDS_ROOT in its environment (as a managed hook does) still
# points at the same canonical source as every other path.
REIN_CONFIG_RECORDS_DIR=""
REIN_CONFIG_LOADED=0
REIN_CFG_KEYS=""
REIN_CFG_KEY_UPPER=""
REIN_CFG_KEY_TYPE=""
REIN_CFG_KEY_DEFAULT=""
REIN_CFG_KEY_SECRET=0
REIN_CFG_KEY_LABEL=""
REIN_CFG_KEY_MEANING=""

# Expand the known-keys table into variables once, at source time. Running the heredoc
# through a command substitution on every lookup would cost tens of milliseconds of fork
# per call, throwing away exactly what hooks gain by sourcing the parser directly (i.e. not
# spawning a command).
# Columns: key|env var suffix|type|can hold a secret|default|type-and-unit label|meaning.
# The last two columns (the type-and-unit label and the meaning) are **the canonical source
# for what each key means**; `rein config list` prints them under each value's line. Copying
# the user-facing description into a separate document would let one copy go stale whenever a
# key is added (a copy is only visible to its own reader), so this one table carries the
# description too.
# Quote the heredoc delimiter (`<<'EOF'`). The last two columns are free-form user-facing
# text that can contain `$` or backticks -- an expanding heredoc would expand and execute the
# table itself.
# The environment variable name is `REIN_` plus the key in uppercase. That mapping is kept
# verbatim in the second column, and the selftest checks it against every key (relying on a
# generation rule alone would let a spelling drift turn into a silently unset value at the
# reader).
# A key whose default is empty means "unset -- this feature is off"; the consuming side
# fails loud there if it actually needs the value.
# **An environment-dependent default cannot live in this table.** The table is expanded
# exactly once, at source time, so:
# (1) A default that tracks cwd (handoff_path) would bake in whatever cwd happened to be
#     current at that moment (wherever the hook launcher or nohup started -- unrelated to the
#     target project).
# (2) A default that includes HOME (usage_state_dir) would **bake in the collapsed
#     `/.claude/...` path on a machine where HOME is empty or unset**. The collapsed path starts
#     with `/`, so it passes the abs-path check, and an unwritable path directly under root
#     (one other users can place files under) gets handed out as "the default location". The
#     missing HOME never surfaces, and the eventual failure reads as the unrelated "cannot
#     write" (this actually happens over launchd, over an ssh session with a stripped
#     environment, and in a hook process that inherits that environment).
# The keys this applies to leave the table's default column empty, and fetching the
# effective value (rein_config_fetch) resolves it through rein_config_dynamic_default
# instead -- every path goes through that one resolution, and a machine where it cannot be
# resolved fails loud right there.
rein_config_expand_spec() {
  local k u t s d l m
  REIN_CFG_KEYS=""
  while IFS='|' read -r k u t s d l m; do
    [ -n "$k" ] || continue
    REIN_CFG_KEYS="${REIN_CFG_KEYS}${REIN_CFG_KEYS:+ }${k}"
    printf -v "REIN_CFGU_${k}" '%s' "$u"
    printf -v "REIN_CFGT_${k}" '%s' "$t"
    printf -v "REIN_CFGS_${k}" '%s' "$s"
    printf -v "REIN_CFGD_${k}" '%s' "$d"
    printf -v "REIN_CFGL_${k}" '%s' "$l"
    printf -v "REIN_CFGM_${k}" '%s' "$m"
    printf -v "REIN_CFGK_${u}" '%s' "$k"
  done <<'EOF'
poll_interval_sec|POLL_INTERVAL_SEC|pos-number|0|5|positive number, seconds (decimals allowed)|how often the watcher's poll loop checks for handover requests and stop requests
cmd_timeout_sec|CMD_TIMEOUT_SEC|pos-int|0|60|positive integer, seconds|cap on a single external command
final_output_timeout_sec|FINAL_OUTPUT_TIMEOUT_SEC|nonneg-int|0|120|nonnegative integer, seconds|cap on waiting, after a handover request is accepted, for the predecessor's marker that it has finished responding (if it never comes, the successor starts without waiting)
final_output_wait_sec|FINAL_OUTPUT_WAIT_SEC|nonneg-int|0|10|nonnegative integer, seconds|wait between seeing that marker and starting the successor (talking to the session within this window cancels the handover)
launch_timeout_sec|LAUNCH_TIMEOUT_SEC|nonneg-int|0|120|nonnegative integer, seconds|cap on waiting for the successor to appear in the claude agents --json listing
exit_grace_sec|EXIT_GRACE_SEC|nonneg-int|0|15|nonnegative integer, seconds|grace period after the pointer is updated before the predecessor is stopped externally
stop_timeout_sec|STOP_TIMEOUT_SEC|nonneg-int|0|60|nonnegative integer, seconds|cap on waiting for an externally stopped session to drop out of enumeration (both a handover's predecessor and down's primary session)
watcher_log_max_bytes|WATCHER_LOG_MAX_BYTES|pos-int|0|1048576|positive integer, bytes|size cap on the watcher log
marker_max_age_sec|MARKER_MAX_AGE_SEC|nonneg-int|0|900|nonnegative integer, seconds|cutoff past which a handover request marker's claimed timestamp is judged too old, relative to now
max_clock_skew_sec|MAX_CLOCK_SKEW_SEC|nonneg-int|0|60|nonnegative integer, seconds|how far into the future a timestamp is tolerated before it is rejected as a future time
handoff_fresh_window_sec|HANDOFF_FRESH_WINDOW_SEC|nonneg-int|0|600|nonnegative integer, seconds|how far back from a marker's claimed timestamp the handoff document's mtime is still accepted as current
seat_wait_timeout_sec|SEAT_WAIT_TIMEOUT_SEC|nonneg-int|0|0|nonnegative integer, seconds|cap on how long the attach loop waits for the current pointer to change
seat_attach_retry_max|SEAT_ATTACH_RETRY_MAX|nonneg-int|0|3|nonnegative integer, count|how many times the attach loop retries a failed attach
seat_heartbeat_max_age_sec|SEAT_HEARTBEAT_MAX_AGE_SEC|nonneg-int|0|60|nonnegative integer, seconds|cutoff past which the attach loop treats the watcher's heartbeat as stale
threshold_notice|THRESHOLD_NOTICE|percent|0|30|0-100, percent usage|usage percentage at which advisories (usage injections) start
threshold_handover|THRESHOLD_HANDOVER|percent|0|40|0-100, percent usage|usage percentage at which the threshold trips: blocking the end of a turn and forcing a handover
notice_cooldown_sec|NOTICE_COOLDOWN_SEC|pos-int|0|1800|positive integer, seconds|cooldown that keeps the same advisory from repeating
usage_stale_sec|USAGE_STALE_SEC|pos-int|0|1800|positive integer, seconds|cutoff past which the usage record is treated as stale
snooze_max_sec|SNOOZE_MAX_SEC|pos-int|0|3600|positive integer, seconds|cap on the duration a snooze accepts
archive_days|ARCHIVE_DAYS|nonneg-int|0|30|nonnegative integer, days|minimum age at which prune treats an archived marker (accepted or rejected) as a cleanup candidate (older than this qualifies)
model|MODEL|string|0||string|model passed when launching the successor (the way to pin it across generations)
settings|SETTINGS|string|1||string (can hold a secret)|settings passed when launching the successor (a file path or a JSON string)
runtime_dir|RUNTIME_DIR|abs-path|0||absolute path|location of runtime data (markers, locks, heartbeat)
handoff_path|HANDOFF_PATH|abs-path|0||absolute path|where the handoff document lives
kickoff_note_path|KICKOFF_NOTE_PATH|abs-path|0||absolute path|file that, at successor launch, points at just that location in one line
usage_state_dir|USAGE_STATE_DIR|abs-path|0||absolute path|location of the usage record (the statusLine writes it; rein itself only reads it)
EOF
}
rein_config_expand_spec

rein_config_keys() {
  local key
  for key in $REIN_CFG_KEYS; do
    printf '%s\n' "$key"
  done
}

# Look up a key and load REIN_CFG_KEY_{UPPER,TYPE,DEFAULT,SECRET,LABEL,MEANING}. Returns 1 for
# an unknown key.
# Load **every** column of the table here (loading only some of them would give a reader who
# needs the others a second entry point that re-reads the table).
# The literal-form check comes first so an invalid identifier is rejected before it's used
# as an indirect-expansion variable name.
rein_config_lookup() {
  local key="$1" var
  case "$key" in
    '' | [!a-z]* | *[!a-z0-9_]*)
      return 1
      ;;
  esac
  var="REIN_CFGU_${key}"
  [ -n "${!var:-}" ] || return 1
  REIN_CFG_KEY_UPPER="${!var}"
  var="REIN_CFGT_${key}"
  REIN_CFG_KEY_TYPE="${!var}"
  var="REIN_CFGD_${key}"
  REIN_CFG_KEY_DEFAULT="${!var:-}"
  var="REIN_CFGS_${key}"
  REIN_CFG_KEY_SECRET="${!var}"
  var="REIN_CFGL_${key}"
  REIN_CFG_KEY_LABEL="${!var}"
  var="REIN_CFGM_${key}"
  REIN_CFG_KEY_MEANING="${!var}"
  return 0
}

# Look up a known key from its environment variable name (an unknown REIN_* is outside the
# config layer's scope and is silently ignored -- non-config REIN_* variables do exist, such
# as check.sh's override hook).
# Returns the result through a variable ($( ) would spawn a subshell per call, stacking one
# fork per environment variable).
REIN_CFG_ENV_KEY=""
rein_config_key_for_env() {
  local name="$1" suffix var
  REIN_CFG_ENV_KEY=""
  case "$name" in
    REIN_*) ;;
    *) return 1 ;;
  esac
  suffix="${name#REIN_}"
  case "$suffix" in
    '' | *[!A-Z0-9_]*)
      return 1
      ;;
  esac
  var="REIN_CFGK_${suffix}"
  [ -n "${!var:-}" ] || return 1
  REIN_CFG_ENV_KEY="${!var}"
  return 0
}

# A key that can hold a secret never prints its value, whether in the listing or an error
# message (config files are plaintext, and `settings` can hold JSON containing credentials).
# The full value is shown only when the user names the key explicitly, via `config get <key>`.
rein_config_display_value() {
  local key="$1" value="$2"
  if rein_config_lookup "$key" && [ "$REIN_CFG_KEY_SECRET" = "1" ] && [ -n "$value" ]; then
    printf '%s\n' '***'
    return 0
  fi
  printf '%s\n' "$value"
}

# Digit cap on a value accepted as an integer. **A digit string that passes the literal-only
# type check (rein_is_nonneg_int) goes straight into `[`'s integer comparison and into
# `$(( ))`** -- past 64 bits, (1) `[` leaks a diagnostic that isn't rein's own, in English
# ("integer expression expected"), to standard error (which reaches the user's own session
# over the hooks / statusline path), and (2) arithmetic silently wraps around into behavior
# unrelated to the configured value (observed: putting 19 digits into max_clock_skew_sec makes
# `$((now + MAX_CLOCK_SKEW_SEC))` wrap negative, and the watcher then rejects every handover
# request as "the requested time is in the future"). 10 digits -- 9999999999 seconds, about
# 317 years -- sits outside real-world use for seconds, byte counts, or day counts alike, and
# the consumer's own arithmetic (adding to or subtracting from an epoch) still fits inside 64
# bits. The cap is checked by digit count, not by arithmetic, because **checking the cap
# itself arithmetically is exactly the comparison that would wrap**.
REIN_CONFIG_INT_MAX_DIGITS=10

# Whether a digit string exceeds the digit cap. **A non-digit-string value is out of scope**
# (0 = exceeds it / 1 = out of scope, or within it) -- the reason text is left to the type
# check, since rejecting a non-numeric value with "too large" would give the wrong reason.
rein_config_int_too_long() {
  case "${1:-}" in
    '' | *[!0-9]*) return 1 ;;
  esac
  [ "${#1}" -gt "$REIN_CONFIG_INT_MAX_DIGITS" ]
}

# Type validation. Silently falling back to the default on an invalid value leads to a loop
# that never waits, an unbounded wait, or an invalid threshold.
# Putting the value into the reason text is safe only because every key that can hold a
# secret is of type string (a string only ever fails for containing a newline, and that
# reason text doesn't include the value).
# When adding another type to a key that can hold a secret, that type's reason text must
# withhold the value. The selftest checks this premise mechanically.
rein_config_validate_value() {
  local key="$1" value="$2" type
  if ! rein_config_lookup "$key"; then
    REIN_CONFIG_ERROR="unknown key: ${key}"
    return 1
  fi
  type="$REIN_CFG_KEY_TYPE"
  # Reject newlines before checking the type. Letting one through breaks the "one setting
  # per line" premise, and the value's second and later lines get read as some other key's
  # setting (an injection through the value).
  case "$value" in
    *$'\n'* | *$'\r'*)
      REIN_CONFIG_ERROR="${key}'s value cannot contain a newline (anything that might contain one travels as a path instead)"
      return 1
      ;;
  esac
  # The digit-count check comes **before the type branch**. Placed after it, `[ "$value" -le
  # 100 ]` (percent) and rein_is_pos_int's `[ "$1" -gt 0 ]` (pos-int) would receive a
  # >64-bit digit string first, and even though the final verdict would still be correct, an
  # English shell diagnostic would leak to standard error.
  case "$type" in
    nonneg-int | pos-int | percent)
      if rein_config_int_too_long "$value"; then
        REIN_CONFIG_ERROR="${key}'s value is too large (an integer can have at most ${REIN_CONFIG_INT_MAX_DIGITS} digits): ${value}"
        return 1
      fi
      ;;
  esac
  case "$type" in
    string)
      return 0
      ;;
    abs-path)
      if [ -z "$value" ]; then
        return 0
      fi
      case "$value" in
        /*)
          return 0
          ;;
      esac
      REIN_CONFIG_ERROR="${key} must be an absolute path (values are taken verbatim, so ~ is not expanded either): ${value}"
      return 1
      ;;
    percent)
      if [ -z "$value" ]; then
        REIN_CONFIG_ERROR="${key} cannot be empty (to fall back to the default, run config unset --user ${key} or config unset --project ${key} -- config list's origin column shows which layer holds the value)"
        return 1
      fi
      if rein_validate_number "$key" "$value" nonneg-int && [ "$value" -le 100 ]; then
        return 0
      fi
      REIN_CONFIG_ERROR="${key} must be an integer between 0 and 100: ${value}"
      return 1
      ;;
    *)
      if [ -z "$value" ]; then
        REIN_CONFIG_ERROR="${key} cannot be empty (to fall back to the default, run config unset --user ${key} or config unset --project ${key} -- config list's origin column shows which layer holds the value)"
        return 1
      fi
      if rein_validate_number "$key" "$value" "$type"; then
        return 0
      fi
      REIN_CONFIG_ERROR="the setting value is invalid: ${REIN_INVALID_VALUE}"
      return 1
      ;;
  esac
}

rein_config_reset() {
  local key var
  for key in $REIN_CFG_KEYS; do
    var="REIN_CFGU_${key}"
    unset "REIN_CFGV_${!var}" "REIN_CFGO_${!var}"
  done
  REIN_CONFIG_LOADED=0
  REIN_CONFIG_WARNING=""
}

# Load one entry along with its origin. A non-empty origin is the marker for "explicitly set".
rein_config_assign() {
  local key="$1" value="$2" origin="$3" upper
  if ! rein_config_lookup "$key"; then
    REIN_CONFIG_ERROR="unknown key: ${key}"
    return 1
  fi
  upper="$REIN_CFG_KEY_UPPER"
  printf -v "REIN_CFGV_${upper}" '%s' "$value"
  printf -v "REIN_CFGO_${upper}" '%s' "$origin"
  return 0
}

# The content read in full, and whether it existed. These two variables carry the discipline of
# **opening exactly once**.
REIN_CONFIG_READ_TEXT=""
REIN_CONFIG_READ_PRESENT=0

# Take a file's content **whole, in one read**. Reopening the same path can catch a different
# content each time -- a replacement happens through a rename (an editor's save, `git
# checkout`), and a rename is atomic, so a single read is guaranteed to catch one side of it
# whole, but opening twice can catch "A the first time, B the second". For the decision (the
# digest) and the application (the parse) to see the same bytes, the only way is to fix the
# open count at exactly one.
# NUL is treated as a read boundary -- a read that stops there has **not** been read in full,
# so it's rejected (settings are newline-delimited text and never contain a NUL; the decision
# never continues on silently truncated content).
# Failing to open (the read never running at all) is detected by the exit-status variable
# staying unset -- a failed open is never let through as "an empty file".
# 0 = read (PRESENT=1 means content is in READ_TEXT; 0 means absent -- no setting is a normal
# state)
# 1 = cannot read (reason in REIN_CONFIG_ERROR)
rein_config_open_file() {
  local file="$1" got=""
  REIN_CONFIG_READ_TEXT=""
  REIN_CONFIG_READ_PRESENT=0
  if [ ! -e "$file" ]; then
    return 0
  fi
  if [ ! -f "$file" ]; then
    REIN_CONFIG_ERROR="${file} is not a regular file"
    return 1
  fi
  if [ ! -r "$file" ]; then
    REIN_CONFIG_ERROR="cannot read ${file}"
    return 1
  fi
  # Redirect standard error **before** reopening the input (these are processed in order, so
  # placing it after would leak the shell's own message on a failed open to the caller's
  # standard error).
  { IFS= read -r -d '' REIN_CONFIG_READ_TEXT; got=$?; } 2>/dev/null <"$file"
  if [ -z "$got" ]; then
    REIN_CONFIG_READ_TEXT=""
    REIN_CONFIG_ERROR="cannot read ${file}"
    return 1
  fi
  if [ "$got" -eq 0 ]; then
    REIN_CONFIG_READ_TEXT=""
    REIN_CONFIG_ERROR="${file} contains a NUL byte (settings are newline-delimited text)"
    return 1
  fi
  REIN_CONFIG_READ_PRESENT=1
  return 0
}

# Split the content read in full into lines. **Never drops the last line for lacking a
# trailing newline** (a newline is the line boundary itself, so having nothing after the last
# boundary doesn't add another line).
REIN_CONFIG_LINES=()
rein_config_split_lines() {
  local rest="$1"
  REIN_CONFIG_LINES=()
  while [ -n "$rest" ]; do
    case "$rest" in
      *$'\n'*)
        REIN_CONFIG_LINES[${#REIN_CONFIG_LINES[@]}]="${rest%%$'\n'*}"
        rest="${rest#*$'\n'}"
        ;;
      *)
        REIN_CONFIG_LINES[${#REIN_CONFIG_LINES[@]}]="$rest"
        rest=""
        ;;
    esac
  done
}

# A format-violation reason never includes the line's content (a value may hold a secret).
# Position is given by line number.
# Takes the content to parse as **bytes already read in full, not a path** -- not reopening
# it guarantees that the content the allow gate digested is the same content applied as a
# layer.
# $1 = content, $2 = origin label, $3 = path to put in the reason text and the origin.
rein_config_parse_text() {
  local text="$1" origin="$2" file="$3" line lineno=0 key value seen="" i=0 count
  rein_config_split_lines "$text"
  count=${#REIN_CONFIG_LINES[@]}
  while [ "$i" -lt "$count" ]; do
    line="${REIN_CONFIG_LINES[$i]}"
    i=$((i + 1))
    lineno=$((lineno + 1))
    case "$line" in
      '' | '#'*)
        continue
        ;;
    esac
    case "$line" in
      *=*) ;;
      *)
        REIN_CONFIG_ERROR="${file}:${lineno}: not in key=value form"
        return 1
        ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    case "$key" in
      '' | [!a-z]* | *[!a-z0-9_]*)
        REIN_CONFIG_ERROR="${file}:${lineno}: invalid key name (lowercase letters, digits, and _ only, no surrounding whitespace): ${key}"
        return 1
        ;;
    esac
    if ! rein_config_lookup "$key"; then
      REIN_CONFIG_ERROR="${file}:${lineno}: unknown key: ${key}"
      return 1
    fi
    case " $seen " in
      *" $key "*)
        REIN_CONFIG_ERROR="${file}:${lineno}: duplicate key: ${key}"
        return 1
        ;;
    esac
    seen="$seen $key"
    if ! rein_config_validate_value "$key" "$value"; then
      REIN_CONFIG_ERROR="${file}:${lineno}: ${REIN_CONFIG_ERROR}"
      return 1
    fi
    rein_config_assign "$key" "$value" "${origin}:${file}" || return 1
  done
  return 0
}

# Rewrites the path shown in the reason text and the origin. `config set` / `config unset`
# check whether a candidate is valid before writing it by **placing the candidate in a
# temp file in the same directory and re-reading it with that layer's path swapped for the
# temp file** (rein_config_commit_scope). Building the reason text with the swap still in
# place would give both the origin and the format-violation position a `.../config.XXXXXX`
# path -- **one that no longer exists right after the decision** -- which the user cannot
# open to check (docs/spec/config.md's "when it's clear which layer holds a value, name that
# layer in one line" would become naming in appearance only). The read still targets the temp
# file; only what it's shown as reverts to the real path.
REIN_CONFIG_PATH_ALIAS_TMP=""
REIN_CONFIG_PATH_ALIAS_REAL=""
REIN_CONFIG_SHOWN_PATH=""
rein_config_shown_path() {
  REIN_CONFIG_SHOWN_PATH="$1"
  [ -n "$REIN_CONFIG_PATH_ALIAS_TMP" ] || return 0
  [ "$1" = "$REIN_CONFIG_PATH_ALIAS_TMP" ] || return 0
  REIN_CONFIG_SHOWN_PATH="$REIN_CONFIG_PATH_ALIAS_REAL"
  return 0
}

rein_config_parse_file() {
  local file="$1" origin="$2"
  rein_config_open_file "$file" || return 1
  [ "$REIN_CONFIG_READ_PRESENT" -eq 1 ] || return 0
  rein_config_shown_path "$file"
  rein_config_parse_text "$REIN_CONFIG_READ_TEXT" "$origin" "$REIN_CONFIG_SHOWN_PATH"
}

# Pull **only the names** of environment variables from the shell itself (compgen -e is a
# builtin that lists exported names). Not chosen: reading names and values together in one
# stream (dumping the environment with an external command), for two reasons: (1) an
# unrelated environment variable whose value contains a newline would have its second and
# later lines read as a separate variable (an injection), and (2) reading a value would need
# an external command (perl), and on the hook path that runs on every tool call, that one
# call (about 17ms on this machine) becomes user-visible latency directly. A name never
# contains a newline, so names alone travel as lines and values are read straight from the
# shell with indirect expansion. The name listing covers only exported names, so a shell
# variable a shared library seeded with its own default (e.g. REIN_CMD_TIMEOUT_SEC in
# rein-common.sh) is never misread as "given through the environment".
rein_config_env_names() {
  compgen -e 2>/dev/null | LC_ALL=C sort
}

rein_config_apply_env() {
  local name value
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    rein_config_key_for_env "$name" || continue
    value="${!name:-}"
    if ! rein_config_validate_value "$REIN_CFG_ENV_KEY" "$value"; then
      REIN_CONFIG_ERROR="environment variable ${name}: ${REIN_CONFIG_ERROR}"
      return 1
    fi
    rein_config_assign "$REIN_CFG_ENV_KEY" "$value" "env:${name}" || return 1
  done <<EOF
$(rein_config_env_names)
EOF
  return 0
}

# Validation before accepting a CLI flag's value. $1 = flag name, $2 = key name, $3 = count
# of remaining arguments, $4 = value.
# "No value given" and "an explicitly empty value" are rejected for different reasons.
# Silently treating an empty value as unspecified would give a user who meant to disable
# something no signal at all, and it would run on the value from the layer below (project
# config). No "explicitly empty = disabled" semantics are built into the CLI layer -- it
# points to the config layer instead, since splitting that into two entry points would make
# behavior depend on which one was used to clear it. Which entry point it points to depends
# on the key: a key whose default is empty is disabled by `config unset` directly, but for a
# key with a dynamic default (handoff_path), **`unset` brings the default back**, so
# disabling it takes `config set <key> ""` (explicitly empty). Pointing to the wrong one
# would leave a user who meant to disable it running on the canonical default instead.
# 0 = may be used / 1 = reject (reason in REIN_CONFIG_ERROR)
rein_config_check_opt() {
  local flag="$1" key="$2" count="$3" value="${4:-}"
  if [ "$count" -lt 2 ]; then
    REIN_CONFIG_ERROR="${flag} requires a value"
    return 1
  fi
  if [ -z "$value" ]; then
    # Names the entry point by **its own name**, not as one runnable `rein ...` line. This check
    # runs at the stage of reading options -- before resolving where settings live
    # (rein_config_resolve_files comes after) -- so it cannot fill the lineage's naming
    # (`--root` / `--config`) with an effective value. Stating `rein config unset <key>`
    # flatly without filling that in would hand a user whose lineage moved its location a
    # line that rewrites **a different config** (the same discipline as
    # rein_config_lineage_opts: never print a flat command line when naming cannot be
    # resolved). The user only needs to append whatever common options they're already
    # passing.
    # **Scope, for the same reason, doesn't fall back to a default either** -- at this stage
    # the config layer hasn't been read yet, so which layer a value lives in isn't decided
    # (rein_config_scope_opt can't be used here). Both layers are named literally, and it's
    # the user who picks one -- never silently hand them a line aimed at the project layer.
    if rein_config_has_dynamic_default "$key"; then
      REIN_CONFIG_ERROR="${flag} cannot take an empty value (to disable it: config set --user ${key} \"\" or config set --project ${key} \"\"; to fall back to the default: config unset --user ${key} or config unset --project ${key} -- either way, name the layer that holds the value)"
    else
      REIN_CONFIG_ERROR="${flag} cannot take an empty value (to disable it, run config unset --user ${key} or config unset --project ${key} -- config list's origin column shows which layer holds the value)"
    fi
    return 1
  fi
  return 0
}

# The CLI flag layer. A value a subcommand received goes in here, and it wins over an environment variable.
rein_config_override() {
  local key="$1" value="$2"
  if ! rein_config_validate_value "$key" "$value"; then
    return 1
  fi
  rein_config_assign "$key" "$value" "cli"
}

# Carries forward that the resolved location failed its format checks (absolute path, no
# embedded newlines) to the next load (several call sites never look at this function's
# return value, so failing is centralized in the layer reader, rein_config_load_layers. A
# call site that never reads layers -- the decision verbs -- checks this value itself).
REIN_CONFIG_RESOLVE_ERROR=""
# **The name rein is called by, filled into one line of instructions.** This layer has no
# material to check whether rein is on PATH (confirming that `command -v`'s result is this
# same implementation needs following a symlink, and only the entry point that runs before
# the shared library is loaded has that) so **the caller decides it** -- writing a bare
# `rein` here would instruct a machine that hasn't put it on PATH to run a command it can't.
# Kept as part of the same "resolved context" as the target cwd, because the writer that
# reads this value (rein_config_decision_hint) decides it in the same single resolution
# that reads REIN_CONFIG_CWD and REIN_CONFIG_USER_FILE -- no separate entry point is built
# to inject it later.
REIN_CONFIG_CMD=""
# The reason the user config's **foundation** couldn't be built (a machine with neither HOME
# nor XDG_CONFIG_HOME). Reading correctly proceeds as "no user config"; **only the write
# entry point** fails for this reason.
REIN_CONFIG_USER_BASE_ERROR=""
rein_config_resolve_files() {
  local cmd="$1" cwd="$2" base
  REIN_CONFIG_CMD="$cmd"
  REIN_CONFIG_CWD="$cwd"
  REIN_CONFIG_RESOLVE_ERROR=""
  REIN_CONFIG_USER_BASE_ERROR=""
  # The target changed -- content already read in full belongs to a different lineage.
  # Carrying it forward would judge the swapped-in cwd using the previous cwd's content.
  rein_config_project_close
  # The records location is decided as a pair with cwd, so the previous lineage's value is
  # discarded every time cwd is swapped in (carrying it forward would hand out something
  # next to a different lineage's records as "this lineage's canonical source").
  REIN_CONFIG_RECORDS_DIR="${3:-}"
  # The foundation is judged by **one shared predicate**. Writing out
  # `${XDG_CONFIG_HOME:-${HOME:-}/.config}` by hand collapsed the foundation to `/.config`
  # on a machine where HOME is empty or unset (over launchd, over an ssh session with a
  # stripped environment, in a hook process that inherits it), and since that starts with
  # `/`, it passed the absolute-path check below.
  #
  # **"No material at all" and "given, but unusable" are kept apart.** The former has no
  # material given at all, so "no user config" is a correct judgment, not a guess -- and
  # failing the whole load there would break the silent pass (this mechanism's basic
  # contract), where **hooks fire on every event even for a project that never stood up a
  # lineage**, for every project on the machine. The latter (a relative XDG_CONFIG_HOME, a
  # relative HOME) fails instead, since the user did point at a location and it is never
  # read as "none" on a guess.
  if [ -n "${REIN_CONFIG_FILE:-}" ]; then
    REIN_CONFIG_USER_FILE="$REIN_CONFIG_FILE"
  elif [ -z "${XDG_CONFIG_HOME:-}" ] && [ -z "${HOME:-}" ]; then
    # A machine with no material at all. Never lets the collapsed `/.config/rein/config` be
    # **read as the user config** (the root belongs to no one in particular, and someone else
    # can place a file there), leaving the location empty. Only the write entry points
    # (`config set --user` and the decision ledger) fail-loud for this reason -- never let it
    # write to under the collapsed root and fail with "cannot create it",
    # **a reason far removed from the cause**. The reason's wording
    # also comes from the predicate (the same fact is never stated two different ways).
    rein_xdg_base "" XDG_CONFIG_HOME .config "the user config"
    REIN_CONFIG_USER_FILE=""
    REIN_CONFIG_USER_BASE_ERROR="$REIN_XDG_BASE_ERROR"
  elif rein_xdg_base "${XDG_CONFIG_HOME:-}" XDG_CONFIG_HOME .config "the user config"; then
    base="$REIN_XDG_BASE"
    REIN_CONFIG_USER_FILE="${base}/rein/config"
  else
    REIN_CONFIG_USER_FILE=""
    REIN_CONFIG_RESOLVE_ERROR="$REIN_XDG_BASE_ERROR"
    return 1
  fi
  REIN_CONFIG_PROJECT_FILE="${cwd}/.rein/config"
  # **A path containing a newline (LF / CR) is never accepted.** macOS places no
  # restriction on newlines in a pathname, so a location's path can genuinely contain one
  # ("a path can't contain a newline" is wrong -- it's reproducible). Project config
  # decisions travel through a one-line-per-entry ledger (rein_config_allow_lookup), so
  # an LF in the path would split one decision into two logical lines, and a CR would get
  # lost at the end of a line and throw off literal comparison.
  # LF specifically doesn't reach the ledger today, but only because macOS's shasum
  # prints a filename containing a newline with a leading backslash and escapes, and
  # rein_config_digest then fails as "not 64 hex digits" -- nothing but an accidental wall
  # that leans on an external command's output convention (and the reason masquerades as
  # "shasum is unavailable"). The ledger is a record that guards whether clone-bundled
  # settings may take effect, so this fails at the **entry point**, before a decision is
  # recorded -- guaranteeing, here and not by format or accident, that no path entering the
  # ledger contains a newline.
  case "$REIN_CONFIG_USER_FILE" in
    *$'\n'* | *$'\r'*)
      printf -v REIN_CONFIG_RESOLVE_ERROR 'the user config location contains a newline: %s (XDG_CONFIG_HOME or REIN_CONFIG_FILE has a path with a newline in it)' \
        "$REIN_CONFIG_USER_FILE"
      return 1
      ;;
  esac
  case "$REIN_CONFIG_PROJECT_FILE" in
    *$'\n'* | *$'\r'*)
      printf -v REIN_CONFIG_RESOLVE_ERROR 'the target directory path contains a newline: %s (project settings allow decisions are one entry per line, so a path with a newline cannot keep a decision boundary intact)' \
        "$cwd"
      return 1
      ;;
  esac
  # By the same discipline as resolving the runtime directory (rein_resolve_runtime_dir),
  # the user config's location is **also restricted to an absolute path**. A relative one
  # would become a different file for each reader's current directory (the CLI -- the
  # user's own shell; the watcher -- wherever nohup started; hooks -- wherever the launcher
  # started), and a reader would silently pass through an absent file as "no user config"
  # while a writer (`config set -u`) creates a new file at a location relative to wherever
  # it was run -- leaving no agreement, within the same lineage, on who read which config.
  case "$REIN_CONFIG_USER_FILE" in
    /*) return 0 ;;
  esac
  # A machine whose foundation couldn't be built leaves the location **empty** (not relative),
  # so it's out of scope for this check. Failing here would break the split above ("reading
  # proceeds as none; only the write entry point fails"), breaking the silent pass for
  # hooks on every project on the machine (the reason is carried to the write entry point by
  # REIN_CONFIG_USER_BASE_ERROR).
  if [ -z "$REIN_CONFIG_USER_FILE" ] && [ -n "$REIN_CONFIG_USER_BASE_ERROR" ]; then
    return 0
  fi
  printf -v REIN_CONFIG_RESOLVE_ERROR 'the user config location is not an absolute path: %s (XDG_CONFIG_HOME or REIN_CONFIG_FILE has a relative path in it)' \
    "$REIN_CONFIG_USER_FILE"
  return 1
}

# A project config can be bundled into a cloned repository -- **whoever wrote it isn't
# necessarily the user**. As a layer it's stronger than the user config, and it can set
# `settings` (the successor session's launch settings), `model`, `kickoff_note_path`, and even
# `runtime_dir` -- so its mere presence never makes it take effect. Following the same
# discipline as direnv, **the content's hash is recorded on the user's side, and an explicit
# decision (`rein config allow` / `rein config deny`) is required the first time and whenever
# the content changes**.
#
# There are two decisions. **allow -- let that content take effect as a layer.** **deny --
# proceed without applying that content.** Without deny, a clone that bundles an untrusted
# project config would leave only "allow it, or delete a file git is tracking" as an escape
# hatch -- neither matches the user's intent. After a deny, the CLI verbs, hooks, and
# statusline all run **silently** without the project layer -- it never sounds off to the
# user who made that decision on every run.
#
# The content is checked by hash rather than path or mtime, because neither catches "the
# content at the same location got swapped out" (clone, pull, and checkout all swap content
# in place). **A deny is tied to content too** -- if the content changes after a deny, the
# decision lapses and it reverts to undecided (fail-loud).
#
# **This gate defends against a project layer bundled by the repository, not against someone
# who can write environment variables** -- the environment layer already outranks the project
# layer, so this gate adds no defense against someone who can write `REIN_SETTINGS`. That's
# why recording an allow decision next to the user config, which moves with the environment,
# is enough.
REIN_PROJECT_ALLOW_FILE=""
REIN_PROJECT_ALLOW_ERROR=""
REIN_PROJECT_ALLOW_REASON=""
REIN_PROJECT_ALLOW_DIGEST=""
REIN_PROJECT_ALLOW_RECORDED=""
REIN_PROJECT_ALLOW_DECISION=""

# Where the decision ledger lives (next to the user config). A lineage whose user-side
# location was moved with `--root` or `--config` carries its decisions along with it -- each
# lineage keeps its own, closed set.
rein_config_allow_file() {
  REIN_PROJECT_ALLOW_FILE=""
  case "$REIN_CONFIG_USER_FILE" in
    */?*) ;;
    *) return 1 ;;
  esac
  REIN_PROJECT_ALLOW_FILE="${REIN_CONFIG_USER_FILE%/*}/${REIN_PROJECT_ALLOW_BASENAME}"
  return 0
}

rein_config_digest() {
  local file="$1" out
  REIN_PROJECT_ALLOW_DIGEST=""
  out="$(shasum -a 256 "$file" 2>/dev/null)" || return 1
  rein_config_digest_take "$out"
}

# Take a digest from content already read in full. Passes **content, not a path**, to
# `shasum` -- so the digest and what's displayed, parsed, and recorded all see the same
# bytes. The value itself is the same either way (a digest taken from standard input matches
# one taken by opening the file), so a decision already recorded in the ledger doesn't
# lapse.
rein_config_digest_text() {
  local text="$1" out
  REIN_PROJECT_ALLOW_DIGEST=""
  out="$(printf '%s' "$text" | shasum -a 256 2>/dev/null)" || return 1
  rein_config_digest_take "$out"
}

# Take just the 64 hex digits from a `shasum` line. **Keeps the acceptance discipline in one
# place** (if the path-based caller and the content-based caller diverged in strictness, only
# one of them would let malformed output through).
rein_config_digest_take() {
  local out="${1%% *}"
  case "$out" in
    '' | *[!0-9a-f]*) return 1 ;;
  esac
  [ "${#out}" -eq 64 ] || return 1
  REIN_PROJECT_ALLOW_DIGEST="$out"
  return 0
}

# Check one ledger line's shape and split it into decision, hash, and path. **Reader and
# writer go through the same one rule** -- never with only one side lenient (a line one side
# accepts that the other cannot read).
# The shape is `<decision> <64 hex digits> <absolute path>`. A path can contain spaces, so
# it's split on the first two spaces from the front.
# A line with a CR mixed in is also rejected -- a newline is the line boundary itself, so it
# cannot sit inside a field (a path containing a newline is already rejected at the entry
# point, rein_config_resolve_files, so it never reaches the ledger).
# **A blank line is rejected too.** It looks harmless, but there are two reasons not to let
# it through:
# (1) The "reader and writer go through the same rule" point above -- if only the reader
#     accepted a blank line, the writer's rewrite would drop it, silently changing the
#     ledger's shape.
# (2) A blank line **can be one surviving fragment of a path-with-newline record split
#     apart**. What's recorded in the ledger is `<cwd>/.rein/config`, so if cwd itself
#     contained consecutive newlines (`/a` + a blank line + `b`), one record would split into
#     three lines, and allowing the blank line would let just the middle one through
#     silently (the entry point already rejects a path with a newline, so this never actually
#     reaches the ledger today, but allowing a blank line would weaken detection of this
#     split by one line).
# 0 = read (the result is loaded into REIN_PROJECT_ALLOW_LINE_*) / 1 = cannot read
REIN_PROJECT_ALLOW_LINE_DECISION=""
REIN_PROJECT_ALLOW_LINE_DIGEST=""
REIN_PROJECT_ALLOW_LINE_PATH=""
rein_config_allow_line_parse() {
  local line="$1" rest
  REIN_PROJECT_ALLOW_LINE_DECISION=""
  REIN_PROJECT_ALLOW_LINE_DIGEST=""
  REIN_PROJECT_ALLOW_LINE_PATH=""
  case "$line" in
    *$'\r'*) return 1 ;;
    'allow '* | 'deny '*) ;;
    *) return 1 ;;
  esac
  rest="${line#* }"
  case "$rest" in
    *' '*) ;;
    *) return 1 ;;
  esac
  REIN_PROJECT_ALLOW_LINE_DECISION="${line%% *}"
  REIN_PROJECT_ALLOW_LINE_DIGEST="${rest%% *}"
  REIN_PROJECT_ALLOW_LINE_PATH="${rest#* }"
  case "$REIN_PROJECT_ALLOW_LINE_DIGEST" in
    *[!0-9a-f]*) return 1 ;;
  esac
  [ "${#REIN_PROJECT_ALLOW_LINE_DIGEST}" -eq 64 ] || return 1
  case "$REIN_PROJECT_ALLOW_LINE_PATH" in
    /*) ;;
    *) return 1 ;;
  esac
  return 0
}

# Lines carried over into a rewrite (decisions for paths other than the one being queried).
# Only accumulated when the second argument is `keep` -- hooks go through this function on
# every read, so material only a writer needs isn't built by default.
REIN_PROJECT_ALLOW_KEEP=""

# Look up a queried path's decision from the ledger. When multiple lines share the same
# path (a hand-edited ledger), the last one wins.
# **An unreadable line is never skipped.** Skipping it would let an allow through without
# distinguishing an injected line from a legitimate one (the ledger is a record that
# guards whether clone-bundled settings may take effect, so its verdict is never continued on
# a guess when it holds an unreadable line). One unreadable line reverts the whole ledger
# to undecided.
#
# **Failing to open it (the read never running at all) is never read as "zero decisions
# exist".** Even when input redirection fails, bash proceeds past the loop body without
# running it, so a bare `done <"$file"` gives a ledger that couldn't be read -- because of
# a permission mix-up or a filesystem error -- the same face as an empty ledger (observed:
# with the ledger chmod'd to 000, `config allow` returned rc=0, announced "allowed", and
# every other project's decisions vanished). The same discipline as rein_config_open_file:
# detected by whether the exit-status variable stays unset.
# 0 = read / 1 = an unreadable line exists (reason in REIN_PROJECT_ALLOW_REASON) /
# 2 = the ledger itself cannot be read (reason in REIN_PROJECT_ALLOW_ERROR)
rein_config_allow_lookup() {
  local file="$1" keep="${2:-}" line lineno=0 opened=""
  REIN_PROJECT_ALLOW_RECORDED=""
  REIN_PROJECT_ALLOW_DECISION=""
  REIN_PROJECT_ALLOW_KEEP=""
  [ -f "$REIN_PROJECT_ALLOW_FILE" ] || return 0
  # Redirect standard error **before** reopening the input (these are processed in order, so
  # placing it after would leak the shell's own English diagnostic on a failed open to the
  # caller's standard error).
  {
    opened=1
    while IFS= read -r line || [ -n "$line" ]; do
      lineno=$((lineno + 1))
      if ! rein_config_allow_line_parse "$line"; then
        REIN_PROJECT_ALLOW_RECORDED=""
        REIN_PROJECT_ALLOW_DECISION=""
        REIN_PROJECT_ALLOW_KEEP=""
        # A blank line is **named explicitly as a blank line**. If a user follows the
        # instructions to clear the ledger's content and their editor leaves a trailing
        # newline, the file looks empty but would be told "line 1 is unreadable", leading them
        # to repeat the same action (a one-byte, newline-only ledger is not the same thing
        # as a zero-byte one).
        if [ -z "$line" ]; then
          printf -v REIN_PROJECT_ALLOW_REASON 'the decision ledger has a blank line (%s, line %d)' \
            "$REIN_PROJECT_ALLOW_FILE" "$lineno"
        else
          printf -v REIN_PROJECT_ALLOW_REASON 'the decision ledger has an unreadable line (%s, line %d)' \
            "$REIN_PROJECT_ALLOW_FILE" "$lineno"
        fi
        return 1
      fi
      if [ "$REIN_PROJECT_ALLOW_LINE_PATH" != "$file" ]; then
        [ "$keep" = "keep" ] &&
          REIN_PROJECT_ALLOW_KEEP="${REIN_PROJECT_ALLOW_KEEP}${line}"$'\n'
        continue
      fi
      REIN_PROJECT_ALLOW_DECISION="$REIN_PROJECT_ALLOW_LINE_DECISION"
      REIN_PROJECT_ALLOW_RECORDED="$REIN_PROJECT_ALLOW_LINE_DIGEST"
    done
  } 2>/dev/null <"$REIN_PROJECT_ALLOW_FILE"
  if [ -z "$opened" ]; then
    REIN_PROJECT_ALLOW_RECORDED=""
    REIN_PROJECT_ALLOW_DECISION=""
    REIN_PROJECT_ALLOW_KEEP=""
    # Used by both the reader (reverts to undecided) and the writer (fails without
    # recording), so the reason goes into both variables with the same wording.
    printf -v REIN_PROJECT_ALLOW_REASON 'cannot read the decision ledger (%s)' "$REIN_PROJECT_ALLOW_FILE"
    printf -v REIN_PROJECT_ALLOW_ERROR 'cannot read the decision ledger (cannot judge or record an allow decision): %s' \
      "$REIN_PROJECT_ALLOW_FILE"
    return 2
  fi
  return 0
}

# Judging the allow decision (the content digest), what the decision verbs print to the
# screen, parsing whether it's valid as a setting, and the digest recorded in the ledger
# **all have to see the same bytes within the same command**. Reopening a path can catch a
# different content on each open (a rename-based replacement is atomic, so a single read is
# guaranteed to catch one side or the other whole, but which side is decided independently
# for each open). Observed: in 12 of 200 runs of `config get`, **content that had
# never been allowed was applied as the project layer**; in 18 of 60 runs of `config allow`,
# **a digest of content different from what was shown on screen was recorded in the
# ledger**. The replacing side is a blind rename loop that observes nothing about rein's
# execution (the same shape as an editor's save or `git checkout`) -- no adversary aiming to
# swap it out is required.
# **The loss runs in one direction only** -- for the same mismatch, the side that reverts to
# undecided, and the side where the ledger ends up recording what was actually allowed,
# are both safe (just decide again). The actual harm is the two forms above: **content that
# was never allowed takes effect as a layer**, or **content different from what was shown on
# screen gets recorded as allowed**. When the same kind of mismatch turns up in another layer
# (the ledger, a pointer), reuse this direction analysis instead of redoing it.
#
# Bytes read in full are **kept in a shell variable** (never copied to a temp file): hooks
# read this layer on every tool call, so copying it would add two external commands to the
# silent pass (at odds with rein-hook.sh's opening rule, "never create a temp file, never
# spawn mktemp"). Keeping it in a variable adds no external command at all, and never puts
# plaintext settings back onto disk.
REIN_CONFIG_PROJECT_HELD=0
REIN_CONFIG_PROJECT_TEXT=""
REIN_CONFIG_PROJECT_PRESENT=0

# 0 = open (PRESENT=1 means content is in TEXT) / 1 = cannot read (reason in REIN_CONFIG_ERROR)
rein_config_project_open() {
  local file="$REIN_CONFIG_PROJECT_FILE"
  [ "$REIN_CONFIG_PROJECT_HELD" -eq 1 ] && return 0
  REIN_CONFIG_PROJECT_TEXT=""
  REIN_CONFIG_PROJECT_PRESENT=0
  REIN_CONFIG_PROJECT_HELD=1
  # A form that isn't a regular file (absent, a directory, a broken symlink) is never read
  # here -- each reader judges it for its own reason (the allow gate lets it through; the
  # parser is what fails).
  [ -f "$file" ] || return 0
  if ! rein_config_open_file "$file"; then
    REIN_CONFIG_PROJECT_HELD=0
    return 1
  fi
  REIN_CONFIG_PROJECT_TEXT="$REIN_CONFIG_READ_TEXT"
  REIN_CONFIG_PROJECT_PRESENT="$REIN_CONFIG_READ_PRESENT"
  return 0
}

# Discard the content read in full. Called **only at a boundary where the target changes**
# (re-resolving cwd, the entry point of loading layers, before and after a rewrite) -- never
# discarded between one decision and its application.
rein_config_project_close() {
  REIN_CONFIG_PROJECT_HELD=0
  REIN_CONFIG_PROJECT_TEXT=""
  REIN_CONFIG_PROJECT_PRESENT=0
}

# Take the project layer's digest from content already read in full, **never reopened**. A
# caller passing a path other than the project layer (the entry point each script's checks
# use to allow a fixture) still takes it from the path, as before.
rein_config_project_digest() {
  local file="$1"
  if [ "$file" = "$REIN_CONFIG_PROJECT_FILE" ]; then
    rein_config_project_open || return 1
    if [ "$REIN_CONFIG_PROJECT_PRESENT" -eq 1 ]; then
      rein_config_digest_text "$REIN_CONFIG_PROJECT_TEXT"
      return $?
    fi
  fi
  rein_config_digest "$file"
}

# Parse the project layer. Reads from the same content the allow gate digested.
rein_config_parse_project() {
  rein_config_project_open || return 1
  if [ "$REIN_CONFIG_PROJECT_PRESENT" -eq 1 ]; then
    rein_config_shown_path "$REIN_CONFIG_PROJECT_FILE"
    rein_config_parse_text "$REIN_CONFIG_PROJECT_TEXT" "project" "$REIN_CONFIG_SHOWN_PATH"
    return $?
  fi
  # A form where there's nothing to read (absent, a directory, a broken symlink) still fails
  # for the reader's own reason, as before (absent is normal -- 0).
  rein_config_parse_file "$REIN_CONFIG_PROJECT_FILE" "project"
}

# Replace a control character in a line printed to the screen with the same `^`-prefixed
# notation `cat -v` uses (shown, not removed -- removing it would also remove the fact that
# something was there, and even announcing the substitution would leave no way to check it).
# **Not one byte of what the decision and the record see changes** -- only the displayed copy
# is substituted.
# Because a project config can be bundled into a clone, the allow gate's consent rests
# entirely on "show the content on screen, then record it". Planting an ESC (0x1B) cursor-move
# or erase sequence in a value or a comment could erase the line just printed from the screen
# and still get an allow typed in (`settings` is the successor session's launch settings,
# which can carry hooks -- reaching all the way to arbitrary command execution). The value's
# type check doesn't close this off -- `settings` is of type string, and that type
# unconditionally passes anything but a newline.
# NUL is already rejected by the read layer, and LF is the line boundary itself, so neither
# survives into a single line at this point.
# **TAB (0x09) is not included.** `cat -v` passes TAB through unchanged too, and TAB has no
# power to erase characters already printed or rewind the screen -- it only advances a column.
# Including it would raise the warning below even for a harmless setting that merely indents
# a value or comment with a TAB, and **the warning firing would stop being a signal that "this
# setting is unusual"**. This choice is pinned by the selftest case "TAB is not replaced".
REIN_CONFIG_CTRL_CHARS=$'\001\002\003\004\005\006\007\010\012\013\014\015\016\017\020\021\022\023\024\025\026\027\030\031\032\033\034\035\036\037\177'
# 0x01-0x1F becomes `^` plus the character at that code point's position in this string (0x1B -> `^[`); DEL alone becomes `^?`.
REIN_CONFIG_CTRL_CARETS='@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\]^_'
REIN_CONFIG_VISIBLE_TEXT=""
REIN_CONFIG_VISIBLE_CHANGED=0
rein_config_visible_line() {
  local rest="$1" out="" head ch code
  REIN_CONFIG_VISIBLE_TEXT=""
  REIN_CONFIG_VISIBLE_CHANGED=0
  while :; do
    case "$rest" in
      *["$REIN_CONFIG_CTRL_CHARS"]*) ;;
      *)
        REIN_CONFIG_VISIBLE_TEXT="${out}${rest}"
        return 0
        ;;
    esac
    head="${rest%%["$REIN_CONFIG_CTRL_CHARS"]*}"
    rest="${rest#"$head"}"
    ch="${rest:0:1}"
    printf -v code '%d' "'$ch"
    if [ "$code" -eq 127 ]; then
      out="${out}${head}^?"
    else
      out="${out}${head}^${REIN_CONFIG_CTRL_CARETS:code:1}"
    fi
    rest="${rest:1}"
    REIN_CONFIG_VISIBLE_CHANGED=1
  done
}

# Visibility substitution covers every entry point that **prints config-derived bytes to the
# screen**, not just the content lines. The decision screen's consent rests entirely on
# "allow whatever was shown", so leaving even one entry point uncovered lets a display spoof
# through there. Two entry points were actually left uncovered: (a) the path line printed
# **before** the content lines (`resolves to: ` shows a symlink's target, and an attacker
# chooses the file name), and (b) the reason text when the validity check fails after the
# content is shown (an unknown key or a type violation puts the key or value in **verbatim**).
# Whether a substitution happened even once is carried in REIN_CONFIG_SHOWN_ESCAPED, and the
# caller announces it within that same run (silently fixing it would let a doctored display
# be read as "the unmodified content").
REIN_CONFIG_SHOWN_ESCAPED=0
REIN_CONFIG_VISIBLE_REASON=""

# Print a label (fixed wording the implementation owns) plus one config-derived line, after visibility substitution.
rein_config_show_line() {
  local label="$1"
  rein_config_visible_line "$2"
  if [ "$REIN_CONFIG_VISIBLE_CHANGED" -eq 1 ]; then
    REIN_CONFIG_SHOWN_ESCAPED=1
  fi
  printf '%s%s\n' "$label" "$REIN_CONFIG_VISIBLE_TEXT"
}

# Run visibility substitution on a failure's reason text and put it in
# REIN_CONFIG_VISIBLE_REASON (the caller owns `fail`'s formatting, so this only hands the
# text over rather than printing it).
rein_config_visible_reason() {
  rein_config_visible_line "$1"
  if [ "$REIN_CONFIG_VISIBLE_CHANGED" -eq 1 ]; then
    REIN_CONFIG_SHOWN_ESCAPED=1
  fi
  REIN_CONFIG_VISIBLE_REASON="$REIN_CONFIG_VISIBLE_TEXT"
}

# The cap on **how much** the consent screen shows. Even without a single control character,
# bundling thousands of lines of comments can push a `settings=` line above the scrollback --
# the same result as removing a line from the display -- so both the line count and each
# line's length are capped. The caller announces the truncation loudly (silently truncating
# would let the push-out masquerade as "a short setting").
# Where the numbers come from -- there are 26 known keys, so writing every key on its own
# line with a one-line annotation each, plus a blank separator line, still fits in 78 lines
# (100 is 1.3 times that). The per-line cap can run long, since `settings` can carry the
# successor's launch settings JSON directly, but 500 characters fits JSON with env and hooks
# side by side, wrapping to about 6 lines on an 80-column terminal (beyond that it can't be
# read as one line anyway).
REIN_CONFIG_PRINT_MAX_LINES=100
REIN_CONFIG_PRINT_MAX_COLS=500
REIN_CONFIG_PRINT_CLIP_MARK='...(this line was cut here)'

# Print the decision target's content line by line, from the same bytes the allow judgment
# saw. Returns the number of lines shown, the total, and how many were truncated to the
# caller (not one byte of what the decision and the record see changes -- both truncation and
# substitution touch only the displayed copy).
REIN_CONFIG_PROJECT_PRINT_TOTAL=0
REIN_CONFIG_PROJECT_PRINT_SHOWN=0
REIN_CONFIG_PROJECT_PRINT_CLIPPED=0
rein_config_project_print_lines() {
  local prefix="$1" i=0 text
  REIN_CONFIG_PROJECT_PRINT_CLIPPED=0
  rein_config_split_lines "$REIN_CONFIG_PROJECT_TEXT"
  REIN_CONFIG_PROJECT_PRINT_TOTAL=${#REIN_CONFIG_LINES[@]}
  REIN_CONFIG_PROJECT_PRINT_SHOWN=$REIN_CONFIG_PROJECT_PRINT_TOTAL
  if [ "$REIN_CONFIG_PROJECT_PRINT_SHOWN" -gt "$REIN_CONFIG_PRINT_MAX_LINES" ]; then
    REIN_CONFIG_PROJECT_PRINT_SHOWN=$REIN_CONFIG_PRINT_MAX_LINES
  fi
  while [ "$i" -lt "$REIN_CONFIG_PROJECT_PRINT_SHOWN" ]; do
    rein_config_visible_line "${REIN_CONFIG_LINES[$i]}"
    if [ "$REIN_CONFIG_VISIBLE_CHANGED" -eq 1 ]; then
      REIN_CONFIG_SHOWN_ESCAPED=1
    fi
    text="$REIN_CONFIG_VISIBLE_TEXT"
    # The length cap applies **to the visibility-substituted copy** (substitution can expand
    # one byte to two characters, so measuring the raw side would let what reaches the screen
    # exceed the cap).
    if [ "${#text}" -gt "$REIN_CONFIG_PRINT_MAX_COLS" ]; then
      text="${text:0:$REIN_CONFIG_PRINT_MAX_COLS}$REIN_CONFIG_PRINT_CLIP_MARK"
      REIN_CONFIG_PROJECT_PRINT_CLIPPED=$((REIN_CONFIG_PROJECT_PRINT_CLIPPED + 1))
    fi
    printf '%s%s\n' "$prefix" "$text"
    i=$((i + 1))
  done
}

# Whether the project config may take effect. **Only this one function holds the judgment**
# (writing it separately per reader is how "just this one reader silently lets it take effect"
# comes about -- exactly the failure prune actually had).
# 0 = may take effect (including when there is no project config) / 1 = undecided (reason in
# REIN_PROJECT_ALLOW_REASON) / 2 = cannot be judged (reason in REIN_PROJECT_ALLOW_ERROR) /
# 3 = deny is already decided
rein_config_project_allowed() {
  local file="$REIN_CONFIG_PROJECT_FILE"
  REIN_PROJECT_ALLOW_REASON=""
  REIN_PROJECT_ALLOW_ERROR=""
  REIN_PROJECT_ALLOW_DIGEST=""
  REIN_PROJECT_ALLOW_RECORDED=""
  REIN_PROJECT_ALLOW_DECISION=""
  # A form that isn't a regular file (absent, a directory) isn't judged here -- the reader
  # fails for its own reason. Failing here too would give the one anomaly two reasons.
  # **The exception is a broken symlink.** Falling into the same branch as "absent" means the
  # reader also reads it as "absent" via `-e`, so nothing fails, and the `config set` writer
  # creates the real file at the target (which can be outside the project) without ever going
  # through consent -- **the one anomaly that can fall on the wrong, permissive side** -- so
  # it's caught here.
  if [ -L "$file" ] && [ ! -e "$file" ]; then
    REIN_PROJECT_ALLOW_REASON="the location is a broken symbolic link (the target doesn't exist -- fix the link or remove it)"
    return 1
  fi
  # Read in full exactly once here -- the digest, display, parse, and record that follow all see this content.
  if ! rein_config_project_open; then
    REIN_PROJECT_ALLOW_ERROR="$REIN_CONFIG_ERROR"
    return 2
  fi
  [ "$REIN_CONFIG_PROJECT_PRESENT" -eq 1 ] || return 0
  if ! rein_config_allow_file; then
    REIN_PROJECT_ALLOW_ERROR="cannot resolve where to record an allow decision (${REIN_CONFIG_USER_BASE_ERROR:-the user config location is not decided})"
    return 2
  fi
  if ! rein_config_digest_text "$REIN_CONFIG_PROJECT_TEXT"; then
    REIN_PROJECT_ALLOW_ERROR="cannot digest the project config's content (shasum is unavailable): ${file}"
    return 2
  fi
  # A ledger with an unreadable line is undecided (the reason comes from lookup) -- never
  # falls to the permissive side.
  # **Failing to open the ledger at all also reverts to undecided** (not to rc=2, "cannot
  # be judged"). The point is never reading "already allowed" out of material that can't be
  # judged, and undecided is enough for that. Making this rc=2 instead would stop a passive
  # context (hooks, statusline) from proceeding without the layer, failing every session
  # event over one broken ledger. **Only the writer** watches for lookup's rc=2 and stops
  # without recording.
  rein_config_allow_lookup "$file" || return 1
  if [ -z "$REIN_PROJECT_ALLOW_DECISION" ]; then
    REIN_PROJECT_ALLOW_REASON="not yet allowed"
    return 1
  fi
  # A decision is tied to content -- if the content changes, either an allow or a deny lapses and reverts to undecided.
  if [ "$REIN_PROJECT_ALLOW_RECORDED" != "$REIN_PROJECT_ALLOW_DIGEST" ]; then
    if [ "$REIN_PROJECT_ALLOW_DECISION" = "deny" ]; then
      REIN_PROJECT_ALLOW_REASON="the content changed after it was denied"
    else
      REIN_PROJECT_ALLOW_REASON="the content changed after it was allowed"
    fi
    return 1
  fi
  case "$REIN_PROJECT_ALLOW_DECISION" in
    allow) return 0 ;;
    deny) return 3 ;;
  esac
  # An unreadable decision falls to **the non-permissive side** (never let a hand-broken
  # ledger make the layer take effect).
  REIN_PROJECT_ALLOW_REASON="cannot read the recorded decision (decide again)"
  return 1
}

# Mutual exclusion for the ledger's read-modify-write. The ledger is **one file next to
# the user config**, and it holds decisions for every project sharing that user config -- so
# recording decisions for two different projects at nearly the same moment from two different
# terminals lets whichever side does the later `mv` overwrite the ledger with content that
# doesn't include the earlier decision. Observed: one side's decision vanished in 24 of 25
# runs; in 9 of 15 of those runs **the side that vanished was a deny, leaving an old allow in
# effect** (clone-bundled settings that were decided against continue to take effect as a
# layer, silently falling toward the unsafe direction). The window isn't milliseconds but
# "from reading the ledger to the mv" -- the entire command's run time -- so the writer
# being a single function doesn't serialize it on its own.
# How the lock is acquired, how ownership is declared, and how staleness is judged all go
# through the same one shared-library lock used elsewhere (writing that judgment separately
# would let just this one place drift from the "never seize" discipline).
REIN_CONFIG_LEDGER_LOCK=""
# How long to wait. The owner only ever holds it for rewriting one file (millisecond-scale),
# so contention resolves within that range. A wait that times out **fails rather than
# guessing and writing anyway** (a silent overwrite would recreate exactly the loss this was
# built to close).
REIN_CONFIG_LEDGER_LOCK_WAIT_SEC=5
rein_config_ledger_lock() {
  local lock="${REIN_PROJECT_ALLOW_FILE}.lock" start i=0 limit rc
  REIN_CONFIG_LEDGER_LOCK=""
  start="$(rein_process_start_identity "$$")"
  limit=$((REIN_CONFIG_LEDGER_LOCK_WAIT_SEC * 20))
  while :; do
    rein_claim_lock_dir_or_reclaim "$lock" \
      start "$start" \
      cwd "$REIN_CONFIG_CWD" \
      mode "$REIN_LOCK_MODE_OP"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      REIN_CONFIG_LEDGER_LOCK="$lock"
      return 0
    fi
    if [ "$rc" -eq 1 ]; then
      REIN_PROJECT_ALLOW_ERROR="cannot set up the decision ledger's lock: ${lock}"
      return 1
    fi
    i=$((i + 1))
    [ "$i" -lt "$limit" ] || break
    sleep 0.05
  done
  REIN_PROJECT_ALLOW_ERROR="waited ${REIN_CONFIG_LEDGER_LOCK_WAIT_SEC} seconds and still could not acquire the decision ledger's lock (another rein is recording a decision): ${lock}"
  return 1
}

rein_config_ledger_unlock() {
  [ -n "$REIN_CONFIG_LEDGER_LOCK" ] || return 0
  rein_release_lock_dir "$REIN_CONFIG_LEDGER_LOCK"
  REIN_CONFIG_LEDGER_LOCK=""
  return 0
}

# Record a decision (drops an older line for the same path, keeping exactly one). **This is
# the ledger's only writer** -- the allow/deny verbs and rein's own rewrite (config set /
# unset) cleanup both go through this single entry point.
# $1 = decision (allow / deny), $2 = the project config's path.
# 0 = recorded / 1 = cannot write (reason in REIN_PROJECT_ALLOW_ERROR)
rein_config_decision_record() {
  local decision="$1" file="$2" dir rc
  REIN_PROJECT_ALLOW_ERROR=""
  case "$decision" in
    allow | deny) ;;
    *)
      REIN_PROJECT_ALLOW_ERROR="invalid decision value: ${decision}"
      return 1
      ;;
  esac
  if ! rein_config_allow_file; then
    REIN_PROJECT_ALLOW_ERROR="cannot resolve where to record an allow decision (${REIN_CONFIG_USER_BASE_ERROR:-the user config location is not decided})"
    return 1
  fi
  # Take the digest to record **without reopening** either (never let the displayed content
  # and the recorded digest become two different things).
  if ! rein_config_project_digest "$file"; then
    REIN_PROJECT_ALLOW_ERROR="cannot digest the project config's content (shasum is unavailable): ${file}"
    return 1
  fi
  dir="${REIN_PROJECT_ALLOW_FILE%/*}"
  # Prepare the location before the lock (the lock's temp directory is also created next to
  # the ledger).
  if ! mkdir -p "$dir"; then
    REIN_PROJECT_ALLOW_ERROR="cannot create ${dir}"
    return 1
  fi
  rein_config_ledger_lock || return 1
  rein_config_decision_write "$decision" "$file"
  rc=$?
  rein_config_ledger_unlock
  return "$rc"
}

# The ledger rewrite itself (called only while the lock is held). Reading and rewriting
# are closed inside one function so that no exit point along the way forgets to release the
# lock (releasing it happens at the one call site).
rein_config_decision_write() {
  local decision="$1" file="$2" tmp
  # Never write into a ledger that has an unreadable line. Doing so would leave that
  # line in place and revert to undecided again on the next read -- "I allowed it and it
  # still doesn't take effect" repeating. Silently dropping the unreadable line isn't taken
  # either (that would lose a recorded decision) -- fail, naming what to fix.
  # The same applies when the ledger itself cannot be opened (the reason comes from
  # lookup) -- reading an unreadable ledger as "an empty one" and writing it back would
  # replace every other lineage's decisions with that one line.
  rein_config_allow_lookup "$file" keep
  case $? in
    0) ;;
    2) return 1 ;;
    *)
      printf -v REIN_PROJECT_ALLOW_ERROR '%s (fix that line, or delete the whole ledger and decide again)' \
        "$REIN_PROJECT_ALLOW_REASON"
      return 1
      ;;
  esac
  # The ledger isn't JSON (it's the `allow <digest> <path>` line format), so it doesn't go
  # through the atomic-write primitive, but the replacement target's shape check runs the same
  # way: if the destination is a directory, `mv` moves the file inside it and returns 0,
  # displaying "allowed" while no decision survives at all (reverting to undecided on the
  # next read).
  if ! rein_dest_shape_ok "$REIN_PROJECT_ALLOW_FILE"; then
    REIN_PROJECT_ALLOW_ERROR="cannot write to the decision ledger: ${REIN_DEST_SHAPE_ERROR}"
    return 1
  fi
  tmp="$(mktemp "${REIN_PROJECT_ALLOW_FILE}.XXXXXX")" || {
    REIN_PROJECT_ALLOW_ERROR="cannot create a temp file for ${REIN_PROJECT_ALLOW_FILE}"
    return 1
  }
  chmod 600 "$tmp" 2>/dev/null
  # The lines kept are **whatever the read just before this brought back** (the ledger is
  # not reopened here). Reopening it would make a second read that fails indistinguishable
  # from "zero lines to keep", replacing the content with one that has dropped other
  # lineages' decisions (the discipline for detecting a failed read wouldn't close in one
  # place).
  if ! {
    [ -z "$REIN_PROJECT_ALLOW_KEEP" ] || printf '%s' "$REIN_PROJECT_ALLOW_KEEP"
    printf '%s %s %s\n' "$decision" "$REIN_PROJECT_ALLOW_DIGEST" "$file"
  } >"$tmp"; then
    rm -f "$tmp"
    REIN_PROJECT_ALLOW_ERROR="cannot write to ${REIN_PROJECT_ALLOW_FILE}"
    return 1
  fi
  if ! mv "$tmp" "$REIN_PROJECT_ALLOW_FILE"; then
    rm -f "$tmp"
    REIN_PROJECT_ALLOW_ERROR="cannot replace ${REIN_PROJECT_ALLOW_FILE}"
    return 1
  fi
  return 0
}

# Record an allow decision (the entry point used by `config allow` and by cleanup after rein's own rewrite).
rein_config_allow_record() {
  rein_config_decision_record allow "$1"
}

# How to handle an undecided project layer. **Never picked up from the environment** (doing
# so would let someone who can write env vars bypass the gate), so it unconditionally reverts
# to the mode's default at load time.
#   require = an undecided layer fails the whole load (CLI verbs, the watcher, the attach
#             loop, a handover request)
#   skip    = an undecided layer proceeds without applying the project layer (the passive
#             context of hooks and statusline -- never breaks the session; the reader prints
#             that it wasn't applied to standard error)
#   trust   = no gate at all (judging whether a candidate rein itself just built is valid --
#             before config set / unset saves it; a temp file by definition has no decision
#             yet, so gating here would block rein's own rewrite)
# **A deny "proceeds without applying" in every context, regardless of mode** (it's a result
# the user decided, so no notice fires either -- the NOTICE below stays empty. A reader sounds
# off only when NOTICE is non-empty).
REIN_CONFIG_PROJECT_MODE="require"
REIN_CONFIG_PROJECT_SKIPPED=0
REIN_CONFIG_PROJECT_NOTICE=""

# Instructions for the allow / deny decision. **Fill both runnable lines with the effective
# value** -- the decision ledger lives next to the user config (rein_config_allow_file), so
# printing a line that drops the naming would, for a lineage whose location moved, record the
# decision **to a different lineage's ledger**. The moved side keeps printing the same
# "not yet allowed" instructions, while the default location ends up with an allow for
# content the user never looked at (observed: typing exactly what was shown for a `--root`
# lineage recorded it to the default `<XDG>/rein/` ledger, leaving the original lineage
# still denied). Abbreviating just one side (deny) to `config deny` has the same hole -- the
# user who types the abbreviated side ends up running an unnamed line. Naming is resolved
# exactly once and distributed to both lines (never resolved twice from the same material).
# **When naming cannot be resolved, no flat command line is printed** (only a reason is
# returned).
# 0 = the instructions were built / 2 = the lineage's naming cannot be resolved (the reason
# also goes into REIN_CONFIG_DECISION_HINT)
# **The display name ($1) is passed in by the caller** (the same discipline as
# rein_handover_mismatch_detail).
REIN_CONFIG_DECISION_HINT=""
rein_config_decision_hint() {
  local cmd="$1" allow deny
  REIN_CONFIG_DECISION_HINT=""
  if ! rein_config_lineage_opts "$REIN_CONFIG_USER_FILE"; then
    printf -v REIN_CONFIG_DECISION_HINT '%s (check the effective value for this lineage before deciding)' \
      "$REIN_LINEAGE_ERROR"
    return 2
  fi
  rein_lineage_line "$cmd" "$REIN_CONFIG_CWD" config allow
  allow="$REIN_LINEAGE_CMD"
  rein_lineage_line "$cmd" "$REIN_CONFIG_CWD" config deny
  deny="$REIN_LINEAGE_CMD"
  printf -v REIN_CONFIG_DECISION_HINT 'to review the content and allow it, run %s; to decide against applying it, run %s' \
    "$allow" "$deny"
  return 0
}

rein_config_gate_project() {
  local rc
  if [ "$REIN_CONFIG_PROJECT_MODE" = "trust" ]; then
    return 0
  fi
  rein_config_project_allowed
  rc=$?
  if [ "$rc" -eq 0 ]; then
    return 0
  fi
  if [ "$rc" -eq 3 ]; then
    # A deny is already on record -- silently drop the layer (never sounds off to the user on
    # every run for a decision they already made).
    REIN_CONFIG_PROJECT_SKIPPED=1
    return 0
  fi
  if [ "$rc" -eq 2 ]; then
    REIN_CONFIG_ERROR="$REIN_PROJECT_ALLOW_ERROR"
    return 1
  fi
  rein_config_decision_hint "$REIN_CONFIG_CMD"
  if [ "$REIN_CONFIG_PROJECT_MODE" = "skip" ]; then
    REIN_CONFIG_PROJECT_SKIPPED=1
    printf -v REIN_CONFIG_PROJECT_NOTICE \
      'the project settings are not applied (%s): %s (%s)' \
      "$REIN_PROJECT_ALLOW_REASON" "$REIN_CONFIG_PROJECT_FILE" "$REIN_CONFIG_DECISION_HINT"
    return 0
  fi
  printf -v REIN_CONFIG_ERROR \
    'the project settings are not allowed (%s): %s (%s)' \
    "$REIN_PROJECT_ALLOW_REASON" "$REIN_CONFIG_PROJECT_FILE" "$REIN_CONFIG_DECISION_HINT"
  return 1
}

# Before an allow, confirm the content **is valid** as a setting (format, known keys, value
# types). Being able to allow invalid content would produce the form "the allow succeeded, but
# the very next verb fails on an unknown key".
#
# Checks **this file alone** -- never the combination of layers (cross-field). A combination
# can also break through a value on the user config's side, and fixing that side alone would
# make it valid again, so the decision "can this file be trusted" is never blocked by another
# layer's current state. Values read here aren't kept (the decision verb doesn't use the
# effective value, and the caller re-reads it anyway).
# 0 = valid / 1 = invalid (reason in REIN_CONFIG_ERROR)
rein_config_validate_project_file() {
  local rc
  rein_config_reset
  REIN_CONFIG_ERROR=""
  rein_config_parse_project
  rc=$?
  rein_config_reset
  return "$rc"
}

# Read the specified layers. $1 = whether to include environment variables (0/1), $2 = how
# far to read (user/project). A failure partway through leaves no partial application in
# place (a reader that caught a mixed set of values would see behavior it never remembers
# configuring). The loaded marker is only raised on success.
rein_config_load_layers() {
  local with_env="$1" upto="$2"
  rein_config_reset
  REIN_CONFIG_ERROR=""
  REIN_CONFIG_PROJECT_SKIPPED=0
  REIN_CONFIG_PROJECT_NOTICE=""
  # Every load sees the current content (carrying forward what a previous load caught would
  # make a re-read after rein's own rewrite see stale content). Within one load -- between
  # judging the allow decision and applying the layer -- nothing is discarded.
  rein_config_project_close
  # If resolving the location already failed its format check, fail here for that reason
  # without reading a single layer (silently passing that through as "no user config" would
  # run on some other, cwd-dependent file).
  if [ -n "$REIN_CONFIG_RESOLVE_ERROR" ]; then
    REIN_CONFIG_ERROR="$REIN_CONFIG_RESOLVE_ERROR"
    return 1
  fi
  if ! rein_config_parse_file "$REIN_CONFIG_USER_FILE" "user"; then
    rein_config_reset
    return 1
  fi
  if [ "$upto" = "project" ]; then
    # The allow gate runs **before reading** (reading first and discarding afterward would let a state holding unallowed values exist, if only for an instant).
    if ! rein_config_gate_project; then
      rein_config_reset
      return 1
    fi
    if [ "$REIN_CONFIG_PROJECT_SKIPPED" -eq 0 ] &&
      ! rein_config_parse_project; then
      rein_config_reset
      return 1
    fi
  fi
  if [ "$with_env" = "1" ]; then
    if ! rein_config_apply_env; then
      rein_config_reset
      return 1
    fi
  fi
  REIN_CONFIG_LOADED=1
  return 0
}

# Read every layer (never includes cross-field validation -- the caller applies that at whatever stage needs it).
rein_config_load_files() {
  rein_config_load_layers 1 project
}

rein_config_init() {
  local cmd="$1" cwd="$2"
  rein_config_resolve_files "$cmd" "$cwd"
  rein_config_load_files
}

rein_config_is_set() {
  local key="$1" var
  rein_config_lookup "$key" || return 1
  var="REIN_CFGO_${REIN_CFG_KEY_UPPER}"
  [ -n "${!var:-}" ]
}

# Resolve a default that tracks cwd (a default that can't live in the table -- see the
# "known-keys table" note above). Resolution goes through one shared-library function
# (rein_default_handoff_path), never rebuilt per call site. Handing out a default while cwd
# isn't decided would pass off a path unrelated to the target as canonical, so this fails
# rather than silently falling back to empty.
# The list of keys with a dynamic default (i.e. keys whose table default column is never
# used). **These are also the keys where `config unset` doesn't mean "disable"**, so the
# instructions that refuse an empty value (rein_config_check_opt) also decide their branching
# from this predicate -- the list is never kept in two places.
rein_config_has_dynamic_default() {
  case "$1" in
    handoff_path | usage_state_dir) return 0 ;;
  esac
  return 1
}

REIN_CFG_DEFAULT_VALUE=""
rein_config_dynamic_default() {
  local key="$1"
  if ! rein_config_has_dynamic_default "$key"; then
    REIN_CFG_DEFAULT_VALUE="$REIN_CFG_KEY_DEFAULT"
    return 0
  fi
  case "$key" in
    handoff_path)
      if [ -z "$REIN_CONFIG_CWD" ]; then
        REIN_CONFIG_ERROR="the target cwd for settings isn't decided (cannot resolve handoff_path's default)"
        return 1
      fi
      if ! rein_default_handoff_path "$REIN_CONFIG_CWD" "$REIN_CONFIG_RECORDS_DIR"; then
        REIN_CONFIG_ERROR="cannot resolve the handoff document's default location: ${REIN_CONFIG_CWD}"
        return 1
      fi
      REIN_CFG_DEFAULT_VALUE="$REIN_DEFAULT_HANDOFF_PATH"
      ;;
    usage_state_dir)
      # The default lives under the consuming side's (Claude Code's) state directory --
      # `~/.claude/state/context-usage` (this exact wording is pinned by
      # docs/spec/usage-state.md and by the selftest that checks the default against every
      # key, scripts/lib/cli/selftest/config.sh. **The known-keys table does not pin it** --
      # this default can't live in the table, so its default column is left empty).
      # **The shared predicate (rein_xdg_base) can't be reused here** -- its first material is
      # an XDG environment variable, and there is no environment variable for this default
      # (adding `CLAUDE_CONFIG_DIR` as material would move where the default lands, a separate
      # decision to make together with the docs' wording). Only the discipline of "never
      # collapse and silently pass through" is applied the same way -- a machine where HOME is
      # empty, unset, or relative never collapses to `/...`; it **fails right here** instead.
      if [ -z "${HOME:-}" ]; then
        REIN_CONFIG_ERROR="cannot build the usage record's default location (HOME isn't set). Set it explicitly with config's usage_state_dir"
        return 1
      fi
      case "$HOME" in
        /*) ;;
        *)
          REIN_CONFIG_ERROR="cannot build the usage record's default location (HOME is not an absolute path: ${HOME}). Set it explicitly with config's usage_state_dir"
          return 1
          ;;
      esac
      REIN_CFG_DEFAULT_VALUE="${HOME}/.claude/state/context-usage"
      ;;
    *)
      # A key added to the predicate whose resolution was forgotten here would, if silently
      # handed the table's (empty) default, masquerade as "unset -- unused". Since that
      # changes the meaning for every reader on every path, it fails instead.
      REIN_CONFIG_ERROR="no dynamic default resolution is implemented for: ${key}"
      return 1
      ;;
  esac
  return 0
}

# Load the effective value and its origin into REIN_CONFIG_VALUE / REIN_CONFIG_ORIGIN (never
# forks). Handing out a value while the load has failed would let the caller catch a partial
# application, or a silent fallback to the default.
rein_config_fetch() {
  local key="$1" value_var origin_var
  if [ "$REIN_CONFIG_LOADED" -ne 1 ]; then
    REIN_CONFIG_ERROR="settings have not been loaded"
    return 1
  fi
  if ! rein_config_lookup "$key"; then
    REIN_CONFIG_ERROR="unknown key: ${key}"
    return 1
  fi
  value_var="REIN_CFGV_${REIN_CFG_KEY_UPPER}"
  origin_var="REIN_CFGO_${REIN_CFG_KEY_UPPER}"
  if [ -n "${!origin_var:-}" ]; then
    REIN_CONFIG_VALUE="${!value_var:-}"
    REIN_CONFIG_ORIGIN="${!origin_var}"
  else
    rein_config_dynamic_default "$key" || return 1
    REIN_CONFIG_VALUE="$REIN_CFG_DEFAULT_VALUE"
    REIN_CONFIG_ORIGIN="default"
  fi
  return 0
}

rein_config_get() {
  rein_config_fetch "$1" || return 1
  printf '%s\n' "$REIN_CONFIG_VALUE"
}

rein_config_origin() {
  rein_config_fetch "$1" || return 1
  printf '%s\n' "$REIN_CONFIG_ORIGIN"
}

# The scope (`--user` / `--project`) named by the one line instructing `config set` /
# `config unset`. **Never instructs with the default scope left implicit** -- `config unset`'s
# default is project (`scope="project"` in lib/cli/config.sh), so typing exactly what was
# instructed against a value living in the user layer wouldn't clear it (observed: `<key> is
# not set in <cwd>/.rein/config` while remaining non-zero, and the value staying in place).
# The same shape as `config allow` dropping the lineage's naming -- **the one line pasted and
# run produces none of the effect that was instructed**. Its material is the origin (the same
# value rein_config_origin returns); `user:<file>` / `project:<file>` map straight to a scope.
# **A layer the config entry points cannot clear** (an environment variable, this run's CLI
# flag), and a key with no explicit setting at all (still the default), both return a reason
# instead of naming a scope -- never printing a flat command line when it cannot be named (the same
# discipline used for naming the lineage).
# 0 = scope resolved (REIN_CONFIG_SCOPE_OPT) / 2 = cannot be named (REIN_CONFIG_SCOPE_ERROR)
REIN_CONFIG_SCOPE_OPT=""
REIN_CONFIG_SCOPE_ERROR=""
rein_config_scope_opt() {
  local key="$1"
  REIN_CONFIG_SCOPE_OPT=""
  REIN_CONFIG_SCOPE_ERROR=""
  # The value itself isn't needed, so fetch runs directly (no `$( )` -- the variable carrying
  # the reason never gets closed inside a subshell). The reason for a not-yet-loaded state
  # comes from fetch.
  if ! rein_config_fetch "$key"; then
    printf -v REIN_CONFIG_SCOPE_ERROR '%s (cannot name which layer holds the value)' "$REIN_CONFIG_ERROR"
    return 2
  fi
  case "$REIN_CONFIG_ORIGIN" in
    user:*)
      REIN_CONFIG_SCOPE_OPT=" --user"
      return 0
      ;;
    project:*)
      REIN_CONFIG_SCOPE_OPT=" --project"
      return 0
      ;;
    env:*)
      printf -v REIN_CONFIG_SCOPE_ERROR 'the value comes from environment variable %s (cannot be cleared through config)' \
        "${REIN_CONFIG_ORIGIN#env:}"
      return 2
      ;;
    cli)
      REIN_CONFIG_SCOPE_ERROR="the value comes from this run's command line (cannot be cleared through config)"
      return 2
      ;;
  esac
  printf -v REIN_CONFIG_SCOPE_ERROR '%s is not explicitly set (still the default)' "$key"
  return 2
}

# Instructions to "check the value" (`config get <key>`). **Fills the lineage naming with the
# effective value** -- pasting a line with no naming for a lineage whose location moved would
# read some other config's value as "matching". **No scope naming is needed** -- `get` folds
# the layers and reads the effective value, and only the write entry points (`set` / `unset`)
# carry `--user` / `--project` (this asymmetry is canonically defined by
# `lib/cli/config.sh`'s `case "$action" in set | unset)`, which interprets scope).
# Never includes the value itself (some keys, like settings, can hold a secret), so the
# instructions only hand over the entry point. Keeps a single writer (if the watcher and
# doctor stated the same fact in different wording, one of them would go stale).
# $1 = display name to fill into the instructions (decided by the caller), $2 = key name,
# $3 = target cwd.
# Returned through a variable.
# 0 = the runnable line was built / 2 = the lineage cannot be named (no flat command line is
# printed)
REIN_CONFIG_GET_HINT=""
rein_config_get_hint() {
  local cmd="$1" key="$2" cwd="$3"
  if rein_config_lineage_cmd "$cmd" "$REIN_CONFIG_USER_FILE" "$cwd" "get ${key}"; then
    printf -v REIN_CONFIG_GET_HINT 'check the value with %s' "$REIN_LINEAGE_CMD"
    return 0
  fi
  printf -v REIN_CONFIG_GET_HINT 'check %s in this lineage config (%s)' \
    "$key" "$REIN_LINEAGE_ERROR"
  return 2
}

# Reject a combination of values that's each individually valid but loses its meaning
# together. Attaches which layer each value came from (without an origin, it isn't clear
# which file to fix).
rein_config_check_cross_fields() {
  local notice notice_from handover handover_from
  rein_config_fetch threshold_notice || return 1
  notice="$REIN_CONFIG_VALUE"
  notice_from="$REIN_CONFIG_ORIGIN"
  rein_config_fetch threshold_handover || return 1
  handover="$REIN_CONFIG_VALUE"
  handover_from="$REIN_CONFIG_ORIGIN"
  if [ "$notice" -gt "$handover" ]; then
    REIN_CONFIG_ERROR="threshold_notice (${notice}, from ${notice_from}) exceeds threshold_handover (${handover}, from ${handover_from}) (advisories must start before the handover threshold trips)"
    return 1
  fi
  return 0
}

# A listing with origins (a human-readable form; TAB separates columns, so a value
# containing a TAB would break the layout). "unset -- default" and "explicitly empty --
# disabled" can only be told apart by the origin column.
# Each key prints as a pair of lines: the first has the value and origin, the second, indented,
# has "type and unit -- meaning". **The first line's wording never changes** (existing checks
# and readers parse this exact shape). The description is included because the key name,
# value, and origin alone don't let a user discover what the setting controls or what it
# accepts.
rein_config_list() {
  local key
  for key in $REIN_CFG_KEYS; do
    rein_config_fetch "$key" || return 1
    printf '%s=%s\t(%s)\n' \
      "$key" "$(rein_config_display_value "$key" "$REIN_CONFIG_VALUE")" "$REIN_CONFIG_ORIGIN"
    # The description's material was already loaded by rein_config_lookup, which
    # rein_config_fetch went through (the table is never looked up again -- the effective
    # value and the description come from the same one lookup).
    printf '    %s -- %s\n' "$REIN_CFG_KEY_LABEL" "$REIN_CFG_KEY_MEANING"
  done
}

# Stream the content after the rewrite to standard output (comments, ordering, blank lines,
# and other keys are all left as they are). Not routed through a command substitution, since
# that would drop a trailing blank line.
rein_config_write_set() {
  local file="$1" key="$2" value="$3" line replaced=0
  if [ -f "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        "${key}="*)
          printf '%s=%s\n' "$key" "$value"
          replaced=1
          ;;
        *)
          printf '%s\n' "$line"
          ;;
      esac
    done <"$file"
  fi
  if [ "$replaced" -eq 0 ]; then
    printf '%s=%s\n' "$key" "$value"
  fi
  return 0
}

rein_config_write_unset() {
  local file="$1" key="$2" line removed=0
  if [ -f "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        "${key}="*)
          removed=1
          ;;
        *)
          printf '%s\n' "$line"
          ;;
      esac
    done <"$file"
  fi
  [ "$removed" -eq 1 ]
}

# Follow a symlink and return the real path. Skipping this before a write would replace a
# symlink the user placed with a regular file.
rein_config_real_path() {
  local path="$1" target count=0
  while [ -L "$path" ]; do
    count=$((count + 1))
    if [ "$count" -gt 32 ]; then
      return 1
    fi
    target="$(readlink "$path")" || return 1
    case "$target" in
      /*) path="$target" ;;
      *) path="$(dirname "$path")/$target" ;;
    esac
  done
  printf '%s\n' "$path"
}

# Places a candidate in a temp file in the same directory, swaps that file in for the target
# scope, re-reads it, and only then moves it into place. Writing first and validating after
# would let an invalid setting be observed as the real file, if only for an instant, and a
# reader hitting that instant would fail.
#
# Validity is judged using **only the file layers up to the scope being saved** (never mixed
# with environment variables). Mixing them in would let a currently-active environment
# variable mask a violation in the file layers, leaving behind a config that "wrote fine, but
# fails every other reader". A violation in the effective value that only shows up once
# environment variables are included is downgraded to a single warning line (that environment
# variable is scoped to this process alone -- a separate matter from the file's own
# correctness).
rein_config_commit_scope() {
  local scope="$1" file="$2" tmp="$3" saved_user saved_project saved_mode saved_err rc
  saved_user="$REIN_CONFIG_USER_FILE"
  saved_project="$REIN_CONFIG_PROJECT_FILE"
  saved_mode="$REIN_CONFIG_PROJECT_MODE"
  # The read target is the temp file, but **what it's shown as is the real path** (putting
  # the swapped-in path straight into the reason text, even though it only exists during
  # judgment, would hand back `.../config.XXXXXX` -- something the user can't open -- as the
  # place to fix).
  REIN_CONFIG_PATH_ALIAS_TMP="$tmp"
  REIN_CONFIG_PATH_ALIAS_REAL="$file"
  if [ "$scope" = "project" ]; then
    REIN_CONFIG_PROJECT_FILE="$tmp"
    # The candidate is content rein itself built (a rewrite the user made explicit through a
    # verb), so the validity judgment doesn't run the allow gate -- a temp file is by
    # definition not yet allowed.
    REIN_CONFIG_PROJECT_MODE="trust"
    rein_config_load_layers 0 project
  else
    REIN_CONFIG_USER_FILE="$tmp"
    rein_config_load_layers 0 user
  fi
  rc=$?
  if [ "$rc" -eq 0 ]; then
    rein_config_check_cross_fields
    rc=$?
  fi
  REIN_CONFIG_USER_FILE="$saved_user"
  REIN_CONFIG_PROJECT_FILE="$saved_project"
  REIN_CONFIG_PROJECT_MODE="$saved_mode"
  REIN_CONFIG_PATH_ALIAS_TMP=""
  REIN_CONFIG_PATH_ALIAS_REAL=""
  # What the validity judgment read in full was the candidate temp file, not the content at the path it was reverted to.
  rein_config_project_close
  if [ "$rc" -ne 0 ]; then
    saved_err="$REIN_CONFIG_ERROR"
    rm -f "$tmp"
    rein_config_load_files
    REIN_CONFIG_ERROR="$saved_err"
    return 1
  fi

  if ! mv "$tmp" "$file"; then
    rm -f "$tmp"
    REIN_CONFIG_ERROR="cannot replace ${file}"
    return 1
  fi

  # Content the user just wrote through a verb is recorded as allowed right then (skipping
  # this would have the very next read reject the setting the user just wrote, as "not yet
  # allowed"). The ledger's key is **the path as a layer** (`<cwd>/.rein/config`) -- even a
  # symlinked config is looked up under the same literal path a reader uses.
  if [ "$scope" = "project" ] && ! rein_config_allow_record "$REIN_CONFIG_PROJECT_FILE"; then
    REIN_CONFIG_ERROR="$REIN_PROJECT_ALLOW_ERROR"
    return 1
  fi

  rein_config_load_files || return 1
  REIN_CONFIG_WARNING=""
  if ! rein_config_check_cross_fields; then
    REIN_CONFIG_WARNING="$REIN_CONFIG_ERROR"
    REIN_CONFIG_ERROR=""
  fi
  return 0
}

rein_config_scope_file() {
  if [ "$1" = "project" ]; then
    printf '%s\n' "$REIN_CONFIG_PROJECT_FILE"
  else
    printf '%s\n' "$REIN_CONFIG_USER_FILE"
  fi
}

# Is `<key>=` literally on a line of this scope's file? **Used only to decide whether an unknown
# key names a line that is actually there** -- never to read a value, so it neither follows the
# known-keys table nor goes through the parser (a file holding a key the table doesn't know is
# exactly the state this exists for, and the parser refuses to read it at all). Nothing is
# created: the path is opened as given, and an absent or unreadable file simply answers "no".
# $1 = scope (user / project), $2 = key
rein_config_key_present() {
  local file line
  file="$(rein_config_scope_file "$1")"
  [ -n "$file" ] && [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "${2}="*) return 0 ;;
    esac
  done <"$file"
  return 1
}

# The reason for "there is nothing of that key to clear in this layer."
#
# **It names the layer the value is actually in.** `config unset`'s scope defaults to project,
# so against a value living in the user layer the instruction the user was handed removes
# nothing and produces this very line -- with no pointer at where the value does live, the
# reader has no next step. The mapping from origin to scope goes through rein_config_scope_opt
# (the one place that owns it), so a layer `config` cannot clear at all -- an environment
# variable, this run's own flag -- gives the reason instead of a command line that would not
# work. The same holds when settings could not be read at all: fetch's reason comes back
# through the same channel, and no command line is printed.
# $1 = the scope that was written to, $2 = key, $3 = that scope's real path
rein_config_unset_missing_reason() {
  local scope="$1" key="$2" real="$3" layer
  if rein_config_scope_opt "$key"; then
    layer="${REIN_CONFIG_SCOPE_OPT# --}"
    if [ "$layer" != "$scope" ]; then
      printf -v REIN_CONFIG_ERROR \
        '%s is not set in %s (the value in effect comes from the %s layer -- clear it with config unset%s %s)' \
        "$key" "$real" "$layer" "$REIN_CONFIG_SCOPE_OPT" "$key"
      return 0
    fi
    # The origin names the very layer just written to. That can only happen if the file changed
    # underneath this run, so there is nothing useful to point at.
    printf -v REIN_CONFIG_ERROR '%s is not set in %s' "$key" "$real"
    return 0
  fi
  printf -v REIN_CONFIG_ERROR '%s is not set in %s (%s)' \
    "$key" "$real" "$REIN_CONFIG_SCOPE_ERROR"
  return 0
}

# Create a temp file. Inherits the mode from an existing real file if one exists (never
# discards permissions the user tightened), or defaults to 0600 for a new one (config is
# plaintext and can hold a secret).
rein_config_new_temp() {
  local real="$1" tmp mode=""
  tmp="$(mktemp "${real}.XXXXXX")" || return 1
  if [ -f "$real" ]; then
    mode="$(stat -f '%Lp' "$real" 2>/dev/null)"
  fi
  case "$mode" in
    '' | *[!0-7]*) mode="600" ;;
  esac
  if ! chmod "$mode" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

# Returns the write target's real path **through a variable** (receiving it via `$( )` would
# lose REIN_CONFIG_ERROR, which carries the failure reason, inside a subshell, leaving the
# caller's `fail` with a reasonless line -- fail-loud in appearance only).
REIN_CONFIG_TARGET_PATH=""
rein_config_prepare_target() {
  local scope="$1" file real dir
  REIN_CONFIG_TARGET_PATH=""
  file="$(rein_config_scope_file "$scope")"
  # A location that isn't decided (a machine that can't build the user config's foundation)
  # fails **before writing**. Proceeding with it empty would have `mktemp ".XXXXXX"` create a
  # temp file in the current directory, sending the write somewhere unrelated to the cause
  # (reading correctly proceeds as "absent", so closing this off is this side's
  # responsibility).
  if [ -z "$file" ]; then
    REIN_CONFIG_ERROR="${REIN_CONFIG_USER_BASE_ERROR:-where to save settings is not decided}"
    return 1
  fi
  real="$(rein_config_real_path "$file")" || {
    REIN_CONFIG_ERROR="cannot follow the symlink at ${file}"
    return 1
  }
  dir="$(dirname "$real")"
  if [ "$scope" = "project" ]; then
    # The reason (cannot be created, or is the wrong shape) is printed to standard error by
    # the location side itself, one line. This only carries **context** -- stating flatly
    # "cannot create it" would claim an already-existing directory can't be created, and
    # never tell the user where to actually fix it.
    rein_ensure_records_dir "$dir" || {
      REIN_CONFIG_ERROR="cannot prepare the settings location: ${dir}"
      return 1
    }
  else
    mkdir -p "$dir" || {
      REIN_CONFIG_ERROR="cannot create ${dir}"
      return 1
    }
  fi
  REIN_CONFIG_TARGET_PATH="$real"
  return 0
}

rein_config_set() {
  local scope="$1" key="$2" value="$3" real tmp
  if ! rein_config_validate_value "$key" "$value"; then
    return 1
  fi
  rein_config_prepare_target "$scope" || return 1
  real="$REIN_CONFIG_TARGET_PATH"
  tmp="$(rein_config_new_temp "$real")" || {
    REIN_CONFIG_ERROR="cannot create a temp file for ${real}"
    return 1
  }
  if ! rein_config_write_set "$real" "$key" "$value" >"$tmp"; then
    rm -f "$tmp"
    REIN_CONFIG_ERROR="cannot write to ${real}"
    return 1
  fi
  rein_config_commit_scope "$scope" "$real" "$tmp"
}

# **An unknown key is refused only when the file does not actually hold it.** A key the table
# doesn't know but that is literally on a line of the target file is a line the user can see and
# is asking to delete -- and refusing that is what left a config with a mistyped key repairable
# by hand alone: every reader fails on the unknown key, so `set` cannot get past its own re-read
# either, and `unset` used to refuse before looking. A key that is neither known nor present is
# a typo in the command itself, and is still named as one (exit 2, the usage-error code, so the
# caller keeps telling the two apart).
# 0 = removed / 1 = nothing of that key in this layer, or the write failed / 2 = unknown key
rein_config_unset() {
  local scope="$1" key="$2" real tmp
  if ! rein_config_lookup "$key" && ! rein_config_key_present "$scope" "$key"; then
    REIN_CONFIG_ERROR="unknown key: ${key}"
    return 2
  fi
  rein_config_prepare_target "$scope" || return 1
  real="$REIN_CONFIG_TARGET_PATH"
  tmp="$(rein_config_new_temp "$real")" || {
    REIN_CONFIG_ERROR="cannot create a temp file for ${real}"
    return 1
  }
  if ! rein_config_write_unset "$real" "$key" >"$tmp"; then
    rm -f "$tmp"
    rein_config_unset_missing_reason "$scope" "$key" "$real"
    return 1
  fi
  rein_config_commit_scope "$scope" "$real" "$tmp"
}

# Reads through the file layers and the environment-variable layer (never applies
# cross-field). Since a CLI flag outranks an environment variable, the caller runs this,
# then rein_config_override, then rein_config_check_cross_fields, in that order. Applying
# cross-field here would fail even a run that correctly overrides through a CLI flag, based
# on a combination that only exists in the file layers.
rein_config_prepare() {
  local cmd="$1" cwd="$2"
  rein_config_resolve_files "$cmd" "$cwd"
  rein_config_load_files
}

# Load the effective value into a variable (never uses command substitution -- the watcher
# re-reads every key on every poll cycle, so one fork per key would turn watch polling
# directly into a burst of forks).
rein_config_bind() {
  local var="$1" key="$2"
  rein_config_fetch "$key" || return 1
  printf -v "$var" '%s' "$REIN_CONFIG_VALUE"
  return 0
}
