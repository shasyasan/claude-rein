# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034  # selftest state is shared across sections (the caller selftest()'s locals, and the ST_* globals)
# How the launch settings handed to a successor are folded (layering rein's own values without
# discarding the consumer's own), and refusing to start where the organization managed settings
# force isolation to a different value.
# Variables are shared with the caller selftest()'s locals through dynamic scope. Declaring a
# local inside a section would hide it from later sections, so this section file declares none.
# Not an executable script, so it carries no execute bit (outside the --selftest convention).

st_section_settings() {
  # The consumer's own settings are passed through **layered, not discarded**. `--settings` given
  # twice has the later one win (measured), so appending rein's own settings after it isn't an
  # option -- they get folded into one object.
  case_dir="$tmp/settings"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  ST_ARGS=(--settings '{"env":{"USER_KEY":"user-value"},"worktree":{"other":"keep"}}')
  ST_EXIT_AFTER_POLLS=2
  # Plant one env in the config layer (to check, beyond the 3 known ones, that the whole REIN_
  # namespace is dropped at the launch boundary too). The value itself isn't used -- only "it
  # doesn't carry over to the successor" is observed.
  ST_ENV_EXTRA=("REIN_THRESHOLD_HANDOVER=35")
  st_run_watcher
  unset ST_ARGS ST_EXIT_AFTER_POLLS ST_ENV_EXTRA
  if st_expect_status "a handover with settings attached goes through" 0; then
    # Check the argument's position and count too (also catches --settings and its value collapsing into one argument).
    bg_call="$(rein_st_call_index "$ST_LOG" "--bg")"
    settings_file="$(rein_st_call_arg "$ST_LOG" "$bg_call" 5)"
    if [ "$bg_call" -ne 0 ] &&
      [ "$(rein_st_call_argc "$ST_LOG" "$bg_call")" -eq "$ST_BG_ARGC_BASE" ] &&
      [ "$(rein_st_call_arg "$ST_LOG" "$bg_call" 4)" = "--settings" ]; then
      st_ok
    else
      st_fail "the launch settings carry through to the successor's launch arguments" "the launch arguments weren't as expected: $(cat "$ST_LOG")"
    fi
    # The value **never appears on the command line** (settings can contain credentials -- keep it invisible to `ps`).
    case "$(cat "$ST_LOG")" in
      *user-value*)
        st_fail "never puts the settings value on the command line" "the value showed up in the launch arguments: $(cat "$ST_LOG")"
        ;;
      *) st_ok ;;
    esac
    # The launched session's hook deletes the real file (that deletion is what the watcher now
    # waits on), so the content is read from the copy the fake CLI takes at launch. What is
    # asserted here is unchanged: the file existed, with this content, at the moment it was handed
    # over.
    if [ -n "$settings_file" ] && [ -f "$ST_LOG.settings" ]; then
      st_ok
      settings_json="$(cat "$ST_LOG.settings")"
      # Check the managed marker's **set of names** for an exact match against the shared
      # library's own list (REIN_MANAGED_MARKER_ENVS). Listing them by hand and checking only
      # "it's present" would let the writer grow one more and this test would stay green, while
      # the rejecting side (selftest's own isolation check) silently fell behind an env it never
      # tracked -- the same hand-written list scattered across the writer, this test, and the
      # rejecting side was the actual gap. A set-equality check fails here no matter which of
      # writer or list changes first.
      marker_names_json="$(printf '%s\n' "${REIN_MANAGED_MARKER_ENVS[@]}" | jq -Rsc 'split("\n") | map(select(. != "")) | sort')"
      # (1) never discards the consumer's own values (2) forces isolation to none (3) the managed
      # marker's set of names matches, and (4) each value points at this lineage.
      # The token column is compared against **what the runtime directory actually holds**, read
      # through the shared reader. The value is drawn once when the lineage is provisioned, so
      # comparing against the file is what pins "the successor is handed this lineage's own
      # token" -- a check that only asked for some 64-character value would stay green if the
      # writer drew a fresh one per launch, which is exactly the shape that would make a
      # successor's hooks refuse the lineage they were launched for.
      if ! rein_read_runtime_token "$ST_RUNTIME"; then
        st_fail "the launch reads this lineage's token" "$REIN_RUNTIME_ERROR"
      elif printf '%s' "$settings_json" | jq -e \
        --argjson marker_names "$marker_names_json" \
        --arg k_managed "$REIN_MANAGED_ENV_NAME" --arg k_cwd "$REIN_MANAGED_CWD_ENV_NAME" \
        --arg k_runtime "$REIN_MANAGED_RUNTIME_ENV_NAME" --arg k_file "$REIN_MANAGED_SETTINGS_ENV_NAME" \
        --arg k_config "$REIN_MANAGED_CONFIG_ENV_NAME" --arg k_records "$REIN_MANAGED_RECORDS_ENV_NAME" \
        --arg k_token "$REIN_MANAGED_TOKEN_ENV_NAME" \
        --arg cwd "$ST_CWD" --arg runtime "$ST_RUNTIME" --arg file "$settings_file" \
        --arg config "$ST_USER_CONFIG" --arg records "$ST_CWD/$REIN_RECORDS_DIRNAME" \
        --arg token "$REIN_RUNTIME_TOKEN" '
          .env.USER_KEY == "user-value" and .worktree.other == "keep"
          and .worktree.bgIsolation == "none"
          and ((.env | keys | map(select(startswith("REIN_"))) | sort) == $marker_names)
          and .env[$k_managed] == "1" and .env[$k_cwd] == $cwd
          and .env[$k_runtime] == $runtime and .env[$k_file] == $file
          and .env[$k_config] == $config and .env[$k_records] == $records
          and .env[$k_token] == $token' >/dev/null 2>&1; then
        st_ok
      else
        st_fail "the launch settings carry both the consumer's values and the managed marker" \
          "expected REIN_ namespace key set=${marker_names_json} / actual=${settings_json}"
      fi
      # The token file itself is placed at 0600 -- a value other users on this machine could read
      # would no longer separate a marker rein issued from one a project's settings named.
      # (Whether the value stays put across generations is the separate case just below.)
      if [ "$(stat -f '%Lp' "$ST_RUNTIME/$REIN_TOKEN_BASENAME" 2>/dev/null)" = "600" ]; then
        st_ok
      else
        st_fail "places the lineage token at 0600" "$(stat -f '%Lp' "$ST_RUNTIME/$REIN_TOKEN_BASENAME" 2>/dev/null)"
      fi
      # Placed readable only by this user, since it can hold secrets. Read off the copy, which is
      # taken with the mode preserved (`cp -p`).
      if [ "$(stat -f '%Lp' "$ST_LOG.settings")" = "600" ]; then
        st_ok
      else
        st_fail "places the launch settings at 0600" "$(stat -f '%Lp' "$ST_LOG.settings")"
      fi
      # Placed inside this lineage's own runtime directory (never widen what cleanup has to reach outside the lineage).
      case "$settings_file" in
        "$ST_RUNTIME/$REIN_MANAGED_SETTINGS_PREFIX"*) st_ok ;;
        *) st_fail "places the launch settings inside the lineage's runtime directory" "$settings_file" ;;
      esac
      # The accepting side of the arrival check: the launched session's hook deletes the file, the
      # watcher sees it gone, and the round goes through. That deletion is the only observable
      # proof the managed marker actually reached the successor (the hook can only learn this path
      # from the marker), which is why the pointer is never advanced without it.
      if [ ! -e "$settings_file" ]; then
        st_ok
      else
        st_fail "lets the round through once the successor has deleted the launch settings" "$settings_file"
      fi
      # The dropping side and the carrying side, paired: the successor's process environment
      # carries none of the REIN_ namespace at all, and the managed context arrives solely
      # through the launch settings' env above (both checked in this one observation). Also check
      # that the same run's `agents` call does carry REIN_* -- otherwise this would trivially pass
      # by there being no environment at all (st_run_watcher always passes REIN_POLL_INTERVAL_SEC and the like).
      bg_env_names="$(rein_st_env_rein_names "$ST_LOG.env" bg)"
      agents_env_names="$(rein_st_env_rein_names "$ST_LOG.env" agents)"
      if [ -z "$bg_env_names" ] && [ -n "$agents_env_names" ]; then
        st_ok
      else
        st_fail "the successor's launch drops the whole REIN_ namespace" \
          "bg=[${bg_env_names}] agents=[${agents_env_names}]"
      fi
    else
      st_fail "the launch settings file gets created" "${settings_file:-(not in the arguments)}"
    fi
  fi

  # **The lineage token stays put across generations.** The successor launched above becomes the
  # predecessor of the next one, and its hooks are checked against the same runtime directory --
  # so a token redrawn per launch would leave every generation after the first holding a marker
  # its own hooks refuse, and the lineage would go silent with nothing but stderr inside a
  # session to say why.
  # This is the **2nd generation of the same lineage** (the case directory, and so the runtime
  # directory and the token in it, are kept). Only the session the current pointer names may
  # request a handover (R10), so the marker names the successor from the round above.
  # Both the previous round's launch log and its copy of the launch settings are cleared first:
  # reading a stale copy would compare the first round against itself and pass no matter what the
  # writer did. That the second round really launched is checked before the comparison, for the
  # same reason.
  settings_token_first="$(jq -r --arg k "$REIN_MANAGED_TOKEN_ENV_NAME" '.env[$k] // ""' "$ST_LOG.settings" 2>/dev/null)"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "succ-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  rein_st_write_agents "$ST_AGENTS" "$ST_CWD" "succ-1"
  : >"$ST_LOG"
  rm -f "$ST_LOG.settings" "$ST_LOG.agents"
  ST_EXIT_AFTER_POLLS=2
  ST_PRED_ID="succ-1"
  ST_SUCC_ID="succ-2"
  st_run_watcher
  unset ST_EXIT_AFTER_POLLS ST_PRED_ID ST_SUCC_ID
  settings_token_second="$(jq -r --arg k "$REIN_MANAGED_TOKEN_ENV_NAME" '.env[$k] // ""' "$ST_LOG.settings" 2>/dev/null)"
  if [ ! -f "$ST_LOG.settings" ]; then
    st_fail "the 2nd generation launches a successor of its own" \
      "no launch settings were handed over on the second round: $(cat "$ST_LOG")"
  elif [ -n "$settings_token_first" ] && [ "$settings_token_first" = "$settings_token_second" ]; then
    st_ok
  else
    st_fail "the successor of the successor is handed the same lineage token" \
      "first=[${settings_token_first}] second=[${settings_token_second}]"
  fi

  # A consumer settings value that isn't an object is **rejected outright, never coerced** (never launch while isolation is still supposedly in effect).
  case_dir="$tmp/settings-not-object"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  ST_ARGS=(--settings '[1,2]')
  ST_EXIT_AFTER_POLLS=2
  st_run_watcher
  unset ST_ARGS ST_EXIT_AFTER_POLLS
  if [ "$(rein_st_count_sub "$ST_LOG" "--bg")" -eq 0 ]; then
    st_ok
  else
    st_fail "never launches a successor when settings isn't an object" "claude --bg was called: $(cat "$ST_LOG")"
  fi

  # In an environment where the organization managed settings force isolation to a different value, fail before starting (never coerce it).
  case_dir="$tmp/managed-policy"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  printf '{"worktree":{"bgIsolation":"worktree"}}\n' >"$tmp/managed-policy.json"
  ST_ENV_EXTRA=("REIN_MANAGED_SETTINGS_POLICY=$tmp/managed-policy.json")
  ST_EXIT_AFTER_POLLS=2
  st_run_watcher
  unset ST_EXIT_AFTER_POLLS
  ST_ENV_EXTRA=()
  if [ "$(rein_st_count_sub "$ST_LOG" "--bg")" -eq 0 ]; then
    st_ok
  else
    st_fail "never launches a successor where isolation is enforced" "claude --bg was called: $(cat "$ST_LOG")"
  fi
  case "$ST_OUT" in
    *"force background-session isolation to"*) st_ok ;;
    *) st_fail "reports being forced as the reason" "$ST_OUT" ;;
  esac
  # An environment where it can't be judged (unreadable, broken) is **never refused**. What
  # applies this enforcement is Claude Code running under the same user privileges as rein, so a
  # file rein can't read, Claude Code can't read either -- the enforcement itself never fires, so
  # refusing protects nothing extra, and a lineage would lose the ability to hand over just
  # because the managed settings happen to be broken. All that changes is "failing silently" --
  # launch it, and report the reason. The destination differs from `rein up`'s because a watcher
  # started as a daemon has its stderr discarded (the watcher log and the GUI notification are the only faces that reach the user).
  case_dir="$tmp/managed-policy-broken"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  printf 'this is not json {{{\n' >"$tmp/managed-policy-broken.json"
  ST_ENV_EXTRA=("REIN_MANAGED_SETTINGS_POLICY=$tmp/managed-policy-broken.json")
  ST_EXIT_AFTER_POLLS=2
  st_run_watcher
  unset ST_EXIT_AFTER_POLLS
  ST_ENV_EXTRA=()
  if [ "$(rein_st_count_sub "$ST_LOG" "--bg")" -eq 1 ]; then
    st_ok
  else
    st_fail "still launches a successor with broken managed settings" "claude --bg was never called: $(cat "$ST_LOG")"
  fi
  case "$ST_OUT" in
    *"cannot be parsed as a JSON object"*) st_ok ;;
    *) st_fail "reports broken managed settings as the reason" "$ST_OUT" ;;
  esac
  case "$ST_OUT" in
    *"force background-session isolation to"*)
      st_fail "never lets a broken shape masquerade as an enforcement reason" "$ST_OUT"
      ;;
    *) st_ok ;;
  esac
  # Check both of the two faces that reach the user (the watcher log and the GUI notification).
  # Stderr is discarded on the real path (a run started as a daemon), so the one ST_OUT check
  # above alone doesn't confirm "it reached the user".
  case "$(cat "$ST_RECORDS/$REIN_WATCHER_LOG_BASENAME" 2>/dev/null)" in
    *"cannot be parsed as a JSON object"*) st_ok ;;
    *)
      st_fail "leaves broken managed settings in the watcher log" \
        "$(cat "$ST_RECORDS/$REIN_WATCHER_LOG_BASENAME" 2>/dev/null)"
      ;;
  esac
  if st_expect_notify "also raises broken managed settings as a GUI notification" \
    "rein: cannot judge whether isolation is enforced" "cannot be parsed as a JSON object"; then
    st_ok
  fi

  # A shape with no read permission (an environment where the distributed managed settings sit
  # root:wheel 0600). Its contents **are** forcing isolation, so this checks the pair of "still launches" and "reports it couldn't be read".
  case_dir="$tmp/managed-policy-unreadable"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  printf '{"worktree":{"bgIsolation":"worktree"}}\n' >"$tmp/managed-policy-unreadable.json"
  chmod 000 "$tmp/managed-policy-unreadable.json"
  ST_ENV_EXTRA=("REIN_MANAGED_SETTINGS_POLICY=$tmp/managed-policy-unreadable.json")
  ST_EXIT_AFTER_POLLS=2
  st_run_watcher
  unset ST_EXIT_AFTER_POLLS
  ST_ENV_EXTRA=()
  chmod 600 "$tmp/managed-policy-unreadable.json"
  if [ "$(rein_st_count_sub "$ST_LOG" "--bg")" -eq 1 ]; then
    st_ok
  else
    st_fail "still launches a successor with unreadable managed settings" "claude --bg was never called: $(cat "$ST_LOG")"
  fi
  case "$ST_OUT" in
    *"no read permission"*) st_ok ;;
    *) st_fail "reports unreadable managed settings as the reason" "$ST_OUT" ;;
  esac
  case "$ST_OUT" in
    *"force background-session isolation to"*)
      st_fail "never lets an unreadable shape masquerade as an enforcement reason" "$ST_OUT"
      ;;
    *) st_ok ;;
  esac
  case "$(cat "$ST_RECORDS/$REIN_WATCHER_LOG_BASENAME" 2>/dev/null)" in
    *"no read permission"*) st_ok ;;
    *)
      st_fail "leaves unreadable managed settings in the watcher log" \
        "$(cat "$ST_RECORDS/$REIN_WATCHER_LOG_BASENAME" 2>/dev/null)"
      ;;
  esac
  if st_expect_notify "also raises unreadable managed settings as a GUI notification" \
    "rein: cannot judge whether isolation is enforced" "no read permission"; then
    st_ok
  fi

  # The accepting side: the same managed settings still launch when they force none.
  case_dir="$tmp/managed-policy-none"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  printf '{"worktree":{"bgIsolation":"none"}}\n' >"$tmp/managed-policy-none.json"
  ST_ENV_EXTRA=("REIN_MANAGED_SETTINGS_POLICY=$tmp/managed-policy-none.json")
  ST_EXIT_AFTER_POLLS=2
  st_run_watcher
  unset ST_EXIT_AFTER_POLLS
  ST_ENV_EXTRA=()
  if [ "$(rein_st_count_sub "$ST_LOG" "--bg")" -eq 1 ]; then
    st_ok
  else
    st_fail "launches where an environment forces none" "$(cat "$ST_LOG")"
  fi

  # The rejecting side of the arrival check: the successor comes up, but the managed marker never
  # reaches its SessionStart hook, so the temporary launch settings are still sitting there.
  # **A session in that state is not visibly broken** -- with the default placement it resolves the
  # same lineage from its working directory and keeps working, so nothing would ever surface that
  # it is running outside rein's management (until now only `rein doctor` noticed, and only when
  # somebody happened to run it). The round has to fail here instead of advancing the pointer onto it.
  case_dir="$tmp/managed-marker-undelivered"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  ST_BG_KEEP_SETTINGS=1
  st_run_watcher
  unset ST_BG_KEEP_SETTINGS
  if st_expect_status "fails the round when the managed marker never reached the successor" 1; then
    if [ -f "$ST_RECORDS/$REIN_POINTER_BASENAME" ]; then
      st_fail "never points the lineage at a successor that is outside management" "current.json was written"
    elif st_log_has '"event":"handover_completed"'; then
      st_fail "never treats an undelivered marker as a completed handover" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    else
      st_ok
    fi
  fi
  # The session that did come up is stepped down through the existing cleanup path -- leaving it
  # would put a background session with no pointer to it in the same working tree.
  if st_log_has '"event":"successor_stopped"'; then
    st_ok
  else
    st_fail "steps down the successor that came up outside management" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
  fi
  # The reason has to name the marker, not the launch. Launch confirmation already succeeded one
  # step earlier, so a reason that read like a launch failure would send the investigation to the
  # wrong place -- the session is up; what failed is the marker reaching it.
  case "$ST_OUT" in
    *"the successor came up, but the temporary launch settings were still there"*"never reached its SessionStart hook"*)
      st_ok
      ;;
    *) st_fail "names the undelivered managed marker as the reason" "$ST_OUT" ;;
  esac
  # Nothing is left in the runtime directory afterwards: the session that would have deleted it is
  # the one being stepped down, so the watcher removes it. Leaving it would have the next `doctor`
  # name it under a reason that no longer fits ("the session it launched may never have come up" --
  # it did come up). The reason itself survives in the handover log, checked above.
  if [ -n "$(find "$ST_RUNTIME" -name "${REIN_MANAGED_SETTINGS_PREFIX}*" -print 2>/dev/null)" ]; then
    st_fail "leaves no temporary launch settings behind after stepping the successor down" \
      "$(find "$ST_RUNTIME" -name "${REIN_MANAGED_SETTINGS_PREFIX}*" -print 2>/dev/null)"
  else
    st_ok
  fi

}
