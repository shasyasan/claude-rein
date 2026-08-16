---
name: request
description: The session requesting a handover places the handover request. Use this when usage is running low and you want to hand off to a successor session -- after finishing the handoff document, run the rein request command line kickoff pointed you to. Triggers on phrases like 'request a handover', 'start a successor', or 'hand this session off'.
---

# Place a handover request

Issue a handover request from this session and have the watcher launch a successor session. **Don't hand-assemble the handover request JSON yourself** -- `rein request` guarantees its shape (the schema version, timestamp format, atomic write, and its ordering against the handoff document). When you need the literal specification, read the bundled `${CLAUDE_PLUGIN_ROOT}/docs/spec/handover.md` (not reproduced here).

## Steps

1. **Finish writing the handoff document first** (where it lives and how it's structured is defined by `/rein:handoff`'s "leaving side" -- not repeated here). A handover request is validated on the assumption that the document is already complete.
2. **Run the handover request command line kickoff pointed you to, exactly as given.** kickoff presents it as **one line set off by line breaks**, with paths already **quoted** (`'...'`). Don't drop arguments, reorder them, substitute a different value, or strip the quotes. Fill in only the placeholders.

   | Placeholder | What to put there |
   | --- | --- |
   | `<your session ID>` | This session's own ID. **Never guess it** (writing another session's ID makes the handover log and the external-stop target disagree). Stop and ask if you don't know it. |
   | `<absolute path to the handoff document>` | The document you finished in step 1. It's the one document that shows up in the successor's kickoff. |

3. Once you run it, the watcher launches the successor. **Don't start new work until told to.**

To check whether the request landed, use `rein --cwd <target project> status`. While `pending marker` reads `present`, the watcher hasn't picked it up yet; once it does, `last event` advances to `marker_accepted` or later. If `watcher` reads `not running`, nobody will ever pick up the request -- **report this to the user** rather than trying to start the watcher yourself.

## When you don't have the kickoff line handy

**First, make sure the runtime-data location (where the marker gets placed) matches the watcher's.** A mismatch places the marker in a different lineage, where it never reaches the watcher and the command exits 0 silently. For a lineage running from the default location (`${XDG_STATE_HOME:-~/.local/state}/rein/<key derived from cwd>/`), line up `--runtime-dir` or config's `runtime_dir` with the watcher.

```sh
rein \
  --cwd <absolute path to the target project> \
  request \
  --session-id <your session ID> \
  --handoff <absolute path to the handoff document>
```

Call `rein` from PATH (the same form hooks return in their messages). If it isn't found, the installation is incomplete -- report `rein doctor`'s output to the user rather than substituting another path.

`--handoff` can be omitted (then the effective value of config's `handoff_path` is used, or the default location if that's unset -- check the effective value with `rein --cwd <target project> config get handoff_path`). You can optionally add `--runtime-dir <same location as the watcher>`, `--successor-name <name>` (the successor's display name), and `--note <note>`. On success, the placed marker's absolute path is printed to stdout, so you can confirm right there that it landed in the intended lineage.

## When a Stop gets blocked once

For a primary session past the handover trigger (config's `threshold_handover`), the end of a turn gets blocked **exactly once per generation**, returning a reason nudging toward a handover. This is a decision point, not a forced termination -- **it never blocks twice in the same generation** (letting it pass just means the advisory keeps showing up from then on). Once blocked, either move on to steps 1-2 above (finish the document, then `rein request`), or use the snooze below. If you're close to done, it's fine to prioritize finishing -- just make sure to finish the document before you wrap up.

## When you can't hand over yet

If you're not at a good stopping point and can't place a handover request yet (i.e. can't finish the handoff document), you can **snooze the pressure to hand over for that period.**

```sh
rein --cwd <absolute path to the target project> snooze 30m
```

- The duration is **any positive integer plus a unit, `s` / `m` / `h`** (no unit means seconds; e.g. `30m`). It's capped by config (`snooze_max_sec`, **default 3600 seconds, 1 hour**); a request over the cap fails outright rather than getting rounded down.
- **Snoozing doesn't cancel the handover.** Reach a stopping point within the window and run steps 1-2.

## On failure

A non-zero exit means the request wasn't placed -- don't finish your work as though the handover happened (no successor will launch). The reason goes to stderr. It might be the document: it doesn't exist, is empty (not finished yet, or wrong location), is in a shape that can't be accepted (a symlink, a directory), or has no resolvable path at all (a lineage where config's `handoff_path` was explicitly set empty). It might be **the watcher: it isn't running, or its state can't be determined** -- with nobody there to pick it up, the request isn't even written, so hand the stderr message to the user as-is and ask them to fix it, rather than trying to start the watcher yourself (for a lineage whose location is set via `--root` / `--runtime-dir`, the message instead points to running `rein up` with the same flags). Or it might be that **the document's section structure doesn't match the template** (a missing section, or a `##` heading that isn't in the template) -- this is one of the few reasons you **can fix on the spot**: move any extra section's content to its own canonical source before deleting it, add back at least the heading for any missing section, and retry (do this before escalating to the user). Other reasons: an unconsumed handover request already exists, or a prerequisite tool is missing. **Don't improvise a workaround** (hand-writing a marker file, or deleting an existing one, are both contract violations) -- report the reason to the user instead.
