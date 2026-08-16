# Handover contract design

The handover contract's invariants, how the layers divide the work, the handover sequence, the requirements for unanticipated ways of using it, and what this contract does not cover.

Throughout this document, "handover" names the event and mechanism, and "handoff document" names the file a session writes for its successor -- see the definitions in [the terminology contract](development.md).

## Invariants

A primary session's handover is defined as **a file format shared between the session issuing the handover request and the watcher**, and that format never takes on the target project's own semantics.

- Only cwd, session ID/name, file paths, and timestamps appear in the contract. None of the target project's own vocabulary -- tasks, milestones, progress -- ever enters it.
- **The guarantee is that state is always externalized -- not that a handover gets detected.** As long as the primary session updates the handoff document at every natural break, any loss stays confined to what happened since the last break, however the handover itself goes. A successor can always resume from that document.
- A well-timed, threshold-driven handover is an optimization for a smooth experience -- when it misses, the fallback is a rough handover, never data loss (this is why detection itself was never made the guarantee).

## How the layers divide the work

**This module newly owns exactly two things -- executing a handover, and the seat's continuity** -- everything else already has a writer somewhere, and a second writer is never placed over the same thing. The one exception is the usage record, where a writer ships bundled, but **the user registers it, and rein never rewrites the user's own settings** (bundling it is providing a means, not adding another writer).

- **Seat** means the place the user's own terminal is connected to through `claude attach`, and nothing else. The attach loop (`rein-seat.sh`) keeps that connection up, and repoints it to the successor at every handover. Wherever this document says "seat," it always means that same place.

| Layer | Owner | What's new in this module |
| --- | --- | --- |
| **Recording** usage | The user's own `statusLine` (either the bundled `rein-statusline.sh`, registered, or any other writer that writes a record matching the contract) | The writer ships bundled, but **isn't registered** (rein never rewrites the user's own settings) |
| **Watching** usage and prompting a handover | rein's plugin hooks (see [the hooks specification](hooks.md)) | New, as a reader of the record (no new writer) |
| Issuing a handover request | The primary session itself (writes the handoff document through to completion, then runs `rein request` in one line) | Only provides the writer command |
| Executing a handover | `rein-watcher.sh` (every step under "The handover sequence" below) | New |
| The seat's continuity | `rein-seat.sh` (the attach loop that watches the current pointer and repoints `claude attach`) | New |

## The handover sequence

The primary session runs under **a standing rule**: write back to the handoff document at every natural break, and start a handover once the context is close to running out.

1. At **its own turn's natural break**, the primary session flushes any running child agent to completion, writes the handoff document through to completion, and places the handover-request marker with `rein request` (see "Handover request marker" in [the handover specification](handover.md)).
   - It never hands over while a child is still alive -- replacing the parent would drag the child down with it. **This is held by machine on both channels that can start a handover, not by the session remembering to**: `Stop`'s push defers while children are running, and `rein request` -- the only channel that writes the marker, and the one a session runs by hand -- fails non-zero without writing (see "The only way to write the marker is `rein request`" in [the handover specification](handover.md)). What `rein request` reads is the ledger of running children the hooks keep, because that process receives no payload of its own; before it existed, a handover requested by hand went straight through while 3 children were running, and 2 of them ended having written nothing (observed).
   - **The marker is never placed if the watcher isn't resident** (`rein request` fails non-zero and sends one notification). Placing it anyway would leave nobody around to claim it, and the leftover marker would then reject every request that follows. The hooks run through this same judgment, so a handover request that is out with no watcher around never goes unreported (see "Stop" in [the hooks specification](hooks.md)).
2. The watcher claims the marker and **verifies its freshness and correspondence** (see "Freshness validation" in [the handover specification](handover.md)). Anything that doesn't hold is rejected and reported (fail-loud).
3. **Before launching a successor**, the watcher waits for the session that issued the request to finish printing its response (see "Waiting for the final output before launching a successor" in [the handover specification](handover.md)).
   - The session still writes a wrap-up of that turn even after issuing the request, so proceeding without waiting would stop the predecessor before the user gets to read it.
   - **If the user says something during this window, the handover is cancelled and the watcher goes back to watching** (no successor has been launched yet). rein does not re-push a handover for the generation that got cancelled this way -- the user's own request outranks rein's.
4. The watcher launches a successor with `claude --bg --name <a descriptive name>`. The kickoff carries only **the handoff document's absolute path**, **a note on how much to read**, and the one-line handover-request command (see "What goes into kickoff" in [the handover specification](handover.md)).
   - The launch settings that disable a background session's automatic worktree isolation are assembled and passed by rein (see "Settings a background session is launched with" in [the locations and locks specification](runtime.md)).
5. **Before the pointer moves**, the watcher confirms the managed marker actually reached the successor: it waits up to a fixed 10 seconds for the temporary launch settings file to disappear, which is the one observable proof that the successor's SessionStart hook read the marker (see "Current pointer" in [the handover specification](handover.md)).
   - A session the marker never reached **isn't visibly broken** -- it comes up and keeps working, it simply gets nothing at all from rein's hooks. So if the file is still sitting there when the grace period runs out, the round goes through the same cleanup as every other post-launch failure (the launched successor is stepped down, `failed`, non-zero exit) rather than pointing the lineage at it.
   - On a healthy launch the file is already gone by the time the launch is confirmed, so this ends on its first check and the 10 seconds are never spent.
6. The watcher switches the current pointer over to the successor. The attach loop detects it and repoints to the successor (**zero action from the user**).
   - Even hitting the roughly one-hour idle auto-stop, `claude attach` restarts with transcript restoration, so the seat is never lost.
7. The watcher **waits out a grace period of `exit_grace_sec` (default 15 seconds), then stops the predecessor session externally with `claude stop`**. If the predecessor is already gone by the end of the grace period, the stop is never issued.
   - **The predecessor session has no way to end itself** (observed), so this step is never built to wait for the predecessor to end on its own -- because `claude attach` only ever returns once the predecessor is stopped, any time spent waiting is exactly the time the seat stays empty.
8. The watcher appends each step (timestamp, old and new session IDs, verification results, failure reasons) to the handover log (see "Handover log" in [the handover specification](handover.md)).

**Between steps 4 and 6, the successor and the predecessor session coexist in the same work tree.** The successor picks up kickoff and resumes work the moment the pointer switches, and the predecessor is only stopped afterward, so there's always a window where both sit in the same directory (isolation is `none` -- rein disables a background session's automatic worktree isolation). By default this is **normally 15-80 seconds** (the `exit_grace_sec` grace period plus the round trip of the external stop), and **about 681 seconds** in the worst case, if every configured cap is exhausted. The derivation of each term, and of how the seat watchdog's own threshold is set against this window, is canonical in [the handover specification](handover.md), under "Timeouts and notifications." (The composed formula itself appears once more below, in the watchdog's own section, because it is that watchdog's firing condition.) This window holds together only because **the predecessor session is idle by the time its turn ends** -- since a handover request is issued at that session's own natural break, the requesting predecessor never touches another file after that. So **never type into the predecessor session's terminal during this window** (doing so creates two sessions editing the same files at once, the successor and the one you just typed into). Whether the window has closed can be checked in `rein status`'s `stranded` line.

### The seat's own watchdog (never staying silent through a stall while attached)

**While attached, the seat occupies the terminal and has no way to judge anything on its own**, so right before attaching it launches a child process to watch on its behalf.

- The watchdog fires once `exit_grace_sec + cmd_timeout_sec + stop_timeout_sec + (the per-enumeration cap) x 3` has passed since the pointer switched to the successor and attach still hasn't returned. **Its threshold is deliberately set to the coexistence window's own worst case** (681 seconds by default), which is why the two carry the same formula -- anything shorter would fire while the watcher is still correctly re-measuring, rather than on a stall.
- Firing produces a **notification and a line in the seat's own log** -- it never touches the terminal or the attach connection (there's no active detach -- the mechanism never seizes a seat the user is actively working in). Both, not just the notification: once a notification is dismissed, or missed because nobody was at the machine, nothing survives it, and the observed stall below could be reconstructed only because a temp file happened to escape cleanup.
- **It keeps notifying for as long as the two stay out of step.** Firing once and going quiet made the whole mechanism single-shot: observed, a seat sat on the predecessor for over 4 hours after the pointer had moved on, and the one notification -- fired while nobody was at the machine -- was the only thing ever said.
- **The spacing between repeats is not the firing threshold.** The threshold has to cover the worst case a legitimate handover can take, so the first notification is never a false alarm; the spacing only has to bring back a state already confirmed to be wrong, and by then the false-alarm question is settled. Reusing the threshold put both jobs on one number and broke at both ends (measured): `cmd_timeout_sec` at 300 gives a threshold of 3081 seconds, at 600 it gives 6081 -- 51 and 101 minutes between reports, which for any realistic sitting is back to the single-shot behaviour the repeat exists to fix -- while the minimal settings a selftest uses give 16 seconds, four notifications a minute. So the spacing keeps the derivation (a lineage with wider caps still gets wider spacing) and is **clamped to between 5 and 15 minutes**. The bounds bracket the default rather than moving it: the default threshold, 681 seconds, already sits inside the range, so an ordinary lineage still reports roughly every 11 minutes and only the extremes are pulled in.
- **There is deliberately no way to silence it.** The lineage has a snooze vocabulary and the watchdog does not read it: a pointer and a seat out of step is always wrong, and the mechanism already refuses to act on it, so the notification is all that is left. Whether someone deliberately staying on an old session needs a way to quiet it is a question for the user, not one to settle by adding a key.
- **The reason line leads with what to do about it**, then the measurement: the only thing that returns attach is the user leaving the agent list screen the detach left them on, so that instruction is what the notification opens with (a notification can be cut off at the tail, and a reason the user can't act on is the same defect as silence). The wording is held in one place and shared with `rein status`'s seat line, so the two surfaces can't send the user somewhere different.
- The notification's reason line only prints to the terminal once attach returns (the terminal is occupied by the TUI while attached).
- Its purpose: the premise that an external stop is what brings attach back can break -- **observed**, and not through the external stop at all: `claude attach` replaces itself with the agent list on detach, so a detach the user triggers from the keyboard leaves attach never returning while the seat blocks in the foreground, unable to re-read the pointer or reconnect. This observation point is what keeps such a break from turning into a silent stall.

### The seat's own log (`seat.log`)

Whether attach succeeded, and why it failed when it didn't, show up only as a notification and a non-zero exit -- which **leaves no way to trace after the fact what happened in a lineage that runs unattended.** The seat leaves its own observations behind, one line at a time, in the lineage's own log.

- The only writer is the attach loop; the location is the lineage's log, resolved the same way the handover log is; the line-format conventions match the handover log's. Details are canonical in [the locations and locks specification](runtime.md).
- It doesn't share the handover log, because that log's writer is the watcher and only the watcher, by contract (two writers on the same file means the lines can't be reconstructed once they interleave).
- **The seat never steps down just because it can't write to the log** (the log is an observation -- it never outranks keeping the seat the user is sitting in).
- Its readers are the user, an audit, and `rein status` -- which reads it twice over, for two different things: the last line's event and timestamp (as its own display line), and **the last of the three life-cycle lines (`seated`, `attach_started`, `attach_ended`), which is the only record of what the seat is connected to**. The seat lock declares who is seated and nothing about the target, so without that second read the seat line can only report presence, and a seat stuck on a session the pointer left behind reads the same as one that is following it.
- **The pair matters as much as the start does.** With only `attach_started`, that read answers "where did the seat last go," not "where is it now" -- and the two differ from the moment attach returns until the next one begins: across the successor being resolved, and through an entire wait for a handover nobody has requested yet, which has no time limit on it. Read that way, the ordinary between-attaches state reports as a live connection in step with the pointer, which is the same shape as the stall this whole observation point exists to surface. `seated` closes the other end: the log outlives the process that wrote it, so without a line marking a new occupancy a fresh seat that has not attached yet would inherit whatever the previous seat was connected to.

### How the seat ends (`rein down` shuts the lineage down)

Since the seat's continuity carries across a handover, **its ending is defined by the contract too** -- `rein down` places a seat-stop marker (one piece of runtime data) before externally stopping the primary session, and the seat that sees attach return clears that marker and exits quietly with 0.

- Without the marker, the seat cannot distinguish an anomaly (the session ended, but the current pointer was never updated) from attach simply returning, and every stop the user issues by hand would produce one notification.
- The only writer is `rein down`; the only reader (and the one that clears it) is the attach loop. The format and cleanup discipline are canonical at `seat.stop` in [the locations and locks specification](runtime.md).
- The path where the user steps down with Ctrl-C is unchanged (the marker only ever communicates "the mechanism shut this down on its own").

## Unanticipated ways of using it (multiplicity and concurrency)

Every row below is **behavior decided as a requirement up front** (not a transcription of an observation). Selftest pins most of them on **both sides** -- that what should happen does, and that what should not does not -- with one exception noted in the row's own reasoning below: the `EnterWorktree` row is measured on one side only. A plain `claude attach` connecting a second terminal is deliberately not among them -- rein has no way to detect it, so there is no requirement to state; the disclaimer for it is the subsection right after this one.

| Usage | Expected behavior |
| --- | --- |
| A second `rein up` on the same cwd | **Idempotent** -- all three layers report being present and exit 0 (nothing new gets launched; exits 0 even when the seat is already present) |
| Running a plain, unmonitored `claude` alongside it, in the same cwd | **Nothing acts at all** -- neither the advisory (threshold injection) nor the Stop-triggered handover wiring; every event emits nothing and exits 0 |
| A second terminal running `rein attach` on the same lineage | **Refused, naming the owner pid of the presence lock** (a lineage has one seat) |
| The primary session itself moves cwd with `EnterWorktree` | The advisory, launching a successor, and the record all stay with the **original** lineage |
| A second lineage on the same cwd, via `--root` | **Runs alongside the first, side by side** (see "Unit of management" in [the locations and locks specification](runtime.md)) |
| A separate lineage exists in a parent directory (nesting) | Never refused, but `rein up` and `rein doctor` **name where it is, in one line** |

The condition and reasoning behind each row:

- **A second `rein up`**: launch and stop are both serialized by the operation lock, so running it twice at once never double-launches the watcher. Only the seat layer is different -- the delegate (`rein attach`) refuses when a seat is already present and returns non-zero, so `up` checks presence first and exits 0 before delegating (`rein attach` on its own keeps refusing, unchanged).
- **A plain, unmonitored `claude`**: hooks act only on a session rein itself launched, and the only evidence of that is the managed marker delivered through the launch settings' `env`. A window opened outside rein carries no marker, so **every event returns before it reads anything else** -- see "A window rein didn't launch gets no action from hooks" in [the hooks specification](hooks.md). Behind that first gate sits a second one that never gets reached from such a window: a handover request issued from a session the current pointer doesn't name is rejected by freshness validation's R10, so rein would never be pushing a request that could be accepted anyway.
- **A second terminal's `rein attach`**: refused because the mechanism never seizes a seat the user is actively working in. A departed seat's leftover lock is picked up by the next seat (the seat is never permanently blocked).
- **`EnterWorktree` moving cwd**: hooks derive the lineage from the managed marker's env, so the lineage is never lost just because cwd moved. **This is the one row measured on a single side** -- selftest pins that the advisory and the record stay with the original lineage once cwd has moved, but there is no counterpart case, and launching a successor is never measured under a moved cwd.
- **A second lineage via `--root`**: a lineage's identity is the pair (cwd, root), and both the record and the runtime data are split per root. Neither one writes into the other's current pointer, log, or runtime data.
- **Nesting**: the unit of a lineage is its cwd, so nesting is a legitimate way to use it. It's surfaced only to catch the accident of running two lineages side by side without noticing.

### Connecting a second terminal with a plain `claude attach` (disclaimer)

`rein attach`'s refusal **only ever applies to a connection made through rein.**

- `rein attach` keeps **one seat per lineage** (a second connection is refused whenever the presence lock already has an owner).
- Running Claude Code's own `claude attach <short job ID>` directly connects a second terminal to the same session. This is the base product's own regular feature, so **rein can neither block it nor even detect that it happened.**
- What actually happens once connected is canonical in [the locations and locks specification](runtime.md), under "A seat's presence is read from the seat lock" (not repeated here).

The tangle from having a second terminal open, and that terminal terminating at handover, are both **out of rein's scope** (disclaimer).

- Since allowing both to coexist still wouldn't let them do separate work anyway, `rein attach` keeps its refusal that limits a lineage to one seat.
- Avoid it by never using a plain `claude attach`.

## Threat model (what this defends against, and where the user's own domain begins)

**Exactly one thing is defended against: a clone the user received changing rein's behavior without the user knowing.** Conversely, a means of configuration the user already holds themselves (an environment variable, a setting at the user layer) is treated as **inside the trust boundary**, and never inspected.

| Layer | Boundary | Treatment |
| --- | --- | --- |
| Environment variables (`REIN_*`) the user themselves set | Inside (the user's own domain) | Takes effect as-is, per the config layer's precedence |
| The `env` block of the project's own `.claude/settings.json`, which can set those same `REIN_*` variables (the managed marker included) | **Outside** (a clone can bundle it, and Claude Code applies it in a folder that was never trusted itself) | A marker it sets is never taken at face value: the runtime directory it names has to already carry an owner file the user's own `rein up` / `rein init` wrote, **and the marker has to carry that lineage's token** -- 64 hex characters drawn from `/dev/urandom` and kept `0600` inside that runtime directory, which static settings text can neither read nor write |
| User config (`${XDG_CONFIG_HOME:-~/.config}/rein/config`), the user's own `settings.json` | Inside (the user's own domain) | Takes effect as-is |
| Project config (`<cwd>/.rein/config`) | **Outside** (a clone can bundle it -- the person who wrote it isn't necessarily the user) | Only takes effect once it's passed an explicit, per-content-hash decision (`rein config allow` / `deny`) |
| Any other file present inside the target project (whether `.rein/` exists, etc.) | **Outside** | Never makes hooks act (they act only on a session rein itself launched, told by the managed marker env) |

- **Why the inside is never inspected**: anyone who can write an environment variable or the user's own `settings.json` can already run any command they want with that same authority, rein or no rein (through the shell's own rc, or Claude Code's own settings-based hooks registration). Adding a check there wouldn't protect anything more -- it would just take away one of the user's own means of applying their own settings.
- Concretely: `REIN_SETTINGS` (the environment layer of the `settings` config key) being able to override the successor session's launch settings **isn't a threat** at this boundary (anyone who can write the environment already has that authority). **Only specifying the same value through project config** is what the allow gate governs.
- **The environment-variable row has one exception, and it is the clone's own settings file.** Claude Code's own documentation lists the `env` block of a repository's `.claude/settings.json` (and its hooks) as taking effect **in a folder that was never trusted itself** -- a `claude -p` or SDK run there, or a folder covered by a parent folder the user did trust. So a clone can set `REIN_MANAGED*` in a window rein never launched and name any lineage it likes. That is stopped one layer in, at the marker's **validation** rather than at its presence, and the validation is in two parts. First, the runtime directory a marker names must already carry an owner file whose one line is the marker's cwd, and only the user's own `rein up` / `rein init` writes that file. Second -- because that owner file holds nothing but the cwd, a value the marker states anyway, so **naming an existing lineage's real values is itself within reach of static settings text** -- the marker must also carry that lineage's token, kept `0600` inside its runtime directory (see "A clone can supply the marker env" in [the hooks specification](hooks.md)). Nothing else about the row changes -- a `REIN_*` variable the user exports themselves is still taken as-is.
- **The validation stops the marker, and only the marker.** That same settings `env` block can set `REIN_CONFIG_FILE` and `XDG_CONFIG_HOME` as well, and the config layer takes those as-is under the table's first row -- so a repository the user merely opened can hand the usage record's writer a config of its own, move where that session's record lands, and take it out of the lineage's own location. **That is deliberately left undefended**, because defending it buys nothing: the official documentation puts a repository's settings **hooks** under the same conditions as its `env` -- both used in a folder covered by a parent folder the user trusted, and both used in a `claude -p` or SDK run in a folder never trusted at all -- so whoever can place that file already runs commands of their own choosing on the machine, which contains anything they could reach through rein's settings. The line belongs at the layer that reads those settings, not at rein's.
- **The token draws the line at "could read that directory," not at "is trusted."** Settings text is written before the clone ever reaches this machine, so it can never hold the value. Anything already running as this user -- a shell rc, `direnv`, a hook a repository ships -- reads that file as easily as rein does, and is inside the boundary by the first row of the table. The token is not, and is not meant to be, a defense against code execution: **what it separates is a marker from a settings file, not a marker from a program.** This is the canonical statement of that line -- the hooks and locations specifications point here rather than restating it.
- **The defending mechanism has exactly two parts**: the project layer's allow gate (see "Allowing project config" in [the config specification](config.md)), and the marker's validation, which every reader of the marker goes through, so that hooks act only on a session rein itself launched -- a marker a clone can name but cannot substantiate, because the runtime directory it names has to be one the user's own `rein up` / `rein init` claimed, and the marker has to carry the token that lineage keeps inside it (see [the hooks specification](hooks.md)). Both are only ever suspicious of what a clone can bundle.
- **Out of scope**: defending against a different user on the same machine, OS-level privilege separation, defending against someone who can rewrite the user's own `settings.json`, and -- per the bullet above -- whatever a repository's own settings reach through any variable other than the marker (none of these hold at rein's own layer).
- **No layer mechanically blocks the bundled content itself** (the measures stop at keeping the display from being faked). What's inside this implementation's own repository is a fact the distributor **can confirm**, not an assumption -- a fork that rewrites the content and gets redistributed from there is outside this contract's scope.

## What this contract does not cover

This module **does not** handle the following three things.

- **Registering** the usage record. The writer (`rein-statusline.sh`) ships bundled, but registering it in the user's own settings is the user's job, and rein never rewrites that (`doctor` only checks whether it's registered and the record's format). The handover mechanism itself only ever reads the record -- it never writes to it (the same object's writer is never duplicated). The prompting layer (see [the hooks specification](hooks.md)) is this module's own, but it doesn't write to the record side either.
- Task routing, an overseeing session above this one, unattended retries -- none of these are in this module's scope.
- Actively dropping a message into a session is never used.
