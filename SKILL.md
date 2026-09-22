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
- `mkdir -p .advisor/briefs .advisor/runs` and ensure `.advisor/runs/` is
  in `.gitignore`.

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

### 4. Dispatch

```
~/.claude/skills/delegate/bin/dispatch.sh --brief .advisor/briefs/NNN-slug.md --round 1
```

Interpret the exit code:

| Code | Meaning | What you do |
|---|---|---|
| 0 | ran, diff printed | go to review |
| 10 | opencode missing | tell the user to install it; stop |
| 11 | not a repo | back to preflight |
| 12 | dirty tree | stop, ask the user to commit or stash |
| 13 | brief unreadable | your bug — fix the path |
| 20 | executor failed | read the log, then review or correct |
| 24 | timed out | read the log; consider a smaller brief |

Codes 10-13 mean the harness refused and nothing ran. Codes 20 and 24
mean the attempt happened and failed.

### 5. Review — the part that matters

Establish what happened yourself. The executor's report is a hypothesis.

1. `git --no-pager diff` — read it in full.
2. Re-run every command in the brief's Verification section **yourself**.
   Never accept pasted output as evidence.
3. Check the diff against each Acceptance criterion and against Out of
   scope.
4. Check for a `BRIEF PROBLEM:` marker in `.advisor/runs/NNN-slug-rN.log`
   — that means the executor stopped deliberately and your brief needs
   fixing, not the code.

### 6. Verdict

- **ACCEPT** — summarize for the user, offer a commit that includes the
  brief.
- **CORRECT** — append a `## Round N delta` section to the brief naming
  only what was wrong and what to change, then dispatch again with
  `--round N --continue`. Do not rewrite the whole brief.
- **ROLLBACK** — for a round that went badly wrong: `git checkout -- .`,
  then re-brief from the baseline.

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
| "I'll leave Contracts loose, it'll figure it out" | Vague contracts are the top cause of failed rounds. |
| "Round 4 will get it" | The brief is wrong. Escalate. |
| "Faster if I just write it myself" | Sometimes true — decide that at preflight, not after briefing. |
