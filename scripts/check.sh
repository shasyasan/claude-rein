#!/usr/bin/env bash
# Aggregate runner that runs every gate with a single command.
# Doesn't use errexit: every gate's result has to show even when one gate fails (pass/fail is tracked with a failure counter).
set -uo pipefail

# Derives its own location using **string operations only** (never shell out to dirname / basename). Handing that resolution
# off to an external command breaks on a machine where that command returns empty (a same-named command that returns empty
# sitting at the front of PATH). The destination becomes empty, and **the current directory gets grabbed as its own location**, so it loads
# and runs whatever lib/rein-selftest-sections.sh / lib/rein-selftest-supervisor.pl happens to sit in the working directory
# (measured: launching from a booby-trapped directory runs that file's contents inside this process).
# **A relative path is resolved against the current directory** (never dropped -- same as scripts/rein-hook.sh). The dev conventions
# tell people to launch via the literal relative path `scripts/check.sh`, so dropping it would break launching exactly as
# documented. Resolving it this way is safe because the relative-path base is the shell's own idea of the current directory
# at the moment it found this file (never swapped out from outside) -- unlike a location decided by an external command's output.
# Only the leading `./` is stripped before prefixing (so the `ROOT` display and the path in scan results never mix in `/./`).
CHECK_SELF_PATH="${BASH_SOURCE[0]}"
case "$CHECK_SELF_PATH" in
  /*) ;;
  ./*) CHECK_SELF_PATH="$PWD/${CHECK_SELF_PATH#./}" ;;
  *) CHECK_SELF_PATH="$PWD/$CHECK_SELF_PATH" ;;
esac
SCRIPT_DIR="${CHECK_SELF_PATH%/*}"
SCRIPT_NAME="${CHECK_SELF_PATH##*/}"
REPO_ROOT="${SCRIPT_DIR%/*}"

# Override point that lets selftest point gates at the fixture directory.
# Only the scan root is swapped, never the judging logic, so the real gate logic runs unmodified and no second execution path exists.
ROOT="${REIN_CHECK_ROOT:-$REPO_ROOT}"
# Override point so selftest can measure the missing-prerequisite-tool path.
SHELLCHECK_BIN="${REIN_SHELLCHECK:-shellcheck}"
JQ_BIN="${REIN_JQ:-jq}"
# The real 3.2 bash. It has an override point so selftest can measure both sides of this mechanism
# itself: actually running it, and skipping it when it's the same binary as PATH's bash.
BASH32_BIN="${REIN_BASH32:-/bin/bash}"
PERL_BIN="${REIN_CHECK_PERL:-perl}"
SELFTEST_SUPERVISOR="$SCRIPT_DIR/lib/rein-selftest-supervisor.pl"
# Finite per-selftest cap. Only has an override point for fixtures to measure a short cap; the normal value
# leaves enough room that even a large selftest isn't cut off partway.
# This value is **a guardrail, not a target** -- it exists only to fail a stuck selftest in finite time.
# Don't lower it even if actual run time shrinks (pushing it close to actual run time cuts off healthy runs on a
# loaded machine too, and neither green nor red stays trustworthy -- when it was 300 seconds, 3 of 5 runs actually failed on deadline overrun).
# Trimming the actual run time is selftest's own job; this value doesn't get trimmed for that.
SELFTEST_DEADLINE_SEC="${REIN_CHECK_SELFTEST_DEADLINE_SEC:-600}"
SELFTEST_MAX_DEADLINE_SEC=3600
# Exit code when the supervisor cuts a run off on deadline (same value the supervisor side uses;
# a mismatch fails the proc:deadline hang fixture).
SELFTEST_DEADLINE_RC=142
SELFTEST_STREAM_FIXTURE_POLLS=200

gate_pass_count=0
gate_fail_count=0
gate_skip_count=0

# Environment variables to drop when launching selftest (an `env` argument list).
SELFTEST_ENV_ARGS=()

# Drop the surrounding REIN_* variables before launching selftest. If they're left in place, the isolation knobs
# (REIN_CONFIG_FILE, REIN_RUNTIME_DIR) keep pointing at the real config and real state while the check runs, and
# the settings key's environment layer changes what the accepting side of a check even means (false red, a check spinning on nothing). Only this script's own override points are kept.
selftest_env_args() {
  local name
  SELFTEST_ENV_ARGS=()
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    case "$name" in
      REIN_CHECK_ROOT | REIN_SHELLCHECK | REIN_JQ | REIN_BASH32 | REIN_CHECK_PERL | REIN_CHECK_SELFTEST_DEADLINE_SEC) continue ;;
    esac
    SELFTEST_ENV_ARGS+=(-u "$name")
  done <<EOF
$(env | sed -n 's/^\(REIN_[A-Za-z0-9_]*\)=.*/\1/p')
EOF
}

gate_pass() {
  gate_pass_count=$((gate_pass_count + 1))
  printf '  PASS %s\n' "$1"
}

gate_fail() {
  gate_fail_count=$((gate_fail_count + 1))
  printf '  FAIL %s: %s\n' "$1" "$2"
}

# Showing "zero targets to check" with the same face as PASS lets a state where nothing was checked read as green.
gate_skip() {
  gate_skip_count=$((gate_skip_count + 1))
  printf '  SKIP %s: %s\n' "$1" "$2"
}

# Scan targets. **Check what actually gets distributed** -- the primary source is the set git manages (tracked files plus untracked
# files that aren't ignored). Writing a second copy of the ignore list (`.gitignore`) into the check side
# would split it across two places that are bound to drift, and the moment this repo applies its own recommended usage
# (`rein init` / `rein up` in a target project) to itself, `<cwd>/.rein/` (the lineage's records and the handoff document's
# location -- not a deliverable) lands inside the scan target. Once it's in, free-form text written mid-task doesn't just get
# flagged red by the docs-links check -- **the contents of a handoff document written for a different project get
# quoted verbatim into the FAIL output**. For the same reason that the "Distribution" section of the dev conventions
# never just compresses the working tree as-is, checking and distributing look at the same set.
# Untracked files that aren't ignored are included too (`--others --exclude-standard`). Matching `git archive`'s
# "tracked only" would leave a new file that hasn't been added yet outside every gate's scope, and **passing checks before
# a commit** -- the very use case -- would become a no-op.
# A machine without git, and a scan root that isn't the root of a git working tree (selftest fixtures are a
# temp directory), fall back to `find`. A fallback run doesn't see `.gitignore` -- it's checking a different set,
# so **which one was used is shown on the scan-root line** (the set is never swapped silently).
SCAN_SOURCE=""

# Checks whether the scan root actually is the root of a git working tree. If it isn't, git's set can reach beyond that
# root, so it's not used (a run pointed at a subtree must never pull in files outside the scan root). Compares by
# device:inode so the same place reads as the same place across a symlinked path.
scan_root_is_git_toplevel() {
  local top
  [ -d "$ROOT" ] || return 1
  command -v git >/dev/null 2>&1 || return 1
  top="$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [ -n "$top" ] || return 1
  [ "$(stat -f '%d:%i' "$top" 2>/dev/null)" = "$(stat -f '%d:%i' "$ROOT" 2>/dev/null)" ]
}

# Never switches which side the material comes from mid-run (never lets each gate look at a different set).
# The override point for the scan root (selftest fixtures) resets SCAN_SOURCE too.
scan_resolve_source() {
  [ -z "$SCAN_SOURCE" ] || return 0
  if scan_root_is_git_toplevel; then
    SCAN_SOURCE="git"
  else
    SCAN_SOURCE="find"
  fi
}

# The one word shown on the scan-root line (never lets a fallback go unstated).
scan_source_label() {
  scan_resolve_source
  case "$SCAN_SOURCE" in
    git) printf '%s\n' 'files under git management (tracked plus untracked and not ignored)' ;;
    *) printf '%s\n' 'find (cannot use the set git manages, so .gitignore is not honored)' ;;
  esac
}

scan_find_files() {
  find "$ROOT" \
    \( -name .git -o -name node_modules \) -prune -o \
    -type f -print | LC_ALL=C sort
}

# `-z` is used to receive output because git, by default, emits non-ASCII paths octal-escaped and quoted
# (receiving them newline-delimited would let a file with a non-ASCII name slip past checks as a nonexistent path).
scan_git_files() {
  git -C "$ROOT" ls-files -z --cached --others --exclude-standard 2>/dev/null |
    while IFS= read -r -d '' rel; do
      [ -n "$rel" ] || continue
      # Drops deleted entries still in the index and submodule entries, matching the set `find -type f` would give.
      [ -f "$ROOT/$rel" ] || continue
      [ ! -L "$ROOT/$rel" ] || continue
      printf '%s\n' "$ROOT/$rel"
    done | LC_ALL=C sort
}

collect_all_files() {
  scan_resolve_source
  case "$SCAN_SOURCE" in
    git) scan_git_files ;;
    *) scan_find_files ;;
  esac
}

# Filters by trailing spelling (`.md`, etc). Building the `case` pattern from a variable (`$suffix)`) would let the value expand
# as a glob, widening the match for any file whose name contains a glob metacharacter.
collect_files_with_suffix() {
  local suffix="$1" file all
  all="$(collect_all_files)" || return 1
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    case "$file" in
      *"$suffix") printf '%s\n' "$file" ;;
    esac
  done <<EOF
$all
EOF
}

# Returns the interpreter name a shebang points to. Judging by extension would leave a command body with no extension
# (under bin/) outside the scope of every gate.
# A form with `env` in between means the next word is the real command. A form like `env -S <cmd> <args>` is resolved through to the real command too.
# An unresolvable `env` option (-i / -u NAME / -P path, etc) returns 2 so the caller can fail loud
# (silently dropping it from scope would let files the convention doesn't reach grow silently).
# 0 = prints the interpreter name / 1 = no shebang, not a shell / 2 = an unresolvable shebang.
shebang_interpreter() {
  local first head rest word
  IFS= read -r first <"$1" 2>/dev/null || return 1
  case "$first" in
    '#!'*) ;;
    *) return 1 ;;
  esac
  first="${first#\#!}"
  read -r head rest <<EOF
$first
EOF
  case "${head##*/}" in
    '')
      return 1
      ;;
    env) ;;
    *)
      printf '%s\n' "${head##*/}"
      return 0
      ;;
  esac
  # From here on it's env's argument list. Resolves one option word at a time up to the real command.
  while [ -n "$rest" ]; do
    word="${rest%% *}"
    case "$word" in
      "$rest") rest="" ;;
      *) rest="${rest#* }" ;;
    esac
    case "$word" in
      '')
        continue
        ;;
      -S)
        continue
        ;;
      -S*)
        printf '%s\n' "${word#-S}"
        return 0
        ;;
      --)
        continue
        ;;
      -*)
        return 2
        ;;
      *)
        printf '%s\n' "${word##*/}"
        return 0
        ;;
    esac
  done
  return 1
}

# The complete set of shell scripts (extension .sh, plus any file whose shebang points to a shell).
# If enumeration itself fails (no scan root, etc), never return it as an empty set. Not being able to tell that apart from
# an actually-empty set lets "nothing was checked" pass with the face of SKIP.
collect_shell_files() {
  local file sh all merged rc word_interpreter
  sh="$(collect_files_with_suffix '.sh')" || return 1
  all="$(collect_all_files)" || return 1
  merged="$sh"
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    case "$file" in
      *.sh) continue ;;
    esac
    word_interpreter="$(shebang_interpreter "$file")"
    rc=$?
    if [ "$rc" -eq 2 ]; then
      printf 'cannot resolve shebang (unsupported env option form): %s\n' "$file" >&2
      return 1
    fi
    case "$word_interpreter" in
      bash | sh) merged="${merged}${merged:+$'\n'}${file}" ;;
    esac
  done <<EOF
$all
EOF
  printf '%s\n' "$merged" | LC_ALL=C sort -u
}

# Where the enumeration result is received. If enumeration itself fails (no scan root, an unresolvable shebang, etc),
# never give it the same face as "zero targets" -- that would let a state where nothing was checked pass as SKIP.
ENUM_LIST=""
enumerate() {
  local gate="$1"
  shift
  if ! ENUM_LIST="$("$@")"; then
    gate_fail "${gate}" "could not enumerate scan targets (scan root: ${ROOT})"
    return 1
  fi
  return 0
}

require_tool() {
  local gate="$1" bin="$2" hint="$3"
  if command -v "$bin" >/dev/null 2>&1; then
    return 0
  fi
  # The name inside a variable expansion is always closed with braces (`${...}`).
  gate_fail "${gate}" "${bin} not found (${hint}). Install it and re-run"
  return 1
}

# Whether something is an executable script is decided by its location (anything under lib/ is a shared library -- needs neither execute permission nor --selftest).
# Checking only files that carry execute permission would let a forgotten chmod +x pass unnoticed instead of failing the convention.
# Not just directly under lib/ but **any subdirectory under it** is treated as a shared library too. Looking only at the direct level
# would turn a library split by layer (lib/<layer>/) into what looks like an executable script, and it would fail the convention for
# lacking execute permission and --selftest (the judging shouldn't warp how finely the code is split).
# A directory not literally named `lib` (libs/, etc) stays in scope -- the judgment isn't widened past that.
is_library_path() {
  case "${1%/*}" in
    */lib | */lib/*) return 0 ;;
  esac
  return 1
}

# Checks the selftest convention's final line (`<script name>: selftest N pass / M fail`).
# Looking only at the exit code lets a no-op script that ignores its arguments and exits 0 pass unnoticed.
verify_selftest_summary() {
  local name="$1" out="$2" summary passed failed
  summary="$(printf '%s\n' "$out" | tail -1)"
  case "$summary" in
    "${name}: selftest "*" pass / "*" fail") ;;
    *)
      printf '    %s: the last line does not follow the selftest convention format: %s\n' "$name" "$summary"
      return 1
      ;;
  esac
  passed="${summary#*: selftest }"
  passed="${passed%% pass*}"
  failed="${summary#* pass / }"
  failed="${failed%% fail*}"
  case "$passed" in
    '' | *[!0-9]*)
      printf '    %s: pass count is not a number: %s\n' "$name" "$summary"
      return 1
      ;;
  esac
  case "$failed" in
    '' | *[!0-9]*)
      printf '    %s: fail count is not a number: %s\n' "$name" "$summary"
      return 1
      ;;
  esac
  if [ "$passed" -eq 0 ]; then
    printf '    %s: selftest checked zero cases: %s\n' "$name" "$summary"
    return 1
  fi
  if [ "$failed" -ne 0 ]; then
    printf '    %s: selftest has failures: %s\n' "$name" "$summary"
    return 1
  fi
  return 0
}

selftest_remove_control_dir() {
  local name="$1" control_dir="$2"
  if rm -rf "$control_dir" && [ ! -e "$control_dir" ]; then
    return 0
  fi
  printf '    %s: could not remove the selftest control temp directory (evidence: %s)\n' \
    "$name" "$control_dir"
  return 1
}

selftest_deadline_is_valid() {
  local value="$1" maximum="$2"
  case "$value" in
    '' | 0 | 0* | *[!0-9]*) return 1 ;;
  esac
  if [ "${#value}" -gt "${#maximum}" ]; then
    return 1
  fi
  if [ "${#value}" -lt "${#maximum}" ]; then
    return 0
  fi
  [ "$value" -le "$maximum" ]
}

# The one runner that runs a single selftest. Keeps the order: show start -> stream output -> pass through the exit code.
# The finite deadline lives on the supervisor's side (fork -> setpgid -> exec, sending TERM -> KILL to the
# process group once monotonic time elapses) -- this shell never holds a second deadline (a single owner for the cap).
# The 3rd argument (optional) is the **inner** bash: the interpreter selftest uses when it relaunches its own body.
# The runner only pins one outer layer, so without passing this, a `bash <script>` inside selftest pulls in
# the bash on PATH, and stays green while outer is 3.2 / inner is 5.x (on a machine with a newer bash at the front of PATH).
# The default is **the very bash currently running the outer layer** (the receiving side resolves it as `${REIN_SELFTEST_BASH:-${BASH:-bash}}`)
# -- not passing it keeps the current behavior, so nothing breaks while the receiving side hasn't switched over yet.
run_one_selftest() {
  local file="$1" runner="$2" inner_bash="${3:-}"
  local name control_dir output_file result_file result_tmp
  local wrapper_pid total shown=0 status out
  local command=()
  local inner_env=()
  # The surrounding REIN_* were already dropped with `-u`, so only what's set here reaches the inner layer (`env` processes options
  # before applying assignments, so an assignment with the same name as a `-u` wins even placed alongside it -- measured).
  [ -z "$inner_bash" ] || inner_env=("REIN_SELFTEST_BASH=$inner_bash")
  name="${file##*/}"
  if ! selftest_deadline_is_valid "$SELFTEST_DEADLINE_SEC" "$SELFTEST_MAX_DEADLINE_SEC"; then
    printf '    %s: selftest deadline is invalid (max %ss): %s\n' \
      "$name" "$SELFTEST_MAX_DEADLINE_SEC" "$SELFTEST_DEADLINE_SEC"
    return 2
  fi
  printf '  START selftest %s (deadline=%ss)\n' "$name" "$SELFTEST_DEADLINE_SEC"
  control_dir="$(mktemp -d "${TMPDIR:-/tmp}/rein-check-selftest.XXXXXX")" || return 1
  output_file="$control_dir/output"
  result_file="$control_dir/result"
  result_tmp="$control_dir/result.tmp"
  : >"$output_file"
  if [ -n "$runner" ]; then
    command=("$runner" "$file" --selftest)
  else
    command=("$file" --selftest)
  fi
  # The target's stdout/stderr are collected into the output file by the supervisor (this shell only tails and displays them).
  # The supervisor's own failures aren't mixed into the capture file; they go straight to the runner's stderr.
  (
    env ${SELFTEST_ENV_ARGS[@]+"${SELFTEST_ENV_ARGS[@]}"} \
      ${inner_env[@]+"${inner_env[@]}"} \
      "$PERL_BIN" "$SELFTEST_SUPERVISOR" "$SELFTEST_DEADLINE_SEC" "$output_file" \
      "${command[@]}" </dev/null
    status=$?
    printf '%s\n' "$status" >"$result_tmp" && mv "$result_tmp" "$result_file"
  ) &
  wrapper_pid=$!
  while [ ! -s "$result_file" ]; do
    total="$(wc -l <"$output_file")" || break
    total="${total//[[:space:]]/}"
    if [ -n "$total" ] && [ "$total" -gt "$shown" ]; then
      sed -n "$((shown + 1)),${total}p" "$output_file" || break
      shown="$total"
    fi
    sleep 0.01
  done
  if [ ! -s "$result_file" ]; then
    printf '    %s: could not follow the selftest output (evidence: %s)\n' \
      "$name" "$control_dir"
    return 1
  fi
  wait "$wrapper_pid" 2>/dev/null || :
  sed -n "$((shown + 1)),\$p" "$output_file" || {
    printf '    %s: could not display the selftest output (evidence: %s)\n' \
      "$name" "$control_dir"
    return 1
  }
  status="$(cat "$result_file")"
  out="$(cat "$output_file")"
  case "$status" in
    '' | *[!0-9]*)
      printf '    %s: the selftest exit code is invalid: %s\n' "$name" "$status"
      return 1
      ;;
  esac
  if ! selftest_remove_control_dir "$name" "$control_dir"; then
    return 1
  fi
  if [ "$status" -eq "$SELFTEST_DEADLINE_RC" ]; then
    printf '    %s: selftest deadline exceeded (%ss, exit=%s)\n' \
      "$name" "$SELFTEST_DEADLINE_SEC" "$status"
    return "$status"
  fi
  if [ "$status" -ne 0 ]; then
    printf '    %s: selftest exit=%s\n' "$name" "$status"
    return "$status"
  fi
  verify_selftest_summary "$name" "$out"
}

gate_shellcheck() {
  local gate="shellcheck"
  require_tool "$gate" "$SHELLCHECK_BIN" "e.g. brew install shellcheck" || return

  local file total=0 failed=0 out
  enumerate "$gate" collect_shell_files || return
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    total=$((total + 1))
    # -x follows source targets too (so an executable script that reads a shared library isn't shown as full of undefined references).
    if ! out="$("$SHELLCHECK_BIN" -x "$file" 2>&1)"; then
      failed=$((failed + 1))
      printf '%s\n' "$out"
    fi
  done <<EOF
$ENUM_LIST
EOF

  if [ "$total" -eq 0 ]; then
    gate_skip "${gate} (0 files)" "no shell scripts to check"
    return
  fi
  if [ "$failed" -eq 0 ]; then
    gate_pass "$gate ($total files)"
  else
    gate_fail "${gate}" "${failed}/${total} files have findings"
  fi
}

gate_json() {
  local gate="jq"
  require_tool "$gate" "$JQ_BIN" "e.g. on macOS, /usr/bin/jq" || return

  local file total=0 failed=0 out
  enumerate "$gate" collect_files_with_suffix '.json' || return
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    total=$((total + 1))
    if ! out="$("$JQ_BIN" empty "$file" 2>&1)"; then
      failed=$((failed + 1))
      printf '%s\n' "$out"
    fi
  done <<EOF
$ENUM_LIST
EOF

  if [ "$total" -eq 0 ]; then
    gate_skip "${gate} (0 files)" "no .json files to check"
    return
  fi
  if [ "$failed" -eq 0 ]; then
    gate_pass "$gate ($total files)"
  else
    gate_fail "${gate}" "${failed}/${total} files are invalid JSON"
  fi
}

# Looks at the contents of the contract files loaded as a plugin (the manifest, skill frontmatter).
# The jq gate only checks syntax, so dropping name or changing slug would sail through with every gate green.
# Doesn't depend on the claude CLI (in an environment that can't launch the CLI, the gate itself couldn't hold).
collect_skill_files() {
  [ -d "$ROOT/skills" ] || return 0
  find "$ROOT/skills" -mindepth 2 -maxdepth 2 -type f -name 'SKILL.md' -print | LC_ALL=C sort
}

# Pulls out the frontmatter between the first --- and the next ---. Returns non-zero if it is never closed.
extract_frontmatter() {
  awk '
    NR == 1 { if ($0 != "---") exit 1; next }
    $0 == "---" { closed = 1; exit 0 }
    { print }
    END { if (!closed) exit 1 }
  ' "$1"
}

check_plugin_manifest() {
  local manifest="$1" actual
  if ! "$JQ_BIN" -e 'has("name")' "$manifest" >/dev/null 2>&1; then
    printf '    %s has no name (a required field for a plugin manifest)\n' "$manifest"
    return 1
  fi
  if ! "$JQ_BIN" -e '.name == "rein"' "$manifest" >/dev/null 2>&1; then
    actual="$("$JQ_BIN" -r '.name' "$manifest" 2>&1)"
    printf '    %s has a name that is not rein: %s\n' "$manifest" "$actual"
    return 1
  fi
  return 0
}

# Events the plugin's hooks must register. Missing even one means that layer silently stops working
# (no advisory shown, can't press for a handover on stop, no liveness check) while every other gate stays green.
# The mapping to verbs (event name <-> the verb passed to the launcher) is pinned in both directions by the hook runner's selftest
# -- what this checks is only the coverage of the registration table: which events it covers.
required_hook_events() {
  printf '%s\n' PostToolBatch Stop SessionStart UserPromptSubmit
}

# The plugin's hooks registration table (the official location: hooks/hooks.json directly under the plugin root).
# Checks the shape (the 3-tier event -> matcher -> handler structure), and that **the registered command calls the
# rein on PATH**. The jq gate lets the command's actual target through unchecked, so this is the only gatekeeper.
check_plugin_hooks() {
  local file="$1" bad event matcher failed=0
  if ! "$JQ_BIN" -e . "$file" >/dev/null 2>&1; then
    printf '    %s cannot be parsed as JSON (the plugin hooks registration table)\n' "$file"
    return 1
  fi
  if ! "$JQ_BIN" -e '(.hooks | type == "object") and ((.hooks | length) > 0)' \
    "$file" >/dev/null 2>&1; then
    printf '    %s has no hooks registered (the 3-tier event -> matcher -> handler structure)\n' "$file"
    return 1
  fi
  bad="$("$JQ_BIN" -r '[ .hooks[][].hooks[]
    | select((.type != "command") or (.timeout == null)) ] | length' "$file" 2>/dev/null)"
  if [ "$bad" != "0" ]; then
    printf '    %s has entries missing type=command or timeout (%s of them)\n' "$file" "${bad:-cannot determine}"
    return 1
  fi
  # hooks call a **minimal launcher** inside the plugin (the real implementation is the runner behind a symlink).
  # Putting the implementation here would run the plugin's cached copy and lag behind updates, while calling the PATH
  # command directly would silently misfire depending on the state of PATH.
  # Whether it's quoted is checked next, so this strips the leading `"` and looks only at the call target
  # (so a wrong call target and a right target missing quotes fail for distinct reasons).
  # shellcheck disable=SC2016  # the literal text being searched for (must not be expanded)
  bad="$("$JQ_BIN" -r --arg prefix '${CLAUDE_PLUGIN_ROOT}/hooks/' '[ .hooks[][].hooks[].command
    | select(((ltrimstr("\"") | startswith($prefix)) | not)) ] | length' "$file" 2>/dev/null)"
  if [ "$bad" != "0" ]; then
    # shellcheck disable=SC2016
    printf '    %s has command entries that do not call the ${CLAUDE_PLUGIN_ROOT}/hooks/ launcher (%s of them)\n' \
      "$file" "${bad:-cannot determine}"
    return 1
  fi
  # The registered command gets handed to a shell on the consumer's side and **word-split**, so the leading word (the launcher path) must be
  # wrapped in double quotes. Without it, the command splits into separate words wherever the plugin's install location contains a space,
  # and not a single hook fires while every step of the install walkthrough stays green (measured).
  # shellcheck disable=SC2016  # the literal text being searched for (must not be expanded)
  bad="$("$JQ_BIN" -r --arg re '^"\$\{CLAUDE_PLUGIN_ROOT\}/hooks/[^"]+" ' '[ .hooks[][].hooks[].command
    | select((test($re)) | not) ] | length' "$file" 2>/dev/null)"
  if [ "$bad" != "0" ]; then
    printf '    %s has command entries that do not quote the launcher path (%s of them -- word-split by a location containing a space, no hook fires)\n' \
      "$file" "${bad:-cannot determine}"
    return 1
  fi
  # Whether the call target **actually exists and is executable** (a registration whose literal text matches but whose target doesn't exist means hooks
  # never fire at all while every gate stays green).
  while IFS= read -r matcher; do
    [ -n "$matcher" ] || continue
    matcher="${matcher#\"\$\{CLAUDE_PLUGIN_ROOT\}/}"
    matcher="${matcher%%\"*}"
    if [ ! -x "$ROOT/$matcher" ]; then
      printf '    %s registers a launcher that cannot be executed: %s\n' "$file" "$ROOT/$matcher"
      failed=1
    fi
  done <<EOF
$("$JQ_BIN" -r '[ .hooks[][].hooks[].command // empty ] | .[]' "$file" 2>/dev/null)
EOF
  # Event coverage. Missing one from the registration means "just that layer silently stops working", so
  # it stays valid as JSON and valid as the 3-tier structure while every gate stays green.
  while IFS= read -r event; do
    [ -n "$event" ] || continue
    # shellcheck disable=SC2016  # $e is a jq variable (invisible to shellcheck since jq's own value is referenced via a variable)
    if ! "$JQ_BIN" -e --arg e "$event" '.hooks | has($e)' "$file" >/dev/null 2>&1; then
      printf '    %s has no registration for %s (that layer silently stops working)\n' "$file" "$event"
      failed=1
    fi
  done <<EOF
$(required_hook_events)
EOF
  # The advisory channel is PostToolBatch (fires exactly once per batch of tools that ran in parallel).
  # The measured shape has **no matcher** (this registration applies to the whole batch), so adding a matcher
  # is rejected -- adding one has no guarantee of working, and if it doesn't, the advisory goes silent entirely.
  if "$JQ_BIN" -e '.hooks | has("PostToolBatch")' "$file" >/dev/null 2>&1; then
    matcher="$("$JQ_BIN" -r '[ .hooks.PostToolBatch[] | select(has("matcher")) ] | length' "$file" 2>/dev/null)"
    if [ "$matcher" != "0" ]; then
      printf '    %s has a matcher on PostToolBatch (the measured form has no matcher)\n' "$file"
      failed=1
    fi
  fi
  return "$failed"
}

# The marketplace registration table (required to register a local directory with `claude plugin marketplace add` --
# without it, step (2) of `rein init` fails with "File not found"). Checks the required fields and
# **the form this repo itself is distributed in** (the plugin manifest's name is present in plugins, with a relative-path source).
check_plugin_marketplace() {
  local file="$1" manifest="$2" name
  if ! "$JQ_BIN" -e '(has("name")) and (.owner.name // "") != "" and ((.plugins | type) == "array")' \
    "$file" >/dev/null 2>&1; then
    printf '    %s is missing name / owner.name / plugins (required fields for a marketplace entry)\n' "$file"
    return 1
  fi
  if ! "$JQ_BIN" -e '[ .plugins[] | select(((.name // "") == "") or ((.source | type) != "string")
      or ((.source | startswith("./")) | not)) ] | length == 0' "$file" >/dev/null 2>&1; then
    printf '    %s has a plugins entry missing name or a relative-path source\n' "$file"
    return 1
  fi
  name="$("$JQ_BIN" -r '.name // empty' "$manifest" 2>/dev/null)"
  # shellcheck disable=SC2016  # $n is a jq variable
  if [ -n "$name" ] &&
    ! "$JQ_BIN" -e --arg n "$name" 'any(.plugins[]; (.name // "") == $n)' "$file" >/dev/null 2>&1; then
    printf '    %s has no plugins entry for %s (the plugin manifest name)\n' "$file" "$name"
    return 1
  fi
  return 0
}

check_skill_frontmatter() {
  local file="$1" fm key failed=0
  if ! fm="$(extract_frontmatter "$file")"; then
    printf '    %s has no frontmatter (open with --- and close with ---)\n' "$file"
    return 1
  fi
  for key in name description; do
    if ! printf '%s\n' "$fm" | grep -q "^${key}:[[:space:]]*[^[:space:]]"; then
      printf '    %s has frontmatter missing %s\n' "$file" "$key"
      failed=1
    fi
  done
  # The run example a skill shows is **the rein on PATH** (never runs the plugin's cached copy).
  # ${CLAUDE_PLUGIN_ROOT}/bin/rein only resolves in a session where the plugin is active, and it would conflict with the
  # hooks' block message (the rein on PATH), leaving two different instructions for the same operation.
  # A reference to bundled docs (${CLAUDE_PLUGIN_ROOT}/docs/...) is out of scope since it isn't a run example.
  # The directive right below covers the whole if (neither the searched-for text nor the shown text gets expanded).
  # shellcheck disable=SC2016  # the literal text being searched for (must not be expanded)
  if grep -q -e '${CLAUDE_PLUGIN_ROOT}/bin/rein' "$file"; then
    printf '    %s has a run example calling ${CLAUDE_PLUGIN_ROOT}/bin/rein (align it with the rein on PATH)\n' "$file"
    failed=1
  fi
  return "$failed"
}

gate_plugin() {
  local gate="plugin"
  local manifest="$ROOT/.claude-plugin/plugin.json"
  local marketplace="$ROOT/.claude-plugin/marketplace.json"
  local hooks_json="$ROOT/hooks/hooks.json"
  local file total=0 failed=0

  if [ -f "$manifest" ] || [ -f "$hooks_json" ]; then
    require_tool "$gate" "$JQ_BIN" "e.g. on macOS, /usr/bin/jq" || return
  fi
  if [ -f "$manifest" ]; then
    total=$((total + 1))
    check_plugin_manifest "$manifest" || failed=$((failed + 1))
  fi

  # If this is meant to load as a plugin, the hooks registration table is required (without it, not a single hook
  # fires while every gate stays green).
  if [ -f "$manifest" ] || [ -f "$hooks_json" ]; then
    total=$((total + 1))
    if [ ! -f "$hooks_json" ]; then
      printf '    %s is missing (the plugin hooks registration table)\n' "$hooks_json"
      failed=$((failed + 1))
    else
      check_plugin_hooks "$hooks_json" || failed=$((failed + 1))
    fi
  fi

  # The marketplace registration table is required too (the entry point for a user-scope install from a local directory).
  if [ -f "$manifest" ] || [ -f "$hooks_json" ]; then
    total=$((total + 1))
    if [ ! -f "$marketplace" ]; then
      printf '    %s is missing (the marketplace registration table -- the entry point for a local install)\n' "$marketplace"
      failed=$((failed + 1))
    else
      check_plugin_marketplace "$marketplace" "$manifest" || failed=$((failed + 1))
    fi
  fi

  enumerate "$gate" collect_skill_files || return
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    total=$((total + 1))
    check_skill_frontmatter "$file" || failed=$((failed + 1))
  done <<EOF
$ENUM_LIST
EOF

  if [ "$total" -eq 0 ]; then
    gate_skip "${gate} (0 files)" "no plugin manifest and no skill"
    return
  fi
  if [ "$failed" -eq 0 ]; then
    gate_pass "$gate ($total files)"
  else
    gate_fail "${gate}" "${failed}/${total} files violate the plugin conventions"
  fi
}

# Strips inline code spans (`...`) from a line. Text inside a code span isn't rendered as a link,
# so a sentence that describes link syntax itself (a gate's own description, a how-to-write example)
# is excluded from scanning so it doesn't get flagged. If a line ends with an unclosed backtick, the tail is dropped too
# (a span left open is still treated as a code span when rendered).
# The result is returned via the global `STRIPPED_LINE` (forking with command substitution for every single line would mean
# hundreds of forks for one document).
STRIPPED_LINE=""
strip_code_spans() {
  local line="$1" out="" seg inside=0
  while [ -n "$line" ]; do
    case "$line" in
      *'`'*)
        seg="${line%%\`*}"
        line="${line#*\`}"
        ;;
      *)
        seg="$line"
        line=""
        ;;
    esac
    [ "$inside" -eq 0 ] && out="$out$seg"
    inside=$((1 - inside))
  done
  STRIPPED_LINE="$out"
}

# Emits one file's worth of markdown inline links as `line number<US>text<US>target`.
# Inside a code fence is out of scope -- text that doesn't render as a link (an example showing markdown syntax) would
# fail a correct document if it were checked as a link.
# Uses US (\037) as the delimiter so that even a link with empty text (`[](path)`) doesn't shift the columns
# (a space or TAB delimiter would collapse the empty field and swap the text and the target).
scan_md_links() {
  local file="$1" line lineno=0 fence=0 rest text target after
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    case "$line" in
      '```'*)
        fence=$((1 - fence))
        continue
        ;;
    esac
    [ "$fence" -eq 0 ] || continue
    strip_code_spans "$line"
    rest="$STRIPPED_LINE"
    while :; do
      case "$rest" in
        *'['*) ;;
        *) break ;;
      esac
      rest="${rest#*[}"
      case "$rest" in
        *']'*) ;;
        *) break ;;
      esac
      text="${rest%%]*}"
      after="${rest#"$text"}"
      after="${after#"]"}"
      case "$after" in
        '('*)
          rest="${after#"("}"
          case "$rest" in
            *')'*) ;;
            *) break ;;
          esac
          target="${rest%%)*}"
          rest="${rest#*)}"
          printf '%s\037%s\037%s\n' "$lineno" "$text" "$target"
          ;;
        *)
          # A `]` not followed by `(` (like [0-9] inside a code span) isn't a link.
          rest="$after"
          ;;
      esac
    done
  done <"$file"
}

# Guards the links between docs mechanically. Checks both that a relative link's target actually exists (stops a rename from killing a link) and
# that the link text isn't a path string (the convention against exposing directory structure in docs).
gate_docs_links() {
  local gate="docs-links"
  local files file dir total=0 violations=0 lineno text target resolved

  enumerate "$gate" collect_files_with_suffix '.md' || return
  files="$ENUM_LIST"
  total="$(printf '%s\n' "$files" | grep -c '[^[:space:]]')"
  if [ "$total" -eq 0 ]; then
    gate_skip "${gate} (0 files)" "no .md files to check"
    return
  fi

  while IFS= read -r file; do
    [ -n "$file" ] || continue
    dir="${file%/*}"
    while IFS=$'\037' read -r lineno text target; do
      [ -n "$lineno" ] || continue
      case "$target" in
        # An external URL and an anchor within the same document have no target to resolve.
        http*) continue ;;
        '#'*) continue ;;
      esac
      target="${target%%#*}"
      if [ -n "$target" ]; then
        case "$target" in
          /*) resolved="$target" ;;
          *) resolved="$dir/$target" ;;
        esac
        if [ ! -e "$resolved" ]; then
          violations=$((violations + 1))
          printf '    %s:%s: link target does not exist: %s\n' "$file" "$lineno" "$target"
        fi
      fi
      case "$text" in
        */* | *.md)
          violations=$((violations + 1))
          printf '    %s:%s: link text is a path string (write it as a doc name or section name): %s\n' "$file" "$lineno" "$text"
          ;;
      esac
    done <<EOF
$(scan_md_links "$file")
EOF
  done <<EOF
$files
EOF

  if [ "$violations" -eq 0 ]; then
    gate_pass "$gate ($total files)"
  else
    gate_fail "${gate}" "${violations} violations"
  fi
}

# Convention: an executable script has --selftest. One without it, or without execute permission, fails as a convention violation
# (never silently skipped).
gate_selftest() {
  local gate="selftest"
  local file total=0 failed=0

  enumerate "$gate" collect_shell_files || return
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    is_library_path "$file" && continue
    total=$((total + 1))
    if [ ! -x "$file" ]; then
      failed=$((failed + 1))
      printf '    %s has no execute permission (a shell script outside lib/ is an executable script with --selftest)\n' "$file"
      continue
    fi
    if ! grep -q -e '--selftest' "$file"; then
      failed=$((failed + 1))
      printf '    %s has no --selftest (the convention for an executable script)\n' "$file"
      continue
    fi
    run_one_selftest "$file" "" || failed=$((failed + 1))
  done <<EOF
$ENUM_LIST
EOF

  if [ "$total" -eq 0 ]; then
    gate_skip "${gate} (0 scripts)" "no executable scripts to check"
    return
  fi
  if [ "$failed" -eq 0 ]; then
    gate_pass "$gate ($total scripts)"
  else
    gate_fail "${gate}" "${failed}/${total} scripts violate the convention or failed"
  fi
}

# Pins the bash-3.2-compatibility claim with a gate. selftest runs on the bash found on PATH, so
# an environment with a newer bash at the front of PATH could go green having never been checked on 3.2 even once.
# If the bash on PATH is the same binary as the real 3.2, the selftest gate has already run on it -- don't run it twice
# (never a silent skip -- state it explicitly with a SKIP line).
# Pins **both the outer and the inner** layer to the real 3.2. Pinning only the runner (the one outer layer) leaves the
# `bash <script>` that relaunches the body inside selftest pulling in the bash on PATH, so it can PASS while staying
# outer-3.2/inner-5.x. The inner layer is received via `REIN_SELFTEST_BASH` (default: the very bash running the outer layer).
# Both result lines name the outer and the inner layer, so whether it ran on 3.2 can be read off the display alone.
gate_bash32() {
  local gate="bash32"
  local file total=0 failed=0 path_bash

  if [ ! -x "$BASH32_BIN" ]; then
    gate_fail "${gate}" "cannot find the real 3.2 bash: ${BASH32_BIN}"
    return
  fi
  path_bash="$(command -v bash 2>/dev/null)"
  if [ -n "$path_bash" ] &&
    [ "$(stat -f '%d:%i' "$path_bash" 2>/dev/null)" = "$(stat -f '%d:%i' "$BASH32_BIN" 2>/dev/null)" ]; then
    # Even a skipped run shows the inner layer's identity. The selftest gate launches the outer layer via the shebang (the bash on PATH), and
    # the inner layer's default is **that very bash running the outer layer** (the receiving side falls back to `$BASH`), so
    # the inner layer is the same binary regardless of what the outer layer is. So this branch's condition (the bash on PATH is identical to the real 3.2)
    # is, by itself, the grounds for "both outer and inner ran on the real 3.2".
    gate_skip "${gate}" \
      "the bash on PATH (${path_bash}) is the same binary as ${BASH32_BIN} -- the selftest gate has already run both outer and inner (REIN_SELFTEST_BASH defaults to the very bash running the outer layer) on the real 3.2"
    return
  fi

  enumerate "$gate" collect_shell_files || return
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    is_library_path "$file" && continue
    [ -x "$file" ] || continue
    grep -q -e '--selftest' "$file" || continue
    total=$((total + 1))
    run_one_selftest "$file" "$BASH32_BIN" "$BASH32_BIN" || failed=$((failed + 1))
  done <<EOF
$ENUM_LIST
EOF

  if [ "$total" -eq 0 ]; then
    gate_skip "${gate} (0 scripts)" "no executable scripts to check"
    return
  fi
  if [ "$failed" -eq 0 ]; then
    # The name inside a variable expansion is always closed with `${...}`.
    gate_pass "$gate ($total scripts on ${BASH32_BIN}, inner launch too via REIN_SELFTEST_BASH=${BASH32_BIN})"
  else
    gate_fail "${gate}" "${failed}/${total} scripts failed on ${BASH32_BIN} (inner launch too via REIN_SELFTEST_BASH=${BASH32_BIN})"
  fi
}

# Scan that checks whether a path embedded into a finished command shown to the user goes through rein_shell_quote.
# Judges the literal source text (not a value only known at runtime -- looks at the form the author chose).
#
# Two forms are checked. For a word **in a path-taking position** (right after an option like `--cwd`, or an argument to
# `rm` / `rmdir` / `ln -s`, etc):
#   (a) if it's `%s`, whether that printf's **corresponding argument** goes through `rein_shell_quote`
#   (b) if it's `${var}` / `$var`, there's no way to quote it there -- a violation
# is judged. A word starting with a double or single quote (a real command's argument, an already-quoted literal inside a needle) and
# `$( )` are on the accepting side.
#
# Four things are excluded, all on the **matching, not output** side:
#   1. A `case` branch pattern line (starts with `*`) -- a line matching **unquoted literal text** like a
#      `ps` argv. Adding quotes here would break the match.
#   2. An `st_expect_not_contains` line -- a needle that measures "the unquoted text does not appear".
#      Carrying the violation's literal text is the point of that check.
#   3. `claude rm`'s argument -- a job ID, not a path.
#   4. A line with `shell-quote-exempt: <reason>` on the same logical line -- an exception declared with a reason.
#      Used at a position where quoting itself is meaningless (e.g. a fake-CLI fixture that echoes a received value verbatim).
#      **Write the exception on the line** (a separate table would leave no way to tell which of the table and the code has gone stale).
#
# Output is one line per finding: `<start line number><TAB><reason><TAB><excerpt>`.
shell_quote_scan_program() {
  cat <<'AWK'
# One word starting at pos (whitespace inside a quote or inside $( ) stays part of the word).
function word_at(s, pos,   n, c, out, sq, dq, depth) {
  n = length(s); out = ""; sq = 0; dq = 0; depth = 0
  while (pos <= n) {
    c = substr(s, pos, 1)
    if (sq) { out = out c; if (c == "'") sq = 0; pos++; continue }
    if (c == "\\") { out = out c substr(s, pos + 1, 1); pos += 2; continue }
    if (dq) {
      if (c == "$" && substr(s, pos + 1, 1) == "(") { depth++; out = out "$("; pos += 2; continue }
      if (depth > 0 && c == ")") { depth--; out = out c; pos++; continue }
      if (c == "\"" && depth == 0) { dq = 0; out = out c; pos++; continue }
      out = out c; pos++; continue
    }
    if (c == "'") { sq = 1; out = out c; pos++; continue }
    if (c == "\"") { dq = 1; out = out c; pos++; continue }
    if (c == "$" && substr(s, pos + 1, 1) == "(") { depth++; out = out "$("; pos += 2; continue }
    if (depth > 0 && c == ")") { depth--; out = out c; pos++; continue }
    if (depth == 0 && c ~ /[ \t]/) break
    out = out c; pos++
  }
  return out
}

# Splits a logical line into words (W_TEXT / W_START / W_END and the word count W_N).
function split_words(s,   pos, n, w) {
  W_N = 0; pos = 1; n = length(s)
  while (pos <= n) {
    while (pos <= n && substr(s, pos, 1) ~ /[ \t]/) pos++
    if (pos > n) break
    w = word_at(s, pos)
    if (w == "") { pos++; continue }
    W_N++
    W_TEXT[W_N] = w; W_START[W_N] = pos; W_END[W_N] = pos + length(w) - 1
    pos += length(w)
  }
}

function var_name(tok,   t) {
  t = tok
  sub(/^\$/, "", t); sub(/^\{/, "", t)
  if (match(t, /^[A-Za-z_][A-Za-z0-9_]*/)) return substr(t, 1, RLENGTH)
  return ""
}

# The number of conversion specs from the start of the format string up to (not including) upto (`%%` is a literal, takes no argument).
function conv_count(fmt, upto,   i, c, n) {
  n = 0; i = 1
  while (i < upto) {
    c = substr(fmt, i, 1)
    if (c == "%") {
      if (substr(fmt, i + 1, 1) == "%") { i += 2; continue }
      n++; i += 2; continue
    }
    i++
  }
  return n
}

# Whether that argument carries a quoted path. Passes both the form where rein_shell_quote appears literally, and, within the same file,
# a variable built from rein_shell_quote passed along (reusing `quoted="$(rein_shell_quote ...)"`).
function arg_is_quoted(arg,   name) {
  if (index(arg, "rein_shell_quote") > 0) return 1
  name = arg
  gsub(/^"|"$/, "", name)
  if (substr(name, 1, 1) == "$") {
    name = var_name(name)
    if (name != "" && ((CURSCOPE SUBSEP name) in QVAR)) return 1
  }
  return 0
}

function excerpt(line, pos,   from) {
  from = pos - 24
  if (from < 1) from = 1
  return "..." substr(line, from, 56) "..."
}

function report(reason, text) {
  printf "%d\t%s\t%s\n", LSTART, reason, text
}

# Resolves the value a conversion spec (%s) fills in from that printf's corresponding argument, and judges it.
function check_conversion(line, pos,   i, wi, fi, ai, idx, args_n, arg, fmt, rel) {
  split_words(line)
  wi = 0
  for (i = 1; i <= W_N; i++) {
    if (W_START[i] <= pos && pos <= W_END[i]) { wi = i; break }
  }
  fi = 0
  if (wi >= 2 && W_TEXT[wi - 1] == "printf") fi = wi
  else if (wi >= 4 && W_TEXT[wi - 3] == "printf" && W_TEXT[wi - 2] == "-v") fi = wi
  if (fi == 0) {
    report("cannot identify the printf that fills this conversion spec (a form a machine cannot check for quoting)", excerpt(line, pos))
    return
  }
  fmt = W_TEXT[fi]
  rel = pos - W_START[fi] + 1
  idx = conv_count(fmt, rel)
  args_n = 0
  for (i = fi + 1; i <= W_N; i++) {
    if (W_TEXT[i] ~ /^[<>|&;]/ || W_TEXT[i] ~ /^2>/) break
    args_n++
    ARGW[args_n] = W_TEXT[i]
  }
  ai = idx + 1
  if (ai > args_n) {
    report("no argument corresponds to this conversion spec (a form a machine cannot check for quoting)", excerpt(line, pos))
    return
  }
  arg = ARGW[ai]
  if (!arg_is_quoted(arg)) {
    report("embeds a path into a finished command without quoting it (route it through rein_shell_quote)", excerpt(line, pos) " arg=" arg)
  }
}

# Judges one word that lands in a path-taking position.
function classify(line, opos,   operand, name) {
  operand = substr(line, opos)
  sub(/[ \t].*$/, "", operand)
  if (operand == "") return
  if (operand ~ /^%%/) return
  if (operand ~ /^%/) { check_conversion(line, opos); return }
  if (operand ~ /^["']/) return
  if (operand ~ /^\$\(/) return
  if (operand ~ /^[<>&|;]/) return
  if (substr(operand, 1, 1) != "$") return
  name = var_name(operand)
  if (name != "" && ((CURSCOPE SUBSEP name) in QVAR)) return
  report("embeds a path into a finished command without quoting it (route it through rein_shell_quote)", excerpt(line, opos))
}

# Returns the preceding word (to exclude a form appearing as another command's verb, like `claude rm`).
function prev_word(line, p,   i, out) {
  i = p - 1
  while (i >= 1 && substr(line, i, 1) ~ /[ \t]/) i--
  out = ""
  while (i >= 1 && substr(line, i, 1) !~ /[ \t]/) { out = substr(line, i, 1) out; i-- }
  # A verb embedded inside a string is picked up along with its opening quote, so the leading quote is stripped before comparing.
  sub(/^["']+/, "", out)
  return out
}

# For each occurrence of tok, judges the word in the path-taking position. If skip_opts=1, option words are skipped over.
function scan_token(line, tok, skip_opts, deny_prev,   p, start, before, after, opos, n, guard) {
  start = 1; n = length(line)
  while ((p = index(substr(line, start), tok)) > 0) {
    p = start + p - 1
    before = (p == 1) ? "" : substr(line, p - 1, 1)
    after = substr(line, p + length(tok), 1)
    start = p + length(tok)
    if (before ~ /[A-Za-z0-9_-]/) continue
    if (after !~ /[ \t]/) continue
    if (deny_prev != "" && prev_word(line, p) == deny_prev) continue
    opos = p + length(tok)
    guard = 0
    while (guard < 6) {
      while (opos <= n && substr(line, opos, 1) ~ /[ \t]/) opos++
      if (opos > n) break
      if (skip_opts && substr(line, opos, 1) == "-") {
        while (opos <= n && substr(line, opos, 1) !~ /[ \t]/) opos++
        guard++
        continue
      }
      break
    }
    if (opos > n) continue
    classify(line, opos)
  }
}

function process(line) {
  if (line ~ /^[ \t]*\*/) return
  if (index(line, "st_expect_not_contains") > 0) return
  if (index(line, "shell-quote-exempt:") > 0) return
  scan_token(line, "--cwd", 0, "")
  scan_token(line, "--root", 0, "")
  scan_token(line, "--runtime-dir", 0, "")
  scan_token(line, "-D", 0, "")
  scan_token(line, "--config", 0, "")
  scan_token(line, "--handoff", 0, "")
  scan_token(line, "-H", 0, "")
  scan_token(line, "--settings", 0, "")
  scan_token(line, "rm", 1, "claude")
  scan_token(line, "rmdir", 1, "")
  scan_token(line, "cat", 1, "")
  scan_token(line, "mkdir", 1, "")
  scan_token(line, "cd", 1, "")
  scan_token(line, "ln -s", 0, "")
  scan_token(line, "git -C", 0, "")
  scan_token(line, "marketplace add", 0, "")
}

{
  raw = $0
  # An already-quoted variable's scope is closed **inside its function**. Allowlisting the name across the whole file would let
  # a single production spot writing `quoted="$(rein_shell_quote ...)"` pass an unquoted variable of the same name in a
  # different function elsewhere in the file too (including test code) -- fail-open.
  # A function's start and end are read by **column-0 literal text** -- this repo's convention (functions live only at the
  # top level, and the closing brace sits at column 0). Assumes no nested function definitions; if one existed, scope would reset to 0 at the inner end,
  # so the rest of the outer function would be treated as top-level, **narrowing the accepting side** (never fail-open).
  if (raw ~ /^[A-Za-z_][A-Za-z0-9_]*[ \t]*\(\)[ \t]*\{[ \t]*$/) { scope_id++; scope = scope_id }
  else if (raw ~ /^\}/) { scope = 0 }
  if (pending) { logical = logical " " raw } else { logical = raw; lstart = NR; lscope = scope }
  if (logical ~ /\\$/) { sub(/\\$/, "", logical); pending = 1; next }
  pending = 0
  LN++; LINES[LN] = logical; LNUM[LN] = lstart; LSCOPE[LN] = lscope
}

END {
  if (pending) { LN++; LINES[LN] = logical; LNUM[LN] = lstart; LSCOPE[LN] = lscope }
  for (i = 1; i <= LN; i++) {
    l = LINES[i]
    if (index(l, "rein_shell_quote") == 0) continue
    if (match(l, /[A-Za-z_][A-Za-z0-9_]*="\$\(rein_shell_quote/)) {
      s = substr(l, RSTART, RLENGTH); sub(/=.*$/, "", s); QVAR[LSCOPE[i] SUBSEP s] = 1
    }
    if (match(l, /printf[ \t]+-v[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) {
      s = substr(l, RSTART, RLENGTH); sub(/^printf[ \t]+-v[ \t]+/, "", s); QVAR[LSCOPE[i] SUBSEP s] = 1
    }
  }
  for (i = 1; i <= LN; i++) { LSTART = LNUM[i]; CURSCOPE = LSCOPE[i]; process(LINES[i]) }
}
AWK
}


# Catches missing quotes on a path embedded into a finished command shown to the user. Without quoting, a location containing a space,
# a `;`, or `$( )` splits the pasted-and-typed line into separate words, or gets evaluated as command substitution (this happens
# to the very person who typed it exactly as instructed). Even 3 people counting independently by eye missed cases, so a machine counts.
gate_shell_quote() {
  local gate="shell-quote"
  local files file total=0 violations=0 out prog lineno reason detail rc

  enumerate "$gate" collect_shell_files || return
  files="$ENUM_LIST"
  total="$(printf '%s\n' "$files" | grep -c '[^[:space:]]')"
  if [ "$total" -eq 0 ]; then
    gate_skip "${gate} (0 files)" "no shell scripts to check"
    return
  fi

  prog="$(shell_quote_scan_program)"
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    # Scans a line one byte at a time (never looks at character boundaries, so the result doesn't move with the locale).
    # **Never give the scan's own failure the same face as "zero violations"** -- if awk itself crashes the output goes empty, so
    # not checking the exit code would let even a run where every file crashed come back PASS (the check spinning on nothing
    # hides behind green -- the worst way this mechanism can break).
    out="$(LC_ALL=C awk "$prog" "$file")"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      gate_fail "${gate}" "scan failed (awk rc=${rc}): ${file}"
      return
    fi
    [ -n "$out" ] || continue
    while IFS="$(printf '\t')" read -r lineno reason detail; do
      [ -n "$lineno" ] || continue
      violations=$((violations + 1))
      printf '    %s:%s: %s: %s\n' "$file" "$lineno" "$reason" "$detail"
    done <<EOF
$out
EOF
  done <<EOF
$files
EOF

  if [ "$violations" -eq 0 ]; then
    gate_pass "$gate ($total files)"
  else
    gate_fail "${gate}" "${violations} violations"
  fi
}

# rein verbs that require the lineage to be named explicitly (`--root` / `--runtime-dir` / `--config` / `--cwd`). Shown bare,
# the lineage at the location where it's typed becomes the target -- a different lineage runs on the very person who typed it as instructed.
# **`config` is on this table too** -- what `config` touches is the user config and the decision log next to it, and
# both move with `--root` / `--config`. Handing someone a line with no lineage named lets a permission get recorded in a different
# log once the lineage moves, while the place it moved from stays rejected and keeps issuing the same instructions (measured and reproduced).
lineage_cmd_verbs() {
  printf '%s\n' init up down request snooze status doctor prune config
}

# Whether a rein command shown to the user goes through the shared function that fills the lineage's naming with its
# effective value (`rein_lineage_cmd`; for `config`'s verbs, `rein_config_lineage_cmd`).
# Counts literal text that skips it -- **a bare `rein <verb>`**. Not just where the verb follows directly, but also
# **a form where an option sits between `rein` and the verb** (`rein --cwd <value> config allow`)
# -- missing that form would leave any instructions with even one common option written in falling entirely outside scope.
# What can sit between is **a word shaped like an option** (`-x` / `--xxx`) and one word for its value (including one level of `$( )`),
# and nothing else -- so a form like `rein_lineage_cmd rein "$RUNTIME_DIR" ... up`, i.e.
# "the argument sequence passed to the shared function", is never counted as a violation.
#
# Four things are excluded, all on the side that is **not an instruction**:
#   1. A line starting with `#` -- a comment explaining the mechanism (`rein up` appears there as the mechanism's own name).
#   2. A line starting with `*` -- a `case` branch pattern (matching, not output).
#   3. An `st_expect_not_contains` line -- a needle that measures "that text does not appear".
#   4. A line with `lineage-cmd-exempt: <reason>` on it -- an exception declared with a reason.
#      **Write the exception on the line** (a separate table would leave no way to tell which of the table and the code has gone stale).
#      An argv sequence a check expects (the lines following `st_expect_argv`) is declared here too -- **since the helper's
#      name only appears on the call's first line**, excluding by name (like exclusion 3) wouldn't drop a single one of these lines.
gate_lineage_cmd() {
  local gate="lineage-cmd"
  local files file total=0 violations=0 out verbs opts rc

  enumerate "$gate" collect_shell_files || return
  files="$ENUM_LIST"
  total="$(printf '%s\n' "$files" | grep -c '[^[:space:]]')"
  if [ "$total" -eq 0 ]; then
    gate_skip "${gate} (0 files)" "no shell scripts to check"
    return
  fi

  verbs="$(lineage_cmd_verbs | tr '\n' '|')"
  verbs="${verbs%|}"
  # What can sit between `rein` and the verb: a word shaped like an option, and one word for its value (up to one level of `$( )`).
  opts='([[:space:]]+-{1,2}[A-Za-z][A-Za-z0-9-]*([[:space:]]+(\$\([^()]*\)|[^[:space:]]+))?)*'
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    # Never give the scan's own failure (unreadable, an unparseable regex) the same face as "zero violations".
    out="$(LC_ALL=C grep -nE "(^|[^A-Za-z0-9_/-])rein${opts}[[:space:]]+(${verbs})([^A-Za-z0-9_-]|\$)" "$file")"
    rc=$?
    if [ "$rc" -gt 1 ]; then
      gate_fail "${gate}" "scan failed (grep rc=${rc}): ${file}"
      return
    fi
    [ -n "$out" ] || continue
    out="$(printf '%s\n' "$out" |
      grep -vE '^[0-9]+:[[:space:]]*#' |
      grep -vE '^[0-9]+:[[:space:]]*\*' |
      grep -v 'st_expect_not_contains' |
      grep -v 'lineage-cmd-exempt:')"
    [ -n "$out" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      violations=$((violations + 1))
      printf '    %s:%s\n' "$file" "$line"
    done <<EOF
$out
EOF
  done <<EOF
$files
EOF

  if [ "$violations" -eq 0 ]; then
    gate_pass "$gate ($total files)"
  else
    gate_fail "${gate}" "${violations} bare rein commands (route it through rein_lineage_cmd, or write lineage-cmd-exempt: <reason> on the line)"
  fi
}

# Scan that checks whether a script's own location -- where the bundled library lives -- is decided by an external command's output.
# Judges the literal source text (not a value only known at runtime -- looks at the form the author chose).
#
# The point where harm actually happens is **a `cd` whose destination is decided by command substitution** (same for `pushd`). If that command returns
# empty, moving to an empty string **succeeds without changing the working directory**, so taking the current location right after
# returns the launcher's own current directory, and it loads and runs whatever same-named library sits there -- this happens just by
# putting a `dirname` that returns empty at the front of PATH, and launching from a booby-trapped directory runs the planted file with that process's
# own privileges (measured). **The same form is already closed elsewhere, yet one spot alone slips through** -- that kept happening, so
# a machine counts it instead of human eyes.
# `dirname` alone isn't the one being forbidden, because the harm isn't specific to that command -- it's "handing the destination to an
# external command's output" itself (the same form happens with `realpath` or `readlink` too).
# The safe form: cut `${BASH_SOURCE[0]}` apart with **shell string operations** (the canonical version lives in
# scripts/lib/rein-common.sh and scripts/rein-hook.sh's location resolution). A relative path is handled either by
# dropping it (shared libraries, rein-request.sh) or prefixing the current directory (hooks, watcher, seat, this
# file) -- both never shell out to an external command, so that's outside this gate's scope.
# A `cd` that passes its destination as a **variable** (`cd "$dir"`) is out of scope -- what can go empty is an external command's output, and
# the variable's contents can be checked separately by whoever wrote it.
#
# Three things are excluded, all on the **never executed** side:
#   1. A line starting with `#` -- a comment explaining the mechanism (some sections spell out the attack form verbatim).
#   2. A line starting with `*` -- a `case` branch pattern (matching, not execution).
#   3. A line with `self-path-exempt: <reason>` on it -- an exception declared with a reason.
#      **Write the exception on the line** (a separate table would leave no way to tell which of the table and the code has gone stale).
gate_self_path() {
  local gate="self-path"
  local files file total=0 violations=0 out rc line pattern

  enumerate "$gate" collect_shell_files || return
  files="$ENUM_LIST"
  total="$(printf '%s\n' "$files" | grep -c '[^[:space:]]')"
  if [ "$total" -eq 0 ]; then
    gate_skip "${gate} (0 files)" "no shell scripts to check"
    return
  fi

  # The scan's literal text is **assembled here** (placing the violation sequence in check.sh's own source would make this gate
  # fail the moment it scans its own source). The movement verbs are kept split apart among the alternatives.
  pattern='(^|[^A-Za-z0-9_.-])(cd|pushd)[[:space:]]+(--[[:space:]]+)?["'"'"']?(\$\(|`)'
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    # Never give the scan's own failure (unreadable, an unparseable regex) the same face as "zero violations".
    out="$(LC_ALL=C grep -nE "$pattern" "$file")"
    rc=$?
    if [ "$rc" -gt 1 ]; then
      gate_fail "${gate}" "scan failed (grep rc=${rc}): ${file}"
      return
    fi
    [ -n "$out" ] || continue
    out="$(printf '%s\n' "$out" |
      grep -vE '^[0-9]+:[[:space:]]*#' |
      grep -vE '^[0-9]+:[[:space:]]*\*' |
      grep -v 'self-path-exempt:')"
    [ -n "$out" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      violations=$((violations + 1))
      printf '    %s:%s\n' "$file" "$line"
    done <<EOF
$out
EOF
  done <<EOF
$files
EOF

  if [ "$violations" -eq 0 ]; then
    gate_pass "$gate ($total files)"
  else
    gate_fail "${gate}" "${violations} cd calls whose destination is decided by an external command's output (cut the location out with string operations, or write self-path-exempt: <reason> on the line)"
  fi
}

# The shared scan for gates that reach a verdict one line at a time. A single place so **each gate never copies the same exclusion pattern**;
# three things are excluded (either the never-executed side, or a side declared with a reason):
#   1. A line starting with `#` -- a comment explaining the mechanism (some sections spell out the dangerous form verbatim).
#   2. A line starting with `*` -- a `case` branch pattern (matching, not execution).
#   3. A line with `<marker>: <reason>` on it -- an exception declared with a reason.
#      **Write the exception on the line** (a separate table would leave no way to tell which of the table and the code has gone stale).
# A suffix filter passed as the 4th argument narrows the scan to files ending in that spelling (for a rule that should apply
# to only one file). The scan's own failure (unreadable, an unparseable regex) never gets
# the same face as "zero violations" -- it returns 2, and the caller returns without printing a result line.
# Return value: 0 = no violations / 1 = violations found / 2 = scan failed (the FAIL line has already been printed).
GATE_SCAN_TOTAL=0
GATE_SCAN_VIOLATIONS=0
gate_scan_shell_lines() {
  local gate="$1" pattern="$2" marker="$3" suffix="${4:-}"
  local files file out rc line
  GATE_SCAN_TOTAL=0
  GATE_SCAN_VIOLATIONS=0
  enumerate "$gate" collect_shell_files || return 2
  files="$ENUM_LIST"
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    if [ -n "$suffix" ]; then
      case "$file" in
        *"$suffix") ;;
        *) continue ;;
      esac
    fi
    GATE_SCAN_TOTAL=$((GATE_SCAN_TOTAL + 1))
    out="$(LC_ALL=C grep -nE "$pattern" "$file")"
    rc=$?
    if [ "$rc" -gt 1 ]; then
      gate_fail "${gate}" "scan failed (grep rc=${rc}): ${file}"
      return 2
    fi
    [ -n "$out" ] || continue
    out="$(printf '%s\n' "$out" |
      grep -vE '^[0-9]+:[[:space:]]*#' |
      grep -vE '^[0-9]+:[[:space:]]*\*' |
      grep -v "${marker}:")"
    [ -n "$out" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      GATE_SCAN_VIOLATIONS=$((GATE_SCAN_VIOLATIONS + 1))
      printf '    %s:%s\n' "$file" "$line"
    done <<EOF
$out
EOF
  done <<EOF
$files
EOF
  [ "$GATE_SCAN_VIOLATIONS" -eq 0 ]
}

# Turns a scan's result into a result line. An empty set is SKIP, not PASS -- a state where nothing was checked never reads as green.
gate_scan_report() {
  local gate="$1" rc="$2" empty_reason="$3" fail_reason="$4"
  [ "$rc" -ne 2 ] || return
  if [ "$GATE_SCAN_TOTAL" -eq 0 ]; then
    gate_skip "${gate} (0 files)" "$empty_reason"
    return
  fi
  if [ "$rc" -eq 0 ]; then
    gate_pass "$gate (${GATE_SCAN_TOTAL} files)"
  else
    gate_fail "${gate}" "${GATE_SCAN_VIOLATIONS} ${fail_reason}"
  fi
}

# Whether the location of the bundled library (a script's own location) is ever built from an external command's output.
# The self-path gate only looks at **a `cd` whose destination is decided by an external command**, so a form that skips the move and
# just receives `dir="$(dirname "${BASH_SOURCE[0]}")"` before loading is invisible to it entirely -- the same setup
# (a same-named command returning empty placed at the front of PATH) makes the resolved target empty, and it loads
# `<empty>/rein-common.sh` built from that -- **exactly the form that actually happened at the hook's entry point** (launching from a
# booby-trapped directory runs the planted file with that process's own privileges -- measured).
#
# **There are two safe forms, and both pass** (treating only one as correct would fail a legitimate implementation):
#   (a) Cut `${BASH_SOURCE[0]}` apart with string operations and drop a relative path on the spot (shared libraries,
#       rein-request.sh).
#   (b) Also cut it apart with string operations, but make a relative path absolute by prefixing the current directory (hooks, watcher,
#       seat, this file, bin/rein).
# Only **resolution via an external command** is rejected -- both forms above never shell out to an external command, so
# neither falls within this gate's scope. A shell function (`bin/rein`'s resolve_self) and shell builtins
# (`cd` / `pwd`) are out of scope too -- they can't be swapped out via PATH.
gate_self_lib() {
  local gate="self-lib" rc tools pattern
  # The scan's literal text is **assembled here** (placing the violation sequence in check.sh's own source would make this gate
  # fail the moment it scans its own source).
  tools='dirname|basename|realpath|readlink|greadlink|grealpath'
  # shellcheck disable=SC2016  # the literal regex being scanned for (not an expression meant to expand in this function)
  pattern='\$\('"($tools)"'[[:space:]][^)]*(BASH_SOURCE|\$0)'
  gate_scan_shell_lines "$gate" "$pattern" "self-lib-exempt"
  rc=$?
  gate_scan_report "$gate" "$rc" "no shell scripts to check" \
    "cases where a script's own location is built from an external command's output (cut it out with string operations, or write self-lib-exempt: <reason> on the line)"
}

# Whether the minimal launcher the plugin's hooks call ever starts the runner with `exec`.
# `exec` replaces the launcher's process with the runner's, so **an exit code the runner fails with for its own shell
# reasons** (can't parse = 2, can't execute = 126/127, killed by signal = 128+n) becomes
# the hook's own exit code as-is. 2 means something different per event, and **for Stop it's the stop block itself**
# -- the runner misbehaving turns into control over the mechanism (and since it never passes through the launcher's own failure log, not a single line is left behind).
# The self-declared invariant "an internal error is always 1, across every event" breaks on the presence or absence of this one word alone.
# Runs on every event, every project, every session, so a machine counts it instead of human eyes.
#
# Only this one launcher file is in scope (no other layer claims to own the hook's exit code).
gate_launcher_exec() {
  local gate="launcher-exec" rc pattern verb
  verb='exec'
  pattern='(^|[;&|(])[[:space:]]*'"$verb"'[[:space:]]'
  gate_scan_shell_lines "$gate" "$pattern" "launcher-exec-exempt" "hooks/rein-hook-launcher.sh"
  rc=$?
  gate_scan_report "$gate" "$rc" "the launcher (hooks/rein-hook-launcher.sh) does not exist" \
    "cases of exec from the launcher (start it as a child and fold in the out-of-spec exit code, or write launcher-exec-exempt: <reason> on the line)"
}

# Whether an external process is ever started **outside the capped runner**. The cap (`rein_run_limited` / `rein_run_capture`)
# has its rationale in the shared library's verbatim comment: "a step's timeout only takes effect between loop iterations,
# so a call that never returns on its own becomes a permanent hang in unattended operation." The watcher's and seat's loops run
# exactly unattended, so a single call stuck outside the cap stalls the whole loop (and every heartbeat update with it),
# and the core feature of "handing over to a successor unattended" dies silently. In practice it was exactly one spot: a bare command
# substitution on the notification path.
# What's counted is `claude` / `osascript` **placed in a command position** -- every external process rein starts.
# A command position isn't just right after a delimiter (start of line, `;` `&` `|` `(`). **A form placed in a conditional position**
# (`if claude ...` / `! claude ...` / `while claude ...`) starts one too, so the shell keywords that follow a delimiter
# are skipped over before checking the spelling (keywords can stack -- `if ! claude ...`).
gate_run_limit() {
  local gate="run-limit" rc pattern cmds keywords
  cmds='claude|osascript'
  keywords='if|elif|while|until|then|else|do|!'
  pattern='(^|[;&|(])[[:space:]]*(('"$keywords"')[[:space:]]+)*('"$cmds"')[[:space:]]'
  gate_scan_shell_lines "$gate" "$pattern" "run-limit-exempt"
  rc=$?
  gate_scan_report "$gate" "$rc" "no shell scripts to check" \
    "cases of starting an external process outside the capped runner (route it through rein_run_limited / rein_run_capture, or write run-limit-exempt: <reason> on the line)"
}

# Whether a location's base is ever built by spelling out `${HOME:-}` directly. On a machine where HOME is empty or unset,
# `${HOME:-}/<relative>` **collapses** to `/<relative>`, and since it starts with `/` it sails straight past an "is it absolute" check
# -- a nonexistent path directly under root gets fixed as the location, and the reason it fails isn't "HOME is missing on this machine" but
# "cannot create that path" -- **a reason far removed from the cause** (against the point of fail-loud).
# The correct form routes through the shared predicate (`rein_xdg_base`), or checks HOME's shape before use and never lets it collapse
# (the launcher's `case "${HOME:-}" in /*)` -- the form used by a layer that doesn't read the shared library).
# The scan counts **only forms that build a path** -- a form like `[ -z "${HOME:-}" ]` or `case "${HOME:-}" in`, which is
# "a check to keep it from collapsing", never matches since no `/` follows.
gate_home_base() {
  local gate="home-base" rc pattern var
  var='HOME'
  pattern='\$\{'"$var"':-\}/'
  gate_scan_shell_lines "$gate" "$pattern" "home-base-exempt"
  rc=$?
  gate_scan_report "$gate" "$rc" "no shell scripts to check" \
    "cases of building a location's base by spelling out ${var} with a default value (route it through the shared predicate rein_xdg_base, or write home-base-exempt: <reason> on the line)"
}

# Whether it's a test-side writer (function names excluded from the scan). **The test side only touches the temp directory it made itself**,
# so it never counts as the threat model's "outside" (something a target project could bundle) --
# applying the same discipline meant for production writers here would only add dozens of meaningless declarations.
# It's split by name because the test side isn't split into its own files (an executable script keeps its own `selftest()`
# in the same file).
# The prefix never includes **the writer verb itself** (`write_`). Production writers normally spell themselves that way,
# so including it would drop a production writer out of scope on the name alone (in practice, the 3 functions for the live
# heartbeat, pointer, and stop marker were excluded this exact way). A test-side writer names itself `st_write_*` and is excluded by `^st_`.
# A form that gets into this exclusion just by renaming itself is closed by the `test-side-scope` gate (below).
# **The suffix (`_selftest$`) is never included** -- a production function like `gate_selftest` normally spells itself
# that way, so excluding by suffix would drop a production writer on the name alone. The one entry function is enough with an
# exact match on `^selftest$` (measured: dropping the suffix adds not a single new record-append violation).
GATE_TEST_SIDE_FUNCS='^(st_|rein_st_|fake_)|^selftest$'

# Since the exclusion above is decided by name, **naming a production function with a test-side name drops it right out of scope**
# (a renamed version of the very form that excluded the 3 live functions by their verb spelling). This gate closes that:
# **never call a test-side-named function from a production position**. A production writer with a renamed name
# still has a caller, so as long as that caller is a production function (or top level), it gets named here.
# Giving the caller a test-side name too changes nothing, as long as tracing the chain still lands on a production caller -- the top of
# any chain is always production (`main` or top level), so a live path always gets caught somewhere.
#
# Only counts **spelling placed in a command position** (a prefix like `if` / `!` / `while` is skipped over,
# the same form as run-limit). Assigning to a variable (`selftest=true`), literal text inside quotes
# (`grep 'st_expect_...'`), and `case` branch patterns aren't calls, so none of them match.
#
# Two things are excluded:
#   1. The caller itself is a test-side-named function -- the test side calling itself.
#   2. A line with `test-side-scope-exempt: <reason>` on it (the one line that launches selftest's entry point).
test_side_scope_scan_program() {
  cat <<'AWK'
BEGIN { fn = ""; heredoc = ""; heredoc_strip = 0 }
{
  if (heredoc != "") {
    tail = $0
    if (heredoc_strip) { sub(/^[[:space:]]+/, "", tail) }
    if (tail == heredoc) { heredoc = ""; heredoc_strip = 0 }
    next
  }
  if ($0 !~ /^[[:space:]]*#/ &&
      match($0, /<<-?[[:space:]]*("[A-Za-z_][A-Za-z0-9_]*"|'[A-Za-z_][A-Za-z0-9_]*'|[A-Za-z_][A-Za-z0-9_]*)/)) {
    token = substr($0, RSTART, RLENGTH)
    heredoc_strip = (substr(token, 3, 1) == "-") ? 1 : 0
    sub(/^<<-?[[:space:]]*/, "", token)
    gsub(/["']/, "", token)
    heredoc = token
  }
  if ($0 ~ /^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{/) {
    fn = $0
    sub(/\(\).*/, "", fn)
    next
  } else if ($0 ~ /^\}[[:space:]]*$/) {
    fn = ""
    next
  }
  if (fn != "" && fn ~ testside) next
  if ($0 ~ /^[[:space:]]*#/) next
  if (index($0, marker) > 0) next
  if ($0 ~ call_re) printf "%d:%s\n", NR, $0
}
AWK
}

gate_test_side_scope() {
  local gate="test-side-scope"
  local files file total=0 violations=0 out rc line program call_re keywords names
  enumerate "$gate" collect_shell_files || return
  files="$ENUM_LIST"
  program="$(test_side_scope_scan_program)"
  # The spelling being scanned for is **assembled here** (placing the violation sequence in check.sh's own source would make this gate
  # fail the moment it scans its own source).
  # The prefix form allows more name to follow, but the one entry word is checked with an **exact match**
  # (a prefix match would count production helper functions too, like `selftest_env_args`).
  names='st_|rein_st_|fake_'
  keywords='if|elif|while|until|then|else|do|!'
  call_re='(^|[;&|(]|[$][(])[[:space:]]*(('"$keywords"')[[:space:]]+)*(('"$names"')[A-Za-z0-9_]*|selftest)([[:space:]]|$)'
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    total=$((total + 1))
    out="$(LC_ALL=C awk -v testside="$GATE_TEST_SIDE_FUNCS" \
      -v marker="test-side-scope-exempt:" -v call_re="$call_re" \
      "$program" "$file")"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      gate_fail "${gate}" "scan failed (awk rc=${rc}): ${file}"
      return
    fi
    [ -n "$out" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      violations=$((violations + 1))
      printf '    %s:%s\n' "$file" "$line"
    done <<EOF
$out
EOF
  done <<EOF
$files
EOF

  if [ "$total" -eq 0 ]; then
    gate_skip "${gate} (0 files)" "no shell scripts to check"
    return
  fi
  if [ "$violations" -eq 0 ]; then
    gate_pass "$gate ($total files)"
  else
    gate_fail "${gate}" "${violations} calls to a test-side name from a production position (rename it to a production name, or write test-side-scope-exempt: <reason> on the line)"
  fi
}

# Whether a writer appending one record line **checks the write target's shape before appending**.
# `>>`, if the target is a symlink, grows whatever it points to (which could be outside the project), and if the symlink is broken,
# it **creates** that target -- yet the caller reads it as success. `.rein/`'s contents can be bundled into a clone
# (the threat model's "outside"), so every append must pass the same one check the replacement writer and the handover log use
# (`rein_dest_shape_ok`) -- in practice, exactly one live-log function skipped it and
# could be made to follow a bundled symlink and append to an arbitrary file outside the project.
# Judges whether the check is passed **inside the same function, before that append** (checking in a different function
# gives no guarantee it's actually called).
#
# Two things are excluded:
#   1. A test-side writer (the name list above) -- its scan root is its own temp directory.
#   2. A line with `record-append-exempt: <reason>` on it -- an exception declared with a reason.
#
# An append outside a function (at top level) can never have a test-side name, so it's always in scope. **The judgment inside a
# function resets at a `}` in column 0** -- without that reset, top-level lines following a test-side-named function
# would carry the exclusion all the way to the end of the file.
#
# **A heredoc's contents never count as evidence for where a function's boundary lies**. Its contents aren't this file's code -- they're
# literal text written out as a different file, so reading a `name() {` / `}` lined up inside it as a function's start/end would swap
# the enclosing function's name for the name inside it (in practice, `fake_...() {` inside a fake CLI a fixture writes out
# was exactly this, and the `fake_` exclusion existed only to absorb that side effect). The lines inside a heredoc are still scanned
# under the enclosing function's name -- never widening the exclusion. A run that loses track of the closing terminator never gets the same
# face as "zero violations" -- it surfaces as a scan failure (exit code 3).
record_append_scan_program() {
  cat <<'AWK'
BEGIN { fn = ""; checked = 0; heredoc = ""; heredoc_strip = 0 }
{
  if (heredoc != "") {
    body = 1
    tail = $0
    if (heredoc_strip) { sub(/^[[:space:]]+/, "", tail) }
    if (tail == heredoc) { heredoc = ""; heredoc_strip = 0; next }
  } else {
    body = 0
    if ($0 !~ /^[[:space:]]*#/ &&
        match($0, /<<-?[[:space:]]*("[A-Za-z_][A-Za-z0-9_]*"|'[A-Za-z_][A-Za-z0-9_]*'|[A-Za-z_][A-Za-z0-9_]*)/)) {
      token = substr($0, RSTART, RLENGTH)
      heredoc_strip = (substr(token, 3, 1) == "-") ? 1 : 0
      sub(/^<<-?[[:space:]]*/, "", token)
      gsub(/["']/, "", token)
      heredoc = token
    }
  }
  if (body == 0) {
    if ($0 ~ /^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{/) {
      fn = $0
      sub(/\(\).*/, "", fn)
      checked = 0
    } else if ($0 ~ /^\}[[:space:]]*$/) {
      fn = ""
      checked = 0
      next
    }
  }
  if (index($0, "rein_dest_shape_ok") > 0) { checked = 1 }
  if (fn != "" && fn ~ testside) next
  if (index($0, marker) > 0) next
  if ($0 ~ /^[[:space:]]*#/) next
  if ($0 ~ append_re && checked == 0) printf "%d:%s\n", NR, $0
}
END {
  if (heredoc != "") {
    printf "0:cannot find the heredoc's closing terminator %s (the scan's structural judgment did not hold)\n", heredoc
    exit 3
  }
}
AWK
}

gate_record_append() {
  local gate="record-append"
  local files file total=0 violations=0 out rc line program

  enumerate "$gate" collect_shell_files || return
  files="$ENUM_LIST"
  program="$(record_append_scan_program)"
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    total=$((total + 1))
    # Never give the scan's own failure (unreadable, awk itself crashed) the same face as "zero violations".
    out="$(LC_ALL=C awk -v testside="$GATE_TEST_SIDE_FUNCS" \
      -v marker="record-append-exempt:" -v append_re='>>[[:space:]]*"' \
      "$program" "$file")"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      gate_fail "${gate}" "scan failed (awk rc=${rc}): ${file}"
      return
    fi
    [ -n "$out" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      violations=$((violations + 1))
      printf '    %s:%s\n' "$file" "$line"
    done <<EOF
$out
EOF
  done <<EOF
$files
EOF

  if [ "$total" -eq 0 ]; then
    gate_skip "${gate} (0 files)" "no shell scripts to check"
    return
  fi
  if [ "$violations" -eq 0 ]; then
    gate_pass "$gate ($total files)"
  else
    gate_fail "${gate}" "${violations} appends that never check the write target's shape (route it through rein_dest_shape_ok, or write record-append-exempt: <reason> on the line)"
  fi
}

# Whether the response that blocks a stop (`block`) has **its output before it's recorded to the fire log**.
# A hook can be cut off from outside by the registered timeout (hooks/hooks.json's 10 seconds), so inserting an
# irrevocable layer between consuming a marker (a latch, a cooldown) and the output means that a cut-off run
# **consumes the marker but not a single character of block reaches anywhere** -- the lineage's log says "blocked" while the model never
# gets it, and that generation passes through unblocked from then on. The fire log can fall back to acquiring a lock and running `ps`, making it the
# longest layer in this window, so it's placed after the output.
# Judges whether the output happens **inside the same function, before that record** is written. Every time it passes a preceding
# record line, it drops "output seen" -- so in a function with two stop-blocking branches (a normal handover trigger, and re-blocking a
# rejected generation), one branch's output can never cover for the other branch's record.
stop_order_scan_program() {
  cat <<'AWK'
BEGIN { fn = ""; emitted = 0; hits = 0 }
/^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{/ { emitted = 0 }
{
  if ($0 ~ /^[[:space:]]*#/) next
  if ($0 ~ output_re) { emitted = 1; next }
  if ($0 ~ record_re) {
    hits++
    if (index($0, marker) == 0 && emitted == 0) printf "%d:%s\n", NR, $0
    emitted = 0
  }
}
END { printf "hits=%d\n", hits > "/dev/stderr" }
AWK
}

gate_stop_order() {
  local gate="stop-order"
  local files file total=0 violations=0 out err rc line program hits

  enumerate "$gate" collect_shell_files || return
  files="$ENUM_LIST"
  program="$(stop_order_scan_program)"
  err="$(mktemp "${TMPDIR:-/tmp}/rein-check-stop-order.XXXXXX")" || {
    gate_fail "${gate}" "cannot create the scan's temp file"
    return
  }
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    out="$(LC_ALL=C awk -v marker="stop-order-exempt:" \
      -v output_re='printf .*"[$]block"' \
      -v record_re='hook_fire_log[[:space:]]+[A-Za-z]+[[:space:]]+block' \
      "$program" "$file" 2>"$err")"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      rm -f "$err"
      gate_fail "${gate}" "scan failed (awk rc=${rc}): ${file}"
      return
    fi
    hits="$(sed -n 's/^hits=\([0-9]*\)$/\1/p' "$err")"
    total=$((total + ${hits:-0}))
    [ -n "$out" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      violations=$((violations + 1))
      printf '    %s:%s\n' "$file" "$line"
    done <<EOF
$out
EOF
  done <<EOF
$files
EOF
  rm -f "$err"

  if [ "$total" -eq 0 ]; then
    gate_skip "${gate} (0 checks)" "not a single line records a stop block to the log"
    return
  fi
  if [ "$violations" -eq 0 ]; then
    gate_pass "$gate ($total checks)"
  else
    gate_fail "${gate}" "${violations} stop-block outputs after the fire log record (move the output before the record, or write stop-order-exempt: <reason> on the line)"
  fi
}

# Whether parsing a flag that takes a value **fails a form missing that value, with a reason**.
# A form that silently falls back on `shift 2` failing (`shift 2 || return 2`) turns a single typo into **not printing a single line of
# reason before ending non-zero**. A handover request is one line the primary session types automatically, so a silent
# non-zero means nobody can observe why it couldn't be placed, while the handover just never happens.
# Judges whether the value is checked **inside the option's branch, before `shift 2`**.
# The checks that pass are `need_value` / `check_opt` (including `rein_config_check_opt`), and a bare count check
# (`$# -ge 2` / `$# -lt 2`) -- all forms that fail with a reason printed.
flag_value_scan_program() {
  cat <<'AWK'
BEGIN { arm = 0; guard = 0; checks = 0 }
/^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{/ { arm = 0; guard = 0 }
/^[[:space:]]*esac[[:space:]]*$/ { arm = 0; guard = 0 }
/^[[:space:]]*;;[[:space:]]*$/ { arm = 0; guard = 0 }
/^[[:space:]]*-{1,2}[A-Za-z0-9][^)]*\)[[:space:]]*$/ { arm = 1; guard = 0; next }
{
  if ($0 ~ /^[[:space:]]*#/) next
  if ($0 ~ guard_re) guard = 1
  if ($0 ~ shift_re && arm == 1) {
    checks++
    if (index($0, marker) == 0 && guard == 0) printf "%d:%s\n", NR, $0
  }
}
END { printf "checks=%d\n", checks > "/dev/stderr" }
AWK
}

gate_flag_value() {
  local gate="flag-value"
  local files file total=0 violations=0 out err rc line program checks

  enumerate "$gate" collect_shell_files || return
  files="$ENUM_LIST"
  program="$(flag_value_scan_program)"
  err="$(mktemp "${TMPDIR:-/tmp}/rein-check-flag-value.XXXXXX")" || {
    gate_fail "${gate}" "cannot create the scan's temp file"
    return
  }
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    out="$(LC_ALL=C awk -v marker="flag-value-exempt:" \
      -v guard_re='need_value|check_opt|[$]# -ge 2|[$]# -lt 2' \
      -v shift_re='(^|[^A-Za-z0-9_])shift[[:space:]]+2([^0-9]|$)' \
      "$program" "$file" 2>"$err")"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      rm -f "$err"
      gate_fail "${gate}" "scan failed (awk rc=${rc}): ${file}"
      return
    fi
    checks="$(sed -n 's/^checks=\([0-9]*\)$/\1/p' "$err")"
    total=$((total + ${checks:-0}))
    [ -n "$out" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      violations=$((violations + 1))
      printf '    %s:%s\n' "$file" "$line"
    done <<EOF
$out
EOF
  done <<EOF
$files
EOF
  rm -f "$err"

  if [ "$total" -eq 0 ]; then
    gate_skip "${gate} (0 checks)" "not a single branch handles a flag that takes a value"
    return
  fi
  if [ "$violations" -eq 0 ]; then
    gate_pass "$gate ($total checks)"
  else
    gate_fail "${gate}" "${violations} value-taking flags parsed in a way that fails without printing a reason (route it through need_value / check_opt, or write flag-value-exempt: <reason> on the line)"
  fi
}

# The 3 places carrying the distribution metadata's author name (every surface a recipient checks identity against).
# One line = `<label> <relative path> <how to extract>`. The extraction method is either json:<jq expression> or copyright (takes the
# name from the copyright line).
dist_author_sources() {
  cat <<'EOF'
plugin.json(author.name) .claude-plugin/plugin.json json:.author.name
marketplace.json(owner.name) .claude-plugin/marketplace.json json:.owner.name
LICENSE LICENSE copyright
EOF
}

# Takes just the name from a copyright line (the `<name>` in `Copyright (c) <year> <name>`. Cuts before the `)` since it also
# accepts a name placed inside parentheses).
dist_author_copyright() {
  LC_ALL=C sed -n 's/.*Copyright (c) [0-9][0-9]* \([^)]*\).*/\1/p' "$1" | sed -n '1p'
}

# Whether the distribution metadata's author name agrees across all 3 places.
# From the recipient's view, one distributed package showing two different author names (a different name in `/plugin`'s
# detail than in the marketplace listing) leaves the recipient unable to confirm whether it's the same person
# -- identity checking fails once published. In practice the surfaces being checked were split across 2 different spellings, and the existing
# plugin gate only checked that `owner.name` was non-empty, so it stayed green the whole time.
gate_dist_author() {
  local gate="dist-author"
  local line label rel how path value first="" first_label="" total=0 violations=0

  require_tool "$gate" "$JQ_BIN" "e.g. on macOS, /usr/bin/jq" || return

  # If even one scan root is missing, the comparison itself can't hold (never let it read as "they agree" while something is missing --
  # shown as SKIP, not PASS).
  while read -r label rel how; do
    [ -n "$label" ] || continue
    [ -f "$ROOT/$rel" ] || { gate_skip "${gate} (0 files)" "the distribution metadata is missing one of its 3 places (missing: ${rel})"; return; }
  done <<EOF
$(dist_author_sources)
EOF

  while read -r label rel how; do
    [ -n "$label" ] || continue
    path="$ROOT/$rel"
    total=$((total + 1))
    case "$how" in
      json:*) value="$("$JQ_BIN" -r "${how#json:} // empty" "$path" 2>/dev/null)" ;;
      *) value="$(dist_author_copyright "$path")" ;;
    esac
    if [ -z "$value" ]; then
      violations=$((violations + 1))
      printf '    %s: cannot extract the author name: %s\n' "$label" "$rel"
      continue
    fi
    if [ -z "$first" ]; then
      first="$value"
      first_label="$label"
      continue
    fi
    if [ "$value" != "$first" ]; then
      violations=$((violations + 1))
      printf '    %s has an author name that differs from %s: %s / %s\n' "$label" "$first_label" "$value" "$first"
    fi
  done <<EOF
$(dist_author_sources)
EOF

  if [ "$total" -eq 0 ]; then
    gate_skip "${gate} (0 files)" "not a single file carries the distribution metadata's author name"
    return
  fi
  if [ "$violations" -eq 0 ]; then
    gate_pass "$gate ($total files)"
  else
    gate_fail "${gate}" "${violations} mismatches in the distribution metadata's author name (align all 3 places to one spelling)"
  fi
}

# A file carrying the section table (one whose line defining `rein_st_section_table` starts at column 0).
# Swapping it in inside a subshell (a check of the section-selection mechanism itself) doesn't start at column 0, so it isn't picked up.
section_table_files() {
  local file
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    LC_ALL=C grep -q '^rein_st_section_table() {' "$file" || continue
    printf '%s\n' "$file"
  done <<EOF
$1
EOF
}

# The section names listed in the table, with `<layer>:` dropped (the part that corresponds to the check file's name).
section_table_names() {
  LC_ALL=C sed -n '/^rein_st_section_table() {/,/^}/p' "$1" |
    awk 'NF == 2 && $1 ~ /:/ { sub(/^[^:]*:/, "", $1); print $1 }'
}

# Rejects a form where a check file is created but **forgotten from the section table**.
# The table-to-implementation direction (listed in the table with nothing behind it) is already rejected by `rein_st_sections_run`, but
# nobody was checking the reverse (a file exists but isn't in the table) -- in practice **32 cases never ran even once** while
# every gate stayed green. A check that never runs "produces zero failures", so there's no way to notice coverage has thinned.
# Judges every **`.sh` sitting in the same directory as the file that carries the section table** (this repo's layout puts one directory =
# one collection of selftest sections, and this rides on that).
#
# Three things are excluded:
#   1. The file that defines the table itself (it's the mechanism, not a section).
#   2. A location whose directory isn't named `selftest` -- a layer that doesn't split sections into files
#      (an executable script that carries the table inside itself).
#   3. A file with `section-table-exempt: <reason>` written somewhere in it -- an exception with a reason
#      (a tool sections share, rather than a section itself, etc).
gate_section_table() {
  local gate="section-table"
  local files table tables dir names name base entry known total=0 violations=0

  enumerate "$gate" collect_shell_files || return
  files="$ENUM_LIST"
  tables="$(section_table_files "$files")"
  while IFS= read -r table; do
    [ -n "$table" ] || continue
    dir="${table%/*}"
    case "${dir##*/}" in
      selftest) ;;
      *) continue ;;
    esac
    names="$(section_table_names "$table")"
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      case "$entry" in
        "$dir"/*.sh) ;;
        *) continue ;;
      esac
      [ "$entry" != "$table" ] || continue
      case "${entry#"$dir"/}" in
        */*) continue ;;
      esac
      LC_ALL=C grep -q 'section-table-exempt:' "$entry" && continue
      total=$((total + 1))
      base="${entry##*/}"
      base="${base%.sh}"
      known=0
      while IFS= read -r name; do
        [ "$name" = "$base" ] && known=1
      done <<EOF
$names
EOF
      if [ "$known" -eq 0 ]; then
        violations=$((violations + 1))
        printf '    %s is missing from the section table in %s (add a line whose second half of the section name is %s)\n' \
          "$entry" "$table" "$base"
      fi
    done <<EOF
$files
EOF
  done <<EOF
$tables
EOF

  if [ "$total" -eq 0 ]; then
    gate_skip "${gate} (0 files)" "no check directory carries a section table"
    return
  fi
  if [ "$violations" -eq 0 ]; then
    gate_pass "$gate ($total files)"
  else
    gate_fail "${gate}" "${violations} check files missing from the section table (add them to the table, or write section-table-exempt: <reason> in the file)"
  fi
}

# A file carrying the gate table (one whose line defining `rein_gate_table` starts at column 0).
gate_table_files() {
  local file
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    LC_ALL=C grep -q '^rein_gate_table() {' "$file" || continue
    printf '%s\n' "$file"
  done <<EOF
$1
EOF
}

# The `<gate name> <function name>` pairs listed in the table. Since the table's body is a heredoc, the starting line (`cat <<'EOF'`) is never
# counted as 2 columns -- only lines whose second column starts with `gate_` are picked up.
gate_table_rows() {
  LC_ALL=C sed -n '/^rein_gate_table() {/,/^}/p' "$1" |
    awk 'NF == 2 && $2 ~ /^gate_/ { print $1 " " $2 }'
}

# The `<name it claims> <function name>` pairs for gates as implemented. Every gate **states the name it shows on its own
# result line via `local gate="<name>"`**, so that becomes the primary source on the implementation side. A value that's a variable form
# (`local gate="$1"`) is a shared scan helper that never prints a result line, so it isn't counted (excluded by `[^$"]`).
gate_table_impl() {
  LC_ALL=C awk -v marker="gate-table-exempt:" '
    /^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{/ {
      fn = $0
      sub(/\(\).*/, "", fn)
      next
    }
    /^\}[[:space:]]*$/ { fn = ""; next }
    fn != "" && $0 ~ /^[[:space:]]*local[[:space:]]+gate="[^$"]+"/ {
      if (index($0, marker) > 0) { fn = ""; next }
      name = $0
      sub(/^[[:space:]]*local[[:space:]]+gate="/, "", name)
      sub(/".*/, "", name)
      print name " " fn
      fn = ""
    }
  ' "$1"
}

# The **reverse** direction between the gate table and the implementation. `run_gates` rejects "listed in the table with nothing behind it", but nobody
# was checking the reverse (writing `gate_*` and forgetting to list it in the table -- that gate never runs even once). A check that never runs
# produces zero failures, so there's no way to notice coverage has thinned -- exactly the same structure as the motive for building
# `section-table`, just with the target swapped for the gate table.
# Since it's **the name/function-name pair** being cross-checked, this catches not just a missing registration but also
# any drift between the table's first column and the name a function claims (the text on a result line splitting from the spelling used to name it with `--gate`), in the same pass.
#
# Two things are excluded:
#   1. Anything other than the file that defines the table -- a `gate_*` in a file without a table is never looked at.
#   2. A function whose `local gate=` line has `gate-table-exempt: <reason>` on it -- an exception declared with a reason.
gate_gate_table() {
  local gate="gate-table"
  local files table tables rows pair name func total=0 violations=0

  enumerate "$gate" collect_shell_files || return
  files="$ENUM_LIST"
  tables="$(gate_table_files "$files")"
  while IFS= read -r table; do
    [ -n "$table" ] || continue
    rows="$(gate_table_rows "$table")"
    while IFS= read -r pair; do
      [ -n "$pair" ] || continue
      total=$((total + 1))
      printf '%s\n' "$rows" | LC_ALL=C grep -qxF "$pair" && continue
      violations=$((violations + 1))
      name="${pair%% *}"
      func="${pair#* }"
      printf '    %s: %s is missing from the table in %s (add a line: %s %s)\n' \
        "$table" "$func" "$table" "$name" "$func"
    done <<EOF
$(gate_table_impl "$table")
EOF
  done <<EOF
$tables
EOF

  if [ "$total" -eq 0 ]; then
    gate_skip "${gate} (0 files)" "no file carries a gate table"
    return
  fi
  if [ "$violations" -eq 0 ]; then
    gate_pass "$gate ($total gates)"
  else
    gate_fail "${gate}" "${violations} gate implementations missing from the table (add them to the table, or write gate-table-exempt: <reason> on the local gate= line)"
  fi
}

# Pins on the real repo that the scan's material is **the set git manages**.
# A run where `collect_all_files` fell back to `find` never sees `.gitignore` -- it's checking a different set, yet
# that's **only shown** on the scan-root line, unnoticeable without someone reading it. Never lets a run where someone
# reverted enumeration to always use `find`, or a run that fell back to a set that ignores the ignore list, pass green.
# **The fallback is legitimate on a machine without git, and where the scan root isn't the root of a git working tree
# itself (a selftest fixture -- a temp directory)**, so it's SKIP there (never red).
# Cross-checking the set itself is done through a different git command (`check-ignore`) -- never places a copy of
# `ls-files --exclude-standard` on the check side (never build a second implementation looking at the same thing).
gate_scan_source() {
  local gate="scan-source"
  local total=0 violations=0 all ignored path leaked=0

  if ! scan_root_is_git_toplevel; then
    gate_skip "${gate} (0 checks)" \
      "the scan root is not the root of a git working tree (a machine where falling back to find is legitimate): ${ROOT}"
    return
  fi

  scan_resolve_source
  total=$((total + 1))
  if [ "$SCAN_SOURCE" != "git" ]; then
    violations=$((violations + 1))
    printf '    the scan target is not the set git manages: %s\n' "$SCAN_SOURCE"
  fi

  # Confirms that not a single ignored file is mixed into the scan (that `.gitignore` is actually taking effect),
  # through a channel separate from enumeration. rc=1 when there's no match isn't a failure.
  all="$(collect_all_files)" || {
    gate_fail "${gate}" "could not enumerate scan targets (scan root: ${ROOT})"
    return
  }
  ignored="$(scan_find_files | git -C "$ROOT" check-ignore --stdin 2>/dev/null)"
  total=$((total + 1))
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if printf '%s\n' "$all" | LC_ALL=C grep -qxF "$path"; then
      leaked=$((leaked + 1))
      printf '    an ignored file is inside the scan target: %s\n' "$path"
    fi
  done <<EOF
$ignored
EOF
  [ "$leaked" -eq 0 ] || violations=$((violations + 1))

  if [ "$violations" -eq 0 ]; then
    gate_pass "$gate ($total checks, $(printf '%s\n' "$ignored" | grep -c '[^[:space:]]') ignored files)"
  else
    gate_fail "${gate}" "${violations}/${total} checks got the scan target wrong"
  fi
}

# The gate table (1 line = `<gate name> <function name>`). The table's **order is the execution order**.
# A gate name matches the literal text each gate prints on its result line (so the name seen in output can be named directly).
# The run-everything path and the run-by-name path share this one table -- never create a gate that's
# listed on only one of them.
# **Never split by who's running it** (anyone can run it). The TERM / KILL that selftest fires on a deadline overrun
# only reaches the dedicated process group the supervisor made with `setpgid(0, 0)` -- processes the test itself started --
# so safety doesn't change based on who owns the machine.
rein_gate_table() {
  cat <<'EOF'
shellcheck gate_shellcheck
jq gate_json
plugin gate_plugin
docs-links gate_docs_links
shell-quote gate_shell_quote
lineage-cmd gate_lineage_cmd
self-path gate_self_path
self-lib gate_self_lib
launcher-exec gate_launcher_exec
run-limit gate_run_limit
home-base gate_home_base
record-append gate_record_append
test-side-scope gate_test_side_scope
stop-order gate_stop_order
flag-value gate_flag_value
section-table gate_section_table
gate-table gate_gate_table
dist-author gate_dist_author
scan-source gate_scan_source
selftest gate_selftest
bash32 gate_bash32
EOF
}

rein_gate_names() {
  rein_gate_table | awk 'NF { print $1 }'
}

# Checks name matches with an exact match (a partial match via `$1 ~ want` would let an existing name's prefix or one
# regex metacharacter pick out a different gate, running an unintended one from the by-name entry point).
rein_gate_func() {
  rein_gate_table | awk -v want="$1" '$1 == want { print $2 }'
}

# One line to lay out for the usage display and error messages.
rein_gate_names_inline() {
  rein_gate_names | tr '\n' ' ' | sed 's/ *$//'
}

# Runs only the chosen gates, in table order (every gate if the first argument is empty).
run_gates() {
  local selected="${1:-}"
  local names name func
  # Decides this here (the parent shell), so no later gate ever looks at a set that differs from what's shown
  # (deciding it inside command substitution would only persist inside the subshell, forcing a re-measure per gate).
  scan_resolve_source
  # Shows not just the scan root but **what was actually scanned**. A run that fell back to find because it couldn't use git's managed set
  # never sees `.gitignore` -- the set actually checked is different, and that difference is never left unstated.
  printf '%s: gates on %s (scan target: %s)\n' "$SCRIPT_NAME" "$ROOT" "$(scan_source_label)"
  selftest_env_args
  # **The list is read to the end before calling anything.** Calling a gate while still reading the list (calling it from inside a
  # `while read` body) would let a gate that reads stdin swallow the rest of the list, and every gate after it **silently gets skipped**
  # -- not a single failure prints, only the count drops, so nobody notices the check thinning out.
  names="$(rein_gate_names)"
  for name in $names; do
    [ -z "$selected" ] || [ "$selected" = "$name" ] || continue
    func="$(rein_gate_func "$name")"
    # Never lets a form listed in the table with nothing behind it pass silently (a silent skip would drop just that
    # gate's worth of checking without a single failure).
    if [ -z "$func" ] || ! type "$func" >/dev/null 2>&1; then
      gate_fail "${name}" "the table's function does not exist: ${func:-the table names no function}"
      continue
    fi
    "$func"
  done
  printf '%s: %d gates pass / %d fail / %d skip\n' \
    "$SCRIPT_NAME" "$gate_pass_count" "$gate_fail_count" "$gate_skip_count"
  [ "$gate_fail_count" -eq 0 ]
}

# The entry point that runs exactly one gate by name. Without it, a judgment a gate already carries would have to be copied out by hand and
# checked separately -- creating a second implementation looking at the same thing.
# A missing gate name, an unknown name, or two or more listed together, is never left silently at zero (the same
# face as everything passing) -- it fails. Who can run it is never split by gate (the table's header carries the reason).
run_one_gate() {
  local name="${1:-}"
  if [ "$#" -ne 1 ] || [ -z "$name" ]; then
    printf '%s: --gate takes exactly one gate name (gate names: %s)\n' \
      "$SCRIPT_NAME" "$(rein_gate_names_inline)" >&2
    return 2
  fi
  if [ -z "$(rein_gate_func "$name")" ]; then
    printf '%s: no gate goes by that name: %s (gate names: %s)\n' \
      "$SCRIPT_NAME" "$name" "$(rein_gate_names_inline)" >&2
    return 2
  fi
  run_gates "$name"
}

st_pass_count=0
st_fail_count=0

rein_st_section_table() {
  cat <<'EOF'
pure:safe st_section_safe
proc:deadline st_section_deadline
EOF
}

st_ok() {
  st_pass_count=$((st_pass_count + 1))
}

st_fail() {
  st_fail_count=$((st_fail_count + 1))
  printf '  FAIL %s: %s\n' "$1" "$2"
}

# Equivalent to a shared library (placed under lib/, has neither execute permission nor --selftest).
st_write_clean_sh() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "clean"
EOF
}

# An executable script that follows the convention (execute permission, final line is the selftest summary).
st_write_stub_sh() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "--selftest" ]; then
  echo "stub.sh: selftest 1 pass / 0 fail"
  exit 0
fi
echo "stub"
EOF
  chmod +x "$1"
}

# An executable script with no extension (the same shape as a command body under bin/).
# check.sh derives the summary line's name from basename, so it must match the file name.
st_write_stub_noext() {
  local name
  name="$(basename "$1")"
  cat >"$1" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [ "\${1:-}" = "--selftest" ]; then
  echo "${name}: selftest 1 pass / 0 fail"
  exit 0
fi
echo "stub"
EOF
  chmod +x "$1"
}

# An executable file with no extension and no --selftest (the side that fails as a convention violation).
st_write_noext_without_selftest() {
  cat >"$1" <<'EOF'
#!/bin/sh
echo "no selftest support"
EOF
  chmod +x "$1"
}

# An executable script with `env -S` in between (unless resolved through to the real command, it silently falls out of the convention's scope).
st_write_noext_env_s() {
  local name
  name="$(basename "$1")"
  cat >"$1" <<EOF
#!/usr/bin/env -S bash -u
set -uo pipefail
if [ "\${1:-}" = "--selftest" ]; then
  echo "${name}: selftest 1 pass / 0 fail"
  exit 0
fi
echo "stub"
EOF
  chmod +x "$1"
}

# An unsupported env option form. Never silently excluded -- the side that fails as an enumeration failure.
st_write_noext_env_unsupported() {
  cat >"$1" <<'EOF'
#!/usr/bin/env -i bash
echo "unresolvable shebang"
EOF
  chmod +x "$1"
}

# An executable script that goes red if the surrounding REIN_* are left in place (the side that measures the selftest gate's cleanup).
st_write_env_probe_sh() {
  local name
  name="$(basename "$1")"
  cat >"$1" <<EOF
#!/usr/bin/env bash
set -uo pipefail
if [ "\${1:-}" = "--selftest" ]; then
  if [ -n "\${REIN_MODEL:-}" ] || [ -n "\${REIN_CONFIG_FILE:-}" ]; then
    echo "  FAIL surrounding REIN_* are left in place"
    echo "${name}: selftest 0 pass / 1 fail"
    exit 1
  fi
  echo "${name}: selftest 1 pass / 0 fail"
  exit 0
fi
exit 0
EOF
  chmod +x "$1"
}

# An executable script that measures the inner bash being passed through. What the side that relaunches its own body inside selftest reads,
# `REIN_SELFTEST_BASH`, is **appended** straight to a record file (so what each gate passed can be counted from
# outside, in call order -- measuring the value that actually arrived, not the literal text shown).
st_write_inner_bash_probe_sh() {
  local name record="$2"
  name="$(basename "$1")"
  cat >"$1" <<EOF
#!/usr/bin/env bash
set -uo pipefail
if [ "\${1:-}" = "--selftest" ]; then
  printf '%s\n' "\${REIN_SELFTEST_BASH:-<unset>}" >>"$record" # record-append-exempt: a probe this check writes into its own mktemp -d (not the lineage records)
  echo "${name}: selftest 1 pass / 0 fail"
  exit 0
fi
exit 0
EOF
  chmod +x "$1"
}

# A shebang for something other than a shell (judging too broadly would fail things the convention was never meant to cover).
st_write_noext_foreign() {
  cat >"$1" <<'EOF'
#!/usr/bin/env python3
print("not a shell script")
EOF
  chmod +x "$1"
}

st_write_valid_json() {
  printf '{"name":"fixture","items":[1,2,3]}\n' >"$1"
}

# Fixture for a plugin manifest (writes the 2nd argument's JSON body as-is).
st_write_plugin_manifest() {
  mkdir -p "$1/.claude-plugin"
  printf '%s\n' "$2" >"$1/.claude-plugin/plugin.json"
}

# Fixture for the plugin's hooks registration table (writes the 2nd argument's JSON body as-is).
st_write_plugin_hooks() {
  mkdir -p "$1/hooks"
  printf '%s\n' "$2" >"$1/hooks/hooks.json"
}

# A registration table that follows the convention (covers all 4 events, carries type=command and timeout, and registers
# a call to the launcher inside the plugin **with quoting**, and PostToolBatch carries no matcher).
# The gate checks all the way down to the launcher's real target (that it's executable), so this is placed on the fixture side too.
# The directive right below covers the whole function (never expands the registration table's literal text or the launcher's generated content).
# shellcheck disable=SC2016  # the literal text that appears in the registration table (must not be expanded)
st_write_plugin_hooks_ok() {
  st_write_plugin_hooks "$1" \
    '{"hooks":{"PostToolBatch":[{"hooks":[{"type":"command","command":"\"${CLAUDE_PLUGIN_ROOT}/hooks/rein-hook-launcher.sh\" post-tool-batch","timeout":10}]}],"Stop":[{"hooks":[{"type":"command","command":"\"${CLAUDE_PLUGIN_ROOT}/hooks/rein-hook-launcher.sh\" stop","timeout":10}]}],"SessionStart":[{"hooks":[{"type":"command","command":"\"${CLAUDE_PLUGIN_ROOT}/hooks/rein-hook-launcher.sh\" session-start","timeout":10}]}],"UserPromptSubmit":[{"hooks":[{"type":"command","command":"\"${CLAUDE_PLUGIN_ROOT}/hooks/rein-hook-launcher.sh\" user-prompt-submit","timeout":10}]}]}}'
  mkdir -p "$1/hooks"
  # The fixture's launcher follows the executable-script convention too (has --selftest) -- without that,
  # the fixture measuring the plugin gate would fail on the selftest gate, hiding the judgment it was meant to measure.
  printf '#!/bin/sh\ncase "${1:-}" in --selftest) printf "rein-hook-launcher.sh: selftest 1 pass / 0 fail\\n"; exit 0 ;; esac\nexit 0\n' \
    >"$1/hooks/rein-hook-launcher.sh"
  chmod +x "$1/hooks/rein-hook-launcher.sh"
}

# Fixture for the marketplace registration table (writes the 2nd argument's JSON body as-is).
st_write_plugin_marketplace() {
  mkdir -p "$1/.claude-plugin"
  printf '%s\n' "$2" >"$1/.claude-plugin/marketplace.json"
}

# A marketplace registration table that follows the convention (name / owner / plugins, source is a relative path).
st_write_plugin_marketplace_ok() {
  st_write_plugin_marketplace "$1" \
    '{"name":"claude-rein","owner":{"name":"someone"},"plugins":[{"name":"rein","source":"./"}]}'
}

# Fixture for the docs-links gate. The accepting side is a relative link that resolves, with link text that's an ordinary word.
# It mixes in a link with just an external URL and one with just an anchor too (both are out of scope, since neither has a target to resolve).
st_write_docs_links_ok() {
  mkdir -p "$1/docs"
  printf '# Map\n\nThe entry point is [the handover contract entry point](architecture.md), external is [the official guide](https://example.com/a/b.md), same-document is [the section below](#sec).\n' \
    >"$1/docs/README.md"
  printf '# Handover Contract\n\nThe map is [the developer-facing doc](README.md).\n\n## sec\n' >"$1/docs/architecture.md"
}

# A relative link that doesn't resolve (the form where a rename kills a link).
st_write_docs_links_missing() {
  mkdir -p "$1/docs"
  printf '# Map\n\nThe specification is [the handover specification](spec/handover.md).\n' >"$1/docs/README.md"
}

# A form where link text exposes directory structure (contains `/`).
st_write_docs_links_text_slash() {
  mkdir -p "$1/docs"
  printf '# Map\n\nThe entry point is [docs/architecture](architecture.md).\n' >"$1/docs/README.md"
  printf '# Handover Contract\n' >"$1/docs/architecture.md"
}

# A form where link text is the file name itself (ends in `.md`).
st_write_docs_links_text_md() {
  mkdir -p "$1/docs"
  printf '# Map\n\nThe entry point is [architecture.md](architecture.md).\n' >"$1/docs/README.md"
  printf '# Handover Contract\n' >"$1/docs/architecture.md"
}

# Literal text inside an inline code span isn't a link either (the side that never fails a sentence describing link syntax).
# The rejecting side is docs-links-missing (placing the same literal text outside a code span makes its target get checked).
# shellcheck disable=SC2016  # the literal text of the code span (must not be expanded)
st_write_docs_links_codespan() {
  mkdir -p "$1/docs"
  printf '# Explanation\n\nWrite a relative link as `[text](target)`.\n' >"$1/docs/README.md"
}

# Literal text inside a code fence isn't a link (the side that never fails an example showing markdown syntax).
st_write_docs_links_fence() {
  mkdir -p "$1/docs"
  {
    printf '# Writing example\n\n'
    printf '```\n'
    printf '[some words](a-file-that-does-not-exist.md)\n'
    printf '```\n'
  } >"$1/docs/README.md"
}

# Fixture for the shell-quote gate. **Never places the violation's literal text in check.sh's own source** (placing it there would make this
# gate fail the moment it scans its own source) -- keeps the command's real target, option, and verb as separate words,
# never assembled adjacent to each other inside this function (the sequence `rein --cwd <value> up` also falls within the lineage-cmd gate's
# scope, so they only line up at the written-out destination). `%%s` only becomes `%s` at the written-out destination.
# **The exception is declared on the writing side too** -- since what this fixture measures is the quoting form, not instructions,
# falling within the lineage-cmd gate's scope (a form with an option in between) still isn't counted as a violation. A conformant fixture
# passes every gate, so without the declaration, "a fixture that should pass fails" would turn the check itself red.
# shellcheck disable=SC2016  # the literal text of the fixture being written out (expanding it here would break the fixture)
st_write_shell_quote_ok() {
  local name='rein' opt='--cwd' verb='up' mark='lineage-cmd-exempt'
  mkdir -p "${1%/*}"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'guide() {\n'
    printf '  printf %sstart the watcher first: %s %s %%s %s\\n%s "$(rein_shell_quote "$1")" # %s: fixture that measures the quoting form (not instructions)\n' \
      "'" "$name" "$opt" "$verb" "'" "$mark"
    printf '}\n'
  } >"$1"
}

# shellcheck disable=SC2016  # same as above (fixture content, not an expression in this function)
st_write_shell_quote_bad_printf() {
  local name='rein' opt='--cwd' verb='up' mark='lineage-cmd-exempt'
  mkdir -p "${1%/*}"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'guide() {\n'
    printf '  printf %sstart the watcher first: %s %s %%s %s\\n%s "$1" # %s: fixture that measures the quoting form (not instructions)\n' \
      "'" "$name" "$opt" "$verb" "'" "$mark"
    printf '}\n'
  } >"$1"
}

# shellcheck disable=SC2016  # same as above. The verb and the fill-in spot are kept as separate words so this function's own literal text
# never trips the shell-quote gate itself (the violation form only lines up at the written-out destination).
st_write_shell_quote_bad_interp() {
  local verb='rmdir' ref='${dir}'
  mkdir -p "${1%/*}"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'fail() { printf %s%%s\\n%s "$1" >&2; }\n' "'" "'"
    printf 'guide() {\n'
    printf '  local dir="$1"\n'
    printf '  fail "confirm no other rein is around, then %s %s"\n' "$verb" "$ref"
    printf '}\n'
  } >"$1"
}

# The form that fails when an already-quoted variable's allowlist takes effect **across the whole file**. In the same file where a production
# function writes `quoted="$(rein_shell_quote ...)"`, a different function embedding **an unquoted variable of the same name** into
# a path position would still pass (fail-open). If the scope is closed inside the function, it fails as it should.
# shellcheck disable=SC2016  # the literal text of the fixture being written out
st_write_shell_quote_bad_scope() {
  local verb='rmdir' ref='${quoted}'
  mkdir -p "${1%/*}"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'fail() { printf %s%%s\\n%s "$1" >&2; }\n' "'" "'"
    printf 'guide_ok() {\n'
    printf '  local quoted\n'
    printf '  quoted="$(rein_shell_quote "$1")"\n'
    printf '  fail "this one is already quoted: %s"\n' "$ref"
    printf '}\n'
    printf 'guide_bad() {\n'
    printf '  local quoted="$1"\n'
    printf '  fail "confirm no other rein is around, then %s %s"\n' "$verb" "$ref"
    printf '}\n'
  } >"$1"
}

# The short options (`-D` / `-H`) and `--settings`'s position. Scanning only the long spelling would let
# a line embedding the same value in the same dangerous form go entirely uncounted.
# shellcheck disable=SC2016  # the literal text of the fixture being written out
st_write_shell_quote_bad_shortopt() {
  # The option's spelling, the command name, and the verb are kept as separate words so this function's own literal text never
  # trips the shell-quote / lineage-cmd gates themselves (the violation form only lines up at the written-out destination).
  local name='rein' verb='up' dopt='-D' hopt='-H' sopt='--settings' ref='${dir}'
  mkdir -p "${1%/*}"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'fail() { printf %s%%s\\n%s "$1" >&2; }\n' "'" "'"
    printf 'guide() {\n'
    printf '  local dir="$1"\n'
    printf '  fail "retype it: %s %s %s"\n' "$name" "$dopt" "$ref"
    printf '  fail "hand over the canonical source: %s %s %s %s"\n' "$name" "$verb" "$hopt" "$ref"
    printf '  fail "pass the settings: %s %s %s %s"\n' "$name" "$verb" "$sopt" "$ref"
    printf '}\n'
  } >"$1"
}

# The form where the scan itself crashes (an unreadable file). Not checking awk's exit code would let
# the empty output pass with the same face as "zero violations" -- the check spinning on nothing hides behind green.
st_write_unreadable_sh() {
  mkdir -p "${1%/*}"
  printf '#!/usr/bin/env bash\n:\n' >"$1"
  chmod 000 "$1"
}

# Fixture for the lineage-cmd gate. **Never places the violation's literal text in check.sh's own source** (placing it there would make
# this gate fail the moment it scans its own source) -- keeps the command name and the verb as separate words.
# shellcheck disable=SC2016  # the literal text of the fixture being written out
st_write_lineage_cmd_ok() {
  local name='rein'
  mkdir -p "${1%/*}"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'guide() {\n'
    printf '  rein_lineage_cmd %s "$1" "$2" "$3" init\n' "$name"
    printf '  printf %sto install, run: %%s\\n%s "$REIN_LINEAGE_CMD"\n' "'" "'"
    printf '}\n'
  } >"$1"
}

# A form that embeds a bare `rein <verb>` into instructions (misleading instructions where the lineage at the typed location becomes the target).
st_write_lineage_cmd_bare() {
  local name='rein' verb='init'
  mkdir -p "${1%/*}"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'guide() {\n'
    printf '  printf %sto install, run: %s %s\\n%s\n' "'" "$name" "$verb" "'"
    printf '}\n'
  } >"$1"
}

# The widened-scope side -- **a bare form with an option in between** (`rein <common option> config allow`).
# A scope that only looks at the verb following directly would drop instructions with even one common option written in entirely --
# `config`'s 3 sets of instructions actually fell right through that hole. The words in between (the option and its value) and the verb are
# kept separate here too (the sequence only lines up at the written-out destination).
# shellcheck disable=SC2016  # the literal text of the fixture being written out
st_write_lineage_cmd_opts_bare() {
  local name='rein' opt='--cwd' verb='config' verb_arg='allow'
  mkdir -p "${1%/*}"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'guide() {\n'
    printf '  printf %sto allow it, run: %s %s %%s %s %s\\n%s "$1"\n' \
      "'" "$name" "$opt" "$verb" "$verb_arg" "'"
    printf '}\n'
  } >"$1"
}

# An exception declared with a reason passes (if the declaration itself didn't work, it would rewrite literal text that isn't even
# instructions -- measures both sides of whether the declaration mechanism actually closes).
st_write_lineage_cmd_exempt() {
  local name='rein' verb='down' mark='lineage-cmd-exempt'
  mkdir -p "${1%/*}"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'guide() {\n'
    printf '  printf %s%s %s shut the lineage down\\n%s # %s: a description of the event\n' "'" "$name" "$verb" "'" "$mark"
    printf '}\n'
  } >"$1"
}

# Fixture for the self-path gate. **Never places the violation sequence in check.sh's own source** (placing it there would make this
# gate fail the moment it scans its own source) -- keeps the movement verb and the external command name as separate words,
# so the sequence only lines up at the written-out destination.
# The accepting side -- a form that cuts the location out with string operations alone (placed in the conformant fixture, passes every gate).
# shellcheck disable=SC2016  # the literal text of the fixture being written out (expanding it here would break the fixture)
st_write_self_path_ok() {
  local src='${BASH_SOURCE[0]}'
  mkdir -p "${1%/*}"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'self_dir() {\n'
    printf '  local path="%s"\n' "$src"
    printf '  case "$path" in\n'
    printf '    /*) ;;\n'
    printf '    *) path="$PWD/$path" ;;\n'
    printf '  esac\n'
    printf '  printf %s%%s\\n%s "${path%%/*}"\n' "'" "'"
    printf '}\n'
  } >"$1"
}

# The rejecting side -- a form that decides the destination via command substitution (grabs the current directory on a machine where `dirname` returns empty).
# shellcheck disable=SC2016  # same as above (fixture content, not an expression in this function)
st_write_self_path_bad() {
  local verb='cd' tool='dirname' src='${BASH_SOURCE[0]}'
  mkdir -p "${1%/*}"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'self_dir() {\n'
    printf '  printf %s%%s\\n%s "$(%s "$(%s "%s")" && pwd)"\n' "'" "'" "$verb" "$tool" "$src"
    printf '}\n'
  } >"$1"
}

# An exception declared with a reason passes (if the declaration itself didn't work, it would rewrite even a spot where deciding the
# destination externally causes no harm -- measures both sides of whether the declaration mechanism actually closes).
# shellcheck disable=SC2016  # same as above
st_write_self_path_exempt() {
  local verb='cd' tool='dirname' mark='self-path-exempt'
  mkdir -p "${1%/*}"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'probe() {\n'
    printf '  printf %s%%s\\n%s "$(%s "$(%s "$1")" && pwd)" # %s: fixture that measures the attack form (not location resolution)\n' \
      "'" "'" "$verb" "$tool" "$mark"
    printf '}\n'
  } >"$1"
}

# Fixture for the self-lib gate. **Never places the violation sequence in check.sh's own source** (placing it there would
# make that gate fail the moment it scans its own source), so the matching literal text is assembled from variables.

# self-lib's rejecting side -- a form that builds its own location from an external command's output.
# shellcheck disable=SC2016  # fixture content, not an expression meant to expand in this function
st_write_self_lib_bad() {
  local tool='dirname' src='${BASH_SOURCE[0]}'
  mkdir -p "${1%/*}"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'lib_dir() {\n'
    printf '  printf %s%%s\\n%s "$(%s "%s")"\n' "'" "'" "$tool" "$src"
    printf '}\n'
  } >"$1"
}

# The accepting side (b) -- a form that prefixes the current directory to a relative path ((a)'s rejecting form is handled by st_write_self_path_ok).
# shellcheck disable=SC2016  # same as above
st_write_self_lib_ok() {
  local src='${BASH_SOURCE[0]}'
  mkdir -p "${1%/*}"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'lib_dir() {\n'
    printf '  local path="%s"\n' "$src"
    printf '  case "$path" in\n'
    printf '    /*) ;;\n'
    printf '    *) path="$PWD/$path" ;;\n'
    printf '  esac\n'
    printf '  printf %s%%s\\n%s "${path%%/*}"\n' "'" "'"
    printf '}\n'
  } >"$1"
}

# shellcheck disable=SC2016  # same as above
st_write_self_lib_exempt() {
  local tool='dirname' src='${BASH_SOURCE[0]}' mark='self-lib-exempt'
  mkdir -p "${1%/*}"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'probe() {\n'
    printf '  printf %s%%s\\n%s "$(%s "%s")" # %s: fixture that measures the attack form (not location resolution)\n' \
      "'" "'" "$tool" "$src" "$mark"
    printf '}\n'
  } >"$1"
}

# Fixture for launcher-exec. The gate narrows its target by the spelling's tail (hooks/rein-hook-launcher.sh), so
# the fixture places it under lib/ (makes the same name without dragging in the execute-permission and --selftest convention).
# shellcheck disable=SC2016  # fixture content, not an expression meant to expand in this function
st_write_launcher_exec_bad() {
  local verb='exec'
  mkdir -p "${1%/*}"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'launcher_main() {\n'
    printf '  %s "$1"\n' "$verb"
    printf '}\n'
  } >"$1"
}

# shellcheck disable=SC2016  # fixture content, not an expression meant to expand in this function
st_write_launcher_exec_exempt() {
  local verb='exec' mark='launcher-exec-exempt'
  mkdir -p "${1%/*}"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'launcher_main() {\n'
    printf '  %s "$1" # %s: fixture that measures the replacement form\n' "$verb" "$mark"
    printf '}\n'
  } >"$1"
}

# Fixture for run-limit (a form that starts an external process without going through the capped runner).
# shellcheck disable=SC2016  # fixture content, not an expression meant to expand in this function
st_write_run_limit_bad() {
  local cmd='claude'
  mkdir -p "${1%/*}"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'probe() {\n'
    printf '  (cd /tmp && %s stop "$1")\n' "$cmd"
    printf '}\n'
  } >"$1"
}

# A form with a keyword prefixed (`if claude ...` / `! claude ...`) is also a launch outside the cap, so it fails the same way.
# Measuring only the bare form would leave a line placed in a conditional position falling outside the scan and staying green.
# shellcheck disable=SC2016  # fixture content, not an expression meant to expand in this function
st_write_run_limit_keyword() {
  local cmd='claude'
  mkdir -p "${1%/*}"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'probe() {\n'
    printf '  if %s stop "$1"; then\n' "$cmd"
    printf '    return 0\n'
    printf '  fi\n'
    printf '  if ! %s resume "$1"; then\n' "$cmd"
    printf '    return 1\n'
    printf '  fi\n'
    printf '}\n'
  } >"$1"
}

# shellcheck disable=SC2016  # fixture content, not an expression meant to expand in this function
st_write_run_limit_exempt() {
  local cmd='claude' mark='run-limit-exempt'
  mkdir -p "${1%/*}"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'probe() {\n'
    printf '  (cd /tmp && %s stop "$1") # %s: fixture that measures the uncapped form\n' "$cmd" "$mark"
    printf '}\n'
  } >"$1"
}

# Fixture for home-base (a form that builds a location's base by spelling it out with a default value).
# shellcheck disable=SC2016  # fixture content, not an expression meant to expand in this function
st_write_home_base_bad() {
  local expansion='${HOME:-}'
  mkdir -p "${1%/*}"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'probe() {\n'
    printf '  printf %s%%s\\n%s "%s/.config"\n' "'" "'" "$expansion"
    printf '}\n'
  } >"$1"
}

# shellcheck disable=SC2016  # fixture content, not an expression meant to expand in this function
st_write_home_base_exempt() {
  local expansion='${HOME:-}' mark='home-base-exempt'
  mkdir -p "${1%/*}"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'probe() {\n'
    printf '  printf %s%%s\\n%s "%s/.config" # %s: fixture that measures the collapsing form\n' \
      "'" "'" "$expansion" "$mark"
    printf '}\n'
  } >"$1"
}

# Fixture for record-append (an append that never checks the write target's shape).
# Both the function's header and its body are assembled with printf -- placing the fixture's literal text at column 0 in a heredoc would make it
# appear as **the violation's own literal text** when check.sh scans itself (this gate never uses a heredoc's contents as
# a function boundary, but it still scans the lines themselves).
# shellcheck disable=SC2016  # fixture content, not an expression meant to expand in this function
st_write_record_append_bad() {
  local fn='log_line'
  mkdir -p "${1%/*}"
  {
    printf '#!/usr/bin/env bash\n'
    printf '%s() {\n' "$fn"
    printf '  printf %s%%s\\n%s "$1" >>"$2"\n' "'" "'"
    printf '}\n'
  } >"$1"
}

# The accepting side is assembled with printf too (same reason as the rejecting side -- the fixture's literal text would appear in check.sh's own scan).
# shellcheck disable=SC2016  # fixture content, not an expression meant to expand in this function
st_write_record_append_ok() {
  local fn='log_line' guard='rein_dest_shape_ok'
  mkdir -p "${1%/*}"
  {
    printf '#!/usr/bin/env bash\n'
    printf '%s() {\n' "$fn"
    printf '  %s "$2" || return 1\n' "$guard"
    printf '  printf %s%%s\\n%s "$1" >>"$2"\n' "'" "'"
    printf '}\n'
  } >"$1"
}

# shellcheck disable=SC2016  # fixture content, not an expression meant to expand in this function
st_write_record_append_exempt() {
  local mark='record-append-exempt'
  mkdir -p "${1%/*}"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'log_line() {\n'
    printf '  printf %s%%s\\n%s "$1" >>"$2" # %s: the destination is a temp file this run created\n' \
      "'" "'" "$mark"
    printf '}\n'
  } >"$1"
}

# Fixture for record-append's **scope** (that it never falls out of scope at a name or a function boundary). Places 2 violations:
#   1. An append inside a function that names itself with a writer verb (`write_*`) -- if the verb were in the test-side name list,
#      it would fall out on the name alone. The 3 live functions actually fell out this exact way.
#   2. A top-level append that follows **after** a test-side-named function -- without resetting the judgment at the function boundary,
#      the exclusion would carry all the way to the end of the file.
# An append inside a test-side-named function (`st_helper`) is on the excluded side -- the same fixture confirms
# the exclusion itself is actually working (if everything were a violation, a mutation that drops the exclusion entirely would be invisible). Inside it,
# a **different script's literal text written out via a heredoc** is placed too -- reading the `name() {` / `}` lined up inside it as a function boundary
# would swap the enclosing function's name, turning the append inside into a violation (measured -- this actually happened).
# shellcheck disable=SC2016  # fixture content, not an expression meant to expand in this function
st_write_record_append_scope() {
  local prod='write_ledger' testside='st_helper'
  mkdir -p "${1%/*}"
  {
    printf '#!/usr/bin/env bash\n'
    printf '%s() {\n' "$prod"
    printf '  printf %s%%s\\n%s "$1" >>"$2"\n' "'" "'"
    printf '}\n'
    printf '\n'
    printf '%s() {\n' "$testside"
    printf '  printf %s%%s\\n%s "$1" >>"$2"\n' "'" "'"
    printf '  cat <<%sEOF%s >/dev/null\n' "'" "'"
    printf 'inner() {\n'
    printf '  printf %s%%s\\n%s "x" >>"$1"\n' "'" "'"
    printf '}\n'
    printf 'EOF\n'
    printf '}\n'
    printf '\n'
    printf 'printf %s%%s\\n%s "top" >>"$1"\n' "'" "'"
  } >"$1"
}

# Fixture for test-side-scope (a form that calls a test-side name from a production position). Places 3 calls:
#   1. Inside a production-named function -- a violation.
#   2. Inside a test-side-named function -- excluded (the same fixture confirms the exclusion itself is working.
#      If everything were a violation, a mutation that drops the exclusion entirely would be invisible).
#   3. Top level, **after** a test-side-named function -- a violation (that the judgment resets at the function boundary).
# The call's literal text is assembled with printf too (placing a test-side name at column 0 in a heredoc would make it
# appear as the violation's own literal text when check.sh scans itself).
# shellcheck disable=SC2016  # fixture content, not an expression meant to expand in this function
st_write_test_side_scope_bad() {
  local prod='prod_writer' testside='st_caller' callee='st_helper'
  mkdir -p "${1%/*}"
  {
    printf '#!/usr/bin/env bash\n'
    printf '%s() {\n' "$prod"
    printf '  %s "$1"\n' "$callee"
    printf '}\n'
    printf '\n'
    printf '%s() {\n' "$testside"
    printf '  %s "$1"\n' "$callee"
    printf '}\n'
    printf '\n'
    printf '%s "top"\n' "$callee"
  } >"$1"
}

# shellcheck disable=SC2016  # fixture content, not an expression meant to expand in this function
st_write_test_side_scope_exempt() {
  local prod='prod_writer' callee='st_helper' mark='test-side-scope-exempt'
  mkdir -p "${1%/*}"
  {
    printf '#!/usr/bin/env bash\n'
    printf '%s() {\n' "$prod"
    printf '  %s "$1" # %s: the one line that launches the test-side entry point\n' "$callee" "$mark"
    printf '}\n'
  } >"$1"
}

# The accepting side (the test side calling itself is out of scope).
# shellcheck disable=SC2016  # fixture content, not an expression meant to expand in this function
st_write_test_side_scope_ok() {
  local testside='st_caller' callee='st_helper'
  mkdir -p "${1%/*}"
  {
    printf '#!/usr/bin/env bash\n'
    printf '%s() {\n' "$testside"
    printf '  %s "$1"\n' "$callee"
    printf '}\n'
  } >"$1"
}

# Fixture for flag-value (parsing that fails a form missing a value, with no reason).
# The branch's header is assembled with printf too (placing an option branch at column 0 in a heredoc would make this gate
# read it as inside that branch when it scans check.sh itself, counting `shift 2` as a violation -- measured, it actually went red).
# shellcheck disable=SC2016  # fixture content, not an expression meant to expand in this function
st_write_flag_value_bad() {
  local fn='parse' opt='--name'
  mkdir -p "${1%/*}"
  {
    printf '#!/usr/bin/env bash\n'
    printf '%s() {\n' "$fn"
    printf '  while [ $# -gt 0 ]; do\n'
    printf '    case "$1" in\n'
    printf '      %s)\n' "$opt"
    printf '        printf %s%%s\\n%s "$2"\n' "'" "'"
    printf '        shift 2\n'
    printf '        ;;\n'
    printf '      *)\n'
    printf '        return 1\n'
    printf '        ;;\n'
    printf '    esac\n'
    printf '  done\n'
    printf '}\n'
  } >"$1"
}

# shellcheck disable=SC2016  # fixture content, not an expression meant to expand in this function
st_write_flag_value_ok() {
  local fn='parse_ok' opt='--name' guard='need_value'
  mkdir -p "${1%/*}"
  {
    printf '#!/usr/bin/env bash\n'
    printf '%s() {\n' "$fn"
    printf '  while [ $# -gt 0 ]; do\n'
    printf '    case "$1" in\n'
    printf '      %s)\n' "$opt"
    printf '        %s "%s" $# "${2:-}" || return 2\n' "$guard" "$opt"
    printf '        printf %s%%s\\n%s "$2"\n' "'" "'"
    printf '        shift 2\n'
    printf '        ;;\n'
    printf '      *)\n'
    printf '        return 1\n'
    printf '        ;;\n'
    printf '    esac\n'
    printf '  done\n'
    printf '}\n'
  } >"$1"
}

# shellcheck disable=SC2016  # fixture content, not an expression meant to expand in this function
st_write_flag_value_exempt() {
  local mark='flag-value-exempt'
  mkdir -p "${1%/*}"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'parse() {\n'
    printf '  while [ $# -gt 0 ]; do\n'
    printf '    case "$1" in\n'
    printf '      --name)\n'
    printf '        printf %s%%s\\n%s "$2"\n' "'" "'"
    printf '        shift 2 # %s: fixture that measures the no-reason form\n' "$mark"
    printf '        ;;\n'
    printf '      *)\n'
    printf '        return 1\n'
    printf '        ;;\n'
    printf '    esac\n'
    printf '  done\n'
    printf '}\n'
  } >"$1"
}

# Fixture for stop-order (a form where the stop-block output comes after the fire log record).
# shellcheck disable=SC2016  # fixture content, not an expression meant to expand in this function
st_write_stop_order_bad() {
  local writer='hook_fire_log'
  mkdir -p "${1%/*}"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'emit() {\n'
    printf '  block="$1"\n'
    printf '  %s Stop block "x"\n' "$writer"
    printf '  printf %s%%s\\n%s "$block"\n' "'" "'"
    printf '}\n'
  } >"$1"
}

# shellcheck disable=SC2016  # fixture content, not an expression meant to expand in this function
st_write_stop_order_ok() {
  local writer='hook_fire_log'
  mkdir -p "${1%/*}"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'emit_ok() {\n'
    printf '  block="$1"\n'
    printf '  printf %s%%s\\n%s "$block"\n' "'" "'"
    printf '  %s Stop block "x"\n' "$writer"
    printf '}\n'
  } >"$1"
}

# shellcheck disable=SC2016  # fixture content, not an expression meant to expand in this function
st_write_stop_order_exempt() {
  local writer='hook_fire_log' mark='stop-order-exempt'
  mkdir -p "${1%/*}"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'emit() {\n'
    printf '  block="$1"\n'
    printf '  %s Stop block "x" # %s: fixture that measures the order\n' "$writer" "$mark"
    printf '  printf %s%%s\\n%s "$block"\n' "'" "'"
    printf '}\n'
  } >"$1"
}

# Fixture for section-table (a directory carrying a section table, plus a listed section, plus an unlisted section).
# `$1` is `<root>/lib/<layer>/selftest`. If `$2` isn't empty, a reasoned declaration is placed on the unlisted section.
st_write_section_table_dir() {
  local dir="$1" mark="${2:-}" table='rein_st_section_table'
  mkdir -p "$dir"
  {
    printf '# shellcheck shell=bash\n'
    printf '%s() {\n' "$table"
    printf '  cat <<%sEOF%s\n' "'" "'"
    printf 'pure:known st_section_known\n'
    printf 'EOF\n'
    printf '}\n'
  } >"$dir/selftest.sh"
  {
    printf '# shellcheck shell=bash\n'
    printf 'st_section_known() {\n'
    printf '  :\n'
    printf '}\n'
  } >"$dir/known.sh"
  {
    printf '# shellcheck shell=bash\n'
    [ -z "$mark" ] || printf '# %s: a tool sections share, not a section itself\n' "$mark"
    printf 'st_section_orphan() {\n'
    printf '  :\n'
    printf '}\n'
  } >"$dir/orphan.sh"
}

# Fixture for gate-table (a file carrying a gate table, plus a gate that's in the table, plus one that isn't).
# `$2` is the name the listed function claims for itself (setting it apart from the table's first column is what measures how far the name has drifted).
# If `$3` isn't empty, a reasoned declaration is placed on the not-in-table side.
# Both the header and the body are assembled with printf -- placing `rein_gate_table() {` or `local gate="..."` at
# column 0 in a heredoc would make this gate read it as a real implementation, not a fixture, when it scans check.sh itself.
# shellcheck disable=SC2016  # fixture content, not an expression meant to expand in this function
st_write_gate_table_file() {
  local path="$1" declared="$2" mark="${3:-}" table='rein_gate_table' decl='local gate'
  mkdir -p "${path%/*}"
  {
    printf '# shellcheck shell=bash\n'
    printf '%s() {\n' "$table"
    printf '  cat <<%sEOF%s\n' "'" "'"
    printf 'known gate_known\n'
    printf 'EOF\n'
    printf '}\n'
    printf '\n'
    printf 'gate_known() {\n'
    printf '  %s="%s"\n' "$decl" "$declared"
    printf '  printf %s%%s\\n%s "$gate"\n' "'" "'"
    printf '}\n'
    printf '\n'
    printf 'gate_orphan() {\n'
    if [ -z "$mark" ]; then
      printf '  %s="orphan"\n' "$decl"
    else
      printf '  %s="orphan" # %s: a tool gates share, not a gate itself\n' "$decl" "$mark"
    fi
    printf '  printf %s%%s\\n%s "$gate"\n' "'" "'"
    printf '}\n'
  } >"$path"
}

# dist-author's 2 JSON surfaces (`author.name` / `owner.name`). **The caller decides which surface
# to offset** -- a fixture that always fixes the surface would let a mutation that drops the comparison on the untouched surface pass green.
st_write_dist_author_json() {
  local root="$1" author="$2" owner="$3"
  mkdir -p "$root/.claude-plugin"
  printf '{\n  "name": "rein",\n  "author": {\n    "name": "%s"\n  }\n}\n' "$author" \
    >"$root/.claude-plugin/plugin.json"
  printf '{\n  "name": "m",\n  "owner": {\n    "name": "%s"\n  }\n}\n' "$owner" \
    >"$root/.claude-plugin/marketplace.json"
}

# dist-author's copyright-notice surface (LICENSE).
st_write_dist_author_copyright() {
  local root="$1" license="$2"
  printf 'MIT License\n\nCopyright (c) 2026 %s\n' "$license" >"$root/LICENSE"
}

# Fixture for a skill (inserts the 3rd argument as-is as the frontmatter's contents).
st_write_skill_md() {
  mkdir -p "$1/skills/$2"
  cat >"$1/skills/$2/SKILL.md" <<EOF
---
$3
---

Body text
EOF
}

st_configure_fixture_gates() {
  ROOT="$1"
  # Re-decides the material judgment whenever the scan root is swapped (never carries over the set decided for the previous scan root).
  SCAN_SOURCE=""
  SHELLCHECK_BIN="$ST_SHELLCHECK"
  JQ_BIN="$ST_JQ"
  BASH32_BIN="$ST_BASH32"
  SELFTEST_DEADLINE_SEC="$2"
  gate_pass_count=0
  gate_fail_count=0
  gate_skip_count=0
  export CHECK_ST_HANG_STATE="${ST_HANG_STATE:-}"
  export CHECK_ST_HANG_CHILD_PID_FILE="${ST_HANG_CHILD_PID_FILE:-}"
  export CHECK_ST_STREAM_RELEASE="${ST_STREAM_RELEASE:-}"
  export CHECK_ST_STREAM_MAX_POLLS="$SELFTEST_STREAM_FIXTURE_POLLS"
}

st_run_fixture_gates() {
  st_configure_fixture_gates "$1" "$2"
  run_gates
}

# Checks both the expected exit status and the expected FAIL gate
# (ending non-zero alone can't tell whether the targeted gate failed or a different gate dragged it down).
st_case() {
  local name="$1" expected_status="$2" root="$3" expect_gate="${4:-}"
  local status
  ST_OUT="$(st_run_fixture_gates "$root" \
    "${ST_SELFTEST_DEADLINE:-$SELFTEST_DEADLINE_SEC}" 2>&1 </dev/null)"
  status=$?

  if [ "$status" -eq 0 ] && [ "$expected_status" -ne 0 ]; then
    st_fail "${name}" "a fixture that should fail passed with exit 0: ${ST_OUT}"
    return 1
  fi
  if [ "$status" -ne 0 ] && [ "$expected_status" -eq 0 ]; then
    st_fail "${name}" "a fixture that should pass failed with exit ${status}: ${ST_OUT}"
    return 1
  fi

  if [ -n "$expect_gate" ]; then
    if ! printf '%s\n' "$ST_OUT" | grep -q "^  FAIL ${expect_gate}"; then
      st_fail "${name}" "no FAIL line for gate ${expect_gate}: ${ST_OUT}"
      return 1
    fi
  elif printf '%s\n' "$ST_OUT" | grep -q '^  FAIL '; then
    st_fail "${name}" "FAIL appeared on a fixture that should show no FAIL line: ${ST_OUT}"
    return 1
  fi

  st_ok
  return 0
}

# Checks whether a given line prefix appears / doesn't appear in the output (pins how PASS and SKIP are told apart).
# Matches a gate line's literal text (`  PASS <gate> (N files)` / `  SKIP ...`) from the start of the line. This is the one place
# where **the display format itself is the contract**, so it's pinned by literal text -- this repo's convention
# ("a gate with zero targets shows SKIP (0 files), not PASS" in the dev conventions) is written as literal text, and
# its readers are people -- the user tracking results by eye. Replacing it with a property would leave that convention guarding nothing.
st_expect_line() {
  local name="$1" prefix="$2"
  if printf '%s\n' "$ST_OUT" | grep -q "^${prefix}"; then
    st_ok
  else
    st_fail "${name}" "no line starting with ${prefix}: ${ST_OUT}"
  fi
}

st_expect_no_line() {
  local name="$1" prefix="$2"
  if printf '%s\n' "$ST_OUT" | grep -q "^${prefix}"; then
    st_fail "${name}" "a line starting with ${prefix} should not appear: ${ST_OUT}"
  else
    st_ok
  fi
}

# Starts the entry point with all its wiring (from argument parsing through to showing results). Calling the function directly would skip main's argument branching,
# and would let a check pass even where the wiring isn't actually connected, so it's launched as an executable file.
# Points the scan root at a fixture (never touches the real repo's files).
# Puts the output into ST_OUT, so the check can use st_expect_line / st_expect_no_line as-is.
st_run_entry() {
  local root="$1"
  shift
  ST_OUT="$(REIN_CHECK_ROOT="$root" "$BASH" "$SCRIPT_DIR/$SCRIPT_NAME" "$@" 2>&1 </dev/null)"
  ST_STATUS=$?
}

st_expect_status() {
  local name="$1" expected="$2"
  if [ "$ST_STATUS" -eq "$expected" ]; then
    st_ok
  else
    st_fail "${name}" "exit code is not ${expected}: ${ST_STATUS} (${ST_OUT})"
  fi
}

st_output_line_number() {
  local exact="$1"
  awk -v exact="$exact" '$0 == exact { print NR; exit }' <<EOF
$ST_OUT
EOF
}

st_streaming_visibility_case() {
  local output_file="$tmp/stream-observed.out" release_file="$tmp/stream-release"
  local runner_pid polls=0 observed=0 status
  rm -f "$output_file" "$release_file"
  (
    ST_STREAM_RELEASE="$release_file"
    st_run_fixture_gates "$tmp/stream-selftest" 5
  ) >"$output_file" 2>&1 </dev/null &
  runner_pid=$!
  while [ "$polls" -lt 100 ]; do
    if grep -q '^stream-visible-stdout$' "$output_file" 2>/dev/null &&
      grep -q '^stream-visible-stderr$' "$output_file" 2>/dev/null; then
      observed=1
      break
    fi
    sleep 0.01
    polls=$((polls + 1))
  done
  if [ "$observed" -eq 1 ]; then
    st_ok
  else
    st_fail "streams stdout/stderr before selftest finishes" "$(cat "$output_file" 2>/dev/null)"
  fi
  : >"$release_file"
  wait "$runner_pid"
  status=$?
  if [ "$status" -eq 0 ]; then
    st_ok
  else
    st_fail "the streaming fixture exits cleanly after the cooperative release" \
      "exit=${status}: $(cat "$output_file" 2>/dev/null)"
  fi
}

st_control_dir_cleanup_failure_case() {
  local evidence="$tmp/control-cleanup-evidence" output status
  mkdir -p "$evidence"
  : >"$evidence/kept"
  output="$(
    rm() { return 1; }
    selftest_remove_control_dir fixture.sh "$evidence"
  )"
  status=$?
  if [ "$status" -ne 0 ] && [ -f "$evidence/kept" ]; then
    st_ok
  else
    st_fail "a control directory cleanup failure returns non-zero and leaves evidence" \
      "exit=${status}: ${output}"
  fi
  case "$output" in
    *"could not remove"*"evidence: ${evidence}"*) st_ok ;;
    *) st_fail "a control directory cleanup failure shows a reason and evidence" "$output" ;;
  esac
}

st_deadline_limit_case() {
  local output status saved_perl="$PERL_BIN" saved_deadline="$SELFTEST_DEADLINE_SEC"
  # Checks that it fails before even launching the supervisor (if it had launched, the missing perl would cause a different failure).
  PERL_BIN="$tmp/absent-perl"
  SELFTEST_DEADLINE_SEC=999999999999999999999999999999
  output="$(run_one_selftest "$tmp/pass/stub.sh" "" 2>&1)"
  status=$?
  PERL_BIN="$saved_perl"
  SELFTEST_DEADLINE_SEC="$saved_deadline"
  if [ "$status" -eq 0 ]; then
    st_fail "rejects a huge selftest deadline before launching the supervisor" "$output"
    return
  fi
  case "$output" in
    *"deadline is invalid"*"max ${SELFTEST_MAX_DEADLINE_SEC}s"*) st_ok ;;
    *) st_fail "shows a deadline-cap violation with a reason" "$output" ;;
  esac
}

st_pid_gone_within_bound() {
  local pid="$1" polls=0
  while [ "$polls" -lt 100 ] && kill -0 "$pid" 2>/dev/null; do
    sleep 0.01
    polls=$((polls + 1))
  done
  ! kill -0 "$pid" 2>/dev/null
}

st_cleanup() {
  [ -n "${ST_TMPDIR:-}" ] && rm -rf "$ST_TMPDIR"
}

selftest() {
  local tmp inner_seen
  # shellcheck source-path=SCRIPTDIR
  # shellcheck source=lib/rein-selftest-sections.sh
  . "$SCRIPT_DIR/lib/rein-selftest-sections.sh"
  rein_st_sections_parse "$@" || return $?
  if [ "$REIN_ST_SECTION_MODE" = "list" ]; then
    rein_st_sections_print_list
    return 0
  fi
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/rein-check-selftest.XXXXXX")" || {
    printf '%s: selftest 0 pass / 1 fail\n' "$SCRIPT_NAME"
    return 1
  }
  # Never leaves the temp directory behind even on an early exit. A function-local variable is already gone by EXIT, so this is stashed in a global.
  ST_TMPDIR="$tmp"
  trap st_cleanup EXIT

  ST_SHELLCHECK="$SHELLCHECK_BIN"
  ST_JQ="$JQ_BIN"
  ST_BASH32="$BASH32_BIN"

  mkdir -p "$tmp/pass/lib" "$tmp/bad-sh/lib" "$tmp/bad-json" "$tmp/bad-selftest" \
    "$tmp/no-selftest" "$tmp/no-exec" "$tmp/lib-only" "$tmp/no-json" \
    "$tmp/lib-sub-only/lib/cli" "$tmp/libs-not-lib/libs" "$tmp/libs-sub-not-lib/libs/cli" \
    "$tmp/prefixed-lib-not-lib/mylib" \
    "$tmp/noop-selftest" "$tmp/zero-selftest" "$tmp/foreign-selftest" \
    "$tmp/hang-selftest" "$tmp/stream-selftest" "$tmp/safe-deadline" \
    "$tmp/empty-repo" \
    "$tmp/noext-ok/bin" "$tmp/noext-no-selftest/bin" "$tmp/noext-no-exec/bin" \
    "$tmp/noext-bad-sh/lib" "$tmp/noext-foreign/bin" \
    "$tmp/noext-env-s/bin" "$tmp/noext-env-bad/bin" \
    "$tmp/shell-quote-bad-printf/lib" "$tmp/shell-quote-bad-interp/lib" \
    "$tmp/shell-quote-bad-scope/lib" "$tmp/shell-quote-bad-shortopt/lib" \
    "$tmp/scan-unreadable/lib" \
    "$tmp/lineage-cmd-bare/lib" "$tmp/lineage-cmd-opts-bare/lib" \
    "$tmp/lineage-cmd-exempt/lib" \
    "$tmp/self-path-bad/lib" "$tmp/self-path-exempt/lib" \
    "$tmp/self-lib-bad/lib" "$tmp/self-lib-exempt/lib" \
    "$tmp/launcher-exec-bad/lib/hooks" "$tmp/launcher-exec-exempt/lib/hooks" \
    "$tmp/run-limit-bad/lib" "$tmp/run-limit-keyword/lib" "$tmp/run-limit-exempt/lib" \
    "$tmp/home-base-bad/lib" "$tmp/home-base-exempt/lib" \
    "$tmp/record-append-bad/lib" "$tmp/record-append-scope/lib" \
    "$tmp/record-append-exempt/lib" \
    "$tmp/test-side-scope-bad/lib" "$tmp/test-side-scope-exempt/lib" \
    "$tmp/flag-value-bad/lib" "$tmp/flag-value-exempt/lib" \
    "$tmp/stop-order-bad/lib" "$tmp/stop-order-exempt/lib" \
    "$tmp/section-table-bad" "$tmp/section-table-exempt" \
    "$tmp/gate-table-bad/lib" "$tmp/gate-table-mismatch/lib" \
    "$tmp/gate-table-exempt/lib" \
    "$tmp/dist-author-split" "$tmp/dist-author-license"

  st_write_stub_sh "$tmp/pass/stub.sh"
  st_write_valid_json "$tmp/pass/ok.json"
  st_write_clean_sh "$tmp/pass/lib/helper.sh"

  # Placed under lib/ since only a static-analysis violation is wanted here (outside the execute-permission / --selftest convention).
  # Starting a line with "shellcheck" would get it parsed as a directive, so the word order is changed.
  cat >"$tmp/bad-sh/lib/broken.sh" <<'EOF'
#!/usr/bin/env bash
echo "unterminated
EOF
  st_write_valid_json "$tmp/bad-sh/ok.json"

  st_write_stub_sh "$tmp/bad-json/stub.sh"
  printf '{"name":\n' >"$tmp/bad-json/broken.json"

  st_write_valid_json "$tmp/bad-selftest/ok.json"
  cat >"$tmp/bad-selftest/failing.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
if [ "${1:-}" = "--selftest" ]; then
  printf 'failing-stdout\n'
  printf 'failing-stderr\n' >&2
  echo "failing.sh: selftest 0 pass / 1 fail"
  exit 7
fi
echo "failing"
EOF
  chmod +x "$tmp/bad-selftest/failing.sh"

  st_write_valid_json "$tmp/no-selftest/ok.json"
  cat >"$tmp/no-selftest/legacy.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "no selftest support"
EOF
  chmod +x "$tmp/no-selftest/legacy.sh"

  # An executable script that forgot execute permission (its contents follow the convention). Judging by anything but location would let it silently go unchecked.
  st_write_stub_sh "$tmp/no-exec/plain.sh"
  chmod -x "$tmp/no-exec/plain.sh"
  st_write_valid_json "$tmp/no-exec/ok.json"

  # A fixture that's only under lib/ (has neither execute permission nor --selftest, but isn't a convention violation).
  mkdir -p "$tmp/lib-only/lib"
  st_write_clean_sh "$tmp/lib-only/lib/helper.sh"
  st_write_valid_json "$tmp/lib-only/ok.json"

  # lib/'s **subdirectory** (lib/cli/) is on the side treated as a shared library too.
  st_write_clean_sh "$tmp/lib-sub-only/lib/cli/helper.sh"
  st_write_valid_json "$tmp/lib-sub-only/ok.json"

  # A similarly-shaped directory not literally named `lib` stays subject to the executable-script convention (the side that never widens the judgment).
  st_write_clean_sh "$tmp/libs-not-lib/libs/helper.sh"
  st_write_valid_json "$tmp/libs-not-lib/ok.json"
  st_write_clean_sh "$tmp/libs-sub-not-lib/libs/cli/helper.sh"
  st_write_valid_json "$tmp/libs-sub-not-lib/ok.json"

  # A name with characters **before** `lib` (mylib/) stays subject to the convention too. The judgment's glob (*/lib) reads
  # everything from the separator onward, so pinning only the form with characters after it (libs/) would leave
  # the check blind to a name that wrongly falls into shared-library treatment because of what comes before it.
  st_write_clean_sh "$tmp/prefixed-lib-not-lib/mylib/helper.sh"
  st_write_valid_json "$tmp/prefixed-lib-not-lib/ok.json"

  # A fixture with not a single .json (shown as SKIP, not PASS).
  st_write_stub_sh "$tmp/no-json/stub.sh"

  # A no-op that ignores its arguments and exits 0 (carries only the literal text `--selftest`). Looking only at the exit code lets it sail through.
  cat >"$tmp/noop-selftest/noop.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# accepts --selftest but checks nothing
exit 0
EOF
  chmod +x "$tmp/noop-selftest/noop.sh"

  # A summary that checked zero cases (pass 0).
  cat >"$tmp/zero-selftest/empty.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "--selftest" ]; then
  echo "empty.sh: selftest 0 pass / 0 fail"
  exit 0
fi
exit 0
EOF
  chmod +x "$tmp/zero-selftest/empty.sh"

  # A form that prints somebody else's summary line (checked nothing itself). Anything short of checking the name correspondence lets it through.
  cat >"$tmp/foreign-selftest/relay.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "--selftest" ]; then
  echo "somebody-else.sh: selftest 9 pass / 0 fail"
  exit 0
fi
exit 0
EOF
  chmod +x "$tmp/foreign-selftest/relay.sh"

  # deadline's rejecting side. The child ignores TERM and holds onto its stdout/stderr fds. The parent shell
  # cleans up its temp state on TERM, so the whole group's KILL and the state's disappearance can be observed separately.
  cat >"$tmp/hang-selftest/hang.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
if [ "${1:-}" = "--selftest" ]; then
  state_dir="${CHECK_ST_HANG_STATE:?}"
  child_pid_file="${CHECK_ST_HANG_CHILD_PID_FILE:?}"
  mkdir -p "$state_dir"
  cleanup() {
    trap - TERM EXIT
    rm -f "$state_dir/active"
    rmdir "$state_dir" 2>/dev/null || :
    exit 143
  }
  trap cleanup TERM EXIT
  sh -c '
    trap "" TERM
    : >"$2"
    printf "%s\n" "$$" >"$1"
    printf "hang-child-stderr\n" >&2
    while :; do sleep 1; done
  ' _ "$child_pid_file" "$state_dir/active" &
  child=$!
  polls=0
  while [ ! -s "$child_pid_file" ] && [ "$polls" -lt 100 ]; do
    sleep 0.01
    polls=$((polls + 1))
  done
  printf 'hang-before-deadline\n'
  wait "$child"
fi
exit 0
EOF
  chmod +x "$tmp/hang-selftest/hang.sh"

  # Waits for a cooperative release until stdout/stderr reach the observing side. Since there's also a natural-end cap, if streaming
  # is broken, the check itself still ends without needing process termination.
  cat >"$tmp/stream-selftest/stream.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
if [ "${1:-}" = "--selftest" ]; then
  release="${CHECK_ST_STREAM_RELEASE:?}"
  trap 'printf "  FAIL streaming fixture: received a signal\n"; exit 9' TERM INT HUP
  printf 'stream-visible-stdout\n'
  printf 'stream-visible-stderr\n' >&2
  polls=0
  max_polls="${CHECK_ST_STREAM_MAX_POLLS:?}"
  while [ ! -e "$release" ] && [ "$polls" -lt "$max_polls" ]; do
    sleep 0.01
    polls=$((polls + 1))
  done
  if [ ! -e "$release" ]; then
    printf '  FAIL streaming fixture: no release\n'
    printf 'stream.sh: selftest 0 pass / 1 fail\n'
    exit 1
  fi
  printf 'stream.sh: selftest 1 pass / 0 fail\n'
  exit 0
fi
exit 0
EOF
  chmod +x "$tmp/stream-selftest/stream.sh"

  cat >"$tmp/safe-deadline/safe-deadline.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
if [ "${1:-}" = "--selftest" ]; then
  printf 'hang-before-deadline\n'
  exit 142
fi
exit 0
EOF
  chmod +x "$tmp/safe-deadline/safe-deadline.sh"

  # Fixture for the plugin gate (its location is fixed, so it's split by scan root).
  # The author name matches the marketplace registration table fixture's spelling (`owner.name`) -- so this scan root also measures
  # dist-author's **side where all 3 surfaces agree**.
  st_write_plugin_manifest "$tmp/plugin-ok" '{"name":"rein","author":{"name":"someone"}}'
  st_write_plugin_hooks_ok "$tmp/plugin-ok"
  st_write_plugin_marketplace_ok "$tmp/plugin-ok"
  st_write_skill_md "$tmp/plugin-ok" "request" 'name: request
description: places a handover request'

  st_write_plugin_manifest "$tmp/plugin-bad-name" '{"name":"other"}'
  st_write_plugin_hooks_ok "$tmp/plugin-bad-name"
  st_write_plugin_marketplace "$tmp/plugin-bad-name" \
    '{"name":"claude-rein","owner":{"name":"someone"},"plugins":[{"name":"other","source":"./"}]}'
  st_write_plugin_manifest "$tmp/plugin-no-name" '{"description":"a manifest with no name"}'
  st_write_plugin_hooks_ok "$tmp/plugin-no-name"
  st_write_plugin_marketplace_ok "$tmp/plugin-no-name"

  st_write_plugin_manifest "$tmp/skill-no-description" '{"name":"rein"}'
  st_write_plugin_hooks_ok "$tmp/skill-no-description"
  st_write_plugin_marketplace_ok "$tmp/skill-no-description"
  st_write_skill_md "$tmp/skill-no-description" "request" 'name: request'

  # A form where a skill's run example calls a plugin-cache path (conflicts with the message hooks return).
  st_write_plugin_manifest "$tmp/skill-plugin-root-path" '{"name":"rein"}'
  st_write_plugin_hooks_ok "$tmp/skill-plugin-root-path"
  st_write_plugin_marketplace_ok "$tmp/skill-plugin-root-path"
  st_write_skill_md "$tmp/skill-plugin-root-path" "request" 'name: request
description: places a handover request'
  # shellcheck disable=SC2016  # the literal text that should be rejected (must not be expanded)
  printf '%s\n' '${CLAUDE_PLUGIN_ROOT}/bin/rein --cwd <path> request' \
    >>"$tmp/skill-plugin-root-path/skills/request/SKILL.md"
  # A **reference** to bundled docs isn't a run example, so it never fails (the accepting side).
  st_write_plugin_manifest "$tmp/skill-plugin-root-doc" '{"name":"rein"}'
  st_write_plugin_hooks_ok "$tmp/skill-plugin-root-doc"
  st_write_plugin_marketplace_ok "$tmp/skill-plugin-root-doc"
  st_write_skill_md "$tmp/skill-plugin-root-doc" "request" 'name: request
description: places a handover request'
  # shellcheck disable=SC2016  # the literal text that should pass (must not be expanded)
  printf '%s\n' 'the specification is at ${CLAUDE_PLUGIN_ROOT}/docs/spec/handover.md' \
    >>"$tmp/skill-plugin-root-doc/skills/request/SKILL.md"

  # Fixture for the hooks registration table (missing, the command's real target, format, event coverage, dropping the matcher).
  st_write_plugin_manifest "$tmp/hooks-missing" '{"name":"rein"}'
  st_write_plugin_marketplace_ok "$tmp/hooks-missing"
  st_write_plugin_manifest "$tmp/hooks-bad-command" '{"name":"rein"}'
  st_write_plugin_marketplace_ok "$tmp/hooks-bad-command"
  # The literal text placed on `Stop` that should fail uses the exact form an old registration table actually called (passing a verb to
  # the `rein` on PATH). **This verb has already been removed from the CLI**, so a registration left in this form
  # makes every `Stop` non-zero with "unknown subcommand" -- a real example of the side that must fail.
  # shellcheck disable=SC2016  # the literal text of the registration table
  st_write_plugin_hooks "$tmp/hooks-bad-command" \
    '{"hooks":{"PostToolBatch":[{"hooks":[{"type":"command","command":"\"${CLAUDE_PLUGIN_ROOT}/hooks/rein-hook-launcher.sh\" post-tool-batch","timeout":10}]}],"Stop":[{"hooks":[{"type":"command","command":"rein hook stop","timeout":10}]}],"SessionStart":[{"hooks":[{"type":"command","command":"\"${CLAUDE_PLUGIN_ROOT}/hooks/rein-hook-launcher.sh\" session-start","timeout":10}]}],"UserPromptSubmit":[{"hooks":[{"type":"command","command":"\"${CLAUDE_PLUGIN_ROOT}/hooks/rein-hook-launcher.sh\" user-prompt-submit","timeout":10}]}]}}'
  # An old form missing quotes (the call target and the launcher's real target both match, yet on the consumer's side it gets word-split by the shell and
  # not a single hook fires). The launcher's real target is left in place -- confines the failing reason to the quoting check alone.
  st_write_plugin_manifest "$tmp/hooks-unquoted-command" '{"name":"rein"}'
  st_write_plugin_marketplace_ok "$tmp/hooks-unquoted-command"
  st_write_plugin_hooks_ok "$tmp/hooks-unquoted-command"
  # shellcheck disable=SC2016  # the literal text of the registration table
  st_write_plugin_hooks "$tmp/hooks-unquoted-command" \
    '{"hooks":{"PostToolBatch":[{"hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/hooks/rein-hook-launcher.sh post-tool-batch","timeout":10}]}],"Stop":[{"hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/hooks/rein-hook-launcher.sh stop","timeout":10}]}],"SessionStart":[{"hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/hooks/rein-hook-launcher.sh session-start","timeout":10}]}],"UserPromptSubmit":[{"hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/hooks/rein-hook-launcher.sh user-prompt-submit","timeout":10}]}]}}'
  st_write_plugin_manifest "$tmp/hooks-no-timeout" '{"name":"rein"}'
  st_write_plugin_marketplace_ok "$tmp/hooks-no-timeout"
  st_write_plugin_hooks "$tmp/hooks-no-timeout" \
    '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"rein hook stop"}]}]}}'
  # A form missing one event (just that layer silently stops working).
  st_write_plugin_manifest "$tmp/hooks-missing-event" '{"name":"rein"}'
  st_write_plugin_marketplace_ok "$tmp/hooks-missing-event"
  # shellcheck disable=SC2016  # the literal text of the registration table
  st_write_plugin_hooks "$tmp/hooks-missing-event" \
    '{"hooks":{"PostToolBatch":[{"hooks":[{"type":"command","command":"\"${CLAUDE_PLUGIN_ROOT}/hooks/rein-hook-launcher.sh\" post-tool-batch","timeout":10}]}],"SessionStart":[{"hooks":[{"type":"command","command":"\"${CLAUDE_PLUGIN_ROOT}/hooks/rein-hook-launcher.sh\" session-start","timeout":10}]}]}}'
  # A form with a matcher added (the measured form has no matcher -- adding one has no guarantee of working).
  st_write_plugin_manifest "$tmp/hooks-narrow-matcher" '{"name":"rein"}'
  st_write_plugin_marketplace_ok "$tmp/hooks-narrow-matcher"
  st_write_plugin_hooks_ok "$tmp/hooks-narrow-matcher"
  # shellcheck disable=SC2016  # the literal text of the registration table
  st_write_plugin_hooks "$tmp/hooks-narrow-matcher" \
    '{"hooks":{"PostToolBatch":[{"matcher":"Bash","hooks":[{"type":"command","command":"\"${CLAUDE_PLUGIN_ROOT}/hooks/rein-hook-launcher.sh\" post-tool-batch","timeout":10}]}],"Stop":[{"hooks":[{"type":"command","command":"\"${CLAUDE_PLUGIN_ROOT}/hooks/rein-hook-launcher.sh\" stop","timeout":10}]}],"SessionStart":[{"hooks":[{"type":"command","command":"\"${CLAUDE_PLUGIN_ROOT}/hooks/rein-hook-launcher.sh\" session-start","timeout":10}]}],"UserPromptSubmit":[{"hooks":[{"type":"command","command":"\"${CLAUDE_PLUGIN_ROOT}/hooks/rein-hook-launcher.sh\" user-prompt-submit","timeout":10}]}]}}'
  # Fixture for the marketplace registration table (missing, a required field missing, a mismatched plugin name).
  st_write_plugin_manifest "$tmp/marketplace-missing" '{"name":"rein"}'
  st_write_plugin_hooks_ok "$tmp/marketplace-missing"
  st_write_plugin_manifest "$tmp/marketplace-bad" '{"name":"rein"}'
  st_write_plugin_hooks_ok "$tmp/marketplace-bad"
  st_write_plugin_marketplace "$tmp/marketplace-bad" \
    '{"name":"claude-rein","plugins":[{"name":"rein","source":"./"}]}'
  st_write_plugin_manifest "$tmp/marketplace-other-plugin" '{"name":"rein"}'
  st_write_plugin_hooks_ok "$tmp/marketplace-other-plugin"
  st_write_plugin_marketplace "$tmp/marketplace-other-plugin" \
    '{"name":"claude-rein","owner":{"name":"someone"},"plugins":[{"name":"other","source":"./"}]}'
  st_write_plugin_manifest "$tmp/hooks-empty" '{"name":"rein"}'
  st_write_plugin_hooks "$tmp/hooks-empty" '{"hooks":{}}'

  # A skill with no frontmatter at all (a form with no opening `---`).
  mkdir -p "$tmp/skill-plain/skills/plain"
  printf '# a skill with no frontmatter\n' >"$tmp/skill-plain/skills/plain/SKILL.md"

  # Fixture for the docs-links gate (split by scan root, one per location).
  st_write_docs_links_ok "$tmp/docs-links-ok"
  st_write_docs_links_missing "$tmp/docs-links-missing"
  st_write_docs_links_text_slash "$tmp/docs-links-text-slash"
  st_write_docs_links_text_md "$tmp/docs-links-text-md"
  st_write_docs_links_fence "$tmp/docs-links-fence"
  st_write_docs_links_codespan "$tmp/docs-links-codespan"

  # Fixture for the shell-quote gate (the accepting side, the side where a printf argument skips quoting, the side that embeds an
  # expansion directly, the allowlist's scope, short options, the side where the scan itself crashes). Placed under lib/ since only
  # static analysis is wanted here (outside the execute-permission / --selftest convention).
  st_write_shell_quote_ok "$tmp/pass/lib/guide.sh"
  st_write_stub_sh "$tmp/shell-quote-bad-printf/stub.sh"
  st_write_shell_quote_bad_printf "$tmp/shell-quote-bad-printf/lib/guide.sh"
  st_write_stub_sh "$tmp/shell-quote-bad-interp/stub.sh"
  st_write_shell_quote_bad_interp "$tmp/shell-quote-bad-interp/lib/guide.sh"
  # An already-quoted variable's allowlist scope (closed inside the function, or fail-open across the whole file).
  st_write_stub_sh "$tmp/shell-quote-bad-scope/stub.sh"
  st_write_shell_quote_bad_scope "$tmp/shell-quote-bad-scope/lib/guide.sh"
  # The short options (-D / -H) and --settings's position.
  st_write_stub_sh "$tmp/shell-quote-bad-shortopt/stub.sh"
  st_write_shell_quote_bad_shortopt "$tmp/shell-quote-bad-shortopt/lib/guide.sh"
  # A form where the scan itself crashes (an unreadable file). Not checking the exit code lets it turn into PASS.
  st_write_stub_sh "$tmp/scan-unreadable/stub.sh"
  st_write_unreadable_sh "$tmp/scan-unreadable/lib/unreadable.sh"
  # Fixture for the lineage-cmd gate (the accepting side is handled by the conformant fixture; bare instructions; a declared exception).
  st_write_lineage_cmd_ok "$tmp/pass/lib/lineage.sh"
  st_write_stub_sh "$tmp/lineage-cmd-bare/stub.sh"
  st_write_lineage_cmd_bare "$tmp/lineage-cmd-bare/lib/guide.sh"
  st_write_stub_sh "$tmp/lineage-cmd-opts-bare/stub.sh"
  st_write_lineage_cmd_opts_bare "$tmp/lineage-cmd-opts-bare/lib/guide.sh"
  st_write_stub_sh "$tmp/lineage-cmd-exempt/stub.sh"
  st_write_lineage_cmd_exempt "$tmp/lineage-cmd-exempt/lib/guide.sh"
  # Fixture for the self-path gate (the accepting side is the conformant fixture; a form that decides the destination via command substitution; a declared exception).
  st_write_self_path_ok "$tmp/pass/lib/self-path.sh"
  st_write_stub_sh "$tmp/self-path-bad/stub.sh"
  st_write_self_path_bad "$tmp/self-path-bad/lib/probe.sh"
  st_write_stub_sh "$tmp/self-path-exempt/stub.sh"
  st_write_self_path_exempt "$tmp/self-path-exempt/lib/probe.sh"

  # Fixture for the self-lib gate. The accepting side is handled by the conformant fixture (`$tmp/pass/lib/`)
  # -- which also measures, at the same time, that the form meant to pass never gets flagged as a violation.
  st_write_self_lib_ok "$tmp/pass/lib/self-lib.sh"
  st_write_stub_sh "$tmp/self-lib-bad/stub.sh"
  st_write_self_lib_bad "$tmp/self-lib-bad/lib/probe.sh"
  st_write_stub_sh "$tmp/self-lib-exempt/stub.sh"
  st_write_self_lib_exempt "$tmp/self-lib-exempt/lib/probe.sh"

  st_write_stub_sh "$tmp/launcher-exec-bad/stub.sh"
  st_write_launcher_exec_bad "$tmp/launcher-exec-bad/lib/hooks/rein-hook-launcher.sh"
  st_write_stub_sh "$tmp/launcher-exec-exempt/stub.sh"
  st_write_launcher_exec_exempt "$tmp/launcher-exec-exempt/lib/hooks/rein-hook-launcher.sh"

  st_write_stub_sh "$tmp/run-limit-bad/stub.sh"
  st_write_run_limit_bad "$tmp/run-limit-bad/lib/probe.sh"
  st_write_stub_sh "$tmp/run-limit-keyword/stub.sh"
  st_write_run_limit_keyword "$tmp/run-limit-keyword/lib/probe.sh"
  st_write_stub_sh "$tmp/run-limit-exempt/stub.sh"
  st_write_run_limit_exempt "$tmp/run-limit-exempt/lib/probe.sh"

  st_write_stub_sh "$tmp/home-base-bad/stub.sh"
  st_write_home_base_bad "$tmp/home-base-bad/lib/probe.sh"
  st_write_stub_sh "$tmp/home-base-exempt/stub.sh"
  st_write_home_base_exempt "$tmp/home-base-exempt/lib/probe.sh"

  st_write_record_append_ok "$tmp/pass/lib/record-append.sh"
  st_write_stub_sh "$tmp/record-append-bad/stub.sh"
  st_write_record_append_bad "$tmp/record-append-bad/lib/probe.sh"
  st_write_stub_sh "$tmp/record-append-scope/stub.sh"
  st_write_record_append_scope "$tmp/record-append-scope/lib/probe.sh"
  st_write_stub_sh "$tmp/record-append-exempt/stub.sh"
  st_write_record_append_exempt "$tmp/record-append-exempt/lib/probe.sh"

  st_write_test_side_scope_ok "$tmp/pass/lib/test-side-scope.sh"
  st_write_stub_sh "$tmp/test-side-scope-bad/stub.sh"
  st_write_test_side_scope_bad "$tmp/test-side-scope-bad/lib/probe.sh"
  st_write_stub_sh "$tmp/test-side-scope-exempt/stub.sh"
  st_write_test_side_scope_exempt "$tmp/test-side-scope-exempt/lib/probe.sh"

  st_write_flag_value_ok "$tmp/pass/lib/flag-value.sh"
  st_write_stub_sh "$tmp/flag-value-bad/stub.sh"
  st_write_flag_value_bad "$tmp/flag-value-bad/lib/probe.sh"
  st_write_stub_sh "$tmp/flag-value-exempt/stub.sh"
  st_write_flag_value_exempt "$tmp/flag-value-exempt/lib/probe.sh"

  st_write_stop_order_ok "$tmp/pass/lib/stop-order.sh"
  st_write_stub_sh "$tmp/stop-order-bad/stub.sh"
  st_write_stop_order_bad "$tmp/stop-order-bad/lib/probe.sh"
  st_write_stub_sh "$tmp/stop-order-exempt/stub.sh"
  st_write_stop_order_exempt "$tmp/stop-order-exempt/lib/probe.sh"

  st_write_stub_sh "$tmp/section-table-bad/stub.sh"
  st_write_section_table_dir "$tmp/section-table-bad/lib/cli/selftest"
  st_write_stub_sh "$tmp/section-table-exempt/stub.sh"
  st_write_section_table_dir "$tmp/section-table-exempt/lib/cli/selftest" "section-table-exempt"

  st_write_stub_sh "$tmp/gate-table-bad/stub.sh"
  st_write_gate_table_file "$tmp/gate-table-bad/lib/gates.sh" "known"
  st_write_stub_sh "$tmp/gate-table-mismatch/stub.sh"
  st_write_gate_table_file "$tmp/gate-table-mismatch/lib/gates.sh" "renamed" "gate-table-exempt"
  st_write_stub_sh "$tmp/gate-table-exempt/stub.sh"
  st_write_gate_table_file "$tmp/gate-table-exempt/lib/gates.sh" "known" "gate-table-exempt"

  # dist-author is measured on both the side where each of the 3 surfaces is offset in turn, and the side where all 3 agree (fixing the accepting side
  # would let a mutation that drops the comparison on an untouched surface pass green). The agreeing side is layered on a scan root that already passes every gate.
  st_write_stub_sh "$tmp/dist-author-split/stub.sh"
  st_write_dist_author_json "$tmp/dist-author-split" "alpha" "beta"
  st_write_dist_author_copyright "$tmp/dist-author-split" "alpha"
  st_write_stub_sh "$tmp/dist-author-license/stub.sh"
  st_write_dist_author_json "$tmp/dist-author-license" "alpha" "alpha"
  st_write_dist_author_copyright "$tmp/dist-author-license" "gamma"
  st_write_dist_author_copyright "$tmp/plugin-ok" "someone"

  # A repo with not a single scan target (zero is shown as SKIP, not PASS).
  mkdir -p "$tmp/empty-repo/sub"

  # A command body with no extension (under bin/) is treated as an executable script too.
  st_write_stub_sh "$tmp/noext-ok/stub.sh"
  st_write_stub_noext "$tmp/noext-ok/bin/tool"
  st_write_stub_sh "$tmp/noext-no-selftest/stub.sh"
  st_write_noext_without_selftest "$tmp/noext-no-selftest/bin/tool"
  st_write_stub_sh "$tmp/noext-no-exec/stub.sh"
  st_write_stub_noext "$tmp/noext-no-exec/bin/tool"
  chmod -x "$tmp/noext-no-exec/bin/tool"
  # Placed under lib/ since only static analysis is wanted here (outside the execute-permission / --selftest convention).
  st_write_stub_sh "$tmp/noext-bad-sh/stub.sh"
  cat >"$tmp/noext-bad-sh/lib/broken" <<'EOF'
#!/bin/bash
echo "unterminated
EOF
  st_write_stub_sh "$tmp/noext-foreign/stub.sh"
  st_write_noext_foreign "$tmp/noext-foreign/bin/tool"
  st_write_stub_sh "$tmp/noext-env-s/stub.sh"
  st_write_noext_env_s "$tmp/noext-env-s/bin/tool"
  st_write_stub_sh "$tmp/noext-env-bad/stub.sh"
  st_write_noext_env_unsupported "$tmp/noext-env-bad/bin/tool"

  st_section_safe() {
  st_case "a conformant fixture passes every gate" 0 "$tmp/pass"
  st_case "rejects a .sh with a shellcheck violation" 1 "$tmp/bad-sh" "shellcheck"
  st_case "rejects a broken .json" 1 "$tmp/bad-json" "jq"
  if st_case "rejects an executable script whose selftest fails" 1 "$tmp/bad-selftest" "selftest"; then
    local start_line stdout_line stderr_line exit_line
    st_expect_line "shows the selftest start with the target name first" "  START selftest failing.sh"
    st_expect_line "captures the selftest stdout" "failing-stdout"
    st_expect_line "captures the selftest stderr" "failing-stderr"
    st_expect_line "shows the selftest exit code" "    failing.sh: selftest exit=7"
    start_line="$(st_output_line_number "  START selftest failing.sh (deadline=${SELFTEST_DEADLINE_SEC}s)")"
    stdout_line="$(st_output_line_number "failing-stdout")"
    stderr_line="$(st_output_line_number "failing-stderr")"
    exit_line="$(st_output_line_number "    failing.sh: selftest exit=7")"
    if [ -n "$start_line" ] && [ -n "$stdout_line" ] && [ -n "$stderr_line" ] && [ -n "$exit_line" ] &&
      [ "$start_line" -lt "$stdout_line" ] && [ "$stdout_line" -lt "$stderr_line" ] &&
      [ "$stderr_line" -lt "$exit_line" ]; then
      st_ok
    else
      st_fail "shows START, stdout, stderr, and exit in execution order" \
        "lines=${start_line:-none}/${stdout_line:-none}/${stderr_line:-none}/${exit_line:-none}: ${ST_OUT}"
    fi
  fi
  st_streaming_visibility_case
  st_control_dir_cleanup_failure_case
  st_deadline_limit_case
  st_case "rejects an executable script that does not support --selftest" 1 "$tmp/no-selftest" "selftest"
  st_case "rejects a .sh with no execute permission" 1 "$tmp/no-exec" "selftest"
  st_case "requires neither execute permission nor --selftest under lib/" 0 "$tmp/lib-only"
  # Both sides of the judgment. Treats even a subdirectory of lib/ as a shared library, but never widens that
  # to a directory not named `lib` (widening it would grow the set of locations where the executable-script convention silently stops working).
  st_case "requires neither execute permission nor --selftest under a subdirectory of lib/ either" 0 "$tmp/lib-sub-only"
  st_case "keeps a directory not named lib subject to the convention" 1 "$tmp/libs-not-lib" "selftest"
  st_case "keeps a subdirectory not named lib subject to the convention too" 1 "$tmp/libs-sub-not-lib" "selftest"
  st_case "keeps a name with characters before lib subject to the convention too" 1 "$tmp/prefixed-lib-not-lib" "selftest"
  st_case "rejects a no-op script that checks nothing" 1 "$tmp/noop-selftest" "selftest"
  st_case "rejects a selftest with zero passes" 1 "$tmp/zero-selftest" "selftest"
  st_case "rejects a script that tries to pass with a summary line belonging to somebody else" 1 "$tmp/foreign-selftest" "selftest"

  # Enumeration that doesn't depend on extension. Without checking the count, a state of "not a single extensionless
  # executable file counted" is indistinguishable from PASS.
  if st_case "passes an extensionless executable script that follows the convention" 0 "$tmp/noext-ok"; then
    st_expect_line "counts extensionless executable scripts" "  PASS selftest (2 scripts)"
    st_expect_line "statically analyzes extensionless executable scripts" "  PASS shellcheck (2 files)"
  fi
  st_case "rejects an extensionless script that does not support --selftest" 1 "$tmp/noext-no-selftest" "selftest"
  st_case "rejects an extensionless script with no execute permission" 1 "$tmp/noext-no-exec" "selftest"
  st_case "rejects an extensionless shellcheck violation" 1 "$tmp/noext-bad-sh" "shellcheck"
  # Judging too broadly would pull even a non-shell command into the --selftest convention's scope.
  if st_case "never counts a non-shell shebang as an executable script" 0 "$tmp/noext-foreign"; then
    st_expect_line "never counts a non-shell script" "  PASS selftest (1 scripts)"
  fi
  # A form with env -S in between is resolved through to the real command and included too (unresolved, the convention silently stops working).
  if st_case "counts an env -S shebang as an executable script too" 0 "$tmp/noext-env-s"; then
    st_expect_line "counts the env -S form" "  PASS selftest (2 scripts)"
  fi
  # An unresolvable env option form is never silently excluded -- it fails as an enumeration failure.
  if st_case "fails an unresolvable shebang as an enumeration failure" 1 "$tmp/noext-env-bad" "shellcheck"; then
    st_expect_line "shows the reason for an unresolvable shebang" "cannot resolve shebang"
  fi

  # When the scan root itself can't be read, fails it distinctly from a zero-target SKIP
  # (without that distinction, a run pointed at the wrong scan root would go "green without checking anything").
  if st_case "fails, not SKIPs, when it cannot enumerate" 1 "$tmp/absent-root" "shellcheck"; then
    st_expect_line "shows an enumeration failure with a reason" "  FAIL shellcheck: could not enumerate scan targets"
    st_expect_no_line "never shows an enumeration failure as SKIP" "  SKIP shellcheck"
    st_expect_line "fails other gates on enumeration failure too" "  FAIL selftest: could not enumerate scan targets"
    st_expect_line "fails the link gate on enumeration failure too" "  FAIL docs-links: could not enumerate scan targets"
  fi

  # Both sides of the plugin gate. Checks all the way down to a broken manifest value, or a broken skill frontmatter, actually failing
  # (the jq gate only checks syntax, so without this, tampering with name would pass every gate green).
  if st_case "passes a plugin manifest, hooks registration table, and skill that follow the convention" 0 "$tmp/plugin-ok"; then
    st_expect_line "shows the checked count on the PASS line" "  PASS plugin (4 files)"
    # Passes the side where all 3 surfaces agree (this scan root carries all 3 distribution-metadata surfaces, all one spelling).
    st_expect_line "shows PASS when the distribution metadata agrees on all 3 surfaces" "  PASS dist-author (3 files)"
    st_expect_no_line "never falls back to SKIP on the agreeing side" "  SKIP dist-author"
  fi
  st_case "rejects a manifest whose name is not rein" 1 "$tmp/plugin-bad-name" "plugin"
  st_case "rejects a manifest with no name" 1 "$tmp/plugin-no-name" "plugin"
  st_case "rejects a skill whose frontmatter has no description" 1 "$tmp/skill-no-description" "plugin"
  st_case "rejects a skill with no frontmatter" 1 "$tmp/skill-plain" "plugin"

  # The hooks registration table. Each fails: missing, calling the real target directly, missing the format
  # (every one is a form where "not a single hook fires / a different target gets called", and the jq gate would let it through).
  if st_case "rejects a plugin with no hooks registration table" 1 "$tmp/hooks-missing" "plugin"; then
    st_expect_line "shows the missing registration table with a reason" "    .*hooks/hooks.json is missing"
  fi
  if st_case "rejects a registered command that does not call the launcher" 1 "$tmp/hooks-bad-command" "plugin"; then
    st_expect_line "shows the command violation with a reason" "    .*do not call the .* launcher"
  fi
  # A form missing quotes (the call target is correct). Letting this through would mean an install location for the plugin containing a space
  # leaves every step of the install walkthrough green while not a single hook fires.
  if st_case "rejects a registered command that does not quote the launcher path" 1 "$tmp/hooks-unquoted-command" "plugin"; then
    st_expect_line "shows the quoting violation with a reason" "    .*do not quote the launcher path"
    st_expect_no_line "never shows it as a call-target violation" "    .*do not call the .* launcher"
  fi
  st_case "rejects a registration missing timeout" 1 "$tmp/hooks-no-timeout" "plugin"
  st_case "rejects hooks with an empty registration" 1 "$tmp/hooks-empty" "plugin"
  # Event coverage and matcher. Both stay valid as JSON and valid as the 3-tier structure, while
  # becoming a form where "just that layer silently stops working".
  if st_case "rejects a registration table missing an event" 1 "$tmp/hooks-missing-event" "plugin"; then
    st_expect_line "names the missing event" "    .*has no registration for Stop"
    # Checks that **every single one** listed in the coverage list can be named (a form that only checks one would let
    # a mutation that drops a new event from the required-events list pass green).
    st_expect_line "names a missing cancellation wiring too" "    .*has no registration for UserPromptSubmit"
  fi
  if st_case "rejects a form that adds a matcher to PostToolBatch" 1 "$tmp/hooks-narrow-matcher" "plugin"; then
    st_expect_line "shows the matcher violation with a reason" "    .*has a matcher on PostToolBatch"
  fi
  # Also rejects a form with no launcher target (only the registration's literal text matches) -- not a single hook fires.
  st_write_plugin_manifest "$tmp/hooks-no-launcher" '{"name":"rein"}'
  st_write_plugin_marketplace_ok "$tmp/hooks-no-launcher"
  st_write_plugin_hooks_ok "$tmp/hooks-no-launcher"
  rm -f "$tmp/hooks-no-launcher/hooks/rein-hook-launcher.sh"
  if st_case "rejects a form that registers a launcher with no real target" 1 "$tmp/hooks-no-launcher" "plugin"; then
    st_expect_line "shows the missing target with a reason" "    .*registers a launcher.*cannot be executed"
  fi

  # The marketplace registration table. Each fails: missing, a required field missing, no entry for the plugin name
  # (every one is a form where "a local install fails on the spot", and other gates would let it through).
  if st_case "rejects a plugin with no marketplace registration table" 1 "$tmp/marketplace-missing" "plugin"; then
    st_expect_line "shows the missing registration table with a reason" "    .*marketplace.json is missing"
  fi
  st_case "rejects a marketplace entry missing owner" 1 "$tmp/marketplace-bad" "plugin"
  if st_case "rejects a marketplace with no entry for the plugin name" 1 "$tmp/marketplace-other-plugin" "plugin"; then
    st_expect_line "names the missing plugin name" "    .*has no plugins entry for rein"
  fi

  # A skill's run example matches the rein on PATH (never conflicts with the message hooks return).
  # A reference to bundled docs isn't a run example, so it never fails (never builds an overly broad judgment).
  if st_case "rejects a skill run example that calls a plugin-cache path" 1 "$tmp/skill-plugin-root-path" "plugin"; then
    st_expect_line "shows the run-example violation with a reason" "    .*calling .*/bin/rein"
  fi
  st_case "never fails a reference to bundled docs" 0 "$tmp/skill-plugin-root-doc"

  # A repo with no plugin contract files isn't a violation (zero is shown as SKIP, not PASS).
  if st_case "never fails a repo with no plugin contract files" 0 "$tmp/pass"; then
    st_expect_line "shows zero plugin files as SKIP" "  SKIP plugin (0 files)"
    st_expect_no_line "never shows zero plugin files as PASS" "  PASS plugin"
  fi

  # Both sides of the docs-links gate. The rejecting side pins "a link that doesn't resolve" and "text that's a path string" separately
  # (an implementation that checks only one would let the other's violation pass every gate green).
  if st_case "passes a resolving link with ordinary-word text" 0 "$tmp/docs-links-ok"; then
    st_expect_line "shows the checked count on the PASS line" "  PASS docs-links (2 files)"
  fi
  if st_case "rejects a relative link that does not resolve" 1 "$tmp/docs-links-missing" "docs-links"; then
    st_expect_line "shows the unresolved link target with its position" "    .*README.md:3: link target does not exist: spec/handover.md"
  fi
  if st_case "rejects link text containing a /" 1 "$tmp/docs-links-text-slash" "docs-links"; then
    st_expect_line "shows path-string text with its position" "    .*README.md:3: link text is a path string"
  fi
  st_case "rejects link text ending in .md" 1 "$tmp/docs-links-text-md" "docs-links"
  # Inside a code span isn't a link (never builds a form where the gate's own description trips its own gate).
  if st_case "never counts literal text inside a code span as a link" 0 "$tmp/docs-links-codespan"; then
    st_expect_line "counts a doc with only a code span too" "  PASS docs-links (1 files)"
  fi
  # Inside a code fence isn't a link (judging too broadly would fail an example showing markdown syntax).
  if st_case "never counts literal text inside a code fence as a link" 0 "$tmp/docs-links-fence"; then
    st_expect_line "counts a doc with only a fence too" "  PASS docs-links (1 files)"
  fi
  # Both sides of the shell-quote gate. The accepting side is handled by the conformant fixture (`$tmp/pass/lib/guide.sh`), so
  # this checks that the **2 forms that should fail** actually get flagged (if they don't, this mechanism exists but
  # counts nothing). There are 2 ways to embed it -- a printf argument, and an expansion inside a string.
  if st_case "rejects instructions where a printf argument skips quoting" 1 \
    "$tmp/shell-quote-bad-printf" "shell-quote"; then
    st_expect_line "shows the violation position and argument" "    .*lib/guide.sh:3: embeds a path into a finished command without quoting it"
  fi
  if st_case "rejects instructions that embed a raw expansion" 1 \
    "$tmp/shell-quote-bad-interp" "shell-quote"; then
    st_expect_line "shows the violation position" "    .*lib/guide.sh:5: embeds a path into a finished command without quoting it"
  fi
  # A form where an already-quoted variable's allowlist takes effect **across the whole file** (fail-open). In the same file, a different function
  # writing `quoted="$(rein_shell_quote ...)"` alone lets even an unquoted variable of the same name through.
  # If the scope is closed inside the function, only the one line in the later function gets flagged.
  if st_case "never lets an already-quoted variable in a different function excuse an unquoted variable of the same name" 1 \
    "$tmp/shell-quote-bad-scope" "shell-quote"; then
    st_expect_line "shows the position of the unquoted side" "    .*lib/guide.sh:10: embeds a path into a finished command without quoting it"
    st_expect_no_line "never flags the already-quoted side" "    .*lib/guide.sh:6: embeds a path.*without quoting"
  fi
  # Short options and --settings. Scanning only the long spelling would flag not a single one.
  if st_case "checks the position of short options and --settings too" 1 \
    "$tmp/shell-quote-bad-shortopt" "shell-quote"; then
    st_expect_line "shows the position of -D" "    .*lib/guide.sh:5: embeds a path into a finished command without quoting it"
    st_expect_line "shows the position of -H" "    .*lib/guide.sh:6: embeds a path into a finished command without quoting it"
    st_expect_line "shows the position of --settings" "    .*lib/guide.sh:7: embeds a path into a finished command without quoting it"
  fi
  # Never gives a run where the scan itself crashed the same face as "zero violations" (the form where a check spinning on nothing hides behind green).
  if st_case "never lets a failed scan pass" 1 \
    "$tmp/scan-unreadable" "shell-quote"; then
    st_expect_line "shows the scan failure as the reason" "  FAIL shell-quote: scan failed"
    st_expect_no_line "never shows a failed scan as PASS" "  PASS shell-quote"
  fi
  # Both sides of the lineage-cmd gate. The accepting side is handled by the conformant fixture (`$tmp/pass/lib/lineage.sh`).
  if st_case "rejects a bare rein command embedded in instructions" 1 \
    "$tmp/lineage-cmd-bare" "lineage-cmd"; then
    st_expect_line "shows the violation position" "    .*lib/guide.sh:3:"
  fi
  # The widened scope (a form with an option between `rein` and the verb; `config`'s verbs). Back when it only checked the verb
  # following directly, this fell out entirely -- this one case checks the scope itself.
  if st_case "rejects a bare rein command with an option in between too" 1 \
    "$tmp/lineage-cmd-opts-bare" "lineage-cmd"; then
    st_expect_line "shows the violation position even in the in-between form" "    .*lib/guide.sh:3:"
  fi
  if st_case "passes an exception declared with a reason" 0 "$tmp/lineage-cmd-exempt"; then
    st_expect_line "shows PASS for a scan with only exceptions" "  PASS lineage-cmd"
  fi
  # Both sides of the self-path gate. The accepting side is handled by the conformant fixture (`$tmp/pass/lib/self-path.sh`)
  # -- which also measures, at the same time, that a form cut out with string operations alone is never flagged as a violation.
  if st_case "rejects location resolution that decides the destination via command substitution" 1 \
    "$tmp/self-path-bad" "self-path"; then
    st_expect_line "shows the violation position" "    .*lib/probe.sh:3:"
  fi
  if st_case "passes a self-path exception declaration" 0 "$tmp/self-path-exempt"; then
    st_expect_line "shows PASS for a scan with only exceptions" "  PASS self-path"
    # On a machine where the scan root isn't the root of a git working tree (a fixture -- a temp directory), the scan-target pin
    # shows the fallback as SKIP, not red (never fails a legitimate fallback on a machine without git).
    st_expect_line "shows the scan-target pin as SKIP on a fixture" "  SKIP scan-source (0 checks)"
    st_expect_no_line "never shows the scan-target pin as PASS on a fixture" "  PASS scan-source"
  fi
  # Both sides of the self-lib gate (the rejecting side down to the violation's position; the accepting side via a declaration).
  if st_case "rejects a form that builds its own location with an external command" 1 \
    "$tmp/self-lib-bad" "self-lib"; then
    st_expect_line "shows the violation position" "    .*lib/probe.sh:3:"
  fi
  if st_case "passes a self-lib exception declaration" 0 "$tmp/self-lib-exempt"; then
    st_expect_line "shows PASS for a scan with only exceptions" "  PASS self-lib"
  fi
  if st_case "rejects exec from the launcher" 1 \
    "$tmp/launcher-exec-bad" "launcher-exec"; then
    st_expect_line "shows the violation position" "    .*rein-hook-launcher.sh:3:"
  fi
  if st_case "passes a launcher-exec exception declaration" 0 "$tmp/launcher-exec-exempt"; then
    st_expect_line "shows PASS for a scan with only exceptions" "  PASS launcher-exec"
  fi
  if st_case "rejects a form that starts an external process outside the capped runner" 1 \
    "$tmp/run-limit-bad" "run-limit"; then
    st_expect_line "shows the violation position" "    .*lib/probe.sh:3:"
  fi
  # Also rejects a launch placed in a conditional position (`if` / `!`) the same way -- measuring only the form right after a delimiter would let a line placed
  # in a conditional position fall outside the scan and stay green.
  if st_case "rejects an uncapped launch placed in a conditional position" 1 \
    "$tmp/run-limit-keyword" "run-limit"; then
    st_expect_line "shows the position of the if-prefixed form" "    .*lib/probe.sh:3:"
    st_expect_line "shows the position of the stacked ! form" "    .*lib/probe.sh:6:"
  fi
  if st_case "passes a run-limit exception declaration" 0 "$tmp/run-limit-exempt"; then
    st_expect_line "shows PASS for a scan with only exceptions" "  PASS run-limit"
  fi
  if st_case "rejects a base that collapses by spelling out a location" 1 \
    "$tmp/home-base-bad" "home-base"; then
    st_expect_line "shows the violation position" "    .*lib/probe.sh:3:"
  fi
  if st_case "passes a home-base exception declaration" 0 "$tmp/home-base-exempt"; then
    st_expect_line "shows PASS for a scan with only exceptions" "  PASS home-base"
  fi
  if st_case "rejects an append that never checks the write target shape" 1 \
    "$tmp/record-append-bad" "record-append"; then
    st_expect_line "shows the violation position" "    .*lib/probe.sh:3:"
  fi
  # Both ends of the scope. Checks in one scan root: that a name matching a writer verb (`write_*`) never falls out; that judgment resets to
  # top level **after** a test-side-named function; and that **inside** a test-side-named function (including literal text written out via a heredoc)
  # stays excluded throughout.
  if st_case "never falls out of scope at a name or a function boundary" 1 \
    "$tmp/record-append-scope" "record-append"; then
    st_expect_line "shows the inside of a function named after a writer verb" "    .*lib/probe.sh:3:"
    st_expect_line "shows top level after a test-side function" "    .*lib/probe.sh:15:"
    st_expect_no_line "never shows the inside of a test-side function" "    .*lib/probe.sh:7:"
    st_expect_no_line "never reads a function inside written-out literal text as a boundary" "    .*lib/probe.sh:10:"
    st_expect_line "shows exactly 2 violations" "  FAIL record-append: 2 appends"
  fi
  if st_case "passes a record-append exception declaration" 0 "$tmp/record-append-exempt"; then
    st_expect_line "shows PASS for a scan with only exceptions" "  PASS record-append"
  fi
  # The layer that checks the name-based exclusion (record-append) can never be obtained just by renaming.
  # The test side calling itself stays excluded -- only a call from a production position matches.
  if st_case "rejects a test-side name called from a production position" 1 \
    "$tmp/test-side-scope-bad" "test-side-scope"; then
    st_expect_line "shows the inside of a production function" "    .*lib/probe.sh:3:"
    st_expect_line "shows top level after a test-side function" "    .*lib/probe.sh:10:"
    st_expect_no_line "never shows the test side calling itself" "    .*lib/probe.sh:7:"
    st_expect_line "shows exactly 2 violations" "  FAIL test-side-scope: 2 calls"
  fi
  if st_case "passes a test-side-scope exception declaration" 0 "$tmp/test-side-scope-exempt"; then
    st_expect_line "shows PASS for a scan with only exceptions" "  PASS test-side-scope"
  fi
  if st_case "rejects parsing a value-taking flag that prints no reason" 1 \
    "$tmp/flag-value-bad" "flag-value"; then
    st_expect_line "shows the violation position" "    .*lib/probe.sh:7:"
  fi
  if st_case "passes a flag-value exception declaration" 0 "$tmp/flag-value-exempt"; then
    st_expect_line "shows PASS for a scan with only exceptions" "  PASS flag-value"
  fi
  if st_case "rejects a stop-block output placed after the log" 1 \
    "$tmp/stop-order-bad" "stop-order"; then
    st_expect_line "shows the violation position" "    .*lib/probe.sh:4:"
  fi
  if st_case "passes a stop-order exception declaration" 0 "$tmp/stop-order-exempt"; then
    st_expect_line "shows PASS for a scan with only exceptions" "  PASS stop-order"
  fi
  if st_case "rejects a check file missing from the section table" 1 \
    "$tmp/section-table-bad" "section-table"; then
    st_expect_line "names the violating file" "    .*selftest/orphan.sh is missing from .*selftest/selftest.sh"
  fi
  if st_case "passes a section-table exception declaration" 0 "$tmp/section-table-exempt"; then
    st_expect_line "shows PASS for a scan with only exceptions" "  PASS section-table"
  fi
  # The reverse of the gate table and the implementation (an implementation forgotten from the table -- a gate that never runs).
  if st_case "rejects an implementation missing from the gate table" 1 \
    "$tmp/gate-table-bad" "gate-table"; then
    st_expect_line "names the violating function" "    .*lib/gates.sh: gate_orphan is missing from the table in .*lib/gates.sh"
  fi
  # A drift between the table's first column and the name a function claims (the result line's literal text splitting from the spelling used with --gate) also
  # fails in the same pass. The forgotten-registration side is excluded via a declaration, leaving only the name drift to measure.
  if st_case "rejects a drift between the table name and the name the function claims" 1 \
    "$tmp/gate-table-mismatch" "gate-table"; then
    st_expect_line "names the drifted name" "    .*lib/gates.sh: gate_known is missing from the table in .*lib/gates.sh (add a line: renamed gate_known)"
  fi
  if st_case "passes a gate-table exception declaration" 0 "$tmp/gate-table-exempt"; then
    st_expect_line "shows PASS for a scan with only exceptions" "  PASS gate-table"
  fi
  # The distribution metadata's 3 surfaces. Switches the offset surface between 2 forms to check that **every surface actually gets compared**
  # (fixing the surface would let a mutation that drops the comparison on the untouched surface pass green). The accepting side is confirmed by plugin-ok.
  if st_case "rejects a drift in the distribution metadata author name" 1 \
    "$tmp/dist-author-split" "dist-author"; then
    st_expect_line "names which surface has drifted" "    marketplace.json(owner.name) has an author name that differs"
  fi
  if st_case "rejects a drift in the LICENSE copyright notice" 1 \
    "$tmp/dist-author-license" "dist-author"; then
    st_expect_line "names the LICENSE surface" "    LICENSE has an author name that differs"
  fi
  if st_case "never fails docs-links with zero scan targets" 0 "$tmp/empty-repo"; then
    st_expect_line "shows zero docs-links targets as SKIP" "  SKIP docs-links (0 files)"
    st_expect_no_line "never shows zero docs-links targets as PASS" "  PASS docs-links"
  fi

  # Zero targets is SKIP, not PASS (never shown in a way that reads as "JSON was checked").
  if st_case "never fails jq with zero targets to check" 0 "$tmp/no-json"; then
    st_expect_line "shows zero jq targets as SKIP" "  SKIP jq (0 files)"
    st_expect_no_line "never shows zero jq targets as PASS" "  PASS jq"
  fi

  # The selftest gate drops the surrounding REIN_* before launching. Measured on both sides -- confirms directly that a fixture that
  # goes red without dropping them actually does, then checks that it passes when run through the gate.
  mkdir -p "$tmp/env-probe"
  st_write_env_probe_sh "$tmp/env-probe/env-probe.sh"
  if REIN_MODEL=opus "$tmp/env-probe/env-probe.sh" --selftest >/dev/null 2>&1; then
    st_fail "a fixture that goes red on surrounding REIN_*" "does not go red without dropping them"
  else
    st_ok
  fi
  export REIN_MODEL=opus
  export REIN_CONFIG_FILE="$tmp/never/config"
  st_case "the selftest gate drops surrounding REIN_* before launching" 0 "$tmp/env-probe"
  unset REIN_MODEL REIN_CONFIG_FILE

  ST_SHELLCHECK="$tmp/absent-shellcheck"
  st_case "never passes with shellcheck missing" 1 "$tmp/pass" "shellcheck"
  ST_SHELLCHECK="$SHELLCHECK_BIN"

  ST_JQ="$tmp/absent-jq"
  st_case "never passes with jq missing" 1 "$tmp/pass" "jq"
  ST_JQ="$JQ_BIN"

  # Both sides of the bash 3.2 gate. Shows SKIP instead of running twice when it's the same binary as the bash on PATH.
  # **The same-binary premise is built on the fixture side** -- points the real-3.2 knob at the very bash on PATH.
  # Leaving it to the machine's own PATH would break that premise on a machine with a newer bash at the front of PATH,
  # going red with "should have skipped but didn't" (the check would depend on the machine -- failing wherever it's distributed).
  ST_BASH32="$(command -v bash 2>/dev/null)"
  [ -n "$ST_BASH32" ] || ST_BASH32="${BASH:-$BASH32_BIN}"
  if st_case "never runs the 3.2 gate twice for the same-binary bash" 0 "$tmp/pass"; then
    st_expect_line "shows avoiding a double run as SKIP" "  SKIP bash32"
    # A skipped run's display isn't enough with just "the outer layer was 3.2" (it would read the same even if the inner layer were a
    # different bash). The literal text also records which side the binary check actually applied to. Since a path's spelling varies by machine,
    # this checks for containment, not a match anchored at the line's start.
    case "$ST_OUT" in
      *"  SKIP bash32: the bash on PATH ("*"both outer and inner (REIN_SELFTEST_BASH defaults to the very bash running the outer layer) on the real 3.2"*)
        st_ok
        ;;
      *)
        st_fail "names both the outer and inner layer even on a skipped run" "$ST_OUT"
        ;;
    esac
  fi
  ST_BASH32="$BASH32_BIN"

  # If the binary differs, actually runs selftest on that shell (a gate that never ran is indistinguishable from SKIP).
  mkdir -p "$tmp/bin32"
  cat >"$tmp/bin32/bash" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$tmp/bin32/invoked.log"
exec /bin/bash "\$@"
EOF
  chmod +x "$tmp/bin32/bash"
  : >"$tmp/bin32/invoked.log"
  ST_BASH32="$tmp/bin32/bash"
  if st_case "runs selftest for a different-binary bash" 0 "$tmp/pass"; then
    st_expect_line "shows a run on the real 3.2 as PASS" "  PASS bash32"
    if grep -q -e '--selftest' "$tmp/bin32/invoked.log"; then
      st_ok
    else
      st_fail "actually launches selftest on the real 3.2" "no launch record: $(cat "$tmp/bin32/invoked.log")"
    fi
  fi

  # Passing the inner bash through. The runner only pins one outer layer, so this counts, via a record the fixture writes,
  # whether it actually reached the side inside selftest that relaunches its own body (reading
  # `${REIN_SELFTEST_BASH:-${BASH:-bash}}`). **Measured on both sides** -- the selftest gate never passes it (the default is the very bash
  # running the outer layer -- this variable is never set, so the probe's record is `<unset>`) --
  # only the bash32 gate names and passes the real 3.2 explicitly. Never reads "it arrived" from just the sending side's implementation.
  mkdir -p "$tmp/inner-bash"
  st_write_inner_bash_probe_sh "$tmp/inner-bash/inner-bash.sh" "$tmp/inner-bash/seen"
  : >"$tmp/inner-bash/seen"
  ST_BASH32="$tmp/bin32/bash"
  if st_case "passes the 3.2 gate for a named inner bash too" 0 "$tmp/inner-bash"; then
    inner_seen="$(tr '\n' ',' <"$tmp/inner-bash/seen" 2>/dev/null)"
    if [ "$inner_seen" = "<unset>,$tmp/bin32/bash," ]; then
      st_ok
    else
      st_fail "the selftest gate stays at the default while only the bash32 gate names the inner layer" \
        "the arrived REIN_SELFTEST_BASH sequence differs: ${inner_seen}"
    fi
  fi

  # Also fails a form that fails on that shell (never build "it ran, but nobody checked the result").
  mkdir -p "$tmp/bin32-fail"
  cat >"$tmp/bin32-fail/bash" <<'EOF'
#!/usr/bin/env bash
exit 3
EOF
  chmod +x "$tmp/bin32-fail/bash"
  ST_BASH32="$tmp/bin32-fail/bash"
  st_case "rejects a selftest that fails on the real 3.2" 1 "$tmp/pass" "bash32"

  ST_BASH32="$tmp/absent-bash"
  st_case "rejects it when the real 3.2 bash is missing" 1 "$tmp/pass" "bash32"
  ST_BASH32="$BASH32_BIN"

  # Both sides of the `--gate` entry point. Not just that a gate can be named, but that **only the named gate** runs,
  # down to that gate's own pass/fail alone showing up in the exit code (if other gates ran alongside it, the judgment
  # couldn't be attributed -- the motive to copy it out by hand and check separately would never go away).
  st_run_entry "$tmp/docs-links-ok" --gate docs-links
  st_expect_status "returns 0 when the named gate passes" 0
  st_expect_line "shows the result of the named gate" "  PASS docs-links (2 files)"
  st_expect_line "shows exactly one gate ran in the summary" \
    "${SCRIPT_NAME}: 1 gates pass / 0 fail / 0 skip"
  st_expect_no_line "never runs a gate that was not named" "  SKIP shellcheck"

  st_run_entry "$tmp/docs-links-missing" --gate docs-links
  st_expect_status "returns non-zero when the named gate fails" 1
  st_expect_line "shows the FAIL line for the named gate" "  FAIL docs-links"

  # Around name matching. An existing name's prefix, one regex metacharacter, and two gate names listed together all
  # flip to the accepting side the moment the judgment loosens to a partial match (testing only the long form would let that change pass green).
  st_run_entry "$tmp/docs-links-ok" --gate docs-link
  st_expect_status "fails on the prefix of an existing name" 2
  st_expect_line "names the prefix as-is" \
    "${SCRIPT_NAME}: no gate goes by that name: docs-link ("
  st_expect_no_line "never runs a single gate on a prefix" "${SCRIPT_NAME}: gates on"

  st_run_entry "$tmp/docs-links-ok" --gate .
  st_expect_status "fails on one regex metacharacter" 2
  st_expect_no_line "never runs a single gate on one metacharacter" "${SCRIPT_NAME}: gates on"

  st_run_entry "$tmp/docs-links-ok" --gate docs-links docs-links
  st_expect_status "fails on two gate names listed together" 2
  st_expect_line "states explicitly that only one is taken" \
    "${SCRIPT_NAME}: --gate takes exactly one gate name"
  st_expect_no_line "never runs a single gate on two names listed together" "${SCRIPT_NAME}: gates on"

  # Even the 2 that were once reserved to the user run with just one name (never split by who's running it). If the opt-in
  # option were still around, this would fail with exit code 2.
  # The scan root is a fixture with not a single executable script -- that the gate ran is checked via its SKIP line.
  st_run_entry "$tmp/docs-links-ok" --gate selftest
  st_expect_status "runs the selftest gate with just one name too" 0
  st_expect_line "shows the result line of the gate that ran" "  SKIP selftest (0 scripts)"
  st_expect_line "shows exactly one gate ran in the summary" \
    "${SCRIPT_NAME}: 0 gates pass / 0 fail / 1 skip"
  st_expect_no_line "never runs a gate that was not named" "  PASS docs-links"

  st_run_entry "$tmp/docs-links-ok" --gate bash32
  st_expect_status "runs the bash32 gate with just one name too" 0
  st_expect_line "shows the result line of the gate that ran (bash32)" "  SKIP bash32"

  # The opt-in option is no longer accepted (if it were still around, it would pass instead of
  # "no gate goes by that name" -- this is where a botched removal gets caught).
  st_run_entry "$tmp/docs-links-ok" --gate selftest --owner
  st_expect_status "fails on the removed opt-in option" 2
  st_expect_line "states explicitly that only one is taken (with the opt-in option attached)" \
    "${SCRIPT_NAME}: --gate takes exactly one gate name"
  st_expect_no_line "never runs a single gate with the opt-in option attached" "${SCRIPT_NAME}: gates on"

  # Silently passing an unknown name at zero would let a typo look the same as everything passing.
  st_run_entry "$tmp/docs-links-ok" --gate made-up-gate
  st_expect_status "fails an unknown gate name with the usage exit code" 2
  st_expect_line "names the unknown gate explicitly" \
    "${SCRIPT_NAME}: no gate goes by that name: made-up-gate (gate names: shellcheck "
  st_expect_no_line "never runs a single gate on an unknown name" "${SCRIPT_NAME}: gates on"

  # If a form missing the gate name fell back to running everything, a run meant to run just one would run every gate (including
  # the heavy sections -- erasing the point of choosing the by-name entry point).
  st_run_entry "$tmp/docs-links-ok" --gate
  st_expect_status "fails a --gate missing its gate name" 2
  st_expect_no_line "never runs every gate on a --gate missing its name" "${SCRIPT_NAME}: gates on"

  # An unknown argument still ends by showing usage, as before. Without the by-name entry point shown in usage,
  # a user would never learn it exists -- the motive to copy it out and check separately would remain.
  st_run_entry "$tmp/docs-links-ok" --unknown-option
  st_expect_status "fails an unknown argument with the usage exit code" 2
  st_expect_line "shows the by-name entry point in usage" \
    "usage: ${SCRIPT_NAME} .* | --gate <gate>\\]"
  st_expect_line "shows the selectable gate names next to usage" "gate names: shellcheck jq plugin docs-links shell-quote "
  st_expect_no_line "never runs a single gate on an unknown argument" "${SCRIPT_NAME}: gates on"

  # Pins the deadline branch's display and non-zero exit using a fixture that doesn't use process control.
  # The combination of a real process group and an intentional hang is measured by the proc:deadline section.
  ST_SELFTEST_DEADLINE=1
  if st_case "fails a deadline end with the target name attached" 1 "$tmp/safe-deadline" "selftest"; then
    st_expect_line "shows the selftest start before the deadline" \
      "  START selftest safe-deadline.sh (deadline=1s)"
    st_expect_line "shows the output captured before the deadline" "hang-before-deadline"
    st_expect_line "shows a deadline overrun with the target name and exit code" \
      "    safe-deadline.sh: selftest deadline exceeded (1s, exit=142)"
  fi
  unset ST_SELFTEST_DEADLINE

  # Since a gate only ever looks at somebody else's source's literal text, a regression where this one file itself reverts to that same
  # form is caught by its own selftest. Plants the attack form as-is: puts a `dirname` that returns empty at the front of PATH, and
  # launches with the current directory set to one seeded with a planted lib/rein-selftest-sections.sh. If the location is decided
  # by an external command's output, moving to an empty string **succeeds without changing the working directory**, so
  # the current location returns the launcher's own current directory, and the planted file runs **inside this process** (measured: this
  # form actually ended with the planted file's exit code, 79). Measures, via that exit code, that what gets loaded is the bundled real file.
  local hijack_dir hijack_out hijack_rc self_bash
  # The 2 cases that relaunch this file itself are resolved with the same discipline as every other internal launch (a bare `bash` pulls in
  # the bash on PATH, so only a run through the bash32 gate would have **these 2 cases skip the real 3.2**). The default is the very bash
  # running the outer layer -- matches the same resolution the shared fixture base (`REIN_ST_BASH`) uses.
  self_bash="${REIN_SELFTEST_BASH:-${BASH:-bash}}"
  hijack_dir="$tmp/self-path-hijack"
  mkdir -p "$hijack_dir/hijack-bin" "$hijack_dir/lib"
  printf '#!/bin/sh\nprintf ""\n' >"$hijack_dir/hijack-bin/dirname"
  chmod +x "$hijack_dir/hijack-bin/dirname"
  printf 'exit 79\n' >"$hijack_dir/lib/rein-selftest-sections.sh"
  hijack_out="$(cd "$hijack_dir" && PATH="$hijack_dir/hijack-bin:$PATH" \
    "$self_bash" "$SCRIPT_DIR/$SCRIPT_NAME" --selftest --list 2>&1 </dev/null)"
  hijack_rc=$?
  if [ "$hijack_rc" -eq 79 ]; then
    st_fail "never loads a same-named library sitting in the current directory" "the planted file ran (rc=79): ${hijack_out}"
  else
    st_ok
  fi

  # A relative-path launch is **the official path** (the dev conventions have people type it as `scripts/check.sh`) -- never fails it,
  # always passes. Dropping the current-directory prefix would leave the location as just the word `check.sh`, and it would fail to load
  # the bundled library -- this one case catches that regression.
  hijack_out="$(cd "$SCRIPT_DIR" && "$self_bash" "$SCRIPT_NAME" --selftest --list 2>&1 </dev/null)"
  hijack_rc=$?
  if [ "$hijack_rc" -ne 0 ]; then
    st_fail "can load the bundled library even from a relative-path launch" "exit=${hijack_rc}: ${hijack_out}"
  else
    case "$hijack_out" in
      *"pure:safe"*) st_ok ;;
      *) st_fail "can load the bundled library even from a relative-path launch" "no section list shown: ${hijack_out}" ;;
    esac
  fi
  }

  st_section_deadline() {
    local hang_child_pid
    ST_SELFTEST_DEADLINE=1
    ST_HANG_STATE="$tmp/hang-runtime-state"
    ST_HANG_CHILD_PID_FILE="$tmp/hang-child.pid"
    if st_case "fails a selftest that exceeds the deadline, with the target name attached" 1 \
      "$tmp/hang-selftest" "selftest"; then
      st_expect_line "shows the selftest start before the deadline" "  START selftest hang.sh (deadline=1s)"
      st_expect_line "shows the output captured before the deadline" "hang-before-deadline"
      st_expect_line "captures the descendant stderr" "hang-child-stderr"
      st_expect_line "shows a deadline overrun with the target name and exit code" \
        "    hang.sh: selftest deadline exceeded (1s, exit=142)"
    fi
    hang_child_pid="$(cat "$ST_HANG_CHILD_PID_FILE" 2>/dev/null)"
    if [ -n "$hang_child_pid" ] && st_pid_gone_within_bound "$hang_child_pid"; then
      st_ok
    else
      st_fail "leaves no TERM-ignoring child behind after the deadline" "pid=${hang_child_pid:-unknown}"
    fi
    if [ ! -e "$ST_HANG_STATE" ]; then
      st_ok
    else
      st_fail "leaves no fixture state behind after the deadline" "$ST_HANG_STATE"
    fi
    unset ST_HANG_STATE ST_HANG_CHILD_PID_FILE
    unset ST_SELFTEST_DEADLINE
  }

  rein_st_sections_run

  printf '%s: selftest %d pass / %d fail\n' "$SCRIPT_NAME" "$st_pass_count" "$st_fail_count"
  [ "$st_fail_count" -eq 0 ]
}

main() {
  case "${1:-}" in
    --selftest)
      shift
      selftest "$@" # test-side-scope-exempt: the one line that launches the selftest entry point (not a production writer)
      ;;
    --gate)
      shift
      run_one_gate "$@"
      ;;
    "")
      run_gates
      ;;
    *)
      printf 'usage: %s [--selftest [section ...] | --selftest --list | --gate <gate>]\n' \
        "$SCRIPT_NAME" >&2
      printf 'gate names: %s\n' "$(rein_gate_names_inline)" >&2
      return 2
      ;;
  esac
}

main "$@"
