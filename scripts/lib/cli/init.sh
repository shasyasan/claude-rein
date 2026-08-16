# shellcheck shell=bash
# Implementation of `rein init` (install).
# Bundles installation -- making the command callable from PATH, enabling the plugin at
# user scope, and laying down the first generation's handoff document -- into one command.
# **Does not create a config template** -- an unset key runs on its default, and a caller
# that needs an explicit value fails loud, so a template would erase the distinction between
# "default" and "explicitly set" from the very first run.
# The handoff document is the one exception, and does get a template: a handover checks that
# the document exists and is non-empty as a precondition (the bootstrap existence check,
# R6/R7), so if nobody creates one, the first generation can never start. Unlike config,
# laying one down doesn't change its meaning and doesn't blur default vs. explicit.
# Not an executable script, so it doesn't get the execute bit (out of scope for the --selftest convention).

# Where the PATH-callable command lives (doctor and init both look at this one place).
# **Returns 1 for "cannot be built" on a machine where HOME is empty, unset, or relative**
# (nothing goes to stdout). Writing this out as `${HOME:-}/.local/bin` folds to `/.local/bin`
# when HOME is empty, and since that starts with `/` it passes the absolute-path check --
# naming an unwritable path under the filesystem root as the install target, and the failure
# reason ends up as the distant-cause "cannot mkdir there" (HOME never surfaces at all).
# The determination goes through the shared predicate. No XDG environment variable is passed
# in, because this location (`~/.local/bin`) has no corresponding environment variable --
# **the predicate's reason text isn't used here either** (it would read "HOME or HOME").
# Naming the reason it can't be built is left to the caller.
# 0=one line to stdout / 1=cannot be built
rein_link_path() {
  rein_xdg_base "" HOME .local/bin "the PATH-callable command" || return 1
  printf '%s/%s\n' "$REIN_XDG_BASE" "$SCRIPT_NAME"
}

# Don't discard the failure reason (print the exit code and the last line of stderr).
init_run_claude() {
  local rc
  rein_run_capture "$CMD_TIMEOUT_SEC" claude "$@" >/dev/null
  rc=$?
  if [ "$rc" -eq 0 ]; then
    return 0
  fi
  fail "claude $* failed ($(rein_command_failure_detail "$rc"))"
  return 1
}

# (1) Make the command callable from PATH. A no-op (idempotent) if it already points at the
# same real file. **Never overwrites a link that points at a different real file** -- that
# would silently take over a lineage that's using a rein from another checkout (breaking the
# very premise that there's one real file).
init_link() {
  local dry="$1" link dir resolved
  # On a machine where the install target can't be built, **fail without placing anything**
  # (don't go and `ln` at the folded `/.local/bin`).
  if ! link="$(rein_link_path)"; then
    fail "cannot decide the install target (cannot build the default location ~/.local/bin: HOME is not set to an absolute path)"
    return 1
  fi
  if [ -e "$link" ] || [ -L "$link" ]; then
    resolved="$(resolve_self "$link")"
    if [ "$resolved" = "$REIN_BIN_PATH" ]; then
      printf 'init: already installed (real file matches): %s\n' "$link"
      return 0
    fi
    fail "${link} points at a different real file (${resolved:-cannot resolve}). To replace it, confirm no lineage still uses the one it currently points at, then remove it: rm $(rein_shell_quote "$link")"
    return 1
  fi
  if [ "$dry" -eq 1 ]; then
    printf 'init: [dry-run] ln -s %s %s\n' "$(rein_shell_quote "$REIN_BIN_PATH")" "$(rein_shell_quote "$link")"
    return 0
  fi
  dir="${link%/*}"
  mkdir -p "$dir" || {
    fail "cannot create ${dir}"
    return 1
  }
  ln -s "$REIN_BIN_PATH" "$link" || {
    fail "cannot place ${link}"
    return 1
  }
  printf 'init: installed: %s -> %s\n' "$link" "$REIN_BIN_PATH"
  return 0
}

# Whether the Claude Code CLI can be resolved at all. **Checked before anything reaches for it**,
# so that "the CLI is not here" and "the CLI is here but its answer cannot be read" never come out
# as the same reason. Without this, the first step that runs it (the enablement-state query) comes
# back undeterminable and init stops on the distant-cause reason "cannot read claude plugin list
# --json" -- naming the query rather than the missing command, and pointing the user at a
# nonexistent problem with the plugin registry. The two states have different fixes: the first is
# fixed by installing the CLI, the second by whatever made a present CLI answer unreadably (a
# version whose --json output moved, an expired login).
# It resolves the command without running it. Whether a resolvable CLI actually works is judged by
# the query that follows, so probing it here would only double every init's calls to it.
# The naming matches doctor's line for the same state, so a user who runs both is told the same
# thing by the same words.
init_require_claude() {
  command -v claude >/dev/null 2>&1 && return 0
  fail "the claude command is not on PATH (the Claude Code CLI is required. Enabling the plugin, launching the successor, enumeration, and external stops all go through this command). Install it, then run init again"
  return 1
}

# (2) Enable the plugin at user scope (hooks are registered on the plugin side, so unless
# it's enabled, neither advisories nor the wiring at turn boundaries ever fires). Safe
# to run repeatedly: re-registering a marketplace under the same name just replaces it.
# **Checks 2 axes**; either alone leaves a state where following the message still doesn't
# fix anything:
#   Axis A = enablement state (`claude plugin list`): enabled / installed but disabled /
#     not installed / cannot determine
#   Axis B = distribution source (`claude plugin marketplace list`): points at this work
#     tree / points at a different real location, or not registered / cannot determine
# If axis B is "a different real location," then even if axis A is "enabled," **the hooks
# that fire are the other real location's**, so the registry gets redirected to this work
# tree (this is the state doctor flags FAIL and points a message at -- init's condition is
# aligned to where that message takes the user who follows it). The redirect happens
# before installing (`install` can only pull from an already-registered marketplace). When
# axis A is "not installed," it gets registered right there below, so it isn't done here.
# **On either axis, "cannot determine" fails without calling anything** -- feeding a
# can't-determine state into installing or redirecting would rewrite the user's own
# marketplace registry on a run where `claude` just happens to be temporarily down (changing external
# state without knowing the state). Axis A is checked first so that a run where `claude` is
# entirely down gets a single name for its reason (never two names for the same cause).
# **A run that changed external state re-reads axis A** (the re-check below) -- so the next
# step is never chosen from the pre-change answer.
init_plugin() {
  local dry="$1" id="$2" rc root_rc redirect=0
  doctor_plugin_state
  rc=$?
  # **Whether the distribution source points at this work tree** is also checked separately
  # from the enablement state. Even with the plugin enabled, if the marketplace points at a
  # different real location (a different checkout, a GitHub distribution), the hooks that
  # fire are that location's, and doctor flags it FAIL with "to distribute from this location:
  # rein init." Back when only the enablement state was checked, **running exactly what that
  # message said produced "already enabled" and called nothing**, and the state the message
  # pointed to was never reached (doctor and init were looking at different conditions).
  # The check runs after the enablement state, so a run where `claude` is entirely down
  # still gets, as before, "cannot determine the enablement state" (never two names for the
  # same cause).
  if [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ] || [ "$rc" -eq 3 ]; then
    doctor_plugin_root_state
    root_rc=$?
    case "$root_rc" in
      0) ;;
      1 | 3 | 4) redirect=1 ;;
      *)
        fail "cannot determine the plugin's distribution source (cannot read claude plugin marketplace list --json). Stopping here rather than changing the marketplace registry while unable to determine its state"
        return 1
        ;;
    esac
  fi
  # The redirect happens before installing (`install` can only pull from an already-
  # registered marketplace). The not-installed path (rc=3) registers it itself below, so
  # it isn't called here -- don't register the same thing twice.
  if [ "$redirect" -eq 1 ] && [ "$rc" -ne 3 ]; then
    if [ "$dry" -eq 1 ]; then
      printf 'init: [dry-run] claude plugin marketplace add %s\n' "$(rein_shell_quote "$REPO_ROOT")"
    else
      init_run_claude plugin marketplace add "$REPO_ROOT" || return 1
      printf 'init: redirected the marketplace to this work tree: %s\n' "$REPO_ROOT"
      # **Once external state has changed, don't reuse the answer taken before the change.**
      # `marketplace add` replaces the distribution source of a same-named registration
      # (observed), so the install/enable state of the plugin it distributes can shift with
      # this one action. Choosing the branch below on the pre-change rc would, on a run that
      # actually needs reinstalling, either finish by saying "already enabled" or run
      # `enable` on a plugin that isn't there. Fail here too on a run that becomes
      # undeterminable (never choose the next step without knowing the post-change state).
      doctor_plugin_state
      rc=$?
    fi
  fi
  case "$rc" in
    0)
      printf 'init: plugin is already enabled (%s)\n' "$id"
      return 0
      ;;
    1)
      if [ "$dry" -eq 1 ]; then
        printf 'init: [dry-run] claude plugin enable %s --scope user\n' "$id"
        return 0
      fi
      init_run_claude plugin enable "$id" --scope user || return 1
      printf 'init: enabled the plugin (%s)\n' "$id"
      return 0
      ;;
    3)
      if [ "$dry" -eq 1 ]; then
        printf 'init: [dry-run] claude plugin marketplace add %s\n' "$(rein_shell_quote "$REPO_ROOT")"
        printf 'init: [dry-run] claude plugin install %s --scope user\n' "$id"
        return 0
      fi
      init_run_claude plugin marketplace add "$REPO_ROOT" || return 1
      init_run_claude plugin install "$id" --scope user || return 1
      printf 'init: enabled the plugin (%s)\n' "$id"
      return 0
      ;;
    *)
      fail "cannot determine the plugin's enablement state (cannot read claude plugin list --json). Stopping here rather than changing the marketplace registry while unable to determine its state"
      return 1
      ;;
  esac
}

# (3) Set up this project's runtime data location, including its owner claim
# (`<runtime>/owner`), which every entry point verifies before it reads or writes there.
# **This is not what makes hooks act** -- hooks act only on a session rein itself launched
# (told by the managed marker env), so nothing fires until `rein up` starts one, however
# installed and enabled the plugin already is. The wording says exactly that, so a user who
# ran init never reads it as "every window in this project is now watched."
# Runtime data is **rein's own**, so this doesn't conflict with init's principle of not
# touching what belongs to the user. Creating it goes through the same shared function as
# every other path (so the owner claim-and-verify logic doesn't live in a second place).
init_runtime() {
  local dry="$1" owner_file="$RUNTIME_DIR/$REIN_OWNER_BASENAME"
  local token_file="$RUNTIME_DIR/$REIN_TOKEN_BASENAME"
  # Both files are required for "already set up," not just the owner. A location claimed before
  # the lineage token existed carries the owner file and nothing else, and hooks for a session
  # launched there fail loud on every event until a token is placed -- so treating the owner
  # alone as finished would have init keep reporting that lineage as done while never placing
  # the one thing it is missing.
  if [ -f "$owner_file" ] && [ -f "$token_file" ]; then
    printf 'init: this project already has its runtime data location set up: %s\n' "$owner_file"
    return 0
  fi
  if [ "$dry" -eq 1 ]; then
    printf 'init: [dry-run] set up the runtime data location for this project (lay down the owner file and the lineage token): %s\n' "$owner_file"
    return 0
  fi
  ensure_runtime_or_fail || return 1
  printf 'init: set up the runtime data location for this project: %s\n' "$owner_file"
  return 0
}

# (4) The first generation's handoff document. Lays down a non-empty template at the
# **effective value**'s location (config's `handoff_path`, which defaults to next to the
# records). Doesn't touch anything that already exists there (its content belongs to the
# user, and rein never reads it).
# The template writes only rein's own semantics -- that this one file is the sole canonical
# document handed over at kickoff, and when to write back to it. It doesn't write anything
# project-specific (the environment, how tasks are tracked).
# The parent directory is created only when it's the records location. If config points
# somewhere else, that parent belongs to the user, so it's a fail rather than a silent
# mkdir.
init_handoff() {
  local dry="$1" path dir
  if ! rein_config_bind path handoff_path; then
    fail "$REIN_CONFIG_ERROR"
    return 1
  fi
  if [ -z "$path" ]; then
    printf 'init: the handoff document is disabled in config (handoff_path is explicitly empty). Not laying down a template\n'
    return 0
  fi
  # Doesn't touch anything that already exists (its content belongs to the user).
  # It does, though, **check whether the shape is acceptable** -- passing a directory, a
  # symlink, or an empty file as "already there" would create a lineage where the first
  # generation starts fine but only handover requests fail (the acceptance check is the
  # same shared function used by bootstrap and request).
  if [ -e "$path" ] || [ -L "$path" ]; then
    if ! rein_handoff_file_ok "$path"; then
      fail "${REIN_HANDOFF_ERROR} (cannot place a document at this location. Fix the location, or reconsider handoff_path)"
      return 1
    fi
    printf 'init: the handoff document already exists (not overwriting it): %s\n' "$path"
    return 0
  fi
  if [ "$dry" -eq 1 ]; then
    printf 'init: [dry-run] lay down the handoff document template: %s\n' "$path"
    return 0
  fi
  dir="${path%/*}"
  if [ "$dir" = "$RECORDS_DIR" ]; then
    rein_ensure_records_dir "$dir" || {
      fail "cannot create ${dir}"
      return 1
    }
  elif [ ! -d "$dir" ]; then
    fail "the handoff document's parent directory doesn't exist: ${dir} (reconsider config's handoff_path, or create it first)"
    return 1
  fi
  # Created with the O_EXCL equivalent (noclobber): never writes through an existing file
  # or a dangling symlink's target.
  # **The writing rules are filled in by printing the shared library's canonical text**
  # (not copied into the template). Keeping a copy would let it go stale the day a rule is
  # added, leaving whoever receives it unable to tell which one to follow -- the acceptance
  # check only knows the terms it was told about at that time, so anything added later
  # passes through unnoticed. A quoted heredoc doesn't expand variables, so this is split
  # into two heredocs with one printed line in between.
  if ! (
    set -o noclobber
    {
      cat <<'HANDOFF_TEMPLATE_HEAD'
# Handoff document

This file is the sole canonical document handed to the successor session at startup (no
other document is pointed to). Write back to it at every work boundary, and finish writing
it before you request a handover.

**The accuracy of this handoff is the foundation this mechanism rests on. Don't cut corners
on it** (even when prompted to hand over, the only thing to rush is deciding it's time --
never the content here).

HANDOFF_TEMPLATE_HEAD
      printf '%s\n' "$REIN_HANDOFF_WRITING_RULES"
      cat <<'HANDOFF_TEMPLATE_BODY'

## Where things stand

(How things stand right now. Don't write what's finished or closed -- by the time the
successor reads this, whatever it pointed to is gone. Write **where the working memory for
each piece of work in progress lives** -- all of them if several run in parallel; the
details live there, not here. For an item another session is holding, name the owner: "held
by live session X.")

## Next steps

(What to do next. Write "needs confirmation" only on an item that needs checking with a
parallel session -- the successor won't check an item that doesn't say so.)

## In flight at handover

(A list of subagents and jobs. Assume they die at handover -- the successor doesn't wait
assuming they're alive, and relaunches them from here if needed. Write "none" if there
aren't any.)

## Standing decisions

(Decisions that bind subsequent work, quoted verbatim. Keep **only time-limited ones** --
ones that hold for the specific task or phase currently being handed over, each one noting
what has to finish before it lapses. **Don't put permanent rules here** -- doing so piles
them up at every handover until this document turns into a place rules live. Move anything
permanent to whatever your environment designates as canonical. Write "none" if there
aren't any.)
HANDOFF_TEMPLATE_BODY
    } >"$path"
  ) 2>/dev/null; then
    fail "cannot lay down the handoff document template: ${path}"
    return 1
  fi
  printf 'init: laid down the handoff document template: %s\n' "$path"
  return 0
}

cmd_init() {
  local dry=0 id rc
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run | -n)
        dry=1
        shift
        ;;
      -*)
        take_verb_opt "$@"
        rc=$?
        case "$rc" in
          0) shift "$VERB_SHIFT" ;;
          2) return 2 ;;
          *)
            fail_usage "unknown argument to init: $1"
            return 2
            ;;
        esac
        ;;
      *)
        fail_usage "init takes no arguments: $1"
        return 2
        ;;
    esac
  done
  prepare_runtime || return 1
  require_prerequisites || return 1
  # **Before touching installation at all** -- for the same reason the exact ID is built first:
  # a machine that cannot get through this must not end up with a symlink placed and nothing else
  # done. It also keeps the reason for a missing CLI from arriving as a plugin-registry problem.
  init_require_claude || return 1
  # The exact ID (`<plugin name>@<marketplace name>`) passed to `claude plugin install /
  # enable`. **Built in exactly one place in the shared library** (`rein_plugin_exact_id`)
  # -- init passes the same value doctor uses to check against. A second writer of this
  # logic could drift when only one of the two follows a manifest rename, producing "doctor
  # is green but init installs a different ID."
  # The material is two canonical sources (the plugin manifest's name and the marketplace
  # registry's name); the latter is required to register a local directory as a marketplace
  # (per the official spec).
  # **Built before touching installation at all** -- so a machine that can't read the
  # canonical sources never ends up with a symlink placed and nothing else done.
  id="$(rein_plugin_exact_id)" || {
    fail "cannot build the plugin's exact ID (a canonical source is missing its name): ${REPO_ROOT}/${REIN_PLUGIN_MANIFEST_RELPATH}, ${REPO_ROOT}/${REIN_MARKETPLACE_MANIFEST_RELPATH}"
    return 1
  }
  init_link "$dry" || return 1
  init_plugin "$dry" "$id" || return 1
  init_runtime "$dry" || return 1
  init_handoff "$dry" || return 1
  # Registering the usage writer (statusLine) is the one thing **init doesn't do** -- the
  # user-scope settings file belongs to the user, and init only creates its own things. Without
  # that registration, a handover never happens, so this names what won't be done, and the
  # closing doctor run supplies both the current state and a snippet to paste (so this
  # determination doesn't live a second time in init).
  printf 'init: registering the usage writer (statusLine) is up to you (rein never edits settings). The check below shows its current state and a snippet to paste\n'
  if [ "$dry" -eq 1 ]; then
    printf 'init: [dry-run] nothing was changed. The check below shows the current state of installation.\n'
  fi
  printf '\n'
  # Whether installation succeeded is judged by doctor (so that determination doesn't live
  # a second time in init).
  cmd_doctor
}
