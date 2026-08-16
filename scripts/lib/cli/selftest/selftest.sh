# shellcheck shell=bash
# The body of `rein --selftest`. Sources each section's file and calls them in the section
# table's order.
# bin/rein sources this only when invoked with `--selftest` (an ordinary launch never reads this much).
# Not an executable script, so it carries no execute bit (out of scope for the --selftest convention).
# shellcheck source-path=SCRIPTDIR
# shellcheck source=./helpers.sh
. "$SCRIPTS_DIR/lib/cli/selftest/helpers.sh"
# The shared fixtures and section selection are loaded here. Sourcing them inside a section would
# break any round that skips that section: a later section would then call an undefined function
# (the entry point that selects and runs sections would no longer hold together).
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../rein-selftest-fixtures.sh
. "$SCRIPTS_DIR/lib/rein-selftest-fixtures.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../rein-selftest-sections.sh
. "$SCRIPTS_DIR/lib/rein-selftest-sections.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=./sections.sh
. "$SCRIPTS_DIR/lib/cli/selftest/sections.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=./config.sh
. "$SCRIPTS_DIR/lib/cli/selftest/config.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=./aliases.sh
. "$SCRIPTS_DIR/lib/cli/selftest/aliases.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=./delegation.sh
. "$SCRIPTS_DIR/lib/cli/selftest/delegation.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=./verbs.sh
. "$SCRIPTS_DIR/lib/cli/selftest/verbs.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=./prune.sh
. "$SCRIPTS_DIR/lib/cli/selftest/prune.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=./doctor.sh
. "$SCRIPTS_DIR/lib/cli/selftest/doctor.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=./fire-log.sh
. "$SCRIPTS_DIR/lib/cli/selftest/fire-log.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=./managed-settings.sh
. "$SCRIPTS_DIR/lib/cli/selftest/managed-settings.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=./init.sh
. "$SCRIPTS_DIR/lib/cli/selftest/init.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=./root.sh
. "$SCRIPTS_DIR/lib/cli/selftest/root.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=./clock.sh
. "$SCRIPTS_DIR/lib/cli/selftest/clock.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=./atomic-write.sh
. "$SCRIPTS_DIR/lib/cli/selftest/atomic-write.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=./common-contracts.sh
. "$SCRIPTS_DIR/lib/cli/selftest/common-contracts.sh"

# The section table (its order is the run order). What each layer means lives at the top of lib/rein-selftest-sections.sh.
rein_st_section_table() {
  cat <<'EOF'
pure:sections st_section_sections
pure:clock st_section_clock
pure:atomic-write st_section_atomic_write
pure:config st_section_config
pure:aliases st_section_aliases
pure:common-contracts st_section_common_contracts
proc:delegation st_section_delegation
proc:verbs st_section_verbs
proc:prune st_section_prune
proc:doctor st_section_doctor
proc:fire-log st_section_fire_log
proc:managed-settings st_section_managed_settings
proc:init st_section_init
proc:root st_section_root
EOF
}

selftest() {
  local tmp proj root key env_name expected_env count marker st_snapshot
  local user_config project_config outside_config outside_state ambient_user_config
  local ambient_before secret line_count help_usage_out key_count
  local help_layout help_layout_align help_layout_desc help_layout_count
  local alias_line alias_scope alias_rest alias_short alias_long
  local alias_verb_shorts alias_all_shorts alias_missing alias_dup alias_seen
  local alias_unlisted alias_version_out alias_help_out alias_help_missing
  local alias_all_out alias_prune_out
  local default_handoff root_handoff init_handoff_path status_handoff_path
  local allow_proj allow_config allow_ledger
  # The section files share selftest's locals through dynamic scope. Some variables are used
  # across sections, so they're declared here rather than inside a section (a declaration inside
  # a section function wouldn't be visible from the next section).
  local proj2 root2 runtime2 verb_bin verb_agents verb_log legacy pid_before pid_after
  local fake_runtime seat_dir seat_pid snooze_file slow_runtime
  local attach_runtime attach_bg attach_found attach_wait attach_snapshot
  local proj3 root3 runtime3 orphan_dir alive_dir plain_dir archive_dir agents3 log3
  local state3 pointer3 stranded_dir notkey_dir generic_dir unreadable_dir dotted_dir
  local inject_victim inject_dir unknown_dir locked_dir
  local proj4 root4 home4
  local records2
  local health_dir leftover_settings nested_child
  local hook_shape_repo hook_shape_saved hook_shape_rc
  local launcher_exec_repo launcher_exec_saved launcher_exec_rc
  local fire_log4 fire_at_old
  local init_home init_link init_calls usage_state broken_bin
  local init_kept
  local seat_lock seat_runtime reclaim_lock reclaim_rc doctor_runtime doctor_owner_rc
  local init_no_claude_env init_run_rc
  local dual_proj dual_root dual_state dual_key dual_default_records dual_root_records
  local dual_before dual_after
  local iso oracle mine
  local aw_final aw_before aw_err aw_rc

  rein_st_sections_parse "$@" || return $?
  if [ "$REIN_ST_SECTION_MODE" = "list" ]; then
    rein_st_sections_print_list
    return 0
  fi

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/rein-cli-selftest.XXXXXX")" || {
    printf '%s: selftest 0 pass / 1 fail\n' "$SCRIPT_NAME"
    return 1
  }
  ST_TMPDIR="$tmp"
  trap st_cleanup EXIT
  # A delegate records cwd as an absolute, symlink-resolved path, so the expected value has to
  # be put in the same form too -- otherwise it would differ by exactly the temp directory's
  # parent (/var vs. /private/var).
  tmp="$(cd "$tmp" && pwd -P)"
  ST_BASH="$REIN_ST_BASH"

  # If a REIN_* variable is present in the launching environment, a check that looks at where the
  # default comes from would swing with the environment layer's value. And if an isolation
  # interface (REIN_CONFIG_FILE etc.) is left set, the check would go on to write to the real
  # config. This strips not just the known keys but also the isolation interfaces sitting outside
  # the key set.
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    rein_config_lookup "$key" || continue
    export -n "REIN_${REIN_CFG_KEY_UPPER}" 2>/dev/null
  done <<EOF
$(rein_config_keys)
EOF
  export -n REIN_CONFIG_FILE REIN_RUNTIME_DIR REIN_RECORDS_ROOT 2>/dev/null
  # A check that runs all the way through delegation starts the real rein-seat.sh /
  # rein-request.sh. If that enters the notification path, a GUI notification shows up on the
  # user's own screen, so this silences it across every child process this check starts (the
  # one line to stderr still remains, so the fact that a notification fired is still observable
  # from the check).
  export REIN_NOTIFY_SILENT=1

  proj="$tmp/proj"
  root="$tmp/root"
  mkdir -p "$proj"
  user_config="$root/config/rein/config"
  project_config="$proj/.rein/config"
  # "Outside root" -- used as a counterexample for isolation. No path that goes through --root
  # is allowed to touch this.
  outside_config="$tmp/outside/config"
  outside_state="$tmp/outside/state"
  mkdir -p "$tmp/outside"
  printf 'threshold_notice=7\n' >"$outside_config"
  ambient_user_config="${XDG_CONFIG_HOME:-${HOME:-}/.config}/rein/config" # home-base-exempt: computes "what to protect" for measuring whether the check actually touches the real settings file -- where no location is configured, there is nothing to protect in the first place
  ambient_before="absent"
  if [ -e "$ambient_user_config" ]; then
    ambient_before="$(shasum -a 256 "$ambient_user_config" | cut -d' ' -f1)"
  fi

  # The groundwork several sections build on is assembled here so every section can run on its
  # own. Assembling it inside a section would break any round that skips that section: a later
  # section could no longer pick up what the earlier one left behind, and would fail.
  mkdir -p "$proj/.rein"
  : >"$tmp/empty-user-config"
  : >"$tmp/notify.log"
  # Since some sections run delegation for a handover request, the groundwork's canonical form is
  # built to match the template's section structure.
  rein_st_write_handoff "$tmp/handoff.md"
  verb_bin="$tmp/verb-bin"
  verb_log="$tmp/verb-claude.log"
  rein_st_write_fake_bin "$verb_bin"
  : >"$verb_log"

  rein_st_sections_run

  # Confirm the check never touched the real config (this breaks if a path that skips --root sneaks in).
  if [ "$ambient_before" = "absent" ]; then
    st_expect_true "creates no real config" test ! -e "$ambient_user_config"
  else
    st_expect_true "doesn't rewrite the real config" \
      test "$(shasum -a 256 "$ambient_user_config" | cut -d' ' -f1)" = "$ambient_before"
  fi
  st_expect_file "doesn't rewrite a config outside root" "$outside_config" "threshold_notice=7"
  st_expect_true "creates no state outside root" test ! -e "$outside_state"

  # Cleanup is part of what this checks too. Leaving it to the EXIT trap alone would print a
  # failed round's stderr **after** the summary line, tripping check.sh's verification that the
  # final line follows the selftest contract's format (the checks themselves all pass, yet the
  # gate alone fails). This confirms everything actually stopped and was actually removed before
  # printing the summary.
  rein_st_stop_all_fake_watchers
  st_stop_watchers
  # The match is done within the captured listing (piping to grep would have that grep's own
  # command line show up in the same listing and always match -- turning this into a check that
  # counts itself).
  st_snapshot="$(rein_ps_snapshot)"
  case "$st_snapshot" in
    *"rein-watcher.sh --cwd ${tmp}"*)
      st_fail "stops every watcher this check started" "a watcher that didn't fully stop is still around"
      ;;
    *) st_ok ;;
  esac
  rm -rf "$ST_TMPDIR"
  st_expect_true "leaves no temp directory behind" test ! -e "$ST_TMPDIR"
  ST_TMPDIR=""

  printf '%s: selftest %d pass / %d fail\n' "$SCRIPT_NAME" "$st_pass_count" "$st_fail_count"
  [ "$st_fail_count" -eq 0 ]
}
