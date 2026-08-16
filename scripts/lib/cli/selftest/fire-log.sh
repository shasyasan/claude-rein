# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034  # selftest state is shared across sections (the caller selftest()'s locals and the ST_* globals)
# The directive above applies to the **whole file** -- in this file, neither an unused local
# inside a function nor a misspelled reference gets caught. The shared variables are scattered
# across the whole file, so a line-level directive can't be scoped tightly enough.
# selftest for the fire log (what got recorded -- a different target from health state, which is
# whether it is running).
# Not an executable script, so it carries no execute bit (out of scope for the --selftest convention).

st_section_fire_log() {
  st_doctor_case_env
  fire_log4="$root4/state/rein/$REIN_FIRE_LOG_BASENAME"
  # The log's directory gets created when rein runs, and running this section alone means no rein
  # run has happened yet -- so create it up front.
  mkdir -p "${fire_log4%/*}"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_contains "says so when there is no log" "WARN there is no fire log"
  : >"$fire_log4"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_contains "says so when the log is empty" "WARN the fire log has no lines"
  # Breakdown by kind = line count per event-and-decision pair (one line that shows at a glance what is being emitted).
  {
    jq -nc --arg s "$REIN_HOOK_FIRE_SCHEMA" --arg at "$(rein_iso_now)" \
      '{schema: $s, at: $at, event: "PostToolBatch", decision: "advisory", reason: "notice:12"}'
    jq -nc --arg s "$REIN_HOOK_FIRE_SCHEMA" --arg at "$(rein_iso_now)" \
      '{schema: $s, at: $at, event: "Stop", decision: "block", reason: "handover:41"}'
  } >"$fire_log4"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_contains "prints the log's breakdown by kind" \
    "OK   fire log: 2 lines (PostToolBatch/advisory=1 Stop/block=1)"
  st_expect_contains "prints the breakdown by schema-and-event pair too" \
    "OK   fire log breakdown by schema: ${REIN_HOOK_FIRE_SCHEMA}/PostToolBatch=1 ${REIN_HOOK_FIRE_SCHEMA}/Stop=1"
  # Lines that can't be interpreted are counted and printed (silently dropping an unreadable
  # line would make the line count -- the firing record -- untrustworthy).
  printf 'not json\n' >>"$fire_log4"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_contains "counts and prints a broken line" "WARN the fire log has lines that cannot be interpreted (1/3 lines"
  st_expect_contains "still prints the breakdown for the healthy lines despite a broken one" "OK   fire log: 3 lines (PostToolBatch/advisory=1 Stop/block=1)"
  # Lines with an unknown schema are counted **separately** from lines that can't be interpreted
  # (folding them together would make it impossible to tell a writer's accident from a different
  # writer mixed in). The breakdown is by schema-and-event pair.
  jq -nc --arg at "$(rein_iso_now)" \
    '{schema: "alien.fire.v0", at: $at, event: "SessionStart", decision: "advisory"}' \
    >>"$fire_log4"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_contains "names the unknown-schema line explicitly" \
    "WARN the fire log has lines with an unknown schema (1/4 lines"
  st_expect_contains "doesn't fold an unknown schema into the unreadable-line count" \
    "WARN the fire log has lines that cannot be interpreted (1/4 lines"
  st_expect_contains "prints the unknown schema paired with its event too" "alien.fire.v0/SessionStart=1"
  st_expect_contains "the known schema's pair stays in the breakdown" "${REIN_HOOK_FIRE_SCHEMA}/Stop=1"
  st_expect_contains "doesn't mix an unknown schema into the by-kind breakdown" \
    "OK   fire log: 4 lines (PostToolBatch/advisory=1 Stop/block=1)"
  # The last line is old (hooks may have stopped firing).
  fire_at_old="$(TZ=UTC date -u -r "$(($(rein_now_epoch) - REIN_HOOK_ACTIVITY_STALE_SEC - 60))" \
    +%Y-%m-%dT%H:%M:%SZ)"
  jq -nc --arg s "$REIN_HOOK_FIRE_SCHEMA" --arg at "$fire_at_old" \
    '{schema: $s, at: $at, event: "Stop", decision: "block", reason: "handover:41"}' >"$fire_log4"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_contains "warns when the last fire is too old" "WARN the fire log's last recorded firing is too old"
  # Over the size cap and not archived (the archiving lock may still be held).
  head -c "$REIN_HOOK_FIRE_LOG_MAX_BYTES" /dev/zero | tr '\0' 'x' >>"$fire_log4"
  st_run_env --root "$root4" --cwd "$proj4" doctor
  st_expect_contains "warns when the log is over the size cap" "WARN the fire log is over the size cap and has not been archived"
  rm -f "$fire_log4"
}
