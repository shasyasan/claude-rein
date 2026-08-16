# Developer-facing documents

A map of the developer-facing documents, and the repository's own parts list (which file owns what).

## Document map

The entry point is **handover contract design**; the rest are per-topic specifications and conventions.

| Document | What it covers |
| --- | --- |
| [Handover contract design](architecture.md) | Invariants, how the layers divide the work, the handover sequence, requirements for unanticipated usage, the threat model (trust boundary), what this contract doesn't cover |
| [Handover specification](handover.md) | The handover-request marker, `rein request`, freshness validation R1-R10, the current pointer, how a session is named (its ID), the handover log, timeouts and notifications, the commands that execute a handover, what goes into kickoff |
| [Hooks specification](hooks.md) | The plugin hooks' registration and execution path (registry -> launcher -> runner), resolving the lineage (the managed marker's env), the conditions under which Stop blocks a stop, the conditions under which UserPromptSubmit cancels a handover, snoozing a handover |
| [Config specification](config.md) | The config format, the layers and their precedence, when a change takes effect, the discipline for rewriting it, `handoff_path`'s default and acceptance conditions |
| [Usage record specification](usage-state.md) | The state file that starts a handover (its location, keys, timestamp format, freshness), and the discipline for its writer (statusLine) and its readers |
| [Locations and locks specification](runtime.md) | The unit of management, locations (split in two by who owns their lifetime), `owner`, the path table, the three lock kinds (`watcher.lock` / `op.lock` / `seat.lock`), heartbeat, handing off a stop request, the structural rule that closes off what cleanup can target, launch settings for a background session |
| [Per-verb internal conventions](cli.md) | Installation, delegation, short-form assignment, plugin cache and updates, launching the watcher directly, what `doctor` inspects, what `prune` scans |
| [Development conventions (gates, selftest, terminology, distribution)](development.md) | Running the gates (`scripts/check.sh`), selftest conventions, and the terminology contract |

## Parts list (which file owns what)

**Each part owns exactly one role**, and a second writer never gets placed over the same target.

| Part | Real file | Role |
| --- | --- | --- |
| Handover contract | `docs/spec/` (entry point `docs/spec/architecture.md`) | The file format and verification rules shared between the session issuing a handover request and the watcher |
| Command entry point | `bin/rein` | The single dispatcher (takes the shared options `--cwd` / `--root` / `--config` in one place, normalizes them, and passes a resolved absolute path to each verb's implementation) |
| Verb implementations | `scripts/lib/cli/` (10 files) | One file per verb (`up` / `down` / `status` / `prune` / `doctor` / `init` / `snooze` / `config` / delegation), plus the shared foundation (`base.sh`: resolving locations, liveness judgment, the operation lock) |
| The CLI's selftest | `scripts/lib/cli/selftest/` | The body of `bin/rein --selftest` (one file per section, plus shared helpers) |
| The config layer | `scripts/lib/rein-config.sh` | The shared library that folds the config file, environment variables, and CLI flags down into one precedence order |
| The watcher | `scripts/rein-watcher.sh` | Marker detection -> freshness validation -> launching the successor -> the pointer update -> confirming the predecessor's termination -> the handover log (also the entry point for launching the first session, with `--bootstrap`) |
| The watcher's selftest | `scripts/lib/watcher/selftest/` | The body of `rein-watcher.sh --selftest` (one file per section, plus shared helpers) |
| The attach loop | `scripts/rein-seat.sh` | Watches the current pointer and re-points `claude attach`, following a handover with zero action from the user |
| The handover request's writer | `scripts/rein-request.sh` | Lets the session issuing a handover request place the handover-request marker atomically |
| The shared library | `scripts/lib/rein-common.sh` | The contract's filenames, timestamps, notifications, logging, session liveness judgment |
| The selftest fixtures | `scripts/lib/rein-selftest-fixtures.sh` | Generating the fake `claude` / fake `osascript` shims |
| The selftest section entry point | `scripts/lib/rein-selftest-sections.sh` | Reads the section table, and interprets `--selftest [section name ...]` and `--selftest --list` |
| Gates | `scripts/check.sh` | Runs every gate in one pass (the list, and the entry point for running just one, live in [Development conventions](development.md)) |
| Plugin manifest | `.claude-plugin/plugin.json` | Loads this repository itself as a Claude Code plugin (slug `rein`) |
| The marketplace registry | `.claude-plugin/marketplace.json` | Also distributes this repository as a marketplace |
| The hooks registry | `hooks/hooks.json` | Registers usage monitoring (`PostToolBatch`), wiring into natural breaks (`Stop`), a liveness check (`SessionStart`), and cancelling a handover (`UserPromptSubmit`) |
| The hooks launcher | `hooks/rein-hook-launcher.sh` | The third-step entry point that sits on the plugin side (launches the real runner as a child and just folds its exit code back) |
| The hooks runner | `scripts/rein-hook.sh` | The hooks implementation (injecting advisories, blocking a stop, the liveness check) |
| The usage writer | `scripts/rein-statusline.sh` | Registered as the `statusLine` in the user's own settings; drops the session's usage percentage into the state file (where handover starts) |
| The handover-request skill | `skills/request/SKILL.md` | `/rein:request` -- instructions for a session issuing a handover request, to run `rein request` |
| The handoff skill | `skills/handoff/SKILL.md` | `/rein:handoff` -- instructions for **deciding where the handoff document lives**, and how much to read and write (it holds no format for the content itself) |

Why it's split this way (design decisions that don't fit in the table's cells):

- **`bin/rein` holds no verb implementations.** It only owns normalizing the shared options and the short-form mapping table (this file is where that table is canonical).
- **The selftest bodies are split off under `lib/` so the always-running path never has to load them.** The CLI side only loads them under `--selftest`; the watcher side never loads them into the resident watcher.
- **hooks also `source` the config layer directly** (hooks never carries a second copy of the same precedence logic).
- **The handover request's writer ships as a command so a session never has to assemble the contract's JSON itself.**
- **The shared library (`rein-common.sh`) is not an executable script** (out of scope for the execute-permission and `--selftest` conventions -- see [Development conventions](development.md)).
- **The fixtures build a fake `claude` / fake `osascript` so checks never trigger the real CLI or a real GUI notification.**
- **The marketplace registry is required for a user-scoped install from a local path**, and `rein init` reads the marketplace name from it.
- **The hooks registration command calls the minimal launcher inside the plugin** (`"${CLAUDE_PLUGIN_ROOT}/hooks/rein-hook-launcher.sh"`). The launcher just follows the PATH command's symlink to its real file, and launches the runner sitting next to it **as a child**, passing along the calling convention's version -- its own update frequency is zero, so a stale implementation never gets stuck in the plugin cache (why it never replaces itself with `exec` is in [the hooks specification](hooks.md)).
- **The registration command wraps the launcher's path in double quotes**, and both `scripts/check.sh`'s plugin gate and `rein doctor` fail a form that lacks the quoting. Why the quoting is required, and what silently breaks without it, are canonical under "Registration" in [the hooks specification](hooks.md).
- **The hooks runner is kept separate from the CLI proper so the layer that runs on every tool call never has to load the dispatcher and the full set of verbs.**
- **The usage writer ships bundled because statusLine's stdin is the only place with an official field for the usage percentage** (neither a hook's stdin nor the model's own self-observation has one). Registration lives in the user's own settings, so rein never rewrites it -- `rein doctor` checks whether it's registered and the record's format instead.

## Gates

**Run `scripts/check.sh` after any change** (it exits non-zero if even one gate fails).

Each gate's content, the selftest conventions, and the terminology contract are in [Development conventions](development.md).
