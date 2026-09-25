#!/usr/bin/env bash
# rollback.sh — undoes a delegation back to the baseline dispatch.sh recorded:
# tracked files are restored to the base commit, and files the executor created
# are deleted. Deletes nothing it cannot attribute to the executor.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BRIEF=""
while [ $# -gt 0 ]; do
  case "$1" in
    --brief)    BRIEF="$2"; shift 2 ;;
    *) usage_error "unknown argument: $1" ;;
  esac
done
[ -n "$BRIEF" ] || usage_error "--brief is required: it names the delegation to roll back"

git rev-parse --git-dir >/dev/null 2>&1 \
  || die $EXIT_NOT_REPO "not inside a git repository."

BRIEF_STEM="$(basename "$BRIEF" .md)"
TOP="$(git rev-parse --show-toplevel)"
RUNDIR="$TOP/.advisor/runs"
BASEFILE="$RUNDIR/${BRIEF_STEM}-base"
CREATED="$(created_ledger "$RUNDIR" "$BRIEF_STEM")"
TOUCHED="$(touched_ledger "$RUNDIR" "$BRIEF_STEM")"

[ -r "$BASEFILE" ] || die $EXIT_NO_BASE \
  "no recorded baseline for '$BRIEF_STEM', so there is nothing to roll back to."
BASE="$(git rev-parse -q --verify "$(cat "$BASEFILE")^{commit}")"
[ -n "$BASE" ] || die $EXIT_NO_BASE \
  "recorded baseline in $BASEFILE does not resolve to a commit."

# With HEAD elsewhere, restoring the tree to the base would silently stage a
# revert of every commit since. Whoever moved HEAD has to decide that.
HEAD_NOW="$(git rev-parse -q --verify HEAD)"
[ "$HEAD_NOW" = "$BASE" ] || die $EXIT_GIT_MUTATED \
  "HEAD is ${HEAD_NOW:0:7} but this delegation started at ${BASE:0:7}. Nothing was changed; ask the user how to proceed."

# Tracked paths only: both index and working tree back to the base, which also
# drops any new file the executor staged. Untracked files are untouched here.
git restore --source="$BASE" --staged --worktree -- :/

# A ledger entry is deleted only if git reports that exact path as untracked
# right now. That bounds this loop to untracked files inside this repository,
# whatever the ledger says -- it sits in a directory the executor can write.
UNTRACKED="$(mktemp)"
trap 'rm -f "$UNTRACKED"' EXIT
( cd "$TOP" && git ls-files --others --exclude-standard -z ) | tr '\0' '\n' > "$UNTRACKED"
[ -r "$CREATED" ] || : > "$CREATED"
while IFS= read -r p; do
  grep -qxF -- "$p" "$UNTRACKED" || continue
  rm -f -- "$TOP/$p"
  echo "rollback: deleted $p"
  # Remove the directories the file needed, stopping at the first that still
  # holds something.
  d="$(dirname -- "$p")"
  while [ "$d" != "." ] && rmdir -- "$TOP/$d" 2>/dev/null; do
    d="$(dirname -- "$d")"
  done
done < "$CREATED"

if [ -s "$TOUCHED" ]; then
  echo "rollback: these untracked files predate the delegation and were changed by the executor." >&2
  echo "rollback: git has no copy of them, so they are left as the executor left them:" >&2
  sed 's/^/  /' "$TOUCHED" >&2
fi

: > "$CREATED"; : > "$TOUCHED"
echo "rollback: tree restored to base ${BASE:0:7}. Remaining changes:"
git status --short
exit $EXIT_OK
