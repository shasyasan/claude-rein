---
name: handoff
description: Read the handoff document to resume work (receiving side), or finish writing it before requesting a handover (leaving side). Triggers on phrases like 'hand off', 'handoff', 'pick up where I left off', or 'resume'. Also the first step for a session that kickoff pointed at a handoff document.
---

# Receive and leave the handoff document

A rein lineage has **exactly one handoff document.** The successor session's kickoff points to this one document, and no other. What's written here is only **how to decide where it lives** and **the discipline for reading and writing it** -- what actually goes in it (what to write, for which project) is up to whoever writes it.

## Receiving side (asked to pick up work, or launched from kickoff)

### 1. Decide where it lives (check these in order; the first one that resolves wins)

| Order | What to check | Notes |
| --- | --- | --- |
| 1 | **The absolute path from your kickoff at launch** | The value the watcher resolved at the moment of handover. Most reliable. |
| 2 | The **effective value** of `rein --cwd <target project> config get handoff_path` | Returns the default (next to the records) even for a lineage with nothing configured. |
| 3 | `pointer.handoff_path` from `rein --cwd <target project> status --json` | **The value the predecessor declared.** Can go stale after the document moves, so check this last. |

When 2 and 3 disagree, go with 2 (the effective value). `rein --cwd <target project> status`'s `handoff:` line already shows the effective value, its origin, and whether it exists, all in one place -- checking it once is enough to confirm where you decided it lives.

**If it can't be resolved, doesn't exist, or is empty, don't start filling the gap with guesses.** Don't go looking for it elsewhere (don't enumerate similarly-named files, working notes, or old logs) -- tell the user where the document was supposed to be and what the situation is, and ask.

### 2. Read it (however much you read up front becomes the fixed cost of resuming)

- Read only **the three sections "Where things stand," "Next steps," and "Standing decisions"** (the standing-decisions section constrains everything that follows -- don't skip it). Open "In flight at handover" only when you need to decide whether to reload something. Don't reread the whole document, and don't preemptively open documents it references (open them once you actually need them).
- This is the **only** document. Don't go looking for another one on the assumption that one must exist.

### 3. Reply on your first turn

- **Where things stand** (how far the work has gotten)
- **What to do next** (the next step the document points to)
- **Whether you're waiting on the user's judgment** (and if so, on what)

Don't send back a long summary of what you read. This one reply should be enough to decide whether you need the user's go-ahead before starting work.

### 4. Check for concurrent work before starting

- **Another session that shares this document may be alive at the same time.** Before starting, check who's running with `ListAgents`, and **ask that session directly if your scope looks like it overlaps** (the document alone can't tell you what a session running since the handover has already changed).
- **Right after a handover runs, read the handover log (`handover.log`, sitting with the lineage records).** Where the records live isn't fixed -- a `--root` lineage keeps them outside the target project -- so resolve it the same way as the document itself, from the `records:` line of `rein --cwd <target project> status`, rather than assuming `.rein/`. A bug in the handover mechanism itself is only noticeable from a seat that's actually using it. If something looks off, record it wherever that environment keeps such notes.

## Leaving side (before requesting a handover)

1. **Finish writing the document before `rein request`.** A handover request is validated on the assumption that the document is already complete (it's rejected if the document doesn't exist, is empty, or is stale), and it's the only thing the successor reads.
2. **Fold everything into this one entry point.** Where things stand, next steps, and any notes all need to be self-contained inside this document (don't split them into another file, or write "see the attached notes"). The successor reads only this document, so anything you put outside it goes unread.
3. **Use the template's section structure as-is -- don't add sections, don't drop them.** The template `rein init` places (4 sections: Where things stand / Next steps / In flight at handover / Standing decisions) is the canonical format, and each section's parenthetical is the instructions for writing it. Don't repeat those instructions here (no duplicate definitions). **A handover request rejects any deviation from the section structure** (a missing section, or a `##` heading not in the template) -- permanent rules, procedures, and knowledge belong not in this document but in whatever canonical source your environment defines for them.
4. Once it's written, place the handover request (see `/rein:request`).

The document's location follows the same effective value as the receiving side (`rein config get handoff_path`); if nothing exists yet, `rein --cwd <target project> init` creates the template.
