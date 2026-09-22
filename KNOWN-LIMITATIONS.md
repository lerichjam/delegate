# Known limitations

Residual findings from the final review of 2026-09-22, left unfixed deliberately.
Each is real and reproducible. None blocks supervised single-task use.

## ROLLBACK can delete unrelated untracked files

`SKILL.md`'s ROLLBACK verdict runs `git checkout -- . && git clean -fd -e .advisor`.
`git clean -fd` deletes every untracked file outside `.advisor/`.

On round 1 this is safe: preflight refuses to start on a dirty tree, and its
dirty check counts untracked files, so none can exist beforehand. Continuation
rounds skip that check by design (that is what makes the CORRECT verdict
reachable). So any untracked file you drop into the tree between rounds — a
scratch note, a build artifact not yet gitignored — is deleted by a later
ROLLBACK.

This is new destructive behavior. The pre-fix ROLLBACK never removed untracked
files, but it also left the executor's stray files behind to contaminate the
re-brief, which was Critical finding C2.

**Do not keep unsaved scratch files in a repo mid-delegation.**

## The executor's git restrictions are a speed bump, not a sandbox

`agent/executor.md` denies `git commit`, `reset`, `checkout`, `stash`, `clean`,
`push`, `rebase` and `merge`, because an executor that mutates git state can
empty the diff the advisor is about to review.

Two gaps:

- `git restore` is not denied. It is the modern equivalent of
  `git checkout -- <file>` and does exactly what these denies exist to prevent.
- The patterns are prefix-anchored, so chaining or wrapping evades them:
  `echo x && git commit ...`, `sh -c "git commit ..."`, `git -C . commit`, or an
  inserted global flag. This is a structural limit of pattern-based permission
  denial, not something more patterns fix.

The executor runs with `bash` and `edit` against your repository. Treat these
denies as protection against an unhelpful executor, not a hostile one.

## Files under `.advisor/` are invisible to review

`dispatch.sh` excludes `.advisor/` from its untracked listing, so a file the
executor writes there appears in neither `git diff` nor the untracked section —
the blind spot C2 fixed, relocated to one directory. Nothing points an executor
there, so this is unlikely rather than impossible.

## `--round N` above 1 without `--continue`

`--round 2` alone skips the dirty check and reuses the recorded base, but
`opencode` only receives `-c` when `--continue` is passed, so the executor loses
its session context. Harmless in practice because the full brief is reattached
every round, but the flags are not independent the way they look.

## Exit code 11 covers two conditions

`EXIT_NOT_REPO` means both "not inside a git repository" and "repository has no
commits". Distinguishing them was not judged worth another exit code.
