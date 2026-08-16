# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034  # selftest state is shared across sections (the caller selftest()'s locals, and the ST_* globals)
# Multiple launches and locks: a live owner, a stale lock whose owner is gone, and a lock whose owner cannot be confirmed.
# Variables are shared with the caller selftest()'s locals through dynamic scope. Declaring a
# local inside a section would hide it from later sections, so this section file declares none.
# Not an executable script, so it carries no execute bit (outside the --selftest convention).

st_section_lock() {
  # Only the variables used solely in this section stay local to this function (anything shared
  # across sections goes in selftest()'s locals, as above).
  local lock_owner lock_rc
  # Multiple launches: don't enter monitoring if a live owner already holds the lock (blocks the loser
  # from notifying a rejection for the wrong reason).
  # The owner must **actually be a watcher** -- use the daemon fixture that watches this location.
  case_dir="$tmp/lock-busy"
  st_setup_case "$case_dir"
  rein_st_start_fake_watcher "$ST_RUNTIME" "$ST_CWD"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  st_run_watcher
  if st_expect_status "does not start when a live instance holds the lock" 1; then
    if [ -s "$ST_LOG" ]; then
      st_fail "does not call claude on a duplicate launch" "$(cat "$ST_LOG")"
    elif [ ! -f "$ST_RUNTIME/$REIN_MARKER_BASENAME" ]; then
      st_fail "does not touch the marker on a duplicate launch" "the marker vanished (the loser consumed the request)"
    elif ! st_expect_notify "notifies about a duplicate launch" \
      "rein: cannot start the watcher" "another instance is already watching"; then
      :
    else
      case "$ST_OUT" in
        *"another instance is already watching"*)
          st_ok
          ;;
        *)
          st_fail "gives a reason for the duplicate launch" "${ST_OUT}"
          ;;
      esac
    fi
  fi

  # Also reclaim, as stale, a lock whose owner pid is alive but **is actually a different process**
  # (a PID reuse). Refusing here would leave readers (`status`, the handover-request writer, hooks)
  # reading "not running" while startup stays blocked forever -- a handover could never happen again
  # at this location.
  case_dir="$tmp/lock-pid-reuse"
  st_setup_case "$case_dir"
  mkdir -p "$ST_RUNTIME/$REIN_LOCK_DIRNAME"
  # The check process's own pid (alive, but not the watcher watching this location).
  printf '%s\n' "$$" >"$ST_RUNTIME/$REIN_LOCK_DIRNAME/pid"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  ST_EXIT_AFTER_POLLS=2
  st_run_watcher
  unset ST_EXIT_AFTER_POLLS
  if st_expect_status "reclaims a lock from a PID reuse" 0; then
    if ! st_log_has '"event":"handover_completed"'; then
      st_fail "the handover goes through with a PID-reuse lock" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    else
      st_ok
    fi
  fi

  # A lock with no owner (a stale lock left behind by a previous abnormal exit) is reclaimed and
  # monitoring begins.
  case_dir="$tmp/lock-stale"
  st_setup_case "$case_dir"
  mkdir -p "$ST_RUNTIME/$REIN_LOCK_DIRNAME"
  # Use a pid near the numbering limit (a value `ps` can confirm doesn't exist).
  printf '99998\n' >"$ST_RUNTIME/$REIN_LOCK_DIRNAME/pid"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  ST_EXIT_AFTER_POLLS=2
  st_run_watcher
  unset ST_EXIT_AFTER_POLLS
  if st_expect_status "reclaims a stale lock" 0; then
    if ! st_log_has '"event":"handover_completed"'; then
      st_fail "the handover goes through with a stale lock" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    elif [ -d "$ST_RUNTIME/$REIN_LOCK_DIRNAME" ]; then
      st_fail "also releases the reclaimed lock" "the lock is still there"
    else
      st_ok
    fi
  fi

  # What reclaiming strips is limited to **the lock for the pid the judgment itself saw**. Re-reading
  # the owner after the judgment finishes, in the gap between seeing and stripping, could let another
  # run reclaim the same stale lock and start over it -- a re-read then picks up **the reclaiming
  # side's live pid**, passes the identity check, and strips that live lock (two watchers holding the
  # lock at once). Interruption is injected deterministically via the `ps` shim (riding along the
  # command-line query the judgment issues last).
  case_dir="$tmp/lock-reclaimed-during-judgement"
  st_setup_case "$case_dir"
  mkdir -p "$ST_RUNTIME/$REIN_LOCK_DIRNAME"
  # The check process's own pid (alive, but not the watcher watching this location -- judged stale).
  printf '%s\n' "$$" >"$ST_RUNTIME/$REIN_LOCK_DIRNAME/pid"
  ST_BROKEN_BIN="$ST_CWD/lock-swap-bin"
  # The reclaiming side's owner is pid=1 (always alive -- provably a "live lock").
  st_write_lock_swap_ps_shim "$ST_BROKEN_BIN" "$ST_RUNTIME/$REIN_LOCK_DIRNAME" \
    "$ST_CWD/lock-swap.state" 1
  st_run_watcher
  unset ST_BROKEN_BIN
  if st_expect_status "does not strip a live lock reclaimed during the judgment gap" 1; then
    if [ ! -d "$ST_RUNTIME/$REIN_LOCK_DIRNAME" ]; then
      st_fail "does not delete a live lock that was reclaimed" "the lock vanished"
    elif [ "$(rein_lock_pid "$ST_RUNTIME/$REIN_LOCK_DIRNAME")" != "1" ]; then
      st_fail "does not seize a live lock that was reclaimed" \
        "the owner changed to $(rein_lock_pid "$ST_RUNTIME/$REIN_LOCK_DIRNAME")"
    else
      st_ok
    fi
  fi
  # Verify both the premise and the substance at once: the reason must name **the pid the judgment
  # itself saw** (the pre-interruption $$). If the re-read side's pid (pid=1) shows up instead, the
  # implementation is deciding the strip target by re-reading. If it isn't $$, the interruption landed
  # before the judgment ran, and this case failed to measure the race at all.
  case "$ST_OUT" in
    *"cannot reclaim the watcher lock (saw a lock owned by pid=$$)"*)
      st_ok
      ;;
    *)
      st_fail "decides the strip target from the pid the judgment saw" "${ST_OUT}"
      ;;
  esac
  rm -rf "${ST_RUNTIME:?}/$REIN_LOCK_DIRNAME"

  # Don't seize a lock whose owner cannot be confirmed (seizing it would itself become a double launch).
  case_dir="$tmp/lock-unreadable"
  st_setup_case "$case_dir"
  mkdir -p "$ST_RUNTIME/$REIN_LOCK_DIRNAME"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  st_run_watcher
  if st_expect_status "does not start with a lock whose owner is unknown" 1; then
    if [ ! -d "$ST_RUNTIME/$REIN_LOCK_DIRNAME" ]; then
      st_fail "does not delete a lock whose owner is unknown" "the lock vanished"
    elif [ -s "$ST_LOG" ]; then
      st_fail "does not call claude when the owner is unknown" "$(cat "$ST_LOG")"
    else
      case "$ST_OUT" in
        *"cannot read the watcher lock's owner"*)
          st_ok
          ;;
        *)
          st_fail "gives a reason for the unknown owner" "${ST_OUT}"
          ;;
      esac
    fi
  fi

  # A published lock declares more than a pid -- it carries a **claim** (start time, cwd, role,
  # token). Relying only on re-parsing `ps`'s command line to identify the owner would flip the
  # judgment just from an option-like name appearing inside a value (the two cases below), and
  # releasing would become "delete whatever's under the published name, unconditionally". The claim
  # is published **before** the lock is published (writing it afterward would leave a moment where
  # it's incomplete, and a reader in that gap would treat it as "a lock whose owner cannot be
  # confirmed").
  case_dir="$tmp/lock-declares-owner"
  st_setup_case "$case_dir"
  st_run_watcher_daemon_bg "$ST_DAEMON_GUARD_SEC"
  if st_wait_for_path "$ST_RUNTIME/$REIN_LOCK_DIRNAME"; then
    lock_owner="$(rein_lock_pid "$ST_RUNTIME/$REIN_LOCK_DIRNAME")"
    if [ "$(rein_lock_field "$ST_RUNTIME/$REIN_LOCK_DIRNAME" cwd)" != "$ST_CWD" ]; then
      st_fail "the watcher lock declares cwd" "$(st_lock_dump "$ST_RUNTIME/$REIN_LOCK_DIRNAME")"
    elif [ "$(rein_lock_field "$ST_RUNTIME/$REIN_LOCK_DIRNAME" mode)" != "watch" ]; then
      st_fail "the watcher lock declares its role" "$(st_lock_dump "$ST_RUNTIME/$REIN_LOCK_DIRNAME")"
    elif [ -z "$(rein_lock_field "$ST_RUNTIME/$REIN_LOCK_DIRNAME" token)" ]; then
      st_fail "the watcher lock declares a token" "$(st_lock_dump "$ST_RUNTIME/$REIN_LOCK_DIRNAME")"
    elif [ "$(rein_lock_field "$ST_RUNTIME/$REIN_LOCK_DIRNAME" start)" != "$(rein_process_start_identity "$lock_owner")" ]; then
      st_fail "the watcher lock declares the owner's start time" "$(st_lock_dump "$ST_RUNTIME/$REIN_LOCK_DIRNAME")"
    else
      st_ok
    fi
  else
    st_fail "the watcher lock is published together with its claim" "the lock was never published: $(cat "$ST_DAEMON_OUT" 2>&1)"
  fi
  # This case only checks the published claim, not the daemon's continued survival -- no witness needed.
  st_alarm_watcher_daemon 0

  # On exit, strip **only the lock for this run's own generation**. Reclaiming runs by "see it stale,
  # then strip it, then claim it", so another run may have already reclaimed it in the gap between
  # seeing and stripping. Releasing without checking identity would then have the earlier occupant
  # delete **the reclaiming side's live lock** on its way out (two runs holding it at once).
  case_dir="$tmp/lock-superseded"
  st_setup_case "$case_dir"
  st_run_watcher_daemon_bg 10
  if st_wait_for_path "$ST_RUNTIME/$REIN_LOCK_DIRNAME"; then
    rm -rf "${ST_RUNTIME:?}/$REIN_LOCK_DIRNAME"
    rein_claim_lock_dir "$ST_RUNTIME/$REIN_LOCK_DIRNAME" \
      start "$(rein_process_start_identity "$$")" cwd "$ST_CWD" mode watch token "st-next-generation"
    printf '{"schema":"%s","requested_at":"%s","requested_by_pid":%s}\n' \
      "$REIN_STOP_REQUEST_SCHEMA" "$(rein_iso_now)" "$$" >"$ST_RUNTIME/$REIN_STOP_REQUEST_BASENAME"
    wait "$ST_DAEMON_PID"
    if [ "$(rein_lock_field "$ST_RUNTIME/$REIN_LOCK_DIRNAME" token)" = "st-next-generation" ]; then
      st_ok
    else
      st_fail "does not delete a watcher lock another generation reclaimed, on exit" \
        "$(st_lock_dump "$ST_RUNTIME/$REIN_LOCK_DIRNAME")"
    fi
    rm -rf "${ST_RUNTIME:?}/$REIN_LOCK_DIRNAME"
  else
    st_fail "does not delete a watcher lock another generation reclaimed, on exit" "the lock was never published"
    wait "$ST_DAEMON_PID"
  fi

  # Don't read an option-like name inside a value as an actual option. Just because `--cwd`'s value
  # contains the word ` --bootstrap` shouldn't misread it as "the one-shot bootstrap entry point" and
  # seize a live watcher's lock **deterministically, with no timing needed** (a misidentification is
  # easier to trigger than a real race). **This path is the command-line re-parse**
  # (`rein_watcher_command_matches`), so the fixture is launched **without a claim** -- with the
  # default fixture, which carries a role and cwd claim, a reader would decide the answer from the
  # claim match and **stop there**, never reading the command line at all, and this case would end up
  # testing "does the claim match work" instead.
  case_dir="$tmp/lock-value-holds-option --bootstrap"
  st_setup_case "$case_dir"
  rein_st_start_fake_watcher "$ST_RUNTIME" "$ST_CWD" bare
  # Premise check: this fixture's lock carries no role claim (if it did, a reader would stop above).
  if [ -z "$(rein_lock_field "$ST_RUNTIME/$REIN_LOCK_DIRNAME" mode)" ]; then
    st_ok
  else
    st_fail "the claim-free fixture carries no role claim" \
      "$(st_lock_dump "$ST_RUNTIME/$REIN_LOCK_DIRNAME")"
  fi
  lock_owner="$(rein_lock_pid "$ST_RUNTIME/$REIN_LOCK_DIRNAME")"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  st_run_watcher
  if st_expect_status "does not read a live watcher as stale from an option-like name inside cwd's value" 1; then
    if [ "$(rein_lock_pid "$ST_RUNTIME/$REIN_LOCK_DIRNAME")" != "$lock_owner" ]; then
      st_fail "does not seize a live lock through misclassification" "the owner changed from ${lock_owner} to $(rein_lock_pid "$ST_RUNTIME/$REIN_LOCK_DIRNAME")"
    else
      case "$ST_OUT" in
        *"another instance is already watching"*)
          st_ok
          ;;
        *)
          st_fail "refuses as a duplicate launch instead of misclassifying" "${ST_OUT}"
          ;;
      esac
    fi
  fi
  rein_st_stop_fake_watcher "$ST_RUNTIME"

  # With `ps` unable to answer (point PATH at a `ps` that fails), don't collapse "not there" and
  # "cannot be confirmed" into the same non-zero. Collapsing them would read a live owner's lock as
  # stale and seize it -- the rule "never seize what cannot be confirmed" already holds on every other
  # path, and `ps` failing to answer is the only outlier.
  case_dir="$tmp/lock-ps-unusable"
  st_setup_case "$case_dir"
  rein_st_start_fake_watcher "$ST_RUNTIME" "$ST_CWD"
  lock_owner="$(rein_lock_pid "$ST_RUNTIME/$REIN_LOCK_DIRNAME")"
  ST_BROKEN_BIN="$tmp/broken-ps"
  rein_st_write_broken_tool "$ST_BROKEN_BIN" ps
  st_run_watcher
  unset ST_BROKEN_BIN
  if [ "$ST_STATUS" -eq 0 ]; then
    st_fail "does not seize a live lock when ps can't answer" "entered monitoring with exit=0: ${ST_OUT}"
  elif [ "$(rein_lock_pid "$ST_RUNTIME/$REIN_LOCK_DIRNAME")" != "$lock_owner" ]; then
    st_fail "does not seize a live lock when ps can't answer" \
      "the owner changed from ${lock_owner} to $(rein_lock_pid "$ST_RUNTIME/$REIN_LOCK_DIRNAME")"
  else
    case "$ST_OUT" in
      *"a prerequisite tool is unavailable"*"ps"*)
        st_ok
        ;;
      *)
        st_fail "gives ps not answering as the reason" "${ST_OUT}"
        ;;
    esac
  fi
  rein_st_stop_fake_watcher "$ST_RUNTIME"

  # Pin down, from the reader's own main judgment, that the fake watcher's lock carries **the same
  # claim as a real one**. With a `pid`-only lock, `rein_watcher_state` would pass the claim check
  # silently and only take the final command-line-match branch -- the one that explicitly documents
  # "rein's own lock never reaches here" -- and a case claiming to check "the watcher is running"
  # would turn green without ever exercising the main judgment.
  case_dir="$tmp/lock-declarations"
  st_setup_case "$case_dir"
  rein_st_start_fake_watcher "$ST_RUNTIME" "$ST_CWD"
  lock_owner="$ST_RUNTIME/$REIN_LOCK_DIRNAME"
  if [ "$(rein_lock_field "$lock_owner" mode)" = "$REIN_LOCK_MODE_WATCH" ] &&
    [ "$(rein_lock_field "$lock_owner" cwd)" = "$ST_CWD" ] &&
    [ -n "$(rein_lock_field "$lock_owner" start)" ] &&
    [ -n "$(rein_lock_field "$lock_owner" token)" ]; then
    st_ok
  else
    st_fail "the fake watcher's lock carries the same claim as a real one" "$(ls -a "$lock_owner" 2>&1)"
  fi
  # Negative side: rewriting just the role claim to a different value should make the reader decide
  # "not a resident role" **from the claim** and return 2 (if it decided from the command line alone
  # without reading the claim, this rewrite would have no effect and it would stay 0).
  printf '%s\n' "$REIN_LOCK_MODE_OP" >"$lock_owner/mode"
  rein_watcher_state "$ST_RUNTIME" "$ST_CWD"
  lock_rc=$?
  if [ "$lock_rc" -eq 2 ]; then
    st_ok
  else
    st_fail "does not seize a lock whose role claim differs" "rc=${lock_rc}: ${REIN_WATCHER_REASON}"
  fi
  printf '%s\n' "$REIN_LOCK_MODE_WATCH" >"$lock_owner/mode"

  # A release-side guard: **don't delete a lock this session didn't create**. If liveness were only
  # judged on the acquire side, a run that got the wrong location could strip a real watcher's watch
  # lock from the release side (the same harm to guard against). The guard counts as one failure, so
  # the caller runs it in a subshell -- the counting stays inside the subshell, leaving only the
  # side effect of "does it get deleted" visible outside (if it's still there, the guard held).
  mkdir -p "$tmp/foreign-runtime/$REIN_LOCK_DIRNAME"
  (rein_st_stop_fake_watcher "$tmp/foreign-runtime") >/dev/null 2>&1
  if [ -d "$tmp/foreign-runtime/$REIN_LOCK_DIRNAME" ]; then
    st_ok
  else
    st_fail "the release side also doesn't delete a lock outside its own log" "it was deleted: ${tmp}/foreign-runtime/${REIN_LOCK_DIRNAME}"
  fi
  # The accepting side's counterpart: a lock this session did create is still stripped as before
  # (the guard hasn't collapsed into "never delete anything").
  rein_st_stop_fake_watcher "$ST_RUNTIME"
  if [ ! -e "$lock_owner" ]; then
    st_ok
  else
    st_fail "the release side strips a lock that's on its own log" "it's still there: ${lock_owner}"
  fi

  # The log is a record that "this session once launched it" -- an entry stays on it even after the
  # lock is released. **If a different owner later reclaims the same location, a release that only
  # checks the log would delete that owner's real lock** (the same harm the acquire-side guard
  # names). Checking the current lock's **published claim (token)** too means even a location in the
  # log is left alone. Bulk release (`rein_st_stop_all_fake_watchers`) goes through the same
  # predicate.
  mkdir -p "$lock_owner"
  printf '%s\n' "$$" >"$lock_owner/pid"
  printf '%s\n' "not-a-fake-watcher-token" >"$lock_owner/token"
  (rein_st_stop_fake_watcher "$ST_RUNTIME") >/dev/null 2>&1
  if [ -d "$lock_owner" ]; then
    st_ok
  else
    st_fail "does not delete a lock published by a different owner, even if it's in the log" "it was deleted: ${lock_owner}"
  fi
  # Both sides of the shared predicate bulk release goes through (leave a different owner's lock alone / strip its own token's).
  (rein_st_release_fake_watcher_lock "$lock_owner") >/dev/null 2>&1
  if [ -d "$lock_owner" ]; then
    st_ok
  else
    st_fail "the shared release predicate also leaves a different owner's lock alone" "it was deleted: ${lock_owner}"
  fi
  printf '%s\n' "${REIN_ST_FAKE_WATCHER_TOKEN_PREFIX}restored" >"$lock_owner/token"
  if rein_st_release_fake_watcher_lock "$lock_owner" && [ ! -e "$lock_owner" ]; then
    st_ok
  else
    st_fail "the shared predicate strips a lock published with its own token" "it's still there: ${lock_owner}"
  fi

  # A round that failed to publish still **lands in the log**. If it didn't, nothing could ever
  # strip a lock published later at that spot (it would also be missed by bulk release) -- block the
  # location's parent directory with a file to make claim fail, and check from the log side.
  # The guard counts as one failure, so call it in a subshell, and take the judgment inside the
  # subshell too.
  printf 'blocker\n' >"$tmp/publish-fail"
  if [ "$( (rein_st_start_fake_watcher "$tmp/publish-fail/runtime" "$ST_CWD" >/dev/null 2>&1
    if rein_st_fake_watcher_lock_known "$tmp/publish-fail/runtime/$REIN_LOCK_DIRNAME"; then
      printf 'known'
    else
      printf 'unknown'
    fi) )" = "known" ]; then
    st_ok
  else
    st_fail "a round that failed to publish still lands in the log" "not on it: ${tmp}/publish-fail/runtime"
  fi

}
