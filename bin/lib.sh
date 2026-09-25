# lib.sh — state shared by dispatch.sh and rollback.sh. Sourced, never run.
# shellcheck shell=bash

readonly EXIT_OK=0
readonly EXIT_NO_OPENCODE=10
readonly EXIT_NOT_REPO=11
readonly EXIT_DIRTY=12
readonly EXIT_NO_BRIEF=13
readonly EXIT_NO_AGENT=14
readonly EXIT_NO_BASE=15
readonly EXIT_NO_COMMITS=16
readonly EXIT_EXECUTOR=20
readonly EXIT_GIT_MUTATED=21
readonly EXIT_TIMEOUT=24

die() { echo "${0##*/}: $2" >&2; exit "$1"; }
usage_error() { echo "${0##*/}: $1" >&2; exit 2; }

# Every untracked, non-ignored file in the repository as "<blob-hash> <path>",
# paths relative to the top level. Comparing two of these is how a round's
# new, changed and deleted untracked files are told apart from ones that were
# already there -- including the advisor's own briefs under .advisor/.
snapshot_untracked() { # snapshot_untracked <toplevel>
  ( cd "$1" || exit
    git ls-files --others --exclude-standard -z \
      | while IFS= read -r -d '' f; do
          printf '%s %s\n' "$(git hash-object -- "$f")" "$f"
        done | sort -k2 )
}

# Everything an executor could move to rewrite history or hide work: where
# HEAD points, what it resolves to, and every ref including the stash and
# remote-tracking refs (a successful push updates those locally).
snapshot_refs() {
  git symbolic-ref -q HEAD || echo "HEAD detached"
  git rev-parse -q --verify HEAD || echo "HEAD unborn"
  git for-each-ref --format='%(refname) %(objectname)'
}

# The ledger of files the executor created during one delegation, one path
# per line, relative to the top level.
created_ledger() { printf '%s/%s-created' "$1" "$2"; }   # <rundir> <stem>
touched_ledger() { printf '%s/%s-touched' "$1" "$2"; }   # <rundir> <stem>
