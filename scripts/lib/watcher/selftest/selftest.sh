# shellcheck shell=bash
# The body of `rein-watcher.sh --selftest`. Sources the per-section files and runs them in the order given by the section table.
# Sourced only when rein-watcher.sh runs `--selftest` (the resident watcher never loads this much code).
# Not an executable script, so it carries no execute bit (outside the --selftest convention).
# shellcheck source-path=SCRIPTDIR
# shellcheck source=./helpers.sh
. "$SCRIPT_DIR/lib/watcher/selftest/helpers.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../rein-selftest-sections.sh
. "$SCRIPT_DIR/lib/rein-selftest-sections.sh"
# Shared fixtures are loaded when this file is sourced (production never sources this file, so it
# adds no dependency on test-only files). The real claude / osascript binaries are never launched;
# a shim ahead of them on PATH records the arguments and plays out the branch. Fixture teardown is
# called from cleanup (st_cleanup), so sections never source it themselves.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../rein-selftest-fixtures.sh
. "$SCRIPT_DIR/lib/rein-selftest-fixtures.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=./handover.sh
. "$SCRIPT_DIR/lib/watcher/selftest/handover.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=./final-output.sh
. "$SCRIPT_DIR/lib/watcher/selftest/final-output.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=./freshness.sh
. "$SCRIPT_DIR/lib/watcher/selftest/freshness.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=./successor.sh
. "$SCRIPT_DIR/lib/watcher/selftest/successor.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=./settings.sh
. "$SCRIPT_DIR/lib/watcher/selftest/settings.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=./marker.sh
. "$SCRIPT_DIR/lib/watcher/selftest/marker.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=./bootstrap.sh
. "$SCRIPT_DIR/lib/watcher/selftest/bootstrap.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=./startup.sh
. "$SCRIPT_DIR/lib/watcher/selftest/startup.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=./failures.sh
. "$SCRIPT_DIR/lib/watcher/selftest/failures.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=./lock.sh
. "$SCRIPT_DIR/lib/watcher/selftest/lock.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=./placement.sh
. "$SCRIPT_DIR/lib/watcher/selftest/placement.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=./records.sh
. "$SCRIPT_DIR/lib/watcher/selftest/records.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=./timing.sh
. "$SCRIPT_DIR/lib/watcher/selftest/timing.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=./argv.sh
. "$SCRIPT_DIR/lib/watcher/selftest/argv.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=./exit.sh
. "$SCRIPT_DIR/lib/watcher/selftest/exit.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=./config.sh
. "$SCRIPT_DIR/lib/watcher/selftest/config.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=./stop-request.sh
. "$SCRIPT_DIR/lib/watcher/selftest/stop-request.sh"

# The section table (order is execution order). What the tier prefix means is documented at the
# top of lib/rein-selftest-sections.sh. Every watcher section spawns a real watcher process, so
# every tier here is proc (that they never split into a lighter tier is itself the readable
# signal that this suite has no light section).
rein_st_section_table() {
  cat <<'EOF'
proc:handover st_section_handover
proc:final-output st_section_final_output
proc:freshness st_section_freshness
proc:successor st_section_successor
proc:settings st_section_settings
proc:marker st_section_marker
proc:bootstrap st_section_bootstrap
proc:startup st_section_startup
proc:failures st_section_failures
proc:lock st_section_lock
proc:placement st_section_placement
proc:records st_section_records
proc:timing st_section_timing
proc:argv st_section_argv
proc:exit st_section_exit
proc:config st_section_config
proc:stop-request st_section_stop_request
EOF
}

selftest() {
  local tmp case_dir kickoff_line daemon_rc tool hb_first hb_pointer bg_call st_default_handoff
  local grace_started grace_elapsed grace_interval grace_limit
  local marker_epoch request_line quoted_argv expected_argv probe_out request_rc
  local fo_started fo_elapsed fo_archived
  # Section files share this function's locals through dynamic scope. Some variables cross
  # section boundaries, so they're declared here rather than inside a section (declaring one
  # inside a section's own function would hide it from later sections).
  local settings_file settings_json st_seat_log_leak hb_probe records_outside records_outside_before

  rein_st_sections_parse "$@" || return $?
  if [ "$REIN_ST_SECTION_MODE" = "list" ]; then
    rein_st_sections_print_list
    return 0
  fi

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/rein-watcher-selftest.XXXXXX")" || {
    printf '%s: selftest 0 pass / 1 fail\n' "$SCRIPT_NAME"
    return 1
  }
  ST_TMPDIR="$tmp"
  trap st_cleanup EXIT

  ST_BIN="$tmp/bin"
  rein_st_write_fake_bin "$ST_BIN"
  # The launch-argument order is `--bg --name <name> --settings <launch settings> [--model <value>] <kickoff>`.
  # `--settings` is always present (rein attaches a temp file carrying worktree-isolation disabled
  # plus the managed marker).
  ST_BG_ARGC_BASE=6
  ST_ENV_EXTRA=()
  # The default is a single scan. Only the cases that watch resident behavior override this array.
  ST_MODE_ARGS=(--once)

  # Sections build an independent working directory per case (st_setup_case), so this just runs
  # them in table order.
  rein_st_sections_run

  # The attach loop is the only writer of the seat's own log. **From the writer side**, this pins
  # that no watcher test run ever creates such a log (with two writers on one file, once the lines
  # interleave there is no way to recover afterward which mechanism a given line came from).
  st_seat_log_leak="$(find "$tmp" -name "$REIN_SEAT_LOG_BASENAME" -print)"
  if [ -z "$st_seat_log_leak" ]; then
    st_ok
  else
    st_fail "the watcher does not write the seat's log" "$st_seat_log_leak"
  fi

  printf '%s: selftest %d pass / %d fail\n' "$SCRIPT_NAME" "$st_pass_count" "$st_fail_count"
  [ "$st_fail_count" -eq 0 ]
}
