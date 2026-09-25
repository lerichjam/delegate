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
