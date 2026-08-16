# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034  # selftest state is shared across sections (the caller selftest()'s locals and the ST_* globals)
# The directive above applies to the **whole file** -- in this file, neither an unused local
# inside a function nor a misspelled reference gets caught. The shared variables are scattered
# across the whole file, so a line-level directive can't be scoped tightly enough.
# selftest for the organization's managed-settings enforcement (runs the same judgment as the launch side).
# Not an executable script, so it carries no execute bit (out of scope for the --selftest convention).

st_section_managed_settings() {
  st_doctor_case_env
  printf '{"worktree":{"bgIsolation":"worktree"}}\n' >"$tmp/doctor-managed-policy.json"
  ST_VERB_ENV+=("REIN_MANAGED_SETTINGS_POLICY=$tmp/doctor-managed-policy.json")
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_reject "doctor fails under an environment that forces isolation" 1 "force background-session isolation to worktree"
  # `up` stops on the same judgment (don't create a situation where diagnostics pass but only launch fails).
  st_run_env --root "$root4" --cwd "$proj4" up --no-bootstrap
  st_expect_reject "up also stops under an environment that forces isolation" 1 "force background-session isolation to worktree"
  st_expect_true "doesn't start the watcher on a stopped run" \
    test ! -e "$root4/state/rein/$(rein_cwd_key "$proj4")/$REIN_LOCK_DIRNAME"
  # The accepting side: an environment forcing none reports no problem.
  printf '{"worktree":{"bgIsolation":"none"}}\n' >"$tmp/doctor-managed-policy.json"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_contains "forcing none is not treated as a problem" \
    "OK   the organization managed settings do not force background session isolation"
  # Never let **a round where the file couldn't be read** get mistaken for the OK that says
  # nothing is forced. The shared judgment that reports whether isolation is forced folds jq's
  # non-zero exit (broken JSON, no read permission) into the same 0 as "no value = no
  # conflict"; if the diagnostic then treated that 0 as green, an environment actually forcing
  # isolation would pass right through.
  printf 'this is not json {{{\n' >"$tmp/doctor-managed-policy.json"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_reject "says it cannot judge broken managed settings" 1 \
    "FAIL the managed settings for this organization cannot be parsed as a JSON object"
  st_expect_not_contains "doesn't let broken managed settings pass as OK with nothing forced" \
    "OK   the organization managed settings do not force background session isolation"
  # Diagnostics won't go green, but **launch is not refused**. Since this enforcement applies
  # to Claude Code running under the same user permissions as rein, a file rein cannot read is
  # also a file Claude Code cannot read, so the enforcement itself never takes effect --
  # refusing would protect nothing extra while leaving someone unable to work on a machine
  # whose settings just happen to be broken. The only thing this changes is that "cannot be read"
  # stops failing silently -- this also confirms the warning reaches the user.
  st_run_env --root "$root4" --cwd "$proj4" up --no-bootstrap
  if st_expect_status "up still launches even with broken managed settings" 0; then
    st_expect_contains "prints broken managed settings as a warning" \
      "warning: the managed settings for this organization cannot be parsed as a JSON object"
    st_expect_not_contains "doesn't let broken managed settings pass as a forcing reason" "force background-session isolation to"
  fi
  st_run_env --root "$root4" --cwd "$proj4" down
  st_expect_status "stops the watcher launched with a warning (broken managed settings)" 0
  # No read permission (the distributed managed settings sit at root:wheel 0600). The content
  # **does** force isolation, so passing this as green would let a successor edit outside this tree.
  printf '{"worktree":{"bgIsolation":"worktree"}}\n' >"$tmp/doctor-managed-policy.json"
  chmod 000 "$tmp/doctor-managed-policy.json"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_reject "says it cannot judge unreadable managed settings" 1 \
    "FAIL the managed settings for this organization cannot be read (no read permission)"
  st_expect_not_contains "doesn't let unreadable managed settings pass as OK with nothing forced" \
    "OK   the organization managed settings do not force background session isolation"
  # Also check the reason isn't misattributed (reporting an unreadable file as "forces worktree" would change how someone fixes it).
  st_expect_not_contains "doesn't let an unreadable file pass as a forcing reason" "force background-session isolation to worktree"
  # Launch isn't refused for an unreadable file either. The content **does** force isolation, so
  # this one round checks both halves at once: that launch goes through, and that the file is
  # reported as unreadable.
  st_run_env --root "$root4" --cwd "$proj4" up --no-bootstrap
  if st_expect_status "up still launches even with unreadable managed settings" 0; then
    st_expect_contains "prints unreadable managed settings as a warning" \
      "warning: the managed settings for this organization cannot be read (no read permission)"
    st_expect_not_contains "doesn't let an unreadable file pass as a launch-refusal reason" "force background-session isolation to"
  fi
  st_run_env --root "$root4" --cwd "$proj4" down
  st_expect_status "stops the watcher launched with a warning (unreadable managed settings)" 0
  chmod 600 "$tmp/doctor-managed-policy.json"
  # The accepting side: once the same file becomes readable, judgment proceeds to check forcing
  # as usual (don't leave it permanently stuck on the undeterminable side -- this one case
  # confirms the two cases above weren't passing simply because the judgment always answers FAIL).
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_reject "proceeds to check forcing once it becomes readable" 1 "force background-session isolation to worktree"
  # A machine with **no** managed-settings file (most machines) still reports OK as before.
  # Treating this as undeterminable would turn every machine that simply has none distributed
  # into FAIL. **The absent case also points at a location built for this check** -- falling back
  # to the default path (/Library/...) would make the result depend on the machine, since a real
  # file may be distributed there via MDM.
  rm -f "$tmp/doctor-managed-policy.json"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_contains "a machine with no managed settings stays OK" \
    "OK   the organization managed settings do not force background session isolation"
  ST_VERB_ENV=("${ST_VERB_ENV[@]:0:${#ST_VERB_ENV[@]}-1}")

  # The case where a temporary launch settings file is left behind (a sign the session it launched never came up).
  leftover_settings="$root4/state/rein/$(rein_cwd_key "$proj4")/${REIN_MANAGED_SETTINGS_PREFIX}leftover.json"
  # The runtime data location gets created when rein runs, and running this section alone means
  # no rein run has happened yet -- so create it up front.
  mkdir -p "${leftover_settings%/*}"
  printf '{}\n' >"$leftover_settings"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_contains "reports a leftover launch settings file" "WARN a temporary launch settings file remains"
  rm -f "$leftover_settings"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_contains "says so when none remains" "OK   no temporary launch settings remain"

  # The case where a different lineage sits in a parent directory (nested). Not rejected, but its location is reported.
  nested_child="$proj4/nested-child"
  mkdir -p "$nested_child" "$proj4/$REIN_RECORDS_DIRNAME"
  rein_st_write_pointer "$proj4/$REIN_RECORDS_DIRNAME/$REIN_POINTER_BASENAME" \
    "sess-nested" "nested" "$proj4" 1
  st_run_env --root "$root4" --cwd "$nested_child" doctor
  st_expect_contains "reports a nested lineage" "WARN a different lineage exists in a parent directory"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_contains "says so when there is no nesting" "OK   no other lineage exists in a parent directory"
  rm -f "$proj4/$REIN_RECORDS_DIRNAME/$REIN_POINTER_BASENAME"
  rmdir "$nested_child"

  # Reject the case where the launcher can't be executed (a corrupted plugin copy, or the
  # execute bit dropped). **Never touch the real repository's launcher execute bit** -- if this
  # check stopped partway, the bit would never come back and the user's live hooks would
  # simply stop firing. Instead, swap the REPO_ROOT the judgment function reads for a temp
  # fixture and run **the real judgment** unchanged (same pattern as an earlier case: the
  # doctor section's check on the registered command). The registry material is a copy of the
  # real one, so what the judgment reads matches the real repository's text.
  launcher_exec_repo="$tmp/doctor-launcher-exec"
  mkdir -p "$launcher_exec_repo/${REIN_HOOK_LAUNCHER_RELPATH%/*}" \
    "$launcher_exec_repo/${REIN_HOOK_RUNNER_RELPATH%/*}"
  : >"$launcher_exec_repo/$REIN_HOOK_LAUNCHER_RELPATH"
  : >"$launcher_exec_repo/$REIN_HOOK_RUNNER_RELPATH"
  chmod +x "$launcher_exec_repo/$REIN_HOOK_LAUNCHER_RELPATH" \
    "$launcher_exec_repo/$REIN_HOOK_RUNNER_RELPATH"
  cp "$REPO_ROOT/$REIN_HOOKS_JSON_RELPATH" "$launcher_exec_repo/$REIN_HOOKS_JSON_RELPATH"
  launcher_exec_saved="$REPO_ROOT"
  REPO_ROOT="$launcher_exec_repo"
  doctor_hook_command_state
  launcher_exec_rc=$?
  # Measure the accepting side first -- this pair confirms the rejecting side's 1 isn't coming
  # from something other than the launcher's execute bit (a missing runner, an unreadable registry).
  st_expect_true "an executable launcher passes as a valid path" test "$launcher_exec_rc" -eq 0
  chmod -x "$launcher_exec_repo/$REIN_HOOK_LAUNCHER_RELPATH"
  doctor_hook_command_state
  launcher_exec_rc=$?
  REPO_ROOT="$launcher_exec_saved"
  # Only **the judgment function's return value** is measured. Starting doctor as a whole would
  # touch the real repository's launcher execute bit, so this check calls the judgment
  # function directly (the mapping from rc=1 to the FAIL line "the hooks execution path does
  # not resolve" is the doctor section's own concern).
  st_expect_true "rejects a launcher that can't be executed" test "$launcher_exec_rc" -eq 1
}
