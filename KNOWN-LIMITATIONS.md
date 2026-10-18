# Known limitations

What the toolkit still cannot do, after the fixes of 2026-09-25. None blocks
supervised single-task use.

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
  can.

Treat the denies and the tripwire as protection against an unhelpful executor,
not a hostile one.

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

## Secrets are readable through the shell

`agent/executor.md` denies the `read` tool on `.env` files, which the
default rules would otherwise have asked about. The `bash` allow is
prefix-matched, so `cat .env` still works. Nested paths such as
`config/.env` are also unverified against the `read` denies. Keep secrets
out of the working tree, or accept that the executor can see them.

## Transport failures surface as exit 20

If the model connection drops mid-run, OpenCode reports
`Transport: The socket connection was closed unexpectedly` and dispatch
exits 20. Nothing retries the round. The log keeps the error.

## OpenCode 1.x limits

On 1.x the executor runs in the same process as the CLI, and the continuation
resumes the last session in the directory (`-c`), not a stored session id. So:

- A correction round continues whatever session is newest in this directory.
  Anything else run in this repository between rounds is the one continued.
- Rollback cannot forget a 1.x session, so a `--continue` after rollback
  resumes the work that was undone. Re-brief with a fresh round instead.
- A timeout kills the executor's process tree, including children that left
  the process group. A child that has already reparented to launchd before
  the timeout is not in the tree, and it can survive.

## Shared OpenCode database

1.x and 2.x share one database. On the machine this was tested on, one
repository had two project rows: its root commit had been rewritten, so the
project id changed. There, `opencode agent list` under 1.x failed with
`no such column: project_id`, and the skill refused with that error. Other
repositories were unaffected. Removing the stale row changes the shared
database, so do that deliberately.
