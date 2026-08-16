# Config specification

The config file's format; the layers and their precedence; when a change takes effect; the discipline for rewriting it; the handoff document's acceptance conditions.

## Layers and precedence

Operating parameters live in a plain-text `key=value` file, and **every reader goes through this one layer**.

- Readers (the watcher, the attach loop, a handover request's writer, hooks) never carry their own separate defaults.
- **Later in the list wins**: default value < user config < project config < the environment variable `REIN_<KEY IN CAPS>` < CLI flag.

| Layer (later wins) | Real file |
| --- | --- |
| Default value | The known-keys table in `scripts/lib/rein-config.sh` |
| User config | `${XDG_CONFIG_HOME:-~/.config}/rein/config` (named explicitly with `--config <path>` or `REIN_CONFIG_FILE`. **Fails if the resolved location isn't an absolute path** -- see "Locations must be absolute paths" below. **Also fails if it contains a newline** -- see "A location can't contain a newline" below) |
| Project config | `<cwd>/.rein/config` (**only content that's been explicitly allowed takes effect** -- see "Allowing project config" below. **Fails if the cwd contains a newline** -- see "A location can't contain a newline" below) |
| Environment variable | `REIN_<KEY IN CAPS>` (e.g. `threshold_notice` -> `REIN_THRESHOLD_NOTICE`) |
| CLI flag | The value a subcommand received |

- **In a session rein launched, both passive contexts take the user layer's location from the managed marker** rather than from the default. Hooks do (see "Lineage resolution" in [the hooks specification](hooks.md)) and so does the usage record's writer (see "The writer (statusLine)" in [the usage record specification](usage-state.md)); each is registered once and cannot tell from its own invocation which lineage it is serving, so without the marker a lineage relocated with `--root` would have its readers and its writer land on different files. The project layer is unaffected -- both resolve it from cwd, and both apply it under the same rule (the table under "Allowing project config" below).
- Of the known keys' defaults, **`handoff_path` is the only one whose default tracks the cwd** (see "Where the handoff document lives" below).
- `rein config list` prints the key list, defaults, origins, **types, units, and meanings** (it hides the value of a key that may hold a secret).
- **The canonical source for what each key means is the known-keys table itself** (in `scripts/lib/rein-config.sh`: `key|environment variable suffix|type|may hold a secret|default|type-and-unit label|meaning`). This 26-row list isn't copied into the docs, because a copy would just go stale the next time a key is added -- a reader who needs to know what a setting accepts runs `rein config list` instead.

### Locations must be absolute paths

**It's fail-loud if the user config resolves to a relative path** (a relative value in `XDG_CONFIG_HOME` or `REIN_CONFIG_FILE`). This is the same discipline as resolving the runtime directory (`XDG_STATE_HOME`): it fails with a reason before reading a single layer.

- Letting it pass silently would mean every reader has a different current directory (the CLI: the user's own shell; the watcher: wherever `nohup` was launched; hooks: wherever the launcher started) -- so **which user config anyone in the same lineage actually read would never line up**. A reader would silently treat a missing file as "no user config," while a writer (`rein config set -u`) would create a new file at whatever relative location it happened to be run from.

### A location can't contain a newline

**Whether it's the user config's location (`XDG_CONFIG_HOME` / `REIN_CONFIG_FILE`) or the target directory (`--cwd`), it's fail-loud if the resolved path contains a newline (LF or CR)**. This reads no layer at all, records not even one decision line (`allow` / `deny`), and fails with a reason (the check lives in one place: the config layer's entry point, `rein_config_resolve_files`).

- **A macOS pathname can hold a newline**, so this isn't "something that can't happen." A project config decision is carried by a log that holds one decision per line (see "Allowing project config" below), so a path with an embedded LF **splits one decision across two logical lines** (the first half reads back as a standalone `allow <hash> <path>` entry). A CR gets lost in the line ending and throws off literal comparison.
  - A cwd containing an LF doesn't currently even reach the log, but only because `shasum` prints a filename containing a newline with a backslash prefix and escaping, which makes the hash check fail as "not 64 hex digits" -- **that's an accidental wall resting on an external command's output convention**, and even the failure reason masquerades as "shasum is unavailable." A cwd containing a CR isn't protected by that accident, and the decision used to make it into the log.
- The log exists to guard "may a project config that came from a clone take effect," so **keeping a line intact is the entry point's job, not the format's** -- nothing entering the log ever contains a newline, guaranteed by this check rather than by a formatting trick (quoting, escaping).
- This applies only to resolving where config lives -- **no other pathname normalization (Unicode, case, folding `..`) happens here.**

## Allowing project config (`rein config allow` / `deny`)

Project config can ship bundled inside a cloned repository -- **the person who wrote it isn't necessarily the user**. As a layer it outranks user config, and it can specify `settings` (the successor session's launch settings), `model`, `kickoff_note_path`, and even `runtime_dir` -- so **its mere presence isn't enough to take effect.**

- **The unit of decision is one file** (keys within it aren't sorted individually). Its content hash (`shasum -a 256`) is recorded, and an explicit decision is required **the first time, and every time the content changes.**
  - Content is what's checked, rather than path or mtime, because those can't catch the shape where the same location's content gets swapped out (a clone, a pull, a checkout all just swap content in place). **A denial is tied to content too**: if the content changes after a denial, the decision lapses and reverts to undecided.
- **There are two decisions:**

| Verb | What it decides | After deciding |
| --- | --- | --- |
| `rein --cwd <target> config allow` | **Let** that content take effect as a layer | The project layer takes effect as usual |
| `rein --cwd <target> config deny` | **Move on without applying** that content | Everything runs without the project layer, in every context (**no notification either** -- never sounding an alarm every time for the person who already made the decision) |

- `deny` exists so that a clone bundling config the user doesn't trust never leaves "allow it" or "delete the file git is tracking" as the only ways out. A decision can be revisited (a denied config can later be allowed).
- **A decision is displayed before it's recorded**: the target's path and content are shown before recording (`.rein/` isn't a location people habitually inspect, so the decision act itself doubles as showing the content). A second decision on the same content ends with an "already ..." line instead.
- **What's shown on screen is processed** (what the judgment and the record see is the raw bytes -- conflating the two would mean what's shown and what takes effect disagree). Two kinds of processing happen:
  - **Control characters are rendered visibly** (C0 and DEL become `^`-prefixed notation; TAB is skipped, since it only advances a column and can't erase what's already been printed). Whenever a substitution happens, one line announces it -- **that line's mere presence is itself the signal that "this content isn't normal,"** so it doesn't print unconditionally. This covers **every place** the decision verbs print to the screen (not just the content line -- the target and resolved paths, and the reason text for content that fails to validate too) -- leave even one unprocessed spot on the same screen and everything after it can be hidden through it.
  - **A cap is placed on volume** (line count and per-line length). Anything past the cap is dropped, with a note that it was truncated. Even without control characters, bundling in a huge amount of content could push an important line off-screen -- the effect is the same as deleting a line from the display. The cap is set above what a config listing every known key would hit.
- **Only the allow side checks that the content validates first** (format, known keys, value types). Content that doesn't validate is never allowed and fails non-zero -- closing off the shape where "allow succeeds, but the very next verb fails on an unknown key." Layer combinations (`threshold_notice` > `threshold_handover`) aren't checked here -- that can break in user config too, so this file's trustworthiness isn't gated on some other layer's current state. **The deny side never validates** -- using a clone that bundles broken config, without applying that config, is exactly what this verb is for. That said, **content that fails even to be read can't be denied either** -- a NUL byte fails in the read layer, and a shape that isn't a regular file (a directory, a broken symlink) fails in the decision verb itself, both before validation is even reached. This is the one shape the escape hatch above doesn't reach: until that file is deleted, that cwd fails for the same reason in **every context, passive ones included (hooks, statusLine)** -- no usage gets recorded and no handover ever happens, so the "never breaks the session or the user's own turn" row in the table below applies only **while undecided**, not to content that can't be read.
- **The record lives next to the user config** (`<the user config's parent>/allowed-project-configs`) -- never inside the project, never inside the repository (a location a clone could bundle would let the decision record itself be shipped). For a lineage that moved its user config with `--root` or `--config`, **the decision moves with it** -- each lineage's decisions are its own closed property.
- **What happens while undecided is split by context** (in every context, **the project layer never takes effect**):

| Context | While undecided |
| --- | --- |
| CLI verbs (`config`, `up`, `down`, `status`, `prune`, `doctor`, etc.), the watcher, the attach loop, a handover request | **Exits non-zero** with guidance on the decision to make (fail-loud) |
| hooks, statusline (passive contexts) | Runs **without applying** the project layer (this never breaks the session or the user's own turn). Not applying it is written to stderr; hooks surface it in the seat once, at SessionStart (never re-injected every 30 minutes) |

- **The CLI name embedded in the decision guidance is decided by the layer that prints the guidance, and passed in** (the config layer never has a name of its own). Whether a name can be folded down to the short `rein` depends on whether the `rein` on PATH is this implementation, a judgment that requires following a symlink -- so only the entry point that runs **before** the shared library is even read (`bin/rein`) has that material. The hooks, the watcher, seat, and a handover request don't, so they are always given **the real file's path, which runs no matter what is on PATH**. If the config layer decided this for itself, the same log's guidance would come out with two different names depending on the caller, mixing in a bare `rein` that can't be run where it isn't installed. What's passed is the first argument to `rein_config_resolve_files <name> <cwd> [<record location>]`, and **it has no default** -- making it optional would leave whichever layer forgot to pass it silently printing guidance under a different name.
- The judgment is consolidated into **one function in the config layer** (`rein_config_project_allowed`). Writing it separately per reader would create a shape where "only this one reader silently applies it."
- **A `rein config set` / `unset` rewrite updates the allow record too** (since the user explicitly named the content through a verb, the very next read shouldn't turn around and refuse it as "not yet allowed"). That said, **a project setting that's decided not to apply isn't even a target for rewriting** (it fails non-zero) -- writing to it would let a rewrite's cleanup silently override the denial and let other lines bundled into the same file take effect too.
- To remove a decision itself, delete the matching line from the ledger (`<decision> <hash> <the project config's absolute path>`, where decision is `allow` or `deny`) or delete the whole file (whatever's removed reverts to undecided on the next read).
- **The log has exactly one line shape**: the decision is `allow` or `deny`, the hash is 64 hex digits, the path is absolute. Fields are separated by a single space, and **splitting takes the first two spaces from the front** -- so a path containing spaces still round-trips (a path containing a newline never reaches the log at all, caught at the entry point by "A location can't contain a newline" above). When the same path has multiple lines (a hand-edited log), the last one wins.
- **A ledger with even one line that can't be read this way falls back to undecided rather than being skipped** (`the decision ledger has an unreadable line (<ledger>, line N)`). Skipping it would let an allow through **without distinguishing an injected line from a legitimate one** -- the log guards "may config that came from a clone take effect," so its judgment never continues on a guess when it holds an unreadable line. For the same reason, a writer (the cleanup that follows `config allow` / `deny`, or `config set` / `unset`) **never appends to a log that already holds an unreadable line** either (appending would leave that line in place, so a decision just made would revert to undecided again on the very next read). To fix it, either fix that line or delete the whole log and decide again.
- What this gate guards against is **the project layer a repository can bundle**, not someone who can write an environment variable (the environment layer already outranks the project layer -- how that boundary is drawn is in "Threat model" in [handover contract design](architecture.md)).

## Format specification (readers and writers follow only this rule)

The format is defined **only by this section** -- it's never left to a shell's own interpretation or a reader's own discretion.

- One setting per line. Never `source`d (never let a value run as arbitrary shell code).
- A blank line, and a line whose **first character** is `#`, are the only comments. An indented `#` isn't a comment -- it's a format violation.
- Split on the first `=`; the left side is the key, the right side the value. The value is read **verbatim** to the end of the line -- no shell expansion, no `~` expansion, no quote interpretation, no trimming of surrounding whitespace.
- A value never contains a newline (LF / CR); this is rejected regardless of layer (even a value that came from an environment variable). Anything that might need to carry a newline travels as a path instead (`kickoff_note_path`).
- A duplicate key within the same file is a format violation (letting the later one win would leave a line the user thought they'd deleted still taking effect).
- **The set of known keys is fixed.** An unknown key, a value that doesn't fit its type, or a combination that can't hold (`threshold_notice` > `threshold_handover`) all fail non-zero, whether from a reader or from `rein config set` (never silently falling back to a default). A `REIN_*` environment variable outside the config layer's scope is ignored.
- **An integer type never accepts a leading zero** (`08`, `007`). `[`'s integer comparison reads it in base 10, so a purely literal check would let it through, but `$(( ))` reads a leading zero as octal -- so if it were allowed to be written, a later stage (`rein up`'s deadline arithmetic, for one) would fail for **a reason that reads as unrelated to the setting's value**. A single-character `0` is accepted as the floor of a nonnegative integer. `0.2`, for a type that allows decimals (`poll_interval_sec`), still works as before.

"Unset, meaning default" and "explicitly empty, meaning disabled" are **kept distinct**.

- An empty value with its origin still on record reads as "disabled at that layer," and never falls through to the layer below.
- That said, **the CLI flag layer has no notion of explicitly empty** -- a flag with an empty value, like `--settings ''`, is never accepted as a disable; it fails non-zero with a reason. Silently treating it as unspecified would send no signal at all to a user who meant to disable it, while the run continues on the layer below's value -- and it would split "how to disable something" into two different mechanisms.
- **The shared options (`--cwd` / `--root` / `--config`) follow the same discipline**: an empty value never falls back to unspecified -- it fails with a reason. This closes off the shape where a script piping `rein --config "$CFG" ...` with an empty `CFG` silently reads the default `~/.config/rein/config` instead of the config that was meant, and proceeds all the way through to `up`.
- **Where "disable" should point depends on the key**: for a key whose default is empty, `rein config unset <key>` disabling it is exactly right, but **`unset` on a key with a real default (`handoff_path`) brings the default back**, so disabling it takes explicit emptiness instead (`rein config set handoff_path ""`) -- pointing someone to the opposite verb would leave a user who meant to disable it running on the canonical default instead.
- **The one line of guidance names the scope too (`--user` / `--project`)**. `config set` / `unset`'s scope **defaults to the project layer when not stated explicitly**, so if a value sits at the user layer and the guidance leaves the scope at its default, running exactly what `config unset <key>` says removes nothing (`<key> is not set in <cwd>/.rein/config` fails non-zero, and the effective value is unchanged). **Wherever it's clear which layer holds the value, the guidance names that layer in one line** (the origin comes from `rein_config_scope_opt` reading `rein_config_origin`). **That failure itself is one of those places**: `<key> is not set in <file>` is exactly the point where the reader has no next step, so it names the layer the value is actually in and hands over the line that would clear it. Where it isn't clear (an option check that runs before config has even been read through), **both layers are named literally, and the guidance never leans on a default.** When a value comes from the environment-variable layer or the CLI-flag layer, `config` has no way to clear it there, so the guidance doesn't print a one-liner claiming it can.
- **`config get` takes no scope** (it's the entry point that folds every layer down to the effective value) -- so a "go check the value" guidance line never carries `--user` / `--project`; adding one would just be a wrong pointer.

## When a change takes effect

**Different readers re-read at different times**: hooks on every call, **the watcher every poll cycle**, the attach loop at launch, and a handover request's writer at call time.

- **`runtime_dir` is the only key pinned at launch.** The runtime directory the watcher actually watches gets fixed at launch (swapping it out mid-cycle would split the marker, `watcher.lock/`, `watcher.heartbeat`, and `owner` references mid-handover). **Restart the watcher to make a change to it take effect.**
- If a poll cycle's re-read finds `runtime_dir`'s effective value has drifted from what was fixed at launch, this is never silently ignored -- **it's logged once, both as a notification and to `watcher.log`** (riding the existing mechanism that only sounds once per distinct reason).
- If the watcher's poll-cycle re-read fails, it **never stops watching** -- it keeps running on the previous effective value and logs the reason, both as a notification and to `watcher.log` (never silently falling back to a default; the same reason is never repeated). If it can't be read at launch, it exits non-zero (there's no previous value to fall back to).
- **The effective value never gets baked into a child process's environment.** A delegate (`rein request`, etc.) validates the setting on the command side, but the value never travels through an environment variable -- doing so would let the environment layer outrank the file layer, pinning the watcher's every poll-cycle re-read to whatever it was at launch.

## The discipline for rewriting (`rein config set` / `unset`)

A rewrite **only swaps the file in once it validates** (an invalid setting is never observed as a real file).

**Reading the layers never gates the verbs that repair them.** `set` and `unset` are the way out of a broken config, so a config that fails to read is not allowed to take them down with it: they carry on past the failed read, saying so on one warning line, and then attempt the rewrite. This is not a hole in validation:

- **The read verbs (`get` / `list`) stay strict.** Their answer would otherwise be a value read out of a state that doesn't hold, so naming the reason and failing non-zero *is* their answer.
- **The rewrite still validates.** Every layer up through the scope being saved is re-read against the candidate before anything is replaced, so a rewrite that would leave the result still broken is rolled back with its own reason. What changed is which failures may stop the attempt, never which results may land.
- **The allow gate is not stepped over.** A load fails for two distinct reasons -- a value in a file is wrong, or a project file has not been decided on (or its location can't be read at all) -- and only the first is a content violation. Writing under the second would have the rewrite's own allow-recording cleanup turn on **every other line bundled in the same file**. An undecided project file has its own way out: `config allow` / `config deny`, which run before any layer is read.
- **`config unset` accepts a key the known-keys table doesn't hold, when that key is literally on a line of the target file.** A mistyped key can't be repaired with `set` (the stray line fails the rewrite's own re-read), so removing the line is the only repair; and a key the user can see in the file is a line they are asking to delete, not a typo in the command. A key that is *neither* known nor present in the file is still refused as a usage error (exit 2), so the two stay distinguishable.

- **`config list` is a human-readable table** (tab-separated; a value containing a tab will throw off the layout). It has no machine-readable form. **Each key comes as a pair of lines**: the first is `<key>=<value><TAB>(<origin>)`, the second is the type-and-unit label and meaning, indented four spaces: `<type-and-unit label> -- <meaning>`. `config get <key>` is the entry point for just the value (one line, no explanation, no origin).
- A key that may hold a secret (currently `settings`) has its value hidden (`***`); the full value comes out only through `config get settings`, naming the key explicitly. A format-violation error never includes the line's content either (its position is shown by line number).
- A rewrite is written to a temp file in the same directory and read back before it's swapped in -- an invalid setting is never observed as a real file, even for an instant.
- **Validation only looks at the file layers up through the scope being saved** -- the environment is never mixed in (letting whatever's currently in the environment mask a violation in the file layer would leave a config that everyone else who reads it fails on, even though it wrote successfully). A violation in the effective value, once the environment is folded in too, is only a one-line warning.
- A symlinked config is written through to its real file, keeping the existing mode (a new one gets 0600).

## Where the handoff document lives (`handoff_path`)

The handoff document is the one entry point that reaches the successor at every handover, so it **has a default** (its location is decided even with nothing configured). This section is the canonical source for that default location.

| Lineage | Default location |
| --- | --- |
| The default root | `<cwd>/.rein/handoff.md` (next to the records) |
| A `--root <dir>` lineage | `<dir>/records/rein/<key>/handoff.md` (next to that lineage's records) |

- **`handoff_path` is the only default that tracks the cwd**, and it can't be written into the known-keys table (that table is expanded once, at load time, and the cwd at that moment is wherever the hook's launcher or `nohup` started -- unrelated to the target project).
  - Resolution is consolidated into **one function in the shared library**, and every path that fetches the effective value goes through it -- a handover request, cold start, `status`, and `config` all see the same value. Assembling it separately per path would let "which one is canonical" split within the same lineage, with only one of them pointing at the real thing.
- **Even with a default, an empty or never-created handoff document blocks a handover** (cold start's existence check and freshness validation's R6/R7 -- see "Freshness validation" in [the handover specification](handover.md)). The first run is `rein --cwd <target> init`, which places the template (needed **per lineage**).
- **There's exactly one shape that's accepted: a non-symlink regular file that isn't empty.** `rein init` (the template), `rein bootstrap` (launching the first session), and `rein request` (a handover request) all check it against this same one judgment.
  - A symlink isn't accepted because swapping out what it points to would let the judgment of "was the handoff document actually written" (existence, non-emptiness, freshness) get quietly substituted for some other file's state.
- `config unset handoff_path` reverts to the default (**this isn't disabling it**). Running with **no handoff document at all** takes **explicit emptiness** (`config set handoff_path ""`) -- and that lineage then fails unless `--handoff` is passed on every handover request (it never silently falls back to the default).
- **Hooks resolve the default location from the managed marker (`REIN_MANAGED_RECORDS_DIR`)** (see "Lineage resolution" in [the hooks specification](hooks.md)). A `--root` root never reaches a session's hook process through the environment, so re-deriving it from the environment would leave hooks looking at a different handoff document than the one kickoff, a handover request, and `rein init` see.
