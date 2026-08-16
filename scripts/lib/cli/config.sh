# shellcheck shell=bash
# Implementation of `rein config` (reading and writing settings).
# Not an executable script, so it doesn't get the execute bit (out of scope for the --selftest convention).

# The project settings decision (`allow` -- let it take effect / `deny` -- proceed without
# applying it).
# **Show what's being decided before recording it** -- `.rein/` isn't a location the user has
# a habit of checking, so the decision operation itself doubles as showing the content.
# Only the allow side **confirms the content is valid before recording** (closing off the case
# where the allow succeeds but the very next verb fails on an unknown key). The deny side
# never confirms this -- content that won't be applied doesn't need to be valid, and "using a
# clone that bundles broken settings, without applying those settings" is exactly what this
# verb is for.
# Never stays silent about a substitution. Letting a substituted display be read as the raw
# content would make the decision's consent rest on what was shown rather than on what was
# actually there. A control character in the setting is itself an anomalous
# signal, so that gets a line too.
# Prints exactly one line per decision. Printing at every exit point would duplicate the same
# line, since the validity check's reason text is built from the content already shown on
# screen -- the same substitution would happen twice.
CONFIG_DECISION_ESCAPE_ANNOUNCED=0
config_decision_escape_notice() {
  [ "$REIN_CONFIG_SHOWN_ESCAPED" -eq 1 ] || return 0
  [ "$CONFIG_DECISION_ESCAPE_ANNOUNCED" -eq 0 ] || return 0
  CONFIG_DECISION_ESCAPE_ANNOUNCED=1
  printf 'note: this contained control characters, so they were replaced with ^-prefixed notation before printing (printing them as-is could spoof what the screen shows)\n'
}

# A failure's line also carries config-derived bytes (the validity check's reason text
# includes the key or value verbatim). Runs visibility substitution before handing it to
# `fail`, and announces it right there if a substitution happened.
config_decision_fail() {
  rein_config_visible_reason "$1"
  config_decision_escape_notice
  fail "$REIN_CONFIG_VISIBLE_REASON"
}

cmd_config_decision() {
  local decision="$1" file rc real
  shift
  if [ $# -ne 0 ]; then
    fail_usage "config ${decision} takes no arguments: $1"
    return 2
  fi
  # The substitution marker is carried only within this one decision (never inherited from a
  # previous verb's run).
  REIN_CONFIG_SHOWN_ESCAPED=0
  CONFIG_DECISION_ESCAPE_ANNOUNCED=0
  file="$REIN_CONFIG_PROJECT_FILE"
  if [ ! -e "$file" ]; then
    # Settling for "does not exist" on a broken symlink would conflict with how the allow
    # gate names it (the gate stops on "the location is a broken symbolic link").
    if [ -L "$file" ]; then
      config_decision_fail "the project settings are a broken symbolic link (the target does not exist, so there is nothing to decide): ${file}"
    else
      config_decision_fail "there are no project settings (nothing to decide): ${file}"
    fi
    return 1
  fi
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    config_decision_fail "cannot read the project settings: ${file}"
    return 1
  fi
  rein_config_project_allowed
  rc=$?
  if [ "$rc" -eq 2 ]; then
    config_decision_fail "$REIN_PROJECT_ALLOW_ERROR"
    return 1
  fi
  if [ "$decision" = "allow" ] && [ "$rc" -eq 0 ]; then
    rein_config_show_line 'already allowed (the content has not changed either): ' "$file"
    config_decision_escape_notice
    return 0
  fi
  if [ "$decision" = "deny" ] && [ "$rc" -eq 3 ]; then
    rein_config_show_line 'already decided against applying (the content has not changed either): ' "$file"
    config_decision_escape_notice
    return 0
  fi
  if [ "$decision" = "allow" ]; then
    rein_config_show_line 'allow target: ' "$file"
  else
    rein_config_show_line 'target to decide against applying: ' "$file"
  fi
  # If the location is a symlink, **also show what it resolves to**. A decision is a judgment
  # of whether this content may take effect, so it cannot be confirmed without showing which
  # real file is being looked at (it can be outside the project) -- the write also targets that
  # real file. The target's file name **can be chosen by whoever bundled it**, so this line
  # goes through the same visibility substitution as the content lines (it prints before the
  # content, so passing it through unfiltered could erase every line after it from the
  # screen).
  if [ -L "$file" ] && real="$(rein_config_real_path "$file")"; then
    rein_config_show_line 'resolves to: ' "$real"
  fi
  if [ -n "$REIN_PROJECT_ALLOW_REASON" ]; then
    rein_config_show_line 'current state: ' "$REIN_PROJECT_ALLOW_REASON"
  fi
  # The content is printed **without reopening it**. Reopening here could let the content the
  # allow judgment digested, the content shown on screen, and the digest recorded in the
  # ledger become three different sets of bytes (observed: in 18 of 60 runs, a digest of
  # content different from what was shown on screen was recorded as `allow` -- content that
  # was never actually shown got allowed).
  printf 'content:\n'
  rein_config_project_print_lines '  '
  # Truncation isn't kept silent either. Even without a single control character, line count
  # and length can push an important line off the screen -- the same result as removing a
  # line from the display -- so how many of how many lines were shown is included.
  if [ "$REIN_CONFIG_PROJECT_PRINT_SHOWN" -lt "$REIN_CONFIG_PROJECT_PRINT_TOTAL" ]; then
    printf 'note: the content has %s lines, so only the first %s are shown (the rest is not on screen -- open this file to see the whole thing)\n' \
      "$REIN_CONFIG_PROJECT_PRINT_TOTAL" "$REIN_CONFIG_PROJECT_PRINT_SHOWN"
  fi
  if [ "$REIN_CONFIG_PROJECT_PRINT_CLIPPED" -gt 0 ]; then
    printf 'note: %s lines were too long and got cut off partway (each line is shown up to %s characters)\n' \
      "$REIN_CONFIG_PROJECT_PRINT_CLIPPED" "$REIN_CONFIG_PRINT_MAX_COLS"
  fi
  config_decision_escape_notice
  if [ "$decision" = "allow" ] && ! rein_config_validate_project_file; then
    config_decision_fail "not allowing this, since it is not valid as a setting: ${REIN_CONFIG_ERROR}"
    return 1
  fi
  if ! rein_config_decision_record "$decision" "$file"; then
    config_decision_fail "$REIN_PROJECT_ALLOW_ERROR"
    return 1
  fi
  if [ "$decision" = "allow" ]; then
    rein_config_show_line 'this content is now allowed (recorded in: ' "${REIN_PROJECT_ALLOW_FILE})"
  else
    rein_config_show_line 'this content will not be applied (recorded in: ' "${REIN_PROJECT_ALLOW_FILE})"
  fi
  config_decision_escape_notice
  return 0
}

cmd_config() {
  local action="${1:-}" scope="project" rc load_error
  if [ $# -gt 0 ]; then
    shift
  fi
  case "$action" in
    get | set | unset | list | allow | deny) ;;
    '')
      fail_usage "specify a config subcommand (get / set / unset / list / allow / deny)"
      return 2
      ;;
    *)
      fail_usage "unknown config subcommand: ${action}"
      return 2
      ;;
  esac

  case "$action" in
    set | unset)
      while [ $# -gt 0 ]; do
        case "$1" in
          --user | -u)
            scope="user"
            shift
            ;;
          --project | -p)
            scope="project"
            shift
            ;;
          *)
            break
            ;;
        esac
      done
      ;;
  esac

  # The name used in guidance stays **the same throughout this one output** (the same discipline as doctor / status).
  cli_rein_cmd
  rein_config_resolve_files "$CLI_REIN_CMD" "$TARGET_CWD"
  # If the location's format is broken, fail here before reading any layers. The decision
  # verbs (allow / deny) never go through loading layers, so a check that lives only on the
  # layer side (rein_config_load_layers) would let **just the decision verbs pass through**,
  # letting a decision for a path containing a newline get written to the ledger.
  if [ -n "$REIN_CONFIG_RESOLVE_ERROR" ]; then
    fail "$REIN_CONFIG_RESOLVE_ERROR"
    return 1
  fi
  # A decision is processed **before** loading layers. Placed after, the very verb used to
  # allow (or deny) a not-yet-allowed project setting would fail because of that setting.
  if [ "$action" = "allow" ] || [ "$action" = "deny" ]; then
    cmd_config_decision "$action" "$@"
    return $?
  fi
  # **Reading the layers is never allowed to gate the verbs that repair them.** Cross-field
  # validity was already left out here for exactly that reason -- but the load below fails on a
  # single violation too (a value that doesn't fit its type, a key typed wrong), and that took
  # `set` / `unset` down with it: one bad line, and the only way back was to hand-edit the file,
  # which is the one thing these verbs exist to avoid. So the write verbs carry on past a failed
  # load, loudly.
  # **The read verbs (`get` / `list`) do not.** Their answer would be a value read out of a
  # state that doesn't hold; naming the reason instead *is* their correct answer.
  # This is not "write over a broken config in silence": rein_config_commit_scope re-reads every
  # layer against the candidate before replacing anything, so a rewrite that would leave the
  # result still broken is rolled back with its own reason.
  if ! rein_config_load_files; then
    load_error="$REIN_CONFIG_ERROR"
    case "$action" in
      set | unset) ;;
      *)
        fail "$load_error"
        return 1
        ;;
    esac
    # **The allow gate is not a content violation, and is never stepped over.** A load can fail
    # for two different reasons, and only one of them is "a value in a file is wrong": the other
    # is "this project file has not been decided on, or its location can't even be read." Writing
    # under that one would have this rewrite's own cleanup record an allow, turning on **every
    # other line bundled in the same file** -- the exact thing the decision verbs exist to
    # prevent. The judgment is the loader's own gate function, asked again rather than
    # reimplemented, so the two can't drift; an undecided project file has its own way out
    # (`config allow` / `config deny`, both of which run before any layer is read).
    if ! rein_config_gate_project; then
      fail "$REIN_CONFIG_ERROR"
      return 1
    fi
    warn "the settings cannot be read as they stand (${load_error}); continuing so this rewrite can repair them"
  fi
  # A project setting already decided against applying is never even a target for a rewrite.
  # Letting it be written would have the rewrite's cleanup (recording an allow) silently
  # override the deny, making **every other line bundled in the same file take effect too**
  # (the very thing that was denied, turned on by the user's own single-line rewrite).
  if [ "$scope" = "project" ]; then
    case "$action" in
      set | unset)
        rein_config_project_allowed
        rc=$?
        if [ "$rc" -eq 3 ]; then
          # The one line for re-deciding also names the lineage (the decision ledger lives
          # next to the user config -- dropping the naming would attach the allow to a
          # different ledger for a lineage whose location has moved). Built through one
          # shared function.
          if rein_config_lineage_cmd "$CLI_REIN_CMD" "$REIN_CONFIG_USER_FILE" "$TARGET_CWD" allow; then
            fail "this project setting is already decided against applying (to rewrite it, run ${REIN_LINEAGE_CMD} first): ${REIN_CONFIG_PROJECT_FILE}"
          else
            fail "this project setting is already decided against applying (${REIN_LINEAGE_ERROR}. Check the effective value for this lineage before deciding again): ${REIN_CONFIG_PROJECT_FILE}"
          fi
          return 1
        fi
        ;;
    esac
  fi

  case "$action" in
    list)
      if [ $# -ne 0 ]; then
        fail_usage "config list takes no arguments: $1"
        return 2
      fi
      if ! rein_config_list; then
        fail "$REIN_CONFIG_ERROR"
        return 1
      fi
      # Fail only after printing every value and origin (which file to fix cannot be told without seeing the whole listing).
      if ! rein_config_check_cross_fields; then
        fail "$REIN_CONFIG_ERROR"
        return 1
      fi
      return 0
      ;;
    get)
      if [ $# -ne 1 ]; then
        fail_usage "config get takes exactly one key"
        return 2
      fi
      if ! rein_config_get "$1"; then
        fail "$REIN_CONFIG_ERROR"
        return 2
      fi
      if ! rein_config_check_cross_fields; then
        fail "$REIN_CONFIG_ERROR"
        return 1
      fi
      return 0
      ;;
    set)
      if [ $# -ne 2 ]; then
        fail_usage "config set takes a key and a value (to fall back to the default, name the layer that holds the value: config unset --user <key> or config unset --project <key>)"
        return 2
      fi
      if ! rein_config_validate_value "$1" "$2"; then
        fail "$REIN_CONFIG_ERROR"
        return 2
      fi
      if ! rein_config_set "$scope" "$1" "$2"; then
        fail "$REIN_CONFIG_ERROR"
        return 1
      fi
      if [ -n "$REIN_CONFIG_WARNING" ]; then
        warn "$REIN_CONFIG_WARNING"
      fi
      return 0
      ;;
    unset)
      if [ $# -ne 1 ]; then
        fail_usage "config unset takes exactly one key"
        return 2
      fi
      # The known-keys check lives inside rein_config_unset, not here: an unknown key that is
      # literally on a line of the target file is a line the user can see and asked to delete
      # (the one repair path for a config with a mistyped key), and only a key that is neither
      # known nor present is a typo in the command. The two are kept apart by the exit code that
      # comes back -- 2 for the usage error, 1 for everything else.
      rein_config_unset "$scope" "$1"
      rc=$?
      if [ "$rc" -ne 0 ]; then
        fail "$REIN_CONFIG_ERROR"
        return "$rc"
      fi
      if [ -n "$REIN_CONFIG_WARNING" ]; then
        warn "$REIN_CONFIG_WARNING"
      fi
      return 0
      ;;
  esac
}
