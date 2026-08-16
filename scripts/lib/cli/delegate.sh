# shellcheck shell=bash
# The shared path for delegating to existing scripts (request / attach / bootstrap).
# Not an executable script, so it doesn't get the execute bit (out of scope for the --selftest convention).

# Reads and validates config fully before delegating. A broken config makes the delegate fail
# for the same reason, but failing here first tells the user which command failed.
# **Never puts the effective values into environment variables** -- the delegate reads its own
# config layer (the watcher does so every loop), so baking startup values into the environment
# would let the environment layer permanently outrank the file layer for later re-reads.
prepare_delegation() {
  cli_rein_cmd
  rein_config_resolve_files "$CLI_REIN_CMD" "$TARGET_CWD"
  if ! rein_config_load_files; then
    fail "$REIN_CONFIG_ERROR"
    return 1
  fi
  if ! rein_config_check_cross_fields; then
    fail "$REIN_CONFIG_ERROR"
    return 1
  fi
  return 0
}

# Delegates to an existing script. Puts the resolved --cwd first and streams the user's own
# arguments after it (a repeated flag later wins, so the user's own value takes precedence --
# this keeps the current parsing behavior).
delegate() {
  local script="$1"
  shift
  if [ ! -x "$script" ]; then
    fail "cannot execute the delegate: ${script}"
    return 1
  fi
  prepare_delegation || return $?
  exec "$script" "$@"
}
