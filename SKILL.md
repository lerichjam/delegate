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

**Run it with the Bash tool's `run_in_background: true`** and wait for the
completion notice. The executor gets up to 600 seconds, and the Bash tool's
own timeout (2 minutes by default) would otherwise kill dispatch first. Dispatch
stops the executor when that happens (exit 130), so the round is lost. Do not
poll the log while it runs, and do not edit the tree.

`--round` only names the log (`.advisor/runs/NNN-slug-rN.log`). What
decides whether a round is a continuation is `--continue` (step 6):
without it, every dispatch is a fresh start that needs a clean tree,
records a new base, and opens a new session. With it, the round resumes the
session round 1 opened: by its recorded id on OpenCode 2.x, or with `-c`
(the last session in this directory) on 1.x.

Optional flags:

- `--timeout <seconds>` — how long the executor gets. Default 600.
- `--model <name or provider/model>` — the executor's model. Defaults to
  `deepseek-flash` (`opencode-go/deepseek-v4.1-flash`). See **Choosing the
  model** below.
- `--message <text>` — what to tell the executor about the attached
  brief. Defaults to "Implement the attached brief. Follow it exactly.";
  a correction round must override it (step 6).

Dispatch echoes the base commit it pinned the diff to. Note it — step 5
needs it. It also prints a `secrets ->` line. If it says `NOT protected`,
tell the user in your report: the executor's shell could read `.env` files
on that run.

Interpret the exit code:

| Code | Meaning | What you do |
|---|---|---|
| 0 | ran, diff printed | go to review |
| 10 | opencode missing (or `OPENCODE_BIN` names nothing) | tell the user to install OpenCode 1.x or 2.x, or set `OPENCODE_BIN`; stop |
| 11 | not a repo | back to preflight |
| 12 | dirty tree | stop, ask the user to commit or stash |
| 13 | brief unreadable | your bug — fix the path |
| 14 | executor agent not found by opencode | nothing ran. The refusal names OpenCode's error when it gives one. Run `~/.claude/skills/delegate/install.sh`, then retry |
| 15 | no recorded baseline or session | you continued a delegation that never had a fresh start, or it was rolled back; dispatch without `--continue` |
| 16 | repository has no commits | offer a baseline commit, with the user's agreement |
| 17 | model unknown, or not offered by opencode | nothing ran. Tell the user which names exist (`config/models.tsv`) and ask which to use. Never substitute a model yourself |
| 18 | opencode is neither 1.x nor 2.x | nothing ran. Tell the user, and stop. Do not adapt the flags to another major |
| 19 | the executor stopped with `BRIEF PROBLEM:` | the report still prints, but do not treat it as a round. Read the problem in the log; fix the brief, or answer the executor's question, then dispatch again |
| 20 | opencode exited nonzero | read the log: an argv or agent error means the executor never ran; otherwise review or correct |
| 21 | the executor moved a git ref (dispatch), or HEAD is not the base (rollback) | do not accept or roll back; show the user the ref change dispatch printed — `git reflog` has the history — and let them decide |
| 24 | timed out | read the log; raise `--timeout` first — a smaller brief is the second remedy, not the first |
| 130 | dispatch itself was killed (a tool timeout, Ctrl-C) and stopped the executor | treat it like 24. If a Bash timeout did it, re-run in the background |
| 1 or 2 | your invocation is malformed | dispatch's own argument handling rejected it; fix the command line |

Codes 10-18 mean the harness refused and nothing ran. Codes 24 and 130 mean
the executor was stopped mid-run, so the tree may hold a half-finished
change — review it before re-dispatching.

#### Choosing the model

The executor always runs on an explicit model, so the one you review
against is the one that did the work.

- **The user named a model in chat** ("use deepseek pro", "try the v4.1
  flash"): pass their words as `--model "<their words>"`. Dispatch resolves
  them through `config/models.tsv`, and the log records the resolved id. Do
  not translate the name yourself, and do not pass a guessed id.
- **The user named none:** omit `--model`. The default applies.
- **Exit 17:** the name is not in the table, or opencode does not offer it.
  Show the user the names in `config/models.tsv` and ask which one they
  want. Do not fall back to another model without asking.
- A `provider/model` id is accepted as given, as long as opencode offers it.

Adding a model means adding one line to `config/models.tsv`. The default
is the frontmatter `model:` in `agent/executor.md`.

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

  It restores every tracked file to the base, deletes the files the
  executor created — only those — and ends the delegation, so a
  `--continue` is refused (exit 15) rather than resuming the undone work. Your briefs survive, and so does any
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
