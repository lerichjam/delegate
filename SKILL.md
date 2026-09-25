---
name: delegate
description: Act as staff-engineer advisor and delegate implementation to an OpenCode executor, then independently verify the diff. Use when the user says "/delegate", "delegate this", "hand this to opencode", or asks for advisor/executor delegation of a coding task.
---

# Delegate — Advisor/Executor Workflow

You are the **advisor**. You conceptualize, architect, and specify. An
OpenCode executor does the typing. You then verify its work yourself.

**Announce at start:** "Using the delegate skill — I'll write the brief,
dispatch to the executor, and review the diff myself."

## When not to use this

Delegation has fixed overhead: writing a brief plus reviewing a diff. For
a small local edit you already understand, just make the edit. Delegate
when the work is substantial enough that specifying it costs less than
doing it — a new module, a broad refactor, wiring across many files.

This is not `ralf-opencode`. That skill grinds many issues unattended.
This is one task, supervised, with you reading every diff.

## Process

### 1. Preflight

- Confirm the task is worth delegating (see above).
- `git rev-parse --git-dir` — if not a repo, offer `git init` plus a
  baseline commit, and get the user's agreement first.
- `git status --porcelain` — if dirty, **stop and ask the user to commit
  or stash.** Do not work around this. A dirty tree makes the post-run
  diff unreadable, which destroys the only real verification step.
- `mkdir -p .advisor/briefs .advisor/runs`. Dispatch drops a
  self-ignoring `.gitignore` into `.advisor/runs/`, so raw executor logs
  cannot reach a commit even if the repo's own ignore rules miss them.

### 2. Reconnaissance

Read enough of the repo to state contracts correctly — not exhaustively.
You are locating the files that matter and learning the conventions. The
executor does the thorough scan. If you cannot state exact signatures
after this step, keep reading; a vague Contracts section is the main
cause of a failed round.

### 3. Write the brief

Copy `~/.claude/skills/delegate/templates/brief.md` to
`.advisor/briefs/NNN-slug.md` and fill every section. Number sequentially
from the existing contents of `.advisor/briefs/`.

Quality bar: could a competent engineer who has never seen this
repository implement it from the brief alone? If not, it is not finished.

Then **run every command in the Verification section yourself, against
the unchanged tree, before dispatching.** You are not checking that it
passes — it should not yet. You are checking that it *runs*: right path,
right flags, right argument format, right interpreter. A Verification
command that cannot succeed makes the executor's report and your own
review equally meaningless, since neither of you is measuring anything.
This has already cost a real round: a brief specified
`--date $(date +%Y-%m-%d)` for a script that only accepts `YYYYMMDD`.

### 4. Dispatch

```
~/.claude/skills/delegate/bin/dispatch.sh --brief .advisor/briefs/NNN-slug.md --round 1
```

`--round` only names the log (`.advisor/runs/NNN-slug-rN.log`). What
decides whether a round is a continuation is `--continue` (step 6):
without it, every dispatch is a fresh start that needs a clean tree and
records a new base.

Optional flags:

- `--timeout <seconds>` — how long the executor gets. Default 600.
- `--model <provider/model>` — override the executor agent's own model.
- `--message <text>` — what to tell the executor about the attached
  brief. Defaults to "Implement the attached brief. Follow it exactly.";
  a correction round must override it (step 6).

Dispatch echoes the base commit it pinned the diff to. Note it — step 5
needs it.

Interpret the exit code:

| Code | Meaning | What you do |
|---|---|---|
| 0 | ran, diff printed | go to review |
| 10 | opencode missing | tell the user to install it; stop |
| 11 | not a repo | back to preflight |
| 12 | dirty tree | stop, ask the user to commit or stash |
| 13 | brief unreadable | your bug — fix the path |
| 14 | executor agent unresolved | run `~/.claude/skills/delegate/install.sh`, then retry |
| 15 | no recorded baseline | you continued a delegation that never had a fresh start; dispatch without `--continue` |
| 16 | repository has no commits | offer a baseline commit, with the user's agreement |
| 20 | opencode exited nonzero | read the log: an argv or agent error means the executor never ran; otherwise review or correct |
| 21 | the executor moved a git ref (dispatch), or HEAD is not the base (rollback) | do not accept or roll back; show the user the ref change dispatch printed — `git reflog` has the history — and let them decide |
| 24 | timed out | read the log; raise `--timeout` first — a smaller brief is the second remedy, not the first |
| 1 or 2 | your invocation is malformed | dispatch's own argument handling rejected it; fix the command line |

Codes 10-16 mean the harness refused and nothing ran. Code 24 means the
executor was still running when the clock ran out, so the tree may hold a
half-finished change — review it before re-dispatching.

### 5. Review — the part that matters

Establish what happened yourself. The executor's report is a hypothesis.

1. `git --no-pager diff <BASE>` — read it in full, using the base SHA
   dispatch echoed. Pinning to the base is what makes the diff mean
   anything on round 2 or later, when the tree already holds round 1.
2. Read every file listed under `=== new files ===` in full. **`git diff`
   cannot show a file the executor created:** a new file is untracked,
   so no form of diff mentions it. The list covers every round since the
   base, and holds only what the executor created — not a file the user
   dropped in between rounds. A new file the brief did not ask for is an
   Out of scope violation, not a bonus. Anything under
   `=== pre-existing untracked files ... ===` is one by definition: the
   executor changed a file that was there before it started, such as
   your own untracked brief.
3. Re-run every command in the brief's Verification section **yourself**.
   Never accept pasted output as evidence.
4. Check the diff *and the new files* against each Acceptance criterion
   and against Out of scope.
5. Check for a `BRIEF PROBLEM:` marker in `.advisor/runs/NNN-slug-rN.log`
   — that means the executor stopped deliberately and your brief needs
   fixing, not the code.

### 6. Verdict

- **ACCEPT** — summarize for the user, offer a commit that includes the
  brief.
- **CORRECT** — the shape is right and you can name the fix. Append a
  `## Round N delta` section to the brief saying only what was wrong and
  what to change, then dispatch again. Do not rewrite the whole brief —
  and say in the message that it is a delta, because the whole brief is
  re-attached every round:

  ```
  ~/.claude/skills/delegate/bin/dispatch.sh --brief .advisor/briefs/NNN-slug.md \
    --round N --continue \
    --message "Apply the '## Round N delta' section at the end of the attached brief. Do not redo the rest."
  ```
- **ROLLBACK** — you would have to write "undo this and start again"
  rather than "change X to Y". Concretely: the executor chose a different
  decomposition than Architecture specified, or it touched files Context
  never named, or a correction would discard more of the round than it
  keeps. A useful test — if your delta is getting longer than the brief's
  Contracts section, you are writing a new brief, so roll back instead:

  ```
  ~/.claude/skills/delegate/bin/rollback.sh --brief .advisor/briefs/NNN-slug.md
  ```

  It restores every tracked file to the base and deletes the files the
  executor created — only those. Your briefs survive, and so does any
  untracked file the user added mid-delegation. If it warns that it
  could not restore a pre-existing untracked file, tell the user: git
  holds no copy of it. Then revise the brief and dispatch the next
  round **without** `--continue`, so the executor starts a fresh session
  rather than resuming the one that went wrong.

### 7. Round cap

Stop after 3 rounds. Report to the user what is blocking and hand them
the decision. Three failed rounds means the brief is wrong or the task is
unsuited to delegation; a fourth round fixes neither.

## Red flags

| Thought | Reality |
|---|---|
| "The executor says tests pass, good" | Run them yourself. That is your entire job here. |
| "The diff is long, I'll skim it" | Skimming means you delegated the review too. |
| "Tree's only a little dirty" | Then the diff is contaminated. Stop. |
| "I'll leave Contracts loose, it'll figure it out" | Go back and read more code until you can write the signatures. |
| "Round 4 will get it" | The brief is wrong. Escalate. |
| "Faster if I just write it myself" | Sometimes true — decide that at preflight, not after briefing. |
