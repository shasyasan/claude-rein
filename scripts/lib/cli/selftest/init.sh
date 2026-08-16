# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034  # selftest state is shared across sections (the caller selftest()'s locals and the ST_* globals)
# The directive above applies to the **whole file** -- in this file, neither an unused local
# inside a function nor a misspelled reference gets caught. The shared variables are scattered
# across the whole file, so a line-level directive can't be scoped tightly enough.
# selftest for init (install: the PATH-callable command, enabling the plugin at user scope).
# Not an executable script, so it carries no execute bit (out of scope for the --selftest convention).

st_section_init() {
  # The lineage (proj4 / root4) comes from the foundation shared with doctor's 4 sections.
  st_doctor_case_env
  # This section's foundation is a lineage whose location has no owner claim yet (one of init's
  # jobs is placing the owner file). The precondition is built here -- doctor's section leaves the same
  # lineage with an owner already in place, so relying on section order would let a run of just
  # this one section and a run of every section diverge.
  rm -f "$root4/$REIN_ROOT_STATE_RELDIR/$(rein_cwd_key "$proj4")/$REIN_OWNER_BASENAME"
  # Never touches the real `claude` or the real `~/.local/bin` (confined to a fake CLI and a check-local HOME).
  init_home="$tmp/init-home"
  init_link="$init_home/.local/bin/rein"
  init_calls="$tmp/init-claude.log"
  mkdir -p "$init_home/usage" "$init_home/.local/bin"
  : >"$init_calls"
  # The usage writer is something the user registers, so init's own checks build on an **already
  # registered** environment (an unregistered environment is measured on both sides by doctor's
  # own section). PATH is also rebuilt for the check, so the final doctor run's judgment doesn't
  # move depending on whether an install already sits on the surrounding PATH.
  st_write_statusline_settings "$init_home/.claude" "$REPO_ROOT/$REIN_STATUSLINE_RELPATH"
  # The marketplace registry's foundation is also built with this work tree already registered as
  # a directory -- the closing doctor run checks the marketplace's real location too, and an empty
  # one there would fail the install check, reporting that the plugin marketplace is not registered.
  init_marketplaces="$tmp/init-marketplaces.json"
  rein_st_write_marketplaces "$init_marketplaces" claude-rein directory "$REPO_ROOT"
  ST_VERB_ENV=(
    "PATH=${init_home}/.local/bin:${verb_bin}:$(st_path_without_rein)"
    "FAKE_LOG=$init_calls"
    "FAKE_NOTIFY_LOG=$tmp/notify.log"
    "HOME=$init_home"
    "CLAUDE_CONFIG_DIR=$init_home/.claude"
    "REIN_USAGE_STATE_DIR=$init_home/usage"
    "FAKE_MARKETPLACES=$init_marketplaces"
  )
  # Generation one's own document sits at the effective value's location (this lineage uses
  # `--root`, so it's next to the records on the root side).
  init_handoff_path="$root4/$REIN_ROOT_RECORDS_RELDIR/$(rein_cwd_key "$proj4")/$REIN_HANDOFF_BASENAME"
  # --dry-run changes nothing (it only prints what it would do).
  st_run_env --root "$root4" --cwd "$proj4" init --dry-run
  if st_expect_status "init --dry-run ends with 0" 0; then
    st_expect_contains "shows the symlink install plan" "[dry-run] ln -s $(rein_shell_quote "$REIN_BIN_PATH") $(rein_shell_quote "$init_link")"
    st_expect_contains "shows the marketplace registration plan" "[dry-run] claude plugin marketplace add $(rein_shell_quote "$REPO_ROOT")"
    st_expect_contains "shows the plugin install plan" "[dry-run] claude plugin install rein@claude-rein --scope user"
    st_expect_contains "shows the template plan" "[dry-run] lay down the handoff document template: ${init_handoff_path}"
    st_expect_contains "shows the runtime-location plan" "[dry-run] set up the runtime data location for this project"
    st_expect_contains "runs doctor at the end" "OK   the prerequisite tools"
  fi
  init_owner="$root4/$REIN_ROOT_STATE_RELDIR/$(rein_cwd_key "$proj4")/$REIN_OWNER_BASENAME"
  st_expect_true "--dry-run doesn't install" test ! -e "$init_link"
  st_expect_true "--dry-run doesn't create the document" test ! -e "$init_handoff_path"
  st_expect_true "--dry-run doesn't place the owner file" test ! -e "$init_owner"
  # If -n doesn't resolve to --dry-run, this round actually installs (confirms a short-form
  # mix-up never turns into an irreversible side effect).
  st_run_env --root "$root4" --cwd "$proj4" init -n
  if st_expect_status "init -n ends with 0" 0; then
    st_expect_contains "-n shows the same plan as --dry-run" "[dry-run] ln -s $(rein_shell_quote "$REIN_BIN_PATH") $(rein_shell_quote "$init_link")"
  fi
  st_expect_true "-n doesn't install either" test ! -e "$init_link"
  # The enablement-state query (plugin list) also runs on the closing doctor, so this is measured
  # by **the entry point that changes it** never being called.
  st_expect_true "--dry-run doesn't register the marketplace" \
    test "$(rein_st_count_calls "$init_calls" plugin marketplace add "$REPO_ROOT")" = "0"
  st_expect_true "--dry-run doesn't install the plugin" \
    test "$(rein_st_count_calls "$init_calls" plugin install "rein@claude-rein" --scope user)" = "0"
  # An actual run: places the symlink, and calls marketplace registration and install once each.
  st_run_env --root "$root4" --cwd "$proj4" init
  if st_expect_status "init ends with 0" 0; then
    st_expect_contains "reports it installed" "installed: ${init_link}"
  fi
  st_expect_true "installs the PATH-callable command" test -L "$init_link"
  st_expect_true "the installed target is this repo's own real file" \
    test "$(resolve_self "$init_link")" = "$REIN_BIN_PATH"
  st_expect_true "registers the marketplace" \
    rein_st_has_call "$init_calls" plugin marketplace add "$REPO_ROOT"
  st_expect_true "installs the plugin at user scope" \
    rein_st_has_call "$init_calls" plugin install "rein@claude-rein" --scope user
  # Generation one's document = a **non-empty** template (an empty one fails the bootstrap
  # existence check and R6). Its content is rein's own semantics only (project-specific items are
  # left to whoever writes it).
  st_expect_contains "reports it laid down the document template" "laid down the handoff document template: ${init_handoff_path}"
  st_expect_true "lays down a non-empty template" test -s "$init_handoff_path"
  # The section headings' order has one shared-library owner -- **the template and a handover
  # request's acceptance check both look at the same order**. Writing the literal text out here
  # would let this check keep pinning the old order on a run where only the template moved, and
  # the template's own document -- written exactly to the template -- would then be rejected by a
  # handover request. (Headings also share their literal text with the skill's own instructions,
  # but that's prose, so it isn't checked by machine there.)
  # Section names are matched as **a fixed string, the whole line** (treating them as a regex
  # would let this check silently go loose the day a metacharacter enters the order). Named
  # individually so a failing round shows which section is missing.
  for init_section in "${REIN_HANDOFF_SECTIONS[@]}"; do
    st_expect_true "the template carries the \"${init_section}\" heading" \
      grep -qFx "## ${init_section}" "$init_handoff_path"
  done
  # The reverse direction (never adding a heading that isn't in the order) calls **the very
  # implementation a handover request uses**. Rebuilding the judgment here would only pin the
  # template against the order, leaving the template against the implementation -- fence
  # exclusion, `## `'s exact spacing, how trailing whitespace is handled -- unchecked, and that is
  # the part that actually matters in production. A quirk in the implementation that rejects the
  # template right after `rein init` (only a handover request gets rejected) would then pass
  # through here green.
  if rein_handoff_sections_ok "$init_handoff_path"; then
    st_ok
  else
    st_fail "the template passes a handover request's own section check as-is" "$REIN_HANDOFF_SECTION_ERROR"
  fi
  # The standing-decisions section only takes **time-limited** decisions. It used to also host
  # permanent ones, but since those never lapse, they piled up at every handover, and the
  # document turned into a place where rules lived (this actually happened). If the template doesn't
  # demand a lapse condition, the distinction is left to whoever's writing it and disappears, and
  # finished decisions linger, binding whatever comes after.
  st_expect_true "the template makes a decision spell out its own lapse condition" \
    grep -q 'what has to finish before it lapses' "$init_handoff_path"
  st_expect_true "the template doesn't let permanent rules go here" \
    grep -q "Don't put permanent rules here" "$init_handoff_path"
  # The writing rules reach 3 firing points (the advisory, the handover trigger, and the
  # stop-blocking text) as well as the template, but **not one of them keeps its own copy** -- the
  # template splits its heredoc in two and prints the shared library's own canonical text to
  # assemble itself. What's checked here is only whether that generation actually took effect,
  # with the canonical text landing whole inside the template.
  # **Doesn't check by listing key words** -- a listing only reflects the rules as they stood when
  # it was written, so a 6th item added to the canonical text would leave the listing green while
  # the template silently goes stale (there's no copy left to compare against, since none is kept).
  # Matched as a fixed string (treating it as a regex would let this check silently go loose the
  # day a metacharacter enters the canonical text).
  st_expect_true "the template carries the writing-rules canon verbatim" \
    grep -qF "$REIN_HANDOFF_WRITING_RULES" "$init_handoff_path"
  # This one file is the location's owner claim, which every entry point (hooks included)
  # verifies before it reads or writes there. Nothing fires until `up` starts a session either
  # way -- hooks act only on a session rein launched -- no matter how installed and enabled the
  # plugin already is.
  st_expect_contains "reports it set up the runtime data location" "set up the runtime data location for this project"
  st_expect_true "places the owner file" test -f "$init_owner"
  st_expect_true "the owner is the target work tree" test "$(head -1 "$init_owner")" = "$proj4"
  # A second run is idempotent (doesn't reinstall if already installed, doesn't reinstall if
  # already enabled, doesn't overwrite an existing document).
  printf 'a line the user added\n' >>"$init_handoff_path"
  rein_st_write_plugins "$tmp/init-plugins.json" "rein@claude-rein" true
  ST_VERB_ENV+=("FAKE_PLUGINS=$tmp/init-plugins.json")
  : >"$init_calls"
  st_run_env --root "$root4" --cwd "$proj4" init
  if st_expect_status "a second init also ends with 0" 0; then
    st_expect_contains "says it's already installed" "already installed"
    st_expect_contains "says it's already enabled" "plugin is already enabled"
    st_expect_contains "says the document already exists" "the handoff document already exists"
    st_expect_contains "says the runtime data location is already set up" "already has its runtime data location set up"
  fi
  st_expect_true "doesn't overwrite an existing document" grep -q 'a line the user added' "$init_handoff_path"
  st_expect_true "doesn't reinstall while enabled" \
    test "$(rein_st_count_calls "$init_calls" plugin install "rein@claude-rein" --scope user)" = "0"
  st_expect_true "doesn't re-register the marketplace while enabled" \
    test "$(rein_st_count_calls "$init_calls" plugin marketplace add "$REPO_ROOT")" = "0"
  # An installed-but-disabled state is never routed down the **same path** as not-installed (the
  # marketplace registry is left alone -- only enablement happens). doctor's guidance is `claude
  # plugin enable`, while the implementation used to redo registration and install -- guidance and
  # implementation pointing at different paths.
  rein_st_write_plugins "$tmp/init-plugins.json" "rein@claude-rein" false
  : >"$init_calls"
  st_run_env --root "$root4" --cwd "$proj4" init
  st_expect_contains "says it enabled a disabled plugin" "enabled the plugin"
  st_expect_true "a disabled plugin only calls the enable entry point" \
    rein_st_has_call "$init_calls" plugin enable "rein@claude-rein" --scope user
  st_expect_true "doesn't re-register the marketplace for a disabled plugin" \
    test "$(rein_st_count_calls "$init_calls" plugin marketplace add "$REPO_ROOT")" = "0"
  st_expect_true "doesn't reinstall for a disabled plugin" \
    test "$(rein_st_count_calls "$init_calls" plugin install "rein@claude-rein" --scope user)" = "0"
  rein_st_write_plugins "$tmp/init-plugins.json" "rein@claude-rein" true

  # A location that already holds something unacceptable (a directory, a symlink, an empty file) is
  # never let through as already being there -- the acceptance condition comes from the one
  # shared-library function that generation one's start (bootstrap) and a handover request also
  # use. Letting it through would produce a lineage where init succeeds but a handover request
  # alone fails later.
  init_kept="$tmp/init-handoff-kept.md"
  mv "$init_handoff_path" "$init_kept"
  mkdir -p "$init_handoff_path/inner"
  st_run_env --root "$root4" --cwd "$proj4" init
  st_expect_reject "doesn't lay down the template at a directory, and fails" 1 "is not a regular file"
  st_expect_true "doesn't create content on a round that failed" test ! -e "$init_handoff_path/$REIN_HANDOFF_BASENAME"
  rm -rf "$init_handoff_path"
  ln -s "$init_kept" "$init_handoff_path"
  st_run_env --root "$root4" --cwd "$proj4" init
  st_expect_reject "doesn't lay down the template at a symlink, and fails" 1 "symlink"
  st_expect_true "doesn't rewrite the target on a round that failed" grep -q 'a line the user added' "$init_kept"
  rm -f "$init_handoff_path"
  : >"$init_handoff_path"
  st_run_env --root "$root4" --cwd "$proj4" init
  st_expect_reject "an empty document isn't let through as 'already there'" 1 "is empty"
  # Accepting side (an ordinary file already there at the same location passes through
  # untouched, as before). Looking only at the rejecting side wouldn't tell that apart from an
  # acceptance condition so broad it always fails whatever is already there.
  mv "$init_kept" "$init_handoff_path"
  st_run_env --root "$root4" --cwd "$proj4" init
  if st_expect_status "init passes with an ordinary file as the document" 0; then
    st_expect_contains "says the document already exists (ordinary file)" "the handoff document already exists"
  fi
  ST_VERB_ENV=("${ST_VERB_ENV[@]:0:${#ST_VERB_ENV[@]}-1}")
  # An install pointing at a different real file is **never overwritten** (never takes over a
  # lineage that's using rein from a different checkout).
  rm -f "$init_link"
  ln -s "$tmp/another-rein" "$init_link"
  st_run_env --root "$root4" --cwd "$proj4" init
  st_expect_reject "doesn't overwrite an install pointing at a different real file" 1 "points at a different real file"
  st_expect_true "doesn't rewrite the install on a round that failed" \
    test "$(resolve_self "$init_link")" = "$tmp/another-rein"
  rm -f "$init_link"
  # A failed CLI call fails with a reason (never silently says "enabled it"). The not-installed
  # path starts with marketplace registration, so this is measured by that entry point failing.
  ST_VERB_ENV+=("FAKE_MARKETPLACE_ADD_FAIL=1")
  st_run_env --root "$root4" --cwd "$proj4" init
  st_expect_reject "fails with a reason on a CLI failure" 1 "claude plugin marketplace add"
  st_expect_not_contains "doesn't report a failure as a success" "enabled the plugin"
  ST_VERB_ENV=("${ST_VERB_ENV[@]:0:${#ST_VERB_ENV[@]}-1}")
  # A round that **can't determine** the enablement state stops without calling even one entry
  # point that changes external state. Writing to the marketplace registry without knowing the
  # state would rewrite the user's environment every time the CLI happens to go down
  # temporarily (not-installed and undeterminable used to be routed the same path).
  ST_VERB_ENV+=("FAKE_PLUGIN_FAIL=1")
  : >"$init_calls"
  st_run_env --root "$root4" --cwd "$proj4" init
  st_expect_reject "fails on a round that can't determine the enablement state" 1 "cannot determine the plugin's enablement state"
  st_expect_true "doesn't register the marketplace on a round that can't determine it" \
    test "$(rein_st_count_calls "$init_calls" plugin marketplace add "$REPO_ROOT")" = "0"
  st_expect_true "doesn't install on a round that can't determine it" \
    test "$(rein_st_count_calls "$init_calls" plugin install "rein@claude-rein" --scope user)" = "0"
  st_expect_true "doesn't enable on a round that can't determine it" \
    test "$(rein_st_count_calls "$init_calls" plugin enable "rein@claude-rein" --scope user)" = "0"
  ST_VERB_ENV=("${ST_VERB_ENV[@]:0:${#ST_VERB_ENV[@]}-1}")
  st_run_env --root "$root4" --cwd "$proj4" init extra
  st_expect_status "init takes no arguments" 2 && st_ok

  # Closes "guide -> run -> re-diagnose" in one case. doctor flags a marketplace pointing at a
  # different real location as FAIL, with "to distribute from this location: ..." as its guidance.
  # But back when init only looked at the enablement state, **running that exact guidance as
  # typed** finished with "already enabled" without calling even one entry point that changes
  # external state, and re-diagnosing returned the same FAIL as before running it. A check that only
  # matches the guidance's literal text catches none of that mismatch -- only actually running it
  # and re-diagnosing can measure whether running it fixes anything.
  # **What's started is the exact line guided** (starting it from separately assembled arguments
  # would let guidance and execution disagree while this check stays green -- passing through a
  # mismatch this was meant to close). The guidance's one line is sliced out of doctor's output,
  # expanded into the argv the shell actually splits it into, and started with those words. Only
  # the leading word is swapped out (`rein` on PATH isn't installed into this check's HOME yet, so it's called by its real path).
  rein_st_write_plugins "$tmp/init-plugins.json" "rein@claude-rein" true
  ST_VERB_ENV+=("FAKE_PLUGINS=$tmp/init-plugins.json")
  rein_st_write_marketplaces "$init_marketplaces" claude-rein directory "$tmp/another-checkout"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_reject "doctor flags a marketplace distributed from a different real location" 1 \
    "To distribute from this location: 'rein' --root $(rein_shell_quote "$root4") --cwd $(rein_shell_quote "$proj4") init"
  init_guide_argv=()
  if ! init_guide_line="$(st_slice_between "${ST_OUT}"$'\n' "To distribute from this location: " $'\n')"; then
    st_fail "the guidance line can be sliced out of doctor's output" "$ST_OUT"
  else
    while IFS= read -r init_guide_word; do
      [ -n "$init_guide_word" ] || continue
      init_guide_argv+=("$init_guide_word")
    done <<EOF
$(st_argv_of "$init_guide_line")
EOF
  fi
  if [ "${#init_guide_argv[@]}" -lt 2 ] || [ "${init_guide_argv[0]}" != "rein" ]; then
    st_fail "the guidance line expands into rein's own argv" "[${init_guide_line}] -> [${init_guide_argv[*]:-}]"
  else
    st_ok
    : >"$init_calls"
    st_run_env "${init_guide_argv[@]:1}"
    st_expect_status "the guided init ends with 0" 0
    st_expect_contains "reports the redirect" \
      "redirected the marketplace to this work tree: ${REPO_ROOT}"
    st_expect_true "the guided init redirects the marketplace" \
      rein_st_has_call "$init_calls" plugin marketplace add "$REPO_ROOT"
    # Measures **whether it re-fetches after changing external state**, by the call count.
    # `marketplace add` replaces the distribution source, so the plugin state it distributes can
    # shift with this one action -- an implementation that decides the next step from the
    # before-change answer finishes this round's enablement-state query at 2 calls.
    # Breakdown is 3: (1) the entry-point judgment / (2) re-fetching right after redirecting / (3) the closing doctor.
    st_expect_true "a round that redirects re-fetches the enablement state" \
      test "$(rein_st_count_calls "$init_calls" plugin list --json)" = "3"
    st_run_env --root "$root4" --cwd "$proj4" doctor
    st_expect_contains "re-diagnosing after the redirect points at this work tree" \
      "OK   the plugin marketplace points at this work tree: ${REPO_ROOT}"
    st_expect_not_contains "re-diagnosing doesn't return the same guidance" "To distribute from this location: "
  fi
  # The side where no redirect is needed leaves the registry untouched (looking only at the
  # accepting side wouldn't tell that apart from an implementation that always adds).
  # The fixture's state is **restored explicitly, not relying on the subject's own side effect**
  # (that the init above ended up pointing at this work tree, as a result of calling `marketplace
  # add`, only holds if the subject behaved correctly -- if the subject is broken, everything
  # after this runs on a broken premise, going green or red for the wrong reason).
  rein_st_write_marketplaces "$init_marketplaces" claude-rein directory "$REPO_ROOT"
  : >"$init_calls"
  st_run_env --root "$root4" --cwd "$proj4" init
  st_expect_true "leaves the registry untouched when already pointing at this work tree" \
    test "$(rein_st_count_calls "$init_calls" plugin marketplace add "$REPO_ROOT")" = "0"
  ST_VERB_ENV=("${ST_VERB_ENV[@]:0:${#ST_VERB_ENV[@]}-1}")

  # A section-structure mismatch is **shown by the current state and doctor**. Only a handover
  # request holds the rejection judgment, so without showing it here, the only place left to
  # notice it is the rejection that lands right when context runs out, just before handover. Measured from the
  # accepting side first (no note while it's still the template) -- to tell it apart from an
  # implementation that always shows the note.
  init_extra_heading="Work Log"
  cp "$init_handoff_path" "$tmp/init-handoff-sections.bak"
  st_run_env --root "$root4" --cwd "$proj4" status
  st_expect_contains "the current state reports the document's effective value" "handoff: ${init_handoff_path} (origin "
  st_expect_not_contains "no section-structure note while it's still the template" "section structure does not match the template"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_not_contains "doctor doesn't sound section structure either while it's still the template" "the handoff document section structure"
  # The machine reader gets the same thing too (if it only showed on the human-readable line and
  # doctor, a script conditioning only on `--json`'s `handoff.present` would read "the document is
  # there" and still fail at handover). Measured as a **pair** of the boolean and the reason -- to
  # tell it apart from an implementation that always fills in the reason.
  st_run_env --root "$root4" --cwd "$proj4" status --json
  if [ "$(printf '%s' "$ST_OUT" | jq -r '.handoff.sections_ok' 2>/dev/null)" = "true" ] &&
    [ "$(printf '%s' "$ST_OUT" | jq -r '.handoff.sections_reason' 2>/dev/null)" = "null" ]; then
    st_ok
  else
    st_fail "while it's still the template, --json also reports section structure as matching" "$ST_OUT"
  fi
  # The rejecting side (a document with a heading added that isn't in the template). It's judged
  # through the same one function a handover request uses, so the named literal text shows up
  # as-is in both the current state and doctor too.
  printf '\n## %s\n' "$init_extra_heading" >>"$init_handoff_path"
  st_run_env --root "$root4" --cwd "$proj4" status
  st_expect_contains "the current state names the section-structure mismatch" \
    "section structure does not match the template -- a handover request in this shape will be rejected: headings not in the template: \"## ${init_extra_heading}\""
  # **Never mixed into the acceptance judgment** (display only) -- the document is still counted
  # as present, and the meaning of every path other than a handover request is unchanged. Mixing it in would turn
  # this line into "missing, empty, or not an acceptable shape."
  st_expect_not_contains "doesn't mix the section-structure mismatch into the acceptance judgment" "missing, empty, or not an acceptable shape"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_contains "doctor also reports the section-structure mismatch as WARN" \
    "WARN the handoff document section structure does not match the template (headings not in the template: \"## ${init_extra_heading}\")"
  # `--json` also names it (with only the boolean, whoever reads it would have to go find what to
  # fix from the human-readable line instead). `present` staying true is measured **in the same
  # round** -- measuring it only on the human-readable side would leave the `--json` assembly,
  # built through a separate path, unchecked.
  st_run_env --root "$root4" --cwd "$proj4" status --json
  if [ "$(printf '%s' "$ST_OUT" | jq -r '.handoff.sections_ok' 2>/dev/null)" = "false" ] &&
    [ "$(printf '%s' "$ST_OUT" | jq -r '.handoff.sections_reason' 2>/dev/null)" = "headings not in the template: \"## ${init_extra_heading}\"" ] &&
    [ "$(printf '%s' "$ST_OUT" | jq -r '.handoff.present' 2>/dev/null)" = "true" ]; then
    st_ok
  else
    st_fail "--json names the section-structure mismatch and doesn't mix it into the acceptance judgment" "$ST_OUT"
  fi
  # The fixture is restored explicitly (both what follows in this section, and other sections
  # sharing this lineage, assume a document that matches the template).
  cp "$tmp/init-handoff-sections.bak" "$init_handoff_path"

  # Presence itself (what this goes by is the seat lock the seat claims first). Real ps is only
  # called to ask whether the declared pid is still there, so both sides (there / left behind)
  # can be measured for real.
  seat_runtime="$tmp/seat-lock-runtime"
  seat_lock="$seat_runtime/$REIN_SEAT_LOCK_DIRNAME"
  mkdir -p "$seat_runtime"
  RUNTIME_DIR="$seat_runtime"
  SEAT_PID=""
  st_expect_true "doesn't read attached with no seat lock there" test ! -e "$seat_lock"
  if find_seat_pid; then
    st_fail "doesn't read attached with no seat lock there" "read it as attached (pid=${SEAT_PID})"
  else
    st_ok
  fi
  # A lock whose owner is itself = a live seat (the start time matches too).
  rein_claim_lock_dir "$seat_lock" start "$(rein_process_start_identity "$$")" \
    cwd "$tmp" token "seat-token"
  if find_seat_pid && [ "$SEAT_PID" = "$$" ]; then
    st_ok
  else
    st_fail "reads a live seat lock as attached" "pid=${SEAT_PID} (expected $$)"
  fi
  # The case where the start time disagrees -- pid reuse. Even a live pid isn't read as the owner then.
  printf 'Thu Jan  1 00:00:00 2020\n' >"$seat_lock/start"
  if find_seat_pid; then
    st_fail "doesn't read a reused pid as attached" "read it as attached (pid=${SEAT_PID})"
  else
    st_ok
  fi
  # Only releases a lock this side actually claimed (token match).
  if rein_release_lock_dir_if_mine "$seat_lock" "other-token"; then
    st_fail "doesn't release someone else's seat lock" "released it anyway"
  else
    st_ok
  fi
  st_expect_true "an unreleased lock remains" test -d "$seat_lock"
  if rein_release_lock_dir_if_mine "$seat_lock" "seat-token"; then
    st_ok
  else
    st_fail "releases its own seat lock" "couldn't release it"
  fi
  st_expect_true "a released seat lock is gone" test ! -e "$seat_lock"

  # Reclaiming a stale lock only ever removes **the exact pid this side itself saw**. If a
  # different execution reclaims the same stale lock in the gap between seeing it and removing
  # it, a plain release strips the live lock right after it was reclaimed -- two executions
  # holding the lock at once.
  reclaim_lock="$seat_runtime/reclaim-probe.lock"
  rein_claim_lock_dir "$reclaim_lock"
  # Rejecting side: a lock whose contents disagree with the pid this side saw is left untouched, not removed.
  if rein_release_lock_dir_if_stale "$reclaim_lock" 99999999; then
    st_fail "doesn't release a lock that disagrees with the pid it saw" "released it anyway"
  else
    st_ok
  fi
  if [ -d "$reclaim_lock" ] && [ "$(rein_lock_pid "$reclaim_lock")" = "$$" ]; then
    st_ok
  else
    st_fail "an unreleased lock remains with its contents intact" "$(ls -a "$reclaim_lock" 2>&1)"
  fi
  # Never leaves a temp name behind at the location (even on a round where the check disagreed, it goes back to the public name).
  if [ -z "$(find "$seat_runtime" -maxdepth 1 -name 'reclaim-probe.lock.release.*' -print 2>/dev/null)" ]; then
    st_ok
  else
    st_fail "never leaves a temp name behind even on a mismatch" "$(ls -a "$seat_runtime" 2>&1)"
  fi
  # Accepting side: releases it when the pid matches.
  if rein_release_lock_dir_if_stale "$reclaim_lock" "$$"; then
    st_ok
  else
    st_fail "releases a lock matching the pid it saw" "couldn't release it"
  fi
  st_expect_true "a released lock is gone" test ! -e "$reclaim_lock"
  # The reclaim entry point is measured on both sides too. A live owner can't be taken (2); a gone one can be reclaimed (0).
  rein_claim_lock_dir "$reclaim_lock"
  rein_claim_lock_dir_or_reclaim "$reclaim_lock"
  reclaim_rc=$?
  if [ "$reclaim_rc" -eq 2 ]; then
    st_ok
  else
    st_fail "doesn't reclaim a live owner's lock" "rc=${reclaim_rc}"
  fi
  printf '99999999\n' >"$reclaim_lock/pid"
  rein_claim_lock_dir_or_reclaim "$reclaim_lock"
  reclaim_rc=$?
  if [ "$reclaim_rc" -eq 0 ] && [ "$(rein_lock_pid "$reclaim_lock")" = "$$" ]; then
    st_ok
  else
    st_fail "reclaims a lock with no owner" "rc=${reclaim_rc} pid=$(rein_lock_pid "$reclaim_lock")"
  fi
  rein_release_lock_dir "$reclaim_lock"

  # A capped run returns non-zero when the command **couldn't even be started**. Perl's `exec`
  # returns
  # false on failure but doesn't end the program, so if the last statement is `exec`, rc=0 comes
  # back without ever running anything -- and a path that uses that rc for success/failure (init's
  # plugin enablement, prune's session deletion) reports a failure as a success. Measured on both
  # the runnable and the unrunnable side.
  rein_run_limited 5 "$tmp/no-such-command-xyz" >/dev/null 2>&1
  init_run_rc=$?
  if [ "$init_run_rc" -ne 0 ]; then
    st_ok
  else
    st_fail "an unrunnable command returns non-zero" "rc=0 (exec's failure came back as a success)"
  fi
  rein_run_limited 5 true >/dev/null 2>&1
  init_run_rc=$?
  if [ "$init_run_rc" -eq 0 ]; then
    st_ok
  else
    st_fail "a runnable command returns 0" "rc=${init_run_rc}"
  fi

  # End to end: `init` in an environment with no `claude` on PATH fails, **and names the missing
  # command as the reason**. Back when a failure was reported as a success, "enabled the plugin"
  # showed up even though it had never run once -- and after that was fixed, the reason it stopped
  # on was still the first thing that happened to reach for the CLI ("cannot read claude plugin
  # list --json"), which sent a user with no CLI installed off to look at a plugin registry that
  # was never the problem. The two states have different fixes, so **the reason belonging to the
  # other one is pinned as absent** as well: a CLI that is present but answers unreadably keeps
  # the enablement-state wording (measured on the FAKE_PLUGIN_FAIL round above).
  init_no_claude_env=("${ST_VERB_ENV[@]}")
  init_no_claude_env[0]="PATH=${init_home}/.local/bin:$(rein_st_path_without_cmd claude)"
  ST_OUT="$(env "${init_no_claude_env[@]}" "$ST_BASH" "$REIN_BIN_PATH" \
    --root "$root4" --cwd "$proj4" init 2>&1 </dev/null)"
  ST_STATUS=$?
  if st_expect_status "init fails with no claude" 1; then
    st_expect_contains "names the missing command as the reason" "the claude command is not on PATH"
    st_expect_not_contains "never blames the plugin registry for a missing CLI" \
      "cannot determine the plugin's enablement state"
    st_expect_not_contains "doesn't report it as a success" "enabled the plugin"
  fi

  # End to end: **`rein init` produces a runtime data location a hook can actually own-verify and
  # write to**, and **it does not, by itself, make a plain `claude` window start acting**. Hooks
  # act only on a session rein itself launched (told by the managed marker), and both sides of
  # that judgment are already measured by the hook's own selftest -- what's measured here is the
  # match between what init lays down and what the hook reads once a marker names it. The lineage
  # is set up at the **default** location (XDG), since that's the layout the marker built by `up`
  # names for a lineage that wasn't relocated.
  init_optin_proj="$tmp/init-optin-proj"
  mkdir -p "$init_optin_proj" "$tmp/init-optin-usage"
  init_optin_proj="$(cd "$init_optin_proj" && pwd -P)"
  : >"$tmp/init-optin-transcript.jsonl"
  # Isolation is assembled through the one shared entry point. **Drops the surrounding REIN_* all
  # the way down** -- this check itself is a child of `bin/rein`, so if this lineage's own values
  # (REIN_RUNTIME_DIR, etc.) are still in the environment, the hook would judge against a
  # different lineage's location.
  rein_st_isolation_env "$tmp/init-optin-user-config" "$tmp/init-optin-config" \
    "$tmp/init-optin-state" "$init_home"
  init_optin_env=(
    "${REIN_ST_ENV_ARGS[@]}"
    "PATH=${init_home}/.local/bin:${verb_bin}:$(st_path_without_rein)"
    "CLAUDE_CONFIG_DIR=$init_home/.claude"
    "REIN_USAGE_STATE_DIR=$tmp/init-optin-usage"
    "FAKE_LOG=$init_calls"
    "FAKE_NOTIFY_LOG=$tmp/notify.log"
  )
  init_optin_payload="$(rein_st_hook_payload sess-optin "$init_optin_proj" "$tmp/init-optin-transcript.jsonl")"
  init_optin_out="$(printf '%s' "$init_optin_payload" | env "${init_optin_env[@]}" \
    "$ST_BASH" "$REPO_ROOT/$REIN_HOOK_RUNNER_RELPATH" --protocol "$REIN_HOOK_PROTOCOL" post-tool-batch 2>&1)"
  if [ -z "$init_optin_out" ]; then
    st_ok
  else
    st_fail "hooks stay silent before init" "$init_optin_out"
  fi
  st_expect_true "no runtime directory is created before init either" \
    test ! -e "$tmp/init-optin-state/rein/$(rein_cwd_key "$init_optin_proj")"
  ST_OUT="$(env "${init_optin_env[@]}" "$ST_BASH" "$REIN_BIN_PATH" \
    --cwd "$init_optin_proj" init 2>&1 </dev/null)"
  ST_STATUS=$?
  st_expect_status "init at the default location ends with 0" 0 && st_ok
  # **`init` alone never makes a plain window start acting** -- the same call, same payload, still
  # gets nothing. This is the user-visible half: setting a project up doesn't turn every `claude`
  # window opened in it into one that gets pushed to hand over.
  init_optin_out="$(printf '%s' "$init_optin_payload" | env "${init_optin_env[@]}" \
    "$ST_BASH" "$REPO_ROOT/$REIN_HOOK_RUNNER_RELPATH" --protocol "$REIN_HOOK_PROTOCOL" post-tool-batch 2>&1)"
  if [ -z "$init_optin_out" ]; then
    st_ok
  else
    st_fail "a plain window still gets nothing after init" "$init_optin_out"
  fi
  # The counterpart (measuring both sides): the same payload with **a managed marker naming what
  # init just created** rings loudly. This is what links the two sides -- init's location passes
  # the hook's owner verification, and its records location matches the lineage the marker names.
  # If init laid down something the hook rejects, this side goes silent (or fails loud) and the
  # case above stops meaning anything.
  init_optin_runtime="$tmp/init-optin-state/rein/$(rein_cwd_key "$init_optin_proj")"
  # The marker's token is **read back out of what init placed**, never written here. That makes
  # this case measure the link in both directions: init has to have drawn a token, and the hook
  # has to accept that exact value. Hardcoding one here would leave the case green even if init
  # stopped placing a token at all (the hook would then refuse every session of a lineage init
  # set up, and nothing would say so).
  if ! rein_read_runtime_token "$init_optin_runtime"; then
    st_fail "init places a lineage token in what it created" "$REIN_RUNTIME_ERROR"
  else
    st_ok
  fi
  init_optin_out="$(printf '%s' "$init_optin_payload" | env "${init_optin_env[@]}" \
    "${REIN_MANAGED_ENV_NAME}=1" \
    "${REIN_MANAGED_CWD_ENV_NAME}=$init_optin_proj" \
    "${REIN_MANAGED_RUNTIME_ENV_NAME}=$init_optin_runtime" \
    "${REIN_MANAGED_CONFIG_ENV_NAME}=$tmp/init-optin-user-config" \
    "${REIN_MANAGED_RECORDS_ENV_NAME}=$init_optin_proj/$REIN_RECORDS_DIRNAME" \
    "${REIN_MANAGED_TOKEN_ENV_NAME}=$REIN_RUNTIME_TOKEN" \
    "$ST_BASH" "$REPO_ROOT/$REIN_HOOK_RUNNER_RELPATH" --protocol "$REIN_HOOK_PROTOCOL" post-tool-batch 2>&1)"
  case "$init_optin_out" in
    *"Monitoring is not working"*) st_ok ;;
    *) st_fail "a marker naming what init created makes the hook act" "${init_optin_out:-(stayed silent)}" ;;
  esac

  # Quoting the **fully assembled command** embedded in an advisory (the same reason as doctor and
  # status -- a one-liner meant to be pasted and run). The install target sits under HOME, so
  # whitespace, `;`, `$( )`, and a single quote are placed inside the check-local HOME to measure
  # this. Measured both by the literal text and by the argv the shell actually splits it into, plus a canary.
  r16_home="$tmp/r16i a b;\$(touch $tmp/r16i-pwned)'q"
  mkdir -p "$r16_home/.local/bin" "$r16_home/usage"
  r16_home="$(cd "$r16_home" && pwd -P)"
  r16_link="$r16_home/.local/bin/rein"
  st_write_statusline_settings "$r16_home/.claude" "$REPO_ROOT/$REIN_STATUSLINE_RELPATH"
  ST_VERB_ENV=(
    "PATH=${r16_home}/.local/bin:${verb_bin}:$(st_path_without_rein)"
    "FAKE_LOG=$init_calls"
    "FAKE_NOTIFY_LOG=$tmp/notify.log"
    "HOME=$r16_home"
    "CLAUDE_CONFIG_DIR=$r16_home/.claude"
    "REIN_USAGE_STATE_DIR=$r16_home/usage"
    "FAKE_MARKETPLACES=$init_marketplaces"
  )
  st_run_env --root "$root4" --cwd "$proj4" init --dry-run
  r16_init_out="${ST_OUT}"$'\n'
  st_expect_not_contains "doesn't embed an unquoted install target in the plan" "ln -s ${REIN_BIN_PATH} ${r16_link}"
  st_expect_contains "quotes the install plan" \
    "[dry-run] ln -s $(rein_shell_quote "$REIN_BIN_PATH") $(rein_shell_quote "$r16_link")"
  st_expect_argv "the install plan is passed word by word" "$r16_init_out" \
    "[dry-run] ln -s " $'\n' \
    "$REIN_BIN_PATH" "$r16_link"
  st_expect_contains "quotes the marketplace registration plan" \
    "[dry-run] claude plugin marketplace add $(rein_shell_quote "$REPO_ROOT")"
  st_expect_argv "the marketplace registration plan is passed word by word" "$r16_init_out" \
    "[dry-run] claude plugin marketplace add " $'\n' \
    "$REPO_ROOT"
  # An install pointing at a different real file is never overwritten -- and its "how to remove
  # it" guidance is also a one-liner meant to be pasted and run.
  ln -s "$tmp/another-rein" "$r16_link"
  st_run_env --root "$root4" --cwd "$proj4" init --dry-run
  r16_init_out="${ST_OUT}"$'\n'
  st_expect_reject "doesn't overwrite an install pointing at a different real file (a HOME containing metacharacters)" 1 \
    "points at a different real file"
  st_expect_contains "quotes how to remove it" "then remove it: rm $(rein_shell_quote "$r16_link")"
  st_expect_argv "how to remove it is passed word by word" "$r16_init_out" \
    "then remove it: rm " $'\n' \
    "$r16_link"
  st_expect_true "init's guidance is never evaluated as command substitution" test ! -e "$tmp/r16i-pwned"
  rm -f "$r16_link"
}
