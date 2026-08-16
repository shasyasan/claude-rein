# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034  # selftest state is shared across sections (the caller selftest()'s locals and the ST_* globals)
# The directive above applies to the **whole file** -- in this file, neither an unused local
# inside a function nor a misspelled reference gets caught. The shared variables are scattered
# across the whole file, so a line-level directive can't be scoped tightly enough.
# selftest for the verbs (up / down / status / snooze / prune / doctor).
# Never starts the real CLI (a shim at the front of PATH records the arguments and plays the branch).
# The watcher is started for real as a daemon, so every case runs `down` at the end (leaving it
# behind would contaminate the next case).
# Not an executable script, so it carries no execute bit (out of scope for the --selftest convention).

st_section_verbs() {
  # Only variables this section alone uses stay scoped to its own function (anything shared
  # across sections belongs on selftest()'s own locals).
  local lock_probe_rc broken_ps_bin oplock_holder_pid oplock_swap_pid
  local hold_bin hold_file frozen_file frozen_polls frozen_ok hold_path_saved seat_release
  local seat_log_probe
  proj2="$tmp/verbs"
  root2="$tmp/verbs-root"
  mkdir -p "$proj2"
  proj2="$(cd "$proj2" && pwd -P)"
  runtime2="$root2/state/rein/$(rein_cwd_key "$proj2")"
  # A lineage set up with `--root` keeps its records (the current pointer) on the root side
  # (see E5: a lineage's identity is cwd + root -- the location that keeps two lineages with the
  # same cwd from sharing `<cwd>/.rein/`).
  records2="$root2/records/rein/$(rein_cwd_key "$proj2")"
  # The fake CLI's location (verb_bin) and its call log (verb_log) are assembled by the driver
  # (other sections that skip this one ride on the same ones), so this section only reuses the
  # location -- it doesn't create it.
  verb_agents="$tmp/verb-agents.json"
  rein_st_write_agents "$verb_agents" "$proj2" "sess-live"
  : >"$verb_log"
  # The wait cap becomes real wall-clock time for the check, so config's effective values are
  # pinned small at the environment layer.
  ST_VERB_ENV=(
    "PATH=${verb_bin}:${PATH}"
    "FAKE_LOG=$verb_log"
    "FAKE_NOTIFY_LOG=$tmp/notify.log"
    "FAKE_AGENTS=$verb_agents"
    "FAKE_SUCC_ID=succ-1"
    "REIN_POLL_INTERVAL_SEC=0.2"
    "REIN_CMD_TIMEOUT_SEC=10"
    "REIN_LAUNCH_TIMEOUT_SEC=5"
    "REIN_EXIT_GRACE_SEC=1"
    "REIN_STOP_TIMEOUT_SEC=2"
  )

  # The machine-readable read of the watcher's liveness is `status --json` alone (the verb that
  # returned it via exit code is retired).
  st_run_env --root "$root2" --cwd "$proj2" status --json
  if [ "$(printf '%s' "$ST_OUT" | jq -r '.watcher.state' 2>/dev/null)" = "stopped" ]; then
    st_ok
  else
    st_fail "watcher.state before startup is stopped" "$ST_OUT"
  fi
  st_run_env --root "$root2" --cwd "$proj2" is-up
  st_expect_reject "the retired is-up becomes an unknown subcommand" 2 "unknown subcommand: is-up"
  # The only entry point for hooks is the launcher inside the plugin (driven by
  # `hooks/hooks.json`'s registration table). The compatibility entry point that used to live on
  # the CLI side is torn down -- this pins **the dispatch branch staying gone**, since removing
  # only the implementation while leaving the branch behind falls into calling a function with no
  # body, `cmd_hook: command not found` (exit code 127).
  st_run_env --root "$root2" --cwd "$proj2" hook stop
  st_expect_reject "the torn-down hook becomes an unknown subcommand" 2 "unknown subcommand: hook"

  # The case where handover's last step (stepping the predecessor session aside) is left
  # outstanding. Since the pointer already points at the successor, the primary-session line
  # looks normal, and this state used to show up nowhere. **A handover in progress legitimately
  # passes through this exact state** (the two coexist during the grace period), so this reads
  # the watcher's presence to tell the two apart.
  mkdir -p "$records2"
  rein_st_write_pointer "$records2/$REIN_POINTER_BASENAME" "succ-1" "successor" "$proj2" 2 "pred-1"
  rein_st_write_agents "$verb_agents" "$proj2" "succ-1" "pred-1"
  st_run_env --root "$root2" --cwd "$proj2" status
  st_expect_contains "reports it as stranded when the watcher is not there" \
    "stranded: present (predecessor session pred-1 is still there with no watcher running"
  st_run_env --root "$root2" --cwd "$proj2" status --json
  if [ "$(printf '%s' "$ST_OUT" | jq -r '.incomplete_handover.state' 2>/dev/null)" = "stranded" ] &&
    [ "$(printf '%s' "$ST_OUT" | jq -r '.incomplete_handover.predecessor_session_id' 2>/dev/null)" = "pred-1" ]; then
    st_ok
  else
    st_fail "status --json reports the stranded state" "$ST_OUT"
  fi
  # Accepting side (1): a resident watcher means handover is still in progress -- never sound this as stranded.
  rein_st_start_fake_watcher "$runtime2" "$proj2"
  st_run_env --root "$root2" --cwd "$proj2" status --json
  if [ "$(printf '%s' "$ST_OUT" | jq -r '.incomplete_handover.state' 2>/dev/null)" = "in_progress" ]; then
    st_ok
  else
    st_fail "reads it as in-progress handover while the watcher is there" "$ST_OUT"
  fi
  rein_st_stop_fake_watcher "$runtime2"
  # Accepting side (2): once the predecessor session has dropped out of enumeration, the same
  # pointer is no longer stranded.
  rein_st_write_agents "$verb_agents" "$proj2" "succ-1"
  st_run_env --root "$root2" --cwd "$proj2" status --json
  if [ "$(printf '%s' "$ST_OUT" | jq -r '.incomplete_handover.state' 2>/dev/null)" = "none" ]; then
    st_ok
  else
    st_fail "not stranded once the predecessor is gone" "$ST_OUT"
  fi
  # Accepting side (3): a round that can't even read enumeration is **undetermined** (never
  # collapsed to "none" -- collapsing it would make stranded handovers permanently invisible on a
  # lineage whose enumeration is broken).
  rein_st_write_agents "$verb_agents" "$proj2" "succ-1" "pred-1"
  ST_VERB_ENV+=("FAKE_AGENTS_FAIL=1")
  st_run_env --root "$root2" --cwd "$proj2" status --json
  if [ "$(printf '%s' "$ST_OUT" | jq -r '.incomplete_handover.state' 2>/dev/null)" = "unknown" ]; then
    st_ok
  else
    st_fail "a round that can't read enumeration is undetermined" "$ST_OUT"
  fi
  st_run_env --root "$root2" --cwd "$proj2" status
  st_expect_contains "undetermined is shown with a reason" "stranded: undetermined ("
  ST_VERB_ENV=("${ST_VERB_ENV[@]:0:${#ST_VERB_ENV[@]}-1}")
  rein_st_write_agents "$verb_agents" "$proj2" "succ-1"
  # The case where only one side died (the primary session on record is a dead successor, and
  # the one actually alive is the predecessor): `up` **never starts a new successor** here.
  # Starting one would leave two primary sessions (the live predecessor plus the new one), both
  # able to edit the same work tree. The handoff document is made real so this measures "up still
  # refuses even with every precondition for starting met" (rather than mistaking a run that
  # failed only because the handoff document is missing for a pass here).
  mkdir -p "$records2"
  printf 'handoff fixture\n' >"$records2/$REIN_HANDOFF_BASENAME"
  rein_st_write_pointer "$records2/$REIN_POINTER_BASENAME" "succ-dead" "successor" "$proj2" 2 "pred-1"
  rein_st_write_agents "$verb_agents" "$proj2" "pred-1"
  : >"$verb_log"
  st_run_env --root "$root2" --cwd "$proj2" up --detach
  st_expect_status "up does not succeed on a one-sided death" 1 && st_ok
  st_expect_not_contains "does not claim it started when it isn't running" "watcher started (pid="
  st_expect_true "does not start a new successor" \
    test "$(rein_st_count_sub "$verb_log" "--bg")" = "0"
  # `status` shows the same state too. **Never reads it as none** -- this state was deliberately
  # decided never to be auto-repaired, so if the only places that surface it were doctor, `up`,
  # and the GUI notification, whoever reads `status` alone would read it as normal.
  # The explanation and the fix are written in exactly one place (the same sentence as doctor and
  # the watcher) -- never a second writer.
  st_run_env --root "$root2" --cwd "$proj2" status
  st_expect_not_contains "does not report a one-sided death as no stranded handover" "stranded: none"
  st_expect_contains "names both sides of the mismatch" \
    "the primary session on record, succ-dead, is not in enumeration, but the predecessor, pred-1, is alive"
  st_expect_contains "says it does not fix this automatically" "rein does not fix this automatically"
  # Points at where the underlying reason lives, verbatim (folding it into a generic sentence
  # would strand the reader with no way to find the cause).
  st_expect_contains "points at where the failure reason lives" \
    "the reason it failed is left in the failed line in ${records2}/${REIN_LOG_BASENAME} and in ${records2}/${REIN_WATCHER_LOG_BASENAME}"
  st_run_env --root "$root2" --cwd "$proj2" status --json
  if [ "$(printf '%s' "$ST_OUT" | jq -r '.incomplete_handover.state' 2>/dev/null)" = "handover_mismatch" ] &&
    [ "$(printf '%s' "$ST_OUT" | jq -r '.incomplete_handover.predecessor_session_id' 2>/dev/null)" = "pred-1" ]; then
    st_ok
  else
    st_fail "status --json reports the mismatch with its own value" "$ST_OUT"
  fi
  st_run_env --root "$root2" --cwd "$proj2" down
  rm -f "$records2/$REIN_POINTER_BASENAME"

  # The case where reclaiming a stranded handover request fails (the reclaim target is blocked
  # by a plain file). If the reclaim can't happen before entering the watch loop, the Stop hook
  # keeps reading that session's handover request as already submitted -- meaning the handover
  # prompt stays silenced forever, while `up` still says "watcher started".
  mkdir -p "$runtime2/$REIN_PROCESSING_DIRNAME"
  printf '%s\n' "$proj2" >"$runtime2/$REIN_OWNER_BASENAME"
  rein_st_write_marker "$runtime2/$REIN_PROCESSING_DIRNAME/orphan.json" "pred-1" \
    "$(rein_iso_now)" "$records2/$REIN_HANDOFF_BASENAME" "$proj2"
  : >"$runtime2/$REIN_REJECTED_DIRNAME"
  st_run_env --root "$root2" --cwd "$proj2" up --no-bootstrap
  if st_expect_status "up does not succeed when the reclaim fails" 1; then
    st_expect_not_contains "does not claim it started while the reclaim failed" "watcher started (pid="
  fi
  st_run_env --root "$root2" --cwd "$proj2" down
  rm -f "$runtime2/$REIN_REJECTED_DIRNAME"
  rm -rf "${runtime2:?}/$REIN_PROCESSING_DIRNAME"
  rm -f "$records2/$REIN_HANDOFF_BASENAME"
  rein_st_write_agents "$verb_agents" "$proj2" "sess-live"

  # A primary session right after finishing a turn (the state actually observed --
  # state is done, the same word as the terminal vocabulary, but status=idle, has a pid, and sits
  # in the normal enumeration) is reported as **attached**. In real operation a session lands in
  # this exact state after every turn, so reading liveness from state first would show a live
  # primary session as "exited" every single time, restarting generation one on top of it.
  rein_st_write_agents_idle "$verb_agents" "$proj2" "sess-idle"
  rein_st_write_pointer "$records2/$REIN_POINTER_BASENAME" "sess-idle" "primary" "$proj2" 1
  st_run_env --root "$root2" --cwd "$proj2" status
  st_expect_contains "reports a primary session right after finishing a turn as present" \
    "primary session: sess-idle (primary) -- present"
  rm -f "$records2/$REIN_POINTER_BASENAME"
  rein_st_write_agents "$verb_agents" "$proj2" "sess-live"

  # The old-format watcher log (nohup's redirect target). It's identified only by the cwd's
  # basename, and lives **outside** the runtime-data location, so `up` never removes it (the
  # decision to remove it is left to the user via doctor's own guidance).
  mkdir -p "$root2/state/rein"
  legacy="$root2/state/rein/watcher-$(basename "$proj2").log"
  : >"$legacy"

  # A leftover stop request is cleared by `up` (leaving it means the watcher it starts goes back
  # down on its very first loop).
  mkdir -p "$runtime2"
  printf '%s\n' "$proj2" >"$runtime2/$REIN_OWNER_BASENAME"

  # The seat-stop marker side gets the same entry-point discipline. **A broken symlink doesn't
  # match `-e`**, so asking whether it's there with `-e` alone would pass with 0 without even
  # attempting the delete, leaving that state sitting there through the watcher coming up (read
  # next by whichever seat attaches next). Deleting it has to happen **before starting the
  # watcher** -- do it in the cleanup step, or a resident watcher piles on top of one that was
  # supposed to have been stopped.
  ln -s "$runtime2/nowhere-seat-stop" "$runtime2/$REIN_SEAT_STOP_BASENAME"
  st_run_env --root "$root2" --cwd "$proj2" up --no-bootstrap
  if st_expect_reject "up does not end with 0 when the seat-stop marker is a broken symlink" 1 \
    "is not a regular file"; then
    st_expect_not_contains "does not claim it cleared a marker it never removed" "seat-stop marker cleared"
    st_expect_not_contains "does not start the watcher on a failed round" "watcher started (pid="
  fi
  st_expect_true "does not create the target on a round that failed" test ! -e "$runtime2/nowhere-seat-stop"
  rm -f "$runtime2/$REIN_SEAT_STOP_BASENAME"
  # Non-regression: an ordinary, removable marker still gets removed as before, then the run
  # proceeds (measured by riding along on the `up` below -- reaching resident and the marker
  # being cleared are both seen in the same one run).
  printf '{"schema":"%s","requested_at":"%s","requested_by_pid":%s}\n' \
    "$REIN_SEAT_STOP_SCHEMA" "$(rein_iso_now)" "$$" >"$runtime2/$REIN_SEAT_STOP_BASENAME"

  printf '{"schema":"%s","requested_at":"%s","requested_by_pid":%s}\n' \
    "$REIN_STOP_REQUEST_SCHEMA" "$(rein_iso_now)" "$$" >"$runtime2/$REIN_STOP_REQUEST_BASENAME"

  st_run_env --root "$root2" --cwd "$proj2" up --no-bootstrap
  if st_expect_status "up makes the watcher resident" 0; then
    st_expect_contains "up reports it started" "watcher started (pid="
    st_expect_contains "says it cleared a leftover stop request" "stop request cleared"
    st_expect_true "the leftover stop request is gone" test ! -e "$runtime2/$REIN_STOP_REQUEST_BASENAME"
    st_expect_true "up doesn't remove an old-format watcher log outside the location" test -e "$legacy"
  fi
  st_expect_contains "says it cleared a leftover seat-stop marker" "seat-stop marker cleared"
  st_expect_true "the leftover seat-stop marker is gone" \
    test ! -e "$runtime2/$REIN_SEAT_STOP_BASENAME"
  # Judged by process state, not overall state -- right after startup there can still be a round
  # before the heartbeat is first written (a window where overall state is unknown, a separate
  # fact from process residency).
  st_run_env --root "$root2" --cwd "$proj2" status --json
  if [ "$(printf '%s' "$ST_OUT" | jq -r '.watcher.process_state' 2>/dev/null)" = "running" ]; then
    st_ok
  else
    st_fail "watcher.process_state once resident is running" "$ST_OUT"
  fi
  st_run_env --root "$root2" --cwd "$proj2" status --json
  pid_before="$(printf '%s' "$ST_OUT" | jq -r '.watcher.pid // empty' 2>/dev/null)"
  if [ -n "$pid_before" ]; then
    st_ok
  else
    st_fail "status --json reports the watcher's pid" "$ST_OUT"
  fi
  # The current state shows the **effective value**'s canonical source (the pointer's handoff_path
  # is the predecessor's own declared value, which stays stale after a move -- there has to be one
  # place to confirm which file a handover request will actually look at).
  status_handoff_path="$root2/$REIN_ROOT_RECORDS_RELDIR/$(rein_cwd_key "$proj2")/$REIN_HANDOFF_BASENAME"
  st_run_env --root "$root2" --cwd "$proj2" status
  if st_expect_status "status ends with 0" 0; then
    st_expect_contains "status reports the watcher as running" "watcher: running"
    st_expect_contains "status reports the heartbeat's freshness" "heartbeat"
    st_expect_contains "status reports whether a stop request is there" "stop request: none"
    st_expect_contains "status reports whether a seat-stop marker is there" "seat stop: none"
    st_expect_contains "status reports the operation lock's state" "operation lock: none"
    st_expect_contains "status reports the handoff document's effective value and origin" \
      "handoff: ${status_handoff_path} (origin default"
    st_expect_contains "an as-yet-unmade document is reported as such" "missing, empty, or not an acceptable shape"
  fi
  # Being present in the current state means **present in an acceptable form**. Judged loosely, it
  # would report something a handover request rejects (a symlink, a directory) as present while
  # handover alone stays stuck.
  mkdir -p "${status_handoff_path%/*}"
  printf 'a real document\n' >"$root2/status-real-handoff.md"
  ln -s "$root2/status-real-handoff.md" "$status_handoff_path"
  st_run_env --root "$root2" --cwd "$proj2" status --json
  if [ "$(printf '%s' "$ST_OUT" | jq -r '.handoff.present' 2>/dev/null)" = "false" ]; then
    st_ok
  else
    st_fail "a symlinked document is not reported as there" "$ST_OUT"
  fi
  rm -f "$status_handoff_path"
  st_run_env --root "$root2" --cwd "$proj2" status --json
  if [ "$(printf '%s' "$ST_OUT" | jq -r '.handoff.path' 2>/dev/null)" = "$status_handoff_path" ] &&
    [ "$(printf '%s' "$ST_OUT" | jq -r '.handoff.origin' 2>/dev/null)" = "default" ] &&
    [ "$(printf '%s' "$ST_OUT" | jq -r '.handoff.present' 2>/dev/null)" = "false" ]; then
    st_ok
  else
    st_fail "status --json reports the document's effective value, origin, and presence" "$ST_OUT"
  fi
  # A round with nothing in an acceptable shape never reads sections at all, so section structure
  # comes back neither true nor false but null (reporting something unmeasured as "matching"
  # would let a reader who ignores `present` read a lineage with no document as green). The
  # reason is null too -- why it wasn't measured is already reported by that same object's
  # `present`.
  if [ "$(printf '%s' "$ST_OUT" | jq -r '.handoff.sections_ok' 2>/dev/null)" = "null" ] &&
    [ "$(printf '%s' "$ST_OUT" | jq -r '.handoff.sections_reason' 2>/dev/null)" = "null" ]; then
    st_ok
  else
    st_fail "section structure is reported as unmeasured when there's no document" "$ST_OUT"
  fi
  # The short form reports the same thing (-j = JSON, -a = cross-lineage listing). Only the
  # human-readable first line is checked, so that a short form which is accepted but emits
  # something different can't pass as accepting it and producing the same thing.
  st_run_env --root "$root2" --cwd "$proj2" status -j
  if [ "$(printf '%s' "$ST_OUT" | jq -r '.watcher.pid // empty' 2>/dev/null)" = "$pid_before" ]; then
    st_ok
  else
    st_fail "-j reports the same thing as --json" "$ST_OUT"
  fi
  st_run_env --root "$root2" --cwd "$proj2" status --all
  alias_all_out="$ST_OUT"
  st_run_env --root "$root2" --cwd "$proj2" status -a
  st_expect_out "-a reports the same listing as --all" "$alias_all_out"

  printf 'x\n' >"$legacy"
  st_run_env --root "$root2" --cwd "$proj2" up --no-bootstrap
  if st_expect_status "a second up also ends with 0" 0; then
    st_expect_contains "a second up doesn't start it over again" "already running"
    st_expect_true "doesn't remove a non-empty old-format watcher log" test -e "$legacy"
  fi
  # The decision to remove it is left to the user via doctor's guidance (identity relies only on
  # the basename, so an environment with two same-named work trees could be pointing at a
  # different lineage's leftovers).
  st_run_env --root "$root2" --cwd "$proj2" doctor
  st_expect_contains "doctor points at the old-format watcher log's location" "an old-format watcher log remains"
  rm -f "$legacy"
  st_run_env --root "$root2" --cwd "$proj2" doctor
  st_expect_not_contains "no guidance when there's no old-format watcher log" "an old-format watcher log remains"
  st_run_env --root "$root2" --cwd "$proj2" status --json
  pid_after="$(printf '%s' "$ST_OUT" | jq -r '.watcher.pid // empty' 2>/dev/null)"
  if [ -n "$pid_before" ] && [ "$pid_before" = "$pid_after" ]; then
    st_ok
  else
    st_fail "up is idempotent (exactly one resident watcher)" "the pid changed: ${pid_before} -> ${pid_after}"
  fi

  # The operation lock. While its owner is alive, it doesn't let either up or down through on the
  # same lineage (letting both through would let two concurrent `up` calls each read "not there"
  # and start it twice).
  mkdir -p "$runtime2/$REIN_OP_LOCK_DIRNAME"
  printf '%s\n' "$$" >"$runtime2/$REIN_OP_LOCK_DIRNAME/pid"
  st_run_env --root "$root2" --cwd "$proj2" up --no-bootstrap
  st_expect_reject "up is refused while an operation is in progress" 1 "another rein operation is in progress"
  st_run_env --root "$root2" --cwd "$proj2" down
  st_expect_reject "down is refused while an operation is in progress" 1 "another rein operation is in progress"
  printf 'not-a-pid\n' >"$runtime2/$REIN_OP_LOCK_DIRNAME/pid"
  st_run_env --root "$root2" --cwd "$proj2" up --no-bootstrap
  if st_expect_reject "an operation lock whose owner can't be confirmed is never seized" 1 "cannot read the operation lock's owner"; then
    # Since it's never seized, the reader has to be shown how to remove it, or this lineage can
    # never be started again.
    st_expect_contains "points at how to remove it" \
      "rmdir $(rein_shell_quote "$runtime2/$REIN_OP_LOCK_DIRNAME")"
  fi
  st_run_env --root "$root2" --cwd "$proj2" status
  st_expect_contains "status also reports a leftover operation lock" "operation lock: a lock with an unreadable owner remains"
  st_run_env --root "$root2" --cwd "$proj2" doctor
  st_expect_contains "doctor also reports a leftover operation lock" "FAIL operation lock: a lock with an unreadable owner remains"
  rm -rf "${runtime2:?}/$REIN_OP_LOCK_DIRNAME"
  # A stale operation lock (no owner) gets reclaimed. Measured with **something other than `pid`
  # left inside it** -- a two-step reclaim (delete `pid`, then `rmdir`) fails the `rmdir` right
  # here, leaving a published lock with no `pid` behind, which permanently blocks up / down /
  # prune -o on this lineage with "cannot read the owner" from then on (what's left behind is a
  # losing claimant's directory, moved into the lock by `mv` but never cleaned up).
  mkdir -p "$runtime2/$REIN_OP_LOCK_DIRNAME/leftover-claim"
  printf '99999999\n' >"$runtime2/$REIN_OP_LOCK_DIRNAME/pid"
  st_run_env --root "$root2" --cwd "$proj2" down
  if st_expect_status "reclaims a stale operation lock with something other than pid left in it" 0; then
    st_expect_not_contains "doesn't report the reclaim as a failure" "cannot read the operation lock's owner"
  fi
  st_expect_true "doesn't leave a reclaimed operation lock behind" test ! -e "$runtime2/$REIN_OP_LOCK_DIRNAME"

  # Releasing the operation lock only ever releases **this generation's own**. A reclaim runs as
  # "see it's stale, then release and claim it" -- so between seeing it and releasing it, another
  # execution can already have reclaimed it. Releasing without checking would strip a live lock
  # out from under the side that just reclaimed it (two rein processes holding it at once). The
  # counterpart it waits on is a watcher that never reads the stop request -- `down` waits up
  # to its cap, and during that wait a different generation reclaims the operation lock.
  rm -rf "${runtime2:?}/$REIN_LOCK_DIRNAME" "${runtime2:?}/$REIN_STOP_REQUEST_BASENAME"
  mkdir -p "$runtime2/$REIN_LOCK_DIRNAME"
  # A resident process whose command line alone looks like the watcher (it never reads the stop
  # request, so it stays put up to the cap). One statement isn't enough on its own -- a single
  # `bash -c` command replaces itself via exec (the command line turns into `sleep 5`), which
  # wouldn't be a match target for identity checks.
  bash -c 'sleep "$5"; exit 0' "$REIN_WATCHER_SCRIPT_PATH" --cwd "$proj2" x x 5 &
  oplock_holder_pid=$!
  printf '%s\n' "$oplock_holder_pid" >"$runtime2/$REIN_LOCK_DIRNAME/pid"
  (
    oplock_wait=0
    while [ "$oplock_wait" -lt 200 ]; do
      if [ -d "$runtime2/$REIN_OP_LOCK_DIRNAME" ]; then
        rm -rf "${runtime2:?}/$REIN_OP_LOCK_DIRNAME"
        rein_claim_lock_dir "$runtime2/$REIN_OP_LOCK_DIRNAME" \
          start "$(rein_process_start_identity "$$")" cwd "$proj2" mode op token "st-next-generation"
        exit 0
      fi
      sleep 0.05
      oplock_wait=$((oplock_wait + 1))
    done
  ) &
  oplock_swap_pid=$!
  ST_VERB_ENV+=("REIN_CMD_TIMEOUT_SEC=2")
  st_run_env --root "$root2" --cwd "$proj2" down --watcher-only
  unset 'ST_VERB_ENV[${#ST_VERB_ENV[@]}-1]'
  wait "$oplock_swap_pid"
  if [ "$(rein_lock_field "$runtime2/$REIN_OP_LOCK_DIRNAME" token)" = "st-next-generation" ]; then
    st_ok
  else
    st_fail "doesn't remove an operation lock a different generation already reclaimed" \
      "token=$(rein_lock_field "$runtime2/$REIN_OP_LOCK_DIRNAME" token) exit=${ST_STATUS}: ${ST_OUT}"
  fi
  wait "$oplock_holder_pid"
  rm -rf "${runtime2:?}/$REIN_OP_LOCK_DIRNAME" "${runtime2:?}/$REIN_LOCK_DIRNAME" \
    "${runtime2:?}/$REIN_STOP_REQUEST_BASENAME"
  # A published lock always carries a pid (if claiming it and writing the pid were two separate
  # steps, a lock that died in between would sit forever with an owner that can't be confirmed).
  if rein_claim_lock_dir "$tmp/claim-probe.lock" &&
    [ "$(rein_lock_pid "$tmp/claim-probe.lock")" = "$$" ]; then
    st_ok
  else
    st_fail "a lock is published with a pid" "$(find "$tmp/claim-probe.lock" -print 2>&1)"
  fi
  # Never steps into a lock that's already there (`mv` moves *into* a directory that already exists).
  if rein_claim_lock_dir "$tmp/claim-probe.lock"; then
    st_fail "doesn't take a lock that's already there" "took it anyway"
  elif [ "$(find "$tmp/claim-probe.lock" -mindepth 1 -maxdepth 1 -print | LC_ALL=C sort | tr '\n' ' ')" = "$tmp/claim-probe.lock/pid " ]; then
    st_ok
  else
    st_fail "doesn't leave the losing side's temp directory behind" "$(find "$tmp/claim-probe.lock" -print)"
  fi
  rm -rf "$tmp/claim-probe.lock"
  # Release also happens in one step. Doing it as "delete pid, then rmdir" leaves a published lock
  # with no pid behind on a run where `rmdir` fails (something rein doesn't know about sitting
  # inside it, say) -- permanently blocking up / down on that location from then on (the releasing
  # side recreating the very unknown state the acquiring side closed off).
  mkdir -p "$tmp/release-probe.lock"
  printf '%s\n' "$$" >"$tmp/release-probe.lock/pid"
  : >"$tmp/release-probe.lock/unknown-file"
  if rein_release_lock_dir "$tmp/release-probe.lock" && [ ! -e "$tmp/release-probe.lock" ]; then
    st_ok
  else
    st_fail "release removes the public name in one step" "$(find "$tmp/release-probe.lock" -print 2>&1)"
  fi
  st_expect_true "doesn't leave release's temp name behind" \
    test -z "$(find "$tmp" -mindepth 1 -maxdepth 1 -name 'release-probe.lock*' -print)"
  st_expect_true "returns 0 when there's nothing to release" rein_release_lock_dir "$tmp/release-probe.lock"

  # The interface that releases only this side's own lock reports a failed release and a
  # deliberate back-off as separate outcomes. Collapsing them to the same 1 would make even a run
  # that correctly backed off get flagged as an anomaly by the caller.
  rein_claim_lock_dir "$tmp/mine-probe.lock" token "st-mine"
  rein_release_lock_dir_if_mine "$tmp/mine-probe.lock" "st-other"
  lock_probe_rc=$?
  if [ "$lock_probe_rc" -eq 2 ] && [ -d "$tmp/mine-probe.lock" ]; then
    st_ok
  else
    st_fail "a lock that isn't mine is left untouched, and reported as such" \
      "exit=${lock_probe_rc} lock=$(find "$tmp/mine-probe.lock" -print 2>&1)"
  fi
  st_expect_true "my own lock can be released" rein_release_lock_dir_if_mine "$tmp/mine-probe.lock" "st-mine"
  st_expect_true "a released lock doesn't remain" test ! -e "$tmp/mine-probe.lock"

  # Liveness has 3 states: there / not there / can't be confirmed. Collapsing an unanswering `ps`
  # into "not there" would steal a live owner's lock as stale (the "never seize what can't be
  # confirmed" rule applied to every other input -- except this one, `ps`'s own answer, which used
  # to sit outside it).
  # An unanswering `ps` is built as a failing shim at the front of PATH (confined to this check's own subshell).
  broken_ps_bin="$tmp/broken-ps-bin"
  mkdir -p "$broken_ps_bin"
  printf '#!/usr/bin/env bash\nexit 127\n' >"$broken_ps_bin/ps"
  chmod +x "$broken_ps_bin/ps"
  rein_pid_alive "$$"
  lock_probe_rc=$?
  if [ "$lock_probe_rc" -eq 0 ]; then
    st_ok
  else
    st_fail "a live pid is alive" "rein_pid_alive(self)=${lock_probe_rc}"
  fi
  # A pid near the allocation ceiling (kern.maxproc) that doesn't exist. `ps` answers, so it's "not there".
  rein_pid_alive 99998
  lock_probe_rc=$?
  if [ "$lock_probe_rc" -eq 1 ]; then
    st_ok
  else
    st_fail "a nonexistent pid is not alive" "rein_pid_alive(99998)=${lock_probe_rc}"
  fi
  (
    # shellcheck disable=SC2030  # confined to a subshell on purpose (never dirties this check's own PATH)
    PATH="$broken_ps_bin:$PATH"
    rein_pid_alive "$$"
  )
  lock_probe_rc=$?
  if [ "$lock_probe_rc" -eq 2 ]; then
    st_ok
  else
    st_fail "liveness is undetermined when ps doesn't answer" \
      "rein_pid_alive(ps unresponsive)=${lock_probe_rc} (collapsed into the same value as not-alive)"
  fi
  # Undetermined falls under never-seize as well (it isn't stale).
  rein_claim_lock_dir "$tmp/stale-probe.lock" start "$(rein_process_start_identity "$$")"
  (
    # shellcheck disable=SC2031  # unrelated to the subshell's PATH above (each subshell sets its own independently)
    PATH="$broken_ps_bin:$PATH"
    rein_lock_dir_is_stale "$tmp/stale-probe.lock"
  )
  lock_probe_rc=$?
  if [ "$lock_probe_rc" -eq 1 ]; then
    st_ok
  else
    st_fail "not read as stale when ps doesn't answer" \
      "rein_lock_dir_is_stale=${lock_probe_rc} (said it was OK to remove a live owner's lock)"
  fi
  rein_release_lock_dir "$tmp/stale-probe.lock"

  # A pid gets reused. The watcher lock's owner isn't read as resident unless it's really rein's
  # watcher. **Once identity has actually been checked, this is "not running (a stale lock)", not
  # "undetermined"** -- kept aligned with the acquiring side (the watcher reclaims through the
  # same identity check). Folding it into unknown would permanently stall the machine-readable
  # side (`status --json`'s `.watcher.state`) that decides whether it's OK to start.
  fake_runtime="$tmp/fake-runtime"
  mkdir -p "$fake_runtime/$REIN_LOCK_DIRNAME"
  printf '%s\n' "$proj2" >"$fake_runtime/$REIN_OWNER_BASENAME"
  printf '%s\n' "$$" >"$fake_runtime/$REIN_LOCK_DIRNAME/pid"
  st_run_env --root "$root2" --cwd "$proj2" status --json --runtime-dir "$fake_runtime"
  if [ "$(printf '%s' "$ST_OUT" | jq -r '.watcher.state' 2>/dev/null)" = "stopped" ]; then
    st_ok
  else
    st_fail "doesn't read someone else's pid as the watcher" "$ST_OUT"
  fi
  st_expect_contains "a reused pid is read as a stale lock" "a stale lock"
  st_expect_contains "shows the reason identity didn't match" "not rein's watcher"
  # Since the classification is "not resident," `up` can still start it there too (the acquiring
  # side reclaims a stale lock through the same identity check). Blocking it here would mean a
  # reused-PID location can never hold a handover ever again.
  st_run_env --root "$root2" --cwd "$proj2" up --no-bootstrap --runtime-dir "$fake_runtime"
  if st_expect_status "up can still make a PID-reused location resident" 0; then
    st_expect_contains "reports it reclaimed and started it" "watcher started (pid="
  fi
  st_run_env --root "$root2" --cwd "$proj2" down --runtime-dir "$fake_runtime"
  st_expect_status "the reclaimed watcher can also be stopped" 0 && st_ok
  # The classification's opposite side: only an input that can't be judged at all is unknown
  # (this is where the never-seize rule applies).
  mkdir -p "$fake_runtime/$REIN_LOCK_DIRNAME"
  st_run_env --root "$root2" --cwd "$proj2" status --json --runtime-dir "$fake_runtime"
  if [ "$(printf '%s' "$ST_OUT" | jq -r '.watcher.state' 2>/dev/null)" = "unknown" ]; then
    st_ok
  else
    st_fail "a watcher lock whose owner can't be read is undetermined" "$ST_OUT"
  fi
  st_expect_contains "shows the undetermined reason" "cannot read the watcher lock's owner"
  # If a runtime directory is named explicitly for a different lineage, don't read its watcher as this lineage's own.
  printf '%s\n' "$tmp/other-project" >"$fake_runtime/$REIN_OWNER_BASENAME"
  st_run_env --root "$root2" --cwd "$proj2" status --runtime-dir "$fake_runtime"
  st_expect_reject "doesn't judge a location whose owner differs" 1 "belongs to a different target"
  # A round where a precondition for judging isn't even met (config is broken) returns non-zero
  # rather than a current-state value (answering "not running" on a broken config would hand the
  # caller a false signal).
  mkdir -p "$proj2/$REIN_RECORDS_DIRNAME"
  printf 'unknown_key=1\n' >"$proj2/$REIN_RECORDS_DIRNAME/config"
  st_allow_project_file "$proj2/$REIN_RECORDS_DIRNAME/config" "$root2/config/rein/config"
  st_run_env --root "$root2" --cwd "$proj2" status
  st_expect_reject "status on broken config is non-zero" 1 "unknown key:"
  rm -f "$proj2/$REIN_RECORDS_DIRNAME/config"

  # The watcher's identity check (measures the boundary without calling real ps). An unrelated
  # process whose command line merely contains `rein-watcher.sh` must not be read as the watcher,
  # or a stop request gets left on that lineage.
  if rein_watcher_command_matches " 4242 bash ${REIN_WATCHER_SCRIPT_PATH} --cwd /a/b --settings x" "/a/b"; then
    st_ok
  else
    st_fail "reads its own lineage's watcher as the watcher" "couldn't match it"
  fi
  if rein_watcher_command_matches " 4242 bash ${REIN_WATCHER_SCRIPT_PATH} --cwd /a/bc" "/a/b"; then
    st_fail "doesn't pick it up on a prefix match of the target (watcher)" "read /a/bc as /a/b's watcher"
  else
    st_ok
  fi
  if rein_watcher_command_matches " 4242 vim /elsewhere/rein-watcher.sh --cwd /a/b" "/a/b"; then
    st_fail "doesn't pick up an unrelated command that merely contains the name" "read an editor as the watcher"
  else
    st_ok
  fi
  # Never reads an option name inside a value as an option. Scanning `ps command`'s whole line as
  # flat text would mistake the word ` --bootstrap` sitting inside the **value** of `--cwd` or
  # `--settings` for "a one-shot bootstrap run," permanently stealing a live watcher's lock.
  if rein_watcher_command_matches \
    " 4242 bash ${REIN_WATCHER_SCRIPT_PATH} --cwd /a/b --bootstrap --settings x" "/a/b --bootstrap"; then
    st_ok
  else
    st_fail "doesn't read an option name inside a value as an option" "couldn't match a watcher whose cwd contains --bootstrap"
  fi
  if rein_watcher_command_matches \
    " 4242 bash ${REIN_WATCHER_SCRIPT_PATH} --cwd /a/b --settings '/x --bootstrap'" "/a/b"; then
    st_ok
  else
    st_fail "doesn't read an option name inside settings' value either" "couldn't match a watcher whose settings contains --bootstrap"
  fi

  # Role is judged by **what the lock declares** (the one-shot bootstrap entry point never takes
  # the watcher lock, so it can never show up as its owner -- if it ever does, that's treated as a
  # mechanism-level anomaly and never seized).
  mkdir -p "$fake_runtime"
  printf '%s\n' "$proj2" >"$fake_runtime/$REIN_OWNER_BASENAME"
  rm -rf "${fake_runtime:?}/$REIN_LOCK_DIRNAME"
  rein_claim_lock_dir "$fake_runtime/$REIN_LOCK_DIRNAME" \
    start "$(rein_process_start_identity "$$")" cwd "$proj2" mode bootstrap token "st-bootstrap"
  st_run_env --root "$root2" --cwd "$proj2" status --json --runtime-dir "$fake_runtime"
  if [ "$(printf '%s' "$ST_OUT" | jq -r '.watcher.state' 2>/dev/null)" = "unknown" ]; then
    st_ok
  else
    st_fail "doesn't read a non-resident role's declaration as resident" "$ST_OUT"
  fi
  rm -rf "${fake_runtime:?}/$REIN_LOCK_DIRNAME"

  # A lock whose declared cwd disagrees is also never seized (it might be a watcher watching a
  # different lineage -- seizing it would silently kill that lineage's residency). Role stays
  # **resident** so this one case only flips on the cwd branch (pinning only the role branch
  # would leave the preceding cwd branch untouched by anything, free to drift to "OK to seize").
  mkdir -p "$fake_runtime"
  printf '%s\n' "$proj2" >"$fake_runtime/$REIN_OWNER_BASENAME"
  rm -rf "${fake_runtime:?}/$REIN_LOCK_DIRNAME"
  rein_claim_lock_dir "$fake_runtime/$REIN_LOCK_DIRNAME" \
    start "$(rein_process_start_identity "$$")" cwd "$proj2/elsewhere" \
    mode "$REIN_LOCK_MODE_WATCH" token "st-other-cwd"
  st_run_env --root "$root2" --cwd "$proj2" status --json --runtime-dir "$fake_runtime"
  if [ "$(printf '%s' "$ST_OUT" | jq -r '.watcher.state' 2>/dev/null)" != "unknown" ]; then
    st_fail "doesn't read a lock declaring a different cwd as resident" "$ST_OUT"
  else
    case "$(printf '%s' "$ST_OUT" | jq -r '.watcher.reason' 2>/dev/null)" in
      *"$proj2/elsewhere"*)
        st_ok
        ;;
      *)
        st_fail "the never-seize reason names the declared cwd" "$ST_OUT"
        ;;
    esac
  fi
  rm -rf "${fake_runtime:?}/$REIN_LOCK_DIRNAME"

  # Identifying the owner isn't enough with pid alone (pids get reused). Even with a command line
  # that looks like the watcher, an owner whose declared start time disagrees isn't read as
  # resident.
  rein_st_start_fake_watcher "$runtime2" "$proj2"
  printf '%s\n' "$proj2" >"$runtime2/$REIN_LOCK_DIRNAME/cwd"
  printf 'Thu Jan  1 00:00:00 2020\n' >"$runtime2/$REIN_LOCK_DIRNAME/start"
  st_run_env --root "$root2" --cwd "$proj2" status --json
  if [ "$(printf '%s' "$ST_OUT" | jq -r '.watcher.state' 2>/dev/null)" = "stopped" ]; then
    st_ok
  else
    st_fail "doesn't read an owner whose declared start time disagrees as resident" "$ST_OUT"
  fi
  rein_st_stop_fake_watcher "$runtime2"

  # Presence is judged by the **seat lock** the seat claims first (checking against `ps` couldn't
  # close the window where the other side vanishes between checking and starting, or two starts
  # race). The owner's liveness is confirmed by its declared pid.
  seat_dir="$tmp/seat-bin"
  mkdir -p "$seat_dir"
  # How long it's held is **never decided by the wall clock** (a fixed `sleep 6` let the 4 starts
  # below overrun the window on a loaded machine, with the owner gone before they got there --
  # overrunning it left `up` running with no seat present, waking a real attach loop that
  # **never returns** -- a hang instead of a red, observed). Release happens on a
  # marker this check places once its own observation is done; the cap is only a guardrail
  # against leaving it stuck.
  cat >"$seat_dir/seat-holder.sh" <<'EOF'
#!/usr/bin/env bash
# Actually claims the seat lock, then holds it until the release marker is placed
# (presence is observed through a lock that was actually claimed).
. "$1/lib/rein-common.sh"
rein_claim_lock_dir "$2" start "$(rein_process_start_identity "$$")" cwd "$3" token "holder" || exit 1
n=0
while [ ! -e "$4" ] && [ "$n" -lt 1200 ]; do
  n=$((n + 1))
  sleep 0.5
done
EOF
  chmod +x "$seat_dir/seat-holder.sh"
  mkdir -p "$runtime2"
  # No seat at all: the machine reader gets nulls, not a comparison it could mistake for a
  # verdict. Measured **before** the holder below claims the lock -- this is the only moment in
  # this check where the lineage genuinely has no seat.
  st_run_env --root "$root2" --cwd "$proj2" status --json
  if [ "$(printf '%s' "$ST_OUT" | jq -r '.seat.state' 2>/dev/null)" = "none" ] &&
    [ "$(printf '%s' "$ST_OUT" | jq -r '.seat.connection' 2>/dev/null)" = "null" ] &&
    [ "$(printf '%s' "$ST_OUT" | jq -r '.seat.attached_session_id' 2>/dev/null)" = "null" ] &&
    [ "$(printf '%s' "$ST_OUT" | jq -r '.seat.pointer_match' 2>/dev/null)" = "null" ]; then
    st_ok
  else
    st_fail "the machine reader sees no seat as nulls, not as a comparison" "$ST_OUT"
  fi
  seat_release="$tmp/seat-holder.release"
  rm -f "$seat_release"
  "$seat_dir/seat-holder.sh" "$SCRIPTS_DIR" "$runtime2/$REIN_SEAT_LOCK_DIRNAME" "$proj2" "$seat_release" &
  seat_pid=$!
  # Waits until the lock is published (publishing is a rename, so once it's visible the pid
  # declaration is already filled in too).
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -d "$runtime2/$REIN_SEAT_LOCK_DIRNAME" ] && break
    sleep 0.2
  done
  st_run_env --root "$root2" --cwd "$proj2" status
  st_expect_seat_line "reads the seat lock's owner as attached" "attached"
  # Presence alone is **not** what the seat line reports any more. The lock declares who is
  # seated and nothing about the target, so a seat stuck on a session the pointer moved off used
  # to read as a plain "attached" -- the state the observed accident sat in for over 4 hours
  # while status said the seat was fine. Where no attach has been recorded, the line says that
  # rather than implying the connection is in step.
  st_expect_seat_line "presence with no recorded attach says so" \
    "not connected yet -- the seat has not entered attach yet (there is no seat log)"
  # The machine reader gets the same answer: a present seat that has never attached carries no
  # target and no verdict. Without this, an automated check reading only `pointer_match` cannot
  # tell "in step" from "there is nothing to compare."
  st_run_env --root "$root2" --cwd "$proj2" status --json
  if [ "$(printf '%s' "$ST_OUT" | jq -r '.seat.state' 2>/dev/null)" = "attached" ] &&
    [ "$(printf '%s' "$ST_OUT" | jq -r '.seat.connection' 2>/dev/null)" = "none" ] &&
    [ "$(printf '%s' "$ST_OUT" | jq -r '.seat.attached_session_id' 2>/dev/null)" = "null" ] &&
    [ "$(printf '%s' "$ST_OUT" | jq -r '.seat.pointer_match' 2>/dev/null)" = "null" ]; then
    st_ok
  else
    st_fail "the machine reader sees an unrecorded connection as nulls" "$ST_OUT"
  fi
  mkdir -p "$records2"
  seat_log_probe="$records2/$REIN_SEAT_LOG_BASENAME"
  # The record is written through **the real writer** (the same function the attach loop calls),
  # so this check rides on the actual column contract rather than a hand-shaped copy of it that
  # could drift.
  rein_seat_log_event "$seat_log_probe" "$REIN_SEAT_EVENT_ATTACH_STARTED" \
    "attaching to session sess-live" "1" "sess-live"
  # The pointer is deliberately left unwritten for this one: nothing to compare against is its
  # own answer, and had to be, or an unreadable pointer would quietly become a mismatch against
  # an empty string -- a lineage in a cold start would be reported as a seat that had drifted.
  st_run_env --root "$root2" --cwd "$proj2" status
  st_expect_seat_line "a connection with no readable pointer says the comparison cannot be made" \
    "connected to sess-live, cannot be compared against the current pointer"
  st_run_env --root "$root2" --cwd "$proj2" status --json
  if [ "$(printf '%s' "$ST_OUT" | jq -r '.seat.connection' 2>/dev/null)" = "attached" ] &&
    [ "$(printf '%s' "$ST_OUT" | jq -r '.seat.attached_session_id' 2>/dev/null)" = "sess-live" ] &&
    [ "$(printf '%s' "$ST_OUT" | jq -r '.seat.pointer_match' 2>/dev/null)" = "null" ]; then
    st_ok
  else
    st_fail "the machine reader gets the target but no verdict when there is no pointer" "$ST_OUT"
  fi
  rein_st_write_pointer "$records2/$REIN_POINTER_BASENAME" "sess-live" "primary" "$proj2" 1
  st_run_env --root "$root2" --cwd "$proj2" status
  st_expect_seat_line "the seat line names what it is connected to, and that it is in step" \
    "connected to sess-live, matches the current pointer"
  st_run_env --root "$root2" --cwd "$proj2" status --json
  if [ "$(printf '%s' "$ST_OUT" | jq -r '.seat.attached_session_id' 2>/dev/null)" = "sess-live" ] &&
    [ "$(printf '%s' "$ST_OUT" | jq -r '.seat.pointer_match' 2>/dev/null)" = "true" ]; then
    st_ok
  else
    st_fail "the machine reader gets the target and the comparison too" "$ST_OUT"
  fi
  # **The state the whole reading exists for**: attach has returned, so the seat is connected to
  # nothing -- and the pointer still names the session it was on. Read from `attach_started`
  # alone this is indistinguishable from a live, in-step connection, and it is not a moment: it
  # lasts for the whole of any wait for a handover, which has no time limit at all.
  rein_seat_log_event "$seat_log_probe" "$REIN_SEAT_EVENT_ATTACH_ENDED" \
    "attach returned (rc=0) from session sess-live" "1" "sess-live"
  st_run_env --root "$root2" --cwd "$proj2" status
  st_expect_seat_line "a seat between attaches is not reported as connected" \
    "not connected right now -- attach last returned from sess-live"
  st_expect_seat_line_lacks "and the line no longer claims to be in step with the pointer" \
    "matches the current pointer"
  st_run_env --root "$root2" --cwd "$proj2" status --json
  if [ "$(printf '%s' "$ST_OUT" | jq -r '.seat.connection' 2>/dev/null)" = "between" ] &&
    [ "$(printf '%s' "$ST_OUT" | jq -r '.seat.pointer_match' 2>/dev/null)" = "null" ]; then
    st_ok
  else
    st_fail "the machine reader gets no verdict for a seat between attaches" "$ST_OUT"
  fi
  # A fresh seat announcing itself is the newest line, so the previous occupancy's target stops
  # being read as this seat's (the log outlives the process that wrote it).
  rein_seat_log_event "$seat_log_probe" "$REIN_SEAT_EVENT_SEATED" \
    "a seat has sat down (it has not entered attach yet)" "1" ""
  st_run_env --root "$root2" --cwd "$proj2" status
  st_expect_seat_line "a newly seated seat does not inherit the previous connection" \
    "not connected yet -- the seat has not entered attach yet"
  st_expect_seat_line_lacks "and the previous occupancy's target is gone from the line" "sess-live"
  # The accident's own shape: the pointer moved on, the seat did not. Presence is unchanged, so
  # this is the only place the state can show up at all.
  rein_seat_log_event "$seat_log_probe" "$REIN_SEAT_EVENT_ATTACH_STARTED" \
    "attaching to session sess-live" "1" "sess-live"
  rein_st_write_pointer "$records2/$REIN_POINTER_BASENAME" "sess-next" "successor" "$proj2" 2
  st_run_env --root "$root2" --cwd "$proj2" status
  st_expect_seat_line "the seat line reports a connection the pointer moved off" \
    "connected to sess-live, but the current pointer is sess-next"
  # A mismatch the user can't act on is the defect the notification had too, so the line carries
  # the same one instruction (held in one place, so the two surfaces can't diverge).
  st_expect_seat_line "the mismatch names the way out" "$REIN_SEAT_DETACH_HINT"
  # **The wording itself, once, as a literal.** Every other check on this instruction -- here and
  # in the seat's own selftest -- reads it from the same constant the code prints, so gutting the
  # constant into something that tells the user nothing would leave the whole suite green. This
  # is the one place that would go red.
  st_expect_seat_line "and the instruction is the real one, not whatever the constant now holds" \
    "leave the agent list screen and the seat reconnects to the successor on its own"
  st_run_env --root "$root2" --cwd "$proj2" status --json
  if [ "$(printf '%s' "$ST_OUT" | jq -r '.seat.pointer_match' 2>/dev/null)" = "false" ]; then
    st_ok
  else
    st_fail "the machine reader sees the mismatch as false" "$ST_OUT"
  fi
  # A seat log that cannot be scanned is its own answer. jq stops at the first line that isn't in
  # contract form, having already emitted the ones before it, so folding this into "nothing
  # recorded" would hand back the target from **before** the damage and present it as current --
  # which here is the very session the pointer has moved off.
  printf '{"schema":\n' >>"$seat_log_probe"
  st_run_env --root "$root2" --cwd "$proj2" status
  st_expect_seat_line "an unreadable seat log is reported as unreadable, not as a connection" \
    "connection state unknown"
  st_expect_seat_line_lacks "and the stale target from before the damage is not presented as current" \
    "sess-live"
  st_run_env --root "$root2" --cwd "$proj2" status --json
  if [ "$(printf '%s' "$ST_OUT" | jq -r '.seat.connection' 2>/dev/null)" = "unreadable" ] &&
    [ "$(printf '%s' "$ST_OUT" | jq -r '.seat.attached_session_id' 2>/dev/null)" = "null" ] &&
    [ "$(printf '%s' "$ST_OUT" | jq -r '.seat.pointer_match' 2>/dev/null)" = "null" ] &&
    [ "$(printf '%s' "$ST_OUT" | jq -r '[.unreadable[].field] | index("seat_connection")' 2>/dev/null)" != "null" ]; then
    st_ok
  else
    st_fail "the machine reader lists the unreadable seat log instead of a verdict" "$ST_OUT"
  fi
  rm -f "$seat_log_probe"
  # The seat layer is idempotent too -- `up` on a lineage the user's own terminal is already
  # attached to reports presence and ends with 0 rather than falling through to the attach loop's
  # own presence rejection (a standalone `rein attach`'s own rejection is unchanged). To reach the
  # seat layer, the primary-session layer ahead of it is set to pass (the pointer targets a live
  # session present in the fake CLI's enumeration).
  mkdir -p "$records2"
  rein_st_write_pointer "$records2/$REIN_POINTER_BASENAME" "sess-live" "primary" "$proj2" 1
  st_run_env --root "$root2" --cwd "$proj2" up
  if st_expect_status "up ends with 0 when the seat is already attached" 0; then
    st_expect_contains "reports the attached seat" "seat is attached (pid=${seat_pid})"
    st_expect_not_contains "doesn't fall into the presence rejection" "already has an attach loop seated"
  fi
  # The other side: a standalone `rein attach`'s own presence rejection is unchanged, non-zero
  # (the user doesn't steal a seat someone is actively using).
  st_run_env --root "$root2" --cwd "$proj2" attach
  st_expect_reject "a standalone attach refuses on presence" 1 "already has an attach loop seated"
  rm -f "$records2/$REIN_POINTER_BASENAME"
  # Presence has been measured, so release the owner (from here on, this measures "a lock left
  # behind once its owner is gone").
  : >"$seat_release"
  wait "$seat_pid"
  # A leftover lock whose owner is gone isn't read as attached (liveness is confirmed by pid and start time).
  st_run_env --root "$root2" --cwd "$proj2" status
  st_expect_contains "a lock whose owner is gone isn't read as attached" "seat: none"
  rm -rf "${runtime2:?}/$REIN_SEAT_LOCK_DIRNAME"

  # `--watcher-only` only stops the watcher (it never touches the primary session or the seat).
  : >"$verb_log"
  rein_st_write_pointer "$records2/$REIN_POINTER_BASENAME" "sess-live" "primary" "$proj2" 1
  st_run_env --root "$root2" --cwd "$proj2" down --watcher-only
  if st_expect_status "--watcher-only stops the watcher" 0; then
    st_expect_contains "down reports it stopped" "watcher stopped"
  fi
  st_expect_true "no watcher lock remains after stopping" test ! -e "$runtime2/$REIN_LOCK_DIRNAME"
  st_expect_true "the stop request is consumed" test ! -e "$runtime2/$REIN_STOP_REQUEST_BASENAME"
  st_expect_true "the operation lock is released" test ! -e "$runtime2/$REIN_OP_LOCK_DIRNAME"
  if [ "$(rein_st_count_sub "$verb_log" stop)" -eq 0 ]; then
    st_ok
  else
    st_fail "--watcher-only doesn't stop the session" "$(cat "$verb_log")"
  fi
  st_expect_true "--watcher-only doesn't place a seat-stop marker" \
    test ! -e "$runtime2/$REIN_SEAT_STOP_BASENAME"
  st_run_env --root "$root2" --cwd "$proj2" status --json
  if [ "$(printf '%s' "$ST_OUT" | jq -r '.watcher.state' 2>/dev/null)" = "stopped" ]; then
    st_ok
  else
    st_fail "watcher.state after stopping is stopped" "$ST_OUT"
  fi

  # The default `down` also stops the primary session, and places a seat-stop marker (the seat
  # quietly goes down on that marker). The watcher is already stopped, so this also measures the
  # session layer acting even when the watcher isn't there.
  : >"$verb_log"
  st_run_env --root "$root2" --cwd "$proj2" down
  if st_expect_status "the default down also stops the primary session" 0; then
    st_expect_contains "names the target in one line before stopping" "stopping primary session sess-live (primary)"
    st_expect_contains "says it stopped" "primary session stopped: sess-live"
    # What's handed to the external stop is the short job ID resolved from enumeration (the full session_id isn't accepted by the real CLI).
    if [ "$(rein_st_count_calls "$verb_log" stop job-sess-live)" -eq 1 ]; then
      st_ok
    else
      st_fail "stops it externally by the short job ID" "$(cat "$verb_log")"
    fi
    st_expect_true "places a seat-stop marker" test -f "$runtime2/$REIN_SEAT_STOP_BASENAME"
  fi
  if [ "$(jq -r '[keys[]] | join(",")' "$runtime2/$REIN_SEAT_STOP_BASENAME" 2>/dev/null)" = \
    "requested_at,requested_by_pid,schema" ] &&
    [ "$(jq -r '.schema' "$runtime2/$REIN_SEAT_STOP_BASENAME" 2>/dev/null)" = "$REIN_SEAT_STOP_SCHEMA" ]; then
    st_ok
  else
    st_fail "the seat-stop marker's contents" "$(cat "$runtime2/$REIN_SEAT_STOP_BASENAME" 2>/dev/null)"
  fi
  st_run_env --root "$root2" --cwd "$proj2" status
  st_expect_contains "status reports the seat-stop marker" "seat stop: present (requested at "
  st_run_env --root "$root2" --cwd "$proj2" status --json
  if [ "$(printf '%s' "$ST_OUT" | jq -r '.seat_stop.schema' 2>/dev/null)" = "$REIN_SEAT_STOP_SCHEMA" ]; then
    st_ok
  else
    st_fail "status --json carries the seat-stop marker" "$ST_OUT"
  fi
  # A marker nobody consumed is cleared by the next up (leaving it means the next seat that
  # attaches consumes it on its very first attach return and silently goes back down).
  st_run_env --root "$root2" --cwd "$proj2" up --no-bootstrap
  if st_expect_status "up succeeds even with a leftover marker there" 0; then
    st_expect_contains "says it cleared the leftover marker" "seat-stop marker cleared"
    st_expect_true "the leftover marker is gone" test ! -e "$runtime2/$REIN_SEAT_STOP_BASENAME"
  fi
  st_run_env --root "$root2" --cwd "$proj2" down --watcher-only
  st_expect_status "cleaning up the marker also stops the watcher it started" 0 && st_ok

  # Rejecting side: no way to stop it externally / the stop fails / it doesn't drop out of
  # enumeration by the cap -- all non-zero (silently succeeding would report the lineage as shut
  # down while a primary session is still running there).
  rein_st_write_agents_interactive "$verb_agents" "$proj2" "sess-tty"
  rein_st_write_pointer "$records2/$REIN_POINTER_BASENAME" "sess-tty" "primary" "$proj2" 1
  rm -f "$runtime2/$REIN_SEAT_STOP_BASENAME"
  st_run_env --root "$root2" --cwd "$proj2" down
  if st_expect_reject "an interactive session can't be stopped externally" 1 "is an interactive session"; then
    st_expect_true "no marker is placed on a round that couldn't stop it" \
      test ! -e "$runtime2/$REIN_SEAT_STOP_BASENAME"
  fi
  rein_st_write_agents "$verb_agents" "$proj2" "sess-live"
  rein_st_write_pointer "$records2/$REIN_POINTER_BASENAME" "sess-live" "primary" "$proj2" 1
  ST_VERB_ENV+=("FAKE_STOP_FAIL=1")
  st_run_env --root "$root2" --cwd "$proj2" down
  st_expect_reject "doesn't turn a failed claude stop into a success" 1 "claude stop exited non-zero"
  ST_VERB_ENV=("${ST_VERB_ENV[@]:0:${#ST_VERB_ENV[@]}-1}")
  ST_VERB_ENV+=("FAKE_STOP_INEFFECTIVE=1")
  st_run_env --root "$root2" --cwd "$proj2" down
  st_expect_reject "doesn't turn a stop that doesn't drop out by the cap into a success" 1 "didn't drop out of enumeration"
  ST_VERB_ENV=("${ST_VERB_ENV[@]:0:${#ST_VERB_ENV[@]}-1}")
  # A round that couldn't fully stop it still leaves the marker (cleaned up before the next up
  # and the next seat -- same discipline as the stop request).
  st_expect_true "the marker stays even on a round that couldn't fully stop it" test -f "$runtime2/$REIN_SEAT_STOP_BASENAME"
  rm -f "$runtime2/$REIN_SEAT_STOP_BASENAME"
  # Actually stops it before handing off to the next section (don't leave a live session in enumeration).
  st_run_env --root "$root2" --cwd "$proj2" down
  st_expect_status "cleanup on the rejecting side (stopping the primary session)" 0 && st_ok
  rm -f "$runtime2/$REIN_SEAT_STOP_BASENAME"

  # A pointer from a duplicated work tree (a `.rein/current.json` that `cp -r` carries along --
  # its inner `cwd` still names the original path) is stopped by contract validation. Back when it
  # was read raw, `down` on the duplicate side **externally stopped a live session belonging to
  # the original lineage** (prune and hooks already went through this same validation -- only the
  # CLI was missing it).
  rein_st_write_agents "$verb_agents" "$proj2" "sess-live"
  rein_st_write_pointer "$records2/$REIN_POINTER_BASENAME" "sess-live" "primary" "$tmp/other-tree" 1
  : >"$verb_log"
  st_run_env --root "$root2" --cwd "$proj2" down
  if st_expect_reject "down isn't let through on a duplicated lineage's pointer" 1 "the cwd in current.json does not match the target"; then
    if [ "$(rein_st_count_sub "$verb_log" stop)" -eq 0 ]; then
      st_ok
    else
      st_fail "doesn't externally stop what a duplicated pointer targets" "$(cat "$verb_log")"
    fi
  fi
  st_run_env --root "$root2" --cwd "$proj2" status
  st_expect_contains "says the current state can't be determined" "primary session: undetermined"
  st_expect_contains "doesn't report a generation for a pointer that violates the contract" "generation: -"
  st_run_env --root "$root2" --cwd "$proj2" status --json
  if [ "$(printf '%s' "$ST_OUT" | jq -r '.main_session.state' 2>/dev/null)" = "unknown" ] &&
    [ "$(printf '%s' "$ST_OUT" | jq -r '.generation' 2>/dev/null)" = "null" ]; then
    st_ok
  else
    st_fail "the JSON also doesn't let a pointer that violates the contract through" "$ST_OUT"
  fi
  # Accepting side: line up just the cwd on the same content, and it stops it as before (the
  # validation doesn't block everything).
  rein_st_write_pointer "$records2/$REIN_POINTER_BASENAME" "sess-live" "primary" "$proj2" 1
  : >"$verb_log"
  st_run_env --root "$root2" --cwd "$proj2" down
  if st_expect_status "a pointer with a matching cwd is stopped" 0; then
    if [ "$(rein_st_count_calls "$verb_log" stop job-sess-live)" -eq 1 ]; then
      st_ok
    else
      st_fail "a pointer with a matching cwd is stopped externally" "$(cat "$verb_log")"
    fi
  fi
  rm -f "$runtime2/$REIN_SEAT_STOP_BASENAME"

  # Even a lineage with no runtime directory never skips the primary-session layer (the current
  # pointer lives on the records side, independent of the runtime data location -- "there's no
  # location" and "there's no primary session" are different facts).
  rein_st_write_agents "$verb_agents" "$proj2" "sess-live"
  rein_st_write_pointer "$records2/$REIN_POINTER_BASENAME" "sess-live" "primary" "$proj2" 1
  : >"$verb_log"
  st_run_env --root "$root2" --cwd "$proj2" down --runtime-dir "$tmp/absent-runtime"
  if st_expect_status "down still stops the primary session with no location" 0; then
    st_expect_contains "says there's no location in one line" "no runtime data location"
    st_expect_contains "still stops the primary session with no location" "primary session stopped: sess-live"
    # No location for the marker means no seat either (the seat lock lives under it) -- never create it as a side effect of stopping.
    st_expect_true "doesn't create the location as a side effect of stopping" test ! -e "$tmp/absent-runtime"
  fi
  # The other side: with neither a location nor a primary session, report each in one line and end with 0 (there's nothing to stop).
  : >"$verb_log"
  st_run_env --root "$root2" --cwd "$proj2" down --runtime-dir "$tmp/absent-runtime"
  if st_expect_status "down with neither a location nor a primary session is 0" 0; then
    st_expect_contains "says there's no primary session in one line" "no primary session"
    if [ "$(rein_st_count_sub "$verb_log" stop)" -eq 0 ]; then
      st_ok
    else
      st_fail "doesn't try to stop a primary session that isn't there" "$(cat "$verb_log")"
    fi
  fi
  rm -f "$records2/$REIN_POINTER_BASENAME"

  st_run_env --root "$root2" --cwd "$proj2" down
  if st_expect_status "down when nothing is resident also ends with 0" 0; then
    st_expect_contains "down when nothing is resident says so" "is not running"
  fi
  # Even on the side with no watcher, "stopped" only holds once a leftover stop request is also
  # cleaned up (leaving it means the next watcher started consumes it on its very first loop and
  # goes straight back down).
  printf '{"schema":"%s","requested_at":"%s","requested_by_pid":%s}\n' \
    "$REIN_STOP_REQUEST_SCHEMA" "$(rein_iso_now)" "$$" >"$runtime2/$REIN_STOP_REQUEST_BASENAME"
  st_run_env --root "$root2" --cwd "$proj2" down
  if st_expect_status "down when nothing is resident also ends with 0 (a request is left over)" 0; then
    st_expect_contains "says it cleaned up the leftover stop request" "stop request cleared"
  fi
  st_expect_true "no stop request remains even with nothing resident" \
    test ! -e "$runtime2/$REIN_STOP_REQUEST_BASENAME"

  # The case where the stop request's path isn't a regular file. If the entry point only asked
  # whether it's there, it would end with 0 **without even attempting a delete**, and that state
  # would sit unnoticed until a later `down`'s write finally fails on it (a fail-loud that arrives too
  # late). Judge by presence, then fail through the same vocabulary the writer uses for anything
  # other than a regular file.
  mkdir -p "$runtime2/$REIN_STOP_REQUEST_BASENAME"
  st_run_env --root "$root2" --cwd "$proj2" down --watcher-only
  if st_expect_reject "down doesn't end with 0 when the stop request's path is a directory" 1 \
    "is not a regular file"; then
    st_expect_not_contains "doesn't claim it cleared a stop request it never removed" "stop request cleared"
  fi
  rmdir "$runtime2/$REIN_STOP_REQUEST_BASENAME"
  ln -s "$runtime2/nowhere-stop-request" "$runtime2/$REIN_STOP_REQUEST_BASENAME"
  st_run_env --root "$root2" --cwd "$proj2" down --watcher-only
  if st_expect_reject "down doesn't end with 0 when the stop request's path is a broken symlink" 1 \
    "is not a regular file"; then
    st_expect_not_contains "doesn't claim it cleared a stop request it never removed (broken symlink)" \
      "stop request cleared"
  fi
  st_expect_true "doesn't create the target on a round that failed" \
    test ! -e "$runtime2/nowhere-stop-request"
  rm -f "$runtime2/$REIN_STOP_REQUEST_BASENAME"

  # Starts one watcher whose loop's sleep has been stopped, to measure (1) that the heartbeat's
  # freshness affects overall state, and (2) that a `down` that doesn't come down by its cap
  # still reports the request as still there. A watcher whose loop is still turning would rewrite
  # the heartbeat right away, and pick up the stop request on the next loop too, so this can only
  # be observed **on a lineage whose loop's sleep has been stopped**. Merely widening the interval
  # (a slower watcher) makes the result flip round to round on a loaded machine, where observation
  # itself lags and gets overtaken by the next loop (the check on `down`'s cap actually broke that
  # way in practice). What's stopped is the `sleep` shim at the front of PATH -- it only halts the
  # watcher's own loop sleep.
  slow_runtime="$tmp/slow-runtime"
  hold_bin="$tmp/slow-watcher-bin"
  hold_file="$tmp/slow-watcher.hold"
  frozen_file="$tmp/slow-watcher.frozen"
  rm -f "$frozen_file"
  st_write_watcher_hold_sleep_shim "$hold_bin" "$hold_file" "$frozen_file"
  : >"$hold_file"
  hold_path_saved="${ST_VERB_ENV[0]}"
  ST_VERB_ENV[0]="PATH=${hold_bin}:${hold_path_saved#PATH=}"
  st_run_env --root "$root2" --cwd "$proj2" up --no-bootstrap --runtime-dir "$slow_runtime"
  frozen_ok=0
  if st_expect_status "starts a watcher whose loop has been stopped" 0; then
    # Measured only after seeing the loop actually stop (a round that missed catching it would
    # go green while unknowingly observing a watcher whose loop is still turning). `up` waits for
    # the heartbeat to appear before returning, so what stops here is the sleep right after
    # finishing loop 1 -- the heartbeat is already written by then.
    frozen_polls=0
    while [ "$frozen_polls" -lt 150 ] && [ ! -e "$frozen_file" ]; do
      sleep 0.2
      frozen_polls=$((frozen_polls + 1))
    done
    if [ -e "$frozen_file" ]; then
      frozen_ok=1
    else
      st_fail "can stop the watcher's loop" \
        "the sleep shim never caught the watcher's sleep: ${frozen_file}"
    fi
  fi
  if [ "$frozen_ok" -eq 1 ]; then
    touch -t 200001010000 "$slow_runtime/$REIN_HEARTBEAT_BASENAME"
    ST_VERB_ENV+=("REIN_SEAT_HEARTBEAT_MAX_AGE_SEC=1")
    st_run_env --root "$root2" --cwd "$proj2" status --runtime-dir "$slow_runtime"
    st_expect_contains "doesn't call a stale heartbeat resident outright" "watcher: stalled"
    st_run_env --root "$root2" --cwd "$proj2" status --json --runtime-dir "$slow_runtime"
    if [ "$(printf '%s' "$ST_OUT" | jq -r '.watcher.state' 2>/dev/null)" = "stale" ] &&
      [ "$(printf '%s' "$ST_OUT" | jq -r '.watcher.process_state' 2>/dev/null)" = "running" ]; then
      st_ok
    else
      st_fail "reports overall state and process state separately" "$ST_OUT"
    fi
    rm -f "$slow_runtime/$REIN_HEARTBEAT_BASENAME"
    st_run_env --root "$root2" --cwd "$proj2" status --json --runtime-dir "$slow_runtime"
    if [ "$(printf '%s' "$ST_OUT" | jq -r '.watcher.state' 2>/dev/null)" = "unknown" ] &&
      [ "$(printf '%s' "$ST_OUT" | jq -r '.watcher.heartbeat_age_sec' 2>/dev/null)" = "null" ]; then
      st_ok
    else
      st_fail "overall state is unknown with no heartbeat" "$ST_OUT"
    fi
    ST_VERB_ENV=("${ST_VERB_ENV[@]:0:${#ST_VERB_ENV[@]}-1}")
    # A down that doesn't come down by the cap surfaces as non-zero, including that the request is still there.
    ST_VERB_ENV+=("REIN_CMD_TIMEOUT_SEC=1")
    st_run_env --root "$root2" --cwd "$proj2" down --runtime-dir "$slow_runtime"
    if st_expect_reject "a down that doesn't come down by the cap is non-zero" 1 "the stop request is still there"; then
      st_expect_true "the request stays even after failing (the next loop brings it down)" \
        test -e "$slow_runtime/$REIN_STOP_REQUEST_BASENAME"
    fi
    ST_VERB_ENV=("${ST_VERB_ENV[@]:0:${#ST_VERB_ENV[@]}-1}")
  fi
  # Un-stops the loop -- leaving it stopped would mean a stop request left behind here never
  # gets a loop to pick it up, and cleanup ends up waiting on a watcher watching a location that's
  # already gone.
  rm -f "$hold_file"
  ST_VERB_ENV[0]="$hold_path_saved"

  # Rejecting side: --handoff only affects starting generation one, so it's rejected when passed at
  # the same time as suppressing that (silently dropping it would leave an explicitly named
  # document silently ignored).
  st_run_env --root "$root2" --cwd "$proj2" up --no-bootstrap --handoff "$tmp/handoff.md"
  st_expect_reject "rejects --no-bootstrap and --handoff given together" 2 "cannot both be given"

  # Rejecting side: --no-bootstrap never starts generation one, even with no primary session there.
  rm -f "$records2/$REIN_POINTER_BASENAME"
  : >"$verb_log"
  st_run_env --root "$root2" --cwd "$proj2" up --no-bootstrap
  if st_expect_status "--no-bootstrap's up ends with 0" 0; then
    if [ "$(rein_st_count_sub "$verb_log" "--bg")" -eq 0 ]; then
      st_ok
    else
      st_fail "--no-bootstrap doesn't start generation one" "$(cat "$verb_log")"
    fi
    st_expect_true "--no-bootstrap doesn't create a pointer" \
      test ! -e "$records2/$REIN_POINTER_BASENAME"
  fi
  # Accepting side: with no primary session there, it starts generation one (up composes starting
  # and bootstrap). The document goes next to the root side's own records (this lineage's default
  # under `--root`) -- the state after `rein init`.
  : >"$verb_log"
  printf 'handoff fixture\n' >"$records2/$REIN_HANDOFF_BASENAME"
  st_run_env --root "$root2" --cwd "$proj2" up -d
  if st_expect_status "up with no primary session starts generation one" 0; then
    st_expect_contains "says it's starting the first generation" "starting the first generation"
    st_expect_true "the current pointer lands on the root side" \
      test -f "$records2/$REIN_POINTER_BASENAME"
    if [ "$(rein_st_count_sub "$verb_log" "--bg")" -eq 1 ]; then
      st_ok
    else
      st_fail "generation one is started exactly once" "$(cat "$verb_log")"
    fi
  fi
  # At the boundary of starting, the isolation environment variables are dropped. A background
  # session's hooks inherit the environment from the shared background service, so if the lineage
  # relocated by `--root` is the first to start that service, the value sticks around for every
  # background session of every generation after it (hooks keep running against a different
  # lineage's location). Also confirms the same run's `agents` call still carries a value (to
  # rule out passing vacuously just because the environment never had it in the first place).
  if [ "$(rein_st_env_values "$verb_log.env" bg)" = "||" ] &&
    [ "$(rein_st_env_values "$verb_log.env" agents)" != "||" ]; then
    st_ok
  else
    st_fail "starting generation one drops the isolation environment variables" \
      "bg=[$(rein_st_env_values "$verb_log.env" bg)] agents=[$(rein_st_env_values "$verb_log.env" agents)]"
  fi
  # An observation on the side that placed the document (the not-yet-created side is checked in
  # the status section -- both sides are measured).
  st_run_env --root "$root2" --cwd "$proj2" status --json
  if [ "$(printf '%s' "$ST_OUT" | jq -r '.handoff.present' 2>/dev/null)" = "true" ]; then
    st_ok
  else
    st_fail "a document that was placed is reported as there" "$ST_OUT"
  fi
  # Never starts it over if a primary session is already attached (never creates a second primary session).
  : >"$verb_log"
  st_run_env --root "$root2" --cwd "$proj2" up -d
  if st_expect_status "up doesn't start it over when it's present" 0; then
    st_expect_contains "reports presence" "primary session is present"
    if [ "$(rein_st_count_sub "$verb_log" "--bg")" -eq 0 ]; then
      st_ok
    else
      st_fail "doesn't start generation one while it's present" "$(cat "$verb_log")"
    fi
    # -d skips the seat layer (returning at all is already evidence it didn't delegate, but this
    # also confirms attach was never called even once -- ruling out a run that returned but had
    # attached behind the scenes).
    if [ "$(rein_st_count_sub "$verb_log" attach)" -eq 0 ]; then
      st_ok
    else
      st_fail "-d doesn't delegate to the seat" "$(cat "$verb_log")"
    fi
  fi
  # -B doesn't start what it would sit with (the primary session), so it implies -d. Measured on
  # both counts: that it doesn't delegate, and that it doesn't start generation one either.
  : >"$verb_log"
  st_run_env --root "$root2" --cwd "$proj2" up -B
  if st_expect_status "-B's up returns (implying -d)" 0; then
    if [ "$(rein_st_count_sub "$verb_log" attach)" -eq 0 ] &&
      [ "$(rein_st_count_sub "$verb_log" "--bg")" -eq 0 ]; then
      st_ok
    else
      st_fail "-B doesn't delegate to the seat either" "$(cat "$verb_log")"
    fi
  fi
  # A retired entry point is never silently ignored -- it's rejected as an unknown argument (handed back to whoever typed it).
  st_run_env --root "$root2" --cwd "$proj2" up --attach
  st_expect_reject "up doesn't accept --attach" 2 "unknown argument to up: --attach"
  st_run_env --root "$root2" --cwd "$proj2" up -a
  st_expect_reject "up doesn't accept -a" 2 "unknown argument to up: -a"

  # The default up goes all the way to the 3rd layer (the seat) -- delegating to the attach loop.
  # Never returning is normal, so it's cut off from outside, and measured by both reaching attach
  # and releasing the operation lock.
  : >"$verb_log"
  # The notification line for a signal-terminated exit ("Alarm clock") comes from the waiting
  # shell, so this runs inside a background subshell and discards its own stderr along with it
  # (running it in the foreground would mix it into this check's own output, and the summary line
  # would no longer be the last line). The exit status comes back through a file -- if the shell
  # waiting on a child killed by a signal read it directly, that same notification line ("Alarm
  # clock") would mix into this check's output and stop the summary line from being the last one.
  (
    env "${ST_VERB_ENV[@]}" perl -e 'alarm shift; exec @ARGV' 10 \
      "$ST_BASH" "$REIN_BIN_PATH" --root "$root2" --cwd "$proj2" up \
      >/dev/null 2>&1 </dev/null
    printf '%s' "$?" >"$tmp/attach.rc"
  ) 2>/dev/null &
  wait $!
  # 142 = the mark of an external cutoff. If it had returned on its own, it never composed all the way to the seat layer.
  if [ "$(cat "$tmp/attach.rc" 2>/dev/null)" = "142" ]; then
    st_ok
  else
    st_fail "the default up never returns while attached" "exit=$(cat "$tmp/attach.rc" 2>/dev/null)"
  fi
  if [ "$(rein_st_count_sub "$verb_log" attach)" -gt 0 ]; then
    st_ok
  else
    st_fail "the default up reaches the attach loop" "$(cat "$verb_log")"
  fi
  st_expect_true "the operation lock is released even on a round that delegates to the seat" test ! -e "$runtime2/$REIN_OP_LOCK_DIRNAME"

  # An explicitly named location is also passed through to the attach loop. Without it, the seat
  # resolves its own default and reads a location different from the watcher's, reading the
  # heartbeat as missing and falsely sounding "waiting on handover" on every check. --root
  # propagates to the delegate through the environment, so this is the only path where propagation
  # can be measured -- by reading the running attach loop's own command line.
  attach_runtime="$tmp/attach-runtime"
  # Same setup as above -- **the exit status comes back through a file**. If the subshell's last
  # statement were the very target being cut off, the shell wouldn't wake the subshell at all --
  # it would exec-replace it, so the subshell itself dies from the signal, and the waiting shell
  # emits the notification line ("Alarm clock: 14"). Because it's the **waiting** shell that emits
  # it, the subshell's own `2>/dev/null` doesn't erase it, and it mixes into this check's output,
  # indistinguishable from a real anomaly. Writing the exit status to a file lets the subshell exit
  # normally on its own, so the notification line never appears -- whether it was actually killed
  # is instead seen through the 142 check below (moving what would have been visible over to this
  # check's own side).
  (
    env "${ST_VERB_ENV[@]}" perl -e 'alarm shift; exec @ARGV' 10 \
      "$ST_BASH" "$REIN_BIN_PATH" --root "$root2" --cwd "$proj2" up \
      --runtime-dir "$attach_runtime" >"$tmp/attach2.out" 2>&1 </dev/null
    printf '%s' "$?" >"$tmp/attach2.rc"
  ) 2>/dev/null &
  attach_bg=$!
  attach_found=0
  attach_wait=0
  # The watch budget is kept inside the outer cutoff (10 seconds) -- never keeps searching after it's already gone from the outer cutoff.
  while [ "$attach_wait" -lt 40 ]; do
    # Doesn't pipe into grep -q (a grep that exits early can send ps a SIGPIPE, which under
    # pipefail reads back as "matched, but false" -- causing occasional misses).
    attach_snapshot="$(rein_ps_snapshot)"
    case "$attach_snapshot" in
      *"rein-seat.sh --cwd ${proj2} --runtime-dir ${attach_runtime}"*)
        attach_found=1
        break
        ;;
    esac
    sleep 0.2
    attach_wait=$((attach_wait + 1))
  done
  wait "$attach_bg"
  # 142 = the mark of an external cutoff. If it had returned on its own, the premise that it
  # never returns while attached is broken, and the presence check above (ps's command line)
  # alone can't tell that apart from having simply caught it right after startup.
  if [ "$(cat "$tmp/attach2.rc" 2>/dev/null)" = "142" ]; then
    st_ok
  else
    st_fail "up with an explicit location also never returns while attached" \
      "exit=$(cat "$tmp/attach2.rc" 2>/dev/null)"
  fi
  if [ "$attach_found" -eq 1 ]; then
    st_ok
  else
    st_fail "up passes the explicit location through to the seat" \
      "the attach loop's command line has no --runtime-dir: $(cat "$tmp/attach2.out" 2>/dev/null)"
  fi

  # The case where a handoff file's pathname is a directory. `mv` moves a temp file **into** a
  # directory destination and returns 0, so a writer that doesn't check the destination's shape reports
  # that it placed the file while the pathname stays an empty directory -- the reader (watcher, seat) never receives it,
  # forever. The stop-request side is only ever written on a lineage where the watcher is
  # resident. Since residency is idempotent, this measures it once first rather than depending on
  # whether it's already up at this point (a fake watcher fixture can't be used here -- the real
  # one checks the stop request with `-f`, while the fixture checks with `-e`, so the fixture alone
  # would go down the instant a directory is placed there).
  rein_st_write_agents "$verb_agents" "$proj2" "sess-live"
  rein_st_write_pointer "$records2/$REIN_POINTER_BASENAME" "sess-live" "primary" "$proj2" 1
  st_run_env --root "$root2" --cwd "$proj2" up --no-bootstrap
  st_expect_status "makes the watcher resident before the shape check" 0 && st_ok
  mkdir -p "$runtime2/$REIN_STOP_REQUEST_BASENAME"
  : >"$verb_log"
  st_run_env --root "$root2" --cwd "$proj2" down --watcher-only
  if st_expect_reject "down doesn't succeed when the stop request's pathname is a directory" 1 \
    "cannot write the stop request"; then
    st_expect_not_contains "doesn't claim it stopped when it couldn't write" "watcher stopped"
    st_expect_true "doesn't write inside the stop request's pathname" \
      test -z "$(find "$runtime2/$REIN_STOP_REQUEST_BASENAME" -mindepth 1 -print)"
  fi
  rm -rf "${runtime2:?}/$REIN_STOP_REQUEST_BASENAME"

  # The seat-stop marker side. It's placed **before** stopping the primary session, so a round
  # that can't write it must never proceed to the external stop (proceeding anyway leaves a seat
  # unable to receive the going-down signal, sounding "unintended stop" as an anomaly).
  mkdir -p "$runtime2/$REIN_SEAT_STOP_BASENAME"
  : >"$verb_log"
  st_run_env --root "$root2" --cwd "$proj2" down
  if st_expect_reject "down doesn't succeed when the seat-stop marker's pathname is a directory" 1 \
    "cannot write the seat-stop marker"; then
    st_expect_not_contains "doesn't claim it stopped a primary session it never stopped" "primary session stopped"
    if [ "$(rein_st_count_sub "$verb_log" stop)" -eq 0 ]; then
      st_ok
    else
      st_fail "doesn't proceed to the external stop on a round that couldn't write the marker" "$(cat "$verb_log")"
    fi
    st_expect_true "doesn't write inside the marker's pathname" \
      test -z "$(find "$runtime2/$REIN_SEAT_STOP_BASENAME" -mindepth 1 -print)"
  fi
  rm -rf "${runtime2:?}/$REIN_SEAT_STOP_BASENAME"

  # Postponing handover (snooze). The reader is increment 3's hooks, so the form is pinned here.
  snooze_file="$runtime2/$REIN_SNOOZE_BASENAME"
  st_run_env --root "$root2" --cwd "$proj2" snooze 30m
  if st_expect_status "snooze ends with 0" 0; then
    st_expect_true "places the snooze marker" test -f "$snooze_file"
    if [ "$(jq -r '[keys[]] | join(",")' "$snooze_file" 2>/dev/null)" = "duration_sec,requested_at,schema,until" ]; then
      st_ok
    else
      st_fail "the snooze marker's key set" "$(cat "$snooze_file" 2>/dev/null)"
    fi
    if [ "$(jq -r '.schema' "$snooze_file" 2>/dev/null)" = "$REIN_SNOOZE_SCHEMA" ] &&
      [ "$(jq -r '.duration_sec' "$snooze_file" 2>/dev/null)" = "1800" ] &&
      [ "$(rein_iso_to_epoch "$(jq -r '.until' "$snooze_file")")" = \
        "$(($(rein_iso_to_epoch "$(jq -r '.requested_at' "$snooze_file")") + 1800))" ]; then
      st_ok
    else
      st_fail "the snooze marker's contents" "$(cat "$snooze_file" 2>/dev/null)"
    fi
  fi
  st_run_env --root "$root2" --cwd "$proj2" status
  st_expect_contains "status reports the snooze remainder" "snooze: "
  st_run_env --root "$root2" --cwd "$proj2" status --json
  if [ "$(printf '%s' "$ST_OUT" | jq -r '.snooze.schema' 2>/dev/null)" = "$REIN_SNOOZE_SCHEMA" ]; then
    st_ok
  else
    st_fail "status --json carries the snooze" "$ST_OUT"
  fi
  # A snooze past its deadline isn't read as active (it isn't cleared even past its deadline -- kept as history).
  jq -c --arg until "2020-01-01T00:00:00Z" '. + {until: $until}' "$snooze_file" >"$tmp/expired.json"
  mv "$tmp/expired.json" "$snooze_file"
  st_run_env --root "$root2" --cwd "$proj2" status
  st_expect_contains "an expired snooze doesn't take effect" "snooze: none"
  rm -f "$snooze_file"
  # The case where the snooze marker's pathname is a directory (same as the stop request and the seat-stop marker).
  mkdir -p "$snooze_file"
  st_run_env --root "$root2" --cwd "$proj2" snooze 30m
  if st_expect_reject "snooze doesn't succeed when the marker's pathname is a directory" 1 \
    "cannot write the snooze marker"; then
    st_expect_not_contains "doesn't claim it accepted a snooze it couldn't write" "postponing forced handover"
    st_expect_true "doesn't write inside the marker's pathname" \
      test -z "$(find "$snooze_file" -mindepth 1 -print)"
  fi
  rm -rf "${snooze_file:?}"
  # The default cap is 3600 seconds, so 2h always falls out (not used in the guidance's own example -- kept for boundary testing).
  st_run_env --root "$root2" --cwd "$proj2" snooze 2h
  st_expect_reject "rejects a snooze past the cap" 1 "exceeds the snooze cap"
  st_run_env --root "$root2" --cwd "$proj2" snooze 0
  st_expect_reject "rejects a snooze of 0" 2 "cannot read the duration"
  st_run_env --root "$root2" --cwd "$proj2" snooze 5x
  st_expect_reject "rejects a snooze whose unit can't be read" 2 "cannot read the duration"
  st_run_env --root "$root2" --cwd "$proj2" snooze
  st_expect_reject "rejects snooze with no duration" 2 "snooze requires a duration"

  st_run_env --root "$root2" --cwd "$proj2" down
  st_expect_status "cleanup for the verb cases (down)" 0 && st_ok

  # Quoting the **fully assembled command** embedded in `status`'s own guidance (the same reason
  # as doctor -- a one-liner meant to be pasted and run). A bare path containing whitespace, `;`,
  # `$( )`, or a single quote would break into separate words wherever it's pasted, and `$( )`
  # would be evaluated as command substitution. Measured both by the literal text and by the argv the shell actually splits it into.
  r16_status_proj="$tmp/r16s a b;\$(touch $tmp/r16s-pwned)'q"
  mkdir -p "$r16_status_proj"
  r16_status_proj="$(cd "$r16_status_proj" && pwd -P)"
  r16_status_records="$root2/$REIN_ROOT_RECORDS_RELDIR/$(rein_cwd_key "$r16_status_proj")"
  # **The name it calls itself must not depend on the machine it runs on.** The name comes from
  # `cli_rein_cmd`'s judgment of whether the `rein` on PATH is this same implementation -- so what
  # text is expected shifts with whether the user happens to have it installed on the surrounding
  # PATH (passing on a machine with it installed, failing on a clean one). With `rein` removed
  # from PATH here, the name resolves to the binary's absolute path, and this simultaneously puts
  # a watch on the name used **on a machine with nothing installed** (the installed side is
  # measured by doctor's own section).
  r16_status_path="${ST_VERB_ENV[0]}"
  ST_VERB_ENV[0]="PATH=${verb_bin}:$(st_path_without_rein)"
  st_run_env --root "$root2" --cwd "$r16_status_proj" status
  r16_status_out="${ST_OUT}"$'\n'
  st_expect_not_contains "doesn't embed an unquoted cwd in status's guidance" "--cwd ${r16_status_proj}"
  st_expect_contains "quotes the template's guidance" \
    "the template for this lineage can be created with $(rein_shell_quote "$REIN_BIN_PATH") --root $(rein_shell_quote "$root2") --cwd $(rein_shell_quote "$r16_status_proj") init"
  # The tail marker must not be a bare ")" -- the injected fixture path itself contains a
  # `$(touch ...)` whose own closing paren would be matched first (st_slice_between takes the
  # first occurrence), truncating the cut command right before that paren. The line this command
  # sits on always ends in ")\n" with nothing else trailing (status_handoff_line's printf format),
  # so anchoring on ")" followed by the newline lands on the message's own close, never the one
  # inside the injected command.
  st_expect_argv "the template's guidance is passed word by word" "$r16_status_out" \
    "the template for this lineage can be created with " ")"$'\n' \
    "$REIN_BIN_PATH" --root "$root2" --cwd "$r16_status_proj" init
  # The stranded-resume guidance (the case where the predecessor session is left over with no watcher) gets the same treatment.
  mkdir -p "$r16_status_records"
  rein_st_write_pointer "$r16_status_records/$REIN_POINTER_BASENAME" "succ-1" "successor" \
    "$r16_status_proj" 2 "pred-1"
  rein_st_write_agents "$verb_agents" "$r16_status_proj" "succ-1" "pred-1"
  st_run_env --root "$root2" --cwd "$r16_status_proj" status
  r16_status_out="${ST_OUT}"$'\n'
  st_expect_not_contains "doesn't embed an unquoted cwd in the stranded guidance" "--cwd ${r16_status_proj}"
  st_expect_contains "quotes the resume-on-startup guidance" \
    "$(rein_shell_quote "$REIN_BIN_PATH") --root $(rein_shell_quote "$root2") --cwd $(rein_shell_quote "$r16_status_proj") up"
  # Same reasoning as the template case above: anchor on the line-ending ")\n", not a bare ")".
  st_expect_argv "the resume-on-startup guidance is passed word by word" "$r16_status_out" \
    "Starting the watcher will resume it on startup: " ")"$'\n' \
    "$REIN_BIN_PATH" --root "$root2" --cwd "$r16_status_proj" up
  st_expect_true "status's guidance is never evaluated as command substitution" test ! -e "$tmp/r16s-pwned"
  ST_VERB_ENV[0]="$r16_status_path"
  rm -f "$r16_status_records/$REIN_POINTER_BASENAME"
  rein_st_write_agents "$verb_agents" "$proj2" "sess-live"
}
