# Known limitations

What the toolkit cannot do. None blocks supervised single-task use.

## The executor is not sandboxed

`agent/executor.md` gives the executor `bash` and `edit` over your repository.
Its git deny patterns match a command's prefix, so `sh -c "git commit ..."` or
`git -C . commit` gets past them. `dispatch.sh` compares every ref before and
after the round and exits 21 if any moved, which catches commits, resets,
branch and tag changes, stashes, and pushes to a configured remote (a push
updates the local remote-tracking ref).

That check is detection, after the fact. It cannot see:

- a push to a URL with no remote-tracking ref, such as `git push https://...`;
- anything outside git — the executor can delete or rewrite any file its user
  can, and reach the network through the shell.

Treat the denies and the tripwire as protection against an unhelpful executor,
not a hostile one. Do not delegate in a repository, or as a user, whose
reach you would not hand to the executor's model.

## Secrets: what the .env protection covers

On macOS, dispatch runs the executor inside `sandbox-exec`, which denies
reading or writing any `.env` or `.env.*` file (`.env.example` excepted) to
the executor and every process it starts. The kernel enforces it, so
`cat`, scripts, symlinks, copies, renames and hard links all fail. The
`read` tool is denied the same files in `agent/executor.md`.

It does not cover:

- **Other platforms.** Without `sandbox-exec` (Linux), or when dispatch
  itself runs inside a sandbox (they do not nest), the run goes ahead
  unprotected and dispatch prints `secrets -> NOT protected`. Only the
  `read`-tool deny applies there, and the shell can still read `.env`.
- **Secrets committed to git.** `git show HEAD:.env` reads from the object
  store, not the file.
- **Secrets in the environment.** The executor inherits dispatch's
  environment, so anything exported in your shell is visible to it.
- **Other secret files**, such as `~/.ssh`, `~/.aws` or `.npmrc`.

Everything the executor reads can end up in `.advisor/runs/` logs and with
the model provider. The executor also cannot create or edit a `.env` under
the sandbox, so a brief that needs one must leave that step to the user.

## Ignored files are invisible to review

The review shows tracked changes (`git diff` against the base) and untracked,
non-ignored files. A file the executor writes to a gitignored path —
`node_modules/`, a build directory, `.env`, `.advisor/runs/` — appears in
neither, and `rollback.sh` does not delete it.

## Rollback cannot restore untracked files that predate the round

If the executor changes or deletes an untracked file that existed before it
started, dispatch reports it under `pre-existing untracked files`, but git
never held a copy, so `rollback.sh` can only warn. Round 1 starts on a clean
tree, so in practice this means the advisor's own untracked brief, or a file
someone added mid-delegation.

## Rollback restores every tracked file to the base

Including tracked edits the user made mid-delegation. That is consistent with
refusing to start a delegation on a dirty tree — mid-edit delegation is not
supported — but rollback does not tell the executor's tracked changes apart
from anyone else's.

## A killed dispatch can only stop what it can see

Dispatch stops the executor when it is interrupted (exit 130) or times out
(exit 24), including children that left the process group. It cannot act on a
`SIGKILL` sent to dispatch itself, and a child that had already been
reparented to init before the stop is not in the tree it walks.

## Transport failures surface as exit 20

If the model connection drops mid-run, OpenCode reports
`Transport: The socket connection was closed unexpectedly` and dispatch
exits 20. Nothing retries the round. The log keeps the error.

## OpenCode 1.x continues the newest session

On 1.x a correction round resumes the last session in the repository (`-c`),
not a recorded session id. Anything else run with OpenCode in this repository
between rounds is the session that gets continued. 2.x pins the id.

## OpenCode 2.x notes

- The agent is read from the global agent directory. A project-level
  `.opencode/agent/executor.md` is not loaded by the private server each run
  uses.
- Runs started right after an `opencode reload` of the shared service were
  seen to stall with no output. Do not reload just before a delegation.
