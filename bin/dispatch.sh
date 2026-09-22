#!/usr/bin/env bash
# dispatch.sh — the single entrypoint the advisor uses to invoke the executor.
# Owns preflight, invocation, logging, and the diff. Contains no judgment.
set -uo pipefail

readonly EXIT_OK=0
readonly EXIT_NO_OPENCODE=10
readonly EXIT_NOT_REPO=11
readonly EXIT_DIRTY=12
readonly EXIT_NO_BRIEF=13
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

# The advisor writes briefs into .advisor/ immediately before dispatch, so those
# files are always untracked at this point and must not count as a dirty tree.
DIRTY="$(git status --porcelain | grep -v '\.advisor/' || true)"
[ -z "$DIRTY" ] \
  || die $EXIT_DIRTY "working tree is dirty. Commit or stash first so the post-run diff is trustworthy."

[ -r "$BRIEF" ] \
  || die $EXIT_NO_BRIEF "brief not readable: ${BRIEF:-<none>}"

BRIEF_STEM="$(basename "$BRIEF" .md)"
RUNDIR="$(git rev-parse --show-toplevel)/.advisor/runs"
mkdir -p "$RUNDIR"
LOG="$RUNDIR/${BRIEF_STEM}-r${ROUND}.log"

ARGS=(run --agent executor)
[ "$CONTINUE" -eq 1 ] && ARGS+=(-c)
[ -n "$MODEL" ] && ARGS+=(-m "$MODEL")
ARGS+=(-f "$BRIEF" "Implement the attached brief. Follow it exactly.")

echo "dispatch: round $ROUND -> opencode ${ARGS[*]}"
echo "dispatch: log -> $LOG"

# macOS ships no timeout(1), so run the command in the background and let a
# watchdog subshell kill it. A TERM-killed child reports 143.
opencode "${ARGS[@]}" >"$LOG" 2>&1 &
CMD_PID=$!
( sleep "$TIMEOUT"; kill -TERM "$CMD_PID" 2>/dev/null ) &
WATCHDOG_PID=$!

wait "$CMD_PID"; RC=$?
kill -9 "$WATCHDOG_PID" 2>/dev/null

if [ "$RC" -eq 143 ]; then
  echo "dispatch: timed out after ${TIMEOUT}s" >&2
  exit $EXIT_TIMEOUT
fi

if [ "$RC" -ne 0 ]; then
  echo "dispatch: opencode exited $RC — see $LOG" >&2
  exit $EXIT_EXECUTOR
fi

echo
echo "=== diff --stat ==="
git --no-pager diff --stat
echo "=== end ==="
exit $EXIT_OK
