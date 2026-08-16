# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034  # selftest state is shared across sections (the caller selftest()'s locals and the ST_* globals)
# The directive above applies to the **whole file** -- in this file, neither an unused local
# inside a function nor a misspelled reference gets caught. The shared variables are scattered
# across the whole file, so a line-level directive can't be scoped tightly enough.
# selftest's doctor.
# Not an executable script, so it carries no execute bit (out of scope for the --selftest convention).

# The foundation used by the 4 sections that run doctor (doctor, fire-log, managed-settings,
# init). The real-file cross-check looks at where things live under HOME, so this swaps in a
# check-only HOME rather than touching the real one.
# Called at the top of each section -- so it stands on its own even if only one section is
# selected to run (never rides on the leftovers of a previous section).
# The user-scope settings file that plays the role of registering the usage writer
# (statusLine). Registration is judged without ever reading the user's own real settings
# (closed off with a check-only HOME and CLAUDE_CONFIG_DIR).
st_write_statusline_settings() {
  local dir="$1" command="$2"
  mkdir -p "$dir"
  jq -nc --arg c "$command" '{statusLine: {type: "command", command: $c}}' >"$dir/settings.json"
}

# Registers the bundled writer **in the shape the advice recommends** (the path wrapped in
# double quotes). Writing it here as a bare path would make this check alone fail on a layout
# where the repository itself sits at a path containing whitespace -- this check asks whether
# it says OK once the bundled writer is registered, so the result shouldn't move with
# whitespace in the location. Continuing to accept a registration with no quoting (a shape the
# user may already have in place) is pinned by a separate check.
st_write_statusline_settings_quoted() {
  st_write_statusline_settings "$1" "\"$2\""
}

# Measures the real file resolved from a registration command **through the judging function
# itself** (when doctor is launched as a whole there are combinations where the resolved
# target never shows up in an OK / WARN line, so which real file it resolved to couldn't be
# pinned that way).
# When $3 is empty, expects it to be "unresolvable (returns non-zero)."
st_expect_statusline_target() {
  local name="$1" command="$2" expected="$3" rc=0
  if [ -z "$expected" ]; then
    # Given a location that doesn't exist, resolve_self's `cd` prints to standard error. Only
    # this branch discards it, to keep it out of the check's own output (this measures the
    # return value, and standard error on the accepting side is never discarded).
    doctor_statusline_target "$command" 2>/dev/null || rc=$?
    st_expect_true "$name" test "$rc" -ne 0
    return
  fi
  doctor_statusline_target "$command" || rc=$?
  if [ "$rc" -ne 0 ]; then
    st_fail "$name" "unresolvable: ${command}"
    return
  fi
  st_expect_true "$name" test "$DOCTOR_STATUSLINE_TARGET" = "$expected"
}

# Measures that what it resolves to is **not that real file** (the point isn't whether it
# resolved at all, but that it comes out as something else -- that a shell's word-splitting
# result never gets read as "the bundled writer").
st_expect_statusline_target_not() {
  local name="$1" command="$2" unexpected="$3"
  doctor_statusline_target "$command" || :
  st_expect_true "$name" test "$DOCTOR_STATUSLINE_TARGET" != "$unexpected"
}

st_doctor_case_env() {
  proj4="$tmp/doctor-proj"
  root4="$tmp/doctor-root"
  home4="$tmp/doctor-home"
  mkdir -p "$proj4" "$home4/.local/bin" "$home4/usage"
  proj4="$(cd "$proj4" && pwd -P)"
  st_write_statusline_settings_quoted "$home4/.claude" "$REPO_ROOT/$REIN_STATUSLINE_RELPATH"
  # PATH is rebuilt for the check (so whether rein can be called from PATH never comes out
  # differently depending on whether the user's own `~/.local/bin/rein` happens to be on the
  # surrounding PATH).
  ST_VERB_ENV=(
    "PATH=${home4}/.local/bin:${verb_bin}:$(st_path_without_rein)"
    "FAKE_LOG=$verb_log"
    "FAKE_NOTIFY_LOG=$tmp/notify.log"
    "HOME=$home4"
    "CLAUDE_CONFIG_DIR=$home4/.claude"
    "REIN_USAGE_STATE_DIR=$home4/usage"
  )
}

st_section_doctor() {
  # Variables scoped only to this section are declared here (only the ones shared across
  # sections are selftest()'s locals).
  local smoke_repo smoke_writer smoke_saved fresh_root statusline_tilde_rc
  st_doctor_case_env
  ln -s "$REIN_BIN_PATH" "$home4/.local/bin/rein"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  if st_expect_status "doctor exits 0" 0; then
    st_expect_contains "checks prerequisite tools" "OK   the prerequisite tools"
    # Back when only the prefix was checked, the OK line still stayed green even with `ps`
    # hand-dropped from it (the FAIL line prints REIN_MISSING_TOOLS as-is, so `ps` shows up there
    # -- OK and FAIL would be naming different sets).
    # **Pins even the tool names**, verbatim -- adding a tool to the check without also fixing
    # this line makes it fail.
    st_expect_contains "the prerequisite tools' OK line names every tool" \
      "OK   the prerequisite tools (jq date(-r:BSD) stat(-f) perl(alarm) perl(CLOCK_MONOTONIC) shasum ps od) work"
    # A literal pin alone would pass a form where the OK line and the pin were hand-edited
    # together. Cross-checks against **the set the implementation actually saw**
    # (rein_check_prerequisites' own record) too, so the material source is checked to match
    # as well.
    rein_check_prerequisites "$REIN_BIN_PATH"
    st_expect_contains "the names on the OK line are exactly the set the check saw" \
      "OK   the prerequisite tools (${REIN_PREREQUISITE_TOOLS}) work"
    st_expect_contains "checks the usage location" "OK   the session usage location exists"
    st_expect_contains "checks the real-file cross-check" "OK   the PATH-callable command real file matches"
    st_expect_contains "the launch settings can be built even with settings unset" \
      "OK   can build the launch settings (the user's own setting is unset"
  fi
  # Fails if the real file mismatches (the hook side and the daemon side calling different
  # reins).
  rm -f "$home4/.local/bin/rein"
  ln -s "$tmp/another-rein" "$home4/.local/bin/rein"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_reject "rejects a mismatched real file" 1 "differs from"
  rm -f "$home4/.local/bin/rein"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  # The not-yet-installed advice is also **something that can be run as-is for this lineage**
  # (the template needs to be per-lineage, so it includes `--cwd`. It isn't on PATH yet, so it
  # runs through the real file path).
  st_expect_contains "advises installing when it isn't installed" \
    "install it: $(rein_shell_quote "$REIN_BIN_PATH") --root $(rein_shell_quote "$root4") --cwd $(rein_shell_quote "$proj4") init"
  # The usage location not being there yet is **the state every brand new install is in**: rein
  # itself only reads that location, and the one thing that creates it is the statusLine writer,
  # on the first turn of the first session opened after registering it. So it is a WARN carrying
  # that recovery, not a FAIL -- the same answer the next stage of the same situation ("the
  # location is there, no record in it yet") already gives. As a FAIL it put a red line in front of
  # the closing doctor of every first `rein init`, at the step the README calls the one thing that
  # has to work, where it reads as "the registration failed."
  st_doctor_case_env
  ST_VERB_ENV+=("REIN_USAGE_STATE_DIR=$home4/never")
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_contains "a location the writer can still create is a WARN with the recovery" \
    "WARN the session usage location does not exist yet"
  st_expect_not_contains "a location the writer can still create is never FAIL" \
    "FAIL the session usage location"
  # **The setting-mistake side stays FAIL**, and the line is drawn on what the writer can actually
  # do: its `mkdir -p` fails when the nearest existing location on the way there cannot be written
  # to, so no session will ever fix that one. This is the shape a mistyped usage_state_dir takes.
  st_doctor_case_env
  mkdir -p "$home4/usage-sealed"
  chmod 500 "$home4/usage-sealed"
  ST_VERB_ENV+=("REIN_USAGE_STATE_DIR=$home4/usage-sealed/never")
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_reject "fails when the usage location cannot be created either" 1 \
    "the session usage location does not exist and cannot be created"
  st_expect_contains "names the location that blocks creating it" "${home4}/usage-sealed is not a writable directory"
  chmod 700 "$home4/usage-sealed"
  # The other setting mistake: something that is not a directory already sits at the path, which
  # is the other shape `mkdir -p` fails on.
  st_doctor_case_env
  printf 'not a directory\n' >"$home4/usage-file"
  ST_VERB_ENV+=("REIN_USAGE_STATE_DIR=$home4/usage-file")
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_reject "fails when something that isn't a directory sits at the usage location" 1 \
    "the session usage location is not a directory"
  # Even if it exists, if it **can't be written to**, not a single record is ever added. Not
  # catching this leaves the WARN "no record exists yet at all," which reads as "just haven't
  # opened a session yet" (a writer's failure only shows up in stderr, which Claude Code
  # discards, so there's no other way to notice it).
  st_doctor_case_env
  mkdir -p "$home4/usage-ro"
  chmod 500 "$home4/usage-ro"
  ST_VERB_ENV+=("REIN_USAGE_STATE_DIR=$home4/usage-ro")
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_reject "fails when the usage location can't be written to" 1 "cannot write to the session usage location"
  st_expect_not_contains "never lets an unwritable location masquerade as \"no record yet\"" \
    "WARN no usage record exists yet"
  chmod 700 "$home4/usage-ro"
  # The accepting side (once the same location becomes writable, proceeds as before).
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_contains "the location check passes once it becomes writable" \
    "OK   the session usage location exists: ${home4}/usage-ro"
  # rein itself disables background-session isolation in the launch settings, so a user-side
  # setting that says nothing about it is not abnormal (absence of a specification isn't
  # itself read as abnormal).
  mkdir -p "$proj4/.git"
  st_doctor_case_env
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_status "isolation alone doesn't fail even under VCS" 0 && st_ok
  ST_VERB_ENV+=('REIN_SETTINGS={"worktree":{"bgIsolation":"none"}}')
  st_run_env --root "$root4" --cwd "$proj4" doctor
  if st_expect_status "still 0 even with a user-scope settings value" 0; then
    st_expect_contains "says it can read it as a foundation to layer onto" \
      "OK   can build the launch settings (rein layers isolation-disabling"
  fi
  # JSON with leading whitespace also passes through verbatim as a setting value (config set
  # never trims a value). Reading this as a "file path" would put a secret-capable value
  # straight into the diagnostic text.
  ST_VERB_ENV=("${ST_VERB_ENV[@]:0:${#ST_VERB_ENV[@]}-1}")
  ST_VERB_ENV+=('REIN_SETTINGS= {"worktree":{"bgIsolation":"none"},"env":{"TOKEN":"s3cr3t-value"}}')
  st_run_env --root "$root4" --cwd "$proj4" doctor
  # Whether the secret is exposed is checked outside the exit code (skipping the whole check
  # on a round where the diagnostic fails would let through the shape "the value only shows up
  # on the round it fails" -- exactly the breakage this check is for).
  st_expect_not_contains "never prints the settings value in the diagnostic text" "s3cr3t-value"
  if st_expect_status "still 0 even with leading whitespace in the JSON" 0; then
    st_expect_contains "reads it as JSON, tolerating the leading whitespace" \
      "OK   can build the launch settings (rein layers isolation-disabling"
  fi
  # A value that's neither JSON nor a file is rejected with the value withheld.
  ST_VERB_ENV=("${ST_VERB_ENV[@]:0:${#ST_VERB_ENV[@]}-1}")
  ST_VERB_ENV+=('REIN_SETTINGS=/never/exists/s3cr3t-path.json')
  # **Even the display name is measured, so this one round alone is fixed to a not-installed
  # machine** (`~/.local/bin` dropped from PATH). Staying installed would let an implementation
  # that writes a bare `rein` into the advice print the same text and pass -- this check would
  # never measure the display name at all (observed: mutating it back to bare still passed
  # 194/0). The installed side is measured by the paired "an installed machine advises with
  # rein" check below.
  ST_VERB_ENV[0]="PATH=${verb_bin}:$(st_path_without_rein)"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_not_contains "never prints an uninterpretable settings value either" "s3cr3t-path"
  st_expect_reject "fails on an uninterpretable settings value" 1 "check the value with"
  # The how-to-check line also names the lineage explicitly (a line with no naming would look
  # at a different config's value and read it as "matches" when pasted and run on a lineage
  # whose location moved). `get` folds every layer when reading, so it takes no scope
  # (`--user` / `--project`) -- this fails if that ever changes.
  st_expect_contains "the how-to-check line also names the lineage explicitly" \
    "check the value with $(rein_shell_quote "$REIN_BIN_PATH") --root $(rein_shell_quote "$root4") --cwd $(rein_shell_quote "$proj4") config get settings"
  ST_VERB_ENV[0]="PATH=${home4}/.local/bin:${verb_bin}:$(st_path_without_rein)"
  # A value not starting with `{` is treated as a path, so `[1,2]` fails on the branch for
  # **a file that doesn't exist** (the object-or-not judgment isn't exercised here -- the next 2
  # file-based cases exercise that branch).
  ST_VERB_ENV=("${ST_VERB_ENV[@]:0:${#ST_VERB_ENV[@]}-1}")
  ST_VERB_ENV+=('REIN_SETTINGS=[1,2]')
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_reject "rejects a value written as a JSON array too" 1 \
    "settings cannot be interpreted either as a file path or as a JSON object"
  # **Settings given as a file path** (existing, with object content) passes. A lineage using
  # `config set settings /path/to/settings.json` only ever goes through this one branch, so
  # leaving it unexercised would let the claim that it judges the same way as the watcher's
  # build_managed_settings drift without anything detecting it.
  ST_VERB_ENV=("${ST_VERB_ENV[@]:0:${#ST_VERB_ENV[@]}-1}")
  doctor_settings_file="$home4/settings-from-file.json"
  printf '%s\n' '{"worktree":{"bgIsolation":"none"},"env":{"TOKEN":"s3cr3t-in-file"}}' \
    >"$doctor_settings_file"
  ST_VERB_ENV+=("REIN_SETTINGS=$doctor_settings_file")
  st_run_env --root "$root4" --cwd "$proj4" doctor
  if st_expect_status "still 0 with settings given as a file path" 0; then
    st_expect_contains "reads the file's content as the foundation" \
      "OK   can build the launch settings (rein layers isolation-disabling"
  fi
  st_expect_not_contains "never prints the file's content in the diagnostic either" "s3cr3t-in-file"
  # Even an existing file can't serve as a foundation unless it's an object (only these 2 cases
  # exercise the object judgment from both sides -- confirms that the jq type judgment that
  # runs once `[ -f ]` passes is still alive).
  printf '%s\n' '[1,2]' >"$doctor_settings_file"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_reject "rejects file settings that aren't an object" 1 \
    "settings cannot be interpreted either as a file path or as a JSON object"
  ST_VERB_ENV=("${ST_VERB_ENV[@]:0:${#ST_VERB_ENV[@]}-1}")
  rm -f "$doctor_settings_file"

  # A failure to **fetch the setting itself** never falls back to "unset" (falling back would
  # masquerade as an OK line, reporting "couldn't be read" as green).
  # A fetch failure can only be manufactured within the same process, so this runs the section
  # itself in a subshell with the config layer's rein_config_bind function swapped out, and
  # measures the printed line and the FAIL count.
  ST_OUT="$(
    # shellcheck disable=SC2329  # called by doctor_settings_report (reached indirectly through the swapped-out rein_config_bind)
    rein_config_bind() {
      REIN_CONFIG_ERROR="cannot load the setting"
      return 1
    }
    DOCTOR_FAIL=0
    doctor_settings_report
    printf 'fail=%s\n' "$DOCTOR_FAIL"
  )"
  st_expect_contains "a state where settings can't be read prints the reason as-is" "FAIL cannot load the setting"
  st_expect_not_contains "never lets an unreadable state masquerade as unset-and-OK" \
    "OK   can build the launch settings"
  st_expect_contains "counts an unreadable settings state as FAIL" "fail=1"
  # The usage location follows the same discipline (never lets "couldn't be read" masquerade
  # as "not configured").
  ST_OUT="$(
    # shellcheck disable=SC2329  # called by doctor_usage_state_report
    rein_config_bind() {
      REIN_CONFIG_ERROR="cannot load the setting"
      return 1
    }
    DOCTOR_FAIL=0
    doctor_usage_state_report
    printf 'fail=%s usage_ok=%s\n' "$DOCTOR_FAIL" "$DOCTOR_USAGE_OK"
  )"
  st_expect_contains "an unreadable usage location also prints the reason as-is" "FAIL cannot load the setting"
  st_expect_not_contains "never lets an unreadable state masquerade as \"not configured\"" \
    "the session usage location is not configured"
  st_expect_contains "counts an unreadable state as FAIL, and never says the record matches the contract" "fail=1 usage_ok=0"
  # A shape where only the freshness cap can't be read (the location itself reads fine).
  # Falling it back to 0 here would turn every record "stale."
  ST_OUT="$(
    # shellcheck disable=SC2329  # called by doctor_usage_state_report
    rein_config_bind() {
      if [ "$2" = usage_stale_sec ]; then
        REIN_CONFIG_ERROR="cannot load the setting"
        return 1
      fi
      printf -v "$1" '%s' "$home4/usage"
    }
    DOCTOR_FAIL=0
    doctor_usage_state_report
    printf 'fail=%s\n' "$DOCTOR_FAIL"
  )"
  st_expect_contains "an unreadable freshness cap is also reported as FAIL" "FAIL cannot load the setting"
  st_expect_not_contains "never proceeds to the record judgment with an unreadable freshness cap" "usage record"
  st_expect_contains "counts an unreadable freshness cap as FAIL" "fail=1"

  # The plugin's enabled state. The hooks registration's real substance lives on the plugin
  # side, so if it isn't enabled, neither advisories nor any handover wiring ever fires (the
  # mechanism is dead while rein itself still looks like it's running).
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_contains "not-installed advises how to install it" "WARN the plugin is not installed"
  # The marketplace registry fixture is built to the observed shape: this work tree registered
  # as a directory.
  rein_st_write_marketplaces "$tmp/marketplaces.json" claude-rein directory "$REPO_ROOT"
  ST_VERB_ENV+=("FAKE_MARKETPLACES=$tmp/marketplaces.json")
  rein_st_write_plugins "$tmp/plugins.json" "rein@claude-rein" true
  ST_VERB_ENV+=("FAKE_PLUGINS=$tmp/plugins.json")
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_contains "calls an enabled plugin OK" "OK   the plugin is enabled"
  # The accepting side (correctly installed). `claude plugin list`'s installPath points at
  # **a cache copy** (observed) -- reading that as the marketplace's real location makes this
  # case fail. This pins, on the accepting side, that a correctly installed environment doesn't
  # regress to FAIL.
  st_expect_contains "calls it OK when the marketplace is this work tree" \
    "OK   the plugin marketplace points at this work tree: ${REPO_ROOT}"
  st_expect_not_contains "never reads the cache copy as the marketplace's real location" \
    "/does-not-exist/plugins/cache"
  rein_st_write_plugins "$tmp/plugins.json" "rein@claude-rein" false
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_reject "fails an installed-but-disabled plugin" 1 "the plugin is installed but disabled"
  # A differently-named plugin isn't read as this one (looking only at enabled would go green
  # for a different plugin).
  rein_st_write_plugins "$tmp/plugins.json" "other@claude-rein" true
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_contains "never reads a different plugin as this one" "WARN the plugin is not installed"
  # A plugin with **the same name but a different marketplace** also isn't read as this one.
  # Matching by name alone would make doctor go green in an environment where not one hook of
  # this work tree fires, and init would do nothing, saying "already enabled" (the
  # identification material is the whole `<name>@<marketplace>`).
  rein_st_write_plugins "$tmp/plugins.json" "rein@other-marketplace" true
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_contains "never reads a same-named plugin from a different marketplace as this one" \
    "WARN the plugin is not installed"
  st_expect_not_contains "never calls it enabled for a same-named plugin from a different marketplace" \
    "OK   the plugin is enabled"
  # When both coexist (the real one disabled, a same-named other one enabled), it takes
  # **the real one's state**.
  rein_st_write_plugins "$tmp/plugins.json" \
    "rein@claude-rein" false "rein@other-marketplace" true
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_reject "when both coexist, takes the real one's state" 1 "the plugin is installed but disabled"
  # A marketplace pointing outside this work tree is rejected as 3 distinct shapes (not
  # registered / points elsewhere / not distributed as a local directory). None of these can
  # be said to mean "this work tree's hooks are firing," yet looking only at the plugin's
  # enabled state would still go green.
  rein_st_write_plugins "$tmp/plugins.json" "rein@claude-rein" true
  rein_st_write_marketplaces "$tmp/marketplaces.json"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_reject "fails a shape with no marketplace registration" 1 \
    "FAIL the plugin marketplace is not registered"
  rein_st_write_marketplaces "$tmp/marketplaces.json" claude-rein directory "$tmp/another-checkout"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_reject "fails a shape pointing at a different location" 1 \
    "FAIL the plugin marketplace points at a different location: ${tmp}/another-checkout"
  st_expect_contains "also names the other side of the mismatch (this real location)" "this real location: ${REPO_ROOT}"
  rein_st_write_marketplaces "$tmp/marketplaces.json" claude-rein github "someone/claude-rein"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_reject "fails a shape that isn't a local-directory distribution" 1 \
    "FAIL the plugin marketplace is not distributed from this work tree (source=github)"
  # An unreadable registry also fails rather than saying OK (never green while it can't be
  # judged).
  printf 'not json\n' >"$tmp/marketplaces.json"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_reject "fails a shape where the registry can't be read" 1 "cannot determine the plugin marketplace"
  rein_st_write_marketplaces "$tmp/marketplaces.json" claude-rein directory "$REPO_ROOT"
  # An undeterminable shape also fails rather than saying OK (silently passing would make a
  # state that isn't firing look normal).
  ST_VERB_ENV+=("FAKE_PLUGIN_FAIL=1")
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_reject "fails a shape where the enablement state can't be determined" 1 "cannot determine the plugin enablement state"
  ST_VERB_ENV=("${ST_VERB_ENV[@]:0:${#ST_VERB_ENV[@]}-3}")

  # Whether the registry's execution path (the launcher inside the plugin -> the runner)
  # **resolves as a real file**. Even with the registration present, if even one link is
  # missing, not a single hook fires (the material for judging this is drawn from hooks.json,
  # so the check never keeps watching a stale path once the real registration changes).
  ln -s "$REIN_BIN_PATH" "$home4/.local/bin/rein"
  st_doctor_case_env
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_contains "checks that the hooks execution path resolves" \
    "OK   the hooks execution path resolves: \${CLAUDE_PLUGIN_ROOT}/${REIN_HOOK_LAUNCHER_RELPATH}"
  st_expect_contains "the path's end is the hooks runner" "$REIN_HOOK_RUNNER_RELPATH"

  # Both sides of the registration command's **shape** (whether the first word is quoted as
  # the launcher's path). The command gets word-split by a shell on the user side, so an
  # unquoted old shape splits into different words on a layout where the plugin's location
  # contains whitespace, and not one hook fires while every install step still reports green
  # (observed). Doesn't touch the real repository's registry -- it swaps the judging
  # function's REPO_ROOT out to a temporary fixture and runs **the real judgment** through it
  # as-is (called in the same process, so even the rejecting side's exit code can be measured).
  hook_shape_repo="$tmp/doctor-hook-shape"
  mkdir -p "$hook_shape_repo/${REIN_HOOK_LAUNCHER_RELPATH%/*}" \
    "$hook_shape_repo/${REIN_HOOK_RUNNER_RELPATH%/*}"
  : >"$hook_shape_repo/$REIN_HOOK_LAUNCHER_RELPATH"
  : >"$hook_shape_repo/$REIN_HOOK_RUNNER_RELPATH"
  chmod +x "$hook_shape_repo/$REIN_HOOK_LAUNCHER_RELPATH" \
    "$hook_shape_repo/$REIN_HOOK_RUNNER_RELPATH"
  hook_shape_saved="$REPO_ROOT"
  REPO_ROOT="$hook_shape_repo"
  # shellcheck disable=SC2016  # the literal text as it appears in the registry (never expanded)
  printf '%s\n' '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\"${CLAUDE_PLUGIN_ROOT}/hooks/rein-hook-launcher.sh\" stop","timeout":10}]}]}}' \
    >"$hook_shape_repo/$REIN_HOOKS_JSON_RELPATH"
  doctor_hook_command_state
  hook_shape_rc=$?
  st_expect_true "passes a quoted registration as the execution path" test "$hook_shape_rc" -eq 0
  # shellcheck disable=SC2016  # the literal text this should fail on (never expanded)
  printf '%s\n' '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/hooks/rein-hook-launcher.sh stop","timeout":10}]}]}}' \
    >"$hook_shape_repo/$REIN_HOOKS_JSON_RELPATH"
  doctor_hook_command_state
  hook_shape_rc=$?
  st_expect_true "never accepts an unquoted registration as the expected shape" test "$hook_shape_rc" -eq 3

  # The mapping from return value **to line**. A check that only looks at the judging
  # function's return value would let a mix-up in the output side's `case` pass unnoticed
  # (dropping rc!=0 to the OK side would have doctor exit 0 for a configuration where not one
  # hook fires -- exactly the breakage this check wants to catch).
  # The judgment stays real -- the fixture's registry and execute permission are moved to
  # actually drive all 4 rc values.
  # shellcheck disable=SC2016  # the literal text as it appears in the registry (never expanded)
  printf '%s\n' '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\"${CLAUDE_PLUGIN_ROOT}/hooks/rein-hook-launcher.sh\" stop","timeout":10}]}]}}' \
    >"$hook_shape_repo/$REIN_HOOKS_JSON_RELPATH"
  ST_OUT="$(
    DOCTOR_FAIL=0
    doctor_hook_command_report
    printf 'fail=%s\n' "$DOCTOR_FAIL"
  )"
  st_expect_contains "a path that resolves becomes an OK line" "OK   the hooks execution path resolves"
  st_expect_contains "a path that resolves isn't counted as FAIL" "fail=0"
  # rc=1 (the launcher can't execute).
  chmod -x "$hook_shape_repo/$REIN_HOOK_LAUNCHER_RELPATH"
  ST_OUT="$(
    DOCTOR_FAIL=0
    doctor_hook_command_report
    printf 'fail=%s\n' "$DOCTOR_FAIL"
  )"
  st_expect_contains "a launcher that can't execute becomes a FAIL line" "FAIL the hooks execution path does not resolve"
  st_expect_contains "a launcher that can't execute is counted as FAIL" "fail=1"
  chmod +x "$hook_shape_repo/$REIN_HOOK_LAUNCHER_RELPATH"
  # rc=1 (the **runner** can't execute). The launcher passes, so this is the counterpart
  # confirming the path's end is checked too.
  chmod -x "$hook_shape_repo/$REIN_HOOK_RUNNER_RELPATH"
  ST_OUT="$(
    DOCTOR_FAIL=0
    doctor_hook_command_report
    printf 'fail=%s\n' "$DOCTOR_FAIL"
  )"
  # The reason text is identical for launcher-can't-execute and runner-can't-execute (the
  # thing named is always the runner), so cross-checking the wording here would only count the
  # previous case again. What's distinguishable is that the rc=1 path is also gated on the
  # runner's execute permission by itself -- and the FAIL line above pins that.
  st_expect_contains "a runner that can't execute also becomes a FAIL line" "FAIL the hooks execution path does not resolve"
  chmod +x "$hook_shape_repo/$REIN_HOOK_RUNNER_RELPATH"
  # rc=3 (a registration missing quotes).
  # shellcheck disable=SC2016  # the literal text this should fail on (never expanded)
  printf '%s\n' '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/hooks/rein-hook-launcher.sh stop","timeout":10}]}]}}' \
    >"$hook_shape_repo/$REIN_HOOKS_JSON_RELPATH"
  ST_OUT="$(
    DOCTOR_FAIL=0
    doctor_hook_command_report
    printf 'fail=%s\n' "$DOCTOR_FAIL"
  )"
  st_expect_contains "a registration not in the expected shape becomes a FAIL line" "FAIL the hooks registration command is not in the expected shape"
  st_expect_contains "a registration not in the expected shape is counted as FAIL" "fail=1"
  # rc=2 (the registry itself can't be read).
  rm -f "$hook_shape_repo/$REIN_HOOKS_JSON_RELPATH"
  ST_OUT="$(
    DOCTOR_FAIL=0
    doctor_hook_command_report
    printf 'fail=%s\n' "$DOCTOR_FAIL"
  )"
  st_expect_contains "an unreadable registry becomes a FAIL line" "FAIL cannot read the hooks registry"
  st_expect_contains "names where the unreadable registry lives" "${hook_shape_repo}/${REIN_HOOKS_JSON_RELPATH}"
  st_expect_contains "an unreadable registry is counted as FAIL" "fail=1"
  REPO_ROOT="$hook_shape_saved"

  # Health state is a different target from "the path resolves" -- **whether it's actually
  # running**.
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_contains "a lineage that has never observed a firing says so" \
    "WARN hooks firing has never been observed yet"
  health_dir="$root4/state/rein/$(rein_cwd_key "$proj4")/$REIN_HOOK_STATE_DIRNAME/$REIN_HOOK_HEALTH_DIRNAME"
  mkdir -p "$health_dir"
  printf '%s\n' "$(rein_now_epoch)" >"$health_dir/last-seen.SessionStart"
  printf '%s\n' "$(rein_now_epoch)" >"$health_dir/last-seen.PostToolBatch"
  printf '%s\n' "$(rein_now_epoch)" >"$health_dir/last-seen.Stop"
  printf '%s\n' "$(rein_now_epoch)" >"$health_dir/last-seen.UserPromptSubmit"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_contains "prints the last firing per event" "OK   PostToolBatch last fired:"
  st_expect_not_contains "never warns once it's actually observed" "PostToolBatch firing has not been observed yet"
  # A missing shape (only that layer never fired) is printed **named per event**. Looks at 2
  # of them -- looking at only 1 would let a mutation that drops a newly added event from
  # doctor's own list pass green (no one is confirming that layer fires, yet doctor still says
  # OK).
  rm -f "$health_dir/last-seen.Stop" "$health_dir/last-seen.UserPromptSubmit"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_contains "names the missing event explicitly" "WARN Stop firing has not been observed yet"
  st_expect_contains "also names a missing cancel-side wiring explicitly" \
    "WARN UserPromptSubmit firing has not been observed yet"
  # An abnormality hooks left behind (undelivered) is also printed.
  printf '%s\n' "$(rein_now_epoch)" >"$health_dir/last-seen.Stop"
  printf '%s\n' "$(rein_now_epoch)" >"$health_dir/last-seen.UserPromptSubmit"
  printf '%s\tPostToolBatch\trein-9999\n' "$(rein_now_epoch)" >"$health_dir/undelivered"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_contains "prints a recorded hooks abnormality" "WARN hooks recorded an abnormality (undelivered)"
  # A last firing older than the freshness threshold (a shared library constant) isn't called
  # OK. Calling "N seconds ago" OK with no threshold would let even a lineage whose
  # registration fell off and hasn't fired in days pass as green.
  rm -f "$health_dir/undelivered"
  printf '%s\n' "$(($(rein_now_epoch) - REIN_HOOK_ACTIVITY_STALE_SEC - 60))" \
    >"$health_dir/last-seen.SessionStart"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_contains "warns on a last firing that's too old" "WARN SessionStart last fired too long ago"
  st_expect_contains "a recent last firing stays OK" "OK   Stop last fired:"
  rm -rf "$health_dir"

  # Whether `rein` can be called from PATH. With installation (the symlink) in place but
  # nothing on PATH, a session prompted to hand over can't even run `rein request` -- fails a
  # shape the install check alone would leave green.
  st_doctor_case_env
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_contains "checks that it can be called from PATH" "OK   can call rein from PATH"
  # The install location dropped from PATH (macOS's default PATH has no `~/.local/bin`).
  st_doctor_case_env
  ST_VERB_ENV[0]="PATH=${verb_bin}:$(st_path_without_rein)"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_reject "fails when it's not on PATH" 1 "cannot call rein from PATH"
  st_expect_contains "advises how to put it on PATH" 'export PATH="'"${home4}/.local/bin"
  # A different real file sits at the front of PATH (an update only takes effect on one of
  # them).
  mkdir -p "$tmp/other-bin"
  printf '#!/bin/sh\nexit 0\n' >"$tmp/other-bin/rein"
  chmod +x "$tmp/other-bin/rein"
  st_doctor_case_env
  ST_VERB_ENV[0]="PATH=${tmp}/other-bin:${home4}/.local/bin:${verb_bin}:$(st_path_without_rein)"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_reject "fails when the rein on PATH is a different real file" 1 "the rein on PATH points at a different real file"
  # For a not-installed lineage, the PATH check isn't printed at all (never splits one fact
  # into 2 FAIL lines).
  rm -f "$home4/.local/bin/rein"
  st_doctor_case_env
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_not_contains "when not installed, the PATH check isn't printed" "cannot call rein from PATH"
  # The **display name** filled into the advice is meant to be pasted and run as-is. On a
  # machine where rein isn't on PATH yet, advising a bare `rein ...` would leave "command not
  # found" on the exact machine that pasted it (the same output was saying "rein isn't placed
  # yet" while telling the user to run `rein`).
  st_expect_not_contains "never advises a bare rein on a not-installed machine" "'rein' --root"
  st_expect_contains "advises with the real file path on a not-installed machine" \
    "install it: $(rein_shell_quote "$REIN_BIN_PATH") --root $(rein_shell_quote "$root4") --cwd $(rein_shell_quote "$proj4") init"
  ln -s "$REIN_BIN_PATH" "$home4/.local/bin/rein"
  # The accepting side's counterpart: on a machine that's installed and callable from PATH, it advises
  # with a bare `rein` (never pastes the real file path -- this pair pins that it's not
  # "always the real file path").
  st_doctor_case_env
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_contains "an installed machine advises with rein" \
    "install it: 'rein' --root $(rein_shell_quote "$root4") --cwd $(rein_shell_quote "$proj4") init"

  # The claude command itself (launching the successor, enumeration, external stops, and
  # plugin installation all go through this).
  st_doctor_case_env
  ST_VERB_ENV[0]="PATH=${home4}/.local/bin:$(st_path_without_rein)"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_reject "fails when claude is absent" 1 "the claude command is not on PATH"

  # The usage writer's (statusLine) registration. Not registered is FAIL plus a paste-ready
  # example; a different writer is WARN.
  st_doctor_case_env
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_contains "calls a bundled writer's registration OK" \
    "OK   statusLine has the rein bundled usage writer registered"
  # A registration existing and that writer **actually running** are different things. In an
  # environment where it doesn't run, the failure only shows up in stderr, which Claude Code
  # discards, so there's no way to tell it apart from "just haven't opened a session yet"
  # unless doctor runs it once. This is the accepting side that launches **the real bundled
  # writer**.
  st_expect_contains "runs the bundled writer once to confirm" \
    "OK   the bundled usage writer actually runs"
  # The record from that run **isn't placed at the real location** (placing it would have
  # doctor's own record check read that synthetic record as the newest one, calling a state
  # with no writer present green -- the exact inverse of what this check is for).
  st_expect_true "never places the smoke-test record at the real location" \
    test ! -e "$home4/usage/rein-doctor-smoke.json"
  st_expect_contains "a smoke test never moves the record check" "WARN no usage record exists yet"
  # A registration with arguments, one starting with `~`, and one through a symlink are all
  # judged by **the real file** (a literal partial match can't tell which real file actually
  # runs).
  st_write_statusline_settings "$home4/.claude" "\"$REPO_ROOT/$REIN_STATUSLINE_RELPATH\" --quiet"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_contains "judges even a registration with arguments by the real file" \
    "OK   statusLine has the rein bundled usage writer registered"
  ln -s "$REPO_ROOT/$REIN_STATUSLINE_RELPATH" "$home4/link-statusline.sh"
  # shellcheck disable=SC2088  # the literal text written into settings (never expanded -- resolved on the reading side)
  st_write_statusline_settings "$home4/.claude" '~/link-statusline.sh'
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_contains "resolves even a ~-prefixed symlink through to the real file" \
    "OK   statusLine has the rein bundled usage writer registered"
  # Keeps accepting a registration with **no** quoting (never fails an existing registration just
  # because advice moved to a quoted shape).
  st_write_statusline_settings "$home4/.claude" "$home4/link-statusline.sh"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_contains "accepts an unquoted registration as the bundled writer too" \
    "OK   statusLine has the rein bundled usage writer registered"
  # A `~` **inside** quotes isn't expanded -- because the shell never does that (this
  # registration never runs). Measures both sides -- never calling it green, and **naming
  # exactly this shape** in the reason text. It also covers that the fix (rewriting `~` to an
  # absolute path and quoting it) is spelled out.
  st_write_statusline_settings "$home4/.claude" '"~/link-statusline.sh"'
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_not_contains "a ~ inside quotes is never expanded, and never called green" \
    "OK   statusLine has the rein bundled usage writer registered"
  if st_expect_status "rejects a registration with ~ inside quotes" 1; then
    st_expect_contains "names explicitly that a ~ inside quotes won't run" \
      "FAIL the statusLine registration uses ~ inside quotes, but the shell never expands a ~ inside quotes"
    st_expect_contains "the fix includes the absolute path" \
      "Rewrite ~ to an absolute path and quote it -- for this environment that would be \"${home4}/link-statusline.sh\""
    st_expect_not_contains "never prints the wrong reason (a different writer)" \
      "statusLine is registered but is not the rein bundled writer"
    st_expect_not_contains "never prints the wrong reason (a different checkout) either" \
      "statusLine has a rein writer registered, but from a different checkout"
  fi
  rm -f "$home4/.claude/settings.json"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_reject "fails when statusLine isn't registered" 1 "statusLine is not registered"
  # The pasted snippet is **the writer's path wrapped in double quotes** (it's passed to a
  # shell on the user side, so unwrapped it word-splits at whitespace in the location). Inside
  # JSON, so `\"` appears literally.
  st_expect_contains "prints a paste-ready example" '"statusLine": { "type": "command", "command": "\"'"$REPO_ROOT/$REIN_STATUSLINE_RELPATH"'\"" }'
  # The paste target is **the user-scope settings file** (named explicitly, as before, wherever
  # the foundation can be assembled). The counterpart to the no-HOME case below -- confirms
  # that routing the foundation judgment through the shared predicate never lost its ability to
  # name the paste target.
  st_expect_contains "names the paste target, the user-scope settings file" \
    "add the following to ${home4}/.claude/settings.json"
  # A machine with neither HOME nor CLAUDE_CONFIG_DIR (via launchd, an ssh session with a
  # stripped environment). Writing out `${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}` would fold to
  # `/.claude/settings.json` and count that one unreadable path as a search location, so
  # doctor would only ever print "not registered" -- **never once naming that HOME is
  # missing** (only the distant-cause reason reaches the user).
  ST_VERB_ENV+=("HOME=" "CLAUDE_CONFIG_DIR=")
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_reject "still fails on not-registered even with no HOME" 1 "statusLine is not registered"
  st_expect_contains "names that HOME is missing" \
    "cannot assemble the default location for the user-scope settings file (neither HOME nor CLAUDE_CONFIG_DIR is set)"
  st_expect_not_contains "never advises a folded root-level path as the paste target" \
    "add the following to /.claude/settings.json"
  st_expect_contains "still prints the paste-ready example even when the target can't be named" \
    '"statusLine": { "type": "command", "command": "\"'"$REPO_ROOT/$REIN_STATUSLINE_RELPATH"'\"" }'
  # The **fix** for a ~ inside quotes is checked in this same setup too (recommending a folded
  # `/...` as "the one for this environment" would have the user rewrite it to a place they
  # can't even write to). Only rebuilds the location, so the registration can still be read.
  ST_VERB_ENV=("${ST_VERB_ENV[@]:0:${#ST_VERB_ENV[@]}-1}")
  ST_VERB_ENV+=("CLAUDE_CONFIG_DIR=$home4/.claude")
  # shellcheck disable=SC2088  # the literal text written into settings (never expanded -- resolved on the reading side)
  st_write_statusline_settings "$home4/.claude" '"~/link-statusline.sh"'
  st_run_env --root "$root4" --cwd "$proj4" doctor
  if st_expect_status "still fails on ~ inside quotes with no HOME" 1; then
    st_expect_contains "names why the expansion target can't be produced" \
      "This machine has no HOME set to an absolute path, so the absolute path to rewrite to cannot be produced"
    st_expect_not_contains "never recommends a folded root-level path as the fix" \
      'for this environment that would be "/link-statusline.sh"'
  fi
  st_doctor_case_env
  rm -f "$home4/.claude/settings.json"
  # A different writer, where a contract-matching record can't be confirmed yet, gets a
  # warning.
  st_write_statusline_settings "$home4/.claude" "$home4/other-statusline.sh"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  if st_expect_status "still 0 even with a different writer" 0; then
    st_expect_contains "a different writer whose record can't be confirmed is warned about" \
      "WARN statusLine is registered but is not the rein bundled writer"
  fi
  # The smoke test only ever runs **on the round the bundled writer is registered** (the
  # diagnostic never launches some other command the user registered -- something whose
  # behavior is unknown is never made a side effect of doctor).
  st_expect_not_contains "never runs it while a different writer is registered" \
    "the bundled usage writer actually runs"
  # A different writer is still **OK if it writes to the contract** (never keeps warning about
  # a setup that is actually working correctly).
  printf '{"at":"%s","session_id":"sess-writer","context_window":{"used_percentage":11}}\n' \
    "$(rein_iso_now)" >"$home4/usage/sess-writer.json"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  if st_expect_status "still 0 with a contract-matching different writer" 0; then
    st_expect_contains "calls a contract-matching different writer OK" \
      "OK   statusLine has a different writer registered, but it writes to the contract"
  fi
  # Even with the same name, **a different checkout's real file** is flagged (an update only
  # takes effect on this repository).
  mkdir -p "$tmp/other-checkout/scripts"
  printf '#!/bin/sh\nexit 0\n' >"$tmp/other-checkout/scripts/${REIN_STATUSLINE_RELPATH##*/}"
  chmod +x "$tmp/other-checkout/scripts/${REIN_STATUSLINE_RELPATH##*/}"
  st_write_statusline_settings "$home4/.claude" "$tmp/other-checkout/scripts/${REIN_STATUSLINE_RELPATH##*/}"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  if st_expect_status "still doesn't fail for a different checkout" 0; then
    st_expect_contains "flags a different checkout's real file" \
      "WARN statusLine has a rein writer registered, but from a different checkout"
  fi
  rm -f "$home4/usage/sess-writer.json"
  # A project-side settings file takes effect on a later-wins basis (the later layer overrides
  # the same key).
  st_write_statusline_settings_quoted "$proj4/.claude" "$REPO_ROOT/$REIN_STATUSLINE_RELPATH"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_contains "a project-side registration wins as the later layer" \
    "OK   statusLine has the rein bundled usage writer registered"
  rm -rf "$proj4/.claude"
  st_write_statusline_settings_quoted "$home4/.claude" "$REPO_ROOT/$REIN_STATUSLINE_RELPATH"

  # How the registration command's first word is resolved, pinned on both sides **through the
  # judging function itself**. Whether it's quoted and whether it has arguments don't change
  # the outcome -- an unquoted registration (a shape the user may already have in place) is
  # still resolved as-is. On the other hand, a shape that **won't run because of how the
  # shell actually behaves** is never resolved -- an unquoted registration at a location
  # containing whitespace (word-split), and a `~` inside quotes (never expanded). Resolving
  # these anyway would report, as green, "the bundled writer is registered" for a registration
  # that never actually runs.
  statusline_space_dir="$tmp/status line/writer dir"
  mkdir -p "$statusline_space_dir"
  statusline_space_writer="$statusline_space_dir/${REIN_STATUSLINE_RELPATH##*/}"
  printf '#!/bin/sh\nexit 0\n' >"$statusline_space_writer"
  chmod +x "$statusline_space_writer"
  statusline_plain_writer="$tmp/plain-statusline.sh"
  printf '#!/bin/sh\nexit 0\n' >"$statusline_plain_writer"
  chmod +x "$statusline_plain_writer"
  st_expect_statusline_target "resolves an unquoted registration" \
    "$statusline_plain_writer" "$statusline_plain_writer"
  st_expect_statusline_target "resolves an unquoted registration even with arguments" \
    "$statusline_plain_writer --quiet" "$statusline_plain_writer"
  st_expect_statusline_target "resolves a double-quoted path containing whitespace" \
    "\"$statusline_space_writer\"" "$statusline_space_writer"
  st_expect_statusline_target "resolves a double-quoted path with whitespace even with arguments" \
    "\"$statusline_space_writer\" --quiet" "$statusline_space_writer"
  st_expect_statusline_target "resolves a single-quoted path containing whitespace" \
    "'$statusline_space_writer'" "$statusline_space_writer"
  st_expect_statusline_target_not "an unquoted path with whitespace doesn't resolve through to the writer" \
    "$statusline_space_writer" "$statusline_space_writer"
  # A shape that can't be resolved **says so** (never hands an empty real file forward as
  # "resolved").
  st_expect_statusline_target "an unclosed double quote says it can't be resolved" \
    "\"$statusline_space_writer" ""
  st_expect_statusline_target "an unclosed single quote says it can't be resolved" \
    "'$statusline_space_writer" ""
  st_expect_statusline_target "a location that doesn't exist says it can't be resolved" \
    "/rein-selftest-no-such-root/${REIN_STATUSLINE_RELPATH##*/}" ""
  # `~` expansion happens **only outside quotes** (exactly the shell's own rule). Expanding a
  # `~` inside quotes would read a registration that never actually runs as "the bundled
  # writer." The judgment reads $HOME, so it's swapped only for the duration of the check
  # rather than relying on the real HOME (uses a location containing whitespace as HOME too, so
  # `~` expansion and quote resolution are exercised together).
  statusline_home_saved="$HOME"
  HOME="$statusline_space_dir"
  # shellcheck disable=SC2088  # the literal registration text (never expanded -- resolved on the judging side)
  st_expect_statusline_target "resolves a ~ outside quotes, expanded" \
    "~/${REIN_STATUSLINE_RELPATH##*/}" "$statusline_space_writer"
  st_expect_statusline_target "a ~ inside quotes isn't expanded, and says it can't be resolved" \
    "\"~/${REIN_STATUSLINE_RELPATH##*/}\"" ""
  # On a machine where HOME can't be used, `~` is **never expanded** (writing out
  # `${HOME:-}/...` would fold to `/...` and hand a nonexistent path under the root forward as
  # the real file -- the judgment then comes out as the mistaken reason "a different writer").
  # Exercises both an empty HOME and a relative HOME (what the predicate looks at is "is it
  # present as an absolute path").
  HOME=""
  # shellcheck disable=SC2088  # the literal registration text (never expanded -- resolved on the judging side)
  st_expect_statusline_target "with an empty HOME, ~ isn't resolved" \
    "~/${REIN_STATUSLINE_RELPATH##*/}" ""
  HOME="relative/home"
  # shellcheck disable=SC2088  # the literal registration text (never expanded -- resolved on the judging side)
  st_expect_statusline_target "with a relative HOME, ~ isn't resolved either" \
    "~/${REIN_STATUSLINE_RELPATH##*/}" ""
  # The advisory side is the same (whether it's this shape at all doesn't depend on HOME, so it
  # returns 0 -- only the expansion target comes out empty).
  HOME=""
  doctor_statusline_quoted_tilde "\"~/${REIN_STATUSLINE_RELPATH##*/}\""
  statusline_tilde_rc=$?
  st_expect_true "the shape of ~ inside quotes is recognized even with no HOME" test "$statusline_tilde_rc" -eq 0
  st_expect_true "with no HOME, the advisory doesn't print an expansion target" \
    test -z "$DOCTOR_STATUSLINE_TILDE_HINT"
  # The accepting side's counterpart (restoring HOME still prints the advisory as before -- never
  # collapsing to empty unconditionally).
  HOME="$statusline_space_dir"
  doctor_statusline_quoted_tilde "\"~/${REIN_STATUSLINE_RELPATH##*/}\""
  st_expect_true "with HOME present, the advisory prints the expansion target" \
    test "$DOCTOR_STATUSLINE_TILDE_HINT" = "$statusline_space_writer"
  HOME="$statusline_home_saved"

  # The 3 shapes where the bundled writer **doesn't run** (exits non-zero, places no record,
  # places a record that violates the contract), driven through both the judging function and
  # the mapping from return value to **line**. Never touches the real writer (dropping its
  # execute permission would stop the user's own live statusLine dead) -- it swaps the judging
  # function's material, REPO_ROOT, out to a temporary fixture and runs the real judgment as-is
  # (the same shape as the earlier registration execution-path check).
  smoke_repo="$tmp/doctor-statusline-smoke"
  mkdir -p "$smoke_repo/${REIN_STATUSLINE_RELPATH%/*}"
  smoke_writer="$smoke_repo/$REIN_STATUSLINE_RELPATH"
  smoke_saved="$REPO_ROOT"
  REPO_ROOT="$smoke_repo"
  # Measures the accepting side first -- this pair pins that the 3 failing cases below aren't
  # simply "the fixture never runs at all" (the write target is the isolated location the
  # smoke test passes).
  cat >"$smoke_writer" <<'SMOKE'
#!/bin/sh
printf 'Model 1%%\n'
mkdir -p "$REIN_USAGE_STATE_DIR" || exit 1
printf '{"at":"2026-01-01T00:00:00Z","session_id":"rein-doctor-smoke","context_window":{"used_percentage":1}}\n' \
  >"$REIN_USAGE_STATE_DIR/rein-doctor-smoke.json"
SMOKE
  chmod +x "$smoke_writer"
  ST_OUT="$(
    DOCTOR_FAIL=0
    doctor_statusline_smoke_report
    printf 'fail=%s\n' "$DOCTOR_FAIL"
  )"
  st_expect_contains "a writer that writes to the contract becomes an OK line" "OK   the bundled usage writer actually runs"
  st_expect_contains "a running writer isn't counted as FAIL" "fail=0"
  # (a) A shape that exits non-zero every turn (a prerequisite tool or the shared library
  # can't be traced in that environment).
  cat >"$smoke_writer" <<'SMOKE'
#!/bin/sh
printf 'Model 1%%\n'
printf 'rein-statusline.sh: cannot create the session usage location\n' >&2
exit 1
SMOKE
  chmod +x "$smoke_writer"
  ST_OUT="$(
    DOCTOR_FAIL=0
    doctor_statusline_smoke_report
    printf 'fail=%s\n' "$DOCTOR_FAIL"
  )"
  st_expect_contains "a writer that doesn't run becomes a FAIL line" \
    "FAIL the registered bundled usage writer does not run"
  st_expect_contains "puts the writer's last line into the not-running reason" "cannot create the session usage location"
  st_expect_contains "a writer that doesn't run is counted as FAIL" "fail=1"
  # (b) A shape that only prints the display and places no record (as far as a reader is
  # concerned, the same as no writer being present).
  cat >"$smoke_writer" <<'SMOKE'
#!/bin/sh
printf 'Model 1%%\n'
SMOKE
  chmod +x "$smoke_writer"
  ST_OUT="$(
    DOCTOR_FAIL=0
    doctor_statusline_smoke_report
    printf 'fail=%s\n' "$DOCTOR_FAIL"
  )"
  st_expect_contains "a writer that places no record becomes a FAIL line" \
    "FAIL the registered bundled usage writer never places a record"
  st_expect_contains "a writer that places no record is counted as FAIL" "fail=1"
  # (c) A shape that places a record but violates the contract (the reader folds
  # used_percentage as a number).
  cat >"$smoke_writer" <<'SMOKE'
#!/bin/sh
printf 'Model 1%%\n'
mkdir -p "$REIN_USAGE_STATE_DIR" || exit 1
printf '{"at":"2026-01-01T00:00:00Z","session_id":"rein-doctor-smoke","context_window":{"used_percentage":"20"}}\n' \
  >"$REIN_USAGE_STATE_DIR/rein-doctor-smoke.json"
SMOKE
  chmod +x "$smoke_writer"
  ST_OUT="$(
    DOCTOR_FAIL=0
    doctor_statusline_smoke_report
    printf 'fail=%s\n' "$DOCTOR_FAIL"
  )"
  st_expect_contains "a contract-violating record becomes a FAIL line" \
    "FAIL the registered bundled usage writer does not write a record matching the contract"
  st_expect_contains "a contract-violating record is counted as FAIL" "fail=1"
  # A dropped execute permission also fails at the same entry point (it is launched directly by
  # real file path, the same as the registration, so it comes back 126).
  chmod -x "$smoke_writer"
  ST_OUT="$(
    DOCTOR_FAIL=0
    doctor_statusline_smoke_report
    printf 'fail=%s\n' "$DOCTOR_FAIL"
  )"
  st_expect_contains "a writer with no execute permission becomes a FAIL line" \
    "FAIL the registered bundled usage writer does not run"
  REPO_ROOT="$smoke_saved"

  # The usage record's format check (a location merely existing doesn't mean "a writer is
  # present").
  st_doctor_case_env
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_contains "says so when no record exists yet" "WARN no usage record exists yet"
  usage_state="$home4/usage/sess-doctor.json"
  printf '{"at":"%s","session_id":"sess-doctor","context_window":{"used_percentage":12.5}}\n' \
    "$(rein_iso_now)" >"$usage_state"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  if st_expect_status "0 for a contract-matching record" 0; then
    st_expect_contains "calls a contract-matching record OK" "OK   the usage record matches the contract"
  fi
  # A record with no used_percentage is FAIL (the shape the "only checks the location exists"
  # form was letting through).
  printf '{"at":"%s","session_id":"sess-doctor","context_window":{}}\n' \
    "$(rein_iso_now)" >"$usage_state"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_reject "fails a record with no used_percentage" 1 "has no context_window.used_percentage"
  # **A type mismatch** is also FAIL (`jq -r` prints the string "20" the same as 20, so a
  # digit-shape check alone lets it through unnoticed. The reader folds it as a number, so
  # letting it through leaves doctor all green while handovers just don't happen).
  printf '{"at":"%s","session_id":"sess-doctor","context_window":{"used_percentage":"20"}}\n' \
    "$(rein_iso_now)" >"$usage_state"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_reject "fails a string-typed used_percentage" 1 "is not numeric (type string"
  # A time format outside the contract is also FAIL (the freshness judgment itself can't even
  # get off the ground).
  printf '{"at":"2026/08/20 04:12:33","session_id":"sess-doctor","context_window":{"used_percentage":12}}\n' \
    >"$usage_state"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_reject "fails a time format outside the contract" 1 "does not match the required time format"
  # A record that can't be read as JSON is also FAIL.
  printf 'not json\n' >"$usage_state"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_reject "fails an unreadable record" 1 "cannot be interpreted as JSON"
  # An old record is WARN (whether the writer stopped, or that session was just closed, can't
  # be told apart from outside).
  printf '{"at":"%s","session_id":"sess-doctor","context_window":{"used_percentage":12}}\n' \
    "$(TZ=UTC date -u -r "$(($(rein_now_epoch) - 100000))" +%Y-%m-%dT%H:%M:%SZ)" >"$usage_state"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  if st_expect_status "an old record doesn't fail" 0; then
    st_expect_contains "warns on an old record" "WARN the usage record was last updated too long ago"
  fi
  rm -f "$usage_state"

  # Handover requests left stranded mid-judgment (`processing/`) are printed by doctor.
  # Reclaiming only ever runs at the next watcher startup, so with no watcher present, nothing
  # anywhere shows that that session's handover trigger is blocked (`rein status` and the
  # archive scan don't look at `processing/` either).
  st_doctor_case_env
  doctor_runtime="$root4/$REIN_ROOT_STATE_RELDIR/$(rein_cwd_key "$proj4")"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_contains "says so when nothing is stranded" "OK   no handover requests are stranded mid-judgment"
  mkdir -p "$doctor_runtime/$REIN_PROCESSING_DIRNAME"
  printf '{}\n' >"$doctor_runtime/$REIN_PROCESSING_DIRNAME/orphan.json"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  if st_expect_status "still doesn't fail even with something stranded" 0; then
    st_expect_contains "warns with a count when something is stranded" \
      "WARN handover requests stranded mid-judgment: 1"
    st_expect_contains "advises the path to reclaiming them" \
      "'rein' --root $(rein_shell_quote "$root4") --cwd $(rein_shell_quote "$proj4") up"
  fi
  rm -rf "${doctor_runtime:?}/$REIN_PROCESSING_DIRNAME"

  # The runtime data location's **owner** (the 3 branches: doesn't exist yet / matches /
  # mismatches). If the owner cross-check stayed green, a state where it's holding a different
  # lineage's location (the state `prune` comes to remove as an orphan) would leave doctor all
  # green while only `status` fails -- the hardest shape to read.
  st_doctor_case_env
  rm -rf "${doctor_runtime:?}"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_contains "says so when the location doesn't exist yet" "WARN the runtime data location does not exist yet"
  st_expect_not_contains "never calls a nonexistent location a matching owner" \
    "OK   the runtime data location owner matches"
  # The location exists but has no claim. The judging function still returns 0 for this too
  # (never stalls a read-only caller), so if doctor didn't also check whether the claim exists,
  # this would masquerade as "matches" -- the matching branch below wouldn't pin the fact of
  # matching even once.
  mkdir -p "$doctor_runtime"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_contains "a location with no claim says so" "WARN the runtime data location has no owner record"
  st_expect_not_contains "never calls a location with no claim a matching owner" \
    "OK   the runtime data location owner matches"
  printf '%s\n' "$proj4" >"$doctor_runtime/$REIN_OWNER_BASENAME"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_contains "says OK once the owner matches" "OK   the runtime data location owner matches"
  # The matching side is also pinned through the judging function (the counterpart to the
  # mismatch branch -- rc alone would also pass "no owner is present yet" as 0, so this checks
  # that the claim actually exists too).
  rein_verify_runtime_owner "$doctor_runtime" "$proj4"
  doctor_owner_rc=$?
  if [ "$doctor_owner_rc" -eq 0 ] && [ "$REIN_RUNTIME_OWNER_PRESENT" -eq 1 ]; then
    st_ok
  else
    st_fail "the owner cross-check also checks that a claim exists" \
      "rc=${doctor_owner_rc} present=${REIN_RUNTIME_OWNER_PRESENT} owner=$(cat "$doctor_runtime/$REIN_OWNER_BASENAME" 2>/dev/null)"
  fi
  printf '%s\n' "$tmp/other-project" >"$doctor_runtime/$REIN_OWNER_BASENAME"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  if st_expect_reject "fails when it's holding a different lineage's location" 1 "belongs to a different target"; then
    st_expect_contains "names the different owner" "owned by ${tmp}/other-project"
    st_expect_not_contains "never says a mismatch is a match too" \
      "OK   the runtime data location owner matches"
  fi
  # Reset the premise for the following cases back to "claimed, matching" (leaving it deleted
  # would run the rest of doctor after this section on a different premise -- a location with
  # no claim).
  printf '%s\n' "$proj4" >"$doctor_runtime/$REIN_OWNER_BASENAME"

  # The lineage token that sits next to the owner file (the 3 branches: absent / in place /
  # readable beyond this user). Nothing else in normal use reports on this file, and a lineage
  # missing it launches sessions whose hooks fail loud on every event, with the reason visible
  # only as stderr inside that session -- so if doctor stayed silent here, the state would first
  # be noticed as "rein stopped working" with nothing pointing at the cause.
  # The premise for this run is the owner already reset above, so the branches below vary **only
  # the token** -- an OK/WARN difference here cannot be coming from the owner check.
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_contains "a claimed location with no token says so" "holds no lineage token file"
  st_expect_contains "the missing-token line advises how to place one" \
    "'rein' --root $(rein_shell_quote "$root4") --cwd $(rein_shell_quote "$proj4") up"
  st_expect_not_contains "never calls a location with no token a lineage that has one" \
    "OK   the lineage token is in place"
  # Placed through the shared function, never written here by hand -- what doctor judges has to be
  # what the provisioning layer actually produces (a hand-written value could disagree with it in
  # length, shape, or mode and this case would never notice).
  if rein_ensure_runtime_token "$doctor_runtime"; then
    st_ok
  else
    st_fail "the doctor fixture can hold a lineage token" "$REIN_RUNTIME_ERROR"
  fi
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_contains "says OK once the token is in place" "OK   the lineage token is in place"
  st_expect_not_contains "never still reports it missing once placed" "holds no lineage token file"
  # A token other users on this machine can read is **FAIL, not a warning**: hooks still work, so
  # nothing else would ever surface it, and the one property the check rests on (that a project's
  # own settings cannot know this value) is gone.
  chmod 644 "$doctor_runtime/$REIN_TOKEN_BASENAME"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  if st_expect_reject "fails when the token's mode is not 0600" 1 "the lineage token's mode is not 0600"; then
    st_expect_contains "names the mode it found" "found 644"
    st_expect_not_contains "never calls a world-readable token in place" "OK   the lineage token is in place"
  fi
  # Reset the premise for the following cases back to "claimed, with a token at 0600".
  chmod 600 "$doctor_runtime/$REIN_TOKEN_BASENAME"

  # A lineage where only the handover's final step (retiring the predecessor session) remains. Since
  # the pointer already points at the successor, the primary session's line looks normal, and
  # nothing anywhere else showed that the predecessor session was still around.
  st_doctor_case_env
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_contains "says so when nothing is left unfinished" "OK   no handover was left unfinished"
  doctor_records="$root4/$REIN_ROOT_RECORDS_RELDIR/$(rein_cwd_key "$proj4")"
  mkdir -p "$doctor_records"
  rein_st_write_pointer "$doctor_records/$REIN_POINTER_BASENAME" "succ-doc" "successor" "$proj4" 2 "pred-doc"
  # The predecessor session is still alive in the enumeration (the successor is present too -- the real
  # layout right after a handover).
  rein_st_write_agents "$tmp/doctor-agents.json" "$proj4" "succ-doc" "pred-doc"
  ST_VERB_ENV+=("FAKE_AGENTS=$tmp/doctor-agents.json")
  st_run_env --root "$root4" --cwd "$proj4" doctor
  if st_expect_status "doesn't fail even with something left unfinished" 0; then
    st_expect_contains "names the predecessor session that remains" \
      "WARN the handover final step is left unfinished (the predecessor session pred-doc"
    st_expect_contains "advises the path to resuming it" \
      "'rein' --root $(rein_shell_quote "$root4") --cwd $(rein_shell_quote "$proj4") up"
  fi
  # Once the predecessor session drops out of the enumeration, the same pointer is no longer left
  # unfinished.
  rein_st_write_agents "$tmp/doctor-agents.json" "$proj4" "succ-doc"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_contains "once the predecessor session is gone, nothing is left unfinished" "OK   no handover was left unfinished"

  # A shape where only one side died (the primary session on record is a dead successor, and
  # what's alive is the predecessor). Since this is a state deliberately not auto-fixed,
  # **doctor naming it explicitly with a fix** is the only way out. Never a dead end -- the
  # advice includes even the last resort (redoing `rein init`).
  rein_st_write_agents "$tmp/doctor-agents.json" "$proj4" "pred-doc"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  if st_expect_status "fails when only one side died" 1; then
    st_expect_contains "names both sides of the mismatch" \
      "the primary session on record, succ-doc, is not in enumeration, but the predecessor, pred-doc, is alive"
    st_expect_contains "never falls back to the leftover-step advice" "rein does not fix this automatically"
    st_expect_contains "advises the last resort" \
      "'rein' --root $(rein_shell_quote "$root4") --cwd $(rein_shell_quote "$proj4") init"
  fi
  st_expect_not_contains "never calls the mismatch a leftover step" "OK   no handover was left unfinished"
  rein_st_write_agents "$tmp/doctor-agents.json" "$proj4" "succ-doc"

  rm -f "$doctor_records/$REIN_POINTER_BASENAME"
  st_doctor_case_env

  # A shape where the location **exists but can't be written to**. The records layer being
  # unwritable stops neither hooks nor the session, so this state proceeds with records
  # silently missing, and the missing record then gets read as a different cause.
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_contains "a writable location is called OK" "OK   every location rein writes to is writable"
  chmod 500 "$doctor_records"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_reject "fails an unwritable location" 1 "cannot write to the records location"
  chmod 700 "$doctor_records"
  # With **nothing at all existing yet** (a new machine's first run), never says "everything is
  # writable." Wording that reads as "checked, no problem" for something not actually checked
  # would leave the user believing this was confirmed, only to discover missing records once
  # they start using it.
  fresh_root="$tmp/doctor-fresh-root"
  st_run_env --root "$fresh_root" --cwd "$proj4" doctor
  st_expect_contains "with nothing existing yet, says it wasn't checked" \
    "WARN none of the locations rein writes to exist yet"
  st_expect_not_contains "never calls a 0-location check \"everything is writable\"" \
    "OK   every location rein writes to is writable"
  st_expect_true "confirms the check's premise (nothing exists yet)" \
    test ! -e "$fresh_root/$REIN_ROOT_STATE_RELDIR"
  # With only some existing, calls only the existing ones OK (never wording it as if all 3 were
  # checked).
  mkdir -p "$fresh_root/$REIN_ROOT_STATE_RELDIR"
  st_run_env --root "$fresh_root" --cwd "$proj4" doctor
  st_expect_contains "with only some existing, says so with a count" \
    "OK   every location that currently exists is writable (1/3"
  st_expect_not_contains "never calls a partial check \"every location is writable\"" \
    "OK   every location rein writes to is writable"
  rm -rf "${fresh_root:?}"

  # A resident watcher **still running the code it started with**. Only config gets re-read
  # each cycle, so updating the checkout doesn't move a running watcher off the old
  # implementation (observed on this machine). The judging material is 2 things: the handover
  # log's `watch_started` timestamp, and the implementation files' last-modified time.
  st_doctor_case_env
  rein_st_start_fake_watcher "$doctor_runtime" "$proj4"
  doctor_log="$doctor_records/$REIN_LOG_BASENAME"
  printf '{"schema":"%s","ts":"%s","event":"watch_started","detail":"cwd=%s pid=%s started_at=%s version=0.0.0","generation":null,"predecessor_session_id":null,"successor_session_id":null}\n' \
    "$REIN_LOG_SCHEMA" "2020-01-01T00:00:00Z" "$proj4" "$REIN_ST_WATCHER_PID" "2020-01-01T00:00:00Z" \
    >"$doctor_log"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  if st_expect_status "doesn't fail even while running old code" 0; then
    st_expect_contains "warns that it's still running old code" \
      "WARN the implementation has been updated since the resident watcher started"
    st_expect_contains "advises the reinstall steps" \
      "'rein' --root $(rein_shell_quote "$root4") --cwd $(rein_shell_quote "$proj4") down"
  fi
  # The accepting side's counterpart: if it started after the implementation's update, this doesn't
  # sound (distinguishes it from a check that always sounds).
  printf '{"schema":"%s","ts":"%s","event":"watch_started","detail":"cwd=%s pid=%s started_at=%s version=0.0.0","generation":null,"predecessor_session_id":null,"successor_session_id":null}\n' \
    "$REIN_LOG_SCHEMA" "$(rein_iso_now)" "$proj4" "$REIN_ST_WATCHER_PID" "$(rein_iso_now)" \
    >"$doctor_log"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_contains "says OK when started on the current implementation" "OK   the resident watcher started with the current implementation"
  rein_st_stop_fake_watcher "$doctor_runtime"
  rm -f "$doctor_log"

  # A lineage's key is built with shasum, so if it's missing, the location itself can't even
  # be resolved. **Surfaces this as a missing tool** ("cannot resolve the runtime data
  # location" would be a reason unrelated to the actual cause).
  st_doctor_case_env
  broken_bin="$tmp/broken-shasum"
  rein_st_write_broken_tool "$broken_bin" shasum
  ST_VERB_ENV[0]="PATH=${broken_bin}:${home4}/.local/bin:${verb_bin}:$(st_path_without_rein)"
  ST_VERB_ENV+=("XDG_CONFIG_HOME=$home4/.config" "XDG_STATE_HOME=$home4/.local/state")
  st_run_env --cwd "$proj4" doctor
  # This rejection actually comes from the generic gate in base.sh (prepare_runtime checks the
  # prerequisites first), never reaching doctor's own prerequisite-tools FAIL line. The two share
  # one phrase by design, so this check doesn't depend on which of them fired.
  st_expect_reject "surfaces a missing shasum as a missing prerequisite tool" 1 "prerequisite tools don't work"
  st_expect_contains "names the missing tool" "shasum"

  # The same, for the tool the lineage token is drawn with. Without `od` on the list, this
  # machine passes every check here and only fails much later, when a lineage is provisioned --
  # as "cannot draw a lineage token", after which every hook of every session of that lineage
  # fails loud on the missing token. Pinned separately from the OK line's literal, so dropping
  # the tool from the check is caught even if the literal is edited to match.
  st_doctor_case_env
  broken_bin="$tmp/broken-od"
  rein_st_write_broken_tool "$broken_bin" od
  ST_VERB_ENV[0]="PATH=${broken_bin}:${home4}/.local/bin:${verb_bin}:$(st_path_without_rein)"
  ST_VERB_ENV+=("XDG_CONFIG_HOME=$home4/.config" "XDG_STATE_HOME=$home4/.local/state")
  st_run_env --cwd "$proj4" doctor
  # The needle carries the phrase and the name together -- `od` on its own is two characters that
  # appear inside ordinary words in this output.
  st_expect_reject "surfaces a broken od as a missing prerequisite tool" 1 "prerequisite tools don't work: od"

  # Quoting for **the ready-to-run commands** embedded in advice. This file's own comments say
  # "make advice something this lineage can paste and run as-is" -- these are lines meant to be
  # pasted and run, not just display paths. Embedding a bare path that contains whitespace,
  # `;`, `$( )`, or a single quote would split into words where it's pasted, and `$( )` would
  # be evaluated as command substitution. A literal cross-check alone can't measure **how a shell
  # would split the words** -- so this extracts the command out of the advice text and actually
  # expands it, checking both argv and a canary.
  # The execution paths (kickoff, the Stop hook's injection, rein request's advice) are already
  # quoted -- untouched here.
  st_doctor_case_env
  r16_proj="$tmp/r16 a b;\$(touch $tmp/r16-pwned)'q"
  mkdir -p "$r16_proj"
  r16_proj="$(cd "$r16_proj" && pwd -P)"
  r16_runtime="$root4/$REIN_ROOT_STATE_RELDIR/$(rein_cwd_key "$r16_proj")"
  mkdir -p "$r16_runtime/$REIN_PROCESSING_DIRNAME"
  printf '{}\n' >"$r16_runtime/$REIN_PROCESSING_DIRNAME/orphan.json"
  rm -f "$home4/.local/bin/rein"
  st_run_env --root "$root4" --cwd "$r16_proj" doctor
  # Builds a copy with a trailing newline added, to extract advice that ends at end of line
  # (command substitution drops a trailing newline, so the last line's advice couldn't be cut
  # out -- there would be no closing boundary to find).
  r16_out="${ST_OUT}"$'\n'
  st_expect_not_contains "never embeds an unquoted cwd in advice" "--cwd ${r16_proj}"
  # This section runs with **installation removed** (the rm just above), so the advice's
  # display name is the real file path -- never pastes a bare `rein` before it's on PATH (both
  # sides of the naming are pinned by the PATH section).
  st_expect_contains "quotes the reclaim advice" \
    "$(rein_shell_quote "$REIN_BIN_PATH") --root $(rein_shell_quote "$root4") --cwd $(rein_shell_quote "$r16_proj") up"
  st_expect_argv "the reclaim advice is passed word by word" "$r16_out" \
    "recovers them to rejected at startup: " $'\n' \
    "$REIN_BIN_PATH" --root "$root4" --cwd "$r16_proj" up
  st_expect_contains "quotes the advice to place the owner record" \
    "To create one: $(rein_shell_quote "$REIN_BIN_PATH") --root $(rein_shell_quote "$root4") --cwd $(rein_shell_quote "$r16_proj") init"
  # The tail marker can't be a bare ")" -- the injected fixture path's own `$(touch ...)` closes
  # with a paren too, and st_slice_between matches the first occurrence (the fixture's, cutting
  # the command short before it). What actually follows the real command here is "): " (doctor_warn's
  # own closing paren, then the runtime dir), a sequence the fixture never produces, so it's used
  # as the anchor instead.
  st_expect_argv "the advice to place the owner record is passed word by word" "$r16_out" \
    "To create one: " "): " \
    "$REIN_BIN_PATH" --root "$root4" --cwd "$r16_proj" init
  st_expect_contains "quotes the install advice" \
    "install it: $(rein_shell_quote "$REIN_BIN_PATH") --root $(rein_shell_quote "$root4") --cwd $(rein_shell_quote "$r16_proj") init"
  st_expect_argv "the install advice is passed word by word" "$r16_out" \
    "install it: " ". To place it by hand" \
    "$REIN_BIN_PATH" --root "$root4" --cwd "$r16_proj" init
  st_expect_contains "quotes the place-it-by-hand advice" \
    "To place it by hand: ln -s $(rein_shell_quote "$REIN_BIN_PATH") $(rein_shell_quote "$home4/.local/bin/rein")"
  st_expect_argv "the place-it-by-hand advice is passed word by word" "$r16_out" \
    "To place it by hand: " ")" \
    ln -s "$REIN_BIN_PATH" "$home4/.local/bin/rein"
  st_expect_true "never lets advice get evaluated as command substitution" test ! -e "$tmp/r16-pwned"
  rm -rf "${r16_runtime:?}"

  # For the same metacharacter-laden path, the **2 remaining pieces of advice** are also
  # checked by argv and canary. These 2 are only ever watched by `st_expect_contains`, and its
  # expected value is derived from `rein_shell_quote` -- if the quoting implementation broke,
  # the needle would break by exactly the same amount, and production and the check would
  # drift together and still pass green (the check on that constant becomes a tautology). argv
  # cross-checks against a **literal**, unrelated to that function.
  r16_records="$root4/$REIN_ROOT_RECORDS_RELDIR/$(rein_cwd_key "$r16_proj")"
  mkdir -p "$r16_records"
  rein_st_write_pointer "$r16_records/$REIN_POINTER_BASENAME" "succ-doc" "successor" "$r16_proj" 2 "pred-doc"
  # A shape where only the handover's final step remains (both the successor and the
  # predecessor session are alive, and there's no watcher).
  rein_st_write_agents "$tmp/r16-agents.json" "$r16_proj" "succ-doc" "pred-doc"
  ST_VERB_ENV+=("FAKE_AGENTS=$tmp/r16-agents.json")
  st_run_env --root "$root4" --cwd "$r16_proj" doctor
  r16_out="${ST_OUT}"$'\n'
  st_expect_contains "quotes the resume advice" \
    "resumes it at startup: $(rein_shell_quote "$REIN_BIN_PATH") --root $(rein_shell_quote "$root4") --cwd $(rein_shell_quote "$r16_proj") up"
  st_expect_argv "the resume advice is passed word by word" "$r16_out" \
    "resumes it at startup: " $'\n' \
    "$REIN_BIN_PATH" --root "$root4" --cwd "$r16_proj" up
  st_expect_true "never lets the resume advice get evaluated as command substitution" test ! -e "$tmp/r16-pwned"

  # The fix for a shape where only one side of the handover died (one sentence shared by
  # watcher, doctor, and status). This is only ever watched by `st_expect_contains`, and it
  # **had no quoting at all** (the cwd was embedded bare) -- at a location containing
  # metacharacters, pasting and running it as advised either splits words or evaluates `$( )`.
  # Measured by argv and canary, not just literal text.
  rein_st_write_agents "$tmp/r16-agents.json" "$r16_proj" "pred-doc"
  st_run_env --root "$root4" --cwd "$r16_proj" doctor
  r16_out="${ST_OUT}"$'\n'
  # This one sentence is built by **the shared library** (the one function watcher, doctor, and
  # status all go through), but the display name is passed in by the caller -- so doctor's own
  # naming choice (the real file path on a not-installed machine) shows up here too. **This
  # pins that the naming never mixes within one single output** (this one sentence used to be
  # the only bare `rein` while every other piece of advice used the real file path).
  st_expect_contains "quotes the resume line in the fix" \
    "(2) Running $(rein_shell_quote "$REIN_BIN_PATH") --root $(rein_shell_quote "$root4") --cwd $(rein_shell_quote "$r16_proj") up launches a new primary session"
  st_expect_argv "the resume line in the fix is passed word by word" "$r16_out" \
    "(2) Running " " launches a new primary session" \
    "$REIN_BIN_PATH" --root "$root4" --cwd "$r16_proj" up
  st_expect_contains "quotes the last-resort line in the fix" \
    "redo $(rein_shell_quote "$REIN_BIN_PATH") --root $(rein_shell_quote "$root4") --cwd $(rein_shell_quote "$r16_proj") init as a last resort"
  st_expect_argv "the last-resort line in the fix is passed word by word" "$r16_out" \
    "redo " " as a last resort" \
    "$REIN_BIN_PATH" --root "$root4" --cwd "$r16_proj" init
  st_expect_true "never lets the fix's advice get evaluated as command substitution" test ! -e "$tmp/r16-pwned"
  rein_st_write_agents "$tmp/r16-agents.json" "$r16_proj" "succ-doc" "pred-doc"

  # Advice for a resident watcher still running the code it started with. A compound command
  # chaining 4 values with `&&`, the shape of the 10 most likely to break on paste, yet
  # unmeasured by either argv or canary. `eval` runs the `&&` right on the spot, so this splits
  # the extraction into 3 rounds and checks argv on each piece.
  rein_st_start_fake_watcher "$r16_runtime" "$r16_proj"
  printf '{"schema":"%s","ts":"%s","event":"watch_started","detail":"cwd=%s pid=%s started_at=%s version=0.0.0","generation":null,"predecessor_session_id":null,"successor_session_id":null}\n' \
    "$REIN_LOG_SCHEMA" "2020-01-01T00:00:00Z" "$r16_proj" "$REIN_ST_WATCHER_PID" "2020-01-01T00:00:00Z" \
    >"$r16_records/$REIN_LOG_BASENAME"
  st_run_env --root "$root4" --cwd "$r16_proj" doctor
  r16_out="${ST_OUT}"$'\n'
  st_expect_contains "quotes the reinstall advice" \
    "reinstall this lineage: $(rein_shell_quote "$REIN_BIN_PATH") --root $(rein_shell_quote "$root4") --cwd $(rein_shell_quote "$r16_proj") down && git -C $(rein_shell_quote "$REPO_ROOT") pull"
  st_expect_argv "the reinstall advice's 1st stage is passed word by word" "$r16_out" \
    "reinstall this lineage: " " && git" \
    "$REIN_BIN_PATH" --root "$root4" --cwd "$r16_proj" down
  st_expect_argv "the reinstall advice's 2nd stage is passed word by word" "$r16_out" \
    "down && " " && claude" \
    git -C "$REPO_ROOT" pull
  st_expect_argv "the reinstall advice's 4th stage is passed word by word" "$r16_out" \
    "update rein@claude-rein && " $'\n' \
    "$REIN_BIN_PATH" --root "$root4" --cwd "$r16_proj" up
  st_expect_true "never lets the reinstall advice get evaluated as command substitution" test ! -e "$tmp/r16-pwned"
  rein_st_stop_fake_watcher "$r16_runtime"
  rm -rf "${r16_runtime:?}" "${r16_records:?}"

  st_doctor_case_env
}
