# OpenCode 2.x compatibility: investigation and plan

**Status:** implemented on the working tree on 2026-10-17, against `opencode v2.0.27`.
Nothing is committed. The investigation and cross-check below are unchanged. What
changed from this plan, and what is still unverified, is in
[Implementation status](#implementation-status).

## Implementation status

| Phase | Result |
|---|---|
| 0 Pin binary | Done. `OPENCODE_BIN` (default `opencode`). Version must match `^opencode v2\.`, otherwise exit 18. |
| 1 Preflight | **Changed from the plan.** `agent list` is gone, and `debug agents` and `api --standalone agent.list` both return zero agents on a private server, so neither can be the probe. The run itself is the check: OpenCode resolves the agent before any model call, and dispatch reads `Agent not found: "executor"` from the log (exit 14). `install.sh` uses a probe with a non-existent model: `Model unavailable` means the agent resolved. |
| 2 Model | Done, via the lookup table. The frontmatter must still equal the default, and a test enforces it. Decision 2 (frontmatter as the only source) is superseded by the chat-name lookup that was requested. |
| 3 Standalone | Done. Every run is `--standalone`. **Verified live:** a timeout killed a real executor `sleep 300`, and nothing survived; dispatch exited 24. **Found:** OpenCode exits 130 on SIGTERM, not 143. Detecting the timeout by exit code reported it as 20. The watchdog now records that it fired. |
| 4 Permissions | **Verified live:** rules are last-match-wins. The `git commit*` deny, listed after `shell *` allow, rejected the command. `read` on `.env` is now denied, after `read *`, and returned `Permission denied: read` in 10 s. **Not verified:** nested paths such as `config/.env`; the shell can still read `.env`. No live run triggered an `ask`, so the hang question is still open. |
| 5 Continuation | Done. Round 1 generates a `ses_` id and stores it in `.advisor/runs/<stem>-session`; correction rounds pass `--session`. **Verified live:** round 2 resumed the same session. `-c` is gone. Any `ses`-prefixed id is accepted. |
| 6 Tests | Done. The stub models v2. 135 assertions pass. |
| 7 Live | **Partly done:** a round, a correction that resumed the session, and a timeout that killed a real child. **Not done:** a full betpawa brief, and a 3-round loop. |

**1.x support (added after the table above):** the skill runs on both majors, with
one code path per version. Per-major differences: version read from `--version`
(1.x prints a bare number); the preflight is `agent list` on 1.x and the run-based
check on 2.x; models are listed with `models` on 1.x and `models --standalone` on
2.x (the ids are the same); 1.x runs without `--standalone` and continues with `-c`.
Verified live on 1.18.21: a round, a correction with `-c`, a timeout that killed an
executor `sleep`, and a read of `.env` denied by the new rule. A timeout on 1.x
first left the executor's `sleep` running, because it had moved out of the process
group. The watchdog now signals the whole descendant tree, verified on both majors.

**Observed while implementing:**
- Three of about six private-server runs stalled right after an `opencode reload`, with no output, and the runs that followed a pause finished normally. This was not reproduced without a reload. Do not reload the shared service just before a delegation.
- A reload makes the service list zero agents for a few seconds.
- A project-level `.opencode/agent/` file is not loaded by a standalone server. Only the global agent directory was tested.
- A `Transport: The socket connection was closed unexpectedly` error appeared when a timeout killed the server. Dispatch reports it as exit 20.

**Investigated:** 2026-10-14, against `opencode v2.0.27` (`~/.opencode/bin/opencode`).
**Baseline:** delegate `main` at `578747d`, written for OpenCode 1.18.x.

## Summary

`delegate` does not work with OpenCode 2 today. It fails before the executor
runs, so no code is ever written. The first failure is in `dispatch.sh`'s
preflight, which calls a subcommand that no longer exists. Behind it sit three
more changes that would break the work even after that is fixed. One of them
is silent and dangerous: the executor can end up on a different model from the
one it is pinned to.

| # | Finding | Severity | Visible as |
|---|---|---|---|
| 1 | `opencode agent list` was removed | Blocks every run | exit 14 from `dispatch.sh`, after an `opencode` error |
| 2 | `run` ignores the agent file's `model:` pin unless `-m` is passed | **Silent wrong model** | executor runs on `gemini-4-argon`, or fails with "Reconnect OpenCode Console" |
| 3 | `run` defaults to a background service, so the timeout kill does not reach the executor | Breaks the timeout guarantee | Unverified in a live run; structurally confirmed |
| 4 | Agent config is cached by the service and needs `opencode reload` | Stale or missing agents | `debug agents` returns `[]` until reload |
| 5 | `-f` changed from an array to a single value | Harmless in production; the test stub models a bug that no longer exists | Test suite gives false confidence |
| 6 | Permissions are a list keyed by `shell` / `subagent` rather than `bash` / `task` | Translated by the loader; git denies survive | Verified in `debug agents` output |
| 7 | Two OpenCode installs on this machine | Risk of picking the wrong binary | `~/.opencode/bin` (v2) precedes `/usr/local/bin` (v1) on PATH |
| 8 | Sessions are per project directory; `-c` continues the last one | Risk of resuming the wrong session | Not tested yet (see Open questions) |

## Evidence

Each claim below was checked by running the binary. Where it was not, it is
marked **unverified**.

### 1. `agent list` is gone

```
$ opencode agent list
ERROR
  Unexpected positional argument: "list"
(exit 1)
```

`dispatch.sh` line ~91 runs `opencode agent list >"$AGENTS_TMP"` and greps for
`^executor`. With the command failing, the grep always misses, so every
dispatch returns exit 14 ("opencode does not resolve the 'executor' agent").
The advisor is then told to run `install.sh`, which fails in the same way.

`install.sh` has the same dependency, so the advice it gives is wrong too.

The v2 equivalent is `opencode debug agents`, which prints JSON:

```json
[ { "id": "executor", "mode": "primary", "model": {...}, "permissions": [...], ... } ]
```

The text format (`^executor`) is gone, so the new check has to parse `"id"`.

### 2. The agent's `model:` pin is ignored by `run`

Pinned in `agent/executor.md`: `model: opencode-go/deepseek-v4.1-flash`.
`debug agents` reports the executor with `model: {id: deepseek-v4.1-flash,
providerID: opencode-go}`, so the loader reads it.

But `run` does not use it:

| Command | Model used |
|---|---|
| `run --agent executor -f brief.md -- "msg"` (service) | `gemini-4-argon` → "Reconnect OpenCode Console to continue." |
| `run --standalone --agent executor -f brief.md -- "msg"` | `gemini-4-argon` → same error |
| `run --standalone --agent executor -m opencode-go/deepseek-v4.1-flash ...` | `deepseek-v4.1-flash` → works |

This is the most dangerous finding. Dispatch currently passes `-m` only when
`--model` is given, so a default run would send the work to a different model
from the one the advisor reviewed against. That is exactly the kind of silent
substitution that makes a review meaningless. It only fails today because the
other model needs a Console reconnect; a model that works would quietly
succeed.

### 3. `run` defaults to the background service

`opencode run --help`:

> `--standalone`  Run with a private server instead of the background service

A background server is already running as a long-lived daemon
(`opencode serve --service`, up for more than a day). A plain `run` is a client
of that daemon, and the executor does its work inside the daemon, not inside
the CLI process.

That breaks the design of `dispatch.sh`. The watchdog signals the CLI's
process group on timeout (`kill -TERM -$CMD_PID`). If the work is in the
daemon, the timeout kills the client and the executor carries on, still
editing the repository the advisor is about to review.

**Unverified:** I have not yet run a long task and watched it survive a kill.
That needs a real model call. The structural evidence is the help text and the
existing daemon process.

### 4. Agent config is cached until `reload`

Created `.opencode/agent/singular.md` and `.opencode/agents/plural.md` in a
scratch project. `debug agents` returned `[]` (not even the built-in agents).
After `opencode reload`, it returned ten agents: built-ins, the executor (from
the global symlink), and both probes. So both `agent/` and `agents/` directory
names load.

Consequence: a preflight that trusts the running service can read a stale
config. Dispatch should reload before it checks.

`--standalone` is not accepted by `debug agents` or `debug config`. It is
accepted by `run`, `models`, and `reload`.

### 5. `-f` is no longer an array

v2 help: `--file, -f string  File to attach to the message` (single value).
v1: `-f, --file ... [array]`.

The `--` terminator that dispatch uses still parses correctly in v2, so the
production invocation is fine. But `tests/stub-opencode` reproduces the v1
array behaviour and rejects any positional after `-f`. Against v2 that test
stub models a constraint that no longer exists, and it would reject a valid
invocation pattern. The stub has to follow the version it stands in for.

### 6. Permission schema changed; git denies survived

`debug agents` shows the executor's rules after loading:

- `bash` was renamed to `shell`. The git denies came across:
  `shell git commit* deny`, and the same for reset, checkout, restore, switch,
  stash, clean, push, rebase, merge.
- `task` became `subagent` (`deny`), and `browser` was added as a deny.
- The loader prepended defaults, including `read *.env ask` and
  `read *.env.* ask`, ahead of our allows.

So the frontmatter in `executor.md` still loads, and the git protections are
present. Two things are not confirmed:

- **Rule ordering.** The shell `allow *` appears before the denies. Our denies
  only win if the last matching rule wins. The v1 file relied on the same
  ordering, but v2's rule evaluation is unverified.
- **`ask` without a TTY.** The inherited `read *.env ask` rules would prompt in
  an interactive session. Under `run` with no terminal, nothing answers, so the
  run could hang until the timeout. **Unverified.**

`--auto` would auto-approve every `ask`, but its help text warns it is
"dangerous". I would not rely on it.

### 7. Two installs

```
~/.opencode/bin/opencode   v2.0.27   (first on PATH)
/usr/local/bin/opencode    v1.18.21  (npm, opencode-ai)
```

`dispatch.sh` calls `opencode` from PATH, so it gets v2. The v1 binary still
resolves the executor, so it is usable as a fallback. Its `agent list` output
is long enough that the executor line appears at line 39,637, which is the
reason the old preflight had to avoid pipes.

### 8. Sessions are per project; `-c` is "last session"

`session list` in two directories returned different sessions. So `-c` is scoped
to the project, which makes it safe between correction rounds of a delegation,
but only if nothing else touched that project's sessions. If the user opened
OpenCode interactively in the same repository, `-c` would continue their session
instead of the executor's.

**Unverified:** whether `--format json` output includes the session ID, which
would let dispatch use `--session <id>` instead.

### Other differences (noted, not blocking)

- `models` lists different sets in service and standalone mode. The pinned
  `opencode-go/deepseek-v4.1-flash` exists in both.
- The model failure exit code is 1. Dispatch maps any nonzero to 20, which is
  still correct.
- `run --format` accepts `default` or `json`. Dispatch does not pass it, so the
  log format is not affected yet.

## Proposed plan

Target OpenCode 2 only. Keep v1 out of the code path: one binary, one set of
assumptions. Make the binary explicit so a v1 fallback is a one-line override
rather than a second code path.

### Phase 0: pin the binary

- `dispatch.sh`, `install.sh`, and `rollback.sh` use `OPENCODE_BIN`, defaulting
  to `opencode`. The default resolves to v2 on this machine.
- dispatch verifies the major version. `opencode --version` prints
  `opencode v2.0.27`, so the match is `^opencode v2\.`, not `^2\.`. A mismatch
  refuses with a clear message (new exit code, added to SKILL.md's table).

### Phase 1: preflight

- Replace `opencode agent list` with a check that queries the same server the
  run will use. The run uses a private `--standalone` server, so the preflight
  must not query the shared service. The endpoint for that is unverified; it
  must be settled before this phase is implemented.
- Do **not** run `opencode reload` on every dispatch. It touches the shared
  service, which the user's interactive sessions also use.
- A failed probe gets its own message and exit code, separate from "executor
  not listed". Stop discarding its stderr and exit status.
- Match the executor by exact `id`, and check its source. A project-level agent
  with the same name must not satisfy the check.
- Update `install.sh` to use the same check. It also calls `agent list`, at
  line 16.

### Phase 2: model comes from the lookup table

- Implemented ahead of the v2 work: `config/models.tsv` maps names to ids, and
  `bin/resolve-model.sh` looks them up. Default `deepseek-flash`. Dispatch
  passes `-m` on every run, and refuses (exit 17) if the name does not resolve or
  `opencode models --standalone` does not list the id.
- `agent/executor.md`'s `model:` must equal the default. A test enforces it.
  The frontmatter is kept for the agent's own listing, not for dispatch.

### Phase 3: run standalone

- Pass `--standalone` to `run`, so the CLI owns the executor and the existing
  process-group timeout applies.
- Verify before relying on it. "Descendant of the CLI PID" is the wrong test: a
  process that calls `setsid`, for example through a PTY, leaves the process
  group and survives `kill -TERM -$PGID`. Check the process group and session of
  every descendant. Then confirm the process tree stops changing after the kill.
  Alternatively, have the watchdog kill the whole descendant tree.
- Also check that a killed run leaves no session lock (`~/.local/state/opencode`)
  that would block the next `--session` round.

### Phase 4: permissions

- Correction from the cross-check: `read: allow` is already in `executor.md`,
  and whether the inherited `*.env ask` matters depends on rule order. Under
  last-match, our `read *` allow overrides it, and `.env` files are readable
  today. Under first-match, rule #1 (`* * allow`) cancels every deny.
- So: settle the evaluation order first (open question below). Then, if `.env`
  must be denied, turn `read: allow` into an ordered map with `"*"` first and
  the `.env` denies after it. Whether `*` matches `/` (for example
  `config/.env`) is unverified.
- Do **not** use `--auto`. Its help text says only "Auto-approve permissions
  that are not explicitly denied". The word "dangerous" is in v1's help, not v2's.
- Verify ordering: one live run in which the executor is asked to run
  `git commit`, and the denial is observed. The ref tripwire (exit 21) remains
  the backstop.

### Phase 5: continuation

- Dispatch generates the session ID on round 1 and stores it in
  `.advisor/runs/<stem>-session`. Correction rounds pass `--session <that id>`.
  This avoids `--format json`, which would turn the log into JSON and break the
  advisor's `BRIEF PROBLEM:` check.
- `--continue` with no stored ID refuses (exit code) and never falls back to
  `-c`. A fresh round after rollback replaces the stored ID.
- Whether `--session` accepts an arbitrary ID is unverified. It needs a
  private-server run to confirm.

### Phase 6: tests

The stub has to mirror v2, not v1.

- `tests/stub-opencode`:
  - `debug agents` prints JSON with the executor's `"id"`.
  - `agent list` exits 1 with v2's message, so any regression to it fails loudly.
  - `-f` takes one value. The array-swallow emulation is removed.
  - `reload` is accepted and logged, so tests can assert it ran before the check.
- New assertions:
  - Preflight never invokes `agent list`.
  - Without `--model`, the argv contains `-m` with the frontmatter's model.
  - Missing `model:` in the agent file refuses.
  - `--standalone` is present in the argv.
  - The executor frontmatter denies `*.env`.
- Write the stub and its tests first, so every phase starts from a suite that
  runs. The stub must handle `--version` and `debug agents`.
- Keep the existing ref-tripwire and rollback tests. They do not depend on the
  OpenCode version. `rollback.sh` never calls opencode, so leave it alone.
- Docs that must change with the code: the README's mermaid line that shows
  `opencode run --agent executor -f brief`, the README install section, SKILL.md's
  exit-14 advice, and KNOWN-LIMITATIONS' wording on how deny patterns match.
- Remove the README's "tested with 1.18.32" and update the install section.

### Phase 7: live acceptance

One real delegation in a scratch repository, with a deliberately tiny brief,
run through the full loop: dispatch, review, one correction using the captured
session, ACCEPT. Then one timeout run, checking that no executor process
survives. Then re-run the betpawa brief from the original delegation as a
regression check if you want it.

## Decisions for review

1. **v2 only, or keep v1 working too?** Recommended: v2 only, with `OPENCODE_BIN`
   as the escape hatch. Supporting both doubles the code paths and the tests.
2. **Frontmatter as the single model source?** Recommended: yes. Dispatch
   refuses if it is absent.
3. **Deny `*.env` reads, or allow them?** Recommended: deny. The executor has no
   need for secrets.
4. **Standalone for every run?** Recommended: yes. It costs a private server
   per run, which is slower to start, in exchange for a timeout that actually
   holds.
5. **Commit this plan?** It is uncommitted at `docs/opencode-2-compatibility.md`.
   I would commit it on a branch with the Phase 0-6 work, not on `main`.

## Open questions

- Does `run --format json` include the session ID? (Phase 5 depends on it.)
- Does `ask` hang a non-interactive run, and does it hit the timeout or fail
  fast? (Phase 4.)
- Does the deny rule win over the earlier `shell *` allow in v2? (Phase 4.)
- Does a process-group kill reach a `--standalone` executor's children? (Phase 3.)

## What I ran during the investigation

Being explicit, since some of this touched shared state:

- **Real model requests:** two. Both used the pinned `deepseek-v4.1-flash`
  model with a trivial prompt, and both succeeded. The executor also read some
  files in a scratch directory during one of them. These consumed a small
  amount of your subscription.
- **Ran `opencode reload`** on the shared background service. This only
  rereads configuration, but it affects every v2 session on this machine.
- **Created sessions** in the scratch project
  (`scratchpad/probe`). They are visible in `opencode session list` for that
  directory. They can be removed with `opencode session delete`. I left them in
  place.
- **Repository:** nothing in `~/.claude/skills/delegate` was modified except
  this file.

## Cross-check (2026-10-14)

An independent Opus 5.5 subagent re-verified the evidence and reviewed the
phases. Verdict: **approve with changes.** Corrections accepted into this document:

**Errors in my plan, now fixed above:**
- The Phase 0 version gate would have refused every run (`^2\.` does not match
  `opencode v2.0.27`).
- The Phase 1 and Phase 3 checks queried or assumed a different server from
  the one the run uses.
- Phase 4 assumed the rule order without checking it.
- The `--auto` "dangerous" wording came from v1's help, not v2's.
- Phase 5's `--format json` would have broken the `BRIEF PROBLEM:` check.
- The Phase 6 stub and tests came last, which would have left every phase red.

**Corrections to the evidence, with the subagent's basis:**
- The `agent list` call is at `bin/dispatch.sh` line 49, not ~91. `install.sh`
  line 16 has the same call.
- The "reload fixes stale config" explanation is not established. In my probe,
  `debug agents` returned `[]` before a reload, and agents after. The subagent
  reads this as lazy per-directory loading. My test never queried a second
  directory after the first, so I cannot rule that out either. Still open.
- `gemini-4-argon` is not in `opencode.jsonc` or `state/model.json`. The cause
  of the wrong-model substitution is unknown; the finding that it happens is
  supported only by the earlier probe logs.
- `--standalone` is also accepted by `api`, `session list`, and `session export`.

**Missed risks to address:**
- A project's own `.opencode/` directory is loaded as a config source. A target
  repo, or the executor itself, could add `.opencode/agents/executor.md` or an
  `opencode.json` with no git denies and a different model. Preflight should
  refuse such files, or compare the resolved agent's rules and model against
  what is expected.
- `run` may drop more than the model pin at run time (temperature, system
  prompt, permissions). `debug agents` shows only what the loader read. Phase 7
  should check these.
- Live interactive sessions can share `-c` with a delegation in the same repo,
  and they are affected by any reload.
- An unrecognised subcommand is treated as a directory and fails strangely. The
  stub should copy that.

**Unverified, because the subagent was forbidden paid model calls and reloads:**
which model `run` picks, the timeout kill behaviour, rule evaluation, whether
`ask` hangs, the model failure exit code, whether `--session` accepts arbitrary
IDs, and which endpoint `api --standalone` exposes.

**Security note:** the subagent's side note says reading
`~/.local/state/opencode/service.json` printed the service password into its
tool output. That output is in this session's transcript. Consider rotating the
service password. The subagent did not repeat it.

