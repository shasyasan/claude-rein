# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034  # selftest state is shared across sections (the caller selftest()'s locals and the ST_* globals)
# The directive above applies to the **whole file** -- in this file, neither an unused local
# inside a function nor a misspelled reference gets caught. The shared variables are scattered
# across the whole file, so a line-level directive can't be scoped tightly enough.
# selftest for prune.
# Not an executable script, so it carries no execute bit (out of scope for the --selftest convention).

st_section_prune() {
  local seat_log3 seat_ts3
  local runtime_spec spec_names spec_impl_names spec_missing spec_extra

  # The list of runtime-data names has two owners: the implementation (the shared library's set)
  # and the verbatim specification (a prose list). The spec side is only ever seen by readers, so
  # a name added to the implementation silently leaves it behind unless this cross-checks it by
  # machine. Checking both directions guards against being structurally blind to a name missing
  # from the spec or an extra one sitting in it. A spec that can't be read fails outright rather
  # than being skipped (never green on a round that never actually checked).
  runtime_spec="$REIN_REPO_ROOT/docs/spec/runtime.md"
  if [ ! -f "$runtime_spec" ]; then
    st_fail "can cross-check the runtime-artifact list against the verbatim spec" "${runtime_spec} does not exist"
  else
    # Picks up only what's inside backticks on the one listing line (a trailing `/` is just a
    # directory decoration, stripped).
    spec_names="$(awk '/^- Runtime data consists of/ { print; exit }' "$runtime_spec" |
      tr '`' '\n' | awk 'NR % 2 == 0' | sed 's:/$::' | LC_ALL=C sort -u)"
    spec_impl_names="$(printf '%s\n' "${REIN_RUNTIME_ARTIFACT_NAMES[@]}" | LC_ALL=C sort -u)"
    if [ -n "$spec_names" ] && [ "$spec_names" = "$spec_impl_names" ]; then
      st_ok
    else
      spec_missing="$(LC_ALL=C comm -23 <(printf '%s\n' "$spec_impl_names") \
        <(printf '%s\n' "$spec_names") | tr '\n' ' ')"
      spec_extra="$(LC_ALL=C comm -13 <(printf '%s\n' "$spec_impl_names") \
        <(printf '%s\n' "$spec_names") | tr '\n' ' ')"
      st_fail "the runtime-artifact list matches the verbatim spec" \
        "missing from the doc: [${spec_missing}] / missing from the implementation: [${spec_extra}]"
    fi
  fi

  # A separate lineage (counts cleanup candidates, so it must not mix with the previous case's
  # leftovers). Isolation is done by swapping out the XDG state area, not --root -- --root sets
  # up a runtime_dir environment layer, which makes it a lineage with an explicit location, and
  # the cross-lineage orphan scan doesn't even apply to those.
  proj3="$tmp/prune-proj"
  state3="$tmp/prune-state"
  mkdir -p "$proj3/$REIN_RECORDS_DIRNAME"
  proj3="$(cd "$proj3" && pwd -P)"
  root3="$state3/rein"
  runtime3="$root3/$(rein_cwd_key "$proj3")"
  mkdir -p "$runtime3/$REIN_PROCESSED_DIRNAME"
  printf '%s\n' "$proj3" >"$runtime3/$REIN_OWNER_BASENAME"
  agents3="$tmp/prune-agents.json"
  log3="$proj3/$REIN_RECORDS_DIRNAME/$REIN_LOG_BASENAME"
  pointer3="$proj3/$REIN_RECORDS_DIRNAME/$REIN_POINTER_BASENAME"
  # Mixes a live current primary session with a finished, completed generation into one
  # enumeration. Just like the real CLI, the fake one puts **only live entries** in the plain
  # enumeration, and only returns a finished one when `--all` is given -- so this section's
  # session candidate only ever materializes when run through `rein_list_agents_all` (swapping
  # the enumeration entry point for the plain one leaves no short job ID to resolve, and zero
  # candidates turn up).
  rein_st_write_agents "$agents3" "$proj3" "sess-cur"
  rein_st_write_agents_done "$tmp/prune-done.json" "$proj3" "sess-old" "sess-halfway"
  jq -s 'add' "$agents3" "$tmp/prune-done.json" >"$tmp/prune-merged.json"
  mv "$tmp/prune-merged.json" "$agents3"
  rein_st_write_pointer "$pointer3" "sess-cur" "cur" "$proj3" 3
  # Generation 1 (sess-old) is a completed handover. Generation 2 (sess-halfway) has an advanced
  # pointer but no completion event -- a handover that stalled partway (not something safe to
  # say can be deleted).
  {
    printf '{"schema":"%s","ts":"%s","event":"pointer_updated","detail":"","generation":1,"predecessor_session_id":null,"successor_session_id":"sess-old"}\n' \
      "$REIN_LOG_SCHEMA" "$(rein_iso_now)"
    printf '{"schema":"%s","ts":"%s","event":"pointer_updated","detail":"","generation":2,"predecessor_session_id":"sess-old","successor_session_id":"sess-halfway"}\n' \
      "$REIN_LOG_SCHEMA" "$(rein_iso_now)"
    printf '{"schema":"%s","ts":"%s","event":"handover_completed","detail":"","generation":2,"predecessor_session_id":"sess-old","successor_session_id":"sess-halfway"}\n' \
      "$REIN_LOG_SCHEMA" "$(rein_iso_now)"
    printf '{"schema":"%s","ts":"%s","event":"pointer_updated","detail":"","generation":3,"predecessor_session_id":"sess-halfway","successor_session_id":"sess-cur"}\n' \
      "$REIN_LOG_SCHEMA" "$(rein_iso_now)"
  } >"$log3"
  # An orphan (owner's work tree doesn't exist), an owner that can't be confirmed, a running one,
  # and a directory that isn't rein's.
  orphan_dir="$root3/gone-000000000001"
  mkdir -p "$orphan_dir"
  printf '%s\n' "$tmp/never-existed" >"$orphan_dir/$REIN_OWNER_BASENAME"
  archive_dir="$root3/nameless-000000000002"
  mkdir -p "$archive_dir"
  : >"$archive_dir/$REIN_HEARTBEAT_BASENAME"
  alive_dir="$root3/alive-000000000003"
  mkdir -p "$alive_dir/$REIN_LOCK_DIRNAME"
  printf '%s\n' "$$" >"$alive_dir/$REIN_LOCK_DIRNAME/pid"
  plain_dir="$root3/not-rein"
  mkdir -p "$plain_dir"
  : >"$plain_dir/README"
  # A lineage whose key starts with a dot (a work tree like ~/.claude has a key that starts with
  # a dot too). The `*/` glob doesn't match it, so it falls out of the scan entirely (the orphan
  # would linger forever).
  dotted_dir="$root3/.dotproj-000000000008"
  mkdir -p "$dotted_dir"
  printf '%s\n' "$tmp/never-existed" >"$dotted_dir/$REIN_OWNER_BASENAME"
  # Things that must never be deleted (the safety of an irreversible delete).
  # (1) A lineage that hasn't moved its location -- the case where lineage records (the handover
  #     log, the canonical audit trail) still sit under the runtime directory. The watcher
  #     already guards this exact state by refusing to start there, so if prune went and deleted
  #     it too, one mechanism would both guard and delete the same state.
  stranded_dir="$root3/stranded-000000000004"
  mkdir -p "$stranded_dir/$REIN_PROCESSED_DIRNAME"
  : >"$stranded_dir/$REIN_HEARTBEAT_BASENAME"
  rein_st_write_pointer "$stranded_dir/$REIN_POINTER_BASENAME" "sess-stranded" "old" "$tmp/never-existed" 1
  printf '{"schema":"%s","ts":"%s","event":"pointer_updated","detail":"","generation":1,"predecessor_session_id":null,"successor_session_id":"sess-stranded"}\n' \
    "$REIN_LOG_SCHEMA" "$(rein_iso_now)" >"$stranded_dir/$REIN_LOG_BASENAME"
  # (2) A name that isn't key-shaped (<basename>-<12 hex digits>) -- not a per-lineage directory rein created.
  notkey_dir="$root3/plainname"
  mkdir -p "$notkey_dir"
  : >"$notkey_dir/$REIN_HEARTBEAT_BASENAME"
  # (3) A directory holding only generic names (processing / processed / rejected).
  generic_dir="$root3/generic-000000000005"
  mkdir -p "$generic_dir/$REIN_PROCESSING_DIRNAME"
  : >"$generic_dir/keep-me.txt"
  # (4) A lineage holding a watcher lock whose owner can't be confirmed (a watcher right after
  #     claiming the lock, or a lock with just a corrupt pid). This module's rule is that a lock
  #     that can't be judged is never seized.
  unreadable_dir="$root3/unreadable-000000000006"
  mkdir -p "$unreadable_dir/$REIN_LOCK_DIRNAME"
  printf 'not-a-pid\n' >"$unreadable_dir/$REIN_LOCK_DIRNAME/pid"
  # (5) A lineage whose seat lock's owner is alive (the user's own terminal is sitting there
  #     even though the watcher is down). The mechanism doesn't steal a seat someone's actively
  #     using -- same rule as the watcher lock, never a candidate.
  seatalive_dir="$root3/seatalive-000000000010"
  mkdir -p "$seatalive_dir/$REIN_SEAT_LOCK_DIRNAME"
  : >"$seatalive_dir/$REIN_HEARTBEAT_BASENAME"
  printf '%s\n' "$$" >"$seatalive_dir/$REIN_SEAT_LOCK_DIRNAME/pid"
  # (6) An orphan whose name contains a newline and a TAB. An implementation that packs candidates
  #     into one delimited string would let this inject a row naming a different kind and a
  #     different target, deleting a file outside the location. The injectable target is limited
  #     to one directory-name word (a `/` can't be part of a name) -- meaning a path relative to
  #     the cwd of whoever ran it, so this check runs from there too.
  inject_victim="prune-victim.txt"
  printf 'victim\n' >"$tmp/$inject_victim"
  inject_dir="$root3/$(printf 'inj\narchive\t%s\tinjected-0123456789ab' "$inject_victim")"
  mkdir -p "$inject_dir"
  : >"$inject_dir/$REIN_HEARTBEAT_BASENAME"
  # An orphan carrying a seat lock whose owner is gone, leftover launch settings from a failed
  # round, and a seat-stop marker nobody consumed. All of these are known runtime artifacts --
  # anything not on the name list makes the final rmdir fail, reporting that something unknown
  # remains.
  leftover_dir="$root3/leftover-000000000011"
  mkdir -p "$leftover_dir/$REIN_SEAT_LOCK_DIRNAME"
  printf '%s\n' "$tmp/never-existed" >"$leftover_dir/$REIN_OWNER_BASENAME"
  printf '99999999\n' >"$leftover_dir/$REIN_SEAT_LOCK_DIRNAME/pid"
  mkdir -p "$leftover_dir/${REIN_SEAT_LOCK_DIRNAME}.claim.stale"
  printf '{}\n' >"$leftover_dir/${REIN_MANAGED_SETTINGS_PREFIX}stale.json"
  printf '{"schema":"%s","requested_at":"%s","requested_by_pid":%s}\n' \
    "$REIN_SEAT_STOP_SCHEMA" "$(rein_iso_now)" "$$" >"$leftover_dir/$REIN_SEAT_STOP_BASENAME"
  : >"$runtime3/$REIN_PROCESSED_DIRNAME/old.json"
  touch -t 200001010000 "$runtime3/$REIN_PROCESSED_DIRNAME/old.json"
  # There are 3 archive locations (processed / rejected / cancelled). **Cancellations' own
  # archive is scanned too** -- pin that here, since leaving even one out would make it the one
  # location the archive_days cleanup never reaches, growing unbounded (the only way to clear it
  # then becomes tearing down the whole lineage). The name is chosen so it never partially
  # matches the existing `old.json` (if one match also passed the other, there'd be no telling
  # which one actually turned up).
  mkdir -p "$runtime3/$REIN_CANCELLED_DIRNAME" "$runtime3/$REIN_REJECTED_DIRNAME"
  : >"$runtime3/$REIN_CANCELLED_DIRNAME/old-cancel.json"
  touch -t 200001010000 "$runtime3/$REIN_CANCELLED_DIRNAME/old-cancel.json"
  : >"$runtime3/$REIN_REJECTED_DIRNAME/old-reject.json"
  touch -t 200001010000 "$runtime3/$REIN_REJECTED_DIRNAME/old-reject.json"
  # Children-ledger entries. Two belong to sessions the pointer no longer names (leftovers a
  # predecessor stopped externally can never remove for itself -- SubagentStop never arrives),
  # and one belongs to the session the pointer **does** name. The current session's entry is what
  # keeps a running child alive in the eyes of `rein request`, so a scan that swept it up would
  # quietly reopen the very hole the ledger exists to close -- it's pinned here on both sides.
  mkdir -p "$runtime3/$REIN_CHILDREN_DIRNAME"
  printf 'Explore\n1\n\n' >"$runtime3/$REIN_CHILDREN_DIRNAME/sess-old.a1"
  # A second leftover, from a session this fixture's handover log never mentions at all -- the
  # scan's rule is "not the session the pointer names," never "a generation the log knows about."
  printf 'Explore\n1\n\n' >"$runtime3/$REIN_CHILDREN_DIRNAME/sess-gone.a2"
  printf 'Explore\n1\n\n' >"$runtime3/$REIN_CHILDREN_DIRNAME/sess-cur.a3"
  # A leftover whose session_id starts with a dot. Nothing rejects such an id, and a `*` glob
  # skips it -- that lineage's ledger would then grow with no way to ever clear it.
  printf 'Explore\n1\n\n' >"$runtime3/$REIN_CHILDREN_DIRNAME/.sess-dot.a4"
  rein_st_isolation_env "$tmp/prune-user-config" "$tmp/prune-xdg-config" "$state3"
  ST_VERB_ENV=(
    "${REIN_ST_ENV_ARGS[@]}"
    "PATH=${verb_bin}:${PATH}"
    "FAKE_LOG=$verb_log"
    "FAKE_NOTIFY_LOG=$tmp/notify.log"
    "FAKE_AGENTS=$agents3"
    "REIN_POLL_INTERVAL_SEC=0.2"
    "REIN_CMD_TIMEOUT_SEC=10"
  )
  : >"$verb_log"
  # The default scan is the two lineage-local kinds -- archives and leftover children-ledger
  # entries (the cross-lineage orphan scan and the delete that shells out to an external CLI are
  # added explicitly).
  st_run_env --cwd "$proj3" prune
  if st_expect_status "the default prune ends with 0" 0; then
    st_expect_contains "the default lists archived entries" "old.json"
    st_expect_contains "the default also lists the cancellation archive" "old-cancel.json"
    st_expect_contains "the default also lists the rejection archive" "old-reject.json"
    st_expect_contains "the default's subtotal is archive and child" "candidates: archive 3 / child 3"
    st_expect_not_contains "the default doesn't list orphans" "orphan"$'\t'
    st_expect_not_contains "the default doesn't list sessions" "finished generation"
    st_expect_contains "points at the entry point that runs it" "add -f to actually delete (nothing was deleted)"
    # The ledger entries of sessions the pointer no longer names are candidates; the current
    # session's own entry never is (deleting it would let a handover go out while that session's
    # child is still running -- the exact hole the ledger closes).
    st_expect_contains "lists a leftover children-ledger entry" "child	${runtime3}/$REIN_CHILDREN_DIRNAME/sess-old.a1"
    st_expect_contains "lists a leftover from a session the handover log never mentions" \
      "child	${runtime3}/$REIN_CHILDREN_DIRNAME/sess-gone.a2"
    st_expect_contains "lists a leftover whose session_id starts with a dot" \
      "child	${runtime3}/$REIN_CHILDREN_DIRNAME/.sess-dot.a4"
    st_expect_not_contains "never lists the current session's own children-ledger entry" \
      "child	${runtime3}/$REIN_CHILDREN_DIRNAME/sess-cur.a3"
  fi
  st_expect_true "the default preview doesn't delete archived entries" test -e "$runtime3/$REIN_PROCESSED_DIRNAME/old.json"
  st_expect_true "the default preview doesn't delete the cancellation archive either" \
    test -e "$runtime3/$REIN_CANCELLED_DIRNAME/old-cancel.json"
  st_expect_true "the default preview doesn't delete the rejection archive either" \
    test -e "$runtime3/$REIN_REJECTED_DIRNAME/old-reject.json"
  # Additional kinds via -o / -s (combinable), or -a for everything.
  st_run_env --cwd "$proj3" prune -o
  if st_expect_status "-o adds orphans" 0; then
    st_expect_contains "-o lists orphans" "the owner's work tree doesn't exist"
    st_expect_not_contains "-o doesn't add sessions" "finished generation"
    st_expect_contains "-o's subtotal adds orphan" "candidates: archive 3 / child 3 / orphan 5"
  fi
  st_run_env --cwd "$proj3" prune -s
  if st_expect_status "-s adds sessions" 0; then
    st_expect_contains "-s lists sessions" "session sess-old of finished generation 1"
    st_expect_not_contains "-s doesn't add orphans" "the owner's work tree doesn't exist"
  fi
  st_run_env --cwd "$proj3" prune -o -s
  st_expect_contains "-o and -s can be combined" "candidates: archive 3 / child 3 / orphan 5 / session 1"
  st_run_env --cwd "$proj3" prune --all
  if st_expect_status "prune's preview ends with 0" 0; then
    st_expect_contains "lists sessions of a finished generation" "session sess-old of finished generation 1"
    st_expect_not_contains "doesn't list a generation with no completion event" "sess-halfway"
    st_expect_contains "lists orphaned runtime directories" "the owner's work tree doesn't exist"
    st_expect_contains "lists runtime directories with no owner" "there is no owner file"
    st_expect_not_contains "doesn't list a running lineage" "orphan	${alive_dir}"
    st_expect_contains "a resident watcher lock is shown with a reason" \
      "watcher lock whose owner (pid="
    st_expect_not_contains "doesn't list an attached lineage" "orphan	${seatalive_dir}"
    st_expect_contains "an attached seat lock is shown with a reason" \
      "seat lock whose owner (pid="
    st_expect_contains "lists an orphan carrying a seat lock with no owner" "orphan	${leftover_dir}"
    st_expect_not_contains "doesn't list something that isn't rein's runtime artifact" "$plain_dir"
    st_expect_not_contains "doesn't list a location that still holds lineage records" "orphan	${stranded_dir}"
    st_expect_contains "points at moving a location that still holds lineage records" "lineage records still remain"
    st_expect_not_contains "doesn't list a name that isn't key-shaped" "$notkey_dir"
    st_expect_not_contains "doesn't list a directory with only generic names" "$generic_dir"
    st_expect_not_contains "doesn't list a lineage with an unreadable watcher lock" "orphan	${unreadable_dir}"
    st_expect_contains "an unreadable watcher lock is shown with a reason" "watcher lock whose owner can't be confirmed"
    st_expect_contains "lists an archived entry old enough at the default age (30 days)" "old.json"
    st_expect_contains "also scans a lineage starting with a dot" "$dotted_dir"
    # 1 finished-generation session + 5 orphans (an owner whose work tree doesn't exist, an
    # unknown owner, one starting with a dot, one with a newline in its name, one carrying a
    # seat lock with no owner) + 3 archived entries (one each in processed / rejected /
    # cancelled -- covering the 3 scanned locations so leaving even one out is always caught red).
    st_expect_contains "reports a subtotal per kind" "candidates: archive 3 / child 3 / orphan 5 / session 1"
  fi
  st_expect_true "the preview doesn't delete" test -d "$orphan_dir"
  if [ "$(rein_st_count_sub "$verb_log" rm)" -eq 0 ]; then
    st_ok
  else
    st_fail "the preview never calls claude rm" "$(cat "$verb_log")"
  fi
  # `status`'s candidate line goes through the same counting as prune (never a case where the
  # current state says 0 while prune turns up some). **The name the guidance calls itself by
  # (`rein`, or the real path) changes with what the machine has on PATH**, so it isn't checked
  # here -- what this case measures is the counting and the naming of the lineage, and the name
  # itself is measured on both sides by doctor's own not-installed / installed pair
  # (`st_section_doctor`).
  st_run_env --cwd "$proj3" status
  st_expect_contains "status reports cleanup candidates" \
    "cleanup candidates: archive 3 / child 3 / orphan 5 / session 1 (list with "
  st_expect_contains "the cleanup guidance names this lineage" \
    " --cwd $(rein_shell_quote "$proj3") prune)"
  st_run_env --cwd "$proj3" status --json
  if [ "$(printf '%s' "$ST_OUT" | jq -r '.prune_candidates.archive' 2>/dev/null)" = "3" ] &&
    [ "$(printf '%s' "$ST_OUT" | jq -r '.prune_candidates.orphan' 2>/dev/null)" = "5" ] &&
    [ "$(printf '%s' "$ST_OUT" | jq -r '.prune_candidates.session' 2>/dev/null)" = "1" ] &&
    [ "$(printf '%s' "$ST_OUT" | jq -r '.prune_candidates.session_reason' 2>/dev/null)" = "null" ] &&
    [ "$(printf '%s' "$ST_OUT" | jq -r '.prune_candidates.child' 2>/dev/null)" = "3" ] &&
    [ "$(printf '%s' "$ST_OUT" | jq -r '.prune_candidates.child_reason' 2>/dev/null)" = "null" ]; then
    st_ok
  else
    st_fail "status --json carries the candidate counts" "$ST_OUT"
  fi
  # A lineage with an explicit location can't run the cross-lineage orphan scan. Folding it to 0
  # would make never scanned and no candidates look identical, so it's shown the same way as
  # session (the kind that can't be counted). The counting side is already covered by the two
  # cases above (orphan 5 at the default location), so both sides are pinned.
  st_run_env --cwd "$proj3" status --runtime-dir "$runtime3"
  st_expect_contains "orphan is never folded to 0 for a lineage that doesn't scan" "orphan not scanned"
  st_expect_contains "shows the reason it doesn't scan" "orphan: this lineage names its runtime data location explicitly"
  st_run_env --cwd "$proj3" status --json --runtime-dir "$runtime3"
  if [ "$(printf '%s' "$ST_OUT" | jq -r '.prune_candidates.orphan' 2>/dev/null)" = "null" ] &&
    [ "$(printf '%s' "$ST_OUT" | jq -r '.prune_candidates.orphan_reason' 2>/dev/null)" != "null" ]; then
    st_ok
  else
    st_fail "status --json reports an unscanned orphan as null plus a reason" "$ST_OUT"
  fi
  # The current state fetches enumeration exactly once (the primary session's liveness and the
  # candidate count read the same one fetch). Fetching it per reader would double status's own
  # wait on an environment where enumeration is slow or hangs.
  : >"$verb_log"
  st_run_env --cwd "$proj3" status --json
  if [ "$(rein_st_calls_total "$verb_log")" -eq 1 ] &&
    [ "$(rein_st_count_sub "$verb_log" agents)" -eq 1 ]; then
    st_ok
  else
    st_fail "status fetches enumeration exactly once" "$(cat "$verb_log")"
  fi

  # Fails on a broken current pointer. It's the sole input that names what must not be deleted,
  # so proceeding with one that can't be read would let even a session of the current generation
  # into the candidates for claude rm.
  mv "$pointer3" "$tmp/prune-pointer.bak"
  jq -nc '{schema: "rein.current.v0", session_id: "sess-cur", cwd: "/elsewhere", generation: "abc"}' >"$pointer3"
  st_run_env --cwd "$proj3" prune --session
  st_expect_reject "fails on a broken current pointer" 1 "cannot validate the current pointer"
  # The children ledger reads the same pointer for the same reason, so an unreadable one leaves
  # **nothing** a candidate there either -- with the reason shown, never silently as 0. Unlike
  # session it doesn't fail the whole run: this kind is in the default scan, and failing here
  # would take a plain `rein prune` down with it.
  st_run_env --cwd "$proj3" prune
  if st_expect_status "a broken pointer doesn't fail the default scan" 0; then
    st_expect_contains "the children ledger isn't scanned on a broken pointer" \
      "cannot validate the current pointer, so the children ledger is not scanned"
    st_expect_not_contains "no children-ledger entry becomes a candidate on a broken pointer" \
      "child	${runtime3}/$REIN_CHILDREN_DIRNAME/"
    st_expect_contains "the preview still reports the subtotal, with the reason above it" \
      "candidates: archive 3 / child 0"
  fi
  st_run_env --cwd "$proj3" status
  st_expect_contains "the current state reports child as not scanned, with the reason" \
    "child not scanned"
  mv "$tmp/prune-pointer.bak" "$pointer3"
  # An archived entry's age is config's archive_days (default 30, a nonnegative integer). Never
  # silently falls back to the default on an invalid value.
  st_run_env --cwd "$proj3" config get archive_days
  st_expect_out "archive_days defaults to 30" "30"
  st_run_with "REIN_ARCHIVE_DAYS=99999" --cwd "$proj3" prune
  if st_expect_status "archive_days can be stretched" 0; then
    st_expect_not_contains "an archived entry newer than the cap isn't listed" "old.json"
    st_expect_not_contains "the cap applies to the cancellation archive too" "old-cancel.json"
    st_expect_not_contains "the cap applies to the rejection archive too" "old-reject.json"
  fi
  st_run_with "REIN_ARCHIVE_DAYS=abc" --cwd "$proj3" prune
  st_expect_reject "rejects a non-numeric archive_days" 1 "archive_days"
  st_run_with "REIN_ARCHIVE_DAYS=-1" --cwd "$proj3" prune
  st_expect_reject "rejects a negative archive_days" 1 "archive_days"
  # A retired entry point is never silently ignored -- it's rejected as an unknown argument.
  st_run_env --cwd "$proj3" prune --apply
  st_expect_reject "prune doesn't accept --apply" 2 "unknown argument to prune: --apply"
  st_run_env --cwd "$proj3" prune --only orphan
  st_expect_reject "prune doesn't accept --only" 2 "unknown argument to prune: --only"
  st_run_env --cwd "$proj3" prune --archives-older-than 1
  st_expect_reject "prune doesn't accept --archives-older-than" 2 \
    "unknown argument to prune: --archives-older-than"
  # Long and short forms produce the same result (the preview's listing is the same text for the same state).
  st_run_env --cwd "$proj3" prune --orphan
  alias_prune_out="$ST_OUT"
  st_run_env --cwd "$proj3" prune -o
  st_expect_out "-o lists the same candidates as --orphan" "$alias_prune_out"
  st_run_env --cwd "$proj3" prune --session
  alias_prune_out="$ST_OUT"
  st_run_env --cwd "$proj3" prune -s
  st_expect_out "-s lists the same candidates as --session" "$alias_prune_out"
  st_run_env --cwd "$proj3" prune --all
  alias_prune_out="$ST_OUT"
  st_run_env --cwd "$proj3" prune -a
  st_expect_out "-a lists the same candidates as --all" "$alias_prune_out"
  # A lineage with an explicit location never runs the cross-lineage scan at all (the scan root
  # would become its parent, sweeping through directories unrelated to rein).
  st_run_env --cwd "$proj3" prune --orphan --runtime-dir "$runtime3"
  if st_expect_status "prune with an explicit location also ends with 0" 0; then
    st_expect_contains "shows the reason it doesn't scan cross-lineage" "the cross-lineage orphan scan does not run"
    st_expect_not_contains "doesn't list orphans for a lineage with an explicit location" "$orphan_dir"
  fi
  st_expect_true "doesn't delete orphans for a lineage with an explicit location" test -d "$orphan_dir"

  : >"$verb_log"
  # Deleting the relative path injected from the name happens in the cwd of whoever ran it, so
  # the apply run is launched from a temp directory that has the victim placed in it.
  ST_OUT="$(cd "$tmp" && env "${ST_VERB_ENV[@]}" "$ST_BASH" "$REIN_BIN_PATH" \
    --cwd "$proj3" prune --all --force 2>&1 </dev/null)"
  ST_STATUS=$?
  # The "must never be deleted" checks sit outside the exit-code branch (if a round that fails
  # non-zero also skipped the checks, depending on how it broke, the deletion itself might go
  # unobserved).
  st_expect_true "doesn't delete a running lineage" test -d "$alive_dir"
  st_expect_true "doesn't delete something that isn't rein's runtime artifact" test -d "$plain_dir"
  st_expect_true "doesn't delete its own lineage" test -d "$runtime3"
  st_expect_true "doesn't delete lineage records" test -f "$stranded_dir/$REIN_LOG_BASENAME"
  st_expect_true "keeps the lineage-records location intact" test -f "$stranded_dir/$REIN_POINTER_BASENAME"
  st_expect_true "doesn't delete a name that isn't key-shaped" test -d "$notkey_dir"
  st_expect_true "doesn't delete a directory with only generic names" test -f "$generic_dir/keep-me.txt"
  st_expect_true "doesn't delete a lineage with an unreadable watcher lock" test -d "$unreadable_dir"
  st_expect_true "doesn't delete an attached lineage" test -d "$seatalive_dir"
  st_expect_true "doesn't touch an attached lineage's seat lock either" \
    test -e "$seatalive_dir/$REIN_SEAT_LOCK_DIRNAME/pid"
  st_expect_true "doesn't delete the target injected from a name" test -f "$tmp/$inject_victim"
  if st_expect_status "prune --force ends with 0" 0; then
    st_expect_true "deletes an archived entry older than the default age" \
      test ! -e "$runtime3/$REIN_PROCESSED_DIRNAME/old.json"
    st_expect_true "deletes the cancellation archive at the same age too" \
      test ! -e "$runtime3/$REIN_CANCELLED_DIRNAME/old-cancel.json"
    st_expect_true "deletes the rejection archive at the same age too" \
      test ! -e "$runtime3/$REIN_REJECTED_DIRNAME/old-reject.json"
    st_expect_true "deletes a leftover children-ledger entry" \
      test ! -e "$runtime3/$REIN_CHILDREN_DIRNAME/sess-old.a1"
    st_expect_true "deletes a leftover from a session the handover log never mentions" \
      test ! -e "$runtime3/$REIN_CHILDREN_DIRNAME/sess-gone.a2"
    st_expect_true "deletes a leftover whose session_id starts with a dot" \
      test ! -e "$runtime3/$REIN_CHILDREN_DIRNAME/.sess-dot.a4"
    st_expect_true "never deletes the current session's own children-ledger entry" \
      test -e "$runtime3/$REIN_CHILDREN_DIRNAME/sess-cur.a3"
    st_expect_true "deletes an orphaned runtime directory" test ! -e "$orphan_dir"
    st_expect_true "deletes a runtime directory with no owner" test ! -e "$archive_dir"
    st_expect_true "also deletes an orphan starting with a dot" test ! -e "$dotted_dir"
    st_expect_true "folds down an orphan carrying a seat lock and leftover launch settings" test ! -e "$leftover_dir"
    if rein_st_has_call "$verb_log" rm "job-sess-old"; then
      st_ok
    else
      st_fail "deletes a finished generation via claude rm" "$(cat "$verb_log")"
    fi
    if [ "$(rein_st_count_sub "$verb_log" rm)" -eq 1 ]; then
      st_ok
    else
      st_fail "doesn't delete the current primary session" "$(cat "$verb_log")"
    fi
    # The closing summary (how many were deleted, and how many were excluded with a reason).
    st_expect_contains "reports the run's summary" "deleted 12 / excluded "
  fi
  st_run_env --cwd "$proj3" prune --all
  if st_expect_status "prune after cleanup is 0" 0; then
    st_expect_contains "says there's nothing left to clean up" "nothing to clean up"
    st_expect_contains "still reports a subtotal even with nothing there" "candidates: archive 0"
  fi
  # The short and long forms of the run entry point are measured here, once candidates have
  # dropped to 0 (the same run can be issued twice). Whether the short form is read as the run
  # entry point (rather than only ever producing a preview) is measured by the run summary
  # ("deleted N") showing up.
  st_run_env --cwd "$proj3" prune --all --force
  alias_prune_out="$ST_OUT"
  st_run_env --cwd "$proj3" prune -a -f
  st_expect_out "-f produces the same result as --force" "$alias_prune_out"
  st_expect_contains "-f is also read as the run entry point" "deleted 0"
  # Only the known runtime-artifact names are deleted individually, so anything rein doesn't know
  # about that was left behind comes to the surface (never swept up by an `rm -rf` alongside
  # anything placed between the dry run and applying it).
  unknown_dir="$root3/unknown-000000000007"
  mkdir -p "$unknown_dir"
  : >"$unknown_dir/$REIN_HEARTBEAT_BASENAME"
  : >"$unknown_dir/someone-elses-file"
  st_run_env --cwd "$proj3" prune --orphan --force
  if st_expect_reject "a location with something unknown left in it isn't fully torn down" 1 "something rein doesn't recognize remains"; then
    st_expect_true "the unknown thing stays" test -f "$unknown_dir/someone-elses-file"
    st_expect_true "the known runtime artifact is gone" test ! -e "$unknown_dir/$REIN_HEARTBEAT_BASENAME"
    # **Never says the opposite of what happened.** By the time this report is reached, the
    # known runtime artifacts are already deleted, so claiming "not deleted" would leave the
    # reader thinking nothing was deleted at all, while actually losing the owner file (what every
    # entry point verifies before it touches the location, and status --all's identification) and any unhandled handover
    # requests. Names what was actually deleted.
    st_expect_contains "names what was deleted" "artifacts deleted: ${REIN_HEARTBEAT_BASENAME}"
    st_expect_not_contains "doesn't report zero artifacts deleted on a round that did delete something" "artifacts deleted: none"
    st_expect_not_contains "doesn't say it wasn't deleted on a round that did delete" "not deleted"
  fi
  rm -rf "$unknown_dir"
  # Takes the target's own operation lock before deleting. A lineage where it can't be taken
  # (another rein is running there, or `up` is in the middle of starting the watcher) isn't
  # deleted -- closing the window between re-validating and deleting.
  locked_dir="$root3/locked-000000000009"
  mkdir -p "$locked_dir/$REIN_OP_LOCK_DIRNAME"
  : >"$locked_dir/$REIN_HEARTBEAT_BASENAME"
  printf '%s\n' "$$" >"$locked_dir/$REIN_OP_LOCK_DIRNAME/pid"
  st_run_env --cwd "$proj3" prune --orphan --force
  if st_expect_reject "a lineage with an operation in progress isn't deleted" 1 "another rein operation is in progress"; then
    st_expect_true "a lineage with an operation in progress remains" test -d "$locked_dir"
    st_expect_true "its runtime artifacts aren't touched either" test -e "$locked_dir/$REIN_HEARTBEAT_BASENAME"
    st_expect_file "doesn't steal someone else's operation lock" "$locked_dir/$REIN_OP_LOCK_DIRNAME/pid" "$$"
    st_expect_true "doesn't leave a temp name behind for a lock it couldn't take" \
      test -z "$(find "$locked_dir" -mindepth 1 -maxdepth 1 -name 'op.lock.*' -print)"
  fi
  # A lock with no owner (stale) is reclaimed and fully deleted, under the same rule as up / down.
  printf '99999999\n' >"$locked_dir/$REIN_OP_LOCK_DIRNAME/pid"
  st_run_env --cwd "$proj3" prune --orphan --force
  if st_expect_status "a lineage whose lock's owner is gone can be deleted" 0; then
    st_expect_true "reclaims it and deletes fully" test ! -e "$locked_dir"
  fi
  # A delete failure is never swallowed (cleanup is irreversible, so returning 0 on a failure
  # would be misread as the target being gone). Checks all the way down to the reason text's rc -- pinning
  # that the external command's own exit code is what actually flows through (so changing how
  # output is discarded doesn't quietly turn the failure reason into something else; the fake CLI's rm fails with 6).
  rein_st_write_agents_done "$agents3" "$proj3" "sess-old"
  ST_VERB_ENV+=("FAKE_RM_FAIL=1")
  st_run_env --cwd "$proj3" prune --all --force
  st_expect_reject "doesn't swallow a claude rm failure" 1 "claude rm job-sess-old failed: rc=6"
  # Never give an unreadable handover log the same face as having nothing to target (that would
  # silence whatever is left uncleaned).
  cp "$log3" "$tmp/prune-log.bak"
  printf 'this is not JSON\n' >>"$log3"
  st_run_env --cwd "$proj3" prune --session
  st_expect_reject "fails on a broken handover log" 1 "cannot read the handover log"
  mv "$tmp/prune-log.bak" "$log3"
  ST_VERB_ENV=(
    "${REIN_ST_ENV_ARGS[@]}"
    "PATH=${verb_bin}:${PATH}"
    "FAKE_LOG=$verb_log"
    "FAKE_NOTIFY_LOG=$tmp/notify.log"
    "FAKE_AGENTS=$tmp/absent-agents.json"
    "REIN_POLL_INTERVAL_SEC=0.2"
    "REIN_CMD_TIMEOUT_SEC=10"
  )
  st_run_env --cwd "$proj3" prune --session
  st_expect_reject "fails when enumeration can't be read" 1 "cannot read claude agents --json"
  # The other side: without selecting session, enumeration is never read, so the default and -o still pass on the same environment.
  st_run_env --cwd "$proj3" prune -o
  st_expect_status "-o still passes even when enumeration can't be read" 0 && st_ok
  # A kind that can't be counted never folds to 0 -- it is shown as "undetermined" (never a case
  # where the current state reads as having no candidates).
  st_run_env --cwd "$proj3" status
  st_expect_contains "an uncountable candidate is shown as undetermined" "session undetermined"
  st_run_env --cwd "$proj3" status --json
  if [ "$(printf '%s' "$ST_OUT" | jq -r '.prune_candidates.session' 2>/dev/null)" = "null" ] &&
    [ "$(printf '%s' "$ST_OUT" | jq -r '.prune_candidates.session_reason' 2>/dev/null)" != "null" ]; then
    st_ok
  else
    st_fail "status --json reports an uncountable candidate as null plus a reason" "$ST_OUT"
  fi
  # The seat's own log is only ever written by the attach loop. This lineage has only ever run
  # prune and status, so if the record exists, a writer has been added (a path meant to be
  # read-only is writing).
  seat_log3="$proj3/$REIN_RECORDS_DIRNAME/$REIN_SEAT_LOG_BASENAME"
  st_expect_true "no verb other than seat writes the seat log" test ! -e "$seat_log3"
  # The current state reports the seat log's last line. **Looked at from the absent side first**
  # -- a log that isn't there and one that's there but unreadable can end up looking the same, so
  # checking only one side would let a disconnected reader through unnoticed.
  st_run_env --cwd "$proj3" status
  st_expect_contains "reports none when there's no record" "seat log: none"
  st_run_env --cwd "$proj3" status --json
  if [ "$(printf '%s' "$ST_OUT" | jq -r '.seat_last_event' 2>/dev/null)" = "null" ]; then
    st_ok
  else
    st_fail "status --json is null when there's no record" "$ST_OUT"
  fi
  # The present side: the last line's event and timestamp show in the human-readable line, and
  # --json carries the row itself.
  seat_ts3="$(rein_iso_now)"
  printf '{"schema":"%s","ts":"%s","event":"seat_failed","detail":"a line from the check","generation":null,"predecessor_session_id":null,"successor_session_id":null}\n' \
    "$REIN_SEAT_LOG_SCHEMA" "$seat_ts3" >"$seat_log3"
  st_run_env --cwd "$proj3" status
  st_expect_contains "reports the last line's event and timestamp when there is one" "seat log: seat_failed ${seat_ts3}"
  st_run_env --cwd "$proj3" status --json
  if [ "$(printf '%s' "$ST_OUT" | jq -r '.seat_last_event.event' 2>/dev/null)" = "seat_failed" ] &&
    [ "$(printf '%s' "$ST_OUT" | jq -r '.seat_last_event.ts' 2>/dev/null)" = "$seat_ts3" ] &&
    [ "$(printf '%s' "$ST_OUT" | jq -r '.seat_last_event.detail' 2>/dev/null)" = "a line from the check" ]; then
    st_ok
  else
    st_fail "status --json carries the seat log's last line" "$ST_OUT"
  fi
  # Reports only the last line (adding a second line moves the current state to it too -- never stuck on the first line).
  printf '{"schema":"%s","ts":"%s","event":"attach_started","detail":"a later line","generation":null,"predecessor_session_id":null,"successor_session_id":null}\n' \
    "$REIN_SEAT_LOG_SCHEMA" "$(rein_iso_now)" >>"$seat_log3"
  st_run_env --cwd "$proj3" status
  st_expect_contains "reports only the last line" "seat log: attach_started"
  # Never a cleanup target either (lineage records aren't a runtime artifact -- same treatment as the handover log).
  st_run_env --cwd "$proj3" prune --all --force
  st_expect_true "the seat log is never a cleanup target" test -f "$seat_log3"
  rm -f "$seat_log3"
}
