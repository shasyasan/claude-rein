# Hooks specification

Hook registration, the three-step execution path, lineage resolution, shared rules, where records are kept, the conditions under which Stop blocks a stop, the conditions under which UserPromptSubmit cancels a handover, the ledger of running children, and snoozing a handover.

## Registration (6 events in effect)

**Registration lives in the plugin's `hooks/hooks.json`** (the official location, directly under plugin root), and every command hands an event name to a launcher inside the plugin.

| Event | Event name passed | What it does |
| --- | --- | --- |
| `PostToolBatch` (no matcher) | `post-tool-batch` | Injects the fact that a threshold was crossed, or a watch-mechanism anomaly, via `additionalContext` (with a cooldown) |
| `Stop` | `stop` | When every condition is met, blocks the stop once per generation and pushes for a handover |
| `SessionStart` | `session-start` | Prints one line each for the usage self-check instructions and rein's own liveness check (advisory only, fail-open) |
| `UserPromptSubmit` | `user-prompt-submit` | If the user speaks after a handover request has been submitted, places a marker that cancels that handover |
| `SubagentStart` | `subagent-start` | Records the child that just started in the children ledger (`<runtime>/children/<session_id>.<agent_id>`) |
| `SubagentStop` | `subagent-stop` | Removes that child's ledger entry |

- The registered command has the shape `"${CLAUDE_PLUGIN_ROOT}/hooks/rein-hook-launcher.sh" <event name>` -- **the first word (the launcher's path) is wrapped in double quotes.**
- **Why quote it**: the registered command is handed to a shell in the user's own environment and undergoes word-splitting. Without the quotes, a plugin install path that contains whitespace (for example, a distribution that clones the repo under a path like `My Repos/claude rein`) splits the first word mid-path, and **no hook ever fires, with no error either** -- every install step and every gate other than `rein doctor` stays green, while both the advisory channel and the handover wiring silently go dark (observed). This shape is guarded mechanically by the plugin gate in `scripts/check.sh` and by `rein doctor`'s check of the execution path (both fail a form that lacks the quoting).
- **Why the advisory channel is `PostToolBatch`**: it fires exactly once per **batch of tools that ran in parallel**, so it never scales with the number of tools and concurrent firings can't structurally race. It's confirmed to fire even on a turn with a single tool call (observed).
- `PostToolUse` is accepted as a **migration-era compatibility path**, but it isn't listed in the hooks registry (it shares the notification claim with the same exclusive marker, so injection still fires only once even if an old registration is still in place).
- The runner accepts 7 event names: `post-tool-batch` / `post-tool-use` / `stop` / `session-start` / `user-prompt-submit` / `subagent-start` / `subagent-stop`. The advisory channel's primary path is `post-tool-batch`.
- **Why the two child events are registered**: "never hand over while a child is alive" is one of this mechanism's invariants (a handover replaces the primary session, and a child dies with its parent). `Stop`'s push already deferred on it, but `rein request` -- the only channel that actually writes the marker, and the one a session runs by hand -- is a separate process with no payload, and so had no view of children at all: a handover requested that way went through while 3 children were running, and 2 of them ended having written nothing (observed). The ledger these two events keep is the evidence that reaches that process (see "Runtime data hooks use" in [the locations and locks specification](runtime.md)).
- **Firing order is `PreToolUse` (`tool_name=Agent`) -> `SubagentStart` -> `SubagentStop` -> `Stop`**, and `TaskCreated` / `TaskCompleted` never fire (observed). `SubagentStart`'s payload carries `agent_id` / `agent_type` / `cwd` / `hook_event_name` / `prompt_id` / `session_id` / `transcript_path`; `SubagentStop` carries the same `agent_id`. **`background_tasks` is not among them**, so these two never stand in for `Stop`'s own evidence. On both, `session_id` is **the parent's** -- which is exactly what the ledger partitions on.
- **`SubagentStop` never arrives for a session stopped externally** (the way rein stops a predecessor), so entries left behind are part of the design rather than an anomaly -- what makes them harmless is the partition, not cleanup (see the same section of the locations specification).
- **Neither of the two writes a liveness record (`health/last-seen.<event>`) and neither appends to the fire log.** A lineage that never launches a child would never fire them, so an absent last-seen record would be read as an anomaly for a perfectly healthy lineage; and the fire log records emitting an injection, blocking a stop, or placing a marker for the watcher, none of which these do. Where a ledger write or delete fails, that failure is loud on its own (stderr and exit 1) -- it is never left to a log nobody checks.
- **Why the cancellation channel is `UserPromptSubmit`**: it's the only event whose payload arriving at all already means "the user is at the keyboard and just spoke" -- no other signal is needed to infer presence. The handover window is only tens of seconds long, so a channel that waits on tool execution or on a stop wouldn't be in time.
- **The rules for writing the handoff document appear at all 3 firing points** (the advisory, the handover trigger, and the Stop-block text) -- the text is one value from the shared library, and every channel fills in that same value (the template outputs the same value too, when it's assembled -> see "Installation" in [the per-verb internal conventions](cli.md)). **The advisory alone isn't enough to reach every session**: threshold checking is mutually exclusive between the advisory and the handover trigger, so a turn that jumps straight past the advisory threshold to the handover threshold never once passes through the advisory channel, and the lower cooldown gets consumed there too. That's exactly **the session rewriting a handoff document that already exists** -- the very target this rule is aimed at -- so all 3 carry it. The value travels as a `%s` argument into a channel that assembles raw JSON with `printf`, so a self-check mechanically confirms it contains no `"`, `\`, or newline (`%` is fine, since it's passed as an argument and is never reinterpreted).
- The one line SessionStart prints for "`rein` isn't on PATH" is a message about **whether the handover request command can be typed**, not a check of the hooks path itself (hooks run through the launcher inside the plugin, so they don't depend on PATH). Judging whether install is correct belongs to `rein doctor`.
- **For a lineage that also registers the same advisory in the user's own `settings.json`, both the plugin's hooks and the settings-side hooks fire** (they merge rather than replace one another). Migrating off the old registration is up to the user, in this order: (1) enable the plugin at user scope, (2) confirm the injection reaches a live session, (3) remove the old registration from the user's own `settings.json`. **Only the single session that spans the switch can see the advisory fire twice** -- the old and new registrations keep their cooldown markers in different places.

## Execution path (the hooks registry -> minimal launcher -> the dedicated hook runner)

**A hook invocation passes through 3 steps** (the hooks registry calls the launcher inside the plugin; the implementation lives in the runner at the far end of a symlink).

| Step | Component | Role |
| --- | --- | --- |
| Registration table | `hooks/hooks.json` | Maps events to the launcher |
| Launcher | `hooks/rein-hook-launcher.sh` | Normalizes the entry environment, follows the `$HOME/.local/bin/rein` symlink to find the real implementation, spawns the runner next to it **as a child**, and passes it the calling-convention version (an out-of-spec exit code is folded into a non-blocking failure, 1) |
| Runner | `scripts/rein-hook.sh` | The hooks implementation (reads only the settings-layer parser and the shared library) |

- **Why 3 steps**: the plugin gets copied to `~/.claude/plugins/cache/` via the marketplace, so putting the implementation on the plugin side means that, **depending on how it was installed**, "you update it, but the old copy is what runs" (which side gets read, and the fact that it rests on observation rather than a documented guarantee, are canonical under "Plugin cache and updates" in [the per-verb internal conventions](cli.md)). Calling a PATH command directly from the registered command isn't safe either -- it becomes a **silent no-fire** depending on the state of PATH. So that an update to the implementation takes effect no matter which side gets read, the plugin side carries only a minimal launcher that never needs updating, and the implementation lives at the far end of a symlink (always current).
- **The runner is not spawned with `exec`.** With `exec`, the runner process would replace the launcher process, so an exit code the runner fails with **for the shell's own reasons** (unparsable = 2, not executable = 126/127, signal = 128+n) would pass straight through as the hook's exit code. 2 means something different per event, and **for `Stop` it's the stop block itself** -- a malfunctioning runner would turn into control over the mechanism (and since it never passes through the launcher's failure log, not even one line survives). Only the 0 and 1 the runner returns on its own are passed through; everything else folds into 1. The `launcher-exec` gate mechanically checks that this hasn't crept back in. A side effect of spawning it as a child: it's the launcher, not the runner, that gets cut off by the registration's timeout (10 seconds) -- the runner can keep running to completion. Running to completion doesn't corrupt state (the ordering is such that the stop-block response is written to stdout before the record layer).
- **Both the launcher and the runner normalize their own execution environment at their own entry point** (`unset LC_ALL CDPATH` and `export LC_CTYPE=UTF-8`, placed before loading the shared library). Under a non-UTF-8 multibyte locale (`ja_JP.eucJP` / `ja_JP.SJIS` / `GB18030`, etc.), bash can't parse the script, and **a launcher-side failure means `Stop` exits with code 2 -- the stop block itself** (observed). Normalizing only on the runner side wouldn't help: on a machine that can't even parse the launcher, execution never reaches the code that folds the exit status. So both steps normalize independently. Only the character set is forced; collation order, time, and messages are left as the machine's own settings.
- **The calling convention is versioned** (`--protocol <version>`). If the launcher (on the plugin side, where an install that reads the copy can lag behind an update) and the runner (at the symlink target, always current) run against each other while mismatched, argument meanings would silently drift, so **the runner fails loud on a mismatch** (with the fix pointed to as `claude plugin update rein@claude-rein` -- the exact ID).
- **When the launcher can't resolve the real implementation, it doesn't die silently**: it prints the reason to stderr and leaves one line in **the plugin's own data directory** (`${CLAUDE_PLUGIN_DATA}/rein-hook-launcher.log`). It doesn't write to rein's own log -- doing that would require resolving the lineage, which is precisely what's failing right now (it doesn't guess at a lineage and write to the wrong log).
- **This log also has a cap** (past 256 KiB, it rotates one generation to `.1`). Enabling the plugin without ever installing the symlink hits this path on **every event of every session**, so with no cap, one broken state grows without bound. No lock is taken here (it's always a single-line append, so the worst a collision can lose is that one line).
- **These 3 steps are the only entry point that calls a hook -- the CLI (`bin/rein`) has none.** Back when the old registry called `rein hook <event>`, the CLI side carried a compatibility adapter (it just passed straight through to the runner), but once it was confirmed that every hooks registry left in the user's own plugin cache called the launcher, the verb was removed entirely. **The only evidence usable for that confirmation is the user's own `/hooks` display (or the `hooks.json` in the plugin cache itself) and the firing log's event breakdown -- `rein doctor` cannot be used for this**: the only hooks registry doctor reads is this working tree's own `hooks/hooks.json`; it has no path at all to a hooks registry left in the user's own plugin cache. If a compatibility path of the same shape is ever added again, the condition for removing it must be judged from this same evidence (removing it on the strength of doctor being green would leave every `Stop` on a machine with a stale cache exiting non-zero with "unknown subcommand").

## Lineage resolution (the managed-marker environment)

**Every session rein starts (the first session and every successor) is handed a managed marker, and hooks confirm the lineage from it in O(1)** (no scanning).

| Env var | Contents |
| --- | --- |
| `REIN_MANAGED` | `1` |
| `REIN_MANAGED_CWD` | The lineage's canonical cwd |
| `REIN_MANAGED_RUNTIME_DIR` | That lineage's runtime directory |
| `REIN_MANAGED_CONFIG_FILE` | That lineage's user-scope config (for a `--root` lineage, `<dir>/config/rein/config`) |
| `REIN_MANAGED_RECORDS_DIR` | That lineage's records location (default root: `<cwd>/.rein/`; a `--root` lineage: `<dir>/records/rein/<key>/`) |
| `REIN_MANAGED_SETTINGS_FILE` | The temporary settings file created for launch (SessionStart removes it) |
| `REIN_MANAGED_TOKEN` | That lineage's token, read out of `<runtime>/token` at launch (see "The lineage token" in [the locations specification](runtime.md)) |

- **The marker has two readers, and one validation between them.** Besides hooks, the usage record's writer reads it, so that a lineage relocated with `--root` gets its record written where that same lineage's hooks read it (see "The writer (statusLine)" in [the usage record specification](usage-state.md)). Both go through `rein_verify_managed_marker` in the shared library; a second copy of the sequence would let the two readers drift into disagreeing about which markers are genuine. **What differs is only what each does with a marker it refuses** -- a hook stops the event, and the writer falls back to the default resolution and says why. The writer also has a third outcome hooks never reach: it is registered once for every session on the machine, so **no marker at all is its ordinary case**, not a failure.
- **The marker carries the lineage's entire context** -- not just what can be derived from cwd, but also the config and records locations that can't be derived from cwd (for a lineage relocated with `--root`).
- Hooks **use this as-is** and never re-derive it from environment variables left over in the process (`REIN_CONFIG_FILE`, `REIN_RECORDS_ROOT`) -- those don't reach that session's hooks either. Re-deriving would mean a hook for a lineage relocated with `--root` reads the default config and writes records to the default location (`<cwd>/.rein/`), mixing two lineages' records together.
- **The delivery mechanism is the `env` of the launch settings.** Environment variables on the launch command don't reach it -- a background session's hook process **inherits its environment from a shared background service**, so a later-launched session's own env never reaches that session's hooks (observed).
- **Validating the values is fail-loud too**: besides catching missing values and relative paths, it rejects a combination where **the records location and the runtime directory belong to different lineages** (it never silently re-derives from cwd).
- Only 2 records locations are valid: `<cwd>/.rein`, or one that **exactly matches the root-side location derived by working backward from the runtime directory** (`<dir>/state/rein/<key>` -> `<dir>/records/rein/<key>`) -- in other words, exactly the `--root` layout.
- The key is determined from cwd alone, so **matching only on the trailing key isn't the check** -- that would let "same key, different root" (an env with a swapped-out root) pass through, and a second lineage would write into the first lineage's records.
- **The marker has to carry that lineage's token, and it is compared against `<runtime>/token`.** Absent, empty, and mismatched are all fail-loud -- there is no "neither side has one, so proceed" path. Every other field of the marker is a value that can be reproduced from outside (a cwd, locations derived from it, a fixed `1`, and an `owner` file whose one line is that same cwd), so the token is the only field that says the marker's author could **read inside the runtime directory**. The value never appears in the failure reason -- only the file's location does (see "A clone can supply the marker env," below).
- **This check sits after the owner check, deliberately.** The two forgeries stay separately measurable: a marker naming a runtime directory nothing has claimed still fails on the missing owner file, rather than being absorbed into a token mismatch.
- **The runtime directory the marker names has to already carry a matching owner file.** The shared owner check answers "fine" for a directory that has no owner file yet -- it has to, so the writers (`rein up`, the seat, a handover request, `prune`, `doctor`) can run before the first claim -- but **the marker's validation requires the file to exist**, and fails loud when it doesn't. Only the user's own `rein up` / `rein init` writes it, and it is written before any session of that lineage exists, so requiring it costs a real launch nothing. Without the requirement, a marker naming an unclaimed directory as the runtime, a real project as the cwd, and that project's own `.rein` as the records location passes every other check here -- and then a hook goes on to append to **that project's** `hooks.log`, while the usage record's writer places that session's record wherever the marker's own config names (see "A clone can supply the marker env," below).
- **The runtime directory may not be the lineage cwd, nor sit under it.** rein keeps runtime data in the user's own state area (XDG's state, or under `--root`) and never inside the target project (see "Locations" in [the locations specification](runtime.md)), so this rejects nothing a real launch produces -- and it is what stops a marker naming a runtime directory **the working tree itself carries** (see "A clone can supply the marker env," below). The separator is part of the test: with cwd `/a/b`, a runtime directory at `/a/b-other` is a different directory and still passes.
- **Both sides of that one comparison are resolved to their physical paths first** (`cd` + `pwd -P`), so a trailing `/`, a `.` segment, or a symlink inside the tree cannot spell the same pair of directories into a pair that doesn't textually nest. It costs 2 subshell forks per managed event -- and no external command, since `cd` and `pwd` are builtins (so the counts under "The no-op path shouldn't spawn more external commands" below are unaffected). **Only this comparison uses the resolved values**: the owner file's contents and the records location keep being matched against the spellings their writers wrote (resolving one side of those would start rejecting a legitimate lineage that was set up through a symlink), and a path that cannot be resolved is fail-loud rather than a fall back to comparing the text. For the runtime directory that also means a marker naming one that does not exist is rejected here rather than at the owner file -- which costs a real launch nothing, since the owner file it has to carry can only exist inside a directory that does.
- **On a session that has the managed marker, the payload's `cwd` is never consulted.** Even after moving the working tree with `EnterWorktree`, recall, launching a successor, and records all keep operating against the **original lineage**.
- **A session without the managed marker gets nothing from hooks at all** -- there is no second way to resolve a lineage (see "A window rein didn't launch gets no action from hooks" below).

## A window rein didn't launch gets no action from hooks

The plugin is enabled at user scope, so hooks run for **every project and every session**. Running across every session is the intended design, but **the mechanism acting in a window the user didn't open through rein** is not. **Hooks act only on a session rein itself launched**: when the managed marker is entirely absent, every event **emits nothing, creates nothing, and exits 0** -- before a single external command is spawned.

### Why silence, and not just "skip the runtime data"

The injection channel's whole purpose is to push the session toward finishing its handoff document and handing over, and **a handover is carried out by `Stop`, which only ever fires for the primary session the current pointer names**. In a window rein didn't launch, `Stop` stays silent by that rule -- so all that arrived was the demand to hand over, in a window where nothing could carry a handover out. The usage advisories go with it, since they exist to lead into that same handover.

- **The evidence is the managed marker alone**, and it is delivered through the launch settings' `env` (see "Lineage resolution" above). Nothing rein reads inside the target project -- `<cwd>/.rein/`, the config inside it, an existing runtime directory -- produces it. (Before this rule existed, that was observed to work: a clone shipping only an `.rein/config` produced injections, runtime-directory creation, stderr on every tool batch, and reinjection on every cooldown.) **A clone can still put the marker into the environment through its own settings**, which is why what stops a forged opt-in is the marker's validation rather than its presence -- see "A clone can supply the marker env," below.
- **Silence takes exactly one shape: exit 0 with nothing on stdout**, and it is the same do-nothing for all 4 registered events. No other shape is available -- a non-zero exit or anything on stdout is a control signal (2 means something different per event, and for `Stop` it is the stop block itself), so **the mechanism not acting never becomes an unknown control signal** to the session.
- **A marker that is present but malformed is not silence -- it fails loud**, exactly as before (see "Lineage resolution"). Only the marker being **entirely absent** means "rein didn't launch this window."
- **Failing to deliver the marker is caught at launch time** rather than absorbed here: the watcher confirms the marker reached the successor before the pointer moves (see "Current pointer" in [the handover specification](handover.md)). So "no marker at all" can only mean a session rein never launched.
- The judgment is shared across all 4 events and runs **before the settings layer is read at all** -- a window rein didn't launch never gets even `SessionStart`'s one line.
- **It costs nothing to reject.** Its only evidence is an environment variable, so it sits ahead of both `jq` and payload extraction, and an unmanaged window returns without spawning a single external process.

### A clone can supply the marker env

**Setting the marker's environment variables isn't out of a clone's reach.** Claude Code's own documentation lists hooks in settings files and the `env` block of a repository's `.claude/settings.json` as taking effect **in a folder that was never trusted itself** -- both in a `claude -p` or SDK run there, and in a folder covered by a parent folder the user did trust. So "the marker is present" can never on its own mean "the user launched this window through rein."

- **What closes it is the marker's validation, not its presence**, and the validation has three parts that stop three different forgeries.
- **The numbering below is the order of the argument, not the order the checks run in.** Each part is here because the ones named before it are not enough on their own -- part three's whole reason for existing is that parts one and two are both satisfied by a runtime directory the clone ships inside itself -- so the parts have to be read in this order to be read at all. **The order the implementation runs them in is part three, then part one, then part two** (`rein_verify_managed_marker`: the cwd has to exist, then the placement check, then the records location has to match the lineage, then the owner file, then the token). Both of those positions are load-bearing, and each is justified where the check itself is described under "Lineage resolution" above: the placement check runs first so that a marker naming a runtime directory **that does not exist** is refused there rather than further down at the owner file, and the token check runs last so that a marker naming a runtime directory **nothing has claimed** still fails on the missing owner file instead of being absorbed into a token mismatch. Since the checks are an AND, nothing about which forgery each one stops depends on the order -- **only the reason a given forgery is refused with does**, which is why the two positions are pinned rather than left to the code's convenience.
- **Part one, the owner file**: the runtime directory the marker names has to already carry an owner file whose one line is the marker's cwd (see "Lineage resolution" above). The forgery this stops, concretely: the runtime pointed at any absolute path that has no owner file, the cwd at a real project of the user's, and the records at that project's own `.rein`. Every other check passes (the records location is exactly the `<cwd>/.rein` shape), and the hook would go on to append to **that project's** `hooks.log` on behalf of a window rein never launched. With the owner file required, it fails loud before any location is provisioned -- not even the owner file gets claimed.
- **Part two, the lineage token.** The owner file alone is not enough, because **a clone can name values it cannot own**: `owner` holds nothing but the cwd, which the marker states anyway. A marker that simply reproduces an existing lineage's values -- the runtime directory the user's own `rein up` created for that cwd, that cwd, and that cwd's `.rein` -- passes every check that only compares reproducible values. What it cannot reproduce is `<runtime>/token`: 64 hex characters drawn from `/dev/urandom` when the lineage was provisioned, kept at `0600` inside the runtime directory (see "The lineage token" in [the locations specification](runtime.md)). A repository's settings file is static text written before the clone was ever placed on this machine; it can name the file's location, but it can neither read the value nor write one there.
- **Part three, where the runtime directory sits.** Parts one and two both compare against files **inside the runtime directory the marker names**, so both are satisfied by a clone that ships a runtime directory *inside its own tree*, `owner` and `token` included -- those are ordinary files, and a repository can carry files. What a repository cannot do is place them **outside the tree it was cloned into**. So the marker's `REIN_MANAGED_RUNTIME_DIR` may not be the lineage cwd nor sit under it (see "Lineage resolution" above): rein keeps runtime data in the user's own state area, never under the target project, so no real launch is affected.
- **What a clone can actually write into the `env` block, measured**: the values are passed through **verbatim** -- neither `${CLAUDE_PROJECT_DIR}` nor a `~` is expanded, and the literal string arrives at the hook process as written (observed). So a settings file **cannot name its own checkout dynamically**: to state a runtime directory inside the tree it was cloned into, its author has to write the absolute path of where the clone will land, and be right. That is not the same as impossible -- the conventional places a clone gets put (`~/<name>`, `~/src/<name>`, `~/Projects/<name>`, with a login name that is often guessable) are exactly what a static value can guess at -- which is why the placement constraint is still carried rather than left to that difficulty.
- **What part three reaches, stated exactly**: the two directories are compared **after both are resolved to their physical paths** (see "Lineage resolution" above), so the spellings that name the same pair without textually nesting -- a trailing `/` or a `.` segment on the cwd it states, or a symlink shipped in the tree and named as the cwd -- are caught along with the plain shape. Both values come from the same settings file, so their author picks the spelling freely; resolving takes that choice away, since every spelling of one directory resolves to one physical path. What it costs is 2 subshell forks per managed event, and no external command (see "Lineage resolution" above).
- **So what a marker proves, stated exactly**: not "this window is managed", but "whoever wrote this marker could read inside that lineage's runtime directory at the time they wrote it, and that directory is not one the working tree could be carrying." That is the property `rein up` has and a clone's settings file does not.
- **This is not a claim to defend the trust boundary itself.** Anyone who can get Claude Code to read a repository's settings in an untrusted folder can already run commands there, and arbitrary code running as this user reads `<runtime>/token` as easily as rein does -- both sit outside rein's layer, and the token does not and cannot change that. The line the token draws is canonical under "Threat model" in [the architecture](architecture.md).

### Where validating stdin sits

**Validating stdin (fail-loud) is placed after this judgment**, and the subagent check after that. The order is "the marker gate -> extraction -> validation -> the subagent judgment -> branching," and moving either of the last 2 breaks one side or the other:

- Placing validation ahead of the marker gate would print stderr and exit 1 on a broken payload **in any unrelated window** (no runtime data would be created there, so the symptom is only noise and a non-zero exit -- but a mechanism that is supposed to be doing nothing at all should not be heard from).
- Placing the subagent check before validation would let `agent_id: 0` get turned into `"0"` by `tostring` and read as truthy, so **even a managed session would exit 0 in silence on every event** (a hole the type check closed reopens purely from the reordering).

**On a machine where `jq` isn't usable, hooks do nothing before extraction and return 0** (no output, no stderr). Extraction requires `jq` to parse the payload, so without it every event of **a managed session** -- one that is otherwise working fine -- would print stderr and exit 1, turning one missing tool into noise on every tool batch.

- **This isn't swallowing a failure**: `jq` is a prerequisite, and its absence gets named explicitly and rejected by install (`rein init`), launch (`rein up`), and diagnostics (`rein doctor`) (via the shared `rein_check_prerequisites`). A hook is a layer with no channel to notify through -- shouting here has nowhere to go, and it would just be noise on a machine unrelated to rein.
- **No auto-install happens** (never silently installing software on the user's machine -- this stays a message; the fix is `brew install jq`).

**A value's slot is blanked out only when that value contains a newline** -- not uniformly whenever a value is rejected. The point of blanking is to preserve the one-value-per-line layout; a value that's merely the wrong type is always squashed to one line by `tostring`, so it never throws off that layout. Blanking uniformly would mean **one bad field throws away every other field**, including the payload's `cwd` the fire log records next to the lineage -- the one column showing that a rejected call came in from a moved working tree. For a value that does contain a newline, the slot is blanked and the call fails loud: the fragment before the newline could itself name a real directory, and a malformed, user-sourced value is never allowed to stand in for the real one.

### What a freshly received clone looks like

| State | Behavior |
| --- | --- |
| A clone that ships an `.rein/` (with a config) inside it, opened in a plain `claude` window | Hooks inject nothing, create no runtime data, print nothing to stderr, and return 0 |
| The same clone, after the user runs `rein up` in it | The session rein launches carries the managed marker -- from then on it behaves as normal (whether the shipped `.rein/config` gets applied is a separate judgment call: "Allowing project config") |
| A window opened with plain `claude` inside a project that has a lineage set up, runtime directory and all | Still nothing -- what makes hooks act is the marker, not anything present on disk |
| A clone whose own settings put the marker's `env` into the window, naming a runtime directory nothing has claimed | Fails loud and writes nothing: that directory carries no owner file (see "A clone can supply the marker env") |
| A clone whose own settings reproduce an existing lineage's values exactly (its real runtime directory, cwd, and records) | Fails loud and writes nothing: the marker carries no `REIN_MANAGED_TOKEN` matching that lineage's `<runtime>/token`, and a settings file cannot read one |
| A clone whose own settings name a runtime directory it ships **inside itself**, `owner` and `token` included, with itself as the cwd | Fails loud and writes nothing: the runtime directory sits under the lineage cwd, where rein never places runtime data |
| The same, with the cwd spelled so the two values do not textually nest (a trailing `/`, a `.` segment, or a symlink shipped in the tree and named as the cwd) | Fails loud and writes nothing, for the same reason: both directories are resolved to their physical paths before being compared |

## Shared rules

**Rules the implementation of all 4 events follows in common** (event-specific conditions are under "The conditions under which Stop blocks a stop," below).

### Settings are read fresh on every call

**Thresholds, the cooldown duration, the staleness cap, and the usage location are re-read from the settings layer on every hook call** (for when a change takes effect, see [the config specification](config.md)).

- The keys used: the thresholds `threshold_notice` / `threshold_handover`, the cooldown duration `notice_cooldown_sec`, the cap past which usage counts as stale `usage_stale_sec`, the usage location `usage_state_dir`, the handoff document's location `handoff_path` (filled into the one-line handover-request command), and the 2 handover waits `final_output_timeout_sec` / `final_output_wait_sec` (the first decides whether the signals get placed at all, the second is the number the handover-wait notice states).
- The reader loads the settings-layer parser directly (spawning `rein config get` on every call would turn its process-launch cost directly into perceived latency, for a hook that runs on every tool execution).
- **Hooks' internal heuristics** (the children's silent window, the delivery-confirmation grace period, the age past which diagnostics call something "stale") are not exposed in settings. These aren't operational parameters for the user to tune; they're implementation constants for "where to cut off the fallback when the payload can't be judged" and "what diagnostics call old," and they fall outside the settings layer's scope (the full set of operational parameters). Their rationale and the conditions for revisiting them live in code comments.

### Every hook stays silent in a subagent context

On a call whose payload carries an `agent_id`, **every hook stays silent and touches no marker.** Injection would reach **the agent that called that tool**, not the primary session, so firing would only consume a firing opportunity for nothing.

- `agent_type` isn't used for this check, because it's also present on a **primary session** launched with `claude --agent <name>` (observed) -- going silent there would drop that entire primary session outside of monitoring.
- **`SubagentStart` and `SubagentStop` are the one exception, and they have to be.** Both always carry an `agent_id`, and on them it names **the child being recorded**, not the caller's context -- so putting them behind this gate would make them go silent the instant they were registered, leaving the ledger permanently empty while every check built on it read "no children." The exemption is by event name (never by inspecting the payload further), and it exempts them from **this gate only**: the managed-marker gate, stdin validation, and the owner and token checks all still apply to them unchanged.
- On those two, `agent_id` is **also expanded into a filename**, so it goes through the same shape check `session_id` does (no path separator, no whitespace). A payload that carries none at all fails loud rather than falling back to a shared name -- one shared entry would have the first child to finish erase the record of every sibling still running.

### How lineage and location are handled

**Both lineage and location are confirmed from the marker handed in, before any read or write** (never guessed from process state).

- Lineage resolves from the managed-marker env above (or the payload's `cwd`, on a session without it). **The hook process's own cwd is never used** (it depends on what launched it). A nonexistent cwd fails rather than silently falling back to the hook's own cwd.
- **The runtime directory's owner is checked before every read or write.** A lineage with an explicit location (config's `runtime_dir`, or an environment variable) that points at another cwd's location might already have a `hooks/` there -- checking only at creation time would let an existing location skip the check and read or write another lineage's markers, latches, and delivery confirmations. A mismatch, or an owner that can't be confirmed, fails loud (the owner is recorded on the first write).

### The exit code for an internal error is always 1

**Every event's exit code for an internal error is 1** (a non-blocking failure). 2 means something different for each event (`PostToolUse` returns stderr to the model; `Stop` is the stop block itself), and `PostToolBatch` has no official meaning for it at all -- so a malfunction is never allowed to turn into unknown control.

### The usage record is read-only

The usage state file (`<usage_state_dir>/<session_id>.json`) is **read-only -- hooks never write it.** If it's missing, stale (past `usage_stale_sec`), or its value is corrupt, that's never silently passed through; it's reported instead, with a cooldown (passing it silently would be indistinguishable from "all quiet").

- **The canonical source for its format (keys, types, time format, freshness) is [the usage record specification](usage-state.md)**; the writer is the `statusLine` setting in the user's own settings (a bundled writer can be registered there).

### Confirming injection delivery

A verification token (`[rein:<nonce>]`) is appended to the injected text and recorded separately. On the next call past the grace period (30 seconds), the runner **confirms whether it turned up** in the transcript's `hook_additional_context`. If it didn't, it's reported (firing and delivery are different things, and a delivery failure is otherwise silent).

- Matching isn't done by `tool_use_id`, because `PostToolBatch`'s injection is recorded on the transcript side under **a synthesized ID, `hook-<uuid>`**, and the hook side has no way to know that value in advance (observed).

### The no-op path shouldn't spawn more external commands

**A no-op path (a call that ends with 0 and no output) shouldn't be made to spawn more external commands** -- since this is a layer that runs on every tool execution, a single extra external command directly becomes perceived latency. **The standard to judge against is the measured cost below**, not "just the one `jq` call" -- the baseline for deciding whether to add one more command should never be a target off by an order of magnitude from reality.

| The no-op path | External commands | Breakdown |
| --- | --- | --- |
| A machine where rein's runtime data location (`<XDG state>/rein/`) doesn't exist yet | 2 | `jq` once to parse the payload, `sort` once to fold the environment variable listing |
| A project with no lineage set up (but the location exists) | 5 | The 2 above, plus `shasum` / `cut` / `basename` once each, to build the lineage key for opt-in judgment |
| `PostToolBatch` on a cwd with a lineage | 8 | The 5 above, plus 3 more for the lineage key that resolves the runtime directory (one extra `mkdir` the first time `<runtime>/hooks/health/` is created, making it 9) |
| `Stop` on a cwd with a lineage (a valid pointer, usage below the trigger threshold) | 13 | The 8 above, plus 5 `jq` calls for validating the current pointer's contract (one file opened 5 times) |

- **These 4 rows were counted before hooks were limited to sessions rein itself launched, and have not been counted again since.** After that change, a window without the managed marker returns **before spawning anything at all** (row 2's path no longer exists, and row 1 applies only to a managed session), and rows 3 and 4 no longer include the 3 commands for a lineage key -- the marker names the runtime directory outright. The numbers stand as measured rather than adjusted on paper.
- **With `UserPromptSubmit` registered, one runner process starts every time the user sends a prompt** (on a cwd with a lineage, the base cost above rides along on every single prompt). The 4 rows predate that registration, so **no `UserPromptSubmit` row is listed until one has actually been counted.**
- **`SubagentStart` / `SubagentStop` fire once per child, not per tool call**, so they never ride along on the path this budget is about. Each adds the "2 things that always happen" below plus one `>` or one `rm` (and a single `mkdir`, the first time `<runtime>/children/` is created for a lineage) -- **no `jq` beyond the one that parses the payload, no `ps`, and no pointer validation.** Neither row has been measured end to end, so, following the same discipline as the row above, none is listed here.

**2 things that always happen** (on every call -- and only on a call that carries the managed marker; a window rein didn't launch returns before any of it):

| What it spawns | When it spawns | Why there's no other way to get it |
| --- | --- | --- |
| `jq` once, to parse the payload | Every event | The payload on stdin can only be read as JSON |
| `sort` once, to fold the environment variable listing | Every event (the moment the settings layer is loaded) | Applying settings from environment variables folds the `compgen -e` listing in a stable order |

**6 things add up conditionally**, each either a call where "what happened to my own handover request" is already known, or something that only happens on `Stop`.

| What it spawns | When it spawns | Why there's no other way to get it |
| --- | --- | --- |
| `jq` to read the marker (on both Stop and the advisory) | A call where `<runtime>/handover-request.json` exists (plus once more for a claimed file in `processing/`, if present) | Whether it's been submitted can only be told from its `session_id` |
| `ps -p` and `ps -o command=` (once each) | For **Stop**: a call where it's submitted and either this generation hasn't been told the wait started yet (the notice's own condition, judged ahead of the cooldown) or the `watcher-missing` cooldown has expired -- both read one shared judgment, so it stays "once each" however many branches ask. Once the notice has gone out, every later submitted turn of that generation folds on the notice's latch and spawns nothing. For **the advisory**: a call where it's submitted (regardless of usage or cooldown) | Whether the watcher is running can only be told from a running process's identity |
| Reading the final-output marker (Stop; spawns no external command) and placing it (`>` once) | A call where it's submitted and the pointer names this session. No write happens if its own marker is already there | There's no other way to hand "this session finished its response" to the watcher |
| Placing the cancellation marker (`UserPromptSubmit`; `>` once) | Same as above. No write and no log entry happens if its own marker is already there | There's no other way to hand "the user spoke" to the watcher |
| `jq` to read a rejection's archive (Stop; once per archived file) | A call where the generation's latch is already consumed, nothing is submitted, and that generation hasn't been re-blocked yet (see "A generation whose handover request was rejected") | Whether something was rejected, and why, can only be told from the contents of the record in `rejected/` |
| `jq`, 5 calls to validate the current pointer's contract (`jq -e .` plus 4 more for `schema` / `cwd` / `session_id` / `generation`) | For `Stop`: a call where the lineage's pointer exists. For `UserPromptSubmit`: a call where a handover request is already submitted (it never gets here unless it's submitted -- this doesn't happen on an ordinary conversational turn) | Whether "this Stop belongs to the primary session under rein's management" can only be told from the pointer's contents. It goes through one shared function, so validation isn't written separately per reader |

- Rejection archives are read **one at a time** because the archive can contain a record that can't be parsed as JSON (an R1 rejection) -- reading them all at once would let that single record fail the whole scan and lose the correct records next to it. **The re-block marker (`stop-latch-rejected.g<generation>`) is checked before the scan**, so this `jq` never runs at all for a generation that's already been re-blocked.

- **On Stop, the cooldown check (just reading a firing marker's contents -- no external command needed) is placed before `ps`** -- a call with nothing to emit stays silent without ever spawning `ps`. **The advisory channel doesn't use this ordering** (see "the check order differs by channel," below) -- on a call where the watcher is alive, there's something to emit (the handover trigger), so checking the cooldown first would erase that trigger's turn too.
- The marker check, `ps`, and the rejection archive read -- none of these 3 happen on the no-op path for a session that hasn't submitted (the side being pushed toward a handover).

On top of that, the following hold:

- Stdin is consumed with a builtin.
- The current time rides along on the output of the `jq` call that reads the payload.
- Usage freshness is read from the `at` the writer stamps (falling back to `stat` only for a writer that doesn't stamp one).
- The cooldown is checked from the marker's contents.
- The lineage's location, for a session rein started, is received via the managed-marker env (so it never spawns the key computation -- `shasum` / `cut` / `basename`). **A manual session has no such evidence, so it builds the key** -- the 3 calls in the table above land there.
- **No temporary files are created.**

## Where records are kept (logs, health, and `hooks.log`)

**"What fired" (the firing log) and "is it running" (health state) are kept in separate locations** -- an anomaly in the latter can't be judged from the former's line count. For the file listing and the writers and readers, see [the locations and locks specification](runtime.md).

- **Every firing is one line in rein's own log** (`<state root>/hook-fire-log.jsonl`; a no-op path is never recorded).
- It never writes to the user's own firing log -- that one gates writes on whether the running script lives in the location the user's own harness treats as canonical, and rein's implementation sits outside that (writing there would print a warning banner to stderr with nothing actually recorded, polluting the hook's output channel).
- Health state records each event's last firing, delivery failures, and internal errors under `hooks/health/`, one fact per file, and **`rein doctor` reads it to check whether rein's own hooks are alive** (this is rein's self-diagnostic; it doesn't substitute for checking the user's own harness).
- On the log side, `doctor` checks: **absence** (no file, or 0 lines), **staleness** (the last line's `at` older than 1 day), **bloat** (past the size cap but never rotated), a **breakdown by kind** (line counts per `<event>/<decision>`), a **breakdown by schema** (line counts per `<schema>/<event>`), and **2 counts of unreadable lines**.
- Unreadable lines split into 2 kinds -- lines that can't be parsed as JSON, and lines that parse but carry an unknown schema -- because the cause (a writer accident, versus another writer's records leaking in, or a version mismatch) and the fix differ between them (which writer an unknown-schema line came from is read off the schema breakdown).
- **1 day is the threshold** because it's the shortest window that catches "the registration fell off" without also alarming over an overnight or weekend lull.
- Every log anomaly is **WARN** -- it's for the user to judge (there's no way to tell, from the outside, whether the mechanism is malfunctioning or the project is simply unused).

## The conditions under which Stop places the final-output marker

**Once the session that submitted a handover request finishes its response, that fact** (`<runtime>/handover-ready`, containing one line: the `session_id`) **is recorded as a marker**. The watcher waits for this marker before launching a successor (see [the handover specification](handover.md), "Waiting for the final output before launching a successor").

Only the following 2 conditions are checked, and **this runs ahead of every gate under "the conditions under which Stop blocks a stop," below**.

| Condition | Check |
| --- | --- |
| Scope: only the primary session under rein's management | The lineage's records location has a `current.json` that passes contract validation, and its `session_id` matches the hook's `session_id` |
| This session's own handover request is submitted | Either `<runtime>/handover-request.json`'s `session_id` is this session's own, or `<runtime>/processing/` has a claimed marker for this session's own `session_id` |

- **This isn't placed under the conditions for blocking a stop** -- those decide whether a handover should be pushed, while this marker represents a different fact: whether the final output came out. Placing it there would silently disable the mechanism on any of the following: (a) the user requests a handover at usage below the trigger threshold (`rein request` can be run regardless of usage), (b) a machine with no usage record, or a stale one, (c) inside a snooze period, (d) the cooldown after a single watcher-missing notice (30 minutes by default). (d) in particular is exactly **the designed recovery path** -- watcher-missing notice -> the user starts it -> the session resubmits -- so it would always be missing at the exact moment the mechanism is needed most.
- **Whether the watcher is alive isn't a condition either.** The marker represents only the fact that "this session finished its response," independent of whether anything is around to read it (if nothing is, it simply goes unread with no harm done).
- **This adds no cost.** Judging whether it's submitted returns just from checking whether the file exists when there's no marker, spawning no `jq` at all. The one `jq` call paid on a turn where a request actually exists is unchanged from before.
- Since Stop runs at the end of a turn, this firing coincides exactly with **the point where that session has finished writing its final output.** Any summary or report written after submitting the handover request is already on the user's screen by this point.
- **If the marker already exists and already names this session, it's never rewritten** (this code path runs every turn while the conversation with the user continues, so writes don't pile up).
- **A lineage with `final_output_timeout_sec` set to `0` never places the marker** -- with the watcher configured not to wait, nothing would ever read it even if it were placed (see [the handover specification](handover.md), "Waiting for the final output before launching a successor"). The value comes from the settings layer, re-read on every call (this adds no external command).
- The running-children check isn't applied here -- this marker is about the submitting side, and a handover always proceeded immediately regardless of whether children were running before this rule too (adding this check would prevent nothing new).
- This never blocks the stop, so **it consumes no generation latch**. A turn that only places the marker emits nothing, so it follows the no-op path rule and leaves no firing-log line -- the one exception is the turn that emits the wait notice below (this generation hasn't been told yet, the watcher is resident, and the wait isn't `0`), which is recorded like any other firing.

### Telling the user the wait has started

**The first turn on which the wait is real tells the user, in one line, that it has begun** -- the wait is the one window in which speaking up cancels the handover (see [the handover specification](handover.md), "Waiting for the final output before launching a successor"), and until this line existed there was no way to know it had started.

```
[rein] Handover in 10 s. Talk to this session to cancel.
```

| Condition | Check |
| --- | --- |
| This generation hasn't been told yet | `<runtime>/hooks/handover-wait.g<generation>` could be created with noclobber. It is created **only by a run that actually printed the line**, so a turn that stayed quiet leaves the next one still owing it |
| There is a wait to announce | `final_output_wait_sec`'s effective value is not `0` |
| The watcher is resident | The same single judgment used everywhere else (the watcher lock's pid is alive and cross-checked as this location's watcher -- see [the locations and locks specification](runtime.md), `watcher.lock/`) |

- **The destination is `systemMessage`, not the model's channels** (`additionalContext` / `reason`). The reader is the user at the seat, deciding within the wait window whether to skim what just landed or speak up -- the model can act on none of it. A Stop hook's `systemMessage` reaches the screen **even on a run that doesn't block the stop** (measured; the official documentation states no display condition for this field).
- **It fires once per handover, not once per turn** -- its own generation latch is what limits it, and every later turn folds on that latch before asking anything.
- **The latch is why the marker's placement can't stand in for it.** The two facts have different conditions: the marker goes down whether or not a watcher is around, while this line is only true when one is. Hanging the line off "this run newly placed the marker" meant the marker -- placed first, and never rewritten afterwards -- consumed the single chance to speak, so a lineage whose watcher was gone when the request went out got no line at all: not on that turn (no watcher, correctly), and not on any later one (the marker was already its own). Bringing the watcher back with `rein up` then handed over with the terminal switching under the user, unannounced. With a latch of its own, the first turn after the watcher is back says the line and no turn after that repeats it.
- **The remaining gap is a lineage that never takes another turn.** If the watcher is restarted from another terminal and the user never speaks to that session again, no Stop fires and nothing is announced. Nothing at the hook layer can close that -- the hook only runs when the session runs.
- **The watcher being resident is a condition here, unlike for the marker itself.** With no watcher, nothing ever picks the marker up and no handover ever starts, so a countdown line would simply be false. This reads **the run's single shared watcher judgment** -- the watcher-missing clause below asks the same one -- so a Stop never spawns more than one `ps`, and the no-op path's fixed cost is untouched.
- **The number is `final_output_wait_sec`'s effective value as-is, with no correction.** The real remaining time is always longer than the line claims: the watcher only sees the marker on one of its later polls, and the marker is typically placed before the request has even been accepted, so the accepting work sits inside the gap too. No bound is put on the gap, because the error is on the safe side -- the user always has at least as long as the line says -- so nothing tries to close it.
- **No time of day appears in the line.** A person can't read the current second off their own head, and going to look for a clock spends the very window the line is about.
- **The line states that a wait has started, not that a handover will happen.** The marker is placed as soon as the request is submitted, which can be before the watcher has claimed it -- a request the freshness checks then reject (see "A generation whose handover request was rejected," below) produces no handover, leaving this line stated ahead of an event that never came. Waiting for acceptance instead isn't available to the hook: it fires once, at the end of the turn, and acceptance lands afterwards, so the announcement would arrive after the window it announces had already closed. The failure is the harmless direction -- the user is told to watch a window that turns out not to need watching.
- **A lineage with `final_output_timeout_sec` set to `0` announces nothing**, because it places no marker to begin with -- there is no separate switch to turn off.
- **A lineage with `final_output_wait_sec` set to `0` announces nothing either**, and this one *is* a switch of its own: the marker is still placed exactly as before, and only the line is withheld. There is no window to speak up into -- the watcher leaves the wait on the same poll that sees the marker -- so `[rein] Handover in 0 s. Talk to this session to cancel.` would be false in both halves at once.
- **A turn that said nothing latches nothing** -- whatever withheld the line (no watcher, a wait of `0`). The latch records that the line went out, so consuming it on a silent turn would mark the generation as told and leave nothing to ring with once the reason for the silence is gone.
- **One Stop emits at most one JSON object.** This does not rest on a rule anyone has to remember: the notice and the watcher-missing branch below read **one shared watcher judgment per run**, so a run that emitted the notice was judged "resident" and that branch exits on its own "the watcher is around" line before assembling anything. Judging twice independently is what would open the gap (a watcher dying in between would put both branches in the emitting state on the same run).
- **One line lands in the firing log** (`decision` of `notice`, `reason` of `handover-wait`). Nothing is written to the lineage's `hooks.log` -- that log's `event` values are all about blocking a stop or letting one through, and this run does neither.

## The conditions under which Stop blocks a stop

**Only when every one of the following is met does it create one generation latch and block the stop** (`decision: block`). If even one is unmet, it passes through silently (with 2 exceptions -- the separate clause below, "When a handover request is submitted but no watcher is around," blocks without consuming the latch, using a different cooldown instead, and "A generation whose handover request was rejected" re-blocks once with **a separate latch**).

| Condition | Check |
| --- | --- |
| Scope: only the primary session under rein's management | The lineage's records location (default root: `<cwd>/.rein/`; a `--root` lineage: `<dir>/records/rein/<key>/`) has a `current.json` that passes contract validation, and its `session_id` matches the hook's `session_id` |
| Outside a snooze period | `<runtime>/snooze`'s `until` is at or before the current time |
| Usage isn't stale | `<usage_state_dir>/<session_id>.json`'s `at` is within `usage_stale_sec` |
| Usage is at or above the trigger threshold | `.context_window.used_percentage` >= `threshold_handover` |
| This session's own handover request isn't yet submitted | Either `<runtime>/handover-request.json` doesn't exist or its `session_id` isn't this session's own, and `<runtime>/processing/` has no claimed marker for this session's own `session_id` (if it is submitted but no watcher is around, the separate clause below still blocks) |
| No running children under this session | The payload's `background_tasks` has no element with `status` of `running` |
| The generation latch isn't yet consumed | `<runtime>/hooks/stop-latch.g<generation>` could be created with noclobber (even if already consumed, the separate clause below re-blocks once if that generation's handover request was rejected) |

- **Why scope is limited to the primary session**: a handover request from a session the pointer doesn't name gets rejected by freshness check R10 anyway -- pushing here would just be pushing for a request that never gets accepted. On a cwd with no lineage (a project not using rein), this passes through silently in the same way.
- Usage's `at` is a top-level UTC timestamp the writer stamps, falling back to mtime only for a writer that doesn't stamp one (if it's stale, this would be pushing without knowing "what's the current percentage right now").
- **Usage is a nested key** (`used_percentage`, inside the `context_window` object) -- a record that places it flat at the top level is never found by the authoritative reader. For the canonical key layout and types, see [the usage record specification](usage-state.md).
- Checking whether a handover request is unsubmitted also checks `processing/` -- the watcher moves it into `processing/` before reading it, so checking only the pending marker would make it look "unsubmitted" for the whole time it's being judged.
- **The latch persists per generation.** `stop_hook_active` can't substitute for it -- it's only true while a stop is already continuing, and re-fires every turn. When the latch can't be placed (can't be written), the stop is **not blocked**, and the reason is printed to stderr instead -- if the block happened but the latch couldn't be left behind, the same block would repeat every turn.
- **A persistent marker (a latch, or de-duplication for a record) is consumed only after the output and the log line have been assembled.** In the reverse order, a failure after placing the marker (unable to write the log, say) would leave that generation or that snooze consumed with nothing ever emitted, and it would never go loud again.
- The marker carries the token of the run that placed it, and if a later step fails, only a marker **whose token matches its own** is withdrawn before failing (a marker some other run has since replaced is left untouched).
- **The moment the generation latch is found already consumed, assembling the normal handover-trigger text stops right there** (a consumed generation passes through this path every turn, so text and a `rein` command line with nowhere to go aren't assembled every time). From there, only "a generation whose handover request was rejected," below, still applies.

### A generation whose handover request was rejected

**Once rejected, that generation's latch stays consumed while only the marker disappears** -- a request archived to `rejected/` reverts to "unsubmitted," so the condition table's "unsubmitted" is satisfied again, but "latch unconsumed" never is again. Left alone, that generation's stop would never block even once, and the forced-handover mechanism would disappear entirely (leaving only the advisory channel's re-trigger).

- **Once per generation**, a separate latch from the normal one (`<runtime>/hooks/stop-latch-rejected.g<generation>`) gets created, and the stop gets re-blocked. It isn't repeated without bound because every rejection reason is a defect in the request itself (freshness checks R1 through R10) -- resubmitting the same content would fail for the same reason, and a lineage unable to fix the defect would then keep getting blocked every turn.
- **The re-block text carries the rejection reason verbatim.** This is the whole point -- a re-block with no reason attached has no value (it would just result in submitting the same request again with no idea what to fix). The reason is never summarized; it's carried along with the measured values the check used.
- The one-line command to run (the handover request, the snooze) goes through **the same assembly as the normal stop block** (only the preamble differs) -- the instructions for the same action are never split into 2 different forms.
- For a generation whose normal latch is still unconsumed, it pushes with **the normal text** even if a rejection archive exists (the rejection path never hijacks the normal handover trigger).
- Cleaning up past generations **folds away both kinds of latch together** (folding just one would split cleanup into a separate path per kind).

#### Relay from the watcher (where the rejection reason lives)

**The rejection reason gets appended directly onto the marker record archived to `rejected/`** (the watcher writes it, and the Stop hook reads it).

| Field | Type | Meaning |
| --- | --- | --- |
| `rejected_reason` | string | The rejection reason from freshness validation (one string, with the rule name at the front) |
| `rejected_at` | string | When it was appended (UTC, second precision) |

- **The hook looks at the most recent archived file that carries its own `session_id` and carries a `rejected_reason`** (an archived file's name starts with a UTC timestamp, so sorting by name is sorting by time). An archived file with no reason (a leftover recovered from `processing/`) is never used as evidence for a re-block.
- The reason lives on the archived record rather than in the handover log (a `marker_rejected` line) so that the hook can get "whose request, and why it failed" from **a single file** (reading it out of the log would mean scanning an append-only file).
- **Only a rejection that can't be parsed as JSON (R1) can't have this appended to it** -- no re-block happens for that rejection (the reason still survives in the handover log and the GUI notification). The same holds for a call where the append itself fails: the failure itself gets one line in the watcher's log (never dropped silently).
- A GUI notification still fires on rejection, as before (see [the handover specification](handover.md)). The re-block is an additional enforcement channel on top of that -- not a replacement for the notification.

### When a handover request is submitted but no watcher is around

**Going silent on a submitted request only holds while the watcher is running.** With none around, nothing is left to claim the marker -- passing through silently would let usage run out with nobody moving the handover forward.

- **Usage is not a condition on either channel.** `rein request` runs regardless of usage, so a request placed below the trigger point strands in exactly the same way, and both channels report it at any usage. With the trigger-point comparison ahead of this judgment, such a lineage went silent everywhere at once -- and on the advisory channel it got the ordinary wrap-up advisory in its place ("decide when to wrap up ... finish writing the handoff document"), aimed at a session that had already done both and was waiting on a watcher nobody had restarted. What stays inside the trigger point is only the normal push (blocking a stop because usage got high), which is the one judgment usage actually decides.
- The gates this still sits under on Stop are unchanged: a snooze period (the user's own explicit "leave me alone"), and a usage record that is present and fresh (a missing or stale one is reported loudly by the advisory channel under its own name).
- The check is **the same single one** used by the CLI verbs, `rein request`, and the watcher's own lock acquisition (the watcher lock's pid is alive, and its identity is confirmed as the watcher for the target cwd -- see [the locations and locks specification](runtime.md), `watcher.lock/`). When identity can be confirmed and it turns out not to be the watcher for this location (a reused PID), that counts as **not running** (a stale lock) -- not as undetermined.
- **The check order differs by channel.** **Stop checks "is it submitted (the marker's contents)" -> "has the `watcher-missing` cooldown expired (a firing marker's contents)" -> "confirm identity (`ps`)"**: during the cooldown, the outcome is silence either way, so it never gets that far -- `ps` is never added to a submitted no-op path. The one branch that judges residency ahead of the cooldown is the handover-wait notice above, on a generation it hasn't announced yet, and that judgment is **the same one this branch then reads**. So a submitted turn pays at most one `ps`, and once the notice has gone out it pays none at all: the turns that do pay are the ones that still owe the line, where whether the watcher came back is precisely the fact the turn has to establish and the cooldown says nothing about it. **The advisory channel checks "is it submitted" -> "confirm identity (`ps`)" -> "cooldown"**: on a submitted call, `ps` is paid every time. They're in reverse order because on the advisory channel, a call where the watcher is alive proceeds to the threshold check -- checking the cooldown first would erase the handover trigger as collateral damage on any turn where the watcher happens to be alive (on Stop, both "watcher alive" and "in cooldown" fall to the same silence, so this difference never shows up there).
- Stop **consumes no generation latch**, and blocks the stop once using a different kind of cooldown (`<runtime>/hooks/<session_id>.watcher-missing`, at the interval of `notice_cooldown_sec`). It doesn't consume the latch so that the normal handover trigger remains available for that generation once the watcher comes up.
- The advisory channel (`PostToolBatch` / the compatible `PostToolUse`) also injects the same message once, using **the same cooldown**, whenever it's submitted and no watcher is around -- at any usage (it never emits a threshold message on such a call: the handover trigger would push for a request that is already placed, and the lower advisory would tell a session waiting on a watcher to go write the handoff document it has already written). With the watcher around, it proceeds as before to the threshold check.
- **The reason and the message differ between "not running" and "can't tell whether it's running."** For the former, the text carries `<this implementation's bin/rein> --cwd <target> up` and **asks the user themselves to run it** (starting the watcher isn't the session's job); on a lineage with an explicit location, "naming the lineage explicitly," below, fills real values into that same line. **The name it prints is never the bare `rein`** -- unlike the CLI entry point, which can check whether the `rein` on PATH is this implementation and fold it to the short name, hooks have no way to follow a symlink, so they always print the real path, which runs no matter what is on PATH (the canonical rule lives in [the config specification](config.md), the "Allowing project config" section). For the latter (the watcher lock's owner can't be read, or isn't numeric), no start message is printed at all; instead the user is asked to confirm **where the watcher lock is** -- falling back to a start message here risks starting a second one against a lineage that's actually already being watched, and it wouldn't resolve anything even if it did start.
- Both count as a firing, so **one line lands in the firing log** (with `reason` of `watcher-missing`). Stop additionally leaves one `stop_blocked_watcher_missing` line in the lineage's `hooks.log` (see "Lines left in `hooks.log`," below).

### Checking for running children

**Whether children are alive is read from the payload's `background_tasks`** (while running, it holds an element with `status` of `running`; it goes back to an empty array once they finish -- observed).

- **This field is absent from the official hook documentation**, so its shape rests on measurement alone: a CLI version that renames or drops it would take the primary evidence away with no error surfacing anywhere. That is why a fallback exists at all, rather than the field simply being trusted.
- **Enumeration is no substitute for it.** An element of `claude agents --json` carries no parent/child field, and a subagent born from the Agent tool never appears in enumeration at all (enumerating from a session that is running one returns only that session's own entry) -- so whether a live child is running under this session cannot be told from enumeration, however many calls it is given.
- **Only when the key is absent entirely** does it fall back to checking that no `<transcript_path's directory>/<session_id>/subagents/agent-*.jsonl` has an mtime within 900 seconds. mtime means "last written at," not "alive," so it's never used as the primary evidence.
- Falling back gets logged too, one `children_probe_degraded` line in `hooks.log` (it's never a silent fallback).
- If the fallback location doesn't exist or can't be read, it proceeds as "no children" (fail-open -- a missing location is indistinguishable from the normal state of having no children, and the cost of a false positive is only delaying the latch to the next stop).
- **The latch isn't consumed while children are around** -- a deferred call leaves one `handover_deferred` line per generation. This doesn't turn into blocking forever (it's confirmed by observation that when the children finish, the parent restarts and gets re-evaluated on the next Stop).

### The text used when pushing for a handover

The handover request command is written **ready to run as-is.** `--session-id` is filled with the real value from the payload (the recipient is never left to guess their own ID).

- `--handoff` is filled with `handoff_path`'s **effective value** (the default, if it's unset) as a real value -- matching the shape kickoff carries. Only a lineage whose effective value can't be determined (one where `handoff_path` was explicitly set empty) gets a placeholder instead, with one phrase telling the user to replace it.
- **The default location is resolved from the managed marker's records location (`REIN_MANAGED_RECORDS_DIR`).** The `--root` root (`REIN_RECORDS_ROOT`) doesn't reach the environment (observed), so re-deriving from the environment would mean a hook for a lineage relocated with `--root` points at `<cwd>/.rein/handoff.md`, mismatching the handoff document that kickoff, the handover request, and `rein init` all actually use (following the message as printed would fail with "doesn't exist").

#### Naming the lineage explicitly (`--root` / `--runtime-dir`)

**The one-line instructions fill the option that names that lineage explicitly with its effective value.** A session rein started launches `claude` with `REIN_CONFIG_FILE` / `REIN_RUNTIME_DIR` / `REIN_RECORDS_ROOT` deliberately dropped (a background session shares its environment, so a per-lineage value can't be carried through env), so printing a line with no location specified would make `rein --cwd <target> request`, typed inside that session, resolve **the default location** instead -- the handover request would fall on deaf ears there (reading as "no watcher around"), and a snooze would get written to the default location, showing success while **taking effect for not even a second**.

| Lineage layout | What gets filled in |
| --- | --- |
| A lineage relocated to a root (both runtime and records under `--root`'s layout) | `rein --root <root> --cwd <target> ...` (a shared option) |
| Anything else whose runtime directory differs from the default (the XDG state area) | `rein --cwd <target> <verb> --runtime-dir <effective value> ...` (a per-verb option) |
| A lineage that's entirely default | Nothing added |

- For a lineage relocated to a root, `--runtime-dir` alone is never added on its own, because that would leave **the records location reverting to the default `<cwd>/.rein/`** (the handover request's R10 check would then read a different lineage's pointer).
- Assembly goes through one shared-library function (`rein_lineage_cmd`) -- **Stop's message, the watcher's kickoff, and doctor's / status's messages all go through the same one** (instructions for the same action are never split into 2 forms). A bare `rein <verb>` that doesn't go through it is counted by `check.sh`'s `lineage-cmd` gate (an exception is declared on that same line, with a reason -- see [the development conventions](development.md)).
- **Both the filled-in values and the command itself are shell-escaped to a single word each** -- what actually appears is a form like `'rein' --root '<root>' --cwd '<target>' <verb>` (the table above is a skeleton showing where values get filled in, with the quotes left out). Since this is a line meant to be pasted and run, a location that contains whitespace or `;` never gets split into separate words. The shell strips the quotes around the command name before locating it, so the result of running it is unchanged.

### Lines left in `hooks.log`

The fact that a stop was blocked, the fact that a snooze let it pass through, or the fact that a piece of evidence fell through -- each of these gets **one line in the lineage's records location's `hooks.log`** (default root: `<cwd>/.rein/hooks.log`; a `--root` lineage: `<dir>/records/rein/<key>/hooks.log`, resolved from the managed marker's `REIN_MANAGED_RECORDS_DIR`).

```json
{"schema":"rein.hook-log.v1","ts":"2026-08-16T04:12:33Z","event":"stop_blocked","detail":"usage 41% / generation 3","session_id":"9b1c2d3e-..."}
```

| `event` | Meaning |
| --- | --- |
| `stop_blocked` | Blocked the stop (pushed for a handover) |
| `stop_blocked_watcher_missing` | Blocked the stop (the handover request is submitted, but no watcher is around, or it couldn't be determined) |
| `stop_blocked_request_rejected` | Re-blocked the stop (once, for a generation whose handover request was rejected; `detail` carries the rejection reason verbatim) |
| `stop_snoozed` | Passed through because of a snooze |
| `handover_cancel_requested` | Requested cancellation of the handover because the user spoke (`UserPromptSubmit`) |
| `handover_deferred` | Deferred that generation's handover because a child was running |
| `children_probe_degraded` | Fell back because the payload had no evidence for the children check |

- The 3 stop-blocking events are kept as separate `event` values because the reason for pushing differs (`watcher_missing` is a state waiting on the user's own action; `request_rejected` is a state waiting on the request being redone) -- so a reader who reads only the lineage's log never conflates the count with the wrong cause. Piling-up of `stop_blocked_watcher_missing` is held down by the `watcher-missing` cooldown, not the generation latch; `stop_blocked_request_rejected` is held down by the rejection generation latch.
- The firing log's `reason` **for a stop block** is split the same 3 ways (`handover:<%>` / `watcher-missing` / `request-rejected:<%>`); the handover-wait notice is a separate `decision` there (`notice`) and reaches this log not at all.
- `stop_snoozed` is **never piled up for the same snooze (the same `until`)** -- `Stop` runs at every turn boundary, so writing it unconditionally would keep growing the log until the snooze expires.
- `children_probe_degraded` follows the same rule, logged only once.

## The conditions under which UserPromptSubmit cancels a handover

**If the user speaks after submitting a handover request, that handover gets cancelled** (see [the handover specification](handover.md), "Waiting for the final output before launching a successor"). Speaking up means the user is right there, so there's no reason to force a handover.

The cancellation marker (`<runtime>/handover-cancel`, containing one line: the `session_id`) is placed only when **every one** of the following is met. If even one is unmet, it passes through silently.

| Condition | Check |
| --- | --- |
| This session's own handover request is submitted | Either `<runtime>/handover-request.json`'s `session_id` is this session's own, or `<runtime>/processing/` has a claimed marker for this session's own `session_id` (the same single check as Stop's condition table) |
| Scope: only the primary session under rein's management | The lineage's records location has a `current.json` that passes contract validation, and its `session_id` matches the hook's `session_id` |

- **The submitted check is placed first** -- on a call where no handover request has been made (most turns where the user speaks), it returns cheaply right there. Pointer contract validation spawns `jq` 5 times, so reversing the order would make every ordinary conversational turn that much heavier.
- **The generation latch is left untouched** -- for a cancelled generation, Stop's handover trigger stays consumed, and rein's side never pushes for a handover again for that generation. Having a handover happen while the user has stepped away would be a problem, and a cancellation is itself the user saying "I want this session to finish this" -- so **the user's own request outranks rein's.** If the user later wants a handover after all, the session just resubmits the request, and it goes through as usual (consuming the latch and completing a handover are independent).
- **A lineage with `final_output_timeout_sec` set to `0` gets neither the marker nor a log line** (the watcher has no step at all that reads a cancellation, so the log never ends up claiming "cancellation requested" on its own).
- **If the marker already exists and already names this session, it returns without writing a log line or a firing-log line either** -- folding only the write would still let the log side grow on every prompt while the same state persists (this matches the existing rule of folding an identical repetition down to one).
- The marker can be placed even outside the window while the watcher is waiting (it can be placed even on a cycle where the marker hasn't been claimed yet) -- the watcher checks this marker before entering its wait, on every cycle of the wait, and **once more at the end of the round, after the predecessor has been stepped down**. That last read is the one that catches a marker placed after the wait was already left: the handover is not turned back there (the pointer has already advanced), but the user is told the cancellation arrived too late (see [the handover specification](handover.md), "Waiting for the final output before launching a successor").
- This counts as a firing, so **one line lands in the firing log** (`decision` is `mark`, `reason` is `handover-cancel`). One line also lands in the lineage's `hooks.log`.
- **`decision` never reuses `advisory` or `block`** -- the cancellation marker is neither an injection to the model nor a stop block; it's a firing whose result is the marker itself, so it gets a distinct value that a reader of the log can count as a third kind.

## Snoozing a handover (`snooze`)

**An escape hatch from the Stop wiring that pushes for a handover.** `rein snooze <duration>` writes a deadline, and while inside it, hooks pass a stop through without blocking it.

```json
{"schema":"rein.snooze.v1","requested_at":"2026-08-16T04:12:33Z","until":"2026-08-16T04:42:33Z","duration_sec":1800}
```

- Timestamps use **the same format as the marker** (`YYYY-MM-DDTHH:MM:SSZ`, UTC, second precision). A reader only needs to convert `until` to epoch and compare it against the current time.
- The duration is **any positive integer plus a unit, `s` / `m` / `h`** (no unit means seconds; e.g. `30m`).
- The duration is capped by `snooze_max_sec`. A duration past the cap **fails non-zero rather than getting rounded down** (silently shortening it would leave the intended snooze time and the actual one mismatched).
- A file whose deadline has passed **is never deleted** (it stays as a record of when, and for how long, a snooze happened). A reader always judges from `until`.
