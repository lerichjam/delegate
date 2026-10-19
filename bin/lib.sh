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
readonly EXIT_NO_MODEL=17
readonly EXIT_WRONG_OPENCODE=18
readonly EXIT_BRIEF_PROBLEM=19
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

# The OpenCode session a delegation runs in, one ses_ id. Round 1 writes it and
# every correction round resumes it with --session, so a correction can never
# attach to whatever session happens to be newest in the project.
session_file() { printf '%s/%s-session' "$1" "$2"; }     # <rundir> <stem>

# ---- OpenCode version differences -------------------------------------------
# Two majors are supported. Everything that differs between them is decided
# here or in dispatch.sh's per-version branch, and nowhere else.
#   1.x  prints a bare "1.18.21"; runs in-process; resumes with -c; agent list works.
#   2.x  prints "opencode v2.0.27"; runs with --standalone; resumes with --session.

# oc_major <binary> -- prints 1 or 2 (or nothing if no version can be read).
oc_major() {
  "$1" --version 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 | cut -d. -f1
}

# oc_models <binary> <major> <outfile> -- the model ids OpenCode offers, one per
# line, colour codes removed. Written to a file: piping this output truncates it.
oc_models() {
  # stderr is kept beside the list ("<outfile>.err") so a refusal can say why
  # the list was empty or short instead of blaming the model name.
  if [ "$2" -eq 1 ]; then
    "$1" models >"$3" 2>"$3.err"
  else
    "$1" models --standalone >"$3" 2>"$3.err"
  fi
  sed -i.bak 's/\x1b\[[0-9;]*m//g; s/\r$//' "$3" && rm -f "$3.bak"
}

# oc_v1_agent_listed <binary> <outfile> -- 1.x only: the executor appears in
# `agent list`. Never piped, for the same truncation reason as oc_models.
oc_v1_agent_listed() {
  "$1" agent list >"$2" 2>&1
  sed -i.bak 's/\x1b\[[0-9;]*m//g' "$2" && rm -f "$2.bak"
  grep -q '^executor' "$2"
}

# descendants <pid> -- every process below <pid>, children before parents. Take
# this BEFORE signalling: once a parent dies, its children are reparented and
# can no longer be found from it. A process-group kill misses a child that has
# moved to its own group, which the executor's shell commands can do.
descendants() {
  local c
  for c in $(pgrep -P "$1" 2>/dev/null); do
    descendants "$c"
    echo "$c"
  done
}

# oc_error_line <file> -- the first error OpenCode printed, if any, so a refusal
# can say why, not only that a check failed.
oc_error_line() { sed 's/\x1b\[[0-9;]*m//g' "$1" 2>/dev/null | grep -v '^[[:space:]]*$' | head -3 | sed 's/^[[:space:]]*//' | paste -sd' ' -; }
