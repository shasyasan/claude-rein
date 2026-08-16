# shellcheck shell=bash
# Implementation of `rein up` (bring the lineage into an up state). By default it brings all
# three layers -- the resident watcher, the primary session, and the seat -- into an up state in
# order; each layer is idempotent (if already up, it reports one line and moves to the next).
# Not an executable script, so it doesn't get the execute bit (out of scope for the --selftest convention).

# Starts the watcher as a daemon. Discards stdout/stderr -- the watcher itself writes its start,
# rejections, per-stage failures, and exit reason to its own watcher log (.rein/watcher.log), so
# giving its output a second redirect target would split the same facts across two places.
start_watcher() {
  local settings="$1" args spawn_pid deadline remaining alive_rc heartbeat_pid
  args=(--cwd "$TARGET_CWD")
  if [ -n "$RUNTIME_DIR_OPT" ]; then
    args+=(--runtime-dir "$RUNTIME_DIR_OPT")
  fi
  if [ -n "$settings" ]; then
    args+=(--settings "$settings")
  fi
  # The signal to wait on is the heartbeat. **The watcher lock arrives too early** -- the watcher
  # takes that lock **before** the work it picks up at startup (recovering any stranded handover
  # request, resuming the last step of a handover), so returning success on the lock's appearance
  # would print "watcher started" even on a run that fails to pick that work up and exits. The
  # heartbeat only ever appears once that work has fully passed.
  # A heartbeat left over from before (a run stopped by `down`, or one killed by a signal) would
  # make the waiting side see the stale one and read it as "up" immediately. Only a run that
  # judged "the watcher isn't there" under the operation lock reaches this point, so any leftover
  # heartbeat must be debris -- remove it before starting.
  if [ -e "$HEARTBEAT_FILE" ] || [ -L "$HEARTBEAT_FILE" ]; then
    if ! rein_dest_shape_ok "$HEARTBEAT_FILE"; then
      fail "cannot remove the leftover heartbeat (can't confirm the watcher came up): ${REIN_DEST_SHAPE_ERROR}"
      return 1
    fi
    if ! rm -f "$HEARTBEAT_FILE"; then
      fail "cannot remove the leftover heartbeat (can't confirm the watcher came up): ${HEARTBEAT_FILE}"
      return 1
    fi
  fi
  nohup "$REIN_WATCHER_SCRIPT_PATH" "${args[@]}" </dev/null >/dev/null 2>&1 &
  spawn_pid=$!
  # Returning right after spawning would report "watcher started" even for a watcher that died
  # immediately from a config problem. It waits for the heartbeat to appear, and if it never
  # does, fails with a pointer to the watcher log.
  # The deadline is measured on the monotonic clock (a wall clock would let the cap stretch or
  # shrink across a mid-run clock adjustment).
  deadline=$(($(rein_now_monotonic) + CMD_TIMEOUT_SEC))
  while :; do
    if [ -f "$HEARTBEAT_FILE" ]; then
      # The heartbeat's first column is the watcher's own pid (the writer writes its own $$). If
      # it can't be read, fall back to the pid this side spawned (a display gap shouldn't turn
      # into "it isn't up").
      heartbeat_pid="$(awk 'NR == 1 { print $1; exit }' "$HEARTBEAT_FILE" 2>/dev/null)"
      case "$heartbeat_pid" in
        '' | *[!0-9]*) heartbeat_pid="$spawn_pid" ;;
      esac
      printf 'watcher started (pid=%s)\n' "$heartbeat_pid"
      return 0
    fi
    # Stops waiting only once the spawned process is confirmed dead (reading `ps` not answering
    # as "dead" would fail with "can't confirm" even on runs where the heartbeat is about to
    # appear). A run where it can't be confirmed is always cut off by the deadline below.
    rein_pid_alive "$spawn_pid"
    alive_rc=$?
    if [ "$alive_rc" -eq 1 ]; then
      break
    fi
    remaining=$((deadline - $(rein_now_monotonic)))
    if [ "$remaining" -le 0 ]; then
      break
    fi
    rein_sleep_capped "$POLL_INTERVAL_SEC" "$remaining"
  done
  fail "cannot confirm the watcher's heartbeat (watcher log: ${RECORDS_DIR}/${REIN_WATCHER_LOG_BASENAME})"
  return 1
}

# Clears a leftover stop request. The only writer is `down`, and the only consumer is a watcher
# that received the request, so a request is left behind whenever `down` timed out or the
# watcher died to a signal. Letting `up` proceed with it still there would make the watcher it
# starts consume that request on its very first loop and immediately go back down.
# `down` also needs this same cleanup on the branch where it returns "the watcher isn't there"
# (both "it isn't there" and "no request is left" have to hold before it counts as stopped).
# Called after taking the operation lock (a live watcher makes `down` wait on the same lock, so
# there's no race).
clear_stale_stop_request() {
  # Checked by "does it exist". **Checking by "is it a regular file" instead would let anything
  # that isn't a regular file end at 0 without even attempting the delete** -- so nothing would
  # notice such a thing sitting there until a later `down`'s write (which checks the
  # destination's shape) finally fails on it (a fail-loud that arrives too late). A broken
  # symlink doesn't match `-e`, so `-L` is checked too.
  [ -e "$STOP_REQUEST_FILE" ] || [ -L "$STOP_REQUEST_FILE" ] || return 0
  # Whether it can be removed is judged by the same one predicate the writer uses (the location's
  # rules aren't kept in two forms). `rm` on a symlink only removes the link and leaves its
  # target behind, so anything other than a regular file is handed back to the user -- a shape
  # nobody remembers placing isn't something a machine can decide to delete.
  if ! rein_dest_shape_ok "$STOP_REQUEST_FILE"; then
    fail "cannot remove the leftover stop request (it would go straight back down once up): ${REIN_DEST_SHAPE_ERROR}"
    return 1
  fi
  if ! rm -f "$STOP_REQUEST_FILE"; then
    fail "cannot remove the leftover stop request (it would go straight back down once up): ${STOP_REQUEST_FILE}"
    return 1
  fi
  printf 'stop request cleared: %s\n' "$STOP_REQUEST_FILE"
  return 0
}

# Clears a leftover seat-stop marker. Its only proper consumer is the seat, but if the seat
# wasn't there when `down` shut the lineage down, or `down` failed to fully stop things, nobody
# consumes it. Leaving it there and running `up` makes the next seat that attaches consume it on
# its very first attach return and silently go back down (the same cleanup discipline as the
# stop-request case). **The contract shape isn't checked here** (same as the cleanup on the seat side)
# -- the point is just to remove whatever is left behind. Called after taking the operation lock
# -- `down` holds this same lock for the whole span while it's placing the marker, so (unlike the
# seat side) this never lands in the window where "the `down` that placed it is still alive".
clear_stale_seat_stop() {
  # Checked with **the same shape** as the stop-request cleanup. `-e` alone would let a broken
  # symlink fall into the same branch as "not there" and pass with 0 without even attempting the
  # delete -- leaving it sitting there through the watcher coming up, until the next seat that
  # attaches reads it. Whether it can be removed also goes through the same one predicate the
  # writer uses (this location doesn't get its own separate spelling of the same judgment).
  [ -e "$SEAT_STOP_FILE" ] || [ -L "$SEAT_STOP_FILE" ] || return 0
  if ! rein_dest_shape_ok "$SEAT_STOP_FILE"; then
    fail "cannot remove the leftover seat-stop marker (the next seat to attach will go silently back down): ${REIN_DEST_SHAPE_ERROR}"
    return 1
  fi
  if ! rm -f "$SEAT_STOP_FILE"; then
    fail "cannot remove the leftover seat-stop marker (the next seat to attach will go silently back down): ${SEAT_STOP_FILE}"
    return 1
  fi
  printf 'seat-stop marker cleared: %s\n' "$SEAT_STOP_FILE"
  return 0
}

# Starts the first-generation primary session (via the watcher's --bootstrap, so the pointer
# doesn't gain a second writer).
run_bootstrap_now() {
  local settings="$1" handoff="$2" args
  args=(--cwd "$TARGET_CWD" --bootstrap)
  if [ -n "$RUNTIME_DIR_OPT" ]; then
    args+=(--runtime-dir "$RUNTIME_DIR_OPT")
  fi
  if [ -n "$settings" ]; then
    args+=(--settings "$settings")
  fi
  if [ -n "$handoff" ]; then
    args+=(--handoff "$handoff")
  fi
  "$REIN_WATCHER_SCRIPT_PATH" "${args[@]}"
}

cmd_up() {
  local no_bootstrap=0 detach=0 handoff="" settings="" rc
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-bootstrap | -B)
        no_bootstrap=1
        shift
        ;;
      --detach | -d)
        detach=1
        shift
        ;;
      --handoff | -H)
        rein_config_check_opt "--handoff" handoff_path $# "${2:-}" || {
          fail "$REIN_CONFIG_ERROR"
          return 2
        }
        handoff="$2"
        shift 2
        ;;
      --settings | -s)
        rein_config_check_opt "--settings" settings $# "${2:-}" || {
          fail "$REIN_CONFIG_ERROR"
          return 2
        }
        settings="$2"
        shift 2
        ;;
      *)
        take_verb_opt "$@"
        rc=$?
        case "$rc" in
          0) shift "$VERB_SHIFT" ;;
          2) return 2 ;;
          *)
            fail_usage "unknown argument to up: $1"
            return 2
            ;;
        esac
        ;;
    esac
  done

  # `--handoff` only ever flows to running bootstrap. Silently dropping it when both are given
  # would leave the explicitly named canonical document ignored without a word, and "nothing was
  # started" would be the only thing returned.
  if [ "$no_bootstrap" -eq 1 ] && [ -n "$handoff" ]; then
    fail_usage "--no-bootstrap and --handoff cannot both be given (--handoff only affects starting the first generation)"
    return 2
  fi
  # Skipping the session layer means the seat layer can't hold either (there is nothing to
  # attach to), so `-B` implies `-d`.
  if [ "$no_bootstrap" -eq 1 ]; then
    detach=1
  fi

  prepare_runtime || return 1
  require_prerequisites || return 1
  # In an environment where the organization managed settings force isolation on background
  # sessions, the session it starts branches into a separate tree. Judged through the same one
  # check the watcher and doctor use (shared library) -- if only the starting side had this,
  # `up` would succeed while only starting the successor fails. An undetermined case (unreadable,
  # broken) just **warns and continues**. The reason it isn't rejected is spelled out verbatim at
  # the top of the shared check (the enforcement itself doesn't trigger under this same user
  # account, so rejecting here wouldn't protect anything more). All this closes off is the case
  # where a fact that couldn't be read reaches no one.
  rein_managed_policy_conflicts
  rc=$?
  case "$rc" in
    1)
      fail "$REIN_MANAGED_POLICY_ERROR"
      return 1
      ;;
    2)
      warn "$REIN_MANAGED_POLICY_ERROR"
      ;;
  esac
  ensure_runtime_or_fail || return 1
  # A different lineage sitting in a parent directory isn't rejected (a lineage is scoped by
  # cwd, and nesting is a valid way to use it), but it points out where it is, to guard against
  # running two lineages without noticing.
  if find_nested_lineage "$TARGET_CWD"; then
    warn "a different lineage exists in a parent directory (a lineage is scoped by cwd): ${NESTED_LINEAGE_DIR}"
  fi
  # Start and stop each judge whether the watcher is running before acting, so without
  # serializing them, two concurrent `up` calls can both read it as absent and start the watcher
  # twice.
  acquire_op_lock || return 1
  clear_stale_stop_request || return 1
  clear_stale_seat_stop || return 1

  watcher_state "$RUNTIME_DIR"
  rc=$?
  case "$rc" in
    0) printf 'watcher is already running (pid=%s)\n' "$WATCHER_PID" ;;
    1) start_watcher "$settings" || return 1 ;;
    *)
      fail "$WATCHER_REASON"
      return 1
      ;;
  esac

  if [ "$no_bootstrap" -eq 0 ]; then
    main_session_state
    rc=$?
    case "$rc" in
      0) printf 'primary session is present: %s (%s)\n' "$MAIN_SESSION_ID" "${MAIN_SESSION_NAME:-unnamed}" ;;
      1)
        printf 'no primary session, starting the first generation (%s)\n' "$MAIN_SESSION_REASON"
        run_bootstrap_now "$settings" "$handoff" || return 1
        ;;
      *)
        fail "$MAIN_SESSION_REASON"
        return 1
        ;;
    esac
  fi

  if [ "$detach" -eq 1 ]; then
    return 0
  fi
  # Makes the seat layer idempotent too -- if the user's own terminal is already attached,
  # this just returns 0. Falling through to the attach loop's own presence rejection (non-zero)
  # here would make `up` fail on the grounds that a layer is already up, when bringing all three
  # layers up is its whole job (a standalone `rein attach`'s own rejection is unchanged).
  if find_seat_pid; then
    printf 'seat is attached (pid=%s)\n' "$SEAT_PID"
    return 0
  fi
  # exec doesn't run the EXIT trap, so release it first (leaving it held would make the next
  # operation stall on "in progress").
  release_op_lock
  rein_close_error_sink
  # Passes the explicit location through to the attach loop too (without it, the seat would
  # resolve its own default, look at a different location than the watcher's, read the heartbeat
  # as missing, and so fire falsely on every wait for a handover).
  if [ -n "$RUNTIME_DIR_OPT" ]; then
    delegate "$SCRIPTS_DIR/rein-seat.sh" --cwd "$TARGET_CWD" --runtime-dir "$RUNTIME_DIR_OPT"
    return $?
  fi
  delegate "$SCRIPTS_DIR/rein-seat.sh" --cwd "$TARGET_CWD"
  return $?
}
