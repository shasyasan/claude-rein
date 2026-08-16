# shellcheck shell=bash
# Implementation of `rein doctor` (check dependencies and installation).
# Not an executable script, so it doesn't get the execute bit (out of scope for the --selftest convention).

DOCTOR_FAIL=0
DOCTOR_HOOK_COMMAND=""
DOCTOR_HOOK_RESOLVED=""
DOCTOR_HOOK_HEALTH_LINES=""
DOCTOR_PLUGIN_ID=""
DOCTOR_PLUGIN_MARKETPLACE=""
DOCTOR_PLUGIN_ROOT=""
DOCTOR_PLUGIN_ROOT_SOURCE=""

doctor_ok() {
  printf 'OK   %s\n' "$1"
}

doctor_warn() {
  printf 'WARN %s\n' "$1"
}

doctor_fail() {
  DOCTOR_FAIL=$((DOCTOR_FAIL + 1))
  printf 'FAIL %s\n' "$1"
}

# Whether the user's own setting (the settings passed to `claude --bg`) can be **read as the
# foundation for the launch settings**. Doesn't look at the value's content (what
# `worktree.bgIsolation` is) -- rein always layers isolation-disabling onto the launch
# settings, so it isn't abnormal for the user's own side to specify nothing for it. The only problem is a
# value that can't be read, which the watcher fails on right before launch -- this lets
# doctor catch it earlier (the check uses the same 3 shapes as the watcher's
# build_managed_settings).
# Whether it's JSON is checked after skipping leading whitespace (the setting value is used
# verbatim, so ` {"..."}` still passes through as-is). Treating that shape as a file path
# would put the value into a "file doesn't exist" reason string -- putting the value of a
# key that may hold a secret onto the terminal and into logs.
# 0=readable as an object / 1=unset / 2=cannot interpret
doctor_settings_readable() {
  local settings="$1" trimmed
  trimmed="${settings#"${settings%%[![:space:]]*}"}"
  case "$trimmed" in
    '') return 1 ;;
    '{'*)
      printf '%s' "$trimmed" | jq -e 'type == "object"' >/dev/null 2>&1 || return 2
      return 0
      ;;
  esac
  [ -f "$settings" ] || return 2
  jq -e 'type == "object"' "$settings" >/dev/null 2>&1 || return 2
  return 0
}

# Turns the launch-settings check into a line. Folding a failed config fetch
# (rein_config_bind) into "unset" would turn the fact that it could not be read into an
# **OK line** (the user's own setting is unset) -- since this function is what reports the
# diagnostic as green, don't let "couldn't be read" go green (the same discipline as
# the usage section, doctor_usage_state_report).
doctor_settings_report() {
  local value rc
  if ! rein_config_bind value settings; then
    doctor_fail "$REIN_CONFIG_ERROR"
    return 0
  fi
  doctor_settings_readable "$value"
  rc=$?
  case "$rc" in
    0) doctor_ok "can build the launch settings (rein layers isolation-disabling and a managed marker onto the user's own setting)" ;;
    1) doctor_ok "can build the launch settings (the user's own setting is unset -- launches on rein's own settings alone)" ;;
    # The value itself isn't put into the diagnostic text (settings is a key that may hold a
    # secret, and config list withholds it too). The how-to-check line fills in the lineage
    # naming with the effective value. Built through the one function in the config layer --
    # so it doesn't drift from the wording the watcher uses to state the same fact.
    *)
      rein_config_get_hint "$CLI_REIN_CMD" settings "$TARGET_CWD"
      doctor_fail "settings cannot be interpreted either as a file path or as a JSON object (cannot build the launch settings. ${REIN_CONFIG_GET_HINT})"
      ;;
  esac
  return 0
}

# Whether the usage record is **written to the contract**. Checking only whether the location
# exists would go green the instant a user who sees the FAIL text runs `mkdir` -- with no
# writer actually there, producing the hardest kind of breakage to trace: "everything's OK
# but handovers just don't happen" (the shape the reader requires is [the usage record
# specification]).
# Looks at the single newest record in the location -- if the writer is alive, this is always
# the one that gets updated. The newest one is picked by comparing mtimes rather than parsing
# `ls -t` output, to avoid parsing names at all.
# 0=matches the contract (freshness included) / 1=no record exists yet / 2=shape violates
# the contract / 3=the newest update is stale
DOCTOR_USAGE_ERROR=""
DOCTOR_USAGE_FILE=""
DOCTOR_USAGE_AGE=""
doctor_usage_state_format() {
  local dir="$1" stale_sec="$2" file mtime newest="" newest_mtime="" pct at epoch
  DOCTOR_USAGE_ERROR=""
  DOCTOR_USAGE_FILE=""
  DOCTOR_USAGE_AGE=""
  for file in "$dir"/*.json; do
    [ -f "$file" ] || continue
    mtime="$(rein_mtime "$file")"
    case "$mtime" in
      '' | *[!0-9]*) continue ;;
    esac
    if [ -z "$newest_mtime" ] || [ "$mtime" -gt "$newest_mtime" ]; then
      newest_mtime="$mtime"
      newest="$file"
    fi
  done
  [ -n "$newest" ] || return 1
  DOCTOR_USAGE_FILE="$newest"
  if ! jq -e . "$newest" >/dev/null 2>&1; then
    printf -v DOCTOR_USAGE_ERROR 'the usage record cannot be interpreted as JSON: %s' "$newest"
    return 2
  fi
  pct="$(jq -r '.context_window.used_percentage // empty' "$newest" 2>/dev/null)"
  if [ -z "$pct" ]; then
    printf -v DOCTOR_USAGE_ERROR 'the usage record has no context_window.used_percentage (the writer is not writing to the contract): %s' "$newest"
    return 2
  fi
  # **Checks the type too** (`jq -r` prints the string `"20"` the same as `20`, so a
  # digit-shape check alone lets a type mismatch through unnoticed). The reader folds the
  # value as a number, so a string-typed record would stay unreadable while "doctor is all
  # green but nothing hands over" -- turning the spec (numeric) directly into a check.
  if ! jq -e '(.context_window.used_percentage | type) == "number"' "$newest" >/dev/null 2>&1; then
    printf -v DOCTOR_USAGE_ERROR 'used_percentage in the usage record is not numeric (type %s, value %s; the reader folds it as a number, so it cannot be read): %s' \
      "$(jq -r '.context_window.used_percentage | type' "$newest" 2>/dev/null)" "$pct" "$newest"
    return 2
  fi
  at="$(jq -r '.at // empty' "$newest" 2>/dev/null)"
  if [ -z "$at" ]; then
    printf -v DOCTOR_USAGE_ERROR 'the usage record has no at (freshness cannot be determined): %s' "$newest"
    return 2
  fi
  epoch="$(rein_iso_to_epoch "$at")" || epoch=""
  if [ -z "$epoch" ]; then
    printf -v DOCTOR_USAGE_ERROR 'at in the usage record does not match the required time format (UTC, second precision) (%s): %s' "$at" "$newest"
    return 2
  fi
  DOCTOR_USAGE_AGE=$(($(rein_now_epoch) - epoch))
  if [ "$DOCTOR_USAGE_AGE" -gt "$stale_sec" ]; then
    printf -v DOCTOR_USAGE_ERROR 'the usage record was last updated too long ago (%s seconds ago, threshold %s seconds; the writer has either stopped or that session was left closed): %s' \
      "$DOCTOR_USAGE_AGE" "$stale_sec" "$newest"
    return 3
  fi
  return 0
}

# Turns the usage location and record check into lines. The point of this section is not to
# fold a failed config fetch (rein_config_bind) into "unset" or "0 seconds" -- doing so would
# turn the fact that it could not be read into a different reason text (not configured /
# everything is stale) reaching the user.
# Whether the record matched the contract is read by the statusLine section, so it is carried
# in DOCTOR_USAGE_OK.
# The nearest existing location on the way to a path -- the one `mkdir -p` would actually have to
# create into. Walks up one segment at a time; `/` always exists, so the walk always terminates
# (the only caller passes a value the config layer already validated as an absolute path). A
# dangling symlink counts as existing here, because that is one of the shapes `mkdir -p` fails on.
doctor_nearest_existing_ancestor() {
  local dir="$1"
  while [ ! -e "$dir" ] && [ ! -L "$dir" ]; do
    case "$dir" in
      */?*)
        dir="${dir%/*}"
        [ -n "$dir" ] || dir="/"
        ;;
      *)
        dir="/"
        break
        ;;
    esac
  done
  printf '%s\n' "$dir"
}

# The usage location not being there. **Which of WARN and FAIL this is decided by whether the writer
# will be able to create it**, not by whether the value came from config or from the default (the
# default location is created by the very same `mkdir -p`, so "explicitly set" on its own says
# nothing about whether it will work).
# The writer (rein-statusline.sh) `mkdir -p`s the location on its first turn, so on a machine that
# simply has not opened a session since registering statusLine, the location being absent is the
# ordinary state with nothing for the user to fix. The next stage of that same situation ("the
# location is there, no record in it yet") is already a WARN carrying exactly that recovery, so
# reporting this one FAIL split one situation into two disagreeing answers -- and put a red line in
# front of every brand new user at the very step the README calls the one thing that has to work,
# where it reads as "the registration failed."
# It stays FAIL for the shapes a mistyped usage_state_dir actually takes, the ones where `mkdir -p`
# fails and no session will ever fix it: something that is not a directory already sits at the
# path (a regular file, a dangling symlink), or the nearest existing location on the way to it is
# not a writable directory.
doctor_usage_state_absent() {
  local value="$1" ancestor
  if [ -e "$value" ] || [ -L "$value" ]; then
    doctor_fail "the session usage location is not a directory (the writer cannot create it there, so not one record is ever written): ${value}"
    return 0
  fi
  ancestor="$(doctor_nearest_existing_ancestor "$value")"
  if [ ! -d "$ancestor" ] || [ ! -w "$ancestor" ]; then
    doctor_fail "the session usage location does not exist and cannot be created (the nearest existing location ${ancestor} is not a writable directory, so the writer's mkdir fails there): ${value}"
    return 0
  fi
  doctor_warn "the session usage location does not exist yet (the statusLine writer creates it. If you just registered statusLine, opening one session creates it and writes the first record): ${value}"
  return 0
}

DOCTOR_USAGE_OK=0
doctor_usage_state_report() {
  local value stale rc
  DOCTOR_USAGE_OK=0
  if ! rein_config_bind value usage_state_dir; then
    doctor_fail "$REIN_CONFIG_ERROR"
    return 0
  fi
  if [ -z "$value" ]; then
    doctor_fail "the session usage location is not configured (usage_state_dir)"
    return 0
  fi
  if [ ! -d "$value" ]; then
    doctor_usage_state_absent "$value"
    return 0
  fi
  # Even if it exists, if it **cannot be written to**, not a single record is ever added.
  # This shape gets misread as the WARN "no record exists yet" -- taken to mean the user has
  # simply not opened a session yet (a writer failure only shows up in stderr, which Claude
  # Code discards, so there is no other way to notice it).
  if [ ! -w "$value" ]; then
    doctor_fail "cannot write to the session usage location (the writer cannot place records, so neither threshold checks nor handovers ever start): ${value}"
    return 0
  fi
  doctor_ok "the session usage location exists: ${value}"
  # The location existing alone does not mean "a writer is present," so this also checks the
  # record's **shape**. The freshness threshold is already validated by the config layer as a
  # positive integer (an unreadable value fails before reaching here) -- no fallback silently
  # folds an unreadable value to 0 (that would turn every record into "stale").
  if ! rein_config_bind stale usage_stale_sec; then
    doctor_fail "$REIN_CONFIG_ERROR"
    return 0
  fi
  doctor_usage_state_format "$value" "$stale"
  rc=$?
  case "$rc" in
    0)
      DOCTOR_USAGE_OK=1
      doctor_ok "the usage record matches the contract (last updated ${DOCTOR_USAGE_AGE} seconds ago): ${DOCTOR_USAGE_FILE}"
      ;;
    1) doctor_warn "no usage record exists yet (if you just registered statusLine, opening one session writes it): ${value}" ;;
    3) doctor_warn "$DOCTOR_USAGE_ERROR" ;;
    *) doctor_fail "$DOCTOR_USAGE_ERROR" ;;
  esac
  return 0
}

# The **user layer's path** for the user-scope settings file. Determining the foundation
# (`CLAUDE_CONFIG_DIR` or `HOME/.claude`) goes through the shared predicate -- writing it out
# as `${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}` would fold to `/.claude/settings.json` on a
# machine where HOME is empty or unset (via launchd, an ssh session with a stripped
# environment), passing a nonexistent path under the filesystem root along **as if it were a
# valid search location**. What it folds to can never be read, so doctor would print only
# **the distant-cause reason** "statusLine is not registered," and HOME being missing never surfaces
# (the same shape the shared library closes off for the default location).
# 0=filled in DOCTOR_STATUSLINE_USER_FILE / 1=cannot be built (reason in REIN_XDG_BASE_ERROR)
DOCTOR_STATUSLINE_USER_FILE=""
doctor_statusline_user_file() {
  DOCTOR_STATUSLINE_USER_FILE=""
  rein_xdg_base "${CLAUDE_CONFIG_DIR:-}" CLAUDE_CONFIG_DIR .claude "the user-scope settings file" || return 1
  DOCTOR_STATUSLINE_USER_FILE="$REIN_XDG_BASE/settings.json"
  return 0
}

# Whether the usage writer (statusLine) is registered in the user-scope settings file. **rein
# never edits settings** (it belongs to the user, so registering it is up to them -- this only
# detects and advises).
# The search locations are the 3 that Claude Code reads, with later ones taking precedence
# (the same key in a later file wins). On a machine where the user layer's foundation cannot
# be built, **that one location is left out of the list** (a folded path is never counted as a
# search location).
# Naming the reason is left to the advisory side (doctor_statusline_snippet) -- this is
# called inside `$( )`, so setting a variable here would not reach the caller.
DOCTOR_STATUSLINE_FILE=""
DOCTOR_STATUSLINE_COMMAND=""
doctor_statusline_files() {
  if doctor_statusline_user_file; then
    printf '%s\n' "$DOCTOR_STATUSLINE_USER_FILE"
  fi
  printf '%s\n' \
    "$TARGET_CWD/.claude/settings.json" \
    "$TARGET_CWD/.claude/settings.local.json"
}

# Extracts the registered command's **first word** (what actually gets launched). Since a
# registration with arguments, a quoted registration, and one starting with `~` all exist in
# practice, a literal partial match cannot tell "which real file runs." The extraction order
# is **quoting first, whitespace second** -- reversed (splitting the first word on whitespace
# before stripping quotes), a quoted path containing whitespace would get cut short at the
# whitespace and fail to resolve, reporting "a different writer" for a distribution laid out
# at a path that contains whitespace even though it is registered correctly.
# **Whether it is quoted does not by itself narrow what is accepted** -- an unquoted
# registration still passes through as-is. This is text the user writes into their own
# settings, so it is never flagged FAIL purely for rein's convenience (the opposite of the
# hooks registry, which is rein's own distributed artifact, so quoting is required there by
# the gate).
# Whether it was quoted is returned to the caller because that changes how `~` is handled
# (the 2 callers below both look at this single extraction -- so how the first word is read
# does not live in two places).
# 0=extracted / 1=the first word cannot be determined (unclosed quote, empty)
DOCTOR_STATUSLINE_WORD=""
DOCTOR_STATUSLINE_QUOTED=0
doctor_statusline_first_word() {
  local command="$1" rest
  DOCTOR_STATUSLINE_WORD=""
  DOCTOR_STATUSLINE_QUOTED=0
  case "$command" in
    '"'*)
      rest="${command#\"}"
      # With no closing quote, where the first word ends is undecidable -- return that as
      # undeterminable.
      case "$rest" in
        *'"'*) ;;
        *) return 1 ;;
      esac
      DOCTOR_STATUSLINE_WORD="${rest%%\"*}"
      DOCTOR_STATUSLINE_QUOTED=1
      ;;
    "'"*)
      rest="${command#\'}"
      case "$rest" in
        *"'"*) ;;
        *) return 1 ;;
      esac
      DOCTOR_STATUSLINE_WORD="${rest%%\'*}"
      DOCTOR_STATUSLINE_QUOTED=1
      ;;
    *)
      DOCTOR_STATUSLINE_WORD="${command%% *}"
      ;;
  esac
  [ -n "$DOCTOR_STATUSLINE_WORD" ]
}

# Expands a `~/<relative>` appearing in a registration the same way the shell would (prefix
# `$HOME`).
# **Does not expand it on a machine where HOME is empty or relative** -- writing this out as
# `${HOME:-}/<relative>` would fold to `/<relative>` and pass a nonexistent path under the
# filesystem root along as if the expansion succeeded. On the checking side, that turns into
# the mistaken reason "a different writer is registered"; on the advisory side, it recommends
# an absolute path the user cannot even write to as "the one for this environment." Whether
# HOME can serve as the foundation goes through the shared predicate (the same one discipline
# used for the default location).
# **The predicate's reason text is not used here** -- that text is aimed at "neither an XDG
# variable nor HOME exists," and there is only one path for expanding `~` (the caller names
# the reason for this spot itself).
# 0=filled in DOCTOR_HOME_PATH / 1=cannot be built from HOME
DOCTOR_HOME_PATH=""
doctor_home_path() {
  DOCTOR_HOME_PATH=""
  rein_xdg_base "" HOME "$1" "where a registration's ~ expands to" || return 1
  DOCTOR_HOME_PATH="$REIN_XDG_BASE"
  return 0
}

# Resolves the first word to a **real path**. Returns empty for a shape that cannot be
# resolved.
# `~/` is expanded **only outside quotes** -- exactly the shell's own rule (a `~` inside
# quotes is never expanded, and names a directory literally called `~`). Taking this rule
# more broadly and expanding even inside quotes would end up **reporting, as green, "the
# bundled writer is registered" for a registration that never actually runs** -- letting
# through "registered but does not run," which is the exact inverse of what this check is
# meant to catch.
# A shape that will not run is left unresolved; the reason is named explicitly by
# doctor_statusline_quoted_tilde.
DOCTOR_STATUSLINE_TARGET=""
doctor_statusline_target() {
  local word
  DOCTOR_STATUSLINE_TARGET=""
  doctor_statusline_first_word "$1" || return 1
  word="$DOCTOR_STATUSLINE_WORD"
  if [ "$DOCTOR_STATUSLINE_QUOTED" -eq 0 ]; then
    # shellcheck disable=SC2088  # a `~` appearing in a registration (identified by prefix, never expanded)
    case "$word" in
      # On a machine where HOME cannot be used, **leave it unresolved** (never pass off
      # something folded to `/<relative>` as a real path).
      '~/'*)
        doctor_home_path "${word#\~/}" || return 1
        word="$DOCTOR_HOME_PATH"
        ;;
    esac
  fi
  DOCTOR_STATUSLINE_TARGET="$(resolve_self "$word")" || DOCTOR_STATUSLINE_TARGET=""
  [ -n "$DOCTOR_STATUSLINE_TARGET" ]
}

# Whether the first word starts with **a `~` inside quotes**. The shell never expands that
# `~`, so this registration will not run (the usage will never be recorded, and handovers
# will never start). Mixing this into the same reason text as other shapes whose real file
# cannot be resolved would produce the **mistaken reason** "a different writer is
# registered," giving no way to tell what needs fixing -- so this shape alone is named
# explicitly.
# So a fix can be suggested, the `~`-expanded path is put into DOCTOR_STATUSLINE_TILDE_HINT
# (for display only -- **never used to judge identity**, since something that will not run
# is never read as if it does).
# On a machine where HOME cannot be used, **only the hint is left empty** (whether it is this
# shape at all does not depend on HOME). It is left empty because recommending the folded
# `/<relative>` as "the one for this environment" would have the user rewrite it to a place
# they cannot even write to. What gets shown when it is empty is up to the caller.
DOCTOR_STATUSLINE_TILDE_HINT=""
doctor_statusline_quoted_tilde() {
  DOCTOR_STATUSLINE_TILDE_HINT=""
  doctor_statusline_first_word "$1" || return 1
  [ "$DOCTOR_STATUSLINE_QUOTED" -eq 1 ] || return 1
  # shellcheck disable=SC2088  # a `~` appearing in a registration (identified by prefix, never expanded)
  case "$DOCTOR_STATUSLINE_WORD" in
    '~/'*) ;;
    *) return 1 ;;
  esac
  doctor_home_path "${DOCTOR_STATUSLINE_WORD#\~/}" || return 0
  DOCTOR_STATUSLINE_TILDE_HINT="$DOCTOR_HOME_PATH"
  return 0
}

# 0=this repository's bundled writer is registered
# 1=a different writer is registered
# 2=nothing registered
# 3=settings cannot be read (not interpretable as JSON)
# 4=a rein writer, but from **a different real location** (a different checkout), is registered
# 5=a registration starting with `~` inside quotes -- the shell never expands it, so it will not run
doctor_statusline_state() {
  local file command found=0 unreadable="" mine
  DOCTOR_STATUSLINE_FILE=""
  DOCTOR_STATUSLINE_COMMAND=""
  DOCTOR_STATUSLINE_TARGET=""
  while IFS= read -r file; do
    [ -f "$file" ] || continue
    if ! jq -e . "$file" >/dev/null 2>&1; then
      unreadable="$file"
      continue
    fi
    command="$(jq -r '.statusLine.command // empty' "$file" 2>/dev/null)"
    [ -n "$command" ] || continue
    # Does not stop at the first match (a later layer overrides the same key, so only the
    # last one is actually in effect).
    DOCTOR_STATUSLINE_FILE="$file"
    DOCTOR_STATUSLINE_COMMAND="$command"
    found=1
  done <<EOF
$(doctor_statusline_files)
EOF
  if [ "$found" -eq 1 ]; then
    # **Compares by real file** (a literal partial match would read a same-named script in a
    # different checkout as "bundled" -- reporting green for a setup where an update only
    # takes effect on one of them. The same discipline used to check the install symlink by
    # its real file).
    mine="$(resolve_self "$REPO_ROOT/$REIN_STATUSLINE_RELPATH")" || mine=""
    # A shape that will not run is rejected **before it ever goes to resolve the real file**.
    # Doing it the other way around would turn the reason it cannot be resolved into "a
    # different writer," and a `cd` failing while trying to follow an unresolvable `~` would
    # bleed into doctor's output (mixing diagnostics unrelated to the fix into the line the
    # user reads).
    if doctor_statusline_quoted_tilde "$DOCTOR_STATUSLINE_COMMAND"; then
      return 5
    fi
    if doctor_statusline_target "$DOCTOR_STATUSLINE_COMMAND" &&
      [ -n "$mine" ] && [ "$DOCTOR_STATUSLINE_TARGET" = "$mine" ]; then
      return 0
    fi
    case "${DOCTOR_STATUSLINE_TARGET:-$DOCTOR_STATUSLINE_COMMAND}" in
      *"${REIN_STATUSLINE_RELPATH##*/}") return 4 ;;
    esac
    return 1
  fi
  [ -z "$unreadable" ] || {
    DOCTOR_STATUSLINE_FILE="$unreadable"
    return 3
  }
  return 2
}

# A registration existing and its writer **actually running** are different things. In an
# environment where it does not run (execute permission was lost, it cannot follow the
# shared library, it fails in that environment's config layer), the failure only shows up in
# stderr, which Claude Code discards -- with records never increasing, doctor would still
# print OK for "registered," and the user reads that as installation being done. This is the
# one place that checks it by **actually running it once**.
# It only runs when **the bundled writer is the one registered** -- a different command the
# user registered is never launched by this diagnostic (something whose behavior is unknown
# is never made a side effect of doctor).
# The write target is redirected to an isolated, temporary location -- placing a synthetic
# record at the real location would have doctor's own record check read that synthetic
# record as the newest one, **reporting green for a state with no writer present** (the exact
# inverse of what this check is for).
# 0=ran and wrote a record matching the contract / 1=did not run (reason in
# DOCTOR_STATUSLINE_SMOKE_ERROR)
DOCTOR_STATUSLINE_SMOKE_ERROR=""
doctor_statusline_smoke() {
  local writer="$REPO_ROOT/$REIN_STATUSLINE_RELPATH" sid="rein-doctor-smoke"
  local dir payload out rc state reason
  DOCTOR_STATUSLINE_SMOKE_ERROR=""
  payload="$(jq -nc --arg sid "$sid" --arg cwd "$TARGET_CWD" \
    '{session_id: $sid, cwd: $cwd, context_window: {used_percentage: 1}}')" || {
    DOCTOR_STATUSLINE_SMOKE_ERROR="cannot build the payload to try the usage writer with (jq is not usable)"
    return 1
  }
  dir="$(mktemp -d "${TMPDIR:-/tmp}/rein-doctor-statusline.XXXXXX")" || {
    DOCTOR_STATUSLINE_SMOKE_ERROR="cannot create a temporary location to try the usage writer in: ${TMPDIR:-/tmp}"
    return 1
  }
  # Launched the same way the registration does (running the real file directly) -- so a
  # loss of execute permission also fails right here.
  out="$(printf '%s' "$payload" | env "REIN_USAGE_STATE_DIR=$dir" "$writer" 2>&1)"
  rc=$?
  state="$dir/${sid}.json"
  # The reason carries **only the writer's last line** (not mixed with the status-bar line
  # printed before it).
  reason="${out##*$'\n'}"
  [ -n "$reason" ] || reason="(no output)"
  if [ "$rc" -ne 0 ]; then
    printf -v DOCTOR_STATUSLINE_SMOKE_ERROR \
      'the registered bundled usage writer does not run (it exits non-zero on every turn, so records never grow and handovers never happen. reason: %s): %s' \
      "$reason" "$writer"
  elif [ ! -f "$state" ]; then
    printf -v DOCTOR_STATUSLINE_SMOKE_ERROR \
      'the registered bundled usage writer never places a record (only the display shows up while the record is dropped -- to a reader this is the same as no writer being present. last output: %s): %s' \
      "$reason" "$writer"
  elif ! jq -e '(.context_window.used_percentage | type) == "number"' "$state" >/dev/null 2>&1; then
    printf -v DOCTOR_STATUSLINE_SMOKE_ERROR \
      'the registered bundled usage writer does not write a record matching the contract (the reader folds used_percentage as a number, so it cannot be read): %s' \
      "$writer"
  fi
  rm -rf "$dir"
  [ -z "$DOCTOR_STATUSLINE_SMOKE_ERROR" ]
}

# Turns the run result into a line. The mapping from return value to line is kept closed in
# here for the same reason as other sections (a mix-up that drops a failed run to the OK side
# would pass unnoticed by a check that only looks at the judging function's return value).
doctor_statusline_smoke_report() {
  if doctor_statusline_smoke; then
    doctor_ok "the bundled usage writer actually runs (wrote a record matching the contract to an isolated temporary location)"
  else
    doctor_fail "$DOCTOR_STATUSLINE_SMOKE_ERROR"
  fi
  return 0
}

# The registration snippet to paste. Keeping the judgment (doctor) and the advisory (this
# function) in one place keeps README and init from drifting apart (two readings of how to
# install would leave installation finished with no writer present).
# **The writer path is wrapped in double quotes inside the JSON** (`"command": "\"...\""`) --
# this command is passed to a shell on the user side and run there (the official docs state
# plainly that "The `command` field runs in a shell"), so without wrapping it, a repository
# laid out at a path containing whitespace would get word-split and the writer would never
# run. The checking side keeps accepting unquoted registrations too (never flags an existing
# registration FAIL) -- only the advisory makes the shape safe.
# On a machine where the location cannot be named (neither HOME nor CLAUDE_CONFIG_DIR
# exists), the folded `/.claude/settings.json` is never advised as the paste target -- the
# user cannot write there, and without knowing why, they would end up at "I registered it and
# it still is not fixed." **This one line names the fact that it could not be built** (since
# the registration check has no basis to work from, this is the only way out after the
# not-registered FAIL).
doctor_statusline_snippet() {
  if ! doctor_statusline_user_file; then
    printf '     %s\n' "$REIN_XDG_BASE_ERROR"
    printf '     once you know the location, add the following to its settings.json (rein never edits settings):\n'
    doctor_statusline_snippet_body
    return 0
  fi
  printf '     add the following to %s (rein never edits settings):\n' "$DOCTOR_STATUSLINE_USER_FILE"
  doctor_statusline_snippet_body
  return 0
}

# The JSON snippet itself to paste (prints **the same one** whether or not the destination
# can be named).
doctor_statusline_snippet_body() {
  printf '       {\n'
  printf '         "statusLine": { "type": "command", "command": "\\"%s\\"" }\n' \
    "$REPO_ROOT/$REIN_STATUSLINE_RELPATH"
  printf '       }\n'
}

# The **exact ID** (`<name>@<marketplace>`) naming the plugin this work tree distributes.
# Identifying it down to the marketplace name matters because otherwise a **same-named**
# plugin distributed by a different marketplace being merely enabled would say "enabled" --
# producing the hardest-to-read shape: doctor green while not a single one of this work
# tree's hooks fires, and init doing nothing because it says "already enabled."
# The material is two registries (the plugin manifest's name and the marketplace registry's
# name), built the same way as the ID init passes to `claude plugin install`. That the two
# never drift apart is pinned mechanically by selftest (a fixture with the same ID makes
# "already enabled" and "does not reinstall" both hold at once).
doctor_plugin_marketplace_name() {
  local marketplace
  marketplace="$(rein_manifest_name "$REIN_MARKETPLACE_MANIFEST_RELPATH")"
  [ -n "$marketplace" ] || return 1
  printf '%s\n' "$marketplace"
}

# Whether it is enabled as a plugin (that is, whether hooks are in a state to fire). The
# material for judging this is `id` (`<name>@<marketplace>`) and `enabled` from `claude
# plugin list --json`.
# 0=enabled / 1=installed but disabled / 2=cannot determine / 3=not installed
doctor_plugin_state() {
  local id out
  DOCTOR_PLUGIN_ID=""
  id="$(rein_plugin_exact_id)" || return 2
  DOCTOR_PLUGIN_ID="$id"
  out="$(rein_run_capture "$CMD_TIMEOUT_SEC" claude plugin list --json)" || return 2
  printf '%s' "$out" | jq -e . >/dev/null 2>&1 || return 2
  if printf '%s' "$out" | jq -e --arg id "$id" \
    'any(.[]; (.id // "") == $id and (.enabled == true))' >/dev/null 2>&1; then
    return 0
  fi
  if printf '%s' "$out" | jq -e --arg id "$id" \
    'any(.[]; (.id // "") == $id)' >/dev/null 2>&1; then
    return 1
  fi
  return 3
}

# Whether the real location of the marketplace distributing that plugin **is this work tree
# itself**. Even with the ID matching, if a same-named marketplace points at a different
# checkout, the hooks that fire are that different real location's.
# **`installPath` from `claude plugin list` must never be used as the material here** -- for
# a distribution that made a local directory into a marketplace, what actually gets read is
# the real file in the work tree, and the cache copy `installPath` points at never runs
# (observed). Checking against it would drop an environment that is installed correctly
# straight to FAIL. The real location comes from `claude plugin marketplace list --json` (an
# official flag).
# 0=this work tree / 1=points at a different location / 2=cannot determine
# 3=not registered / 4=not a local directory distribution
doctor_plugin_root_state() {
  local marketplace out row
  DOCTOR_PLUGIN_MARKETPLACE=""
  DOCTOR_PLUGIN_ROOT=""
  DOCTOR_PLUGIN_ROOT_SOURCE=""
  marketplace="$(doctor_plugin_marketplace_name)" || return 2
  DOCTOR_PLUGIN_MARKETPLACE="$marketplace"
  out="$(rein_run_capture "$CMD_TIMEOUT_SEC" claude plugin marketplace list --json)" || return 2
  printf '%s' "$out" | jq -e . >/dev/null 2>&1 || return 2
  # The two values are delimited by US (0x1f). A path may contain not just whitespace but a
  # newline, so this never splits on a line or on whitespace.
  row="$(printf '%s' "$out" | jq -r --arg m "$marketplace" \
    '(map(select((.name // "") == $m)) | .[0]) as $e
     | if $e == null then empty else "\($e.source // "")\u001f\($e.path // "")" end')" || return 2
  [ -n "$row" ] || return 3
  DOCTOR_PLUGIN_ROOT_SOURCE="${row%%$'\037'*}"
  DOCTOR_PLUGIN_ROOT="${row#*$'\037'}"
  [ "$DOCTOR_PLUGIN_ROOT_SOURCE" = "directory" ] || return 4
  if [ -z "$DOCTOR_PLUGIN_ROOT" ] || [ "$DOCTOR_PLUGIN_ROOT" != "$REPO_ROOT" ]; then
    return 1
  fi
  return 0
}

# Turns judging the marketplace's real location into a line. The mapping from return value
# to line is kept closed in here for the same reason as the plugin enablement mapping (a
# mix-up that drops to the green side would produce the shape "doctor is all green, yet not
# one of this work tree's hooks fires").
doctor_plugin_root_report() {
  local rc init
  doctor_plugin_root_state
  rc=$?
  # `init` lays down its template per lineage -- so the advice is **something that can be run
  # as-is for this lineage** (where you run it from changes which lineage it is, so a bare
  # `rein init` would lay down a template for a different one). Built through the one shared
  # function.
  rein_lineage_cmd "$CLI_REIN_CMD" "$RUNTIME_DIR" "$RECORDS_DIR" "$TARGET_CWD" init
  init="$REIN_LINEAGE_CMD"
  case "$rc" in
    0) doctor_ok "the plugin marketplace points at this work tree: ${DOCTOR_PLUGIN_ROOT}" ;;
    1) doctor_fail "the plugin marketplace points at a different location: ${DOCTOR_PLUGIN_ROOT:-cannot resolve} (this real location: ${REPO_ROOT}). To distribute from this location: ${init}" ;;
    3) doctor_fail "the plugin marketplace is not registered (running claude plugin marketplace list finds no ${DOCTOR_PLUGIN_MARKETPLACE}. To register it: ${init})" ;;
    4) doctor_fail "the plugin marketplace is not distributed from this work tree (source=${DOCTOR_PLUGIN_ROOT_SOURCE}). To distribute from this location: ${init}" ;;
    *) doctor_fail "cannot determine the plugin marketplace (cannot read claude plugin marketplace list --json)" ;;
  esac
  return 0
}

# Whether the execution path the hooks registry calls **currently resolves to a real file**.
# The path has 3 stages (the registry -> the tiny launcher inside the plugin -> the runner
# next to the PATH-callable command's real file), and if even one is missing, not a single
# hook fires even with the registration present -- the wiring is dead while rein itself
# looks like it is working. The material for judging this comes from **the registry itself**,
# with the path never kept a second time on the checking side (so changing the registration
# never leaves the check alone still looking at the old path).
# 0=the path resolves / 1=the launcher or the runner cannot execute / 2=cannot read the registry
# 3=the registration command is not in the expected shape (a quoted ${CLAUDE_PLUGIN_ROOT}/... launcher)
doctor_hook_command_state() {
  local file="$REPO_ROOT/$REIN_HOOKS_JSON_RELPATH" commands command rel runner
  DOCTOR_HOOK_COMMAND=""
  DOCTOR_HOOK_RESOLVED=""
  [ -f "$file" ] || return 2
  commands="$(jq -r '[ .hooks[][].hooks[].command // empty ] | .[]' "$file" 2>/dev/null)" || return 2
  [ -n "$commands" ] || return 2
  runner="$REPO_ROOT/$REIN_HOOK_RUNNER_RELPATH"
  DOCTOR_HOOK_RESOLVED="$runner"
  while IFS= read -r command; do
    [ -n "$command" ] || continue
    # The shape check lives in exactly one place in the shared library (a shape lacking
    # quotes -- one that would get word-split at a location containing whitespace -- fails
    # right here). On failure, the raw command is shown as-is, so the user can read what is
    # different.
    DOCTOR_HOOK_COMMAND="$command"
    rel="$(rein_hook_command_launcher_relpath "$command")" || return 3
    # shellcheck disable=SC2016  # the literal registration text shown to the user (never expanded)
    DOCTOR_HOOK_COMMAND='${CLAUDE_PLUGIN_ROOT}'"/$rel"
    [ -x "$REPO_ROOT/$rel" ] || return 1
  done <<EOF
$commands
EOF
  [ -x "$runner" ] || return 1
  return 0
}

# Turns judging the execution path into a line. The **mapping** from return value to line is
# kept closed in here because a mix-up that drops a lineage with a dead path (rc != 0) to the
# OK side would produce the hardest-to-read shape "doctor is all green, yet not one hook
# fires" (checking only the judging function's return value lets this mix-up pass unnoticed).
doctor_hook_command_report() {
  local rc
  doctor_hook_command_state
  rc=$?
  # shellcheck disable=SC2016  # the literal registration text shown to the user (never expanded)
  case "$rc" in
    0) doctor_ok "the hooks execution path resolves: ${DOCTOR_HOOK_COMMAND} -> ${DOCTOR_HOOK_RESOLVED}" ;;
    1) doctor_fail "the hooks execution path does not resolve (cannot execute ${DOCTOR_HOOK_COMMAND} or the runner ${DOCTOR_HOOK_RESOLVED})" ;;
    3) doctor_fail 'the hooks registration command is not in the expected shape (a quoted ${CLAUDE_PLUGIN_ROOT}/... launcher): '"${DOCTOR_HOOK_COMMAND}" ;;
    *) doctor_fail "cannot read the hooks registry (cannot determine the execution path): ${REPO_ROOT}/${REIN_HOOKS_JSON_RELPATH}" ;;
  esac
  return 0
}

# Whether rein's own hooks are **actually running** (a different target from the fire log --
# what it printed. The abnormality of it not printing at all -- registration not taking
# effect, the launcher unable to trace to a real file, an advisory never being delivered --
# cannot be judged from the log's line count). The material is the health state hooks write.
# The result is accumulated as lines in DOCTOR_HOOK_HEALTH_LINES (0=nothing abnormal /
# 1=something abnormal).
doctor_hook_health_state() {
  local dir="$RUNTIME_DIR/$REIN_HOOK_STATE_DIRNAME/$REIN_HOOK_HEALTH_DIRNAME"
  local file event seen age note bad=0
  DOCTOR_HOOK_HEALTH_LINES=""
  if [ ! -d "$dir" ]; then
    # The install advice is **something that can be run as-is for this lineage** (built
    # through the one shared function).
    rein_lineage_cmd "$CLI_REIN_CMD" "$RUNTIME_DIR" "$RECORDS_DIR" "$TARGET_CWD" init
    DOCTOR_HOOK_HEALTH_LINES="WARN hooks firing has never been observed yet (the registration may not be taking effect. install with ${REIN_LINEAGE_CMD}; check it with /hooks in Claude Code): ${dir}"
    return 1
  fi
  for event in SessionStart PostToolBatch Stop UserPromptSubmit; do
    file="$dir/last-seen.$event"
    if [ ! -f "$file" ]; then
      DOCTOR_HOOK_HEALTH_LINES="${DOCTOR_HOOK_HEALTH_LINES}${DOCTOR_HOOK_HEALTH_LINES:+
}WARN ${event} firing has not been observed yet (${event} has never once run for this lineage)"
      bad=1
      continue
    fi
    seen=""
    IFS= read -r seen <"$file" 2>/dev/null || :
    case "$seen" in
      '' | *[!0-9]*)
        DOCTOR_HOOK_HEALTH_LINES="${DOCTOR_HOOK_HEALTH_LINES}${DOCTOR_HOOK_HEALTH_LINES:+
}WARN cannot read the last-fired record for ${event}: ${file}"
        bad=1
        continue
        ;;
    esac
    age=$(($(rein_now_epoch) - seen))
    # Reporting "last fired N seconds ago" as OK without a freshness threshold would let even
    # a lineage whose registration fell off and has not fired in days pass as green (the
    # threshold value and its rationale are in the shared library constant comment).
    if [ "$age" -gt "$REIN_HOOK_ACTIVITY_STALE_SEC" ]; then
      DOCTOR_HOOK_HEALTH_LINES="${DOCTOR_HOOK_HEALTH_LINES}${DOCTOR_HOOK_HEALTH_LINES:+
}WARN ${event} last fired too long ago (${age} seconds ago, threshold ${REIN_HOOK_ACTIVITY_STALE_SEC} seconds. Either the registration fell off, or this lineage has not been used in a while)"
      bad=1
      continue
    fi
    DOCTOR_HOOK_HEALTH_LINES="${DOCTOR_HOOK_HEALTH_LINES}${DOCTOR_HOOK_HEALTH_LINES:+
}OK   ${event} last fired: ${age} seconds ago"
  done
  for event in undelivered error; do
    file="$dir/$event"
    [ -f "$file" ] || continue
    note=""
    IFS= read -r note <"$file" 2>/dev/null || :
    DOCTOR_HOOK_HEALTH_LINES="${DOCTOR_HOOK_HEALTH_LINES}${DOCTOR_HOOK_HEALTH_LINES:+
}WARN hooks recorded an abnormality (${event}): ${note}"
    bad=1
  done
  return "$bad"
}

# Checks the fire log (**what hooks printed**). This is a different target from health state
# (whether it is running), so doctor checks both -- with only one checked, either "the
# registration is alive but has never printed once" or "it is printing, but the record is
# broken" would go unnoticed silently. It checks 5 things:
#   missing (no log, or 0 lines) / stale (the last line is old) / bloated (over the size cap
#   without being archived) / breakdown by kind (line count per event-and-decision pair --
#   what is being printed) / breakdown by schema (line count per schema-and-event pair --
#   who is writing to this location).
# **Unreadable lines are counted as 2 separate categories** -- a line that cannot be
# interpreted as JSON (a writer accident, a different format mixed in) and a line that
# parses but has an unknown schema (a different writer mixed in, or a version bump where one
# side is still old) have different causes and different next steps, so folding them into one
# corruption count would make the log unable to say which one it is. Lines with an unknown
# schema go into the breakdown paired with their event (so who is writing shows up in one
# line).
# The result is accumulated as lines in DOCTOR_FIRE_LOG_LINES (0=nothing abnormal / 1=
# something abnormal).
DOCTOR_FIRE_LOG_LINES=""
doctor_hook_fire_log_state() {
  local file="$STATE_ROOT/$REIN_FIRE_LOG_BASENAME"
  local out size total unparsable unknown last_at kinds schema_kinds epoch age bad=0
  DOCTOR_FIRE_LOG_LINES=""
  if [ ! -f "$file" ]; then
    DOCTOR_FIRE_LOG_LINES="WARN there is no fire log (hooks have never fired even once at this location): ${file}"
    return 1
  fi
  # Read line by line **as raw text** first, then interpret as JSON (a single broken line
  # would otherwise fail `jq -s` at the read stage itself, and the breakdown could not even
  # be produced for the healthy lines).
  out="$(jq -sRr --arg schema "$REIN_HOOK_FIRE_SCHEMA" '
    def kind_counts: group_by(.) | map("\(.[0])=\(length)") | join(" ");
    split("\n") | map(select(. != ""))
    | map(. as $line | (try ($line | fromjson) catch null)
          | if type == "object" then . else null end)
    | . as $rows
    | ($rows | map(select(. != null))) as $parsed
    | ($parsed | map(select(.schema == $schema))) as $good
    | [ ($rows | length),
        (($rows | length) - ($parsed | length)),
        (($parsed | length) - ($good | length)),
        ($good | map(.at // "") | last // ""),
        ($good | map((.event // "?") + "/" + (.decision // "?")) | kind_counts),
        ($parsed | map(((.schema // "(none)") | tostring) + "/"
                       + ((.event // "?") | tostring)) | kind_counts) ]
    | .[] | tostring' "$file" 2>/dev/null)"
  if [ -z "$out" ]; then
    DOCTOR_FIRE_LOG_LINES="WARN cannot read the fire log: ${file}"
    return 1
  fi
  {
    IFS= read -r total
    IFS= read -r unparsable
    IFS= read -r unknown
    IFS= read -r last_at
    IFS= read -r kinds
    IFS= read -r schema_kinds
  } <<EOF
$out
EOF
  if [ "$total" -eq 0 ]; then
    DOCTOR_FIRE_LOG_LINES="WARN the fire log has no lines (hooks have never fired even once): ${file}"
    return 1
  fi
  DOCTOR_FIRE_LOG_LINES="OK   fire log: ${total} lines (${kinds:-no breakdown}): ${file}
OK   fire log breakdown by schema: ${schema_kinds:-no breakdown}"
  if [ "$unknown" -gt 0 ]; then
    DOCTOR_FIRE_LOG_LINES="${DOCTOR_FIRE_LOG_LINES}
WARN the fire log has lines with an unknown schema (${unknown}/${total} lines, expected ${REIN_HOOK_FIRE_SCHEMA}. The breakdown by schema shows the writer. Either a different writer got mixed in, or a version was bumped while one side is still old)"
    bad=1
  fi
  if [ "$unparsable" -gt 0 ]; then
    DOCTOR_FIRE_LOG_LINES="${DOCTOR_FIRE_LOG_LINES}
WARN the fire log has lines that cannot be interpreted (${unparsable}/${total} lines. The line count cannot be read as firing activity)"
    bad=1
  fi
  epoch="$(rein_iso_to_epoch "$last_at")" || epoch=""
  if [ -z "$epoch" ]; then
    DOCTOR_FIRE_LOG_LINES="${DOCTOR_FIRE_LOG_LINES}
WARN cannot read the fire log last line timestamp: ${last_at:-(none)}"
    bad=1
  else
    age=$(($(rein_now_epoch) - epoch))
    if [ "$age" -gt "$REIN_HOOK_ACTIVITY_STALE_SEC" ]; then
      DOCTOR_FIRE_LOG_LINES="${DOCTOR_FIRE_LOG_LINES}
WARN the fire log's last recorded firing is too old (${age} seconds ago, threshold ${REIN_HOOK_ACTIVITY_STALE_SEC} seconds)"
      bad=1
    fi
  fi
  size="$(rein_file_size "$file")"
  case "$size" in
    '' | *[!0-9]*) size=0 ;;
  esac
  if [ "$size" -ge "$REIN_HOOK_FIRE_LOG_MAX_BYTES" ]; then
    DOCTOR_FIRE_LOG_LINES="${DOCTOR_FIRE_LOG_LINES}
WARN the fire log is over the size cap and has not been archived (${size} bytes, cap ${REIN_HOOK_FIRE_LOG_MAX_BYTES}). Confirm no live run still holds the archiving lock before removing it: rm -rf $(rein_shell_quote "${file}.lock")"
    bad=1
  fi
  return "$bad"
}

# Whether a different lineage (a current pointer) exists in a parent directory. A lineage is
# scoped by cwd, so `/proj` and `/proj/sub` run **as separate lineages** in parallel (with
# separate records and separate handover wiring). That is a legitimate way to use it on its
# own, so this does not refuse it, but running two of them without noticing is a likely
# accident -- so this names where it is in one line. The result is returned via a variable
# (the parent directory found).
NESTED_LINEAGE_DIR=""
find_nested_lineage() {
  local dir="$1"
  NESTED_LINEAGE_DIR=""
  while [ "$dir" != "/" ] && [ -n "$dir" ]; do
    dir="${dir%/*}"
    [ -n "$dir" ] || break
    if [ -f "$dir/$REIN_RECORDS_DIRNAME/$REIN_POINTER_BASENAME" ]; then
      NESTED_LINEAGE_DIR="$dir"
      return 0
    fi
  done
  return 1
}

doctor_nested_lineage() {
  if find_nested_lineage "$TARGET_CWD"; then
    doctor_warn "a different lineage exists in a parent directory (a lineage is scoped by cwd. If running two was not intended, run rein down on one of them): ${NESTED_LINEAGE_DIR}" # lineage-cmd-exempt: the one that would be shut down here is a **different lineage** in a parent directory, and its runtime directory cannot be resolved from here (filling in this lineage's effective value would give misleading advice)
    return 1
  fi
  doctor_ok "no other lineage exists in a parent directory"
  return 0
}

# The temporary settings rein creates to launch (for disabling worktree isolation) are meant
# to be removed by the successor's SessionStart. Any that remain are the mark of "the session
# it launched never came up," so this names where they are (removing them is the user's call
# -- it can be material for investigating why the launch failed).
doctor_managed_settings_leftovers() {
  local file count=0
  for file in "$RUNTIME_DIR/$REIN_MANAGED_SETTINGS_PREFIX"*; do
    [ -f "$file" ] || continue
    count=$((count + 1))
    doctor_warn "a temporary launch settings file remains (the session it launched may never have come up. You can remove it after checking its content): ${file}"
  done
  if [ "$count" -eq 0 ]; then
    doctor_ok "no temporary launch settings remain"
  fi
  return 0
}

# Handover requests left stranded mid-judgment (in `processing/`). A watcher can claim one
# (`mv` into `processing/`) and then go down from a mechanism failure, leaving that round's
# marker here (this is specified behavior). **Recovering them only ever runs when the next
# watcher starts**, so a state left this way with no watcher present, if left alone, silently keeps
# blocking the Stop hook's handover trigger without anyone noticing (the hook finds its own
# session_id inside `processing/` and reads that as "already submitted," so it never prompts
# to stop). This reports the count and the path to recovering them.
doctor_processing_leftovers() {
  local dir="$RUNTIME_DIR/$REIN_PROCESSING_DIRNAME" file count=0
  for file in "$dir"/*.json; do
    [ -f "$file" ] || continue
    count=$((count + 1))
  done
  if [ "$count" -eq 0 ]; then
    doctor_ok "no handover requests are stranded mid-judgment: ${dir}"
    return 0
  fi
  rein_lineage_cmd "$CLI_REIN_CMD" "$RUNTIME_DIR" "$RECORDS_DIR" "$TARGET_CWD" up
  doctor_warn "handover requests stranded mid-judgment: ${count} (that session's handover trigger stays blocked in the meantime): ${dir}. Starting the watcher recovers them to rejected at startup: ${REIN_LINEAGE_CMD}"
  return 0
}

# A lineage where only the handover's final step (retiring the predecessor session) is left
# unfinished. A handover proceeds as "launch the successor -> advance the pointer -> retire
# the predecessor session," so if the watcher goes down at the final step, it stalls at "successor
# alive, predecessor session alive, watcher absent" -- **there was no way to notice this shape**
# (since the pointer already points at the successor, every handover request from then on
# just keeps getting rejected with R10).
# **Mid-handover legitimately passes through this same shape** too (both coexist during the
# grace period), so this tells them apart by whether the watcher is running. The check goes
# through the one shared library function also used by watcher resumption and `status`.
# The enumeration is only fetched for a lineage whose pointer names a predecessor session at all
# (narrowed by the material before fetching -- a lineage that has never handed over even once
# never starts an external process for this).
doctor_incomplete_handover() {
  local rc
  rein_stranded_predecessor "$POINTER_FILE" "$TARGET_CWD"
  rc=$?
  if [ "$rc" -eq 2 ]; then
    doctor_warn "cannot determine whether a handover was left unfinished: $(rein_list_agents_error)"
    return 0
  fi
  # A shape where only one side of the handover went down (the primary session on record is
  # not in the enumeration, yet the predecessor is alive). **This is a state deliberately not
  # auto-fixed**, so this line -- naming it and how to fix it -- is the only way out. Folding
  # it into "unfinished" would produce the **advice that does not work**, "start the watcher
  # to resume" (starting it still stalls at this same shape). The wording goes through the same
  # one function used for the watcher startup handoff and bootstrap.
  if [ "$rc" -eq 3 ]; then
    doctor_fail "$(rein_handover_mismatch_detail "$CLI_REIN_CMD" "$REIN_STRANDED_SUCCESSOR" "$REIN_STRANDED_PREDECESSOR" \
      "$TARGET_CWD" "$(cli_handover_failure_cause)" "$RUNTIME_DIR" "$RECORDS_DIR")"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    doctor_ok "no handover was left unfinished"
    return 0
  fi
  if watcher_state "$RUNTIME_DIR"; then
    doctor_ok "a handover is in progress (the predecessor session ${REIN_STRANDED_PREDECESSOR} coexists with the successor during the grace period)"
    return 0
  fi
  rein_lineage_cmd "$CLI_REIN_CMD" "$RUNTIME_DIR" "$RECORDS_DIR" "$TARGET_CWD" up
  doctor_warn "the handover final step is left unfinished (the predecessor session ${REIN_STRANDED_PREDECESSOR} remains with no watcher present. Handover requests keep getting rejected in the meantime). Starting the watcher resumes it at startup: ${REIN_LINEAGE_CMD}"
  return 0
}

# Whether the lineage records location can be resolved at all. Every other verb stops on this
# (an unresolvable location used to collapse every path derived from it to the filesystem root),
# so **doctor is the only place left that can still name what is wrong** -- it runs with the
# reason carried in RECORDS_ERROR instead of stopping, and turns it into one line.
# The reason itself is never rewritten here: it comes from the same resolver every other verb
# fails on, so the wording the user is told to fix matches the wording that stopped them.
doctor_records_report() {
  if [ -n "$RECORDS_ERROR" ]; then
    doctor_fail "$RECORDS_ERROR"
    return 0
  fi
  doctor_ok "the lineage records location resolves: ${RECORDS_DIR}"
  return 0
}

# A shape where a location **exists but cannot be written to** (a permission or ownership
# mismatch, a read-only mount). The records layer not being writable stops neither hooks nor
# the session (the non-blocking contract), so this state just proceeds with records silently
# missing -- and a missing record then gets read as a **different cause**, "hooks are not
# reaching it" or "the handover is not working." A location that does not exist is not
# abnormal (it gets created when first used), so this does not look at that.
# **It even tracks how many it actually checked**, so that a state with nothing existing yet (a brand
# new machine's first run) does not say "everything is writable" -- wording that reads as
# "checked, no problem" for something not actually checked would leave the user believing
# this aspect was confirmed, only to discover missing records once they start using it (the
# very breakage this section most wants to catch would get deferred). A shape that cannot be
# determined is never treated as green -- the same discipline as every other section of
# doctor.
doctor_writable_dirs() {
  local dir label failed=0 checked=0 total=0
  # The 3: lineage records (the handover log, the pointer), runtime data, and the fire log
  # parent -- every location rein writes to.
  for label in "records:$RECORDS_DIR" "runtime data:$RUNTIME_DIR" "fire log:$STATE_ROOT"; do
    dir="${label#*:}"
    [ -n "$dir" ] || continue
    total=$((total + 1))
    [ -d "$dir" ] || continue
    checked=$((checked + 1))
    if [ ! -w "$dir" ]; then
      doctor_fail "cannot write to the ${label%%:*} location (records will just go silently missing, making hooks and handovers look inactive): ${dir}"
      failed=1
    fi
  done
  [ "$failed" -eq 0 ] || return 0
  if [ "$checked" -eq 0 ]; then
    doctor_warn "none of the locations rein writes to exist yet (writability was not checked. They get created when first used)"
  elif [ "$checked" -lt "$total" ]; then
    doctor_ok "every location that currently exists is writable (${checked}/${total}; the rest do not exist yet)"
  else
    doctor_ok "every location rein writes to is writable"
  fi
  return 0
}

# The newest last-modified time among the implementation files (a proxy for when this
# checkout was updated). Covers the entry-point executable script and the shared library --
# what the resident watcher reads and fixes in place at startup.
doctor_impl_newest_mtime() {
  local file mtime newest=""
  for file in "$REPO_ROOT/bin/$SCRIPT_NAME" "$REPO_ROOT"/scripts/*.sh \
    "$REPO_ROOT"/scripts/lib/*.sh "$REPO_ROOT"/scripts/lib/cli/*.sh; do
    [ -f "$file" ] || continue
    mtime="$(rein_mtime "$file")"
    case "$mtime" in
      '' | *[!0-9]*) continue ;;
    esac
    if [ -z "$newest" ] || [ "$mtime" -gt "$newest" ]; then
      newest="$mtime"
    fi
  done
  printf '%s\n' "$newest"
}

# The record of when the resident watcher started (the ts of `watch_started`). Multiple
# startup records can remain, so this looks only at **the row for the currently live pid**
# (never reading another round's startup time as this watcher's own).
doctor_watch_started_epoch() {
  local pid="$1" ts
  [ -f "$LOG_FILE" ] || return 1
  ts="$(jq -r --arg pid "pid=${pid} " '
    [ .[] | select(.event == "watch_started")
          | select((.detail // "") | contains($pid)) ] | (last // empty) | .ts // empty' \
    -s "$LOG_FILE" 2>/dev/null)"
  [ -n "$ts" ] || return 1
  rein_iso_to_epoch "$ts"
}

# Whether a running watcher is **still running the code it started with**. Only config gets
# re-read each cycle, so updating the checkout with `git pull` still leaves a running watcher
# operating on the old implementation (there is a real case on this machine of two lineages
# running old code, making a fix that was supposed to have landed appear to recur). The only
# material for judging this is "when the watcher started" and "when the implementation files
# were last modified."
doctor_watcher_code_drift() {
  local started newest down_cmd
  watcher_state "$RUNTIME_DIR" || return 0
  started="$(doctor_watch_started_epoch "$WATCHER_PID")" || {
    doctor_warn "cannot read the resident watcher startup time from the handover log (cannot determine whether it is still running the code it started with): ${LOG_FILE}"
    return 0
  }
  newest="$(doctor_impl_newest_mtime)"
  case "$newest" in
    '' | *[!0-9]*) return 0 ;;
  esac
  if [ "$newest" -le "$started" ]; then
    doctor_ok "the resident watcher started with the current implementation"
    return 0
  fi
  rein_lineage_cmd "$CLI_REIN_CMD" "$RUNTIME_DIR" "$RECORDS_DIR" "$TARGET_CWD" down
  down_cmd="$REIN_LINEAGE_CMD"
  rein_lineage_cmd "$CLI_REIN_CMD" "$RUNTIME_DIR" "$RECORDS_DIR" "$TARGET_CWD" up
  doctor_warn "the implementation has been updated since the resident watcher started (it is still running the old code). To pick it up, reinstall this lineage: ${down_cmd} && git -C $(rein_shell_quote "$REPO_ROOT") pull && claude plugin update $(rein_plugin_exact_id) && ${REIN_LINEAGE_CMD}" # run-limit-exempt: advisory text shown to the user (this line never starts an external process)
  return 0
}

# Turns judging the managed settings into a line. The mapping from return value to line is
# kept closed in here for the same reason as other sections (a mix-up that drops an
# undeterminable shape to the OK side would pass unnoticed by a check that only looks at the
# judging function's return value). The judgment itself goes through **the one shared
# function also used on the launch side** (watcher, up) -- so an environment doctor passed
# never turns out to fail only at launch. Whether the material could even be read is also
# returned by that same judgment (2), so the diagnostic never needs a second reader opening
# this file.
# The only difference is **how it is received**: launch treats 2 as a warning and continues;
# the diagnostic never treats 2 as green (never calling an undeterminable shape OK -- the
# same discipline as the plugin enablement state and the marketplace's real location).
doctor_managed_policy_report() {
  local rc
  rein_managed_policy_conflicts
  rc=$?
  if [ "$rc" -eq 0 ]; then
    doctor_ok "the organization managed settings do not force background session isolation"
  else
    doctor_fail "$REIN_MANAGED_POLICY_ERROR"
  fi
  return 0
}

cmd_doctor() {
  local rc link resolved lock_line legacy claude_path path_rein path_resolved
  local owner_matches token_mode
  while [ $# -gt 0 ]; do
    take_verb_opt "$@"
    rc=$?
    case "$rc" in
      0) shift "$VERB_SHIFT" ;;
      2) return 2 ;;
      *)
        fail_usage "unknown argument to doctor: $1"
        return 2
        ;;
    esac
  done
  # **The one caller that keeps going with an unresolvable records location** -- diagnosing that
  # state is this verb's job, so stopping here would take away the tool that names it (the reason
  # comes back in RECORDS_ERROR and is reported by doctor_records_report below).
  prepare_runtime --records-optional || return 1
  DOCTOR_FAIL=0
  # The name used in guidance stays **the same throughout this one output** (mixing a bare
  # rein and a real file path from line to line would leave the user unable to tell which
  # form actually runs).
  cli_rein_cmd

  if rein_check_prerequisites "$REIN_BIN_PATH"; then
    # Never hand-written -- prints exactly the set the check **saw**, the same material
    # source as the FAIL line printing REIN_MISSING_TOOLS as-is. Hand-writing it would go stale
    # here alone the day a tool is added to the check, producing "a tool missing from the OK
    # line shows up in the FAIL line" (this actually happened with `ps`).
    doctor_ok "the prerequisite tools (${REIN_PREREQUISITE_TOOLS}) work"
  else
    doctor_fail "prerequisite tools don't work: ${REIN_MISSING_TOOLS}"
  fi

  # The Claude Code CLI itself. rein delegates launching the successor, enumeration,
  # external stops, and plugin installation entirely to this one command, so if it cannot be
  # resolved, a handover can never happen even once (the prerequisite tools check only looks
  # at external commands rein itself uses, so this is checked separately here).
  claude_path="$(command -v claude 2>/dev/null)"
  if [ -n "$claude_path" ]; then
    doctor_ok "the claude command resolves: ${claude_path}"
  else
    doctor_fail "the claude command is not on PATH (the Claude Code CLI is required. Launching the successor, enumeration, external stops, and plugin installation all go through this command)"
  fi

  # rein never runs the usage writer itself -- it only reads this location. Without it,
  # threshold checks can never happen.
  doctor_usage_state_report

  # **Who writes to that location** is the statusLine in the user-scope settings file. Without a
  # registration, records never grow, a handover never once happens, and only "the
  # monitoring mechanism is not working" keeps getting injected.
  # **Whether it is the bundled one is not the pass/fail criterion** (rein requires only the
  # record's shape) -- a different writer is still OK if it writes records matching the
  # contract. Making this a permanent WARN would keep sounding for a correctly working setup.
  doctor_statusline_state
  rc=$?
  case "$rc" in
    0)
      doctor_ok "statusLine has the rein bundled usage writer registered: ${DOCTOR_STATUSLINE_FILE}"
      # A registration existing alone does not mean it "runs" -- run that writer once to
      # confirm.
      doctor_statusline_smoke_report
      ;;
    1)
      if [ "$DOCTOR_USAGE_OK" -eq 1 ]; then
        doctor_ok "statusLine has a different writer registered, but it writes to the contract: ${DOCTOR_STATUSLINE_COMMAND}"
      else
        doctor_warn "statusLine is registered but is not the rein bundled writer, and a record matching the contract cannot be confirmed either (see the usage record check above): ${DOCTOR_STATUSLINE_COMMAND}"
      fi
      ;;
    # A different checkout's real file is reported even when its records match the contract
    # (an update only takes effect on one of them -- the same shape as "never overwrites a
    # link that points at a different real file" for the install symlink).
    5)
      # On a machine where the expansion target cannot be produced (HOME is empty or
      # relative), instead of recommending the folded `/<relative>`, **name the reason it
      # cannot be produced** (recommending a target to rewrite to would leave a registration
      # that never runs still not running).
      if [ -n "$DOCTOR_STATUSLINE_TILDE_HINT" ]; then
        doctor_fail "the statusLine registration uses ~ inside quotes, but the shell never expands a ~ inside quotes (this registration does not run, so usage is never recorded. Rewrite ~ to an absolute path and quote it -- for this environment that would be \"${DOCTOR_STATUSLINE_TILDE_HINT}\"): ${DOCTOR_STATUSLINE_COMMAND}"
      else
        doctor_fail "the statusLine registration uses ~ inside quotes, but the shell never expands a ~ inside quotes (this registration does not run, so usage is never recorded. Rewrite ~ to an absolute path and quote it. This machine has no HOME set to an absolute path, so the absolute path to rewrite to cannot be produced): ${DOCTOR_STATUSLINE_COMMAND}"
      fi
      ;;
    4) doctor_warn "statusLine has a rein writer registered, but from a different checkout (an update only takes effect on this repository): ${DOCTOR_STATUSLINE_COMMAND} -> ${DOCTOR_STATUSLINE_TARGET:-cannot resolve}" ;;
    3) doctor_fail "cannot read the user-scope settings file as JSON (cannot determine the statusLine registration): ${DOCTOR_STATUSLINE_FILE}" ;;
    *)
      doctor_fail "statusLine is not registered (with no mechanism writing usage, handovers never start)"
      doctor_statusline_snippet
      ;;
  esac

  # There is one real file (if the hook side and the daemon side point at different real
  # files, an update only takes effect on one of them).
  link="$(rein_link_path)"
  if [ -e "$link" ] || [ -L "$link" ]; then
    resolved="$(resolve_self "$link")"
    if [ "$resolved" = "$REIN_BIN_PATH" ]; then
      doctor_ok "the PATH-callable command real file matches: ${link}"
      # Placing it alone does not make it runnable -- macOS's default PATH has no
      # `~/.local/bin`. Both a session prompted to hand over and the guidance a skill gives
      # run **`rein` on PATH**, so a shape that cannot be resolved leaves things at
      # "installed, but a handover request cannot even be run" (looking only at the install
      # check reports green).
      path_rein="$(command -v "$SCRIPT_NAME" 2>/dev/null)"
      if [ -z "$path_rein" ]; then
        doctor_fail "cannot call ${SCRIPT_NAME} from PATH (${link%/*} is not on PATH. Add to your shell rc: export PATH=\"${link%/*}:\$PATH\")"
      else
        path_resolved="$(resolve_self "$path_rein")"
        if [ "$path_resolved" = "$REIN_BIN_PATH" ]; then
          doctor_ok "can call ${SCRIPT_NAME} from PATH: ${path_rein}"
        else
          doctor_fail "the ${SCRIPT_NAME} on PATH points at a different real file (${path_rein} -> ${path_resolved:-cannot resolve}). Put ${link%/*} at the front of PATH"
        fi
      fi
    else
      doctor_fail "the real file of ${link} differs from ${REIN_BIN_PATH}: ${resolved:-cannot resolve}"
    fi
  else
    # The PATH check only runs once it is installed (never splitting the single fact "not
    # installed" into 2 FAIL lines).
    # The advice is **something that can be run as-is for this lineage** -- `init` lays down
    # its template per lineage, so advice without `--cwd` would lay down a template for the
    # lineage of wherever it is run. The name used is the one cli_rein_cmd decided (in this
    # branch, no other real file is normally even present on PATH, so the real file path is
    # what gets shown).
    rein_lineage_cmd "$CLI_REIN_CMD" "$RUNTIME_DIR" "$RECORDS_DIR" "$TARGET_CWD" init
    doctor_warn "${link} does not exist (to install it: ${REIN_LINEAGE_CMD}. To place it by hand: ln -s $(rein_shell_quote "$REIN_BIN_PATH") $(rein_shell_quote "$link"))"
  fi
  # Hooks are registered on the plugin side, so if it is disabled, neither advisories nor
  # any handover wiring ever fires. A shape that cannot be determined (cannot call the CLI,
  # cannot read the JSON) is never called OK.
  doctor_plugin_state
  rc=$?
  # The install advice is **something that can be run as-is for this lineage** (built through
  # the one shared function).
  rein_lineage_cmd "$CLI_REIN_CMD" "$RUNTIME_DIR" "$RECORDS_DIR" "$TARGET_CWD" init
  case "$rc" in
    0) doctor_ok "the plugin is enabled (hooks fire): ${DOCTOR_PLUGIN_ID}" ;;
    1) doctor_fail "the plugin is installed but disabled (hooks do not fire. To enable it: claude plugin enable ${DOCTOR_PLUGIN_ID} --scope user, or ${REIN_LINEAGE_CMD})" ;;
    3) doctor_warn "the plugin is not installed (hooks do not fire. To install it: ${REIN_LINEAGE_CMD})" ;;
    *) doctor_fail "cannot determine the plugin enablement state (cannot read claude plugin list --json)" ;;
  esac
  # Even with the ID matching, if its marketplace points at a different checkout, the hooks
  # that fire are **that different real location's** (checking only the enablement state
  # reports green). This line is not added on a run where it is not installed, so the same
  # single fact (not yet installed) does not get split into 2 abnormal lines.
  if [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; then
    doctor_plugin_root_report
  fi

  # Even with the registration present, if its execution path (launcher -> runner) does not
  # resolve, not a single hook fires. The SessionStart side also has a line for "rein is not
  # on PATH," but that is advice about **whether the handover request command can be run**,
  # not a check of the hooks path.
  doctor_hook_command_report

  # The path resolving and **actually running** are different things. Not-running
  # abnormalities (the registration is not enabled, the launcher cannot trace to a real
  # file, an advisory never reaches its target) are checked via the health state hooks write.
  # A health abnormality is a WARN (the line itself declares OK / WARN) -- not recounted as
  # FAIL here.
  doctor_hook_health_state || :
  if [ -n "$DOCTOR_HOOK_HEALTH_LINES" ]; then
    printf '%s\n' "$DOCTOR_HOOK_HEALTH_LINES"
  fi

  # Running (health state) and **what it printed** (the fire log) are yet another separate thing.
  # A log abnormality is also a WARN (the line itself declares OK / WARN) -- not recounted as
  # FAIL here.
  doctor_hook_fire_log_state || :
  if [ -n "$DOCTOR_FIRE_LOG_LINES" ]; then
    printf '%s\n' "$DOCTOR_FIRE_LOG_LINES"
  fi

  # Whether the temporary settings created for launch remain (they are meant to be removed
  # by the successor's SessionStart).
  doctor_managed_settings_leftovers

  # A nested lineage (a different lineage in a parent directory). A lineage is scoped by cwd,
  # so running a second one inside a work tree where a parent directory has `rein up` running
  # means both the records and the handover wiring proceed separately.
  doctor_nested_lineage

  # Background session isolation is **disabled by rein in the launch settings** (independent
  # of what the user's own setting specifies), so what matters is not whether the user's own
  # value is none, but these 2 points instead:
  #   (1) can the launch settings be built (does the user's own value read as an object)
  #   (2) do the organization managed settings force a different value
  # An old warning reading "no specification in the user's own setting means isolation stays
  # enabled" disagrees with how merging actually behaves now (rein always layers none on top,
  # so having no specification is not abnormal).
  doctor_settings_report
  doctor_managed_policy_report

  # The judging function returns 0 for both "not a different owner" and "no owner is present
  # yet" (a contract so that a reader that only reads never stalls on a location with no
  # claim). If doctor folded those two into the same OK line, it would flatly claim "matches"
  # even for **a location with no owner file** -- the state `status --all` reports as "(owner
  # unknown)", where nothing has claimed the location yet. This checks whether the claim exists
  # at all (REIN_RUNTIME_OWNER_PRESENT) too,
  # splitting it into 3 outcomes.
  owner_matches=0
  if [ ! -d "$RUNTIME_DIR" ]; then
    doctor_warn "the runtime data location does not exist yet: ${RUNTIME_DIR}"
  elif ! rein_verify_runtime_owner "$RUNTIME_DIR" "$TARGET_CWD"; then
    doctor_fail "$REIN_RUNTIME_ERROR"
  elif [ "$REIN_RUNTIME_OWNER_PRESENT" -eq 1 ]; then
    owner_matches=1
    doctor_ok "the runtime data location owner matches: ${RUNTIME_DIR}"
  else
    rein_lineage_cmd "$CLI_REIN_CMD" "$RUNTIME_DIR" "$RECORDS_DIR" "$TARGET_CWD" init
    doctor_warn "the runtime data location has no owner record (which project it belongs to cannot be traced from outside, and hooks do not fire for this project either. To create one: ${REIN_LINEAGE_CMD}): ${RUNTIME_DIR}"
  fi

  # The lineage token sits next to the owner file and is checked here for the same reason: it is
  # a precondition for hooks acting at all, and **nothing else in normal use ever reports on
  # it**. A session launched without one fails loud on every event, and the only visible symptom
  # is stderr inside that session -- which nobody reads until something is already broken.
  # The two failures get different severities, because they mean different things. Missing (or
  # holding something that is not a token) is **WARN**, the same as a location with no owner
  # record: the consequence is the same one -- hooks do not act for this lineage -- and it is a
  # state the next `rein up` resolves on its own, including for a lineage that was claimed
  # before tokens existed. The mode being anything but 0600 is **FAIL**: hooks still work, but the
  # value other users on this machine can now read is the one thing that separates a marker rein
  # issued from a marker a project's settings named, and no later run repairs a mode.
  # The check runs **only when the owner check above came out matching** (owner_matches). For a
  # location that does not exist, whose owner is a different project, or that nothing has
  # claimed, there is no lineage of this project's here to hold a token, and the line above
  # already says what is wrong -- a second line about the token would only add noise to a
  # problem the reader has to fix first anyway.
  if [ "$owner_matches" -ne 1 ]; then
    :
  elif ! rein_read_runtime_token "$RUNTIME_DIR"; then
    rein_lineage_cmd "$CLI_REIN_CMD" "$RUNTIME_DIR" "$RECORDS_DIR" "$TARGET_CWD" up
    doctor_warn "${REIN_RUNTIME_ERROR} (until one is placed, a session launched for this lineage has its hooks fail loud on every event. To place one: ${REIN_LINEAGE_CMD})"
  else
    token_mode="$(stat -f '%Lp' "$RUNTIME_DIR/$REIN_TOKEN_BASENAME" 2>/dev/null)"
    if [ "$token_mode" = "600" ]; then
      doctor_ok "the lineage token is in place: ${RUNTIME_DIR}/${REIN_TOKEN_BASENAME}"
    else
      doctor_fail "the lineage token's mode is not 0600 (found ${token_mode:-unknown}) -- this value is what tells a marker rein issued apart from one a project's settings named, so anyone else on this machine who can read it can forge a marker for this lineage: ${RUNTIME_DIR}/${REIN_TOKEN_BASENAME}"
    fi
  fi

  # Handover requests stranded mid-judgment (in `processing/`). Recovering them only ever
  # runs when a watcher starts, so **if something stays stranded with no watcher present, that
  # state shows up nowhere** -- the Stop hook finds its own session_id inside `processing/`
  # and reads that as "the handover request was already submitted," so it never prompts to
  # stop, leaving that session's handover trigger blocked. Neither `rein status` nor the
  # archive scan looks at `processing/`, so this is the only place that notices.
  doctor_processing_leftovers

  # A lineage where only the handover's final step is left unfinished (the same as the
  # `processing/` leftovers -- if left alone with no watcher present, it shows up nowhere).
  doctor_incomplete_handover

  # The handoff document's section structure. Only the handover request holds the acceptance
  # judgment, so with nowhere else to notice a drift, it would only be discovered
  # **right before a handover with context running out** (both the current-state report and
  # doctor still green). Resolving the effective value and the judgment go through the same
  # one function as the current-state report (doctor never keeps a second resolution).
  # This is **display only** -- it does not count toward FAIL, and is not folded into the
  # acceptance judgment (STATUS_HANDOFF_PRESENT) either -- so it never changes the meaning
  # anywhere but the handover request path.
  # **stderr is silenced for this one call.** The records resolver names its own rejection by
  # printing to stderr from inside the shared library (most of its callers sit inside `$( )`,
  # where a variable would never reach them), and resolving the handoff document's default
  # location goes through it. doctor already reports that same rejection as its own FAIL line
  # (doctor_records_report below), so leaving it unsilenced put the identical reason into the
  # middle of the report a second time, as a raw `rein: ...` line belonging to no section. Only
  # this call site is silenced -- every other caller still gets the reason. Nothing is lost here:
  # the reason this branch prints arrives through REIN_CONFIG_ERROR.
  if ! status_handoff_state 2>/dev/null; then
    doctor_warn "cannot determine the handoff document section structure (${REIN_CONFIG_ERROR})"
  elif [ "$STATUS_HANDOFF_PRESENT" -eq 1 ] && [ "$STATUS_HANDOFF_SECTIONS_OK" -eq 0 ]; then
    doctor_warn "the handoff document section structure does not match the template (${STATUS_HANDOFF_SECTIONS_DETAIL}). Requesting a handover in this shape will be rejected: ${STATUS_HANDOFF_PATH}"
  fi

  # Whether the records location resolves at all. Checked before writability, since a location
  # that never resolved has nothing to check for writability (doctor_writable_dirs skips an empty
  # one, and would otherwise report "everything that exists is writable" for a broken lineage).
  doctor_records_report

  # A shape where a location exists but cannot be written to (the records layer not being
  # writable does not stop anything -- it goes silently missing).
  doctor_writable_dirs

  # Whether the resident watcher is still running the code it started with (an update only
  # takes effect via down -> up).
  doctor_watcher_code_drift

  # The operation lock serializes `up` / `down`. Since the rule is never to seize a lock
  # whose pid cannot be read, one left behind blocks every startup and stop after it (leaving
  # the user stuck unless how to remove it is also advised).
  lock_line="$(op_lock_state_line)"
  rc=$?
  if [ ! -d "$OP_LOCK_DIR" ]; then
    doctor_ok "no operation lock remains: ${OP_LOCK_DIR}"
  elif [ "$rc" -ne 0 ]; then
    doctor_fail "operation lock: ${lock_line}"
  else
    doctor_warn "operation lock: ${lock_line}"
  fi

  # The old-format watcher log (nohup's redirect target). It is identified only by the cwd's
  # basename, so an environment with 2 work trees of the same name could have this pointing
  # at a different lineage's leftovers -- removing it is the user's call.
  legacy="$(legacy_watcher_log_path)"
  if [ -f "$legacy" ]; then
    # Naming where the current one lives needs the records location. On a lineage whose records
    # never resolved, that half of the sentence is dropped rather than emitted as `/watcher.log`
    # (the reason is already on its own FAIL line above).
    if [ -n "$RECORDS_DIR" ]; then
      doctor_warn "an old-format watcher log remains (the current watcher log is ${RECORDS_DIR}/${REIN_WATCHER_LOG_BASENAME}. You can remove it after checking its content: rm $(rein_shell_quote "$legacy"))"
    else
      doctor_warn "an old-format watcher log remains (where the current watcher log lives cannot be named while the records location does not resolve. You can remove it after checking its content: rm $(rein_shell_quote "$legacy"))"
    fi
  fi

  [ "$DOCTOR_FAIL" -eq 0 ]
}
