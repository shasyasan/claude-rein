# Handover specification

The file formats read and written during the handover sequence (the handover request marker, the current pointer, the handover log), the freshness validation rules, how a session is addressed, per-step timeouts, the command that executes a handover, and what goes into kickoff.

## Handover request marker `handover-request.json`

The marker is **one file** representing a single handover request; it stays in the runtime data location until the watcher consumes it by accepting or rejecting it.

```json
{
  "schema": "rein.handover-request.v1",
  "session_id": "0aa35181-3898-4a09-a63e-be7f529d0e68",
  "requested_at": "2026-08-15T04:12:33Z",
  "handoff_path": "/Users/you/Projects/example-app/.rein/handoff.md",
  "cwd": "/Users/you/Projects/example-app",
  "successor_name": "example-app-rein-g4",
  "note": "handover at 12% usage"
}
```

| Key | Required | Contents |
| --- | --- | --- |
| `schema` | required | The fixed string `rein.handover-request.v1` |
| `session_id` | required | The session ID of the session submitting the request (a string with no whitespace) |
| `requested_at` | required | The time the marker was written |
| `handoff_path` | required | The **absolute path** to the handoff document |
| `cwd` | optional | The target project's absolute path |
| `successor_name` | optional | The successor session's display name |
| `note` | optional | A note for the user to read later (the watcher never uses it in judgment) |

- `schema` is a version stamp -- it's checked against a fixed string so that a future format change is never silently accepted.
- `requested_at`'s format is strictly `YYYY-MM-DDTHH:MM:SSZ` (UTC, second precision).
- `handoff_path` is carried straight into the successor's kickoff. When omitted, `rein request` writes config's effective value (including the default) instead.
- If `cwd` is present, it must match the watcher's target cwd (R9).
- When `successor_name` is omitted, the watcher generates `<cwd's basename>-rein-g<generation>`.
- The write happens **atomically** (a temp file in the same directory, then `mv`). If the watcher reads a half-written JSON file, it gets rejected as a syntax error even though the content would otherwise be correct.
- **The only writer of the marker, for a given cwd, is that cwd's current primary session submitting a request** (since the management unit is one lineage per cwd, 2 primary sessions can never coexist). So there's no queue for writers to wait their turn in. **But publishing itself does happen inside the operation lock (`op.lock/`)** -- if checking "no unconsumed marker exists" were split apart from publishing, 2 requests fired at the same moment could both read "nothing unconsumed" and the one written second would replace the first with no non-zero exit and no record left behind (reproduced by observation). This is also to keep it from interleaving with `rein up` / `down`, which take the same lock (see [the locations and locks specification](runtime.md), `op.lock/`). The loser falls into the existing "an unconsumed marker exists" path.

### The only way to write the marker is `rein request`

There is **exactly one** channel that places the marker; writing it by hand is a contract violation.

```sh
rein --cwd <target project> request \
  --session-id <your session ID> [--handoff <handoff document's absolute path>] \
  [--runtime-dir <runtime data location>] [--successor-name <name>] [--note <note>]
```

- **A session is never made to assemble JSON itself.** Atomic writes, the time format, and ordering against the handoff document all break down as soon as each writer reimplements them (satisfying R1 through R10 from natural-language instructions is close to impossible). What goes into the successor's kickoff is this one command line.
- When `--handoff` is omitted, config's **effective value** for `handoff_path` is used (default: `handoff.md` next to the lineage's records).
- **A lineage whose effective value can't be determined** (one where `handoff_path` was explicitly set empty) never writes a request; it fails instead -- a handover request with no handoff document behind it is never created.
- The command **touches the handoff document right before writing** the marker. This is the code-side guarantee for R7 (the handoff document must come before the marker) -- it holds regardless of the timing window, even for a workflow of "update the handoff document -> a long final check -> the marker."
- **On a lineage where the watcher isn't resident, the command fails non-zero without writing, and prints one notification** (the reason and how to start it also go to stderr). If it wrote anyway, nothing would be around to consume it, and the leftover marker would reject every subsequent request as "unconsumed" -- blocking that lineage's handover channel entirely. The check runs **after** confirming the owner and **before** the unconsumed check (printing "unconsumed" first, while a stale marker is sitting there, would leave the user with no visibility into the root cause and steer them toward "delete the existing marker" instead). Residency is checked with the same single check used by the CLI verbs, hooks, and the watcher's own lock acquisition (see [the locations and locks specification](runtime.md), `watcher.lock/`). **The check that decides whether publishing may proceed runs once, after the operation lock is taken** -- proceeding to publish on the strength of a check made outside the exclusive section risks a race against `rein down` (which takes the same lock, stops the watcher, then releases the lock): a stale "it's there" reading could place the marker at a location with no watcher and report success with exit 0. It's also checked once before taking the lock, so that a lineage whose location doesn't even exist yet (one where the operation lock itself can't be prepared) still gets one line telling the user how to start it.
- **It fails for 2 distinct reasons, each with its own message.** "Not resident" (no lock, the owning pid is gone, or the pid is alive but its identity isn't that cwd's watcher -- a stale lock from a reused PID) gets a start-it message; "can't tell whether it's resident" (the watcher lock's owner can't be read, or isn't numeric) prints no start message and instead points at **where the watcher lock is** -- falling back to a start message here just because the evidence is missing risks starting a second watcher.
- **The start-it message is printed with real values filled in, as "a line ready to run."** For a lineage with no explicit location (the default XDG state area), that's `<this implementation's bin/rein> --cwd <target> up`; for a lineage relocated with `--root`, it adds `--root <effective value>`; for a lineage running with `--runtime-dir` or through config, it becomes `up --runtime-dir <effective value>`. It never phrases this as prose ("start it with the same options as this handover request") -- that would leave the user to work out the effective values themselves, and a mistake there would start a watcher watching a different location (one that would never pick up this request either way). On a call where the naming evidence isn't all there (the records location can't be resolved), **no line is printed at all**; instead it says "the lineage cannot be named explicitly in the line to run" and names what couldn't be determined -- guessing and falling back to the `--runtime-dir` form would start a watcher on the wrong location for a lineage relocated with `--root`.
- **The name filled into the message is never the bare `rein`** -- it's printed as the real path to `<this implementation's bin/rein>`. Only the layer that has what it takes to follow the symlink (the CLI entry point) can check whether the `rein` on PATH is this implementation and collapse it to the short name; the handover request, hooks, the watcher, and the seat don't have that evidence, so they all print the real path, **a form that runs no matter what is on PATH** (the canonical rule lives in [the config specification](config.md), the "Allowing project config" section).
- **While this session still has a running child (subagent), the command fails non-zero without writing.** A handover replaces the primary session, and a child dies along with its parent -- the invariant "never hand over while a child is alive" is stated in [the architecture](architecture.md), and `Stop`'s push already defers on it, but this side had no view of children at all, so a request typed by hand went straight through (observed: of 3 children running, 2 ended having written nothing). The check runs **after** residency and **before** taking the operation lock: a lineage with no watcher can't hand over at all, so that reason comes first, and a running child clears itself within minutes while a missing watcher doesn't.
  - The evidence is the children ledger the hooks keep, `<runtime>/children/<session_id>.<agent_id>` (see "Runtime data hooks use" in [the locations and locks specification](runtime.md)) -- a payload, which is the hooks' own evidence, never reaches this process. **Only this session's own entries are read**, so leftovers from earlier generations never refuse a handover.
  - The reason names **how many** children are running and, for each, its `agent_type`, its `agent_id`, and how long it has been running -- enough to decide whether to wait or to stop them.
  - **An entry whose child has gone silent past the expiry cutoff isn't counted** (the same cutoff, through the same judgment, that the hooks apply), so a child that vanished without delivering `SubagentStop` can never refuse that session's handover permanently. Where the child's own record doesn't exist yet, the moment it was registered stands in for it, so the window right after `SubagentStart` is not a hole.
  - **There is deliberately no `--force`.** Overriding it would place the marker, the watcher would replace this session, and the children would die anyway -- an override rescues nothing.
- **If an unconsumed marker already exists, it's never overwritten -- the command fails non-zero instead** (the earlier request is never erased with no record). Once the watcher accepts or rejects it and consumes it, the next one can be placed.
- If the handoff document isn't **in an acceptable shape** (a regular, non-symlink, non-empty file) or its path can't be resolved, the command fails without writing (surfaced on the writer's side rather than waiting for the watcher's rejection).
  - The acceptance condition is the same single check shared with `rein init` (the template) and `bootstrap` (launching the first session). Symlinks are rejected because swapping the link's target could make the existence, non-emptiness, and freshness checks apply to a completely different file underneath.
- **A handoff document whose section structure doesn't match the template also fails without writing** -- either a section the template requires is missing, or a `##` heading the template doesn't define has been added. The failure reason **names** the missing or extra heading explicitly, and points at where permanent rules, procedures, and knowledge belong instead (not this document, but whatever canonical source that environment defines for each).
  - **Only depth-2 headings (`##`) are checked** -- anything at `###` or deeper doesn't count as a section (this is a deliberate scope, not an oversight; the goal is to stop sections themselves from proliferating, leaving the structure inside a section to the writer's own judgment).
  - **This check doesn't run on the reader's side** (the watcher's R1 through R10) -- it relies on the marker-placing channel being the single choke point of "one handover request" (asymmetric with the acceptable-shape check, which exists on both the writer's and the reader's side).
  - **Only a handover request goes through this check** -- it's a separate function from the acceptable-shape check shared with `rein init` and `bootstrap`, because those run before the template is even placed, or while launching the first session, using only the boolean result; mixing the section check in would block that step too.
  - **The list of sections is canonically one single ordering, from the shared library** -- the template (`rein init`) and this check read that same list (what's checked is **set equality** -- only missing and extra headings -- and **the ordering within the handoff document itself is never a condition**) (keeping the same text in 2 places would let a handoff document written exactly to the template still get rejected by the handover request).
  - **Why this is machine-checked**: "don't add sections" used to be nothing but a request in the template's own prose. An added section gets copied forward at every handover, so once one is added, it never goes away without someone removing it by hand (permanent rules and a work log had piled up until the handoff document turned into just another place to dump things). A `##` inside a code fence (` ``` `) doesn't count as a heading -- an example pasted into the body never blocks a handover.
- **The rules for how to "write" the handoff document are also canonically one single value, from the shared library** (a separate value from the section-list ordering), and **no copy of it exists anywhere else** -- the template (`rein init`) outputs that value when it's assembled, and hooks' 3 firing points (the advisory, the handover trigger, and the stop-block text) all fill in that same value (see [the hooks specification](hooks.md), Registration). Adding one more rule never leaves a stale copy behind anywhere, structurally. `init`'s self-check confirms "did the generation take effect, with that value landing whole, as one line, in the template" by matching a fixed string (it never checks by listing out key words and matching against those -- a list only reflects the rules as of when it was written, so it would silently let anything added since slip through).

## Freshness validation

Testing only that the file exists always passes, so **that alone is never a check.** The watcher only carries out a handover when **every one** of the following holds; if even one fails, it archives the marker to `rejected/` and notifies with the reason (fail-loud).

| Rule | What it checks | Default threshold |
| --- | --- | --- |
| R1 | The JSON is syntactically valid | -- |
| R2 | `schema` is `rein.handover-request.v1` | -- |
| R3 | `session_id` is non-empty and **contains no whitespace and no path separator (`/`)** | -- |
| R4 | `requested_at` can be parsed as **exactly the required format**, and **isn't in the future** (within the allowed skew) | 60-second skew (`REIN_MAX_CLOCK_SKEW_SEC`) |
| R5 | `requested_at` isn't **too old** | 900 seconds (`REIN_MARKER_MAX_AGE_SEC`) |
| R6 | `handoff_path` is an absolute path, and is an existing, non-empty, regular file that's **not a symlink** | -- |
| R7 | The handoff document's mtime falls **between `requested_at` - 600 seconds and `requested_at` + 60 seconds, inclusive** | Lower bound 600 seconds (`REIN_HANDOFF_FRESH_WINDOW_SEC`), upper bound the 60-second skew |
| R8 | The handoff document's mtime isn't in the future | 60-second skew (shared with R4) |
| R9 | If `cwd` is present, **both sides resolved with `pwd -P`** match the watcher's target cwd | -- |
| R10 | If a current pointer exists, `session_id` **matches the pointer's `session_id`** | -- |

The premise behind each rule, and why it was decided this way:

- **R4's "exactly the required format"**: BSD's `date -j -f` isn't a strict parser -- it lets trailing garbage through with only a warning (`...Z garbage`), and rounds a nonexistent date (`2026-02-30`) forward into the next month instead of rejecting it. **Both behaviors rest on observation, not on any documented guarantee**, so neither is safe to treat as specified: a version that tightened the parser would not announce itself here. The implementation fixes the literal text to the `YYYY-MM-DDTHH:MM:SSZ` shape first, then converts it to epoch and formats that epoch back the same way to confirm it round-trips to the same input. Accepting any other format would defeat freshness validation entirely.
- **Why R6 goes as far as "not a symlink"**: `[ -f ]` is also true for a symlink whose target is a regular file, so an implementation that reads only the literal phrase "an existing, non-empty, regular file" can look compliant while silently letting a symlink through. Acceptance is centralized in one shared check (`rein_handoff_file_ok`), used by the writer side (`rein request`) and by launching the first session (bootstrap) too, and freshness validation goes through that same function. Symlinks are rejected for the same reason as in "the only way to write the marker is `rein request`," above: swapping the target lets the existence, non-emptiness, and freshness checks apply to a completely different file underneath.
- **Why R7 isn't "mtime >= the marker's timestamp"**: an actual handover request proceeds as "update the handoff document -> write the marker," so the handoff document's mtime is always a few seconds earlier than the marker's timestamp. Requiring it strictly would block every handover that could otherwise succeed.
  - What needs guarding against is "only the marker is new, while the handoff document is untouched for days" -- so it's implemented as **a finite band anchored to the marker's timestamp.** The upper bound (the handoff document keeps getting updated after the marker -- meaning the handoff write isn't finished yet) is also rejected.
  - Because `rein request` touches the handoff document right before writing, the gap stays close to 0 seconds as long as the correct writer is used.
- **R5 and R7 combined give an effective upper bound of 1500 seconds**: R5 is anchored to `now` (the marker's age, up to 900 seconds), while R7 is anchored to `requested_at` (going back up to 600 seconds from there) -- **the two anchor points differ**, so the allowance on the handoff document's mtime as seen from `now` stretches as far as **900 + 600 = 1500 seconds (25 minutes)**. Reading only R7's "600 seconds" and concluding "a handoff document older than 10 minutes never passes" is a mistake.
  - The anchor points aren't unified (R7 isn't made `now`-anchored) because what R7 needs to check is **the correspondence** between the handoff document and the marker -- not "how fresh does it look from right now." Freshness itself is R5's job.
- **R10 (only the current primary session may request a handover)**: since the marker's only legitimate writer is defined as "that cwd's current primary session," a request from a session the pointer doesn't name is, by definition, never supposed to happen.
  - Without this check, a marker placed by a session outside monitoring (an old marker from another lineage, or a mixed-up session ID) would still carry out a handover as long as it passed freshness, and the seat would get re-attached to a session the user never intended.
  - **On a lineage with no pointer yet (right after cold start), there's nobody to check against, so this passes** -- rejecting here would mean the very first handover could never succeed.
- **Why R9 normalizes both sides**: the watcher resolves and holds the target cwd with `pwd -P`. Comparing the marker's string as-is would reject a legitimate marker written for `/tmp/...` (whose real path is `/private/tmp/...`), or for a project path reached through a symlink. A path that can't be resolved can't be shown to be the same target, so it's rejected.

**A rejection never terminates the watcher** (a rejection is a user-side input error, not a mechanism malfunction).

- A resident watcher notifies and **keeps watching** (letting a single bad marker halt automation permanently would turn into a silent standstill of "nothing ever happens" from then on).
- A stage failure (a mechanism malfunction) exits non-zero.
- `--once` is a channel that reports whether that one request went through, so it exits non-zero on a rejection too.
- **A call where a marker exists but the handover's exclusive lock couldn't be acquired**, and **a call where a different run consumed it a moment before the claim**, both also exit non-zero the same way (in neither case did this run itself carry that request through). The resident watch stops for neither.

## Waiting for the final output before launching a successor

**Between accepting the request and launching a successor, the watcher waits for the session that submitted the request to finish its response.** The session keeps writing a summary or a report for the rest of that turn even after submitting the request, so proceeding without waiting would externally stop the predecessor session before the user ever reads it (there are 25 seconds between the request and the screen switching over, but that isn't enough for the user to read and react -- so a hardcoded number of seconds can't solve this).

The wait has 2 stages, and both draw on a one-line signal in the runtime data (see [the locations and locks specification](runtime.md), Runtime data).

| Stage | What it waits for | Cap |
| --- | --- | --- |
| 1 | `handover-ready` (placed by the Stop-wired hook once "the session that submitted a handover request has finished its response") | `final_output_timeout_sec` |
| 2 | Whether the user speaks up, measured from confirming the signal | `final_output_wait_sec` (measured fresh from the moment the signal is observed) |

- **Setting `final_output_timeout_sec` to `0` skips the wait entirely** (proceeds straight to launching a successor on acceptance -- the behavior before this mechanism existed). In that case, `final_output_wait_expired` is **never logged** -- it's not that the wait ran out, it's that the setting decided not to wait at all (no line reading "the mechanism didn't kick in" gets appended to every single handover). **Hooks read this same value and stop placing the 2 signals too** (see [the hooks specification](hooks.md)) -- nothing keeps placing a signal that no longer has a reader.
- **Stage 2's window is announced to the user, once, by the hook that places the signal** -- the moment stage 1's signal goes down, one line goes to the screen naming `final_output_wait_sec` and how to cancel (see [the hooks specification](hooks.md), "Telling the user the wait has started"). Without it, the only window in which speaking up cancels a handover would open and close with nothing on screen to say so. The watcher itself announces nothing -- it has no channel that reaches the seat's screen.
- **The 2 caps are kept separate** -- collapsing them into one would tie the wait for the signal to stage 2's short wait (10 seconds by default). A turn where a long summary follows the request is exactly the scenario this mechanism targets, so it would defeat the purpose if the wait for the signal itself timed out and fell back to the old behavior there.
- **The wait is placed before launching a successor** (after recording acceptance, before launch). rein has no way to roll the current pointer back, and the existing path for retiring a successor from a handover that didn't go through is also written assuming the pointer hasn't advanced yet -- a cancellation can only be carried out before the pointer moves. The tradeoff is that a handover's total time grows to "final output + stage 2's wait + launching the successor + confirming the managed marker reached it." That last term is spelled out rather than folded into "launching the successor" because it is a separate wait with a cap of its own (normally 0 seconds, up to a fixed 10 -- see "Current pointer" below).
- **On every cycle of either stage, `handover-cancel` (placed by the UserPromptSubmit-wired hook) is checked first** -- a cancellation always wins over a completion signal.
- The wait loop takes the same shape as the wait for a successor and the wait for the predecessor session to exit (a deadline measured against a monotonic clock, the watcher's heartbeat updated every cycle, and never sleeping past the deadline). A cycle where the heartbeat can't be updated is treated as a stage failure, the same as the other waits.
- **Only a signal whose contents match the requesting session's own `session_id` counts as evidence** (a signal left over from an earlier handover is skipped). Exiting the wait clears both signals regardless of whether they matched.
- **The signal can still be placed after the wait ends** -- in the window between exiting the wait and the pointer moving to the successor (up to `launch_timeout_sec`, covering the successor's launch and enumeration wait), the predecessor session is still the one the pointer names and the request is still sitting in `processing/`, so if the user speaks up during that window, the cancellation signal still gets placed. **That signal is read once more at the end of the round** (after the predecessor has been stepped down, just before the completion line), and the round leaves `cancel_after_window` plus one notification saying the cancellation arrived after the window had closed and the handover completed as scheduled.
  - **A late cancellation does not turn the handover back.** By the time it can be read, the pointer has already advanced and rein has no way to roll it back -- undoing it after the fact (stopping the successor that is already holding the seat) would be a bigger hazard than the silence it replaces. What the round owes the user is only that their words are never swallowed: they spoke, and one line says where those words landed.
  - **`cancel_after_window` is never `marker_cancelled`**, and it carries this round's generation number rather than `null` -- that vocabulary means "the cancellation took effect and no successor was launched", so reusing it would make a completed handover read in the audit log as one that never happened, and would double-count as a second handover claiming the same number.
  - **The read is placed at the end of the round, not right after the wait or right after the pointer moved** -- the signal can be placed anywhere across that window, including the race right at the pointer swap (the hook reads the pointer before it moves and writes after), so the end of the round is the only position that sees every one of them. A round that fails a stage before reaching there never reads it, and nothing is lost by that: such a round is already loud on its own (a `failed` event, a notification, and a non-zero exit), so the user is never left with a handover that quietly went its own way.
  - **A round with no signal placed says nothing** (the check starts from the file's existence, so it spends not one extra external command there), and **a signal naming another session is neither read nor deleted** -- the same discipline the wait itself follows.
  - **A lineage with `final_output_timeout_sec` set to `0` reads nothing here either** -- the hook stops placing the signal on such a lineage, so a reader there could only ever report a cancellation the user never made.
  - Once read, the signal is deleted, for the same reason the wait clears it on the way out: left behind, it matches on the first cycle of the next handover's wait and cancels a handover the user never spoke against. A deletion that fails leaves one line in the watcher log rather than passing silently.
  - **The channel that clears them is the request side (`rein request`)** -- it clears its own 2 signals before publishing the marker. "I want to hand over now" invalidates a past cancellation this way, unlike an alternative design that sweeps at the entry to the wait (which would also discard a legitimate cancellation placed before the claim).
  - Without clearing it, on the path where the same session resubmits the same request (a stage failure leaves it stranded in `processing/` -> recovered on the next launch -> resubmitted), the leftover signal would match on the first cycle of the wait and the handover would get cancelled -- **producing a notification saying "cancelled because you spoke," even though the user never spoke.**

The wait resolves 3 ways.

| Outcome | Handling |
| --- | --- |
| The cancellation signal is observed | The marker is archived to `cancelled/`, `marker_cancelled` is logged, a notification fires, and **watching continues** (no successor is ever launched) |
| Stage 2's cap is reached while waiting | Proceeds to launch a successor as-is. No extra record is left -- the time spent waiting shows up as the gap between `marker_accepted` and `successor_launching` |
| Stage 1's cap is reached with no marker | Logs `final_output_wait_expired` before launching a successor (falling back to the old immediate-handover behavior because the mechanism didn't kick in is never left silent) |

- **A cancellation doesn't erase the forced handover.** For the cancelled generation, Stop's stop-blocking latch stays consumed, and rein's side never pushes for a handover again in that generation (see [the hooks specification](hooks.md), UserPromptSubmit). If the user wants a handover after all, the session just resubmits the request, and it goes through as usual.
- **A call that ends in cancellation makes `--once` exit non-zero** (the resident watch doesn't stop for this, same as a rejection). `--once` is a channel that reports whether that one request went through, and a cancelled request never did.
- **The stop request from `rein down` has no effect while waiting** (it's deferred until after the wait, along with any other work for that cycle). The sum of the caps is much smaller than the worst-case time already budgeted for the predecessor session's departure, so no branch that checks the stop request is added inside the wait loop.
  - That said, `rein down`'s own cap for waiting on the watcher to depart is `cmd_timeout_sec` (60 seconds by default), and **stage 1's default (120 seconds) exceeds that** -- so running it mid-wait on a lineage where the signal never arrives can exit non-zero with "placed the stop request, but the watcher is still there" (the request stays in place, so it takes effect on the next cycle). The handover's exclusive lock is also held that much longer, so `bootstrap` gets aborted during that window.

## Current pointer `current.json`

The pointer is **one file naming that lineage's current primary session** -- it's where the seat's attach target and R10's comparison target both come from.

```json
{
  "schema": "rein.current.v1",
  "session_id": "9b1c2d3e-...",
  "session_name": "example-app-rein-g4",
  "cwd": "/Users/you/Projects/example-app",
  "generation": 4,
  "updated_at": "2026-08-15T04:13:10Z",
  "predecessor_session_id": "0aa35181-...",
  "handoff_path": "/Users/you/Projects/example-app/.rein/handoff.md"
}
```

- **The only writer is the watcher** (never 2 writers). The attach loop and the user only read it. Cold start's job of launching the first session lives in the watcher rather than the attach loop for the same reason: to keep this single-writer property intact.
- `generation` is a handover counter that increases monotonically within the lineage: the existing pointer's value + 1, or 1 if there's none.
- Updates go through an atomic replacement (a temp file, then `mv`; a reader never grabs a half-written JSON file). **If `current.json`'s pathname isn't a regular file, the write is skipped and the handover fails** (the writer is the same single one used for runtime data -- see [the locations and locks specification](runtime.md), "Replacing a JSON runtime-data file"). Without this check, a call where `mv` targeted a pathname that's actually a directory would return 0, leaving a record where the generation advanced with no pointer ever present.
- `session_id` is **the full session ID** (see "How a session is addressed," below; the attach loop resolves it to the short job ID right before attaching).
- `predecessor_session_id` is `null` for cold start (no predecessor). `handoff_path` is also `null`, but only for a cold start with no handoff document (a lineage with `handoff_path` explicitly set empty).

**An existing pointer is validated before it's read** (`schema` is `rein.current.v1`, `cwd` matches the target, `session_id` is non-empty, `generation` is a positive integer).

- If even one check fails, it **never silently rolls back to generation 1** -- it logs `failed` and exits non-zero instead (overwriting a broken pointer would erase the monotonic-increase guarantee along with it).
- The attach loop checks the same `schema` and `cwd` before attaching too (so a location mix-up never attaches to a different project's session).
- **`rein prune` goes through the same validation too** -- the pointer is the only input that names "who must never be deleted," so proceeding while unable to read it would let a current-generation session end up as a candidate for `claude rm` (it fails non-zero if it can't be validated; pointer absence, i.e. cold start, is let through).
- **A lineage with records left behind at the old location won't start.** A shape where `<cwd>/.rein/current.json` doesn't exist, but the runtime directory side has either `current.json` or `handover.log`, means "a lineage that never relocated its records" -- this isn't read as cold start; startup is refused instead, with a reason.
  - Reading it that way would silently reset the generation back to 1, erase R10's comparison target, and split the canonical audit trail across 2 locations, old and new -- exactly the behavior forbidden for a broken pointer would happen instead through a pointer at the wrong location.

**It's written only after confirming the successor launched** (a pointer that failed to launch is never left behind). Launch confirmation requires all of the following:

- Wasn't in the set of session IDs before launch
- Its name and cwd match
- `startedAt` is at or after when the launch command was issued (it is a millisecond epoch number, so the comparison is made in milliseconds)
- **Has a short job ID (i.e. it's a background session)**
- Has a `pid`, and isn't in a terminated state
- **The candidate is unique** (if more than one turns up, there's no way to decide which one becomes the seat's target, so it's treated as `failed`)

**After the launch is confirmed, and still before the pointer moves, the watcher confirms the managed marker actually reached the successor** (up to a fixed grace period of 10 seconds).

- **What's observed is the temporary launch settings file disappearing.** rein hands the marker over through that file's `env`, and the successor's SessionStart hook deletes the file using a path it can only have learned from the marker (see "Lineage resolution" in [the hooks specification](hooks.md)). So the file still sitting in the runtime directory once the session is up means one thing: **the marker never arrived.**
- **A session missing the marker isn't visibly broken** -- it comes up and works normally, it simply gets nothing at all from rein's hooks (see "A window rein didn't launch gets no action from hooks" in [the hooks specification](hooks.md)). Nothing about the session itself surfaces that it started outside rein's management: the only thing that ever noticed was `rein doctor`'s leftover-settings warning, and only when someone happened to run it.
- **A failure here goes through the same cleanup as every other post-launch failure** (step the launched successor down, `failed`, non-zero exit). It's placed **before the pointer moves** for the same reason the final-output wait is: rein has no way to roll the pointer back, so while the pointer still names the predecessor, cleaning up takes nothing beyond the existing path. The reason says explicitly that the session **did** come up -- launch confirmation already passed one step earlier, so a reason reading like a launch failure would send the investigation to the wrong place.
- **Both entry points go through it** (cold start's first session and a handover's successor), so neither can start out unmanaged without it being said out loud.
- The grace period is **a guardrail, not a target**: on a healthy launch the file is already gone by the time the launch is confirmed, so the wait ends on its first check and the 10 seconds are never spent. They're only ever consumed on the failing path, which is why the value is set generously -- 2 of the default polling intervals -- so a hook that's merely slow on a loaded machine isn't misread as a marker that never arrived.

## How a session is addressed (session ID and short job ID)

Each element of `claude agents --json` carries `sessionId` (the full session ID -- a UUID) and `id` (the short job ID -- e.g. `cad54b97`) **as separate fields.** `claude stop` / `claude attach` only accept **the short job ID** -- passing the full session ID exits non-zero with `No job matching` (observed).

| Context | ID passed |
| --- | --- |
| The marker's `session_id` / the pointer's `session_id` and `predecessor_session_id` / each ID in the handover log | The full session ID |
| `claude stop` (the step where the watcher externally stops the predecessor session) | The short job ID |
| `claude attach` (the step where the attach loop re-attaches) | The short job ID |

- **An ID appearing in the contract is always fixed as the full session ID.** The short job ID is a convenience the CLI holds at runtime, not something to persist as state (persisting it would lose track of the target if enumeration ever renumbers it differently).
- **Resolving to the short job ID happens right before calling the CLI**, from `claude agents --json` at that moment (looking up the `id` of the element whose `sessionId` matches).
- **Slicing the first 8 characters off the UUID is never used as a shortcut.** The correspondence between `id` and `sessionId` is the CLI's internal implementation detail, and prefix matching is not a guaranteed part of its contract.
- **Failing to resolve it fails loud** (no match in the enumeration, the enumeration can't be read, or an element has no `id`). It's never papered over by substituting the full session ID and calling the CLI with that instead -- a notification, a `failed` event, and a non-zero exit surface it instead.

**Only a background session carries a short job ID** (observed). Elements of `claude agents --json` split shape by `kind`: only `kind:"background"` carries `id` (the short job ID) and `state`. `kind:"interactive"` carries `pid` and `status`, but no `id` and no `state`. `status` holds a real value (`busy` / `idle`) for a live background session too, and **the `status` and `pid` keys themselves are absent only for a terminated element.** The consequences:

- **The attach target is always a background session.** If the pointer names an interactive session, the attach loop never attaches -- it notifies and exits non-zero instead.
- **An interactive session can't be stopped externally.** If the predecessor is an interactive session and it still hasn't exited by the end of the grace period, the watcher can't issue `claude stop`, so it marks the handover `failed` with a reason that says so explicitly (it's never silently treated as complete). The only way to end it is for the user to end the interactive session themselves.
- Therefore **the first session is also launched as a background session** (`--bootstrap`). A primary session started as an interactive session can never be stopped externally, under this contract.
- **Liveness is read as `.status // .state`, in that order -- never from `state` alone.** `state` reaching `done` is not a mark of termination: every time a turn ends, a live background session shows up in regular enumeration with `state=done`, `status=idle`, and a `pid`, so reading `state` first would call a perfectly healthy primary session finished on every single turn. What marks a terminated element instead is that it carries **no `pid` and no `status` key at all**, which leaves `state` (`done` / `stopped` / `blocked`) as the only thing left to read there.

## Handover log `handover.log`

The only writer is the watcher. The attach loop's records go into a separate file (`seat.log`) instead (see [the locations and locks specification](runtime.md)) -- the column convention is the same, but putting 2 writers in one file would make it impossible to later reconstruct which mechanism wrote which record.

The handover log is **JSON Lines, one event per line** -- append-only, never truncated.

```json
{"schema":"rein.handover-log.v1","ts":"2026-08-15T04:13:02Z","event":"marker_accepted","detail":"handoff=/Users/you/Projects/example-app/.rein/handoff.md","generation":4,"predecessor_session_id":"0aa35181-...","successor_session_id":null}
```

| `event` | Meaning |
| --- | --- |
| `watch_started` | The watcher started watching the target cwd |
| `marker_accepted` | The marker passed freshness validation and entered a handover |
| `marker_rejected` | Freshness validation rejected it (`detail` carries the rule name and the measured values; `generation` is `null`) |
| `marker_recovered` | A marker left stranded in `processing/` by a previous watcher run that stepped down mid-judgment was recovered to `rejected/` at startup (`generation` is `null`) |
| `marker_cancelled` | The handover was cancelled because the user spoke (`generation` is `null`; `detail` carries the generation it was accepted as) |
| `cancel_after_window` | The user's cancellation reached the runtime data only after the window had closed, so the handover completed as scheduled (the round carries its own `generation`; a notification goes out too) |
| `final_output_wait_expired` | The final-output signal didn't arrive within the cap, so it fell back to an immediate handover as before |
| `successor_launching` | Issued the successor's launch command |
| `successor_launched` | Confirmed the successor's session ID via enumeration |
| `pointer_updated` | Switched the current pointer to the successor |
| `predecessor_exited` | Confirmed the predecessor session disappeared from enumeration during the grace period |
| `predecessor_stopped` | Didn't disappear during the grace period, so externally stopped it with `claude stop` |
| `handover_completed` | The handover completed every stage |
| `successor_orphaned` | A successor launched for a handover that didn't go through couldn't be identified or stopped, and was left behind outside management (`generation` is `null`) |
| `successor_stopped` | A successor launched for a handover that didn't go through was retired with `claude stop` (`generation` is `null`) |
| `failed` | Some stage failed or timed out (`detail` carries the stage and the reason) |

- **A rejection is recorded only as `marker_rejected`** (never also as a `failed` for the same reason). Rejection has its own independent vocabulary in the event set, and double-logging it would make it impossible for an audit log to tell "one input error" apart from "one mechanism malfunction." `failed` is used only for a stage failure.
- **A cancellation's `generation` is `null`, with the generation it was accepted as kept in `detail`** -- since the pointer never advances, the next successful handover reuses that same number. Putting the number itself in the top-level field would let an audit confuse 2 separate handovers, but which acceptance disappeared can still be traced.
- **A cancellation is never the same event as a rejection** -- a rejection is a defect in the request itself (fixable), while a cancellation is the user deliberately stopping it (nothing to fix); the next step differs between them. Their archive destinations differ too (see [the locations and locks specification](runtime.md)).
- **A cancellation that took effect (`marker_cancelled`) and one that arrived too late (`cancel_after_window`) are never the same event.** The first means no successor was ever launched and the seat stayed where it was; the second means the seat has already moved and the words only explain themselves. Folding them together would leave an audit unable to tell whether that lineage handed over at all, and would let one word claim both `generation: null` and a real generation number.
- **A handover that didn't go through gets no generation number.** `marker_rejected`'s `generation` is `null` (numbering happens only once accepted -- a number on a rejection line would let the next successful handover claim the same number, and an audit would misread the two).
- Cold start (`--bootstrap`) records `successor_launching` / `successor_launched` / `pointer_updated` with the predecessor as `null` (no dedicated event is added for it).
- **A recovery (`marker_recovered`) is never the same event as a rejection.** A rejection means the user's input failed freshness validation; a recovery means the previous run stepped down mid-judgment -- the cause and the next step both differ (collapsing them into one would make it impossible to reconstruct "why did that request disappear" from the audit log). For the details of recovery, see [the locations and locks specification](runtime.md).
- **A call where a successor was launched but the handover didn't go through gets the disposition of that successor recorded too** (`successor_orphaned` / `successor_stopped`). A successor left behind in the same working tree with nothing pointing at it is the most dangerous state this mechanism can reach, so a call where cleanup succeeded and one where it didn't are kept as distinct events. `successor_orphaned` also fires a macOS notification and lands in the operational log at the same time.
- The handover log is a plain file for now (this module only writes to its own 2 locations -- it never adds a writer to the user's own records).

## Timeouts and notifications (fail-loud)

**Each stage has a cap, and exceeding it is surfaced through a macOS notification (`osascript`), stderr, a `failed` event, and a non-zero exit** (a silent standstill is never produced).

| Stage | Settings key |
| --- | --- |
| The watch polling interval | `poll_interval_sec` |
| From acceptance until the final-output marker arrives | `final_output_timeout_sec` |
| From confirming the marker until launching a successor (the window for accepting a cancellation) | `final_output_wait_sec` |
| Until the successor shows up in enumeration | `launch_timeout_sec` |
| From confirming the launch until the successor deletes the temporary launch settings (the proof the managed marker reached it) | 10 seconds, fixed (no key of its own -- never spent on a healthy launch, where the file is already gone at the first check) |
| The grace period after the pointer updates, before externally stopping the predecessor session | `exit_grace_sec` |
| Until it disappears after being externally stopped | `stop_timeout_sec` |
| How long the attach loop waits for the pointer to change | `seat_wait_timeout_sec` |
| How many times the attach loop retries a failed attach | `seat_attach_retry_max` |
| The cap per external command call | `cmd_timeout_sec` |
| How old the attach loop considers the watcher's heartbeat before calling it stale | `seat_heartbeat_max_age_sec` |
| How old hooks consider the usage record before calling it stale | `usage_stale_sec` |
| **The cap for one enumeration call** (`claude agents --json`) | `cmd_timeout_sec x 3 + 2 seconds` (composed, no key of its own -- a transient failure is measured up to 3 times, with a 1-second sleep between attempts. 182 seconds by default) |
| Until the seat's watchdog decides it's "fallen behind on the handover" | `exit_grace_sec + cmd_timeout_sec + stop_timeout_sec + (the per-enumeration cap) x 3` (composed, no key of its own. 681 seconds by default) |
| **The window where the successor and the predecessor session coexist in the same working tree** (from the pointer updating until the predecessor session disappears) | `exit_grace_sec + stop_timeout_sec + cmd_timeout_sec + (the per-enumeration cap) x 3` (composed, no key of its own. approximately 681 seconds by default) |

- The overlap window is **a cap, not a target** -- if the predecessor session disappears during the grace period, no external stop is ever issued, and the window closes right there. This window's premise (the predecessor session is idle by the end of its turn) and the user's own convention (never typing into the predecessor session's terminal during the window) live in [the handover contract architecture](architecture.md), "The handover sequence."
- **A background session has no way to end itself**, and `claude attach` never returns on its own once its target reaches `done` -- a predecessor that submitted a handover request stays attached and alive however long the wait runs, and the seat only gets its terminal back once the external stop lands. That is why the sequence ends in an external stop after a grace period rather than waiting the predecessor out, why the grace period is kept short, and what the seat's own watchdog is watching for.
- **3 enumeration calls fall inside the overlap window**: confirming the predecessor session's exit, resolving its job ID, and confirming its exit after the external stop. And since the wait for confirming an exit checks its deadline **after** calling enumeration, even a 15-second grace period can overshoot by a full presence check. That's why the composed formula isn't "the sum of each stage's cap" -- it's the per-enumeration cap counted 3 times.
- **The seat watchdog's threshold assumes the same worst case as the overlap window above** (`scripts/rein-seat.sh`'s `watchdog_limit_sec`) -- it folds in enumeration retries, so it never fires while the watcher is correctly re-measuring. It used to be `grace + cap + exit-confirmation` with no retries folded in (135 seconds by default), under which a false alarm of "fallen behind" with no such thing happening was structurally possible even while a handover was proceeding normally. The per-enumeration cap and "how many stages pass through enumeration" are pulled from **the same place as the retry constants** (the shared library's `rein_list_agents_worst_sec` and `REIN_RETIRE_LIST_AGENTS_CALLS`) -- the formula is never copied over to the seat side to go stale on its own.
- **The same threshold is also the spacing between repeats**, because the watchdog doesn't stop after the first firing -- it keeps reporting while the pointer and the connection stay out of step (see "The seat's own watchdog" in [the handover contract architecture](architecture.md)). No key of its own is added for the spacing: the threshold is already "the longest a legitimate handover can take," which is exactly what a repeat interval needs from below, and it moves with the same configured caps, so a lineage that widened them widens the spacing too.
- **The 2 composed values landing on the same 681 seconds isn't a coincidence** (they're counting the same worst-case steps). The watchdog fires only when the threshold is **exceeded**, and measurement starts on the cycle after the pointer's change is observed -- so even a handover that used up exactly the worst case, to the second, never fires it.
- **The default values are never written here** -- the canonical source is the implementation (`rein config list`'s output), which also carries what each key means and what values it accepts.
- Every settings key can also be passed as the environment variable `REIN_<KEY IN UPPERCASE>` (see [the config specification](config.md)).
- **A stage's timeout only takes effect between iterations of a loop**, so a cap is also placed on the external command **call itself** (`claude --bg`, `claude stop`, `claude agents --json`). The cap is enforced with macOS's own `perl`'s `alarm` (BSD has no `timeout(1)`), and exceeding it is recorded as exit code 142 in `failed`.
- **The cap bounds "the group of processes a command spawned," not a single process.** The capped runner doesn't replace `perl` with the target command; instead it `fork`s a child, makes it the leader of its own process group with `setpgid(0, 0)`, and launches it that way. On a timeout, it kills that whole group, so any descendants the command left behind (a setup where `claude` sits behind a wrapper script that never `exec`s, or one that forks off into a separate process at launch) get taken down with it. **2 things are guaranteed**: (a) the capped runner itself always returns around the cap, and (b) a caller that captures output via command substitution (`$( )`) -- `rein_list_agents` and `rein_notify` -- also returns around the cap. (b) matters because command substitution waits **until the stdout pipe closes**, and a surviving descendant would leave that pipe open.
- **Outside the guarantee** (stated explicitly, so a green run is never read as "always returns by the cap no matter what"): if a descendant **starts its own new session** and steps outside the group, a signal aimed at the group never reaches it. If that descendant still holds stdout, a caller capturing via command substitution is still left waiting (observed: with a grandchild that calls `setsid` and holds stdout as a fake command, a 2-second cap still left the caller waiting 12.44 seconds -- until the grandchild finished). The capped runner itself still returns by the cap, as in (a) -- **only (b) breaks down in this case.**
- **A timeout fires with one single KILL, with no TERM grace period first.** The cap is an input to composed values (`rein_list_agents_worst_sec` and the seat watchdog's threshold), and inserting a grace period would push the actual time per call over the composed value by that much, bringing back false alarms while it's correctly re-measuring. Even back when it used `alarm` on the raw command, the timeout used `SIGALRM`'s default behavior too (an immediate death with no cleanup), so how roughly the target gets cut off is unchanged. **A call that finishes normally never sends a signal at all.**
- **The capped runner forwards any `INT` / `TERM` / `HUP` / `QUIT` it receives to the child's group.** A child moved into its own group never receives a terminal signal (Ctrl-C) directly, so without forwarding, only the capped runner would die while the command itself was left stranded (back when the raw command received it directly, this held automatically -- forwarding keeps that property).
- **The capped runner also reports "the command couldn't even be launched" as non-zero (127).** perl's `exec` merely returns false on failure without ending the program, so if the last statement is `exec`, **the command never runs at all, yet the exit code comes back 0** (`rein init` reports "enabled the plugin" and `rein prune -s -f` reports "deleted" as a success, even in an environment where `claude` isn't on PATH). The reason is also printed to stderr and folded into the failure text.
- **A transient enumeration failure (`claude agents --json`) is measured a few more times at the enumeration call site before it's treated as a failure.** A single failed call is realistically possible -- the CLI briefly not responding, right after waking from sleep -- but if that single failure alone brought down both residency (the watcher) and presence (the seat), the guarantee of unattended operation ("zero manual steps to attach to the successor") would break on every such blip, recoverable only by the user running `rein up` again by hand. Rather than giving each reader (a liveness check, resolving a short job ID) its own tolerance, it's centralized at **the single enumeration call site** (so which readers tolerate it and which don't never splits apart). A persistent read failure still fails loud as before, once the cap is used up. The count and interval aren't operational parameters for the user, so they're not exposed in settings.
- **Only `claude attach` is left uncapped** -- never returning while the user is sitting at the seat is the normal state, and cutting it off on a timer would seize a seat mid-use.

### Checking prerequisites at startup

**A prerequisite tool** is checked by **whether it actually works**, not by whether it's on PATH (if it's missing, that's a notification plus a non-zero exit).

| Prerequisite | What it's actually relied on for |
| --- | --- |
| `jq` | Reading and writing JSON |
| BSD `date` | `date -u -r <epoch>` (epoch -> the contract's time format) |
| BSD `stat` | `stat -f` (reading mtime, size, and mode) |
| `perl` | `alarm`, plus `fork` / `setpgid` / `waitpid` (the external command's capped runner), plus `Time::HiRes`'s `clock_gettime(CLOCK_MONOTONIC)` (a process-local monotonic clock for deadlines). **The check is split in two** (shown as `perl(alarm)` and `perl(CLOCK_MONOTONIC)` when missing) -- if the monotonic clock can't be read, the deadline value comes back empty, `$(( + cap))` collapses to just the cap, and **every wait gets cut off on its first cycle** (this is the kind of silent, structural loss of a cap that gets surfaced right at startup) |
| `shasum` | `shasum -a 256` (the digest a lineage's key ends with -- `<cwd's basename>-<first 12 characters>`, which keeps same-named projects apart). Every location a lineage has is named by that key, so without this the runtime directory cannot be resolved at all; before the check covered it, that surfaced as the unrelated reason "cannot resolve the location for runtime data" |
| `ps` | `ps -p` (reading a process's liveness and start time). Under a `ps` that never answers, there's no way to tell "gone" from "can't confirm," so every lock falls on the side of "don't seize it," and the lineage stops |
| `od` | `od -An -v -tx1 -N32 /dev/urandom` (drawing the lineage token). The check runs the same shape in miniature -- the flags and the device together -- because a short or non-hex draw is refused rather than padded: without it, the failure surfaces only when a lineage is provisioned, as "cannot draw a lineage token," after which every hook of every session of that lineage fails loud on the missing token |

- **A GNU-flavored `date` / `stat` present under the same name on PATH doesn't work for what it's relied on** (`date -r` refers to a file, not an epoch, in that flavor; `stat -f` shows filesystem information rather than accepting a format specifier). Checking only whether it's there would let this check pass silently on Linux.
- Converting the contract's time format into epoch is done arithmetically (spawning no external command), so `date`'s implementation differences never show up there. That's why the check is performed against **the actual dependency** (epoch -> format). `date -j -f` is only used to check the answer in selftest (see [the development conventions (gates, selftest, terminology, distribution)](development.md)).
- Without this check, a missing tool shows up as **a rejection under a misleading reason, such as `R1 cannot be parsed as JSON` or `R4 cannot parse requested_at as UTC, second precision`**.

**Numeric settings** have their type and range held by the settings layer's known-keys table, and an invalid value is a notification plus a non-zero exit.

| Kind | Type and range |
| --- | --- |
| Timeout-style | Non-negative integer |
| Polling interval | Positive number (decimals allowed) |
| External command cap, log cap | Positive integer |
| Cooldown duration, usage freshness, escape-hatch cap (`notice_cooldown_sec` / `usage_stale_sec` / `snooze_max_sec`) | Positive integer (`0` isn't allowed) |
| Threshold | 0 to 100 |
| `--max-attach` (outside the settings layer -- the attach loop checks this one itself) | Non-negative integer |

- **`0` never means "no cooldown" or "the escape hatch is disabled"** -- these 3 values only accept positive integers, and `0` is rejected on the type side (settings never carries a value that silently disables a feature).
- Without this check, `sleep abc` would just return non-zero in 0.004 seconds -- silently collapsing into **a loop that never waits** (pegging the CPU while hammering enumeration). Likewise, an invalid wait cap would silently collapse to `deadline=0`, i.e. waiting forever.

### Never discarding a failure's reason

**A failure is always kept with its reason** (in a daemon-style workflow that can't be reproduced after the fact, material that explains the cause is never thrown away).

- A failed external command has its **exit code and stderr's last line** kept in `failed`'s `detail` and in the handover log (a daemon-style workflow can't reproduce it later).
- **Failing to write the handover log is itself treated as loud.** A write failure for `watch_started` (before entering the watch) or `handover_completed` (recording completion) results in `failed` plus a non-zero exit -- a handover never proceeds while only the audit record has gone missing. Where even `failed` can't be written, that fact goes to stderr instead.
- **The notification channel's silence is never allowed either.** If `osascript` is missing or fails to run, that fact is appended to stderr (a GUI notification's delivery can't be confirmed, so nothing relies on it alone).
- **"Can't read the enumeration"** and **"the successor hasn't shown up yet"** are treated as distinct. The former is `failed` immediately, without waiting (waiting out the cap in an unreadable state would fail with text that points at the wrong cause).
- **`claude attach`'s exit status is always checked.** If it returns non-zero and the pointer has changed, the loop re-attaches to the successor as-is; if the pointer hasn't changed and the target is still alive, it retries up to the cap, then notifies and exits non-zero.
  - Treating an attach failure the same as "the user stepped away" would display "waiting for the handover" even though the attach never actually succeeded -- indistinguishable, from the user's side, from a normal wait.

## Executing a handover (the command)

All 4 channels involved in a handover (cold start, the watcher, the attach loop, and a handover request) are launched through `rein`.

```sh
# cold start (launches the first primary session and creates the current pointer; runs once and exits)
# rein layers the background-session isolation override onto the launch settings itself, so it's never passed here.
rein --cwd ~/Projects/example-app bootstrap

# the watcher (one instance per target project; run this as a resident daemon)
rein --cwd ~/Projects/example-app up

# the attach loop (run this in the user's own terminal)
rein --cwd ~/Projects/example-app attach

# a handover request (run by the session submitting the request itself; kickoff points to this)
rein --cwd ~/Projects/example-app request \
  --session-id <your session ID> --handoff <handoff document's absolute path>
```

- **Calling `scripts/rein-watcher.sh` directly, bypassing this, drops 2 rules** (it never takes the operation lock, and without an absolute launch path, liveness identity checking fails) -- the channel to run it as a resident process is `rein up` (see [the per-verb internal conventions](cli.md), "Launching the watcher directly").
- `--settings` is passed straight through to `claude --bg` (either a file path or a JSON string works). Config's `settings` key can also carry the same value (a CLI flag wins).
- **A `settings` value that contains a secret (a credential, etc.) should be passed as a file path** -- a value passed as a JSON string can end up in a failure-reason channel (the handover log, a notification, stderr) if `claude` fails and prints an error containing that value. The implementation **masks any substring matching the effective value as `***` before it goes into a reason text**, but it can't catch a value that got transformed along the way.
- Automatic worktree isolation for a background session is overridden by rein layering it onto the launch settings (see [the locations and locks specification](runtime.md), "Settings a background session is launched with").
- For a lineage with config's `model` set, `--model` is passed to the successor's launch (a channel for pinning the model across generations; empty follows the CLI's own default).
- `bootstrap` only proceeds when either there's no pointer, or the pointer's target has already terminated. If it names a live session, it notifies and exits non-zero instead (2 primary sessions are never created).
- The first session's kickoff also carries the handoff document -- via `--handoff`, or config's effective value for `handoff_path` (including the default) if that's omitted -- and confirms **it's in an acceptable shape** (a regular, non-symlink, non-empty file) before launch. If it isn't acceptable, launch fails with the reason plus a runnable `rein --cwd <target> init` for that lineage (the template must be created per lineage, so a message with no `--cwd` would create the template for whichever lineage the command happened to be run in). Only a lineage with `handoff_path` explicitly set empty can launch a first session with no handoff document.

## What goes into kickoff

**How much the successor reads on its first turn directly becomes the fixed cost of a handover** (whatever gets included gets read). Only the following 3 things go in:

1. **The handoff document's absolute path** (the successor is never left to choose which of several handoff documents to read)
2. **A note on how to read it** -- verbatim: "Read only the sections you need to resume, and do not re-read it in full or pre-read related documents."
3. **The one-line handover request command** (`<the absolute path to rein's own implementation> --cwd <absolute path> request --session-id <your session ID> --handoff <absolute path>`; the contract is never left for the successor to reconstruct from prose)

The literal specification for the handover request command (the successor runs this one line as-is):

- **The command is printed as the absolute path to `bin/rein`, resolved from repo root** (it never depends on the `rein` on PATH -- so a watcher launched through a symlink still points at the same one implementation). A session loaded as a plugin also has a `bin/rein` under plugin root pointing at that same implementation, but **the skill's own instructions use the `rein` on PATH** (matching the same shape hooks return in their own text -- so instructions for the same action are never split into 2 forms; the plugin gate rejects a call made through plugin root inside a skill).
- **The path is shell-escaped to a single word.** Even an absolute path containing whitespace, `'`, `;`, or `$( )` never splits into separate arguments, and never gets evaluated as unintended shell syntax. Only the placeholder that still needs filling in (`<your session ID>`) is left unquoted.
- **A line break separates the command from what comes before and after it.** Concatenating a sentence right after it would leave the successor with no way to tell, from the literal text, where the command actually ends -- it would run everything up through the closing period as part of the path, and the handover would stall in that generation.

Alongside these 3, 2 more sentences are included, each as its own sentence (both close off a mistake on the successor's first turn without expanding what it needs to read):

- **That the handoff document is this one, and only this one** (the successor is never sent to look for any other handoff document)
- **That once this runs, the watcher launches the successor, so no new work should begin until instructed** (the successor is never left continuing its own work after submitting the handover request)

There are exactly 2 exceptions and additions:

- For a lineage with no handoff document (`handoff_path` explicitly set empty), only cold start skips item 1. In that case it says only "begin work as this project's primary session," and the handover request command's `--handoff` is left as a placeholder (the user fills in the absolute path to their own handoff document).
- If config has `kickoff_note_path`, **only one line pointing at where it is** gets added (rein never reads its contents -- it carries no opinion about the project's own semantics). Anything that would expand what needs to be read, such as a transcript path, is never included (it can be traced from the handover log's session_id if it's ever needed).
