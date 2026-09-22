#!/usr/bin/env bash
# dispatch.sh — the single entrypoint the advisor uses to invoke the executor.
# Owns preflight, invocation, logging, and the diff. Contains no judgment.
set -uo pipefail

readonly EXIT_OK=0
readonly EXIT_NO_OPENCODE=10
readonly EXIT_NOT_REPO=11
readonly EXIT_DIRTY=12
readonly EXIT_NO_BRIEF=13
readonly EXIT_NO_BASE=15
readonly EXIT_EXECUTOR=20
readonly EXIT_TIMEOUT=24

BRIEF=""; ROUND=1; MODEL=""; TIMEOUT=600; CONTINUE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --brief)    BRIEF="$2"; shift 2 ;;
    --round)    ROUND="$2"; shift 2 ;;
    --model)    MODEL="$2"; shift 2 ;;
    --timeout)  TIMEOUT="$2"; shift 2 ;;
    --continue) CONTINUE=1; shift ;;
    *) echo "dispatch: unknown argument: $1" >&2; exit 2 ;;
  esac
done

die() { echo "dispatch: $2" >&2; exit "$1"; }

command -v opencode >/dev/null 2>&1 \
  || die $EXIT_NO_OPENCODE "opencode not found on PATH. Install it before delegating."

git rev-parse --git-dir >/dev/null 2>&1 \
  || die $EXIT_NOT_REPO "not inside a git repository. Run 'git init' and make a baseline commit first."

[ -r "$BRIEF" ] \
  || die $EXIT_NO_BRIEF "brief not readable: ${BRIEF:-<none>}"

BRIEF_STEM="$(basename "$BRIEF" .md)"
RUNDIR="$(git rev-parse --show-toplevel)/.advisor/runs"
if [ ! -d "$RUNDIR" ]; then
  mkdir -p "$RUNDIR"
fi
# Raw executor logs can contain anything the executor read, including secrets.
# Self-ignoring the directory means an ACCEPT plus `git add -A` cannot sweep
# them into a commit, whatever the repo's own .gitignore says.
[ -f "$RUNDIR/.gitignore" ] || printf '*\n' > "$RUNDIR/.gitignore"

LOG="$RUNDIR/${BRIEF_STEM}-r${ROUND}.log"
BASEFILE="$RUNDIR/${BRIEF_STEM}-base"

# A round after the first is a continuation of a delegation already under way,
# and round 1 necessarily leaves the tree dirty. Trust therefore comes from the
# baseline commit recorded on round 1, not from the tree being clean — which is
# strictly stronger, since the diff is pinned to a known commit either way.
IS_CONT=0
[ "$CONTINUE" -eq 1 ] && IS_CONT=1
[ "$ROUND" -gt 1 ] && IS_CONT=1

if [ "$IS_CONT" -eq 0 ]; then
  # Starting a delegation on a dirty tree is refused unconditionally.
  # The advisor writes briefs into .advisor/ immediately before dispatch, so
  # those files are always untracked here and must not count as dirty.
  DIRTY="$(git status --porcelain | grep -v '\.advisor/' || true)"
  [ -z "$DIRTY" ] \
    || die $EXIT_DIRTY "working tree is dirty. Commit or stash first so the post-run diff is trustworthy."
  BASE="$(git rev-parse HEAD 2>/dev/null)"
  [ -n "$BASE" ] \
    || die $EXIT_NOT_REPO "repository has no commits. Make a baseline commit first."
  printf '%s\n' "$BASE" > "$BASEFILE"
else
  [ -r "$BASEFILE" ] || die $EXIT_NO_BASE \
    "no recorded baseline for '$BRIEF_STEM'. Start this delegation at round 1 (no --continue) so the baseline commit is recorded."
  BASE="$(cat "$BASEFILE")"
  BASE="$(git rev-parse --verify --quiet "${BASE}^{commit}" 2>/dev/null)"
  [ -n "$BASE" ] || die $EXIT_NO_BASE \
    "recorded baseline in $BASEFILE does not resolve to a commit. Start this delegation at round 1 (no --continue)."
fi

ARGS=(run --agent executor)
[ "$CONTINUE" -eq 1 ] && ARGS+=(-c)
[ -n "$MODEL" ] && ARGS+=(-m "$MODEL")
ARGS+=(-f "$BRIEF" -- "Implement the attached brief. Follow it exactly.")

echo "dispatch: round $ROUND -> opencode ${ARGS[*]}"
echo "dispatch: base -> $(git rev-parse --short "$BASE")"
echo "dispatch: log -> $LOG"

# macOS ships no timeout(1), so run the command in the background and let a
# watchdog subshell kill it. A TERM-killed child reports 143.
opencode "${ARGS[@]}" >"$LOG" 2>&1 &
CMD_PID=$!
( sleep "$TIMEOUT"; kill -TERM "$CMD_PID" 2>/dev/null ) >/dev/null 2>&1 &
WATCHDOG_PID=$!

wait "$CMD_PID"; RC=$?
pkill -P "$WATCHDOG_PID" >/dev/null 2>&1
kill -TERM "$WATCHDOG_PID" 2>/dev/null
wait "$WATCHDOG_PID" 2>/dev/null

if [ "$RC" -eq 143 ]; then
  echo "dispatch: timed out after ${TIMEOUT}s" >&2
  exit $EXIT_TIMEOUT
fi

if [ "$RC" -ne 0 ]; then
  echo "dispatch: opencode exited $RC — see $LOG" >&2
  exit $EXIT_EXECUTOR
fi

echo
echo "=== diff --stat (against base $(git rev-parse --short "$BASE")) ==="
git --no-pager diff --stat "$BASE"
echo "=== end ==="
exit $EXIT_OK
