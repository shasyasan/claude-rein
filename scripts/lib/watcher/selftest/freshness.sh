# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034  # selftest state is shared across sections (the caller selftest()'s locals, and the ST_* globals)
# Freshness validation's rejection rules (stale, future, a defective handoff document, bad
# format, a mismatched cwd) and a missing marker.
# All of these end without launching a successor: notify, and exit non-zero.
# Variables are shared with the caller selftest()'s locals through dynamic scope. Declaring a
# local inside a section would hide it from later sections, so this section file declares none.
# Not an executable script, so it carries no execute bit (outside the --selftest convention).

st_section_freshness() {
  case_dir="$tmp/stale"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" \
    "$(TZ=UTC date -u -r "$(($(rein_now_epoch) - 3600))" +%Y-%m-%dT%H:%M:%SZ)" "$ST_HANDOFF" "$ST_CWD"
  st_run_watcher
  st_reject_case "rejects a stale marker" "R5" "900 sec cap"

  case_dir="$tmp/future"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" \
    "$(TZ=UTC date -u -r "$(($(rein_now_epoch) + 3600))" +%Y-%m-%dT%H:%M:%SZ)" "$ST_HANDOFF" "$ST_CWD"
  st_run_watcher
  st_reject_case "rejects a marker timestamped in the future" "R4"

  case_dir="$tmp/stale-handoff"
  st_setup_case "$case_dir"
  touch -t 202001010000 "$ST_HANDOFF"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  st_run_watcher
  st_reject_case "rejects when the handoff document was left stale before the marker" "R7" "window 600 sec"

  case_dir="$tmp/missing-handoff"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_CWD/absent.md" "$ST_CWD"
  st_run_watcher
  st_reject_case "rejects when the handoff document does not exist" "R6"

  case_dir="$tmp/empty-handoff"
  st_setup_case "$case_dir"
  : >"$ST_HANDOFF"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  st_run_watcher
  st_reject_case "rejects an empty handoff document" "R6"

  # R6's "regular file" requirement. Following a symlink to judge it would swap all three checks
  # (existence, non-empty, freshness) for the state of whatever it points to (just repointing it
  # at some other, recently touched working file would let a handover through with last week's
  # handoff document still attached). Point it somewhere deliberately acceptable, so the only
  # possible reason to fail is the symlink itself.
  case_dir="$tmp/symlink-handoff"
  st_setup_case "$case_dir"
  mv "$ST_HANDOFF" "$ST_CWD/handoff-target.md"
  ln -s "$ST_CWD/handoff-target.md" "$ST_HANDOFF"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  st_run_watcher
  st_reject_case "rejects a symlinked handoff document" "R6"

  # The other shape "regular file" rules out. A directory can be both existent and non-empty, so
  # shrinking the check to existence alone would pass it (the check is folded into the same one
  # place as the writer, the template, and the first-launch check).
  case_dir="$tmp/directory-handoff"
  st_setup_case "$case_dir"
  mkdir -p "$ST_CWD/handoff-dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" \
    "$ST_CWD/handoff-dir" "$ST_CWD"
  st_run_watcher
  st_reject_case "rejects a directory as the handoff document" "R6"

  case_dir="$tmp/relative-handoff"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "handoff.md" "$ST_CWD"
  st_run_watcher
  st_reject_case "rejects a relative path as the handoff document" "R6"

  case_dir="$tmp/broken-json"
  st_setup_case "$case_dir"
  printf '{"schema":\n' >"$ST_RUNTIME/$REIN_MARKER_BASENAME"
  st_run_watcher
  st_reject_case "rejects a marker that is broken JSON" "R1"

  case_dir="$tmp/bad-schema"
  st_setup_case "$case_dir"
  jq -nc --arg h "$ST_HANDOFF" --arg at "$(rein_iso_now)" \
    '{schema: "rein.handover-request.v0", session_id: "pred-1", requested_at: $at, handoff_path: $h}' \
    >"$ST_RUNTIME/$REIN_MARKER_BASENAME"
  st_run_watcher
  st_reject_case "rejects a marker with a schema mismatch" "R2"

  case_dir="$tmp/no-session"
  st_setup_case "$case_dir"
  jq -nc --arg h "$ST_HANDOFF" --arg at "$(rein_iso_now)" \
    --arg schema "$REIN_MARKER_SCHEMA" \
    '{schema: $schema, session_id: "", requested_at: $at, handoff_path: $h}' \
    >"$ST_RUNTIME/$REIN_MARKER_BASENAME"
  st_run_watcher
  st_reject_case "rejects an empty session_id" "R3"

  # session_id is an externally sourced string that can end up expanded into the archived-file
  # name. Letting a separator through it would make it possible to write outside the runtime
  # location. There are 3 entry points (the hook's stdin, the writer command, and this R3) --
  # route them all through the same one function (never leave one of them closed and the others open).
  case_dir="$tmp/path-session"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "a/b" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  st_run_watcher
  st_reject_case "rejects a session_id containing a path separator" "R3"

  # Freshness is judged **against the on-disk value**, so it stays on the wall clock (a value
  # spanning processes cannot be compared against a monotonic clock). Under a shim that advances
  # the clock, a marker placed only moments ago reading as stale under R5 is the proof of that --
  # move this to a monotonic clock and the same marker would instead read as "future" (R4).
  case_dir="$tmp/wall-clock-freshness"
  st_setup_case "$case_dir"
  ST_BROKEN_BIN="$ST_CWD/clock-shim"
  st_write_clock_shim "$ST_BROKEN_BIN" "$ST_CWD/clock-shim.count"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "$ST_CWD"
  st_run_watcher
  unset ST_BROKEN_BIN
  st_reject_case "the marker's freshness goes stale as the wall clock advances" "R5" "900 sec cap"

  case_dir="$tmp/bad-time"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "2026/08/15 04:12" "$ST_HANDOFF" "$ST_CWD"
  st_run_watcher
  st_reject_case "rejects a timestamp outside the contracted format" "R4"

  case_dir="$tmp/other-cwd"
  st_setup_case "$case_dir"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" "$ST_HANDOFF" "/somewhere/else"
  st_run_watcher
  st_reject_case "rejects a marker whose cwd belongs to a different project" "R9"

  # R9's rejecting side has 2 independent shapes (unresolvable, or resolvable but a different
  # real path). The `/somewhere/else` case above doesn't exist, so it only exercises the
  # unresolvable side. Without also exercising a real, existing, different directory, a change
  # that drops the real-path comparison (e.g. shrinking it to "pass if it resolves at all") would
  # slip through -- since a lineage with no pointer yet also lets R10 through, a request from an
  # unrelated project could repoint the seat.
  case_dir="$tmp/resolvable-other-cwd"
  st_setup_case "$case_dir"
  mkdir -p "$tmp/another-project"
  rein_st_write_marker "$ST_RUNTIME/$REIN_MARKER_BASENAME" "pred-1" "$(rein_iso_now)" \
    "$ST_HANDOFF" "$tmp/another-project"
  st_run_watcher
  st_reject_case "rejects a marker whose cwd resolves to a different, real directory" "R9"

  # With no marker, nothing happens at all (claude is never called).
  case_dir="$tmp/no-marker"
  st_setup_case "$case_dir"
  st_run_watcher
  if st_expect_status "does nothing with no marker present" 0; then
    if [ -s "$ST_LOG" ]; then
      st_fail "never calls claude with no marker present" "claude was called: $(cat "$ST_LOG")"
    elif st_log_has '"event":"marker_'; then
      st_fail "records no handover event with no marker present" "$(cat "$ST_RECORDS/$REIN_LOG_BASENAME")"
    else
      st_ok
    fi
  fi

}
