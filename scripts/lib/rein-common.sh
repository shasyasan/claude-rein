# shellcheck shell=bash
# shellcheck disable=SC2034  # contract constants are used by the sourcing side (look unused in this file alone)
# Shared library that centralizes the handover contract's file names, timestamps, notifications, and logs in one place.
# The watcher and the attach loop (rein-seat.sh) read and write the same format, so writers must not be spread across files.
# Not an executable script, so it carries no execute permission (exempt from the --selftest convention).

REIN_MARKER_BASENAME="handover-request.json"
REIN_POINTER_BASENAME="current.json"
REIN_LOG_BASENAME="handover.log"
# The seat's own log. Only the attach loop writes it, kept separate from the handover log
# (written only by the watcher) -- with two writers on one file, once the lines interleave
# there is no way to later recover which mechanism a given line came from.
REIN_SEAT_LOG_BASENAME="seat.log"
REIN_WATCHER_LOG_BASENAME="watcher.log"
REIN_HEARTBEAT_BASENAME="watcher.heartbeat"
REIN_LOCK_DIRNAME="watcher.lock"
REIN_OWNER_BASENAME="owner"
# The lineage token: a per-lineage secret that only something able to read inside the runtime
# directory can know. The owner file says **which** lineage a runtime directory belongs to, and
# is content anyone can reproduce (it is just the cwd), so it can be named from outside; this
# says **that the namer could read the runtime directory**, which a project's own settings `env`
# cannot do (see "A clone can supply the marker env" in docs/spec/hooks.md).
REIN_TOKEN_BASENAME="token"
REIN_RECORDS_DIRNAME=".rein"
# The default name of the handoff document (its location sits next to the records --
# assembled only by rein_default_handoff_path).
REIN_HANDOFF_BASENAME="handoff.md"
# The canonical source for the handoff document's **writing rules**. **Not a single copy of it
# exists anywhere else** -- the template (laid down by `rein init`), the advisory nudging a
# handover, and the text that blocks a stop to force a handover all assemble from this one
# value. Because the template is a quoted heredoc (no variable expansion happens inside it),
# the heredoc is split in two and this value is emitted between the halves (copying the text
# verbatim would mean that the day a rule gets added, only the stale copy survives, and the
# recipient can't tell which one to follow).
# **All three destinations carry it because each reaches a different audience.** The template
# only takes effect on fresh creation, and the advisory is mutually exclusive with the
# handover threshold via if/elif, so a session that jumps straight past the lower threshold to
# the trigger threshold never sees it even once. Reaching **the session that is editing an
# already-existing canonical document** (exactly the audience this mechanism targets) reliably
# requires all three: the advisory, the handover trigger, and the stop-blocking text.
# The location's concrete name is not spelled out here -- the mechanism that holds the
# canonical location depends on the consuming environment, so baking in a concrete name would
# split the help given between environments that have the mechanism and those that don't. It
# stops at "to whatever your environment designates as canonical."
# This is passed **as a `%s` argument** into a path that assembles raw JSON with printf, so it
# must not contain `"`, `\`, or a newline (the argument is not reinterpreted as a format string,
# so `%` is fine). The self-check enforces the character constraint mechanically.
REIN_HANDOFF_WRITING_RULES="How to write the handoff document (keep these 5 rules): (1) Under Where things stand, write where the working memory for each piece of work in progress lives (all of them if several run in parallel; the details live there, not here). (2) Where things stand gets overwritten, not appended to (don't record finished history, settled decisions, analysis conclusions, or a work log). (3) For each thing you're about to write, first decide where its canonical source lives. If a destination for it already exists, just point to it -- don't also summarize it here. (4) Don't add or remove sections (a handover request rejects either kind of deviation from the section structure). (5) Under Standing decisions, keep only time-limited ones; move permanent decisions to whatever your environment designates as canonical."
# The layout under a lineage relocated with `--root` (relative to the root). The side that
# assembles it (bin/rein's --root) and the side that works it back out (the managed-marker
# consistency check) look at **the same constant** -- if only one changes, hooks on a
# root-relocated lineage all fail with "the records location doesn't match the lineage."
REIN_ROOT_STATE_RELDIR="state/rein"
REIN_ROOT_RECORDS_RELDIR="records/rein"
# The **user config's location** within the same layout (`--root` relocates this too). The
# project config's allow/deny decision ledger sits next to this file, so the line that
# points the user at a decision names this location -- not the runtime directory, not the
# records location. The side that assembles it (bin/rein's --root) and the side that works it
# back out (rein_config_lineage_opts) look at the same constant.
REIN_ROOT_CONFIG_RELPATH="config/rein/config"
REIN_PROCESSING_DIRNAME="processing"
REIN_PROCESSED_DIRNAME="processed"
REIN_REJECTED_DIRNAME="rejected"
# Where a handover request goes when the user speaks up and cancels it. **Kept separate from
# rejected** -- a rejection is a user-input defect caught by freshness validation (fixable),
# while this is the user deliberately stopping it (nothing to fix). Mixing them would make it
# impossible to recover, on audit, which reason made the request disappear.
REIN_CANCELLED_DIRNAME="cancelled"
REIN_SNOOZE_BASENAME="snooze"
REIN_STOP_REQUEST_BASENAME="watcher.stop"
# The marker that tells the seat a lineage has been folded up. `rein down` places it **before**
# externally stopping the primary session, and the attach loop, once attach returns, exits quietly
# with 0 if this is present (only the seat removes it). Without the marker, the seat can't tell
# an attach return after `down` stopped the primary session apart from the anomaly "the session
# ended but the pointer was never updated," so every intentional stop would trigger a
# notification.
REIN_SEAT_STOP_BASENAME="seat.stop"
# Two markers read at the same wait, both consumed only by the watcher before it launches a
# successor: one that the session that requested the handover places once it has finished
# responding (written by the hooks wired to Stop), and one that cancels the handover because
# the user spoke up (written by the hooks wired to UserPromptSubmit). **Their content is a
# single line of plain text, the session_id -- not JSON** -- because the only reader is the
# watcher and all it needs is the session_id, and because adding an external command for atomic
# replacement (mktemp plus mv) to the hooks' silent-pass path is not worth it. A half-written
# line reads as "no match," and the next cycle reads the complete line once it lands (this
# fails toward safety).
REIN_HANDOVER_READY_BASENAME="handover-ready"
REIN_HANDOVER_CANCEL_BASENAME="handover-cancel"
REIN_OP_LOCK_DIRNAME="op.lock"
# Mutual exclusion for a handover (the sequence that launches a successor and re-points the
# pointer). **Two entry points -- the resident watcher's cycle and bootstrap -- can run for the
# same lineage at the same time**, so neither the watcher lock (held for the resident's whole
# lifetime) nor the operation lock (held for the whole of `rein up`) can stand in for it --
# using either would guarantee a collision between the watcher `up` launches and `up`'s own
# bootstrap. This is held as a third lock scoping just the handover window.
# Without this exclusion, a `rein up` run while an unconsumed handover-request marker remains
# can launch **two successors for the same generation** (one never lands on the pointer and,
# stopped by no one, keeps editing the same working tree).
REIN_HANDOVER_LOCK_DIRNAME="handover.lock"
# The resident watcher's binary (the exact path `rein up` passes when launching it). The side
# that launches it and the side that cross-checks a PID-reuse candidate against it look at the
# same single value (assembling them separately would let "it's resident" be read as "it's not
# there").
# Its own location is derived from pure string operations (this shared library is read by a
# hook on every tool invocation, so spawning dirname / pwd would become a fixed cost every
# single time).
# Being sourced via a relative path is rejected **on the spot** (fail-loud). Filling it in with
# the current directory would produce a value that disagrees with the launching side's argv,
# letting "it's resident" be read as "it's not there" -- keeping the load path
# absolute is the caller's responsibility, so this surfaces the problem here instead of
# silently patching around it.
REIN_WATCHER_SCRIPT_PATH="${BASH_SOURCE[0]}"
case "$REIN_WATCHER_SCRIPT_PATH" in
  /*) ;;
  *)
    printf 'rein: shared library was sourced via a relative path (cannot resolve the watcher binary to an absolute path): %s\n' \
      "$REIN_WATCHER_SCRIPT_PATH" >&2
    exit 1
    ;;
esac
REIN_WATCHER_SCRIPT_PATH="${REIN_WATCHER_SCRIPT_PATH%/*}"
# This checkout's root (where the contract files and implementation files live). Not
# reassembled per reader.
REIN_REPO_ROOT="${REIN_WATCHER_SCRIPT_PATH%/*}"
REIN_REPO_ROOT="${REIN_REPO_ROOT%/*}"
REIN_WATCHER_SCRIPT_PATH="${REIN_WATCHER_SCRIPT_PATH%/*}/rein-watcher.sh"
# The attach loop's (seat's) presence lock. A lineage has one seat -- a second one is refused
# because the first shows presence. This isn't decided by matching against `ps` output, because
# that can't close the window between checking and launching where the counterpart disappears,
# or the two launch at the same moment (TOCTOU) -- only an atomic creation can stake the claim.
REIN_SEAT_LOCK_DIRNAME="seat.lock"
# The "owner role" carried in a lock's declaration. This is the vocabulary a reader uses to
# decide "is this the resident watcher?" **by declaration, not by re-parsing the `ps` command
# line** -- the value is held in one place (if the writer and reader used different spellings,
# the comparison would silently always mismatch).
REIN_LOCK_MODE_WATCH="watch"
REIN_LOCK_MODE_OP="op"
REIN_LOCK_MODE_HANDOVER="handover"
REIN_LOCK_MODE_SEAT="seat"
REIN_LOCK_MODE_FIRE_LOG="fire-log"
# Where the plugin hooks' runtime data lives (cooldown fire markers, the pending-verify record
# for reachability confirmation, the stop latch). Nested one level under the runtime directory rather than sitting
# directly in it, so the items that accumulate per session can be counted as one
# entry during cleanup (the known-name list `rein prune` removes individually).
REIN_HOOK_STATE_DIRNAME="hooks"
# The ledger of running children (subagents), one file per child at
# `<runtime>/children/<session_id>.<agent_id>`. Written by the hooks wired to SubagentStart /
# SubagentStop, read by `rein request` (which refuses a handover while this session still has a
# live child -- replacing the parent takes the children down with it).
# **Entries are partitioned by the parent's session_id.** Leftovers are unavoidable (a parent
# stopped externally never delivers SubagentStop), but a successor only ever looks at its own
# session_id's entries, so a leftover from an earlier generation can never block the next
# generation's handover.
REIN_CHILDREN_DIRNAME="children"
# The lineage log the hooks write. Since only the watcher writes the handover log
# (handover.log) and the watcher log (watcher.log), the hooks write to their own file
# instead (never give the same target a second writer).
REIN_HOOK_LOG_BASENAME="hooks.log"
# Where the state lives that lets something outside tell whether rein's own hooks are alive
# (under the runtime directory's hooks/). This targets something different from the fire log
# (what it emitted) -- the anomaly of "it didn't emit anything" (registration isn't taking
# effect, the launcher can't resolve the real file, the injection never arrived) can't be
# judged from the fire log's line count, so this gets its own location. One file, one fact
# (reads and writes crossing paths don't get mixed up).
REIN_HOOK_HEALTH_DIRNAME="health"
# The hook calling-convention version. Of the three stages -- the registry, the launcher inside
# the plugin, and the runner -- the launcher sits in the plugin's cache and can lag behind an
# update (the runner is the symlink target, so it's always current). The version travels as an
# argument, and a mismatch makes the runner fail loud -- the argument's meaning never silently
# drifts.
REIN_HOOK_PROTOCOL="1"
# The managed marker (an env present only in sessions rein launched). A way to confirm lineage
# in O(1) without re-deriving it from cwd, held in one place so readers don't each spell out
# the name themselves.
REIN_MANAGED_ENV_NAME="REIN_MANAGED"
REIN_MANAGED_CWD_ENV_NAME="REIN_MANAGED_CWD"
REIN_MANAGED_RUNTIME_ENV_NAME="REIN_MANAGED_RUNTIME_DIR"
REIN_MANAGED_SETTINGS_ENV_NAME="REIN_MANAGED_SETTINGS_FILE"
# The parts of lineage context that **can't be uniquely derived from cwd** (the config and
# records of a lineage relocated with `--root`) also travel via the managed marker. Re-deriving
# them from the process's inherited environment (REIN_CONFIG_FILE / REIN_RECORDS_ROOT) does not
# work -- a background session's hook process inherits its environment from the shared
# background service, so the launching side's environment variables never reach that session's
# hooks (observed). Re-deriving them anyway would make a root-relocated lineage's hooks write
# to the default location (`<cwd>/.rein/`), mixing the records of the two lineages.
REIN_MANAGED_CONFIG_ENV_NAME="REIN_MANAGED_CONFIG_FILE"
REIN_MANAGED_RECORDS_ENV_NAME="REIN_MANAGED_RECORDS_DIR"
# The lineage token (REIN_TOKEN_BASENAME) travels with the marker too. Every other field of the
# marker is a value that can be **reproduced from outside** -- a cwd, a location, a fixed `1` --
# so a marker built entirely out of them proves only that someone knew the shape. This field is
# the one that cannot be reproduced without reading inside the runtime directory, which is what
# separates "a session rein launched" from "a settings file that names the same lineage."
REIN_MANAGED_TOKEN_ENV_NAME="REIN_MANAGED_TOKEN"
# **All** the managed-marker env names. Held as a list, separate from the individual
# readers above, so that the side that must "drop every managed marker without exception" (the
# selftest isolation, rein_st_isolation_env) doesn't have to spell the names out itself.
# Spelling them out invites a miss whenever a new one is added, and **a selftest started from a
# session rein launched then runs while holding real state and real config** (observed: with a
# miss like that in place, running rein-hook.sh --selftest fails 14 cases, writing the fire log
# and the hooks/ pending-verify records to the runtime directory the managed marker named). Adding a name here
# means the dropping side follows automatically.
# shellcheck disable=SC2034  # read by lib/rein-selftest-fixtures.sh (sourced from there)
REIN_MANAGED_MARKER_ENVS=(
  "$REIN_MANAGED_ENV_NAME"
  "$REIN_MANAGED_CWD_ENV_NAME"
  "$REIN_MANAGED_RUNTIME_ENV_NAME"
  "$REIN_MANAGED_SETTINGS_ENV_NAME"
  "$REIN_MANAGED_CONFIG_ENV_NAME"
  "$REIN_MANAGED_RECORDS_ENV_NAME"
  "$REIN_MANAGED_TOKEN_ENV_NAME"
)
# The "locations a child must never touch" (newline-separated) passed to selftest child
# processes. **A way to kill a child on the spot when isolation slipped, not to count the
# slip after the fact** -- counting would require a fingerprint per write path, and none of an
# unchanging overwrite (health's last-seen), a location outside the state tree (the records'
# hooks.log), or a generation-tagged marker (the stop latch) can be counted that way (observed:
# these three were exactly what counting missed). Handing over the roots lets the child close
# the gap in the one place it resolves its own location, regardless of how many write paths
# exist.
# Written by lib/rein-selftest-fixtures.sh's rein_st_isolation_env (the sole place that
# assembles the isolation env), read by rein_selftest_never_root_hit. Held here once so the
# name isn't duplicated on both sides.
REIN_SELFTEST_NEVER_ROOTS_ENV_NAME="REIN_SELFTEST_NEVER_ROOTS"
# The prefix for the temporary settings rein creates to launch a session (lives under the
# runtime directory; used to match it up during cleanup).
REIN_MANAGED_SETTINGS_PREFIX="managed-settings."

# All the locks placed under the runtime directory. Only these four ever have the claim/release
# temp-name suffixes (below) hanging off them, so they are grouped apart from the full list of
# public names -- cleanup code doesn't have to spell out "which of these are locks" itself.
REIN_RUNTIME_LOCK_DIRNAMES=(
  "$REIN_LOCK_DIRNAME"
  "$REIN_OP_LOCK_DIRNAME"
  "$REIN_SEAT_LOCK_DIRNAME"
  "$REIN_HANDOVER_LOCK_DIRNAME"
)
# The temp-name suffixes lock claim/release use (a fixed shape hanging off a public name). They
# can be left behind on a crash, but they are still rein's own runtime data -- cleanup must
# not treat them as "unknown."
REIN_LOCK_TEMP_SUFFIXES=(".claim.*" ".release.*")
# The infix for the temp name atomic writes (rein_write_json_atomic) use. Fixing the name to
# the **set shape** `<dest>.rein-tmp.<nonce>` lets cleanup recognize it mechanically -- with a
# plain `mktemp "${dest}.XXXXXX"`, a leftover temp file's name can't distinguish "rein made
# this" from "something else's file that wandered into the location," so it can't be added to
# the known-runtime-artifact list either (adding it would mean deleting any
# `<known-name>.<6 chars>`). To keep the writer and the cleanup enumeration from holding the
# same literal in two places, the infix lives here alone.
REIN_ATOMIC_TEMP_INFIX=".rein-tmp."
# **The known runtime-artifact names** that can appear under the runtime directory. This one
# list is the canonical enumeration, and cleanup (what `rein prune` folds away) just iterates
# it -- if cleanup kept its own list instead, adding a new name would leave that list behind,
# and that lineage's final rmdir would fail forever with "something unknown is left" (since
# this sits right before an irreversible delete, a leftover fails toward "can't be folded
# away" rather than silently vanishing -- noticeable, but only the person who added the
# enumeration entry can fix it).
# Entries can contain globs (launch settings are counted by prefix), so the expanding side
# iterates as `"$dir/"$name` -- quoting only the location, leaving the name unquoted.
# Selftest cross-checks both directions against the literal spec (the runtime-artifact list in
# docs/spec/runtime.md) so the prose listing doesn't silently become a third, unsynced writer.
REIN_RUNTIME_ARTIFACT_NAMES=(
  "$REIN_OWNER_BASENAME"
  "$REIN_TOKEN_BASENAME"
  "$REIN_HEARTBEAT_BASENAME"
  "$REIN_MARKER_BASENAME"
  "$REIN_SNOOZE_BASENAME"
  "$REIN_STOP_REQUEST_BASENAME"
  "$REIN_SEAT_STOP_BASENAME"
  "$REIN_HANDOVER_READY_BASENAME"
  "$REIN_HANDOVER_CANCEL_BASENAME"
  "${REIN_RUNTIME_LOCK_DIRNAMES[@]}"
  "$REIN_PROCESSING_DIRNAME"
  "$REIN_PROCESSED_DIRNAME"
  "$REIN_REJECTED_DIRNAME"
  "$REIN_CANCELLED_DIRNAME"
  "$REIN_HOOK_STATE_DIRNAME"
  "$REIN_CHILDREN_DIRNAME"
  # Launch settings (`managed-settings.<nonce>.json`) are a temp artifact the hooks that read
  # them delete, but they are left behind if the session crashes -- without an entry here, an
  # orphan's rmdir would always fail.
  "${REIN_MANAGED_SETTINGS_PREFIX}*"
  # Atomic-write temp names (`<dest>.rein-tmp.<nonce>`). Left behind in the location on a crash
  # between mktemp and mv, or a crash during mv itself. Lock temp names
  # (REIN_LOCK_TEMP_SUFFIXES) aren't listed here since they can be mechanically derived from the
  # four public lock names, but this one **can appear next to any destination** (a handover
  # request, a stop marker, a snooze), so it's listed as one glob with a wildcard destination.
  "*${REIN_ATOMIC_TEMP_INFIX}*"
)
# The name of the project config's (`<cwd>/.rein/config`) ledger. Its location sits
# **next to the user config** (resolved by the config layer's rein_config_allow_file) -- never
# inside the project, never inside the repository (placing it somewhere a clone would carry
# would mean shipping the allow record itself along with the clone).
REIN_PROJECT_ALLOW_BASENAME="allowed-project-configs"
# The log that accumulates only hook firings (branches that actually emitted an injection or
# blocked a stop). It lives on rein's state side (the runtime directory's parent), a single
# file shared across every lineage -- its line count is the firing record itself.
# It does not write to the consuming side's log (`~/.claude/state/`): that one restricts
# writes by the invoking path, and rein's binary sits outside it -- trying to write there
# produces only a warning, with nothing recorded.
REIN_FIRE_LOG_BASENAME="hook-fire-log.jsonl"
# The log's size cap (past this, one generation gets rotated out). A cap to keep it from
# growing without bound, matched to the watcher log's cap (the default for config's
# watcher_log_max_bytes).
REIN_HOOK_FIRE_LOG_MAX_BYTES=1048576
# The age past which hook activity (the log's last line, health state's last firing) is
# treated as "stale." `rein doctor` reports records past this age as WARN. A day is chosen
# because a rein lineage assumes a primary session is present at all times, yet people normally
# step away overnight or on weekends -- a threshold measured in hours would keep firing on
# perfectly normal downtime.
# Going a full day with not a single firing means either "registration came loose" or "this
# lineage isn't in use anymore" -- either way, that's for the user to look at and decide, so
# it's WARN rather than a hard failure.
# This is not exposed as a setting because it isn't an operational parameter the user tunes;
# it's a diagnostic rule of thumb (treated the same as the hooks' internal heuristics -- outside
# the config layer's scope).
REIN_HOOK_ACTIVITY_STALE_SEC=86400
# The contract files that let this be loaded as a plugin (relative to the repository root).
# Held in one place so readers don't each spell out the same path (the canonical source for
# version, plugin name, and marketplace name is these three).
REIN_PLUGIN_MANIFEST_RELPATH=".claude-plugin/plugin.json"
REIN_MARKETPLACE_MANIFEST_RELPATH=".claude-plugin/marketplace.json"
REIN_HOOKS_JSON_RELPATH="hooks/hooks.json"
# The hook execution path (the tiny launcher the registry calls, and the dedicated hook runner
# the launcher spawns as a child). **The side that reads this shared library** (`rein doctor`,
# the various selftests) holds this one path in one place so they don't each write it
# separately. Three parties that cannot read the library carry the same literal on their own --
# this is not the single repository-wide source for them: the registry (JSON, so it can't
# reference a variable), the tiny launcher (sourcing it would defeat the point of being "tiny,
# written to change essentially never"), and the standalone gate (scripts/check.sh sources
# nothing). Two of the possible mismatches are pinned mechanically: that the launcher the
# registry calls actually exists and is executable (doctor's execution-path check), and the
# calling-convention version between launcher and runner (the launcher's --selftest reads this
# library's value and cross-checks it).
REIN_HOOK_LAUNCHER_RELPATH="hooks/rein-hook-launcher.sh"
REIN_HOOK_RUNNER_RELPATH="scripts/rein-hook.sh"
# The bundled usage statusline writer (what gets registered as statusLine in the consuming
# side's settings). The installation instructions and diagnostics look at the same one path, so
# where the user was told to point and where the check looks never diverge.
REIN_STATUSLINE_RELPATH="scripts/rein-statusline.sh"
# The CLI binary the user invokes. **The name embedded in a one-line instruction** is used by
# every layer so the instruction still runs on a machine without rein on PATH (the CLI itself
# uses `cli_rein_cmd`, which switches to the short name when "the rein on PATH is this same
# implementation," but the other layers that read the shared library -- hook, watcher, seat,
# request -- have no way to probe PATH's state, so they always give the instruction as the
# binary's real path).
REIN_CLI_RELPATH="bin/rein"
REIN_MARKER_SCHEMA="rein.handover-request.v1"
REIN_POINTER_SCHEMA="rein.current.v1"
REIN_LOG_SCHEMA="rein.handover-log.v1"
REIN_SEAT_LOG_SCHEMA="rein.seat-log.v1"
REIN_SNOOZE_SCHEMA="rein.snooze.v1"
REIN_STOP_REQUEST_SCHEMA="rein.watcher-stop.v1"
REIN_SEAT_STOP_SCHEMA="rein.seat-stop.v1"
REIN_HOOK_LOG_SCHEMA="rein.hook-log.v1"
REIN_HOOK_FIRE_SCHEMA="rein.hook-fire.v1"

# The seat log's event name for "the attach loop is entering attach on this session." The writer
# (the attach loop) and the reader (`rein status`, deciding whether what the seat is connected to
# still matches the current pointer) hold the spelling **in one place** -- with a literal on each
# side, a rename on the writer would leave the reader silently matching nothing, and status would
# go back to reporting presence with no idea what it is connected to.
REIN_SEAT_EVENT_ATTACH_STARTED="attach_started"
# The seat log's event name for "attach has returned, so the seat is not connected to anything
# right now." **Without this, `attach_started` alone can only answer "where did the seat last go,"
# never "is it connected at this moment"** -- and the two differ for an unbounded stretch on every
# ordinary handover: from the moment attach returns until the successor is resolved and the next
# attach begins, and for as long as the lineage sits waiting for a handover that has not been
# requested yet (no time limit at all). A reader with only the start event reports that whole
# stretch as a live connection matching the pointer, which is the same shape as the accident this
# whole observation point exists to surface (a seat reported as fine while nobody was connected).
# **A pair, read as "whichever of the two came last."**
REIN_SEAT_EVENT_ATTACH_ENDED="attach_ended"
# The seat log's event name for "a seat has sat down here." Written once, right after the seat
# lock is claimed and before the first attach. It is what stops **the previous seat's**
# `attach_started` from being read as the current seat's connection: the log outlives the process
# that wrote it, so a fresh seat that has not entered attach yet would otherwise inherit whatever
# the last seat was connected to, hours or days ago.
REIN_SEAT_EVENT_SEATED="seated"
# The seat log's event name for "the pointer moved on, but attach still has not returned." The
# watchdog is the writer; an audit after the fact is the reader.
REIN_SEAT_EVENT_HANDOVER_STALLED="handover_stalled"
# The one sentence that says how to get out of that state. The mechanism is contractually
# forbidden from touching the terminal or the attach connection (no active detach), so **the only
# thing that returns attach is the user leaving the screen they are looking at** -- which makes
# this the single actionable instruction, and the reason it is held in one place: both surfaces
# that report the mismatch (the watchdog's notification and `rein status`'s seat line) have to say
# the same thing, or one of them sends the user somewhere else. No keystroke is named, because
# which key leaves that screen belongs to the external CLI and is not something this side can
# confirm.
REIN_SEAT_DETACH_HINT="leave the agent list screen and the seat reconnects to the successor on its own"

# The floor and the ceiling (seconds) on how far apart the stall notification repeats.
# **The firing threshold is not a spacing.** The threshold's job is to avoid a false alarm, so it
# has to cover the worst case a legitimate handover can take; the spacing's job is to remind
# someone of a state that has *already* been confirmed, and once the first notification has fired
# the false-alarm hypothesis is settled -- the two jobs simply do not want the same number.
# Reusing the threshold as the spacing put the whole pacing at the mercy of one config value and
# broke in both directions: with `cmd_timeout_sec` at 600 the threshold is 6081 seconds (measured),
# so a repeat "every 101 minutes" is back to a single shot for any realistic sitting; with the
# minimal settings a selftest uses it is 16 seconds, which is a notification every quarter minute
# for as long as the user stays where they are. Clamping keeps the derivation (a lineage with
# wider caps still gets wider spacing) while bounding it to a range a person can live with.
REIN_SEAT_NOTIFY_REPEAT_MIN_SEC=300
REIN_SEAT_NOTIFY_REPEAT_MAX_SEC=900

# The cap (seconds) on a single external command. Since a stage's own timeout only takes
# effect between loop iterations, a call that never returns at all (a stuck CLI) becomes a
# permanent stall under unattended operation.
# An execution path that goes through the config layer overwrites this with config's effective
# value at startup. What's left here as a default covers the case read before the config layer
# (a failure before config itself has been read), and its value is kept matched to config's
# default (a mismatch would create "two different caps in effect even though nothing was
# configured," which selftest cross-checks mechanically).
REIN_CMD_TIMEOUT_SEC="${REIN_CMD_TIMEOUT_SEC:-60}"
# An execution path that goes through the config layer loads its folded effective value into
# this variable (defaulting to the shared library's value above). This is not stored under the
# REIN_ prefix because if the caller exported REIN_CMD_TIMEOUT_SEC, `printf -v` would preserve
# the export attribute and the effective value would carry straight into a successor session's
# environment (the environment layer beats the file layer, so the successor's config would
# lose -- the effective value must not get baked into a child's environment).
CMD_TIMEOUT_SEC="$REIN_CMD_TIMEOUT_SEC"
REIN_RUNTIME_ERROR=""
REIN_RUNTIME_OWNER_PRESENT=0
# A cap being exceeded is observed as the exit code for being killed by SIGALRM (14).
REIN_TIMEOUT_RC=142
# The retry count and the wait between retries when measuring a session's liveness via
# enumeration (`claude agents --json`). If a single failure made both the watcher and the seat
# step down, the guarantee behind unattended operation would break on a
# transient glitch. This is not exposed as a setting because it isn't an operational parameter
# the user tunes; it's internal slack against an external command's jitter (treated the same as
# the diagnostic rule of thumb REIN_HOOK_ACTIVITY_STALE_SEC). Capping it at 3 tries / 1 second
# keeps a persistent failure from surfacing (fail-loud) too slowly -- since enumeration itself
# is time-capped, this settles within 3x `cmd_timeout_sec` at worst.
REIN_AGENTS_PROBE_ATTEMPTS=3
REIN_AGENTS_PROBE_RETRY_SEC=1
# The number of stages involving enumeration that run **serially** in the stage that retires
# the predecessor session (rein-watcher.sh's retire_predecessor): the exit confirmation inside
# the grace period (wait_for_exit), resolving the short job ID (rein_resolve_job_handle), and
# the exit confirmation after an external stop (wait_for_exit) -- three in all.
# The side that assembles the wait cap (the seat's watchdog) must budget one enumeration's
# worst case times this count, so the count lives here instead of being baked into the seat's
# formula (if retire_predecessor grows a stage, this and rein-seat.sh's selftest fail together).
REIN_RETIRE_LIST_AGENTS_CALLS=3

REIN_ERR_FILE=""
REIN_MISSING_TOOLS=""
# The list of tools rein_check_prerequisites **looked at** (all of them, regardless of whether
# any were missing). The diagnostic's OK line is assembled from this -- OK and FAIL never claim
# to be drawing from separate sets.
REIN_PREREQUISITE_TOOLS=""
REIN_INVALID_VALUE=""
REIN_POINTER_ERROR=""
REIN_POINTER_GENERATION=""
REIN_POINTER_SESSION_ID=""
# A place to receive a value without spawning $( ) (one implementation, two ways to receive it).
REIN_NONCE=""
REIN_RECORDS_PATH=""
REIN_ISO_EPOCH=""

# The key that maps a target cwd onto one state directory. The basename is prefixed so a human
# can trace it, and a digest of the full path is appended to avoid mixing up same-named
# projects.
rein_cwd_key() {
  local target_cwd="$1" digest
  digest="$(printf '%s' "$target_cwd" | shasum -a 256 2>/dev/null | cut -c1-12)"
  if [ -z "$digest" ]; then
    return 1
  fi
  printf '%s-%s\n' "$(basename "$target_cwd")" "$digest"
}

# Whether a runtime directory's name has the key shape (`<cwd's basename>-<12 characters>`).
# A structural check so that cross-lineage cleanup (`rein prune`) doesn't sweep anything besides
# "a per-lineage directory rein created" -- it looks only at the name's shape (a separate layer
# from screening the contents).
rein_runtime_key_shaped() {
  local name="$1"
  case "$name" in
    *-[0-9A-Za-z][0-9A-Za-z][0-9A-Za-z][0-9A-Za-z][0-9A-Za-z][0-9A-Za-z][0-9A-Za-z][0-9A-Za-z][0-9A-Za-z][0-9A-Za-z][0-9A-Za-z][0-9A-Za-z]) ;;
    *) return 1 ;;
  esac
  # A key always has a basename prefixed (a name that's just `-<12 characters>` is not a key).
  [ -n "${name%-*}" ] || return 1
  return 0
}

# Assembles the base of the default (XDG) location. **Failing "can't resolve" when neither XDG
# nor HOME is set** is this function's job -- the code that used to write
# `${XDG_...:-${HOME:-}/<relative>}` inline only ever checked whether the result started with
# `/`. When HOME is empty or unset, the base collapses to `/<relative>`, which starts with `/`
# and so sails right through the absolute-path check (this actually happens under launchd, over
# an ssh session with a stripped environment, and in a hook process that inherits its
# environment). Where it sails through to is an unwritable path directly under the filesystem
# root, so instead of failing with "can't resolve the location" as fail-loud intends, it fails
# with the **distant cause** "the location was resolved but mkdir failed," and the fact that
# HOME was missing never surfaces at all. This applies the same discipline already used to
# reject a relative XDG value to this shape too.
# **Assembling the base is consolidated into this one function** because the same literal used
# to be scattered per location (two places on the state side, one on the config side -- the
# same discipline splitting apart within a single library).
# $1=the XDG env var's value $2=that variable's name (carried in the error) $3=relative path
# from HOME $4=the name for this location (carried in the error)
# 0=the base was placed in REIN_XDG_BASE / 1=couldn't assemble it (reason in REIN_XDG_BASE_ERROR)
REIN_XDG_BASE=""
REIN_XDG_BASE_ERROR=""
rein_xdg_base() {
  local xdg="$1" xdg_name="$2" home_rel="$3" label="$4"
  REIN_XDG_BASE=""
  REIN_XDG_BASE_ERROR=""
  if [ -n "$xdg" ]; then
    case "$xdg" in
      /*)
        REIN_XDG_BASE="$xdg"
        return 0
        ;;
    esac
    printf -v REIN_XDG_BASE_ERROR 'the default location for %s is not an absolute path: %s (%s holds a relative path)' \
      "$label" "$xdg" "$xdg_name"
    return 1
  fi
  if [ -z "${HOME:-}" ]; then
    printf -v REIN_XDG_BASE_ERROR 'cannot assemble the default location for %s (neither HOME nor %s is set)' \
      "$label" "$xdg_name"
    return 1
  fi
  case "$HOME" in
    /*) ;;
    *)
      printf -v REIN_XDG_BASE_ERROR 'cannot assemble the default location for %s (HOME is not an absolute path: %s)' \
        "$label" "$HOME"
      return 1
      ;;
  esac
  printf -v REIN_XDG_BASE '%s/%s' "$HOME" "$home_rel"
  return 0
}

# Resolves the location for runtime data (markers, locks, heartbeat,
# processing/processed/rejected). Explicit override (the config layer's folded effective value)
# beats the user's state area (XDG).
# This does not go under the target project because runtime data belongs to "whatever process
# is running on this machine right now," a different lifetime than the lineage's records
# (.rein/). It does not go under ${TMPDIR} either, because there is no guarantee that a marker's
# writer (inside a session) and the watcher (under a terminal or nohup) resolve to the same
# place, and a mismatch would stall a handover silently.
rein_resolve_runtime_dir() {
  local target_cwd="$1" explicit="${2:-}" base key
  if [ -n "$explicit" ]; then
    printf '%s\n' "$explicit"
    return 0
  fi
  # The reason is also written to stderr. Every caller of this resolver is inside `$( )`, so
  # returning it via a variable never reaches the caller -- all the caller can say is "can't
  # resolve it (pass it explicitly)," and **which piece is missing** never gets named (the same
  # reason the records-location resolver goes all the way to printf too).
  if ! rein_xdg_base "${XDG_STATE_HOME:-}" XDG_STATE_HOME .local/state "runtime data"; then
    printf 'rein: %s\n' "$REIN_XDG_BASE_ERROR" >&2
    return 1
  fi
  base="$REIN_XDG_BASE"
  key="$(rein_cwd_key "$target_cwd")" || return 1
  printf '%s/rein/%s\n' "$base" "$key"
}

# The records location for a lineage (the current pointer, the handover log, the watcher log,
# the hooks log). Defaults to the project side's `.rein/` (a handover's history belongs to that
# working tree's lineage, and stays meaningful even if the machine changes).
#
# **A lineage's identity is not just cwd -- it's "cwd + root."** A second lineage relocated to a
# different root with `--root` puts its records on the root side too
# (`REIN_RECORDS_ROOT/<key>`) -- if two lineages sharing the same cwd shared `<cwd>/.rein/`
# instead, they would overwrite each other's current pointer and there would be no way to
# later recover which lineage a given primary session belonged to (running two lineages, say
# backend and frontend, in the same repository is a normal thing to do, so the locations are
# kept separate to make that work).
# The shape of the **last single stage** on the way to the records location. If that stage is a
# symlink, everything under it (the current pointer, the handover log, the watcher log, the
# hooks log, the handoff document, .gitignore) **moves along with it** to whatever the symlink
# targets. The clone's author gets to choose the target, which can be outside the project, so
# one command from the user would spawn records and a bare `*` .gitignore in an unrelated
# directory.
# **A per-writer shape check does not close this** -- since the target is a regular file, the
# atomic-write destination check, the handoff document's symlink rejection, and the
# runtime-directory owner check all correctly return 0. What goes unclosed is "the chain of
# parent directories leading to that path," so this is checked in the one place records get
# resolved.
# **A lineage with an explicit root (REIN_RECORDS_ROOT) is exempt** -- its records go under the
# root the user chose, so a clone has no room to redirect the location (the single
# `<cwd>/.rein` stage is simply not on that path at all).
# The reason is also carried in a variable, but it goes all the way to printf because most
# callers of this resolver are inside `$( )` -- returning it via a variable never reaches them
# (a caller that does receive it adds context and prints it itself).
REIN_RECORDS_ERROR=""
rein_records_dir_ok() {
  local dir="$1"
  REIN_RECORDS_ERROR=""
  [ -L "$dir" ] || return 0
  printf -v REIN_RECORDS_ERROR 'the records location is a symbolic link (not accepted, since it would write records out through the target -- put a real directory here instead): %s' \
    "$dir"
  printf 'rein: %s\n' "$REIN_RECORDS_ERROR" >&2
  return 1
}

rein_records_dir() {
  local root="${REIN_RECORDS_ROOT:-}" key
  if [ -n "$root" ]; then
    key="$(rein_cwd_key "$1")" || return 1
    printf -v REIN_RECORDS_PATH '%s/%s' "$root" "$key"
  else
    printf -v REIN_RECORDS_PATH '%s/%s' "$1" "$REIN_RECORDS_DIRNAME"
    if ! rein_records_dir_ok "$REIN_RECORDS_PATH"; then
      REIN_RECORDS_PATH=""
      return 1
    fi
  fi
  printf '%s\n' "$REIN_RECORDS_PATH"
}

# Whether a resolved location falls under a "never-touch root" (an interface only the selftest
# child holds). **The check sits in the one place right after a location is resolved, not just
# before a write** -- adding it per write path invites a miss whenever a path is added, and that
# miss becomes exactly the isolation hole (this is precisely what the counting-based fingerprint
# used to miss).
# Roots arrive newline-separated in REIN_SELFTEST_NEVER_ROOTS. Newline is the separator because
# `:` and `,` can appear in a path (a path containing a newline never appears in any of rein's
# location resolution).
# **The comparison is a literal prefix match; it does not normalize `..`, a trailing slash, or a
# symlink.** This only holds up because both the root and the child's resolved path derive
# from the same one env string (the managed marker, XDG), producing the identical literal.
# If one side picked up a normalization difference the other lacks (say the root alone runs
# through `pwd -P`, or only the child resolves through a symlink), a path that is actually inside
# the root would silently fail to match.
# 0=hit (the location hit and the root land in REIN_SELFTEST_NEVER_ROOT_HIT) / 1=no hit.
REIN_SELFTEST_NEVER_ROOT_HIT=""
rein_selftest_never_root_hit() {
  local roots="${REIN_SELFTEST_NEVER_ROOTS:-}" root path
  REIN_SELFTEST_NEVER_ROOT_HIT=""
  [ -n "$roots" ] || return 1
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    for path in "$@"; do
      [ -n "$path" ] || continue
      # The root itself, and anything under it. The pattern-side variable is quoted, so a glob
      # character in the root is matched as a literal.
      case "$path" in
        "$root" | "$root"/*)
          printf -v REIN_SELFTEST_NEVER_ROOT_HIT '%s (never-touch root %s)' "$path" "$root"
          return 0
          ;;
      esac
    done
  done <<EOF
$roots
EOF
  return 1
}

# The default location for the handoff document (next to the records). Because it follows cwd
# and `--root`, it cannot live in the config layer's known-keys table (which expands once at
# source time and knows neither cwd nor REIN_RECORDS_ROOT).
# **Only this one function resolves the default** -- if a handover request, bootstrap, the
# status view, and the config display each assembled it separately, "which path is canonical"
# would split apart per code path within the same lineage, and a handover would stall wherever
# only one of them turned out to exist.
# The result is also returned via a variable ($( ) would add a fork every cycle for the watcher,
# which reads every key on every pass).
#
# The records location can be passed in $2. **An interface for readers that cannot re-derive the
# records root from the environment**, used by hooks -- a managed hook receives a lineage's
# records location via the managed marker (REIN_MANAGED_RECORDS_DIR), because a `--root` root
# (REIN_RECORDS_ROOT) never reaches the environment (a background session's hook inherits its
# environment from the shared background service). Re-deriving it from the environment instead
# of accepting the argument would make only a root-relocated lineage's hooks point at
# `<cwd>/.rein/handoff.md`, disagreeing with the root-side document that a handover request,
# kickoff, and `rein init` are all looking at.
REIN_DEFAULT_HANDOFF_PATH=""
rein_default_handoff_path() {
  local records="${2:-}"
  REIN_DEFAULT_HANDOFF_PATH=""
  if [ -z "$records" ]; then
    rein_records_dir "$1" >/dev/null || return 1
    records="$REIN_RECORDS_PATH"
  fi
  printf -v REIN_DEFAULT_HANDOFF_PATH '%s/%s' "$records" "$REIN_HANDOFF_BASENAME"
  return 0
}

# Whether a file is a shape the handoff document can be accepted in -- **a non-symlink regular
# file, non-empty**. The reason is returned via a variable.
# Acceptance is consolidated into this one function because cold start (the template `rein init`
# lays down), launching the primary session (bootstrap), and a handover request each used to
# check the same path under separate conditions -- when the looser side let something through
# (a directory, a symlink) that the stricter side rejected, the primary session would start
# fine while only handover stalled.
# A symlink is rejected because swapping the target would let the judgment "the document has
# been fully written" (exists, non-empty, fresh) get silently substituted for a different file's
# state.
REIN_HANDOFF_ERROR=""
rein_handoff_file_ok() {
  local path="$1"
  REIN_HANDOFF_ERROR=""
  if [ -L "$path" ]; then
    REIN_HANDOFF_ERROR="the handoff document is a symlink (put a real regular file here instead): ${path}"
    return 1
  fi
  if [ ! -e "$path" ]; then
    REIN_HANDOFF_ERROR="the handoff document does not exist: ${path}"
    return 1
  fi
  if [ ! -f "$path" ]; then
    REIN_HANDOFF_ERROR="the handoff document is not a regular file: ${path}"
    return 1
  fi
  if [ ! -s "$path" ]; then
    REIN_HANDOFF_ERROR="the handoff document is empty: ${path}"
    return 1
  fi
  return 0
}

# **The canonical listing** of the handoff document's sections. Only this one sequence decides
# both the headings in the template `rein init` lays down and the section structure a handover
# request accepts -- if the template and the check held the literal separately, a document
# written exactly to the template could get rejected by a handover request (or, the other way
# around, an added section could slip past only the template's own check).
# The spelling and order are taken straight from the template's headings (no separate vocabulary
# is invented here).
REIN_HANDOFF_SECTIONS=(
  "Where things stand"
  "Next steps"
  "In flight at handover"
  "Standing decisions"
)

# Whether the handoff document matches the template's section structure -- **none of the
# template's sections are missing, and no `##` heading absent from the template has been
# added**. The reason is returned via a variable.
# **Kept as a separate function from the acceptable-shape check (`rein_handoff_file_ok`)**:
# that one is used as a plain boolean by laying down the template, launching the primary
# session, and a handover request all three -- adding the section check there would stop even
# the stage before the template exists, or launching the primary session, with "sections are
# missing." Only a handover request looks at sections.
# **Why this is checked mechanically**: "don't add sections" was only ever a rule in words, and
# it was actually broken (permanent rules and a work log piled up until the document turned into
# a dumping ground). An added section gets copied forward at every handover, so once it's added
# it never goes away without a person removing it by hand.
# Inside a code fence, nothing is counted as a heading -- otherwise a code example or a
# markdown quote pasted into the handoff body would turn into an "extra section" and block the
# very session that just finished writing the document right before a handover.
# **A fence remembers its opening character (` or ~) and its length, and only closes on a line
# of the same kind at the same length or longer** (both the opening and closing lines may be
# indented). A form that "flips on every line starting with ```" would let a run of 3 backticks
# appearing inside a 4-backtick fence, or an indented closing fence, swap what counts as inside
# and outside -- **so that not a single real heading gets counted, and the whole document is
# reported as "missing"** -- since this function's failure means handover cannot proceed, a
# misdiagnosis fails toward blocking handover.
# A never-closed fence is rejected with **its own reason, separate from "missing"** (mixing it
# with "missing" would tell the user to add headings that are already in the file, something
# reading the message alone can't fix).
REIN_HANDOFF_SECTION_ERROR=""
# **Just the substance of the reason** (used by the status view and doctor to embed in one line
# -- no long explanation attached).
REIN_HANDOFF_SECTION_DETAIL=""
rein_handoff_sections_ok() {
  local path="$1" line body rest heading want known missing="" extra="" detail=""
  local mark run fence=0 fence_mark="" fence_len=0
  local seen_headings=()
  REIN_HANDOFF_SECTION_ERROR=""
  REIN_HANDOFF_SECTION_DETAIL=""
  while IFS= read -r line || [ -n "$line" ]; do
    # Only fence detection strips leading whitespace (headings are left alone -- if an indented
    # `##` started counting as a section, a heading inside a bullet list would turn into an
    # "extra section").
    body="${line#"${line%%[![:space:]]*}"}"
    case "$body" in
      '`'*) mark='`' ;;
      '~'*) mark='~' ;;
      *) mark='' ;;
    esac
    run=0
    if [ -n "$mark" ]; then
      rest="$body"
      while [ "${rest#"$mark"}" != "$rest" ]; do
        run=$((run + 1))
        rest="${rest#"$mark"}"
      done
    fi
    if [ "$fence" -eq 1 ]; then
      # A line closes it only when it's **the same kind, same length or longer**, with nothing
      # but whitespace after the marker (the opening line may carry an info string; a closing
      # line may not -- the same split CommonMark makes).
      if [ "$mark" = "$fence_mark" ] && [ "$run" -ge "$fence_len" ]; then
        case "$rest" in
          *[![:space:]]*) ;;
          *)
            fence=0
            fence_mark=""
            fence_len=0
            ;;
        esac
      fi
      continue
    fi
    if [ -n "$mark" ] && [ "$run" -ge 3 ]; then
      fence=1
      fence_mark="$mark"
      fence_len="$run"
      continue
    fi
    case "$line" in
      '## '*) ;;
      *) continue ;;
    esac
    heading="${line#"## "}"
    # Strip trailing whitespace/CR (so two headings that look identical are not counted as
    # different ones).
    heading="${heading%"${heading##*[![:space:]]}"}"
    [ -n "$heading" ] || continue
    known=0
    for want in "${REIN_HANDOFF_SECTIONS[@]}"; do
      [ "$heading" = "$want" ] && known=1
    done
    [ "$known" -eq 1 ] || extra="${extra}${extra:+, }\"## ${heading}\""
    seen_headings[${#seen_headings[@]}]="$heading"
  done <"$path"
  # A never-closed fence means the way of counting sections itself never completed --
  # **kept separate from "missing"** (mixing them would tell the user to "add" headings that
  # are already present in the file).
  if [ "$fence" -ne 0 ]; then
    REIN_HANDOFF_SECTION_DETAIL="the code fence (${fence_mark} x${fence_len}) is never closed"
    REIN_HANDOFF_SECTION_ERROR="cannot count the handoff document's sections (${REIN_HANDOFF_SECTION_DETAIL}): ${path}. Add a closing fence -- to close it, repeat the same marker character the same number of times or more, with nothing else on that line (until it's closed, every heading after it reads as body text)"
    return 1
  fi
  for want in "${REIN_HANDOFF_SECTIONS[@]}"; do
    known=0
    for heading in ${seen_headings[@]+"${seen_headings[@]}"}; do
      [ "$heading" = "$want" ] && known=1
    done
    [ "$known" -eq 1 ] || missing="${missing}${missing:+, }\"## ${want}\""
  done
  [ -n "$missing" ] || [ -n "$extra" ] || return 0
  [ -n "$missing" ] && detail="missing headings: ${missing}"
  [ -n "$extra" ] && detail="${detail}${detail:+ / }headings not in the template: ${extra}"
  REIN_HANDOFF_SECTION_DETAIL="$detail"
  REIN_HANDOFF_SECTION_ERROR="the handoff document's section structure doesn't match the template (${detail}): ${path}. There are only the ${#REIN_HANDOFF_SECTIONS[@]} sections the template defines (add any missing heading, and move an extra heading's content out before deleting it). Permanent rules, procedures, and knowledge don't belong in this document -- write them to whatever your environment designates as canonical instead. Leaving them here means they get copied forward at every handover and never go away without someone removing them by hand"
  return 1
}

# The records location matching a runtime directory (used by cross-lineage scans -- `status
# --all`, `prune`). Since a scan only looks inside a single root, for a lineage that keeps its
# records on the root side, the key (the runtime directory's name) is itself the mapping. Not
# recomputing the key means one fewer shasum per scanned entry.
rein_records_dir_for_runtime() {
  local runtime_dir="$1" owner_cwd="$2"
  if [ -n "${REIN_RECORDS_ROOT:-}" ]; then
    printf '%s/%s\n' "$REIN_RECORDS_ROOT" "${runtime_dir##*/}"
    return 0
  fi
  [ -n "$owner_cwd" ] || return 1
  printf '%s/%s\n' "$owner_cwd" "$REIN_RECORDS_DIRNAME"
}

# Whether a records location is consistent with the same lineage's cwd and runtime directory
# (used to validate the value carried by the managed marker). Only two shapes hold: a lineage on
# the default root is `<cwd>/.rein`, and a root-relocated lineage is **an exact match with the
# root-side location worked back out from the runtime directory** (reversing `--root`'s
# layout). Anything that fits neither is either a mix-up in who passed what, or a reconstructed
# environment -- if a reader used it without checking, it would write into a different
# lineage's records.
#
# This does not pass on a mere match of the trailing key, because **the key is determined by
# cwd alone** -- an env with the root swapped out still has a matching key while pointing at a
# different root's records, so checking by key alone would let "same key, different root" pass
# silently through (running a second lineage with `--root` turns exactly this mix-up into a
# write into the first lineage's records). The key is not recomputed here, so as not to add one
# more shasum to a layer that runs on every tool invocation (the correspondence between key and
# cwd is checked by the runtime directory's owner check, rein_verify_runtime_owner).
rein_records_dir_matches_lineage() {
  local records="$1" runtime="$2" target_cwd="$3" root
  [ -n "$records" ] && [ -n "$runtime" ] && [ -n "$target_cwd" ] || return 1
  [ "$records" = "$target_cwd/$REIN_RECORDS_DIRNAME" ] && return 0
  root="${runtime%/"$REIN_ROOT_STATE_RELDIR"/*}"
  [ "$root" != "$runtime" ] || return 1
  [ "$records" = "$root/$REIN_ROOT_RECORDS_RELDIR/${runtime##*/}" ]
}

# .rein/ never goes into the consuming side's VCS (a rein lineage's records are not the target
# project's own output). Creation uses the O_EXCL equivalent (noclobber) and never touches an
# existing file or symlink (pointing `>` at a dangling symlink would create its target).
rein_ensure_records_dir() {
  local dir="$1" ignore="$1/.gitignore"
  # `mkdir -p` follows a symlink and succeeds (meaning the target's contents become the
  # location), so the last stage is checked before creating it. This runs through the same one
  # predicate as the resolution entry point -- the discipline isn't held in two places.
  rein_records_dir_ok "$dir" || return 1
  mkdir -p "$dir" || return 1
  # `.gitignore` is only placed in rein's own records location (.rein/). When config is a
  # symlink, the real parent directory (which can be a different repository belonging to the
  # user) arrives here instead, so without checking the name, an unrelated directory would get
  # hidden from git wholesale.
  case "${dir##*/}" in
    "$REIN_RECORDS_DIRNAME") ;;
    *) return 0 ;;
  esac
  if [ -e "$ignore" ] || [ -L "$ignore" ]; then
    return 0
  fi
  if ! (
    set -o noclobber
    printf '*\n' >"$ignore"
  ) 2>/dev/null; then
    # Couldn't write it, and it doesn't exist -- meaning the records would show up in the
    # consuming side's VCS. Passing this silently would make keeping the locations separate a
    # guarantee that only holds "when the write happened to succeed."
    [ -e "$ignore" ] || return 1
  fi
  return 0
}

# Checks a runtime directory's owner **using reads only** (this avoids adding a write, so it
# stops lineage mix-ups even for a reader that only reads the location -- the attach loop and a
# handover request's writer use this too).
# The owner file is restricted to a regular, non-symlink file containing a single line, because
# if a directory or symlink were accepted as owner, the check would pass silently through and
# something could start up in a runtime directory that has no valid owner.
# When the check completes, REIN_RUNTIME_OWNER_PRESENT records whether the owner file exists
# (1/0).
# 0=belongs to the target, or no owner has claimed it yet / 2=a different owner, or the owner
# cannot be confirmed
rein_verify_runtime_owner() {
  local dir="$1" target_cwd="$2" owner_file lines existing extra
  REIN_RUNTIME_ERROR=""
  REIN_RUNTIME_OWNER_PRESENT=0
  owner_file="$dir/$REIN_OWNER_BASENAME"
  if [ -L "$owner_file" ]; then
    printf -v REIN_RUNTIME_ERROR 'the owner file is a symlink (cannot confirm the owner of the runtime directory): %s' "$owner_file"
    return 2
  fi
  if [ ! -e "$owner_file" ]; then
    return 0
  fi
  REIN_RUNTIME_OWNER_PRESENT=1
  if [ ! -f "$owner_file" ]; then
    printf -v REIN_RUNTIME_ERROR 'the owner file is not a regular file (cannot confirm the owner of the runtime directory): %s' "$owner_file"
    return 2
  fi
  # Line count and the first line are checked using **builtins only** (since this check runs on
  # every tool invocation the hook fires, spawning awk and head once each would add up to a
  # fixed cost around 20 ms).
  # A file missing a trailing newline is still counted as one line (read returns 1 at EOF, but
  # the value is still populated).
  existing=""
  extra=""
  lines=0
  {
    if IFS= read -r existing || [ -n "$existing" ]; then
      lines=1
    fi
    if IFS= read -r extra || [ -n "$extra" ]; then
      lines=2
    fi
  } <"$owner_file"
  case "$lines" in
    1) ;;
    *)
      printf -v REIN_RUNTIME_ERROR 'the owner file is not exactly one line (%s lines): %s' "$lines" "$owner_file"
      return 2
      ;;
  esac
  if [ "$existing" = "$target_cwd" ]; then
    return 0
  fi
  printf -v REIN_RUNTIME_ERROR 'the runtime directory belongs to a different target (owned by %s): %s' \
    "${existing:-(unreadable)}" "$dir"
  return 2
}

# Places a fresh owner file, and **runs whatever landed back through the same full
# verification used before creation**. Creation uses the O_EXCL equivalent (noclobber), so on a
# race, only the side that wrote first wins. If the losing side accepted a mere `head -1` match,
# it would end up accepting a symlink dropped into the race window, or a multi-line file whose
# first line just happens to match, as the owner (with mktemp + mv instead, whichever write
# lands last would simply win and overwrite).
# 0=claimed by the target / 1=cannot write it / 2=a different owner, or cannot be confirmed
rein_claim_runtime_owner() {
  local dir="$1" target_cwd="$2" owner_file="$1/$REIN_OWNER_BASENAME" rc
  (
    set -o noclobber
    printf '%s\n' "$target_cwd" >"$owner_file"
  ) 2>/dev/null
  # Both the winning and losing side run through the same verification (the write's own
  # success or failure is not consulted -- "wrote it but the contents are someone else's" and
  # "lost the race but the contents are the target's anyway" are both judged from whatever landed).
  rein_verify_runtime_owner "$dir" "$target_cwd"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    return "$rc"
  fi
  if [ "$REIN_RUNTIME_OWNER_PRESENT" -eq 1 ]; then
    return 0
  fi
  printf -v REIN_RUNTIME_ERROR 'cannot write the owner file: %s' "$owner_file"
  return 1
}

# The lineage token's length in hex characters (32 bytes of /dev/urandom). Held once so the
# drawing side and the shape check can never disagree about how long a token is.
REIN_TOKEN_HEX_LEN=64
REIN_RUNTIME_TOKEN=""

# Reads the lineage token a runtime directory holds, **using builtins only** (this runs on every
# tool invocation a hook fires, and the hook's whole design is to spawn nothing it doesn't have
# to -- see the "no-op path" rules at the top of rein-hook.sh).
# The shape is checked, not just the presence: a file that is a symlink, is not a regular file,
# is not exactly one line, or holds anything but exactly REIN_TOKEN_HEX_LEN lowercase hex
# characters **is not a token**, and is refused rather than compared. Comparing an unvalidated
# value would make an empty file a token any empty env matches.
# **The value never goes into the reason** (it is the secret; a reason is printed to stderr and
# lands in logs). Only the file's location does.
# 0=read (in REIN_RUNTIME_TOKEN) / 1=absent, unreadable, or not a token's shape
# (reason in REIN_RUNTIME_ERROR, and REIN_RUNTIME_TOKEN is emptied so a caller that skips the
# return value cannot compare against a half-read value)
rein_read_runtime_token() {
  local dir="$1" token_file="$1/$REIN_TOKEN_BASENAME" extra lines=0
  REIN_RUNTIME_TOKEN=""
  REIN_RUNTIME_ERROR=""
  if [ -L "$token_file" ]; then
    printf -v REIN_RUNTIME_ERROR 'the lineage token file is a symlink (its content cannot be trusted as this lineage secret): %s' "$token_file"
    return 1
  fi
  if [ ! -f "$token_file" ]; then
    printf -v REIN_RUNTIME_ERROR 'the runtime directory holds no lineage token file: %s' "$token_file"
    return 1
  fi
  extra=""
  {
    if IFS= read -r REIN_RUNTIME_TOKEN || [ -n "$REIN_RUNTIME_TOKEN" ]; then
      lines=1
    fi
    if IFS= read -r extra || [ -n "$extra" ]; then
      lines=2
    fi
  } <"$token_file"
  if [ "$lines" -ne 1 ] || [ "${#REIN_RUNTIME_TOKEN}" -ne "$REIN_TOKEN_HEX_LEN" ]; then
    REIN_RUNTIME_TOKEN=""
    printf -v REIN_RUNTIME_ERROR 'the lineage token file is not a single line of %s hex characters: %s' \
      "$REIN_TOKEN_HEX_LEN" "$token_file"
    return 1
  fi
  case "$REIN_RUNTIME_TOKEN" in
    *[!0-9a-f]*)
      REIN_RUNTIME_TOKEN=""
      printf -v REIN_RUNTIME_ERROR 'the lineage token file holds something other than hex characters: %s' "$token_file"
      return 1
      ;;
  esac
  return 0
}

# Draws a fresh lineage token: 32 bytes straight from /dev/urandom, rendered as hex.
# **rein_nonce is deliberately not reused here.** That value is `$$` concatenated with `$RANDOM`
# -- a collision avoider for file names, never a secret: the pid is observable, and `$RANDOM` is
# a per-shell PRNG whose next value follows from its seed. A marker forged with a guessed value
# would pass, which is the whole thing this token exists to stop.
# `od` and `tr` are both POSIX. `tr` is already used on production paths; **`od` is the one new
# external command this adds**, and it is reached only when a lineage is being provisioned --
# never on the hook's no-op path. It is in rein_check_prerequisites' list, so a machine without a
# working `od` is named at install, launch, and diagnostics time, before ever getting here.
# The reason below still names the commands rather than only the outcome: this path is also
# reached for what that check cannot see (a short read from /dev/urandom on this one call), and
# a lineage can be provisioned by an entry point that ran its prerequisite check earlier in the
# same process.
# 0=drawn (in REIN_RUNTIME_TOKEN) / 1=the draw produced nothing usable
rein_new_runtime_token() {
  local value
  REIN_RUNTIME_TOKEN=""
  value="$(od -An -v -tx1 -N32 /dev/urandom 2>/dev/null | tr -d ' \n')"
  # A short or non-hex draw is refused rather than padded or retried: a token that is not the
  # full width is a weaker secret than the one this claims to place, and a silent weakening is
  # exactly the failure a fail-loud rule exists to prevent.
  [ "${#value}" -eq "$REIN_TOKEN_HEX_LEN" ] || return 1
  case "$value" in
    *[!0-9a-f]*) return 1 ;;
  esac
  REIN_RUNTIME_TOKEN="$value"
  return 0
}

# Places a lineage token if the runtime directory has none, and leaves an existing one alone.
# **The lifetime is the runtime directory's**: drawn once when the lineage is provisioned and
# kept until the directory itself goes away, so the first session and every successor of a
# lineage are handed the same value (a per-launch value would mean every generation had to be
# re-handed one, and a session whose marker predated the redraw would start failing loud).
# Creation is create-exclusive under `umask 077` (0600, never through a symlink, never over an
# existing file), and **whatever landed is read back through the same full validation** -- on a
# race the loser takes the winner's value rather than its own.
# A file that exists but is not a token's shape is **never overwritten** (it may be something
# the user put there); it fails loud instead.
# 0=a token is in place (in REIN_RUNTIME_TOKEN) / 1=cannot place one (reason in REIN_RUNTIME_ERROR)
rein_ensure_runtime_token() {
  local dir="$1" token_file="$1/$REIN_TOKEN_BASENAME"
  if rein_read_runtime_token "$dir"; then
    return 0
  fi
  if [ -e "$token_file" ] || [ -L "$token_file" ]; then
    return 1
  fi
  if ! rein_new_runtime_token; then
    printf -v REIN_RUNTIME_ERROR 'cannot draw a lineage token (od and tr did not turn 32 bytes of /dev/urandom into %s hex characters -- check that both commands work): %s' \
      "$REIN_TOKEN_HEX_LEN" "$token_file"
    return 1
  fi
  (
    umask 077
    set -o noclobber
    printf '%s\n' "$REIN_RUNTIME_TOKEN" >"$token_file"
  ) 2>/dev/null
  # The write's own success is not consulted -- "wrote it but someone else's value is what is
  # there" and "lost the race but a valid token is there anyway" are both judged from what landed.
  rein_read_runtime_token "$dir" || return 1
  return 0
}

# Prepares a runtime directory, has it self-declare its owner (cwd), and places its lineage
# token. Without an owner, there is no way from the outside to trace which working tree a
# leftover piece of runtime data belongs to, and so no way to decide whether it is safe to
# delete. The token is placed **in the same layer as the owner claim** so that every side that
# can stand a lineage up (the watcher, the seat, a handover request, `rein init` / `up`) leaves
# a lineage complete -- a lineage provisioned by one of them and later handed a session by
# another would otherwise have no token for that session's hooks to match.
# 0=ready / 1=cannot create it, or cannot place the token / 2=belongs to a different cwd
# (reason in REIN_RUNTIME_ERROR)
rein_ensure_runtime_dir() {
  local dir="$1" target_cwd="$2" rc
  REIN_RUNTIME_ERROR=""
  mkdir -p "$dir" || {
    printf -v REIN_RUNTIME_ERROR 'cannot create the runtime directory: %s' "$dir"
    return 1
  }
  rein_verify_runtime_owner "$dir" "$target_cwd"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    return "$rc"
  fi
  if [ "$REIN_RUNTIME_OWNER_PRESENT" -ne 1 ]; then
    rein_claim_runtime_owner "$dir" "$target_cwd"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      return "$rc"
    fi
  fi
  rein_ensure_runtime_token "$dir"
}

# Resolve a directory to its physical path -- symlinks resolved, `.` segments and a trailing `/`
# collapsed. `cd` and `pwd` are shell builtins, so nothing here can be swapped out through PATH,
# and every entry point that loads this library unsets `CDPATH` before doing so (with it set,
# `cd` prints the destination and the substitution would come back as two lines).
# 0 with the result in REIN_PHYSICAL_DIR / 1 when it cannot be resolved (it does not exist,
# is not a directory, or cannot be entered). The caller decides what an unresolvable path means --
# there is no "return the text unchanged" answer, because that is exactly the silent fall back to
# comparing spellings that the resolution exists to remove.
REIN_PHYSICAL_DIR=""
rein_physical_dir() {
  REIN_PHYSICAL_DIR="$(cd -- "$1" 2>/dev/null && pwd -P)"
  [ -n "$REIN_PHYSICAL_DIR" ] || return 1
  return 0
}

# The lineage context a **verified** managed marker carries. Empty until
# rein_verify_managed_marker has answered 0, and emptied again on every rejection -- so a caller
# that skipped the return value can never pick up a value only half of which was checked.
REIN_MANAGED_MARKER_CWD=""
REIN_MANAGED_MARKER_RUNTIME_DIR=""
REIN_MANAGED_MARKER_RECORDS_DIR=""
REIN_MANAGED_MARKER_CONFIG_FILE=""
# Why a marker that was present did not verify. This reaches stderr (and, for the hook, the
# health record), so it never carries either side of the token comparison.
REIN_MANAGED_MARKER_ERROR=""

# Rejects the marker: records the reason and drops every value, so nothing downstream can use a
# context that only some of the checks passed.
rein_managed_marker_reject() {
  REIN_MANAGED_MARKER_ERROR="$1"
  REIN_MANAGED_MARKER_CWD=""
  REIN_MANAGED_MARKER_RUNTIME_DIR=""
  REIN_MANAGED_MARKER_RECORDS_DIR=""
  REIN_MANAGED_MARKER_CONFIG_FILE=""
  return 1
}

# Validates the managed marker env (present only for sessions rein itself launched) and hands
# back the lineage context it carries. A missing field, a malformed one, or a runtime directory
# whose recorded owner doesn't match is **rejected** -- there is no "resolve it some other way"
# path left: a marker that is present but broken means the launch handed over a lineage that
# cannot be trusted, and guessing one would mean writing into a different lineage's records.
# This env arrives via **the session's settings env**, not the launch command's environment --
# a background session's hook and statusline processes inherit their environment from the shared
# background service, so environment variables set at launch time never reach them (observed).
# **The marker carries the entire lineage context** (cwd and the runtime directory, plus the
# user-scope config and records location, neither of which can be derived from cwd alone) **and
# that lineage's token** -- the one field of it that cannot be reproduced without reading inside
# the runtime directory.
# These are deliberately never re-derived from the process's leftover environment variables
# (REIN_CONFIG_FILE, REIN_RECORDS_ROOT) -- for the same reason, they never reach that session.
# Falling back would mean a reader for a lineage rooted elsewhere (via --root) reads the default
# config and writes to the default location (`<cwd>/.rein/`), mixing two lineages together.
#
# **This is the one implementation of that validation.** Both readers of the marker go through
# here -- the hook, which acts on the session, and statusline, which writes the usage record
# into the location the lineage's own config names. A second copy would let the two drift, and
# the drift is invisible from either side alone: the reader that kept the weaker copy would go
# on acting for a lineage the other one already refuses.
# **This function decides nothing about what a verdict means.** It has no exit of its own, it
# never writes anywhere, and it never prints -- the caller owns the ending. The hook turns a
# rejection into hook_die; statusline turns it into one line on stderr and a fall back to its
# default resolution.
# 0=verified (context in REIN_MANAGED_MARKER_*) / 1=present but not verified (reason in
# REIN_MANAGED_MARKER_ERROR) / 2=no marker at all, which is **an ordinary session rein never
# launched and not a failure** (the reason stays empty; every caller has a reader that runs in
# sessions rein did not launch, so this verdict is the normal one out in the world)
rein_verify_managed_marker() {
  local owner_rc cwd_real runtime_real
  REIN_MANAGED_MARKER_ERROR=""
  REIN_MANAGED_MARKER_CWD=""
  REIN_MANAGED_MARKER_RUNTIME_DIR=""
  REIN_MANAGED_MARKER_RECORDS_DIR=""
  REIN_MANAGED_MARKER_CONFIG_FILE=""
  # The marker being **entirely absent** is its own verdict (2), never a rejection. Anything
  # else that is present is a marker in a shape rein never writes.
  [ -n "${REIN_MANAGED:-}" ] || return 2
  case "${REIN_MANAGED:-}" in
    1) ;;
    *)
      rein_managed_marker_reject "managed marker ${REIN_MANAGED_ENV_NAME} is not 1: ${REIN_MANAGED:-(none)}"
      return 1
      ;;
  esac
  REIN_MANAGED_MARKER_CWD="${REIN_MANAGED_CWD:-}"
  REIN_MANAGED_MARKER_RUNTIME_DIR="${REIN_MANAGED_RUNTIME_DIR:-}"
  REIN_MANAGED_MARKER_RECORDS_DIR="${REIN_MANAGED_RECORDS_DIR:-}"
  REIN_MANAGED_MARKER_CONFIG_FILE="${REIN_MANAGED_CONFIG_FILE:-}"
  case "$REIN_MANAGED_MARKER_CWD" in
    /*) ;;
    *)
      rein_managed_marker_reject "managed marker's ${REIN_MANAGED_CWD_ENV_NAME} is not an absolute path: ${REIN_MANAGED_CWD:-(none)}"
      return 1
      ;;
  esac
  case "$REIN_MANAGED_MARKER_RUNTIME_DIR" in
    /*) ;;
    *)
      rein_managed_marker_reject "managed marker's ${REIN_MANAGED_RUNTIME_ENV_NAME} is not an absolute path: ${REIN_MANAGED_RUNTIME_DIR:-(none)}"
      return 1
      ;;
  esac
  case "$REIN_MANAGED_MARKER_RECORDS_DIR" in
    /*) ;;
    *)
      rein_managed_marker_reject "managed marker's ${REIN_MANAGED_RECORDS_ENV_NAME} is not an absolute path: ${REIN_MANAGED_RECORDS_DIR:-(none)}"
      return 1
      ;;
  esac
  case "$REIN_MANAGED_MARKER_CONFIG_FILE" in
    /*) ;;
    *)
      rein_managed_marker_reject "managed marker's ${REIN_MANAGED_CONFIG_ENV_NAME} is not an absolute path: ${REIN_MANAGED_CONFIG_FILE:-(none)}"
      return 1
      ;;
  esac
  if [ ! -d "$REIN_MANAGED_MARKER_CWD" ]; then
    rein_managed_marker_reject "the managed marker's lineage cwd doesn't exist: ${REIN_MANAGED_MARKER_CWD}"
    return 1
  fi
  # **The runtime directory may never sit under the lineage cwd.** rein places runtime data in
  # the user's own state area (XDG's state, or under `--root`) and never inside the target
  # project (see "Locations" in docs/spec/runtime.md), so this rejects nothing a real launch
  # produces -- and it closes the one forgery the owner file and the token cannot: **a clone
  # that ships its own runtime directory inside itself**, `owner` and `token` included. Both of
  # those are files, and a repository can carry files; what a repository cannot do is place them
  # outside the tree it was cloned into. Every other field of such a marker is self-consistent
  # (the owner file holds the cwd the marker states, the token matches the file beside it, and
  # the records location is that cwd's own `.rein`), so nothing else here objects to it.
  # The trailing `/` is what makes this a containment test rather than a prefix test: with
  # cwd `/a/b`, the runtime directory `/a/b-other` is a **different** directory and still passes.
  # **Both sides are resolved to their physical paths before the comparison** (`cd` + `pwd -P`).
  # Comparing the two values as the marker spells them would be evaded by naming the same pair of
  # directories through spellings that don't textually nest -- a trailing `/` or a `.` segment on
  # the cwd it states, or a symlink shipped inside the tree and named as the cwd. Both values come
  # from the same settings file, so an author who knows the check picks the spelling; resolving
  # removes the choice, because every spelling of one directory resolves to one physical path.
  # The price is 2 subshell forks per managed event, and no external command (`cd` and `pwd` are
  # builtins), on a path that already runs `jq`.
  # **Only this comparison uses the resolved values.** The owner file's contents and the records
  # location are matched against the spellings the marker and the watcher wrote, unresolved and
  # unchanged: the owner file holds the cwd as its writer spelled it, so resolving one side of
  # that comparison would start rejecting legitimate lineages that were set up through a symlink.
  # A path that cannot be resolved is rejected, never a silent fall back to comparing the text.
  # For the runtime directory this also means a marker naming one that does not exist is refused
  # here rather than further down at the owner file -- which costs a real launch nothing, since
  # the owner file that same launch requires can only exist inside a directory that does.
  if ! rein_physical_dir "$REIN_MANAGED_MARKER_CWD"; then
    rein_managed_marker_reject "the managed marker's ${REIN_MANAGED_CWD_ENV_NAME} cannot be resolved to a physical path, so nothing can say where the runtime directory sits relative to it: ${REIN_MANAGED_MARKER_CWD}"
    return 1
  fi
  cwd_real="$REIN_PHYSICAL_DIR"
  if ! rein_physical_dir "$REIN_MANAGED_MARKER_RUNTIME_DIR"; then
    rein_managed_marker_reject "the managed marker's ${REIN_MANAGED_RUNTIME_ENV_NAME} cannot be resolved to a physical path, so nothing can say where it sits relative to the lineage cwd: ${REIN_MANAGED_MARKER_RUNTIME_DIR}"
    return 1
  fi
  runtime_real="$REIN_PHYSICAL_DIR"
  case "$runtime_real" in
    "$cwd_real" | "$cwd_real"/*)
      rein_managed_marker_reject "the managed marker's ${REIN_MANAGED_RUNTIME_ENV_NAME} sits under the lineage cwd, where rein never places runtime data, so nothing separates it from a runtime directory the working tree itself carries: ${REIN_MANAGED_MARKER_RUNTIME_DIR} (under ${REIN_MANAGED_MARKER_CWD})"
      return 1
      ;;
  esac
  # Reject a records location and runtime directory that belong to different lineages -- if
  # only one of the two was swapped out in the env, a reader would end up reading one lineage's
  # markers while writing another lineage's records.
  if ! rein_records_dir_matches_lineage "$REIN_MANAGED_MARKER_RECORDS_DIR" "$REIN_MANAGED_MARKER_RUNTIME_DIR" "$REIN_MANAGED_MARKER_CWD"; then
    rein_managed_marker_reject "managed marker's ${REIN_MANAGED_RECORDS_ENV_NAME} doesn't match the lineage (records ${REIN_MANAGED_MARKER_RECORDS_DIR} / runtime ${REIN_MANAGED_MARKER_RUNTIME_DIR})"
    return 1
  fi
  rein_verify_runtime_owner "$REIN_MANAGED_MARKER_RUNTIME_DIR" "$REIN_MANAGED_MARKER_CWD"
  owner_rc=$?
  if [ "$owner_rc" -ne 0 ]; then
    rein_managed_marker_reject "$REIN_RUNTIME_ERROR"
    return 1
  fi
  # **A marker requires the owner file to exist**, unlike every other caller of that function.
  # rein_verify_runtime_owner answers 0 for a runtime directory that has no owner file yet -- its
  # contract, so the writers (watcher, seat, request, prune, doctor) can run before the first
  # claim -- and that "nobody has claimed it yet" answer is exactly what a forged marker leans on.
  # Point the runtime at any owner-less absolute path, the cwd at a real project, and the records
  # at that project's real records location, and nothing else in this function objects
  # (rein_records_dir_matches_lineage only asks that records equal `<cwd>/<records dirname>`), so
  # a reader would act on **that project's** lineage -- the hook would append to its hooks.log,
  # and statusline would place the usage record wherever that project's config points. That is
  # reachable: the marker arrives through the session's settings env, and Claude Code's own
  # documentation lists a repository's settings `env` block as taking effect in a folder that was
  # never trusted itself (a `claude -p` or SDK run there, or a folder covered by a parent folder
  # that was trusted), so a received clone can carry one.
  # Requiring it costs nothing legitimate: whoever started this lineage (`rein up` / `rein init`)
  # claims the owner before any session exists, so by the time a reader can run under a marker the
  # owner file is already there. The other callers keep the unchanged contract -- they are the
  # ones who create it.
  if [ "$REIN_RUNTIME_OWNER_PRESENT" -ne 1 ]; then
    rein_managed_marker_reject "the managed marker's ${REIN_MANAGED_RUNTIME_ENV_NAME} names a runtime directory with no owner file, so nothing confirms it belongs to this lineage: ${REIN_MANAGED_MARKER_RUNTIME_DIR}/${REIN_OWNER_BASENAME}"
    return 1
  fi
  # **The marker also has to carry that lineage's own token.** Everything checked above is a
  # value that can be reproduced from outside: a cwd, the locations derived from it, and an
  # owner file whose one line is that same cwd. A settings `env` shipped inside a repository can
  # name all of them, so none of them separates "rein launched this window" from "a settings
  # file said so." The token is the one field that cannot be written without reading inside the
  # runtime directory -- and the runtime directory of a lineage the user's own `rein up`
  # created sits under the user's own state area (0600), which is outside the clone and outside
  # what a settings file can reach. So a marker naming a real lineage now fails here unless it
  # came from the launch that read that lineage's token.
  # **This check sits after the owner check on purpose**: the two forgeries stay separately
  # measurable (a marker naming an unclaimed directory still fails on the owner file, naming
  # the missing owner as the reason, rather than being absorbed into a token mismatch).
  # Absent, empty, and mismatched are one single outcome, fail-loud. A "neither side has one,
  # so let it through" path would hand the whole bypass back to anyone naming a runtime
  # directory that has no token.
  if ! rein_read_runtime_token "$REIN_MANAGED_MARKER_RUNTIME_DIR"; then
    rein_managed_marker_reject "$REIN_RUNTIME_ERROR"
    return 1
  fi
  # Neither value goes into the reason: the marker's side is attacker-chosen text, and the
  # file's side is the secret itself -- and this reason reaches stderr and the health record.
  if [ -z "${REIN_MANAGED_TOKEN:-}" ] || [ "${REIN_MANAGED_TOKEN:-}" != "$REIN_RUNTIME_TOKEN" ]; then
    rein_managed_marker_reject "the managed marker's ${REIN_MANAGED_TOKEN_ENV_NAME} does not match this lineage's token, so the marker did not come from a session rein launched: ${REIN_MANAGED_MARKER_RUNTIME_DIR}/${REIN_TOKEN_BASENAME}"
    return 1
  fi
  return 0
}

# The "lineage named explicitly" that gets embedded into a one-line instruction. In a session
# rein launched, REIN_CONFIG_FILE / REIN_RUNTIME_DIR / REIN_RECORDS_ROOT are deliberately
# dropped (a background session's hook and seat inherit a shared environment, so a per-lineage
# override cannot travel via env), so if the instruction given were a plain line naming no
# location, `rein --cwd <cwd> request` typed inside that session would resolve the **default**
# location instead. For a root-relocated lineage, the handover request would fail right there
# (reading "no watcher present"), and a snooze would get written to the default location and
# show success while doing nothing for even a second.
#
# Only two layouts hold (the same two rein_records_dir_matches_lineage accepts):
#   (1) A root-relocated lineage -- both runtime and records follow the root's layout ->
#       `--root <root>` (a global option). `--runtime-dir` alone is not enough, because
#       **the records location would fall back to the default `<cwd>/.rein/`**, and the
#       handover request's R10 cross-check would then read a different lineage's pointer --
#       only `--root` can name this lineage correctly.
#   (2) Anything else -- records are at `<cwd>/.rein/`. Only when the runtime directory differs
#       from the default (XDG's state area) is `--runtime-dir <effective value>` appended (a
#       verb option -- placed after the verb).
# A lineage on the default layout gets nothing appended (the line the user runs stays no
# longer than it needs to be). Whether it's the default is checked without recomputing the key
# (the key is the runtime directory's name, verbatim).
# **A records location that is empty (couldn't be resolved) is named "undetermined"** (2). Since
# the records location is the material that tells (1) apart from (2), moving forward with it
# empty would always collapse into (2), the `--runtime-dir` form -- producing exactly the wrong
# instructions warned about above, now dressed up as a determined answer.
# 0=the lineage was named explicitly / 2=the records location is empty, cannot be determined
REIN_LINEAGE_GLOBAL_OPTS=""
REIN_LINEAGE_VERB_OPTS=""
REIN_LINEAGE_ERROR=""
rein_lineage_opts() {
  local runtime="$1" records="$2" root
  REIN_LINEAGE_GLOBAL_OPTS=""
  REIN_LINEAGE_VERB_OPTS=""
  REIN_LINEAGE_ERROR=""
  if [ -z "$records" ]; then
    REIN_LINEAGE_ERROR="cannot resolve the records location, so the lineage cannot be named explicitly in the line to run"
    return 2
  fi
  root="${runtime%/"$REIN_ROOT_STATE_RELDIR"/*}"
  if [ "$root" != "$runtime" ] &&
    [ "$records" = "$root/$REIN_ROOT_RECORDS_RELDIR/${runtime##*/}" ]; then
    printf -v REIN_LINEAGE_GLOBAL_OPTS ' --root %s' "$(rein_shell_quote "$root")"
    return 0
  fi
  # Whether it matches the default location **can only be asked on a machine where the default
  # itself can be assembled**. Comparing without that guard, on a machine with no HOME,
  # `/.local/state/rein/<key>` would masquerade as "the default location," and `--runtime-dir`
  # would drop out of the line the successor runs -- if HOME is back by the time the successor's
  # machine runs it, it would look in a different location, silently stalling handover for that
  # generation. On a machine where the default cannot even be assembled, this does not claim to
  # be the default; it falls back to naming the location explicitly.
  if rein_xdg_base "${XDG_STATE_HOME:-}" XDG_STATE_HOME .local/state "runtime data" &&
    [ "$runtime" = "$REIN_XDG_BASE/rein/${runtime##*/}" ]; then
    return 0
  fi
  printf -v REIN_LINEAGE_VERB_OPTS ' --runtime-dir %s' "$(rein_shell_quote "$runtime")"
  return 0
}

# Quotes a value into a single word that can be pasted straight into a shell (bash 3.2 has no
# printf %q, so this wraps it in single quotes and splits any ' inside the value into '\'').
# Since the command kickoff instructs is run verbatim by the successor, a path containing a
# space, `;`, or `$( )` that isn't quoted would either split the arguments and stall handover
# for that generation, or get evaluated as unintended shell syntax.
rein_shell_quote() {
  local value="$1" sq="'" rep
  # The 4 characters ' \ ' ' (close the single quote, place an escaped ', reopen it).
  rep="${sq}\\${sq}${sq}"
  printf '%s%s%s\n' "$sq" "${value//$sq/$rep}" "$sq"
}

# A single rein command line the user can paste and run verbatim. Naming the lineage explicitly
# (`--root` / `--runtime-dir`) with its effective value matters because, for a lineage whose
# locations were relocated, simply saying `rein --cwd <cwd> up` would launch a watcher for
# **a different lineage** (typed exactly as instructed, this leaves whatever request was placed
# for this lineage never picked up). Adding a prose aside like "also pass the same `--root` /
# `--runtime-dir`" leaves the same hole in the line itself (the user still has to go look up the
# effective value themselves).
# **Every writer that shows the user a rein command as "a single line to paste and run" goes
# through this one function** -- if the same judgment split across "a helper / prose / nothing
# at all," whichever fraction split off would always end up giving wrong instructions somewhere.
# **The one exception is the `config` verb, which is named from different material** (the user
# config's location, not the runtime directory) -- its entry point is
# `rein_config_lineage_cmd`, sharing this same assembly.
# **"Every" is counted mechanically, not by a human enumeration** -- `check.sh`'s `lineage-cmd`
# gate scans the entire shell source for a bare `rein <verb>` (also catching the case where an
# option sits between `rein` and the verb). An exempted line declares it on the same line as
# `lineage-cmd-exempt: <reason>` (written on the line itself so it can never drift out of sync
# with a separate table).
# The declared exemptions fall into 4 kinds, none of which is **a line meant to be run**:
#   (1) Instructions given before rein is even on PATH (the PATH-absent line in
#       `hooks/rein-hook-launcher.sh` / `rein-hook.sh`) -- a layer with no notion of a lineage,
#       so that line was never runnable as pasted in the first place.
#   (2) Explaining an event that already happened (`rein-seat.sh`'s "rein down shut this
#       lineage down," among others).
#   (3) Instructions telling the user to shut down **a different lineage** (the nested lineage
#       in `lib/cli/doctor.sh`) -- the other lineage's runtime directory cannot be resolved from
#       here, so filling in this lineage's effective values would give wrong instructions.
#   (4) The argv sequence a check expects (the line following `st_expect_argv`) -- a needle
#       measuring that the instructions are passed word by word. Since the helper name only
#       appears on a call's first line, excluding by name would exclude zero of these lines.
# $1=the command's binary (`rein` on PATH, or the absolute path used on a machine where it isn't)
# $2=runtime directory $3=records location $4=target cwd $5=verb $6=literal text to append after
# the verb (optional).
# **The command's binary is also quoted inside this function** (no contract of "quote it before
# passing it in" is placed on the caller). Stating that contract only as a comment would mean
# **no machine checks whether it's honored** -- what the shell-quote gate looks for is "a word
# sitting in a position that takes a path," and `rein_lineage_cmd`'s first argument is not on
# that list; a `"$VAR"` wrapped in double quotes looks quoted as a word already, so adding the
# check there still would not catch it. Quoting inside the function instead means the line stays
# unbroken even for a binary placed at a location containing a space or `;`. A literal `rein`
# becomes `'rein'`, but pasted and run, the result is identical (the shell strips a command
# name's quotes before searching for it).
# **When the lineage cannot be named explicitly, nothing is assembled** (a non-zero return, and
# REIN_LINEAGE_CMD stays empty) -- so the caller can never mistake "a line with effective values
# filled in" for "an unfilled literal."
# 0=assembled / 2=cannot determine how to name the lineage explicitly (reason in
# REIN_LINEAGE_ERROR)
REIN_LINEAGE_CMD=""
rein_lineage_cmd() {
  local bin="$1" runtime="$2" records="$3" cwd="$4" verb="$5" verb_args="${6:-}"
  REIN_LINEAGE_CMD=""
  rein_lineage_opts "$runtime" "$records" || return $?
  rein_lineage_line "$bin" "$cwd" "$verb" "$verb_args"
}

# **Just the assembly**, once the naming has been decided. The order -- global options before
# the verb, verb options after it -- lives in this one place (the way a lineage gets named
# explicitly differs by lineage type, but the shape of the line to run is one shape). This is
# the internal interface a caller invokes after first deciding REIN_LINEAGE_*_OPTS; writers that
# build a line to show the user go through the two entry points below
# (rein_lineage_cmd / rein_config_lineage_cmd).
rein_lineage_line() {
  local bin="$1" cwd="$2" verb="$3" verb_args="${4:-}"
  printf -v REIN_LINEAGE_CMD '%s%s --cwd %s %s%s%s' \
    "$(rein_shell_quote "$bin")" "$REIN_LINEAGE_GLOBAL_OPTS" "$(rein_shell_quote "$cwd")" \
    "$verb" "$REIN_LINEAGE_VERB_OPTS" "${verb_args:+ $verb_args}"
}

# The "lineage named explicitly" embedded into `config`'s instructions. **Named from different
# material than above (rein_lineage_opts)** -- the `config` verb touches the user config and the
# decision ledger next to it (rein_config_allow_file); neither the runtime directory nor the
# records location moves where the ledger lives. So this is worked back out from **the user
# config's location** instead (whichever of `--root` / `--config` relocated it, it is folded
# into this one value).
#
# Only two layouts hold:
#   (1) A root-relocated lineage -- `<root>/$REIN_ROOT_CONFIG_RELPATH` -> `--root <root>` (a
#       global option).
#   (2) Anything else that differs from the default (XDG's config area) -> `--config <effective
#       value>` (a global option).
# A lineage on the default layout gets nothing appended (the line the user runs stays no longer
# than it needs to be).
# **The `--runtime-dir` form cannot be used here** -- `config` takes no verb options at all, so
# literal text appended after the verb fails with "takes no arguments" (observed). It has no
# effect on where the ledger lives either.
# **A location that is empty (couldn't be resolved) is named "undetermined"** (2) -- falling
# back to the default while it's empty would present "a line with no lineage named" as a
# determined answer for a relocated lineage.
# 0=the lineage was named explicitly / 2=the user config's location is empty, cannot be
# determined
rein_config_lineage_opts() {
  local user_config="$1" root
  REIN_LINEAGE_GLOBAL_OPTS=""
  REIN_LINEAGE_VERB_OPTS=""
  REIN_LINEAGE_ERROR=""
  if [ -z "$user_config" ]; then
    REIN_LINEAGE_ERROR="cannot resolve the user config's location, so the lineage cannot be named explicitly in the line to run"
    return 2
  fi
  root="${user_config%/"$REIN_ROOT_CONFIG_RELPATH"}"
  if [ "$root" != "$user_config" ] && [ -n "$root" ]; then
    printf -v REIN_LINEAGE_GLOBAL_OPTS ' --root %s' "$(rein_shell_quote "$root")"
    return 0
  fi
  # Whether it matches the default can only be asked on a machine where the default itself can
  # be assembled (the same discipline as the runtime-data side).
  if rein_xdg_base "${XDG_CONFIG_HOME:-}" XDG_CONFIG_HOME .config "the user config" &&
    [ "$user_config" = "$REIN_XDG_BASE/rein/config" ]; then
    return 0
  fi
  printf -v REIN_LINEAGE_GLOBAL_OPTS ' --config %s' "$(rein_shell_quote "$user_config")"
  return 0
}

# A single line that runs the `config` verb, pasted and run verbatim (filled in using the
# naming above).
# $1=the command's binary $2=the user config's location $3=target cwd $4=literal text to append
# after `config` (e.g. `allow`, `unset handoff_path`).
# 0=assembled / 2=cannot determine how to name the lineage explicitly (reason in
# REIN_LINEAGE_ERROR)
rein_config_lineage_cmd() {
  local bin="$1" user_config="$2" cwd="$3" verb_args="$4"
  REIN_LINEAGE_CMD=""
  rein_config_lineage_opts "$user_config" || return $?
  rein_lineage_line "$bin" "$cwd" config "$verb_args"
}

# Extracts the launcher's relative path called from the hooks registry's (hooks/hooks.json)
# command. A registration takes the shape `"${CLAUDE_PLUGIN_ROOT}/<launcher>" <event>`, and
# **wrapping the first word in double quotes is mandatory**. Since the consuming side hands
# command to the shell for word-splitting, without the quotes, a plugin installed at a location
# containing a space (a distribution that placed the repository at a path with a space in it)
# would split command into separate words, and every hook would fail to fire while the install
# steps all report green (observed). **The side that reads this shared library** (`rein doctor`, the
# hook runner's selftest) has its check consolidated here so a separately held literal doesn't
# let one side pass a stale shape. That said, **one more writer looks at the same shape** --
# scripts/check.sh's plugin gate judges it independently with jq. That gate sources nothing and
# runs as a standalone check, so it cannot be folded in here -- if the checker sourced the very
# library it's checking, a broken library would take the check down with it, and there would be
# no way left to say "it's broken."
# The accepted range is deliberately different, **and wider here** -- this accepts any path
# directly under the plugin root (this function's only job is pulling the first word out of
# command; whether the location itself is legitimate is for the caller to judge -- doctor
# separately checks whether the extracted path is actually executable). The gate fixes the
# distributed registry's own location to `hooks/` (a convention check keeping it aligned with
# the official location, REIN_HOOK_LAUNCHER_RELPATH).
# Since the wider side contains the narrower one, any registration that passes the gate passes
# here too.
# 0=outputs the relative path / 1=not the expected shape (unquoted, never closed, or calling
# something else)
rein_hook_command_launcher_relpath() {
  local command="$1" rest
  # shellcheck disable=SC2016  # the literal exact form found in a registration (must not expand)
  case "$command" in
    '"${CLAUDE_PLUGIN_ROOT}/'*) ;;
    *) return 1 ;;
  esac
  rest="${command#\"\$\{CLAUDE_PLUGIN_ROOT\}/}"
  # Looks all the way through the closing quote and the whitespace that follows it (if the
  # quote were left open, where the first word ends would be undetermined, and the extracted
  # relative path would swallow the next word too). **The event name itself is not checked** --
  # the launcher already fails loud when it isn't passed, so this does not judge it a second
  # time.
  case "$rest" in
    *'" '*) ;;
    *) return 1 ;;
  esac
  rest="${rest%%\"*}"
  [ -n "$rest" ] || return 1
  printf '%s\n' "$rest"
}

# Never sleeps longer than the time remaining (a deadline-capped poll, so that overshooting by
# one polling interval never itself becomes an overshoot of the stage's own cap). The polling
# interval may be fractional, so only the integer part is compared against the remainder.
rein_sleep_capped() {
  local interval="$1" remain="$2" int
  int="${interval%%.*}"
  case "$int" in
    '' | *[!0-9]*) int=0 ;;
  esac
  if [ "$int" -ge "$remain" ]; then
    sleep "$remain"
    return 0
  fi
  sleep "$interval"
}

# An identifier that avoids collisions in a diverted file's name (a second-precision timestamp
# plus the same ID alone can still collide).
# The value is also carried in a variable: even a single $( ) (1.2 ms on this machine) is a
# fixed cost for a hook, so an interface that receives it without spawning a subshell is needed
# (one implementation, two ways to receive it).
rein_nonce() {
  printf -v REIN_NONCE '%s%s' "$$" "${RANDOM:-0}"
  printf '%s\n' "$REIN_NONCE"
}

rein_now_epoch() {
  date -u +%s
}

# A monotonic clock (integer seconds) for process-local deadlines.
# **The wall clock (rein_now_epoch) is not used for a deadline** -- a time sync, daylight
# saving, or a manual change stretches or shrinks the cap (observed: winding the clock back an
# hour mid-run stretched a 5-second cap to effectively an hour, and winding it forward an hour
# reported "cannot be stopped" without ever waiting out the cap).
# **A comparison against a value on disk (mtime, a persisted timestamp, a freshness check) still
# uses the wall clock** -- a monotonic clock's origin differs per process, so a writer and a
# reader in different processes cannot compare their values.
# The tool is already a prerequisite, perl (`rein_check_prerequisites` confirms it alongside
# alarm), and the same clock is already used by the selftest supervisor -- this adds no new
# external dependency.
rein_now_monotonic() {
  perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC \
    -e 'printf "%d\n", clock_gettime(CLOCK_MONOTONIC)'
}

rein_iso_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

rein_iso_stamp_for_filename() {
  date -u +%Y%m%dT%H%M%SZ
}

# Accepts only the contract's timestamp format (UTC, second precision). Silently accepting any
# other format would defeat freshness validation across the board.
# **This spawns no external command** (pure arithmetic): the conversion sits on a path a hook
# runs through on every tool invocation, and a single fork (around 12 ms on this machine) would
# become experienced latency by itself. Using BSD's date -j -f is not a strict parser either
# (trailing garbage passes with only a warning, and 2/30 passes as 3/2 -- observed), so calendar
# validity is checked here. The day count uses the standard civil-to-days formula (counting a
# year that starts in March).
# The conversion result is cross-checked exhaustively by selftest, which uses `date -j -f` as
# the answer key.
rein_iso_to_epoch() {
  local iso="$1" year month day hour minute second days era yoe doy doe shifted max_day
  case "$iso" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    *) return 1 ;;
  esac
  # Without the 10# prefix, 08 / 09 would fail as an invalid octal digit.
  year=$((10#${iso:0:4}))
  month=$((10#${iso:5:2}))
  day=$((10#${iso:8:2}))
  hour=$((10#${iso:11:2}))
  minute=$((10#${iso:14:2}))
  second=$((10#${iso:17:2}))
  if [ "$month" -lt 1 ] || [ "$month" -gt 12 ] || [ "$day" -lt 1 ] ||
    [ "$hour" -gt 23 ] || [ "$minute" -gt 59 ] || [ "$second" -gt 59 ]; then
    return 1
  fi
  case "$month" in
    4 | 6 | 9 | 11) max_day=30 ;;
    2)
      max_day=28
      if [ $((year % 4)) -eq 0 ] && { [ $((year % 100)) -ne 0 ] || [ $((year % 400)) -eq 0 ]; }; then
        max_day=29
      fi
      ;;
    *) max_day=31 ;;
  esac
  [ "$day" -le "$max_day" ] || return 1
  # Re-anchoring the year to start in March moves the leap day to the year's end, letting the
  # day-count formula be written without a branch.
  shifted="$year"
  if [ "$month" -le 2 ]; then
    shifted=$((year - 1))
  fi
  era=$((shifted / 400))
  yoe=$((shifted - era * 400))
  if [ "$month" -gt 2 ]; then
    doy=$(((153 * (month - 3) + 2) / 5 + day - 1))
  else
    doy=$(((153 * (month + 9) + 2) / 5 + day - 1))
  fi
  doe=$((yoe * 365 + yoe / 4 - yoe / 100 + doy))
  days=$((era * 146097 + doe - 719468))
  # The value is also carried in a variable (an interface that receives it without spawning
  # $( ) -- one fewer fixed cost per hook invocation).
  REIN_ISO_EPOCH=$((days * 86400 + hour * 3600 + minute * 60 + second))
  printf '%s\n' "$REIN_ISO_EPOCH"
}

rein_mtime() {
  stat -f %m "$1" 2>/dev/null
}

rein_file_size() {
  stat -f %z "$1" 2>/dev/null
}

# Seconds within which a child (subagent) still counts as "may be running." A record touched
# within this window counts as live; anything older is treated as gone.
# mtime is the time of the last write, not liveness itself, so it is **never the primary
# evidence** -- the primary evidence is the Stop payload's background_tasks on the hook side, and
# the children ledger on the `rein request` side. This constant is only ever the expiry cutoff on
# top of that.
# The value matches the subagent silence threshold that delegation monitoring settled on from
# observation. **One constant for both readers** -- the hook's fallback judgment and the handover
# request's refusal have to expire a child at the same moment, or a handover would be refused by
# one and allowed by the other for the same child.
REIN_CHILD_ACTIVE_SEC=900

# Where a child's own record lives: `<transcript location>/<session_id>/subagents/` (observed).
# The layout is assembled in this one place, because the side that records a child (the hooks
# wired to SubagentStart) and the side that falls back to scanning the location (Stop, when the
# payload carries no evidence) would otherwise each spell it out.
rein_child_records_dir() {
  local transcript="$1" session_id="$2"
  [ -n "$transcript" ] || return 1
  printf '%s/%s/subagents\n' "${transcript%/*}" "$session_id"
}

# One child's record file inside that location.
rein_child_record_path() {
  local dir
  dir="$(rein_child_records_dir "$1" "$2")" || return 1
  printf '%s/agent-%s.jsonl\n' "$dir" "$3"
}

# The expiry judgment, shared by both readers. `latest` is the newest evidence of activity for
# that child (a record's mtime, or the moment it was registered). A non-numeric or empty value is
# **not** treated as fresh -- there is nothing to measure against.
# 0 = still counts as running / 1 = expired
rein_child_active_at() {
  local latest="$1" now="$2"
  case "$latest" in
    '' | *[!0-9]*) return 1 ;;
  esac
  case "$now" in
    '' | *[!0-9]*) return 1 ;;
  esac
  [ "$((now - latest))" -le "$REIN_CHILD_ACTIVE_SEC" ]
}

# Pulls one human-readable line out of some output (the last non-blank line; an overlong line
# is truncated). Since a failure reason ends up in the handover log's detail field, the cause
# string is cleaned up here rather than discarded.
rein_last_line() {
  printf '%s\n' "$1" | awk 'NF > 0 { last = $0 } END { if (length(last) > 200) last = substr(last, 1, 200); print last }'
}

# Where an external command's stderr is collected. Since the call happens inside `$( )`, a
# variable assigned there never reaches the parent, so the reason is carried back through a
# process-local temp file instead.
# If one is already open, it is not reopened (one process can go through location resolution
# twice -- `rein init` running doctor at the end is one such path -- and reopening would drop
# the previous temp file out of cleanup's reach).
rein_open_error_sink() {
  if [ -n "$REIN_ERR_FILE" ] && [ -f "$REIN_ERR_FILE" ]; then
    return 0
  fi
  REIN_ERR_FILE="$(mktemp "${TMPDIR:-/tmp}/rein-stderr.XXXXXX")" || return 1
  return 0
}

rein_close_error_sink() {
  [ -n "$REIN_ERR_FILE" ] || return 0
  rm -f "$REIN_ERR_FILE"
  REIN_ERR_FILE=""
}

rein_last_error() {
  [ -n "$REIN_ERR_FILE" ] || return 0
  rein_last_line "$(cat "$REIN_ERR_FILE" 2>/dev/null)"
}

# Runs an external command with a cap. BSD has no timeout(1), so this arms an alarm with the
# perl that ships standard on macOS. Exceeding the cap is rc=142 (the same value as the exit
# code for being killed by SIGALRM -- this observation is kept as-is).
#
# **The command never replaces this process (no exec); a forked child is launched in its own
# dedicated process group instead.** If exec replaced this process and armed alarm on itself,
# the timeout signal would only ever reach **the one process that got replaced** -- and on a
# machine where that command leaves a child behind (going through a wrapper script that doesn't
# exec `claude`, or one that forks off into a background service at launch), a grandchild
# survives. Since the grandchild inherits standard output, the caller's command substitution
# (`$( )`) **waits until the pipe closes**, never returning even past the cap.
# Observed (a fake `claude` in place, calling `rein_list_agents` with `CMD_TIMEOUT_SEC=2`):
# `exec /bin/sleep 30` (the replacing form) returns in 8.45 seconds, while
# `#!/usr/bin/env bash` + `/bin/sleep 30` (the non-replacing form) never returns in 92.16
# seconds (30x3+2), and the grandchild kept running even after the parent died at the cap.
# An unattended watcher's cycle stalls right there -- the heartbeat never updates, and all that
# rings is "the watcher may have stopped," while **handover itself can no longer happen at
# all**.
# So the child is made the leader of its own group with `setpgid(0, 0)`, and a timeout takes
# down the whole group (how it's shot is described below). Since the pipe closes all the way
# down to the grandchild, a caller that captures output via command substitution
# (`rein_list_agents`, `rein_notify`) also returns at the cap.
# **A run that finishes normally never sends a single signal** -- something only gets shot on a
# timeout, or during the signal forwarding described below.
# **Outside this guarantee**: if a descendant starts its own new session (`setsid`) and steps
# outside the group, the signal never reaches it. The capped runner itself is still guaranteed
# to return at the cap thanks to the reaping loop below, but if the escaped descendant is still
# holding standard output, a caller capturing via command substitution is still made to wait
# (observed: with a fake command whose grandchild calls `setsid` and holds standard output, even
# a 2-second cap left the caller waiting 12.44 seconds -- until the grandchild itself finished).
#
# **The parent forwards any INT / TERM / HUP / QUIT it receives to the child's group.** A child
# moved into its own dedicated group no longer receives a terminal signal (Ctrl-C) directly, so
# without forwarding, only the parent would die while the child was left behind (back when exec
# was used, the command itself received these directly -- this keeps that behavior matched).
#
# The meaning of the exit code is kept the same as it was under exec: a normal exit keeps its
# own value, dying by a signal is 128+number, a timeout is 142, and **127 if the command could
# not even be launched**. The last case is explicitly caught because perl's `exec` merely
# returns false on failure without ending the program (if the last statement were `exec`, **not
# a single command would ever run, yet rc=0**). A path that uses that rc directly as
# success/failure (`rein init`'s plugin activation, `rein prune -s -f`'s session deletion) would
# then report "activated" / "deleted" -- **failure reported as success** -- on a machine with no
# `claude` on PATH. The reason is also written to stderr as one line, landing in the failure
# reason text (rein_command_failure_detail). 127 is the conventional value for "command not
# found," and this is reused for a fork failure too, since that is likewise "could not be
# launched." 125 marks a case where the wait itself broke in some unaccountable way (the same
# value the supervisor uses).
#
# **A single child also gets the same signal sent to it at the same moment the group gets
# KILL**, so that on a machine where `setpgid` failed to take effect for whatever reason, "no
# such group exists" doesn't leave every single one unshot and the cap silently defeated (on a
# machine where it did take effect, this is a harmless second delivery to an already-dying
# child).
#
# **Ends with one KILL, no TERM grace period** (the selftest supervisor uses TERM -> grace ->
# KILL, but this takes a different shape). The reason is that the cap is **material for a larger
# composition** -- one enumeration call's worst case, assembled by
# `rein_list_agents_worst_sec`, and the seat's watchdog threshold (`watchdog_limit_sec`), which
# adds that up three times, both rest on the guarantee that "using the cap in full never rings
# the alarm." Adding a grace period would push the real elapsed time past the composed value by
# that grace period on every single call, bringing back a false alarm in the middle of a
# perfectly normal re-measurement. From the perspective of whatever gets shot, a timeout back
# when exec plus alarm was used was SIGALRM's default action anyway (an immediate death with no
# cleanup), so having no grace period is not a change from before.
#
# **A child's exit is awaited with a `WNOHANG` reaping loop, not a blocking `waitpid`** (the
# same shape as the selftest supervisor). A blocking `waitpid` cannot be interrupted by SIGALRM
# -- the handler itself still fires right on schedule, but perl **re-arms the interrupted wait
# internally**, so the wait only ever returns once the child finishes on its own (observed: with
# a 2-second cap and a child that sleeps 10 seconds, `ALRM at 2.00` / `waitpid returned at
# 10.01`. Left in that shape, capping a 30-second-sleeping command at 2 seconds returns rc=0
# after the full 30.08 seconds, never once entering the timeout branch -- the cap is defeated
# entirely). With a loop instead, the very next check after the flag is raised always sees the
# timeout. **Not making "returning at the cap" depend on the child's death** is the other reason
# for the loop -- once something has been shot, this steps down without waiting further.
REIN_RUN_LIMITED_POLL_SEC=0.02
rein_run_limited() {
  local limit="$1"
  shift
  perl -e '
    use POSIX ();
    use Time::HiRes ();
    my $limit = shift;
    my $poll = shift;
    my $timeout_rc = shift;
    my $pid = fork();
    if (!defined $pid) {
      print STDERR "fork failed: $ARGV[0]: $!\n";
      exit 127;
    }
    if ($pid == 0) {
      POSIX::setpgid(0, 0);
      exec @ARGV;
      print STDERR "exec failed: $ARGV[0]: $!\n";
      POSIX::_exit(127);
    }
    POSIX::setpgid($pid, $pid);
    my $timed_out = 0;
    $SIG{ALRM} = sub { $timed_out = 1 };
    for my $name (qw(INT TERM HUP QUIT)) {
      $SIG{$name} = sub { kill($_[0], -$pid); kill($_[0], $pid) };
    }
    alarm $limit;
    my $status;
    while (1) {
      my $reaped = waitpid($pid, POSIX::WNOHANG());
      if ($reaped == $pid) { $status = $?; last }
      if ($timed_out) {
        alarm 0;
        kill(q(KILL), -$pid);
        kill(q(KILL), $pid);
        exit $timeout_rc;
      }
      exit 125 if $reaped < 0;
      Time::HiRes::sleep($poll);
    }
    alarm 0;
    exit POSIX::WEXITSTATUS($status) if POSIX::WIFEXITED($status);
    exit 128 + POSIX::WTERMSIG($status) if POSIX::WIFSIGNALED($status);
    exit 125;
  ' "$limit" "$REIN_RUN_LIMITED_POLL_SEC" "$REIN_TIMEOUT_RC" "$@"
}

# Actually runs the capped runner once to check **whether it works on this machine** (whether
# perl's alarm is usable). There are two consumers of the answer (the prerequisite check that
# refuses to launch, and the notification path that decides whether to give up on the cap), so
# the measurement is kept in this one place -- if the writer split apart, "the condition that
# refuses to launch" and "the condition that gives up on the cap" would drift apart, and the
# path that tells the user why it's being refused would end up silently vanishing.
# **The result is not remembered**, because carrying a cached value around risks "the machine it
# was measured on" and "the machine it's used on" drifting apart (re-measuring on every launch
# is the prerequisite check's whole job). This is only ever called at launch and at notification
# time, neither of which sits inside a cycle.
rein_limiter_usable() {
  rein_run_limited 5 true >/dev/null 2>&1
}

# Assembles the env vars dropped at the boundary of launching a session, as an `env` argument
# list. The target is **every single one in the REIN_ namespace**, and the names are collected
# mechanically from **the environment at that moment** (no fixed enumeration is kept, so a new
# config key never creates dual bookkeeping -- both the config layer's env names
# (`REIN_<KEY-IN-CAPS>`) and non-config REIN_* interfaces -- lineage overrides, substitution
# points -- get dropped together).
# Why this drops them: a background session's hook inherits its environment from the shared
# background service (observed), so launching with a lineage's own values (locations,
# thresholds) still set would leave those values behind in every background session from that
# generation onward (a hook running while still pointed at a different lineage's location, or a
# threshold taking effect on a generation it was never meant for).
# A managed session's context travels through the launch settings' `env` (REIN_MANAGED_*)
# instead, so dropping everything here does not break the successor's own resolution.
REIN_ENV_DROP_ARGS=()
rein_env_drop_args() {
  local name
  REIN_ENV_DROP_ARGS=()
  while IFS= read -r name; do
    case "$name" in
      REIN_*) REIN_ENV_DROP_ARGS+=(-u "$name") ;;
    esac
  done < <(compgen -e)
  return 0
}

# Runs with a cap and drops stderr into the sink (so a failure reason lands in detail and the
# handover log).
rein_run_capture() {
  local limit="$1"
  shift
  if [ -n "$REIN_ERR_FILE" ]; then
    : >"$REIN_ERR_FILE"
    rein_run_limited "$limit" "$@" 2>"$REIN_ERR_FILE" </dev/null
    return $?
  fi
  rein_run_limited "$limit" "$@" </dev/null
}

# The reason text for when enumeration could not be read. Kept in one place so the watcher and
# the attach loop never drift into different wording.
rein_list_agents_error() {
  local last
  last="$(rein_last_error)"
  if [ -n "$last" ]; then
    printf 'cannot read claude agents --json: %s' "$last"
    return 0
  fi
  printf 'cannot read claude agents --json'
}

# The reason text for a failed external command (exit code plus stderr's last line).
rein_command_failure_detail() {
  local rc="$1" last suffix=""
  last="$(rein_last_error)"
  if [ -n "$last" ]; then
    printf -v suffix ' output=%s' "$last"
  fi
  if [ "$rc" -eq "$REIN_TIMEOUT_RC" ]; then
    printf 'rc=%s (exceeded the %s-second cap)%s' "$rc" "$CMD_TIMEOUT_SEC" "$suffix"
    return 0
  fi
  printf 'rc=%s%s' "$rc" "$suffix"
}

# Records the check result for one prerequisite tool. **The tool name's writer is consolidated
# into this one place**, so a tool that was looked at lands in REIN_PREREQUISITE_TOOLS
# regardless of the result, and only a missing one lands in REIN_MISSING_TOOLS -- making it
# impossible to check a tool and then forget to add it to the list (the cause behind the
# diagnostic's OK line once dropping `ps` was that it kept a second, hand-written writer of tool
# names separate from the set actually looked at).
# The second argument is the check's exit code (0=works).
rein_prereq_record() {
  local name="$1" check_rc="$2"
  REIN_PREREQUISITE_TOOLS="${REIN_PREREQUISITE_TOOLS} ${name}"
  [ "$check_rc" -eq 0 ] || REIN_MISSING_TOOLS="${REIN_MISSING_TOOLS} ${name}"
  return 0
}

# The runtime prerequisite-tool check. Applies the same discipline as check.sh's require_tool
# to the production path too (without it, freshness validation would reject every marker for
# the wrong reason, such as "the JSON is broken," when a tool is simply missing).
# This checks whether it works, not whether it exists: the GNU versions of date/stat can sit
# on PATH without ever having -j / -f.
# A missing tool goes into REIN_MISSING_TOOLS and this returns 1. The list of tools looked at
# (every one, regardless of whether it was missing) is kept in REIN_PREREQUISITE_TOOLS -- so the
# diagnostic's OK line and FAIL line read from the same source material.
rein_check_prerequisites() {
  local probe_file="$1" mtime rc
  REIN_MISSING_TOOLS=""
  REIN_PREREQUISITE_TOOLS=""
  printf '%s' '{}' | jq -e . >/dev/null 2>&1
  rein_prereq_record jq $?
  # This checks **the shape actually depended on** (epoch -> the contract's timestamp format).
  # Since ISO -> epoch is now solved by arithmetic, that direction no longer surfaces a
  # difference between date implementations -- this check is kept so a GNU version can still be
  # caught here.
  rc=1
  [ "$(TZ=UTC date -u -r 1577836800 +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" = '2020-01-01T00:00:00Z' ] && rc=0
  rein_prereq_record 'date(-r:BSD)' "$rc"
  mtime="$(rein_mtime "$probe_file")"
  rc=0
  case "$mtime" in
    '' | *[!0-9]*) rc=1 ;;
  esac
  rein_prereq_record 'stat(-f)' "$rc"
  rein_limiter_usable
  rein_prereq_record 'perl(alarm)' $?
  # A process-local deadline is measured with this clock. Under a perl that can't be read, the
  # deadline's value would come out empty, `$(( + cap ))` would collapse to just the cap, and
  # every wait would be cut short on its very first pass (the cap silently disappearing). This
  # missing tool is instead surfaced at launch time.
  rc=0
  case "$(rein_now_monotonic 2>/dev/null)" in
    '' | *[!0-9]*) rc=1 ;;
  esac
  rein_prereq_record 'perl(CLOCK_MONOTONIC)' "$rc"
  # A lineage's key (the runtime directory's name) is built from this, so if it's missing, the
  # location itself cannot be resolved at all. Before this was added to the check, that failed
  # with the unrelated reason "cannot resolve the location for runtime data" (surfacing the
  # missing tool is what fail-loud requires -- naming exactly which tool is missing).
  rc=1
  case "$(printf '%s' rein | shasum -a 256 2>/dev/null)" in
    [0-9a-f][0-9a-f]*) rc=0 ;;
  esac
  rein_prereq_record shasum "$rc"
  # This is the one place liveness gets judged. Under a `ps` that never answers, there is no
  # material left to tell "not there" apart from "cannot be confirmed," and every single lock
  # fails toward "don't seize it," stalling the lineage (safer than failing toward seizing it,
  # but stuck with the cause never visible). Whether it works is judged by **whether it can see
  # itself**.
  rc=0
  rein_pid_alive $$ || rc=1
  rein_prereq_record ps "$rc"
  # The lineage token is drawn through this (`od -An -v -tx1 -N32 /dev/urandom | tr -d ' \n'`),
  # and a draw that comes out short or non-hex is refused rather than padded -- so on a machine
  # where this doesn't work, provisioning a lineage fails with "cannot draw a lineage token"
  # while every hook of every session of that lineage fails loud on the missing token. Naming
  # the tool at install / launch / diagnostics time is what keeps that from being read as
  # "rein is broken."
  # **What's checked is the whole shape the draw depends on** -- the flags and the device
  # together -- in miniature (4 bytes -> 8 hex characters), not merely whether the command
  # exists: an `od` that doesn't take `-tx1`, and a machine with no readable /dev/urandom, both
  # end here rather than at the draw.
  rc=1
  case "$(od -An -v -tx1 -N4 /dev/urandom 2>/dev/null | tr -d ' \n')" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) rc=0 ;;
  esac
  rein_prereq_record od "$rc"
  REIN_PREREQUISITE_TOOLS="${REIN_PREREQUISITE_TOOLS# }"
  if [ -n "$REIN_MISSING_TOOLS" ]; then
    REIN_MISSING_TOOLS="${REIN_MISSING_TOOLS# }"
    return 1
  fi
  return 0
}

# Zero-padding (`08`, `007`) is **not accepted**. `[`'s integer comparison reads in base 10, so
# it passes the type check, but arithmetic evaluation (`$(( ))`) reads a leading 0 as octal
# (observed on bash 3.2.57: `v=08; echo $((1 + v))` -> `08: value too great for base`). Accepting
# it would let `rein config set cmd_timeout_sec 08` get written, and a later stage (`rein up`'s
# deadline arithmetic) would then fail **for a reason that reads as unrelated to the configured
# value**. This is rejected by type rather than normalized on the value side, so that a setting,
# once written, never later changes meaning (the value shown is always the value in effect).
rein_is_nonneg_int() {
  case "${1:-}" in
    '' | *[!0-9]*)
      return 1
      ;;
    0)
      return 0
      ;;
    0*)
      return 1
      ;;
  esac
  return 0
}

rein_is_pos_int() {
  rein_is_nonneg_int "${1:-}" || return 1
  [ "$1" -gt 0 ]
}

# Only a polling interval accepts a fraction (a value handed straight to sleep -- checks use
# 0.2 seconds).
rein_is_pos_number() {
  local value="${1:-}" int frac
  case "$value" in
    '' | *[!0-9.]*)
      return 1
      ;;
    *.*.*)
      return 1
      ;;
    *.*)
      int="${value%%.*}"
      frac="${value#*.}"
      ;;
    *)
      int="$value"
      frac=""
      ;;
  esac
  case "${int}${frac}" in
    *[1-9]*)
      return 0
      ;;
  esac
  return 1
}

# Validates a numeric setting. An invalid value would silently fall into sleep returning
# instantly (a loop that never waits) or an unbounded wait, so this rejects it by type at
# launch. If invalid, REIN_INVALID_VALUE is set to "name=value (expected type)" and this
# returns 1.
rein_validate_number() {
  local name="$1" value="$2" kind="$3" shown
  shown="$value"
  if [ -z "$shown" ]; then
    shown="(empty)"
  fi
  case "$kind" in
    nonneg-int)
      rein_is_nonneg_int "$value" && return 0
      ;;
    pos-int)
      rein_is_pos_int "$value" && return 0
      ;;
    pos-number)
      rein_is_pos_number "$value" && return 0
      ;;
  esac
  printf -v REIN_INVALID_VALUE '%s=%s (expected: %s)' "$name" "$shown" "$kind"
  return 1
}

# Redacts a secret (a `settings` effective value) that ended up mixed into a reason text. Since
# a reason text carries an external command's stderr last line verbatim, if `claude` is handed a
# malformed `--settings` and spits out an error carrying the value, JSON that can contain
# credentials would land in the handover log (the canonical audit trail) and in a GUI
# notification. This lives in the shared library so the redaction discipline isn't written
# differently by each reader.
rein_redact_settings() {
  local text="$1" secret="${2:-}"
  if [ -n "$secret" ]; then
    text="${text//"$secret"/***}"
  fi
  printf '%s' "$text"
}

# Whether the organization managed settings **force a different value** for background
# session isolation. Under an environment that forces it, the `worktree.bgIsolation=none` rein
# layers into its launch settings never takes effect, and a successor branches off into a
# different tree (this is never quietly rounded away -- if it's forced, this fails before
# launch).
# **This can only speak to whether it's being forced when** the managed settings file can be
# read and a value is written in it (the priority order itself cannot be confirmed from outside
# -- stated as a premise in docs/spec/runtime.md's "a background session's launch settings").
# This lives in the shared library so that **the launching side (watcher) and the diagnostic
# side (`rein up` / `rein doctor`) run through the same judgment** -- if written separately,
# only launch could fail in an environment diagnostics passed (or the other way around).
#
# **A case where the material could not be read is never folded into "not forced."** Back when
# it was, a managed settings file distributed as root:wheel 0600, one whose contents were
# broken, and a machine with no jq all passed identically as 0, the same as "no value written,
# so no conflict" -- with the fact that it could not be read never surfacing anywhere.
# What happens on 2 (cannot be determined) is left to the caller:
#   - Launch (`rein up`, the watcher) **issues a warning and launches anyway**. Since this
#     enforcement applies to Claude Code running under the same user permissions as rein, a file
#     rein cannot read is also a file Claude Code cannot read, so the enforcement itself never
#     takes effect -- refusing to launch would protect nothing extra, while producing a user who
#     cannot work simply because the managed settings happen to be broken. The only thing this
#     changes is no longer failing silently.
#   - Only diagnostics (`rein doctor`) fails toward not-green (a case that cannot be determined
#     is never called OK).
# 0=no problem (including the file not existing) / 1=forcing a different value / 2=cannot be
# determined (the reason for both 1 and 2 is REIN_MANAGED_POLICY_ERROR)
REIN_MANAGED_POLICY_ERROR=""
REIN_MANAGED_POLICY_FILE_DEFAULT="/Library/Application Support/ClaudeCode/managed-settings.json"
rein_managed_policy_conflicts() {
  local file="${REIN_MANAGED_SETTINGS_POLICY:-$REIN_MANAGED_POLICY_FILE_DEFAULT}"
  local value="" undecidable=""
  REIN_MANAGED_POLICY_ERROR=""
  [ -f "$file" ] || return 0
  # The value is only extracted after confirming inside jq that it is an object. Reading
  # `.worktree.bgIsolation` bare would let broken JSON and an array alike get discarded as jq's
  # non-zero exit, coming out as the same empty string as "no value" (exactly the folding this
  # avoids). Going through `// ""` means an object simply missing the key does not trip
  # `jq -e`'s false/null check, and returns 0.
  # The contents are never placed in the reason text (managed settings can contain keys holding
  # secrets -- only its location is placed there).
  if [ ! -r "$file" ]; then
    undecidable='cannot be read (no read permission)'
  elif ! value="$(jq -er 'if type == "object" then (.worktree.bgIsolation // "") else error("not an object") end' "$file" 2>/dev/null)"; then
    undecidable='cannot be parsed as a JSON object'
  fi
  if [ -n "$undecidable" ]; then
    printf -v REIN_MANAGED_POLICY_ERROR 'the managed settings for this organization %s (cannot determine whether it forces background-session isolation; if it does, a successor edits outside this tree): %s' \
      "$undecidable" "$file"
    return 2
  fi
  [ -n "$value" ] || return 0
  [ "$value" = "none" ] && return 0
  printf -v REIN_MANAGED_POLICY_ERROR 'the managed settings for this organization force background-session isolation to %s (%s). Not launching, since a successor would edit outside this tree under this state' \
    "$value" "$file"
  return 1
}

# A failure always goes to stderr too. There is no way to confirm a GUI notification actually
# arrived, so nothing relies on it alone. To keep the notification path itself from failing
# silently, osascript being absent or failing is also written to stderr.
#
# REIN_NOTIFY_SILENT=1 stops only the GUI notification (the one line to stderr always still
# goes out). An interface letting checks avoid putting a notification on the user's screen,
# without changing what a notification means -- the observation point for "a notification went
# out" already lived on the stderr side, and that side is untouched.
#
# **osascript is also called with a cap.** This is the one place that spawns an external process
# through a plain command substitution, sitting outside the scope of "a call that never returns
# becomes a permanent stall under unattended operation" stated above (REIN_CMD_TIMEOUT_SEC's
# intent) -- the caller here runs **inside the watcher's and the seat's cycle**, so on a machine
# with no GUI session or an unresponsive Notification Center, osascript never returning would
# stall the heartbeat update along with it (silently killing the core feature of handing over
# to a successor unattended).
# This cap is kept separate from config's cmd_timeout_sec because it isn't an operational
# parameter the user tunes; it's internal slack against an external command's jitter (treated
# the same as REIN_AGENTS_PROBE_ATTEMPTS). The value leaves ample margin over the observed
# figure (osascript launches in 0.042 seconds), while staying short as a cap meant to stop a
# cycle.
#
# **On a machine where the capping mechanism itself doesn't work, the notification still goes
# out, giving up on the cap.** Since the capped runner is implemented with perl's alarm, on a
# machine where perl doesn't work, a capped call would fail without ever spawning osascript even
# once -- the notification would vanish entirely. The scenario this matters most for is exactly
# "not launching because a prerequisite tool is missing," when the missing tool is perl itself
# -- **nothing would ever reach the person meant to be told** (an unattended watcher has no
# terminal, so the one stderr line is no substitute). Giving up on the cap does not stall the
# cycle: a machine where the capped runner doesn't work is also one where the prerequisite check
# (perl(alarm)) refuses to launch at all, so this path is only ever taken **once, on the way
# down** -- the watcher's / seat's cycle never even started. Giving up on the cap still leaves
# one line on stderr (never silently dropping the cap).
REIN_NOTIFY_TIMEOUT_SEC=10
rein_notify() {
  local title="$1" message="$2" out rc
  local -a limit=()
  printf '%s: %s\n' "$title" "$message" >&2
  if [ "${REIN_NOTIFY_SILENT:-0}" = "1" ]; then
    return 0
  fi
  if ! command -v osascript >/dev/null 2>&1; then
    printf 'rein: no osascript, cannot show a GUI notification\n' >&2
    return 0
  fi
  if rein_limiter_usable; then
    limit=(rein_run_limited "$REIN_NOTIFY_TIMEOUT_SEC")
  else
    printf 'rein: the capping mechanism (perl alarm) does not work, showing the GUI notification with no cap\n' >&2
  fi
  out="$(${limit[@]+"${limit[@]}"} osascript \
    -e 'on run argv' \
    -e 'display notification (item 1 of argv) with title (item 2 of argv)' \
    -e 'end run' \
    -- "$message" "$title" 2>&1)"
  rc=$?
  [ "$rc" -eq 0 ] && return 0
  # A cutoff gets a reason text separate from a failure (`rc=142` alone cannot tell "a machine
  # that cannot show a notification" apart from "a machine where the notification path is
  # stuck" -- the latter is an anomaly in the machine itself, so it is named explicitly).
  if [ "$rc" -eq "$REIN_TIMEOUT_RC" ]; then
    printf 'rein: cut off the GUI notification after %s seconds with no response (the notification path is not responding)\n' \
      "$REIN_NOTIFY_TIMEOUT_SEC" >&2
    return 0
  fi
  printf 'rein: GUI notification failed: %s\n' "$(rein_last_line "$out")" >&2
  return 0
}

# Whether something is a shape that can be accepted as a write target -- **absent, or a regular
# file**. The reason is returned via a variable (where printf sends it is left to the caller,
# since this sits at a layer with no single fixed place to print a reason).
# **Consolidated into this one place** because if the writers for replacement (mv), append
# (>>), and delete (rm) each carried their own shape check, the same one discipline would split
# across as many copies as there are writers.
# A symlink is rejected because following it writes to something other than the requested
# pathname, and not following it deletes the link itself (neither matches what the caller
# intended). The same goes for a broken symlink -- both `>>` and `mv` would **create its
# target**.
# A different process under the same UID actively swapping the pathname between the check and
# the write is outside this guarantee -- this only closes off a normal write and an anomalous
# filesystem shape.
REIN_DEST_SHAPE=""
REIN_DEST_SHAPE_ERROR=""
rein_dest_shape_ok() {
  local dest="$1"
  REIN_DEST_SHAPE=""
  REIN_DEST_SHAPE_ERROR=""
  if [ -L "$dest" ]; then
    REIN_DEST_SHAPE="a symbolic link"
  elif [ -d "$dest" ]; then
    REIN_DEST_SHAPE="a directory"
  elif [ -e "$dest" ] && [ ! -f "$dest" ]; then
    REIN_DEST_SHAPE="not a regular file"
  else
    return 0
  fi
  printf -v REIN_DEST_SHAPE_ERROR 'the write target is not a regular file (%s): %s' \
    "$REIN_DEST_SHAPE" "$dest"
  return 1
}

# Whether a value is a shape that can be accepted as an externally-sourced `session_id`
# (rejects a path separator and whitespace).
# **Consolidated into this one place** because a check written per entry point against the same
# risk leaves exactly the entry point nobody wrote it for wide open -- in practice, only the
# hook's standard input was closed off this way, while the writer command and the watcher's
# freshness validation (R3) let a separator straight through.
# By contract, `session_id` is opaque (not guaranteed to be a UUID), so the shape check is kept
# to these two things. The reason is returned via a variable (where it goes is up to the caller
# -- a hook dies immediately, R3 uses it as the rejection reason, a writer sends it to stderr).
REIN_SESSION_ID_ERROR=""
rein_session_id_shape_ok() {
  local id="$1" subject="$2"
  REIN_SESSION_ID_ERROR=""
  case "$id" in
    */* | *[[:space:]]*) ;;
    *) return 0 ;;
  esac
  printf -v REIN_SESSION_ID_ERROR '%s cannot contain a path separator or whitespace: %s' "$subject" "$id"
  return 1
}

# Assembles one record line (JSON Lines, append-only, never truncated). Only this one place
# holds the column convention -- if the handover log and the seat log each assembled the same
# columns separately, one growing a column without the other would split readers apart.
rein_log_line() {
  local log_file="$1" schema="$2" event="$3" detail="$4"
  local generation="${5:-}" predecessor="${6:-}" successor="${7:-}"
  local dir
  # The path that can create the location is **closed to just one**. A plain `mkdir -p` (a)
  # never places a `*`-only `.gitignore`, so a freshly created `.rein/` shows up as untracked
  # files in the user's working tree, and (b) passes silently through a symlink shape at the
  # location, so records get written out through the target (which can sit outside the
  # project). Going through the one function that prepares it means the records-location
  # discipline never splits across as many copies as there are writers.
  # The split is done with string operations (spawning no external command -- a relative name
  # with no separator is `.`).
  dir="${log_file%/*}"
  [ "$dir" != "$log_file" ] || dir="."
  rein_ensure_records_dir "$dir" || return 1
  # Since appending uses `>>`, a symlink would grow its target (which can sit outside the
  # project) while the caller reads it as success. The same shape check the replace-writer uses
  # runs here too.
  if ! rein_dest_shape_ok "$log_file"; then
    printf 'rein: %s\n' "$REIN_DEST_SHAPE_ERROR" >&2
    return 1
  fi
  jq -nc \
    --arg schema "$schema" \
    --arg ts "$(rein_iso_now)" \
    --arg event "$event" \
    --arg detail "$detail" \
    --arg generation "$generation" \
    --arg predecessor "$predecessor" \
    --arg successor "$successor" \
    '{
      schema: $schema,
      ts: $ts,
      event: $event,
      detail: $detail,
      generation: (if $generation == "" then null else ($generation | tonumber) end),
      predecessor_session_id: (if $predecessor == "" then null else $predecessor end),
      successor_session_id: (if $successor == "" then null else $successor end)
    }' >>"$log_file"
}

rein_log_event() {
  rein_log_line "$1" "$REIN_LOG_SCHEMA" "$2" "$3" "${4:-}" "${5:-}" "${6:-}"
}

# The seat log. **Failing to write it never brings the caller down** (a log is an observation;
# it never outranks keeping the user's seat itself). The failure to write is itself left as one
# line on stderr (never silently dropped).
# The session in question goes into successor_session_id (to keep the column convention as one
# with the handover log; a seat's row is never a transition, so predecessor is always null).
rein_seat_log_event() {
  local log_file="$1" event="$2" detail="$3" generation="${4:-}" session="${5:-}"
  [ -n "$log_file" ] || return 0
  if ! rein_log_line "$log_file" "$REIN_SEAT_LOG_SCHEMA" "$event" "$detail" \
    "$generation" "" "$session" 2>/dev/null; then
    printf 'rein: cannot write to the seat log (the seat keeps going): %s\n' "$log_file" >&2
  fi
  return 0
}

# Replaces via a temp file in the same directory, so a reader never catches something
# half-written. The replacement target is **restricted to a regular file only**. If the
# destination is a directory, `mv` moves the temp file **inside it** and returns 0, so without a
# shape check, the payload can land at `<dest>/<basename>.<nonce>` while the caller still reads
# success -- since a reader reads `<dest>` as JSON, nobody ever sees that nothing was actually
# written (a false success). A symlink is rejected too: following it writes to something other
# than the requested target pathname, and replacing without following it deletes the link itself
# (neither matches what the caller intended).
# A different process under the same UID actively swapping the pathname between the check and
# `mv` is outside this guarantee -- this only closes off a normal replacement and an anomalous
# filesystem shape.
#
# **On failure, the temp file is always reclaimed.** If only a `printf` failure were reclaimed
# and an `mv` failure were not, a temp file would be left behind at the location whenever a
# replacement failed. Calls whose destination sits directly under the runtime directory really
# do exist (a handover request, a stop marker, a snooze), so a leftover means `rein prune`'s
# final `rmdir` always fails with "something rein doesn't recognize is left, not deleting," and
# that lineage can never be folded away again without the user removing it by hand.
# **What can't be reclaimed stays behind** (the process dying between mktemp and mv -- Ctrl-C,
# `rein down`, a forced sleep termination), so the temp name is given the fixed shape cleanup
# can recognize mechanically (`<dest>.rein-tmp.<nonce>`) and added to the known-runtime-artifact
# list -- even what's left behind still fails toward being foldable. With a plain `.XXXXXX`,
# there is no way to tell by name what rein created apart from something else's file that
# wandered into the location.
rein_write_json_atomic() {
  local dest="$1" content="$2" tmp dir
  # The location goes through **the one function that prepares it** (the same reason as the
  # append writer, rein_log_line). A plain `mkdir -p` (a) never places a `*`-only `.gitignore`,
  # so untracked directories show up in the user's working tree on a run that rewrites
  # `<cwd>/.rein/current.json` after the location was deleted, and (b) passes silently through a
  # symlink shape at the location, so the target (which can sit outside the project) becomes the
  # location instead. The split is done with string operations (spawning no external command --
  # a relative name with no separator is `.`).
  dir="${dest%/*}"
  [ "$dir" != "$dest" ] || dir="."
  rein_ensure_records_dir "$dir" || return 1
  if ! rein_dest_shape_ok "$dest"; then
    printf 'rein: %s\n' "$REIN_DEST_SHAPE_ERROR" >&2
    return 1
  fi
  tmp="$(mktemp "${dest}${REIN_ATOMIC_TEMP_INFIX}XXXXXX")" || return 1
  printf '%s\n' "$content" >"$tmp" || {
    rm -f "$tmp"
    return 1
  }
  mv "$tmp" "$dest" && return 0
  rm -f "$tmp"
  return 1
}

# Enumeration is used by both the watcher and the attach loop. The vocabulary for "counts as
# finished" is not held in two separate places.
# Called with a cap, and stderr is not discarded but dropped into the sink (without a reason
# left behind for "can't read it," reproducing the failure is impossible).
# **A transient failure is re-measured in this one place.** Enumeration is a capped external
# command, and it's realistic for the CLI to fail once from a temporary non-response, right
# after waking from sleep, or the like -- if that single failure made both the watcher and the
# seat step down, the guarantee behind "attach to the successor with zero action" would break
# every single time, recoverable only by the user re-running `rein up`
# by hand. Giving each reader (liveness judgment, job-ID resolution) its own resilience would
# split apart which readers tolerate it and which don't, so this is consolidated at the
# enumeration interface instead. "It could be read" is judged the same way a reader judges it
# (non-empty and valid JSON), and if it still can't be read once the cap is reached, the last
# result is simply returned as-is -- a reader's own fail-loud (its cannot-determine branch) is
# left untouched.
rein_list_agents() {
  local attempts=1 out
  while :; do
    out="$(rein_run_capture "$CMD_TIMEOUT_SEC" claude agents --json)"
    if [ -n "$out" ] && printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
      break
    fi
    [ "$attempts" -lt "$REIN_AGENTS_PROBE_ATTEMPTS" ] || break
    attempts=$((attempts + 1))
    sleep "$REIN_AGENTS_PROBE_RETRY_SEC"
  done
  printf '%s' "$out"
}

# One enumeration call's worst-case duration (seconds). **"cmd_timeout_sec per external
# command" cannot speak to this** -- the retry above stacks a capped call up to
# REIN_AGENTS_PROBE_ATTEMPTS times, sleeping REIN_AGENTS_PROBE_RETRY_SEC in between (60 seconds
# by default -> 182 seconds). If this formula were copied into the side that assembles the wait
# cap (the seat's watchdog), changing the retry constants would leave one of the two copies
# stale -- so the writer is closed to this one place. `cmd_timeout_sec` reads the same effective
# value enumeration does (the same variable rein_list_agents reads).
rein_list_agents_worst_sec() {
  printf '%s\n' "$((CMD_TIMEOUT_SEC * REIN_AGENTS_PROBE_ATTEMPTS \
    + REIN_AGENTS_PROBE_RETRY_SEC * (REIN_AGENTS_PROBE_ATTEMPTS - 1)))"
}

# Enumeration including finished background sessions (these only appear with `--all` --
# observed). Cleaning up a finished generation (`rein prune`) can only pull a short job ID from
# a finished entry.
rein_list_agents_all() {
  rein_run_capture "$CMD_TIMEOUT_SEC" claude agents --json --all
}

# Reads a lock's owner (pid) declaration. The file being absent is a normal thing to happen too
# (right after claiming a lock, or after failing to), so existence is checked first -- a
# redirect failure is written to stderr by the shell itself, so appending `2>/dev/null` alone
# would still let it pollute the caller's own output.
# 0=read successfully (to standard output) / 1=cannot read it (whether this means cannot be
# determined is left to the caller)
rein_lock_pid() {
  local file="$1/pid"
  [ -f "$file" ] || return 1
  tr -d '[:space:]' <"$file" 2>/dev/null
}

# Publishes a lock "with an owner declaration attached." With the two-step form of `mkdir` then
# writing `pid`, a lock that crashed or failed to write in between would be left as "a lock
# whose owner cannot be confirmed," and under the discipline of never seizing one (the
# contract), it would never come free no matter how much time passed (every operation after it
# stalls permanently). Writing `pid` into a staging directory and publishing it with a rename
# means **a published lock always has a pid** -- an undetermined state is never even generated
# in the first place.
# 0=claimed / 1=cannot prepare it / 2=a different owner is already there
# Additional declarations (pairs of `<name> <value>`) are written **before publishing**. Writing
# them after publishing would create a moment where the lock is published but its declarations
# are not yet complete, and a reader that hits that window treats it as "a lock whose owner
# cannot be confirmed" (under the never-seize discipline, a lock that was correctly claimed
# would then be stuck looking undetermined).
rein_claim_lock_dir() {
  local lock="$1" staging name value
  shift
  staging="$(mktemp -d "${lock}.claim.XXXXXX" 2>/dev/null)" || return 1
  if ! printf '%s\n' "$$" >"$staging/pid" 2>/dev/null; then
    rm -rf "$staging"
    return 1
  fi
  while [ $# -ge 2 ]; do
    name="$1"
    value="$2"
    shift 2
    case "$name" in
      '' | */* | *[[:space:]]*) continue ;;
    esac
    if ! printf '%s\n' "$value" >"$staging/$name" 2>/dev/null; then
      rm -rf "$staging"
      return 1
    fi
  done
  if [ -e "$lock" ]; then
    rm -rf "$staging"
    return 2
  fi
  # If it loses the race, `mv` never turns into a rename -- it lands **inside** the lock that
  # was already there. Whether it published is judged by "is the pid on whatever landed my
  # own," not the exit code.
  mv "$staging" "$lock" 2>/dev/null
  if [ "$(rein_lock_pid "$lock")" = "$$" ]; then
    return 0
  fi
  rm -rf "${lock:?}/${staging##*/}" "$staging" 2>/dev/null
  return 2
}

# Releases a lock. With the two-step form of deleting `pid` then `rmdir`, a crash between the
# two operations, or `rmdir` failing (something rein doesn't recognize sitting inside, etc.),
# would leave **a published lock with no pid** -- releasing would end up creating exactly the
# "undetermined state" that claiming closes off. Instead, the public name is removed with a
# rename first, then everything inside is deleted (once the rename succeeds, the lock is
# already gone from the public name).
# 0=released / 1=cannot release it (the caller states the reason)
rein_release_lock_dir() {
  local lock="$1" staging
  [ -e "$lock" ] || return 0
  staging="${lock}.release.$(rein_nonce)"
  if mv "$lock" "$staging" 2>/dev/null; then
    rm -rf "${staging:?}"
    return 0
  fi
  # A location where rename cannot happen offers no atomicity to keep. Rather than falling back
  # to deleting just the pid first, this returns "could not release it" (never silently leaves
  # a half-finished state).
  return 1
}

# Reads one of a lock's declared fields (anything besides pid). 1 if absent.
rein_lock_field() {
  local file="$1/$2" value=""
  [ -f "$file" ] || return 1
  IFS= read -r value <"$file" 2>/dev/null || [ -n "$value" ] || return 1
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

# A process's identity (a pid alone is not enough -- pids get reused). Its start time is
# checked alongside it.
# Reads only (this module never performs an OS process-stopping operation of any kind).
# The locale is fixed to C because lstart's month and day names get translated according to
# LANG (a hook running with LANG unset that reads a lock written by a Japanese-locale terminal
# would misjudge a live owner as stale). Since the writer and the reader both go through this
# same function, a misjudgment on a lock written before this fix is transient -- it
# self-corrects the moment that lock is rewritten by the next claim.
# The time zone is fixed to UTC for the same class of reason: lstart renders the start time in
# the **reader's** effective zone, so one live process yields two different strings whenever TZ
# differs between the claim and the liveness judgment (a machine moved across zones between the
# two, or a launchd-started watcher running with TZ unset alongside a terminal that exports one).
# Without this, that difference alone reads as "the pid was reused" -- and a live owner's lock
# would be seized, breaking the rule that only a lock confirmed to have no living owner is ever
# retaken.
rein_process_start_identity() {
  LC_ALL=C TZ=UTC ps -p "$1" -o lstart= 2>/dev/null | tr -s '[:space:]' ' '
}

# Whether a lock's owner is **actually** there right now. A live pid alone is not enough (it
# would misidentify whatever now holds a reused pid as the owner), so this cross-checks the
# start time recorded at claim time.
# A lock with no declared start time counts as unconfirmable -- this fails toward live (the
# never-seize discipline).
# 0=the owner is there / 1=not there (stale)
rein_lock_owner_alive() {
  local lock="$1" pid start recorded
  pid="$(rein_lock_pid "$lock")" || return 0
  case "$pid" in
    '' | *[!0-9]*) return 0 ;;
  esac
  rein_pid_alive "$pid"
  case $? in
    1) return 1 ;;
    # A liveness that cannot be confirmed (`ps` never answers) is not the same as "not there" --
    # this fails toward never seizing it.
    2) return 0 ;;
  esac
  recorded="$(rein_lock_field "$lock" start)" || return 0
  start="$(rein_process_start_identity "$pid")"
  [ -n "$start" ] || return 0
  [ "$start" = "$recorded" ] && return 0
  return 1
}

# Whether a published lock's owner is gone already (stale). **A lock whose pid declaration
# cannot be read fails toward "it's there"** -- a lock whose owner can't be confirmed is never
# seized
# (the same discipline the claiming side of `up` / `down` follows).
# Liveness is checked not just by pid but all the way through **the declared start time**
# (`rein_lock_owner_alive`) -- since pids get reused, judging liveness by pid alone would
# misidentify whatever now holds the reused pid as the owner, and that location's lock would
# never come free again.
# When something is judged stale, its owner's pid is kept in REIN_LOCK_STALE_PID (so the side
# that releases it can cross-check "the lock I saw was this exact pid's").
# 0=stale (safe to release) / 1=the owner is there, or cannot be determined
REIN_LOCK_STALE_PID=""
rein_lock_dir_is_stale() {
  local lock="$1" pid
  REIN_LOCK_STALE_PID=""
  pid="$(rein_lock_pid "$lock")" || return 1
  case "$pid" in
    '' | *[!0-9]*) return 1 ;;
  esac
  rein_lock_owner_alive "$lock" && return 1
  REIN_LOCK_STALE_PID="$pid"
  return 0
}

# Releases only **that specific** lock judged stale (the one whose `pid` matches). In the gap
# between checking and releasing, a different run can end up **reclaiming** that same stale
# lock, and a plain release would then strip away exactly "the live lock that was just
# reclaimed" (two runs holding the lock at once). The public name is renamed to a temp name
# first, and only then is the `pid` inside cross-checked -- since rename is atomic, only one run
# can ever divert it this way, and whichever side's cross-check comes up mismatched puts it back
# under the public name and backs off.
#
# **`pid` is read once more even before diverting it.** With only a check-after-diverting form,
# a different run could **reclaim** that same stale lock somewhere inside the window between the
# judgment (the caller's `rein_lock_dir_is_stale`) and this point -- a window wide enough, since
# several external commands sit inside it -- and that live lock would get stripped from the
# public name once. If, at that point, `[ ! -e "$lock" ]` turns out false (because a third run
# has since taken the public name), whatever was diverted **gets discarded, contents and all** --
# leaving the reclaiming run and the third run both believing, at the same time, that they hold
# the lock (the discarded side later gets a token mismatch, 2, when it tries to release, and the
# caller logs "replaced by a different run" and exits normally -- so the double ownership never
# even shows up to the user as an anomaly).
# The read just beforehand narrows this window down to "between reading and mv," and a run that
# still falls into what window remains **never discards silently** (since this operation can
# delete someone else's live lock, it always leaves one line on stderr).
# 0=released / 1=not the one this run saw -- cannot release it
rein_release_lock_dir_if_stale() {
  local lock="$1" expected="$2" staging
  [ -n "$expected" ] || return 1
  # The cross-check right before diverting it. A run that backs off here never touched the
  # public name at all -- a reclaiming run's lock is never stripped (most of the races that fall
  # into the window between the judgment and this point are excluded by this one line alone).
  [ "$(rein_lock_pid "$lock")" = "$expected" ] || return 1
  staging="${lock}.release.$(rein_nonce)"
  mv "$lock" "$staging" 2>/dev/null || return 1
  if [ "$(rein_lock_pid "$staging")" = "$expected" ]; then
    rm -rf "${staging:?}"
    return 0
  fi
  # It was reclaimed before this could divert it -- this is a different run's live lock. Put it
  # back if the public name is free.
  if [ ! -e "$lock" ] && mv "$staging" "$lock" 2>/dev/null; then
    return 1
  fi
  # The place to put it back is already occupied (yet another run has taken the public name) --
  # whatever was diverted no longer belongs to any run's public lock. There is nothing left to
  # do but fold it away, but **what is being folded away is a different run's live lock**, so
  # this names it explicitly rather than deleting it silently (without this one line, the
  # double ownership would never show up in any record at all).
  printf 'rein: could not put back a lock diverted from a different run that had reclaimed it (a third run has taken the public name -- two runs may be holding the lock at the same time): %s\n' \
    "$lock" >&2
  rm -rf "${staging:?}"
  return 1
}

# Claims a lock, and if the existing one is stale, releases it once and reclaims it.
# **The reclaim discipline is consolidated into this one function** -- the same shape used to be
# written out separately at each call site, and exactly the paths that never got it (diverting
# the fire log, mutual exclusion during a handover) were left with "once something goes stale,
# it can never be claimed again." The behavior when a reclaim isn't possible, or the owner is
# there, is unchanged, returning 2 with the caller stating the reason.
# What gets released is restricted to **the lock at the exact pid this run judged stale** (the
# cross-checked release above).
# 0=claimed / 1=cannot prepare it / 2=the owner is there (cannot claim it)
rein_claim_lock_dir_or_reclaim() {
  local lock="$1" rc stale_pid
  shift
  rein_claim_lock_dir "$lock" "$@"
  rc=$?
  [ "$rc" -eq 2 ] || return "$rc"
  rein_lock_dir_is_stale "$lock" || return 2
  stale_pid="$REIN_LOCK_STALE_PID"
  rein_release_lock_dir_if_stale "$lock" "$stale_pid" || return 2
  rein_claim_lock_dir "$lock" "$@"
}

# Releases only the lock this run claimed (a token match). Never touches a lock a different run
# has reclaimed.
# **"Could not release it" and "not mine" are returned as distinct values** -- collapsing them
# into one would make even a run that correctly backed off (because a different generation had
# reclaimed it) get reported by the caller as a mechanism anomaly.
# 0=released / 1=mine, but cannot release it / 2=not mine (untouched)
rein_release_lock_dir_if_mine() {
  local lock="$1" token="$2" recorded
  [ -e "$lock" ] || return 0
  recorded="$(rein_lock_field "$lock" token)" || return 2
  [ "$recorded" = "$token" ] || return 2
  rein_release_lock_dir "$lock"
}

# A process's liveness is judged **with reads only** (this module never performs an OS
# process-stopping operation of any kind -- the contract "one resident watcher instance per
# runtime directory").
# **"Not there" and "cannot be confirmed" are never collapsed into the same value** -- collapsed
# together, an environment where `ps` never answers would read every live owner's lock as stale
# and seize it (double ownership). Other material (an unreadable pid, a non-numeric one) already
# carries the discipline "what cannot be confirmed is never seized," so `ps`'s own answer is not
# left as an exception to that.
# This always includes its own pid in the query so that whether `ps` is answering at all can be
# judged from **the output itself** (since this process is definitely there, if it's missing
# from the output, `ps` isn't answering). Since this is a path a hook runs through every time,
# the judgment does not cost a second fork.
# 0=there / 1=not there / 2=cannot be confirmed
rein_pid_alive() {
  local target="$1" listed
  case "$target" in
    '' | *[!0-9]*) return 1 ;;
  esac
  listed=" $(ps -p "$target" -p $$ -o pid= 2>/dev/null | tr -s '[:space:]' ' ') "
  case "$listed" in
    *" $$ "*) ;;
    *)
      # There are two ways this process can end up missing: (a) `ps` itself isn't answering,
      # (b) `ps` rejected the given pid outright, taking the whole query down with it (macOS
      # rejects a value past the allocation ceiling with `process id too large` -- this is
      # **an impossible value**, not "cannot be confirmed." Failing this toward unknown would
      # mean a lock written with a broken pid could never be reclaimed again). To tell them
      # apart, this process is queried alone a second time, only here -- the path that succeeds
      # normally still costs just one fork.
      if ps -p $$ -o pid= >/dev/null 2>&1; then
        return 1
      fi
      return 2
      ;;
  esac
  case "$listed" in
    *" $target "*) return 0 ;;
  esac
  return 1
}

# The command line a pid is running. The last piece of material for judging whether **a lock
# with no declaration** (not something rein created -- placed by hand) belongs to rein's
# resident watcher. A lock rein itself publishes carries a declaration (start time, cwd, role),
# so that cross-check takes effect first instead.
rein_ps_command() {
  ps -p "$1" -o command= 2>/dev/null
}

# Where a judgment's result is carried back (calling this inside `$( )` closes it into a
# subshell, so it's returned to the caller via a variable instead).
REIN_WATCHER_PID=""
REIN_WATCHER_REASON=""

# Whether a command line is "the resident watcher's binary watching the target cwd" (a judgment
# that never calls real ps -- directly measurable in a check). A mere substring match would read
# any unrelated process whose command line just happens to contain the watcher's binary path
# (an editor, tail, a watcher for a different cwd) as the watcher, leaving a stop request on
# that lineage. Trailing whitespace is added to the target comparison so that `--cwd /a/b`
# never matches `--cwd /a/bc`.
#
# **This never re-parses argv out of the flat `ps command` string** -- that string cannot tell
# an option apart from "an option's value," so adding a condition that scans the whole line
# flips the judgment the moment an option name simply appears inside a value (a watcher whose
# `--cwd` value happened to contain the word ` --bootstrap` actually got read as "an interface
# that finishes in one shot," and its live lock got deterministically seized -- this really
# happened). Role (resident or bootstrap) is checked through **the lock's declaration** instead
# -- `rein_watcher_state`'s mode cross-check. All this function answers is whether this binary
# is a launch of the watcher for the target cwd.
rein_watcher_command_matches() {
  local cmd="$1" target="$2"
  case "$cmd" in
    *"$REIN_WATCHER_SCRIPT_PATH"*) ;;
    *) return 1 ;;
  esac
  case "${cmd} " in
    *"--cwd ${target} "*) ;;
    *) return 1 ;;
  esac
  return 0
}

# Checks whether the watcher is resident from the watcher lock's owner (reads only -- performs no
# stop operation).
# A live pid alone is not enough -- since pids get reused, this cross-checks all the way to
# whether the binary is actually rein's watcher.
# The judgment is **consolidated into this one function** (the CLI verbs, a handover request's
# writer, and the hooks all go through the same three conditions).
# If a side that never checks residency decides to "place a marker / stay silent" on its own, a
# request is left behind with nobody there to remove it, and every handover after it stalls.
# The second argument is "the cwd that location is supposed to be watching" (a cross-lineage
# listing has a different owner per lineage, so the counterpart to check against is always
# supplied by the caller).
# **What separates the categories is whether a judgment could be reached at all** -- a case
# where the binary could be cross-checked all the way and turned out to be "not this location's
# watcher" (a PID reuse) has reached a judgment, so it's **1 (not resident -- a stale lock)**;
# only a case where the material itself is missing (pid unreadable, non-numeric, cannot trace
# the owner's cwd) is **2**. Failing this toward 2 instead would put the claiming side (the
# watcher itself reclaims using this same cross-check as stale) and the reading side's
# categorization out of sync, producing a state where `up` keeps refusing to launch while
# `status` reports "cannot be determined."
# 0=resident (pid in REIN_WATCHER_PID) / 1=not resident / 2=cannot be determined (reason in
# REIN_WATCHER_REASON)
rein_watcher_state() {
  local dir="$1" expected_cwd="$2" lock pid cmd declared_cwd declared_mode
  REIN_WATCHER_PID=""
  REIN_WATCHER_REASON=""
  lock="$dir/$REIN_LOCK_DIRNAME"
  if [ ! -d "$lock" ]; then
    REIN_WATCHER_REASON="no watcher lock"
    return 1
  fi
  pid="$(rein_lock_pid "$lock")"
  case "$pid" in
    '' | *[!0-9]*)
      REIN_WATCHER_REASON="cannot read the watcher lock's owner: ${lock}"
      return 2
      ;;
  esac
  rein_pid_alive "$pid"
  case $? in
    1)
      REIN_WATCHER_REASON="the watcher lock is still there, but its owner pid=${pid} is not there (a stale lock)"
      return 1
      ;;
    2)
      REIN_WATCHER_REASON="ps is not answering, so pid=${pid}'s liveness cannot be confirmed (a lock that cannot be confirmed is never seized): ${lock}"
      return 2
      ;;
  esac
  # Even with a live pid, if it disagrees with the declared start time, the owner is already
  # gone (whatever now holds a reused pid). Only a lock with no declaration (one rein never
  # published) passes through this check and falls all the way to the command-line cross-check
  # below.
  if ! rein_lock_owner_alive "$lock"; then
    REIN_WATCHER_REASON="the watcher lock is still there, but pid=${pid} is not the owner at the declared start time (a stale lock from a PID reuse): ${lock}"
    return 1
  fi
  if [ -z "$expected_cwd" ]; then
    REIN_WATCHER_REASON="cannot trace the owner's cwd, so cannot cross-check whether pid=${pid} is rein's watcher"
    return 2
  fi
  # The binary is cross-checked through **the lock's declaration** (a `ps` command line cannot
  # tell an option apart from "an option's value," so adding a condition that scans the whole
  # line flips the judgment on a word that simply appears inside a value). A declaration that
  # disagrees means "something else is alive" -- this fails toward never seizing it (the
  # claiming side never reclaims on this judgment either).
  declared_cwd="$(rein_lock_field "$lock" cwd)"
  if [ -n "$declared_cwd" ] && [ "$declared_cwd" != "$expected_cwd" ]; then
    REIN_WATCHER_REASON="the watcher lock declares ${declared_cwd} (not the watcher for ${expected_cwd}, so not seizing it): ${lock}"
    return 2
  fi
  declared_mode="$(rein_lock_field "$lock" mode)"
  if [ -n "$declared_mode" ] && [ "$declared_mode" != "$REIN_LOCK_MODE_WATCH" ]; then
    REIN_WATCHER_REASON="the watcher lock declares a role that is not resident (${declared_mode}) (not seizing it): ${lock}"
    return 2
  fi
  if [ -z "$declared_mode" ]; then
    # Only a lock with no role declaration (one rein never published -- placed by hand) falls
    # all the way to the command-line cross-check as the last piece of material. A lock rein
    # published itself never reaches this point.
    cmd="$(rein_ps_command "$pid")"
    if ! rein_watcher_command_matches "$cmd" "$expected_cwd"; then
      REIN_WATCHER_REASON="the watcher lock is still there, but pid=${pid} is not rein's watcher for ${expected_cwd} (a stale lock from a PID reuse): ${cmd}"
      return 1
    fi
  fi
  REIN_WATCHER_PID="$pid"
  return 0
}

# The list of running processes (pid and command line). Since the seat never writes a state
# file (contract: the seat is a reader, and never gains a second writer), a presence judgment
# can only be reached by cross-checking this list.
rein_ps_snapshot() {
  ps -axo pid=,command= 2>/dev/null
}

# **The one entry check every enumeration reader runs before it indexes elements**: is this the
# shape of an enumeration, elements included. `jq -e .` alone only answers "is this valid JSON",
# and both `{"error":...}` -- **valid JSON that is not an array** (an external CLI spitting out
# an error in place of a real body) -- and `[1,2,3]` -- an array whose elements are not objects
# -- pass right through it. Indexing `.sessionId` on either makes jq fail with a runtime error
# (rc=5), which surfaces **as the same non-zero as "not there"**, and every reader below acts on
# that answer: bootstrap launches the primary session even though a live predecessor might still
# be around, and the cleanup of a launched successor concludes "there is no one to clean up".
# Each reader names its own cannot-be-determined value, so what is shared here is only the shape
# judgment.
# **Written out at each reader instead, one of them gets widened later and the rest stay behind**
# -- and the ones left behind are exactly the ones that fail toward "not there".
# 0=usable as an enumeration / 1=not usable
rein_agents_json_ok() {
  printf '%s' "$1" | jq -e 'type == "array" and all(.[]; type == "object")' >/dev/null 2>&1
}

# Whether a session is alive within enumeration JSON already in hand. A single judgment kept in
# one place so the vocabulary for "counts as finished" is never held in two places -- a side
# that cannot re-fetch enumeration (`rein prune` judging several sessions from one enumeration
# call, among others) goes through this too.
# The entry point goes through `rein_agents_json_ok` (why that shape, and not `jq -e .` alone,
# is stated there). Cannot-be-determined is named explicitly as 2 (never silently failed toward
# not-there): a value outside the declared 0/1/2 matches none of the caller's branches and flows
# into the default branch -- "the predecessor isn't there" -- meaning exactly the shape this
# function is supposed to close off (two primary sessions) goes ahead and happens anyway
# (observed: `printf '[1,2,3]' | jq -e --arg id x 'any(.[]; .sessionId == $id ...)'` -> rc=5).
# **The second jq call's non-zero is also split into "false" and "a runtime error"** (even with
# the entry check widened, room remains for a runtime error from a jq version difference or an
# unknown response -- this closes off every avenue for a value outside the contract to be
# returned).
# 0=alive / 1=not there or already finished / 2=enumeration isn't the expected shape, cannot be
# determined
rein_agents_has_live() {
  local agents="$1" session_id="$2" rc
  rein_agents_json_ok "$agents" || return 2
  printf '%s' "$agents" | jq -e --arg id "$session_id" '
    any(.[];
      .sessionId == $id
      and ((.pid // null) != null)
      and (((.status // .state // "") | ascii_downcase) as $s
           | ($s != "done" and $s != "failed" and $s != "stopped"))
    )' >/dev/null 2>&1
  rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

# Enumeration can be passed in as an argument (**if given, this never fetches its own**) -- an
# interface for keeping several judgments aligned to the same moment in time (the same as
# `rein_stranded_predecessor`). Fetched separately, whatever changed in between or a transient
# failure would let the judgments disagree with each other. An empty string means "could not be
# read" -- cannot be determined.
# 0=alive / 1=not there or already finished / 2=cannot read enumeration, cannot be determined
rein_is_session_live() {
  local session_id="$1" agents=""
  if [ "$#" -ge 2 ]; then
    agents="$2"
  else
    agents="$(rein_list_agents)"
  fi
  if [ -z "$agents" ]; then
    return 2
  fi
  rein_agents_has_live "$agents" "$session_id"
}

# Resolves a session ID (a full UUID) from enumeration to the short job ID the CLI accepts.
# `claude stop` / `claude attach` reject a full UUID, failing with `No job matching` (observed).
# Since the CLI's internal mapping between id and sessionId offers no guarantee of a prefix
# match, this pulls it from enumeration's matching element rather than slicing the UUID as a
# string.
# 0=resolved (short ID to standard output) / 1=no match in enumeration / 2=cannot read
# enumeration, cannot be determined
# 3=present, but has no short job ID (observed: this applies to a kind=interactive element)
rein_resolve_job_handle() {
  local session_id="$1" agents handle present
  agents="$(rein_list_agents)"
  if [ -z "$agents" ]; then
    return 2
  fi
  rein_agents_json_ok "$agents" || return 2
  handle="$(printf '%s' "$agents" | jq -r --arg sid "$session_id" '
    [ .[] | select(.sessionId == $sid) | (.id // empty) ] | (.[0] // empty)' 2>/dev/null)"
  if [ -n "$handle" ]; then
    printf '%s\n' "$handle"
    return 0
  fi
  present="$(printf '%s' "$agents" | jq -r --arg sid "$session_id" '
    [ .[] | select(.sessionId == $sid) ] | length' 2>/dev/null)"
  case "$present" in
    '' | 0 | *[!0-9]*)
      return 1
      ;;
  esac
  return 3
}

# Turns a resolution failure into a human-readable reason (kept in one place so the wording
# never drifts apart between callers).
rein_job_handle_error() {
  local session_id="$1" rc="$2"
  case "$rc" in
    2)
      printf 'cannot read claude agents --json (cannot resolve the job ID for %s)' "$session_id"
      ;;
    3)
      printf 'session %s is an interactive session (has no short job ID, so it cannot be given to the CLI)' "$session_id"
      ;;
    *)
      printf 'session %s is not in the claude agents --json enumeration (cannot resolve the job ID)' "$session_id"
      ;;
  esac
}

# This checkout's version (the plugin manifest is canonical). Since a resident watcher keeps
# running **on the code it launched with** (only settings get re-read each cycle), if the
# version isn't kept on the line marking the start of monitoring, there is no way to recover
# from the records which version was actually running. An unreadable case returns empty (this
# shows up as a gap in the record -- failing this toward a default value instead would erase the
# distinction between "the version is unknown" and "the version is known").
rein_plugin_version() {
  jq -r '.version // empty' "$REIN_REPO_ROOT/$REIN_PLUGIN_MANIFEST_RELPATH" 2>/dev/null
}

# A contract file's `name` field (plugin and marketplace both use the same field name).
rein_manifest_name() {
  jq -r '.name // empty' "$REIN_REPO_ROOT/$1" 2>/dev/null
}

# The plugin's exact ID (`<plugin name>@<marketplace name>`). The form passed to `claude plugin
# install / enable / update`, canonically sourced from the two manifests. **Never written as a
# literal in an instruction** -- a second copy of the same value would mean that renaming a
# manifest leaves only the instruction giving the stale ID, stalling whoever typed exactly what
# it said with "not found" (a bare name doesn't resolve independent of version, so this
# mechanism assumes instructions always give the qualified form).
# Read by everyone who reads the shared library (installation, diagnostics, the dedicated hook
# runner). **The ID installation passes to `claude plugin install / enable`, and the value
# diagnostics cross-checks against `claude plugin list`'s `id`, are the same one value** -- if
# assembled separately, only one of them following a manifest rename would leave diagnostics
# green while installation deploys a different ID.
# An unreadable case returns non-zero rather than empty, so whatever assembles an instruction
# can tell "the ID could not be assembled" apart from the rest.
rein_plugin_exact_id() {
  local name marketplace
  name="$(rein_manifest_name "$REIN_PLUGIN_MANIFEST_RELPATH")"
  [ -n "$name" ] || return 1
  marketplace="$(rein_manifest_name "$REIN_MARKETPLACE_MANIFEST_RELPATH")"
  [ -n "$marketplace" ] || return 1
  printf '%s@%s\n' "$name" "$marketplace"
}

rein_pointer_field() {
  local pointer_file="$1" field="$2"
  jq -r --arg field "$field" '.[$field] // empty' "$pointer_file" 2>/dev/null
}

# Validates the current pointer's contract (`schema` is `rein.current.v1`, `cwd` matches the
# target, `session_id` is non-empty, `generation` is a positive integer). If each reader wrote
# its own validation, exactly "this one reader silently lets a broken pointer through" is the
# shape that results (this is in fact what used to happen with prune).
# The result is returned via a variable ($( ) would close it into a subshell and never let the
# reason back out to the parent).
# 0=valid (REIN_POINTER_GENERATION / REIN_POINTER_SESSION_ID) / 1=no pointer / 2=violates the
# contract (reason in REIN_POINTER_ERROR)
rein_validate_pointer() {
  local pointer_file="$1" target_cwd="$2" schema pointer_cwd session_id generation
  REIN_POINTER_ERROR=""
  REIN_POINTER_GENERATION=""
  REIN_POINTER_SESSION_ID=""
  if [ ! -f "$pointer_file" ]; then
    return 1
  fi
  if ! jq -e . "$pointer_file" >/dev/null 2>&1; then
    REIN_POINTER_ERROR="current.json cannot be parsed as JSON"
    return 2
  fi
  schema="$(rein_pointer_field "$pointer_file" "schema")"
  if [ "$schema" != "$REIN_POINTER_SCHEMA" ]; then
    printf -v REIN_POINTER_ERROR 'the schema in current.json does not match the contract: %s' "${schema:-(none)}"
    return 2
  fi
  pointer_cwd="$(rein_pointer_field "$pointer_file" "cwd")"
  if [ "$pointer_cwd" != "$target_cwd" ]; then
    printf -v REIN_POINTER_ERROR 'the cwd in current.json does not match the target: %s' "${pointer_cwd:-(none)}"
    return 2
  fi
  session_id="$(rein_pointer_field "$pointer_file" "session_id")"
  if [ -z "$session_id" ]; then
    REIN_POINTER_ERROR="current.json has no session_id"
    return 2
  fi
  generation="$(rein_pointer_field "$pointer_file" "generation")"
  case "$generation" in
    '' | 0 | *[!0-9]*)
      printf -v REIN_POINTER_ERROR 'the generation in current.json is not a positive integer: %s' "${generation:-(none)}"
      return 2
      ;;
  esac
  REIN_POINTER_GENERATION="$generation"
  REIN_POINTER_SESSION_ID="$session_id"
  return 0
}

# The material for judging a handover that failed partway through. Since a handover proceeds
# "launch the successor -> advance the pointer -> retire the predecessor session," a session
# the pointer's `predecessor_session_id` names still being present in enumeration means "the
# successor launched and the pointer advanced, but only retiring the predecessor session is left
# outstanding" (the same shape also results from a launch-confirmation failure, or the watcher
# stepping down partway through).
# **A handover mid-flight normally passes through this exact shape** (both sides coexist during
# the grace period), so the caller reads this together with "the watcher isn't there" -- this
# function only answers what the state is; it never decides whether that state is an anomaly.
# **The successor's liveness is checked from the same enumeration too.** Looking only at the
# predecessor and calling it "stranded" would retire the predecessor session even on a lineage whose
# successor has already died -- ending up with zero live sessions while it gets recorded and
# announced as "the handover completed" (a loss actually reproduced in observation). Checking
# the predecessor and the successor from separate enumeration calls would let whatever changed
# in between masquerade as "neither is there" or "both are there," so the judgment is always
# kept aligned to one single moment.
# Enumeration can be passed in as an argument (**if given, this never fetches its own**) -- an
# interface for not hitting the external command twice within one moment in time. An empty
# string means "could not be read" -- cannot be determined.
# When there is no pointer, or it violates the contract, this returns 1 (that anomaly is already
# named explicitly by the primary session's own judgment, so it is not given a second reason
# here).
# 0=both the successor and the predecessor session are there (stranded; the IDs are in
# REIN_STRANDED_PREDECESSOR / REIN_STRANDED_SUCCESSOR)
# 1=nothing is stranded / 2=cannot be determined
# 3=only the predecessor session is there (the primary session on record is gone -- a mismatch where
# only one side of the handover died)
REIN_STRANDED_PREDECESSOR=""
REIN_STRANDED_SUCCESSOR=""
rein_stranded_predecessor() {
  local pointer_file="$1" target_cwd="$2" agents="" have_agents=0 predecessor successor rc
  if [ "$#" -ge 3 ]; then
    have_agents=1
    agents="$3"
  fi
  REIN_STRANDED_PREDECESSOR=""
  REIN_STRANDED_SUCCESSOR=""
  rein_validate_pointer "$pointer_file" "$target_cwd" || return 1
  predecessor="$(rein_pointer_field "$pointer_file" "predecessor_session_id")"
  [ -n "$predecessor" ] || return 1
  successor="$REIN_POINTER_SESSION_ID"
  if [ "$have_agents" -eq 0 ]; then
    agents="$(rein_list_agents)"
  fi
  # This checks not merely "the JSON could be read" but **a shape usable as enumeration** (an
  # array whose elements are objects). Both `{"error":...}` and `[1,2,3]` would otherwise pass
  # `jq -e .`, and would send the judgment below toward the same non-zero as "not there" --
  # cannot be determined would silently fail toward "nothing is stranded." Since the shape judgment
  # belongs to `rein_agents_has_live`'s entry point, **its 2 is simply passed straight through
  # here** (if two places carried the same check separately, one of them being widened alone
  # would put them out of sync).
  if [ -z "$agents" ]; then
    return 2
  fi
  rein_agents_has_live "$agents" "$predecessor"
  rc=$?
  [ "$rc" -eq 2 ] && return 2
  [ "$rc" -eq 0 ] || return 1
  REIN_STRANDED_PREDECESSOR="$predecessor"
  REIN_STRANDED_SUCCESSOR="$successor"
  # This is the second use of the same enumeration, so the shape judgment has already passed --
  # only the liveness answer is taken here.
  rein_agents_has_live "$agents" "$successor" || return 3
  return 0
}

# The explanation and the fix for a state where only one side of a handover died (the primary
# session on record is not in enumeration, yet the predecessor is alive). Since this was
# decided to be a state **rein never fixes automatically**, the one sentence the user reads is
# this function's only exit point -- the watcher (which stops at launch) and doctor (which
# diagnoses it) both emit this same one sentence; if written in two places, one of them would
# always be left behind with stale instructions. Whatever material the caller holds for the
# cause (the log's original text if it made it into the handover log, or where to go look if
# not) is inserted verbatim -- never folded into generic wording.
# **The name to call it by ($1) is supplied by the caller.** Writing a bare `rein` here would
# mean instructing a machine with rein not yet on PATH to run "a command it cannot run" (the CLI
# uses the one name `cli_rein_cmd` decides; the watcher passes the binary's absolute path
# instead). Since this layer knows neither the state of PATH nor its own binary's path, it is
# never the one to decide.
rein_handover_mismatch_detail() {
  local cmd="$1" successor="$2" predecessor="$3" cwd="$4" cause="$5" runtime="$6" records="$7" up init
  rein_lineage_cmd "$cmd" "$runtime" "$records" "$cwd" up
  up="$REIN_LINEAGE_CMD"
  rein_lineage_cmd "$cmd" "$runtime" "$records" "$cwd" init
  init="$REIN_LINEAGE_CMD"
  printf 'the primary session on record, %s, is not in enumeration, but the predecessor, %s, is alive (only one side of the handover died). rein does not fix this automatically (it will not relaunch a successor, will not roll back the pointer, and will not stop the live predecessor). %s. To fix it: (1) In the predecessor %s, finish writing the handoff document, then look up its job ID with claude agents --json and stop it with claude stop. (2) Running %s launches a new primary session from the document. (3) If that still does not recover it, redo %s as a last resort' \
    "$successor" "$predecessor" "$cause" "$predecessor" "$up" "$init"
}
