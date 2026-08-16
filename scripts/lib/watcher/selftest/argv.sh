# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034  # selftest state is shared across sections (the caller selftest()'s locals, and the ST_* globals)
# How values passed to external commands are handled: never leaking a settings value into a
# failure record, a notification, or stderr; the kickoff handover-request command being quoted
# word by word. Alongside that, CLI argument handling (a flag missing its value, an explicit
# empty value, an unresolvable target directory) failing with a reason.
# Variables are shared with the caller selftest()'s locals through dynamic scope. Declaring a
# local inside a section would hide it from later sections, so this section file declares none.
# Not an executable script, so it carries no execute bit (outside the --selftest convention).

st_section_argv() {
  # Only variables used exclusively in this section are kept local here (anything shared across sections belongs to selftest()'s own locals).
  local st_flag
  # A flag that has no config key (`--cwd` / `--handoff` / `--successor-name`) is held to the same
  # discipline as one that does (check_opt). Silently falling through on a failed `shift 2` would
  # exit non-zero **without printing a single line of reason**, and treating an explicit empty
  # value as unspecified would let "the value I meant to give disappeared and it ran with the
  # default" slip through with no signal (`--handoff ''` would grab config's default, and
  # `--successor-name ''` the default naming -- either way, a different input passes unnoticed).
  for st_flag in --cwd --handoff --successor-name; do
    probe_out="$("$REIN_ST_BASH" "$SCRIPT_PATH" "$st_flag" 2>&1 </dev/null)"
    request_rc=$?
    if [ "$request_rc" -ne 2 ]; then
      st_fail "fails ${st_flag} with no value" "exit=${request_rc}: ${probe_out}"
    else
      case "$probe_out" in
        *"${st_flag} requires a value"*)
          st_ok
          ;;
        *)
          st_fail "fails ${st_flag} with no value and a reason" "no reason was printed: [${probe_out}]"
          ;;
      esac
    fi
    probe_out="$("$REIN_ST_BASH" "$SCRIPT_PATH" "$st_flag" '' --once 2>&1 </dev/null)"
    request_rc=$?
    if [ "$request_rc" -ne 2 ]; then
      st_fail "fails ${st_flag} given an explicit empty value" "exit=${request_rc}: ${probe_out}"
    else
      case "$probe_out" in
        *"${st_flag} cannot take an empty value"*)
          st_ok
          ;;
        *)
          st_fail "does not treat an explicit empty ${st_flag} as unspecified" "no reason was printed: [${probe_out}]"
          ;;
      esac
    fi
  done

  # The target directory **can exist and still fail to resolve** (an unreachable permission, an
  # unreachable parent). Without covering that resolution failure, the assignment runs first, cwd
  # stays empty, execution proceeds, the reported reason turns into something unrelated (cannot
  # create the records location), and a raw shell error line leaks into user-facing output. Always
  # pass an isolated env and a runtime directory (this measures the shape where cwd stays empty
  # and proceeds, so the default location must never get resolved).
  case_dir="$tmp/cwd-unresolvable"
  st_setup_case "$case_dir"
  mkdir -p "$ST_CWD/no-entry"
  chmod 000 "$ST_CWD/no-entry"
  probe_out="$(env "${ST_ENV_ARGS[@]}" PATH="$ST_BIN:$PATH" \
    "$REIN_ST_BASH" "$SCRIPT_PATH" --cwd "$ST_CWD/no-entry" --runtime-dir "$ST_RUNTIME" --once 2>&1 </dev/null)"
  request_rc=$?
  chmod 755 "$ST_CWD/no-entry"
  if [ "$request_rc" -ne 2 ]; then
    st_fail "fails on an unresolvable target directory" "exit=${request_rc}: ${probe_out}"
  else
    case "$probe_out" in
      *"cannot resolve the target directory"*)
        st_ok
        ;;
      *)
        st_fail "reports the resolution failure as its own reason" "[${probe_out}]"
        ;;
    esac
    # Never leak a raw shell error line (`...: line N: cd: `) and never let the reason turn into something unrelated.
    case "$probe_out" in
      *": cd: "* | *"cannot create the lineage records location"*)
        st_fail "does not let the failure reason turn into something else" "[${probe_out}]"
        ;;
      *)
        st_ok
        ;;
    esac
  fi

  # settings can be JSON containing credentials. Even when an external command errors out on the
  # value itself, never put the full value in the canonical audit trail (the handover log), a
  # notification, or stderr.
  case_dir="$tmp/settings-in-failure-detail"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  ST_ARGS=(--settings '{"env":{"TOKEN":"s3cr3t-value"}}')
  ST_BG_FAIL=1
  st_run_watcher
  unset ST_ARGS ST_BG_FAIL
  if st_expect_status "stops on a launch failure with settings attached" 1; then
    if grep -q -F 's3cr3t-value' "$ST_RECORDS/$REIN_LOG_BASENAME" ||
      grep -q -F 's3cr3t-value' "$ST_NOTIFY"; then
      st_fail "never puts the settings value in the reason text" \
        "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME") / $(cat "$ST_NOTIFY")"
    else
      case "$ST_OUT" in
        *"s3cr3t-value"*)
          st_fail "never puts the settings value in stderr" "${ST_OUT}"
          ;;
        *)
          # Confirm the leak path itself is closed: the value **never appears on the command
          # line** (launch settings are handed over as a 0600 file in the runtime directory), so
          # it shows up in neither `ps` nor the CLI's failure output.
          if grep -q -F 's3cr3t-value' "$ST_LOG"; then
            st_fail "never puts the settings value on the command line" "$(cat "$ST_LOG")"
          else
            st_ok
          fi
          ;;
      esac
    fi
  fi

  # The accepting side: the fake CLI plays the role of a CLI that "prints the settings value it
  # received on the command line to stderr" (without a CLI that does print it, the check above
  # would always pass, and it wouldn't actually be measuring that the leak is closed). Confirm
  # this one does leak it, and that on the real path the value **never lands on the command line
  # in the first place**.
  case_dir="$tmp/settings-leak-fixture"
  st_setup_case "$case_dir"
  probe_out="$(FAKE_LOG="$ST_LOG" FAKE_AGENTS="$ST_AGENTS" FAKE_BG_FAIL=1 \
    "$ST_BIN/claude" --bg --name x --settings 's3cr3t-value' kickoff 2>&1)"
  case "$probe_out" in
    *"s3cr3t-value"*)
      st_ok
      ;;
    *)
      st_fail "the fake CLI prints the settings value to stderr" "the leak path isn't reproduced: ${probe_out}"
      ;;
  esac

  # The kickoff handover-request command is quoted word by word, even for an absolute path
  # containing spaces, a single quote, `;`, or `$( )` (the successor executes this one line
  # verbatim -- split it and the handover stalls that generation; leave it unquoted and it gets
  # evaluated as unintended shell syntax).
  case_dir="$tmp/od'd na;me \$(touch $tmp/pwned)"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  ST_EXIT_AFTER_POLLS=2
  st_run_watcher
  unset ST_EXIT_AFTER_POLLS
  if st_expect_status "a handover goes through even with metacharacters in the path" 0; then
    bg_call="$(rein_st_call_index "$ST_LOG" "--bg")"
    kickoff_line="$(rein_st_call_arg "$ST_LOG" "$bg_call" "$ST_BG_ARGC_BASE")"
    # The record side folds newlines into RS, so the command's one line is cut out there.
    # Match on " request " immediately followed by a flag (`--`), not on the bare word: the prose
    # sentences around the command also contain "request", and a bare-word match would pick one of
    # those up and glue it onto the command line before the shell ever parses it.
    request_line="$(printf '%s' "$kickoff_line" | awk -F"$REIN_ST_RS" \
      '{ for (i = 1; i <= NF; i++) if ($i ~ / request --/) print $i }')"
    # Fill in the placeholder, then take the argv the shell actually parses it into.
    # shellcheck disable=SC2016  # meant to expand inside the child shell (expanding it here defeats the point)
    quoted_argv="$(ST_LINE="${request_line/<your session ID>/sess-x}" \
      "$REIN_ST_BASH" -c 'eval "set -- $ST_LINE"; printf "%s\n" "$@"' 2>/dev/null)"
    expected_argv="$(printf '%s\n' "$REIN_BIN" --cwd "$ST_CWD" request \
      --runtime-dir "$ST_RUNTIME" --session-id sess-x --handoff "$ST_HANDOFF")"
    if [ "$quoted_argv" = "$expected_argv" ]; then
      st_ok
    else
      st_fail "the path with metacharacters passes as one word" "argv didn't match expectations: [${quoted_argv}] / expected [${expected_argv}]"
    fi
    if [ ! -e "$tmp/pwned" ]; then
      st_ok
    else
      st_fail "never lets it evaluate as command substitution" "\$( ) was executed"
    fi
  fi

  # **Never delegate resolving your own location to an external command** (delegating it opens
  # arbitrary code execution). Put a `dirname` that returns empty at the front of PATH, make the
  # working directory one holding a planted `lib/rein-common.sh`, and start the watcher
  # **with an absolute path**. If the location were resolved by "cd into dirname's output, then
  # read the current directory", moving to an empty string would succeed as a no-op, the working
  # directory would stay put, the current directory would read as the booby-trapped one, and its
  # shared library would run with the resident process's privileges.
  mkdir -p "$tmp/hijack-bin" "$tmp/hijack-cwd/lib"
  printf '#!/bin/sh\nexit 0\n' >"$tmp/hijack-bin/dirname"
  chmod +x "$tmp/hijack-bin/dirname"
  printf 'printf "%s\\n"\nexit 42\n' "REIN_ST_HIJACKED" >"$tmp/hijack-cwd/lib/rein-common.sh"
  probe_out="$(cd "$tmp/hijack-cwd" && PATH="$tmp/hijack-bin:$PATH" \
    "$REIN_ST_BASH" "$SCRIPT_PATH" --help 2>&1 </dev/null)"
  request_rc=$?
  case "$probe_out" in
    *REIN_ST_HIJACKED*)
      st_fail "never delegates resolving its own location to an external command" \
        "the working directory's lib/rein-common.sh ran (exit=${request_rc}): ${probe_out}"
      ;;
    *)
      # Check the accepting side at the same time (not only that the planted library never runs,
      # but that it still works as usual with that dirname on PATH).
      if [ "$request_rc" -eq 0 ]; then
        st_ok
      else
        st_fail "still works as usual with a broken dirname on PATH" "exit=${request_rc}: ${probe_out}"
      fi
      ;;
  esac
  # Even started with a relative path, it reads the library **right next to itself** (it resolves
  # to an absolute path against the working directory at startup -- there's no room for it to land
  # somewhere else).
  probe_out="$(cd "${SCRIPT_PATH%/*}" && "$REIN_ST_BASH" "${SCRIPT_PATH##*/}" --help 2>&1 </dev/null)"
  request_rc=$?
  if [ "$request_rc" -eq 0 ]; then
    st_ok
  else
    st_fail "reads the library right next to itself even started with a relative path" "exit=${request_rc}: ${probe_out}"
  fi

}
