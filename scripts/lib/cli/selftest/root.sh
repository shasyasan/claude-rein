# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034  # selftest state is shared across sections (the caller selftest()'s locals and the ST_* globals)
# The directive above applies to the **whole file** -- in this file, neither an unused local
# inside a function nor a misspelled reference gets caught. The shared variables are scattered
# across the whole file, so a line-level directive can't be scoped tightly enough.
# selftest for two lineages (the default one and one pinned by `--root`) sharing the same cwd.
# A lineage's identity is the pair of cwd **and root**. Without separate records locations, the
# two would overwrite each other's current.json, and there would be no way to tell afterwards
# which lineage the primary session belonged to (running a backend and a frontend lineage in the
# same repository is an ordinary use case). Both directions are pinned here: **neither reads the
# other's records** and **neither writes to the other's location**.
# Not an executable script, so it carries no execute bit (out of scope for the --selftest convention).

st_section_root() {
  dual_proj="$tmp/dual-proj"
  dual_root="$tmp/dual-root"
  dual_state="$tmp/dual-state"
  mkdir -p "$dual_proj/$REIN_RECORDS_DIRNAME" "$dual_state"
  dual_proj="$(cd "$dual_proj" && pwd -P)"
  dual_key="$(rein_cwd_key "$dual_proj")"
  dual_default_records="$dual_proj/$REIN_RECORDS_DIRNAME"
  dual_root_records="$dual_root/records/rein/$dual_key"
  mkdir -p "$dual_root_records"
  rein_st_write_pointer "$dual_default_records/$REIN_POINTER_BASENAME" \
    "sess-default" "default" "$dual_proj" 1
  rein_st_write_pointer "$dual_root_records/$REIN_POINTER_BASENAME" \
    "sess-root" "root" "$dual_proj" 7
  ST_VERB_ENV=(
    "PATH=${verb_bin}:${PATH}"
    "FAKE_LOG=$verb_log"
    "FAKE_NOTIFY_LOG=$tmp/notify.log"
    "XDG_STATE_HOME=$dual_state"
    "REIN_CONFIG_FILE=$tmp/empty-user-config"
  )
  : >"$tmp/empty-user-config"
  st_run_env --cwd "$dual_proj" status
  st_expect_contains "the default lineage reads its own records" "generation: 1"
  st_expect_not_contains "the default lineage doesn't read the root-pinned side's records" "generation: 7"
  st_run_env --root "$dual_root" --cwd "$dual_proj" status
  st_expect_contains "the --root lineage reads the root-pinned side's records" "generation: 7"
  st_expect_not_contains "the --root lineage doesn't read .rein/" "generation: 1"
  # Writes are split the same way: an operation on the `--root` side doesn't grow the default
  # side's records (and vice versa).
  dual_before="$(find "$dual_default_records" | LC_ALL=C sort)"
  st_run_env --root "$dual_root" --cwd "$dual_proj" snooze 30m
  st_expect_status "can set a snooze on the --root lineage" 0 && st_ok
  dual_after="$(find "$dual_default_records" | LC_ALL=C sort)"
  if [ "$dual_before" = "$dual_after" ]; then
    st_ok
  else
    st_fail "the --root lineage doesn't write to the default side" "the default side grew: ${dual_after}"
  fi
  st_expect_true "a --root snooze goes to the root-pinned side's location" \
    test -f "$dual_root/state/rein/$dual_key/$REIN_SNOOZE_BASENAME"
  dual_before="$(find "$dual_root/records" "$dual_root/state" | LC_ALL=C sort)"
  st_run_env --cwd "$dual_proj" snooze 30m
  st_expect_status "can set a snooze on the default lineage too" 0 && st_ok
  dual_after="$(find "$dual_root/records" "$dual_root/state" | LC_ALL=C sort)"
  if [ "$dual_before" = "$dual_after" ]; then
    st_ok
  else
    st_fail "the default lineage doesn't write to the root-pinned side" "the root-pinned side grew: ${dual_after}"
  fi
  st_expect_true "a default-lineage snooze goes to the XDG location" \
    test -f "$dual_state/rein/$dual_key/$REIN_SNOOZE_BASENAME"
  # The cross-lineage listing also stays scoped per lineage (doesn't mix in the other lineage across roots).
  st_run_env --root "$dual_root" --cwd "$dual_proj" status --all
  st_expect_contains "the --root listing shows the root-pinned side's generation" "7"
  # The JSON form goes through the same resolution too (if only the human-readable table
  # resolved correctly while the machine-readable form read `<cwd>/.rein/` directly, only the
  # JSON reader would lose the root-pinned lineage's generation).
  st_run_env --root "$dual_root" --cwd "$dual_proj" status --all --json
  st_expect_contains "the --root listing (JSON) also shows the root-pinned side's generation" '"generation":7'
  st_expect_not_contains "the --root listing (JSON) doesn't show .rein/'s generation" '"generation":1'
  ST_VERB_ENV=()

  # From here on: checks within this same process (layer composition, and what state survives a failure).
  REIN_CONFIG_FILE="$tmp/empty-user-config"
  export REIN_CONFIG_FILE
  export REIN_THRESHOLD_NOTICE=22
  printf 'threshold_notice=26\n' >"$project_config"
  rein_config_resolve_files "$REIN_BIN_PATH" "$proj"
  # Since this check runs in the same process, allow it through the config layer's own
  # recording entry point directly too (don't add another writer of the ledger).
  st_expect_true "can allow this check's fixture (same process)" \
    rein_config_allow_record "$project_config"
  if rein_config_load_files &&
    [ "$(rein_config_get threshold_notice)" = "22" ] &&
    rein_config_override threshold_notice 5 &&
    [ "$(rein_config_get threshold_notice)" = "5" ] &&
    [ "$(rein_config_origin threshold_notice)" = "cli" ]; then
    st_ok
  else
    st_fail "the CLI layer outranks the environment variable" "value=$(rein_config_get threshold_notice) origin=$(rein_config_origin threshold_notice)"
  fi
  unset REIN_THRESHOLD_NOTICE

  # Don't bake the effective value into the delegate's environment. Doing so would let the
  # environment layer outrank the file layer, and would pin the watcher's per-cycle reread to the
  # value at launch time, so it would stop taking effect (a delegate reads its own config layer
  # itself, so there's no need to hand it anything at all).
  if type rein_config_export_effective >/dev/null 2>&1; then
    st_fail "doesn't bake the effective value into the delegate's environment" "rein_config_export_effective has come back"
  else
    st_ok
  fi

  # A failed load leaves no partial application behind, and an unloaded state hands out no values.
  printf 'threshold_notice=26\nunknown_key=1\n' >"$project_config"
  rein_config_allow_record "$project_config" ||
    st_fail "can allow this check's fixture (same process)" "$REIN_PROJECT_ALLOW_ERROR"
  if rein_config_load_files; then
    st_fail "rejects a config that fails partway through" "it loaded anyway"
  else
    st_ok
  fi
  if rein_config_is_set threshold_notice; then
    st_fail "leaves no partial application behind on failure" "threshold_notice is still set"
  else
    st_ok
  fi
  if rein_config_get threshold_notice >/dev/null 2>&1; then
    st_fail "hands out no value when nothing has loaded" "it returned a value"
  else
    st_ok
  fi
  rm -f "$project_config"
  unset REIN_CONFIG_FILE

  st_config_lineage_cases
  st_records_parent_cases
}

# Which lineage the message for a decision (`config allow` / `deny`) names explicitly. What it
# goes by is **where the user config lives**, not the runtime directory or the records location
# (the ledger sits next to the user config -- rein_config_allow_file). This pins all 3
# mappings within the same process -- the default mapping can't be measured from the CLI
# (measuring it would touch the space right next to the user's real config), so this is the
# only place that measures it.
# As a pair, it also measures that an undeterminable case (an empty location) **is never folded
# onto the default side** -- folding it would report a lineage that was actually relocated as if
# it had been judged, on a single line that names no lineage.
st_config_lineage_cases() {
  local default_config lineage_root rc
  default_config="${XDG_CONFIG_HOME:-${HOME:-}/.config}/rein/config" # home-base-exempt: this line builds the "default location" inside the check itself in order to measure the default mapping; where no location is configured, the default itself doesn't exist (this isn't a resolution of the write destination)
  lineage_root="$tmp/lineage-root"

  if rein_config_lineage_opts "$default_config" && [ -z "$REIN_LINEAGE_GLOBAL_OPTS" ]; then
    st_ok
  else
    st_fail "the default location adds no naming" "opts=[${REIN_LINEAGE_GLOBAL_OPTS}]"
  fi
  if rein_config_lineage_opts "$lineage_root/$REIN_ROOT_CONFIG_RELPATH" &&
    [ "$REIN_LINEAGE_GLOBAL_OPTS" = " --root $(rein_shell_quote "$lineage_root")" ]; then
    st_ok
  else
    st_fail "a root-pinned lineage is named explicitly with --root" "opts=[${REIN_LINEAGE_GLOBAL_OPTS}]"
  fi
  if rein_config_lineage_opts "$tmp/elsewhere/config" &&
    [ "$REIN_LINEAGE_GLOBAL_OPTS" = " --config $(rein_shell_quote "$tmp/elsewhere/config")" ]; then
    st_ok
  else
    st_fail "a lineage with a relocated config is named explicitly with --config" "opts=[${REIN_LINEAGE_GLOBAL_OPTS}]"
  fi
  # `config` takes no verb options at all (`config allow --runtime-dir <value>` is rejected with
  # "takes no arguments" -- observed). Naming added after the verb must not be
  # assembled for any mapping.
  if [ -z "$REIN_LINEAGE_VERB_OPTS" ]; then
    st_ok
  else
    st_fail "doesn't put config's naming after the verb" "verb_opts=[${REIN_LINEAGE_VERB_OPTS}]"
  fi
  rein_config_lineage_opts ""
  rc=$?
  if [ "$rc" -eq 2 ] && [ -z "$REIN_LINEAGE_GLOBAL_OPTS" ] && [ -n "$REIN_LINEAGE_ERROR" ]; then
    st_ok
  else
    st_fail "declares itself undeterminable when the location is empty" "rc=${rc} opts=[${REIN_LINEAGE_GLOBAL_OPTS}]"
  fi
}

# The lineage where `<cwd>/.rein` **itself** is a symlink. Checks aimed at an individual file (an
# atomic write's destination, the handoff document, the runtime directory's owner) all correctly
# return 0 as long as the target is a real file -- what's unclosed here is **the one parent
# segment leading to that path**, not a per-writer check. Only the `<cwd>/.rein` segment gets
# closed here; a lineage that names a root (its records go under whatever root the user
# chose) is not swept in -- **the non-regression is pinned here alongside the negative case**.
st_records_parent_cases() {
  local proj outside before key records_verb
  proj="$tmp/records-link-proj"
  outside="$tmp/records-link-outside"
  mkdir -p "$proj" "$outside"
  printf 'sentinel
' >"$outside/SENTINEL"
  ln -s "$outside" "$proj/$REIN_RECORDS_DIRNAME"
  before="$(find "$outside" | LC_ALL=C sort)"

  if rein_records_dir "$proj" >/dev/null 2>&1; then
    st_fail "doesn't resolve a records location when .rein is a symlink" "resolved it anyway: ${REIN_RECORDS_PATH}"
  else
    st_ok
  fi
  if rein_ensure_records_dir "$proj/$REIN_RECORDS_DIRNAME" 2>/dev/null; then
    st_fail "doesn't create a records location when .rein is a symlink" "created it anyway"
  else
    st_ok
  fi
  st_expect_true "writes not a single file into what .rein's symlink points at" \
    test "$(find "$outside" | LC_ALL=C sort)" = "$before"

  # Non-regression (1): a lineage that names a root returns the root-pinned side even for the
  # same cwd (never looks at the form .rein takes).
  key="$(rein_cwd_key "$proj")"
  REIN_RECORDS_ROOT="$tmp/records-link-root/records/rein"
  if rein_records_dir "$proj" >/dev/null &&
    [ "$REIN_RECORDS_PATH" = "$REIN_RECORDS_ROOT/$key" ]; then
    st_ok
  else
    st_fail "a root-pinned lineage's records destination is unaffected by the form .rein takes" \
      "resolved to=${REIN_RECORDS_PATH}"
  fi
  unset REIN_RECORDS_ROOT
  # Non-regression (2): a lineage under an ordinary directory still resolves as before, and its location can still be created.
  mkdir -p "$tmp/records-plain-proj"
  if rein_records_dir "$tmp/records-plain-proj" >/dev/null &&
    [ "$REIN_RECORDS_PATH" = "$tmp/records-plain-proj/$REIN_RECORDS_DIRNAME" ] &&
    rein_ensure_records_dir "$REIN_RECORDS_PATH" &&
    [ -f "$tmp/records-plain-proj/$REIN_RECORDS_DIRNAME/.gitignore" ]; then
    st_ok
  else
    st_fail "a lineage under an ordinary directory behaves as before" "resolved to=${REIN_RECORDS_PATH}"
  fi

  # From the CLI's point of view. Closes the case where typing a single write verb is enough to
  # spawn a `.gitignore` (`*` = hides that whole directory from git) and a config in a location
  # the clone's author chose.
  # The fake CLI goes on PATH so the verbs that reach for `claude` (doctor below) never start the
  # real one.
  ST_VERB_ENV=(
    "PATH=${verb_bin}:${PATH}"
    "FAKE_LOG=$verb_log"
    "FAKE_NOTIFY_LOG=$tmp/notify.log"
    "HOME=$tmp/records-link-home"
    "XDG_STATE_HOME=$tmp/records-link-state"
    "REIN_CONFIG_FILE=$tmp/empty-user-config"
  )
  mkdir -p "$tmp/records-link-home" "$tmp/records-link-state"
  st_run_env --cwd "$proj" config set threshold_notice 25
  st_expect_reject "doesn't write to a lineage where .rein is a symlink" 1 "symbolic link"
  st_expect_true "writes neither config nor .gitignore into what the symlink points at" \
    test "$(find "$outside" | LC_ALL=C sort)" = "$before"

  # The read-only verbs too. **These are the ones that used to exit 0**: the resolver's rejection
  # arrived as an empty string through `$( )`, every path derived from it collapsed to the
  # filesystem root, and reading `/current.json` (absent) reported "no primary session" -- a
  # broken lineage indistinguishable from an idle one, from the exit code as much as from the
  # text. Both the reason and a non-zero exit are pinned, since either one alone would let the
  # regression back in (a run reporting the reason while still exiting 0 breaks every caller
  # that goes by the exit code, and the reverse leaves the user with no idea what to fix).
  for records_verb in down status; do
    st_run_env --cwd "$proj" "$records_verb"
    st_expect_reject "${records_verb} stops on a lineage where .rein is a symlink" 1 "symbolic link"
    st_expect_not_contains "${records_verb} never reports a broken lineage as an idle one" "no primary session"
  done

  # doctor is the exception, and the reason the failure is carried rather than raised inside the
  # shared preparation step: it is the verb whose job is to report exactly this state, so it has
  # to run all the way through with it. Pinned on 3 points -- it reaches the end (the last section
  # of the report is present), it names the state (a FAIL line carrying the resolver's own reason),
  # and it comes out non-zero (a diagnosis that reads as a clean bill of health is no diagnosis).
  st_run_env --cwd "$proj" doctor
  st_expect_true "doctor still comes out non-zero on a lineage where .rein is a symlink" \
    test "$ST_STATUS" -ne 0
  st_expect_contains "doctor runs to the end of its report even so" "operation lock"
  case "$ST_OUT" in
    *"FAIL the records location is a symbolic link"*) st_ok ;;
    *) st_fail "doctor reports the symlinked records location as one FAIL line" "${ST_OUT}" ;;
  esac
  # **One reason, once.** The resolver prints its own rejection to stderr from inside the shared
  # library (most of its callers sit inside `$( )`, so a variable would never reach them), and
  # doctor reaches it a second time while resolving the handoff document's default location. That
  # second call reads the return value correctly and reports its own WARN, but left the raw
  # `rein: ...` line loose in the middle of the report as well -- the identical sentence twice,
  # once belonging to no section. Counted rather than matched, since both copies carry the same
  # text and only the count tells them apart.
  st_expect_true "doctor states the symlink reason exactly once" \
    test "$(printf '%s\n' "$ST_OUT" | grep -c 'the records location is a symbolic link')" = "1"
  # Nothing on the diagnostic path writes through the link either (doctor is read-only, and a
  # location that never resolved must not become a path it reads or writes at the filesystem root).
  st_expect_true "doctor writes not a single file into what the symlink points at" \
    test "$(find "$outside" | LC_ALL=C sort)" = "$before"
  ST_VERB_ENV=()
}
