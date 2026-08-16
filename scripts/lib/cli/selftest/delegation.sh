# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034  # selftest state is shared across sections (the caller selftest()'s locals and the ST_* globals)
# The directive above applies to the **whole file** -- in this file, neither an unused local
# inside a function nor a misspelled reference gets caught. The shared variables are scattered
# across the whole file, so a line-level directive can't be scoped tightly enough.
# selftest for delegation wiring (does the resolved --cwd, location, and config reach the delegate).
# Not an executable script, so it carries no execute bit (out of scope for the --selftest convention).

st_section_delegation() {
  local root_runtime
  # The runtime directory for the lineage pinned by --root (built from the same constants as bin/rein).
  root_runtime="$root/$REIN_ROOT_STATE_RELDIR/$(rein_cwd_key "$proj")"

  # Delegation wiring. Confirm the resolved --cwd reaches the delegate by reading it back out of
  # the marker that got written (if the delegate never received it, cwd would be the directory
  # it started in).
  rein_st_start_fake_watcher "$root_runtime" "$proj"
  ST_OUT="$(cd "$tmp" && "$ST_BASH" "$REIN_BIN_PATH" --root "$root" --cwd "$proj" request \
    --session-id "sess-cli" --handoff "$tmp/handoff.md" 2>&1 </dev/null)"
  ST_STATUS=$?
  if st_expect_status "can delegate to request" 0; then
    marker="$(find "$root/state" -name "$REIN_MARKER_BASENAME" -print 2>/dev/null | head -1)"
    if [ -n "$marker" ] && [ "$(jq -r '.cwd // empty' "$marker" 2>/dev/null)" = "$proj" ]; then
      st_ok
    else
      st_fail "the resolved cwd reaches the delegate" "marker=${marker} cwd=$(jq -r '.cwd // empty' "${marker:-/dev/null}" 2>/dev/null)"
    fi
    if [ -n "$marker" ] && [ "$(jq -r '.session_id // empty' "$marker" 2>/dev/null)" = "sess-cli" ]; then
      st_ok
    else
      st_fail "the caller's argument reaches the delegate" "$(st_file_content "${marker:-/dev/null}")"
    fi
    st_expect_true "doesn't create state outside the target" test ! -e "$outside_state"
  fi
  rm -rf "${root:?}/state"

  # --root wins even when the environment points at another runtime directory. If it lost,
  # isolation would break and the test would write its marker to wherever the environment
  # points (which could be the user's own real state).
  rein_st_start_fake_watcher "$root_runtime" "$proj"
  st_run_with "REIN_RUNTIME_DIR=$outside_state" --root "$root" --cwd "$proj" request \
    --session-id "sess-root" --handoff "$tmp/handoff.md"
  if st_expect_status "--root outranks REIN_RUNTIME_DIR from the environment" 0; then
    st_expect_true "doesn't write to the outside runtime directory" test ! -e "$outside_state"
    marker="$(find "$root/state" -name "$REIN_MARKER_BASENAME" -print 2>/dev/null | head -1)"
    if [ -n "$marker" ] && [ "$(jq -r '.session_id // empty' "$marker" 2>/dev/null)" = "sess-root" ]; then
      st_ok
    else
      st_fail "writes to the runtime directory under root" "marker=${marker}"
    fi
  fi
  rm -rf "${root:?}/state"

  # A config value reaches the delegate (if it didn't, the setting would be recorded and still
  # have no effect). This case doesn't go through --root -- since only config decides where
  # runtime data lives here, the user layer is pinned with --config instead. The XDG default --
  # where config would land if it broke -- is also steered into a temp directory: without that, a
  # broken config in this very check would create a lineage in the real state.
  printf 'runtime_dir=%s\n' "$tmp/cfgstate" >"$project_config"
  st_allow_project --config "$tmp/empty-user-config" --cwd "$proj"
  rein_st_start_fake_watcher "$tmp/cfgstate" "$proj"
  ST_OUT="$(cd "$tmp" && XDG_STATE_HOME="$tmp/xdg-state" "$ST_BASH" "$REIN_BIN_PATH" \
    --config "$tmp/empty-user-config" --cwd "$proj" request \
    --session-id "sess-cfg" --handoff "$tmp/handoff.md" 2>&1 </dev/null)"
  ST_STATUS=$?
  if st_expect_status "can delegate through config" 0; then
    st_expect_true "the config value decides the delegate's behavior" test -f "$tmp/cfgstate/$REIN_MARKER_BASENAME"
    st_expect_true "the XDG default fallback goes unused once config takes effect" test ! -e "$tmp/xdg-state/rein"
  fi
  rm -rf "$tmp/cfgstate"

  # The delegation path also checks config for format and cross-field violations (without this,
  # a broken config would run through on the default and the handover machinery would keep
  # moving without anyone noticing). --root is also passed here so that this check itself won't
  # create a lineage in the real state if this path ever breaks by skipping the config check and
  # falling through to delegation -- --config is more specific, so it still takes effect.
  printf 'unknown_key=1\n' >"$project_config"
  st_allow_project_file "$project_config" "$tmp/empty-user-config"
  st_run --root "$root" --config "$tmp/empty-user-config" --cwd "$proj" attach --once
  st_expect_reject "the delegation path also rejects an unknown key" 1 "unknown key"
  printf 'threshold_notice=45\nthreshold_handover=40\n' >"$project_config"
  st_allow_project --config "$tmp/empty-user-config" --cwd "$proj"
  st_run --root "$root" --config "$tmp/empty-user-config" --cwd "$proj" request \
    --session-id x --handoff "$tmp/handoff.md"
  st_expect_reject "the delegation path also rejects a cross-field violation" 1 "threshold_notice"
  rm -f "$project_config"

  st_run --root "$root" --cwd "$proj" attach --bogus
  st_expect_reject "attach's delegate validates its own arguments" 2 "rein-seat.sh"

  # This check never shows a GUI notification on the user's own screen. It runs a delegate
  # all the way through to where it would enter the notification path (attach with no current
  # pointer), and confirms via the fake osascript that it never gets called. The un-silenced
  # side is also measured, since without it there'd be no way to tell "silenced correctly" from
  # "the fake osascript was just never wired in to begin with".
  rein_st_write_fake_bin "$tmp/notify-bin"
  : >"$tmp/notify.log"
  ST_OUT="$(PATH="$tmp/notify-bin:$PATH" FAKE_LOG="$tmp/fake-claude.log" \
    FAKE_NOTIFY_LOG="$tmp/notify.log" REIN_NOTIFY_SILENT=0 \
    "$ST_BASH" "$REIN_BIN_PATH" --root "$root" --cwd "$proj" attach --once 2>&1 </dev/null)"
  ST_STATUS=$?
  if st_expect_status "can reproduce a delegation that enters the notification path" 1; then
    st_expect_contains "the notification's reason goes to stderr" "cannot keep the seat"
    st_expect_true "the GUI notification fires when not silenced" \
      test "$(rein_st_calls_total "$tmp/notify.log")" -gt 0
  fi
  : >"$tmp/notify.log"
  ST_OUT="$(PATH="$tmp/notify-bin:$PATH" FAKE_LOG="$tmp/fake-claude.log" \
    FAKE_NOTIFY_LOG="$tmp/notify.log" REIN_NOTIFY_SILENT=1 \
    "$ST_BASH" "$REIN_BIN_PATH" --root "$root" --cwd "$proj" attach --once 2>&1 </dev/null)"
  ST_STATUS=$?
  if st_expect_status "silencing doesn't change the delegation's result" 1; then
    st_expect_contains "the reason still goes to stderr when silenced" "cannot keep the seat"
    st_expect_true "silencing stops the GUI notification from firing" \
      test "$(rein_st_calls_total "$tmp/notify.log")" -eq 0
  fi
  # With no explicit silencing -- only the environment this check process itself inherited -- the
  # notification still doesn't fire. The two cases above both silence explicitly, so they can't
  # catch this check having forgotten to export the silencing itself.
  : >"$tmp/notify.log"
  ST_OUT="$(PATH="$tmp/notify-bin:$PATH" FAKE_LOG="$tmp/fake-claude.log" \
    FAKE_NOTIFY_LOG="$tmp/notify.log" \
    "$ST_BASH" "$REIN_BIN_PATH" --root "$root" --cwd "$proj" attach --once 2>&1 </dev/null)"
  ST_STATUS=$?
  st_expect_true "the GUI notification still doesn't fire under a delegation that inherited this check's own environment" \
    test "$(rein_st_calls_total "$tmp/notify.log")" -eq 0
}
