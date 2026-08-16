# Usage record specification

The state file a session's context usage is recorded in: its location, keys, timestamp format, freshness handling, and the discipline for its writer and its readers.

**This one file is where handover starts** (both threshold judgment and a Stop-triggered handover only run once this exists). In an environment with no writer, handover never happens even once -- instead, the advisory "Monitoring is not working" keeps getting injected.

## Location and name

| What | Value |
| --- | --- |
| Location | The effective value of the `usage_state_dir` setting (default `~/.claude/state/context-usage`) |
| Filename | `<session_id>.json` (the `session_id` straight from the Claude Code payload) |

- Resolving the setting follows the layers in [the config specification](config.md) (writer and reader alike see the same effective value -- what makes that hold for a lineage relocated with `--root` is under "The writer (statusLine)" below).
- `session_id` **never contains a path separator or whitespace.** A payload that has one can point outside the location, so the writer rejects it.
- The temp file used while writing goes in the same location, with a name that doesn't end in `.json` (so anything scanning the location never mistakes a half-written file for state).

## Record shape (one JSON line)

```json
{"at":"2026-08-20T04:12:33Z","session_id":"9b1c2d3e-...","cwd":"/path/to/project","context_window":{"used_percentage":41.7,"context_window_size":1000000,"total_input_tokens":417000}}
```

| Key | Type | Required | Meaning |
| --- | --- | --- | --- |
| `at` | String (`YYYY-MM-DDTHH:MM:SSZ`, UTC, second precision) | Required | The timestamp the writer stamped. This is all a reader's freshness judgment looks at |
| `session_id` | String | Required | The payload's `session_id` (matches the filename) |
| `cwd` | String (absolute path) | Optional | The payload's `cwd` (omitted for a payload that has none) |
| `context_window` | Object | Required | The payload's `context_window`, **carried through as-is** (never thinned) |
| `context_window.used_percentage` | Number (0-100, decimals allowed) | Required | The usage percentage. A reader floors it to an integer before comparing it against a threshold |

- **There's exactly one timestamp format in the contract** (the same one the marker and the pointer use). Letting any other format through would disable freshness validation wholesale.
- **`context_window` is carried through whole.** A reader only ever looks at `used_percentage`, but thinning the raw data would make it impossible to look at it later from some other angle (tokens remaining, window size).
- **Written as one line.** The reader (hooks) runs on a layer that fires on every tool call, so it has a fast path that pulls the value out of one JSON line without spawning an external command (falling back to `jq` only when the shape doesn't match).
- **Only a payload whose `context_window.used_percentage` is a number within the spec's range gets written** -- not one with the key missing, not a string type like `"20"`, not a non-finite value (`NaN`, `1e400`), and not anything outside `0`-`100` (`-0.1`, `100.1`, `99999` are all rejected; the boundary values `0` and `100` are written). The reader folds this value as a number, so writing an unreadable record would make "the writer is alive but its value can't be read" indistinguishable from "the writer isn't there," and a finite value over 100 would read as having crossed every threshold there is.
- **On rejection, no record is written -- it fails non-zero with a reason code attached** (`used-percentage-nonfinite`, `used-percentage-range:<value>`). A writer that claims success with exit 0 while leaving behind an unreadable record is exactly the state this section declares "never write."
- **A payload whose value contains a newline is also never written** (`field-newline:<session_id|cwd|model>`). The values are pulled one line per value from stdin, so a newline embedded in a value shoves the following value into the wrong slot -- the record's own slot ends up holding only the usage-percentage string, and what gets placed at `<session_id>.json` **isn't even JSON.**
- **A field participating in the record that isn't a string is also never written** (`field-type:<session_id|cwd>`). A non-string value that fits on one line never trips the newline check, so `session_id: 0` would slip through and get written into the record's pathname as `"0"` -- the reader (hooks) rejects the same payload by type, so if only the writer let it through, it would place **a record nobody ever reads**. The check applies only to the fields that participate in the record's pathname and content -- `session_id` and `cwd` -- and specifically **`model` is never rejected for its type** (stopping the whole write over a display-only field would make the writer's absence indistinguishable to a reader). **Only `null` and a missing key count as "absent, treat as empty"** -- `false` is rejected as "a non-string value that's present" (jq's `//` folds `null` and `false` together, so it can't be used here).

## Freshness

- A reader compares `at` against the current time, and treats it as **stale** once it's older than `usage_stale_sec` (default 1800 seconds) -- it never passes it through silently, and it says so with a cooldown attached.
- **Only when `at` can't be used for the freshness judgment** does a reader fall back to the file's mtime -- both when the writer carries no `at` at all, and when `at` is present but can't be read in this timestamp format (an unreadable value never silently reads as "recent"). If even the mtime can't be obtained, that falls to "stale" as well.
- A stale record is **never deleted** (it's a clue to how long it was still being written). The judgment runs on `at` whenever `at` can be read.

## The writer (statusLine)

**The writer is Claude Code's `statusLine` command** -- rein itself never writes this file.

- A hook's stdin never carries context usage, and a model can't self-observe its own usage percentage either. An official field for it exists **only on statusLine's stdin**, so that is the one and only writer.
- **A background session rein launched gets this record written for it too, even while no terminal is attached to it** -- so leaving usage monitoring entirely to the user's own writer costs an unattended generation nothing, and rein never needs a writer of its own.
- The bundled writer is `scripts/rein-statusline.sh` (it reads the stdin payload, returns one status-bar line on stdout, and writes this spec's state). Registration steps are in [the user-facing guide](../../README.md).
- **Registering it is the user's job**: `rein init` never rewrites the user's own `settings.json` (it only creates what it owns). `rein doctor` checks whether it's registered and the record's format, and reports on both.
- **The writer resolves the user layer from the managed marker, not from the default location.** It is registered once, for every session on the machine, so nothing about how it is invoked says which lineage a session belongs to -- and a lineage relocated with `--root` keeps its user config at `<dir>/config/rein/config`, which the default resolution never reaches. Reading the marker is what makes this document's guarantee ("writer and reader alike see the same effective value") hold for such a lineage. Without it the writer lands the record in one place while the readers look in another, and **the handover never fires even once while the advisory blames the writer** -- which is working correctly.
  - **The marker reaches the writer through the launch settings' `env`** (measured: a session started as `claude --bg --name <name> --settings <file>` runs its statusLine command with that file's `env` block applied). **This rests on observation, not on a documented guarantee** -- what the official documentation states about a statusLine command's environment is that `COLUMNS` and `LINES` are set for it, and it says nothing either way about the `env` block. Measured alongside it: `claude -p` runs no statusLine command at all, so a record only ever gets written for a session that has a status line to render.
  - **The marker is validated before it is used**, through the one check hooks go through as well (see "Lineage resolution" in [the hooks specification](hooks.md)). A repository the user merely opened can name a marker, so its presence is evidence of nothing on its own.
  - **Three outcomes, and only one of them uses the marker.** No marker: the default resolution stands, silently -- for a writer that runs in every session, this is the ordinary case rather than a failure. Verified: the marker's config file becomes the user layer. Present but refused: **the marker is not used**, the default resolution stands, and the reason goes out through the one failure channel this writer has (one line to stderr). None of the three moves the exit code -- a writer that broke the user's own turn over a marker would be worse than a record landing in the default place.
- **A different writer works too.** The only condition is meeting this section's format -- rein doesn't care whose implementation it is (`rein doctor` doesn't judge by whether it's the bundled one either -- it goes by the record's format).
- A write swaps in through **a temp file in the same location, then a rename** (so a reader never grabs a half-written file).
- A writer's failure **never silently falls back to a default** -- it writes no state, prints a reason to stderr, and exits non-zero.

## The readers (hooks, `doctor`)

- The hooks only **read** (missing, stale, or broken all get reported with a cooldown -- see [the hooks specification](hooks.md)).
- **The fast path only commits once it's confirmed the value is actually terminated** (that `used_percentage` is followed by a `,` or a `}`). The writer lives outside rein, so a non-atomic write -- truncating with `>` and then appending -- is a real possibility: without requiring termination, reading a half-written `..."used_percentage":4` would take "everything after" as the value, turning 41% into 4% (and that Stop would then judge it under threshold and never push for a handover). Unterminated input never commits through the fast path -- it falls to `jq` and gets read authoritatively instead.
- Beyond confirming the location exists, `rein doctor` checks **the newest record's format** (readable as JSON, `used_percentage` numeric, `at` in the contract's format) and its freshness.
  - Checking only whether the location exists would read green the instant the location gets `mkdir`-ed, with no writer present -- the hardest kind of breakage to track down: "everything reads OK, yet handover never happens."
  - `used_percentage` is checked **down to its type** (`jq -r` prints a string like `"20"` as `20` too, so a purely literal digit check lets a type mismatch through, and the one case only the reader chokes on reads green).
  - A format violation is `FAIL`; no record existing yet, or the last update being too old, is `WARN` (the former points to a writer defect, the latter can't be told apart from "that session was simply left closed").
  - **Whether statusLine's registration passes is decided by the record's format too** -- even without the bundled writer, a record matching the contract reads `OK`. Registration identity is checked by the real file's path, so even a same-named registration reads `WARN` if it's a different checkout's real file (an update taking effect on only one side).
