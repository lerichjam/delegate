#!/usr/bin/env bash
# dispatch.sh — the single entrypoint the advisor uses to invoke the executor.
# Owns preflight, invocation, logging, and the diff. Contains no judgment.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BRIEF=""; ROUND=1; MODEL=""; TIMEOUT=600; CONTINUE=0
# A correction round re-attaches the whole brief, so without a message saying
# otherwise the executor is told to implement all of it again.
MESSAGE="Implement the attached brief. Follow it exactly."

while [ $# -gt 0 ]; do
  case "$1" in
    --brief)    BRIEF="$2"; shift 2 ;;
    --round)    ROUND="$2"; shift 2 ;;
    --model)    MODEL="$2"; shift 2 ;;
    --timeout)  TIMEOUT="$2"; shift 2 ;;
    --message)  MESSAGE="$2"; shift 2 ;;
    --continue) CONTINUE=1; shift ;;
    *) usage_error "unknown argument: $1" ;;
  esac
done

case "$ROUND" in
  ''|*[!0-9]*|0) usage_error "--round takes a positive integer, got '$ROUND'" ;;
esac
# --round only labels the log. --continue is what makes a round a
# continuation, and there is nothing to continue before round 2.
if [ "$CONTINUE" -eq 1 ] && [ "$ROUND" -eq 1 ]; then
  usage_error "--continue resumes an earlier round, so it needs --round 2 or higher"
fi

command -v opencode >/dev/null 2>&1 \
  || die $EXIT_NO_OPENCODE "opencode not found on PATH. Install it before delegating."

git rev-parse --git-dir >/dev/null 2>&1 \
  || die $EXIT_NOT_REPO "not inside a git repository. Run 'git init' and make a baseline commit first."

[ -r "$BRIEF" ] \
  || die $EXIT_NO_BRIEF "brief not readable: ${BRIEF:-<none>}"

# opencode exits nonzero for an unresolved agent exactly as it does for a
# failed task, so an unrun install.sh would otherwise arrive as EXIT_EXECUTOR
# -- "the executor ran and failed" -- when no model call ever happened.
# Never pipe `opencode agent list`: it emits ~1.4 MB and truncates at exactly
# 1 MiB through a pipe, which previously made a `| grep` check false-negative.
AGENTS_TMP="$(mktemp)"
opencode agent list >"$AGENTS_TMP" 2>/dev/null
if ! grep -q '^executor' "$AGENTS_TMP"; then
  rm -f "$AGENTS_TMP"
  die $EXIT_NO_AGENT "opencode does not resolve the 'executor' agent. Run ~/.claude/skills/delegate/install.sh, then retry."
fi
rm -f "$AGENTS_TMP"

BRIEF_STEM="$(basename "$BRIEF" .md)"
TOP="$(git rev-parse --show-toplevel)"
RUNDIR="$TOP/.advisor/runs"
if [ ! -d "$RUNDIR" ]; then
  mkdir -p "$RUNDIR"
fi
# Raw executor logs can contain anything the executor read, including secrets.
# Self-ignoring the directory means an ACCEPT plus `git add -A` cannot sweep
# them into a commit, whatever the repo's own .gitignore says.
[ -f "$RUNDIR/.gitignore" ] || printf '*\n' > "$RUNDIR/.gitignore"

LOG="$RUNDIR/${BRIEF_STEM}-r${ROUND}.log"
BASEFILE="$RUNDIR/${BRIEF_STEM}-base"

CREATED="$(created_ledger "$RUNDIR" "$BRIEF_STEM")"
TOUCHED="$(touched_ledger "$RUNDIR" "$BRIEF_STEM")"

# A continuation runs on the tree its earlier rounds necessarily dirtied, so
# its trust comes from the baseline commit recorded when the delegation
# started, not from the tree being clean -- strictly stronger, since the diff
# is pinned to a known commit either way.
if [ "$CONTINUE" -eq 0 ]; then
  BASE="$(git rev-parse -q --verify HEAD)"
  [ -n "$BASE" ] \
    || die $EXIT_NO_COMMITS "repository has no commits. Make a baseline commit first."
  # Starting a delegation on a dirty tree is refused unconditionally.
  # The advisor writes briefs into .advisor/ immediately before dispatch, so
  # those files are always untracked here and must not count as dirty.
  DIRTY="$(git status --porcelain | grep -v '\.advisor/' || true)"
  [ -z "$DIRTY" ] \
    || die $EXIT_DIRTY "working tree is dirty. Commit or stash first so the post-run diff is trustworthy."
  printf '%s\n' "$BASE" > "$BASEFILE"
  : > "$CREATED"; : > "$TOUCHED"
else
  [ -r "$BASEFILE" ] || die $EXIT_NO_BASE \
    "no recorded baseline for '$BRIEF_STEM'. Start this delegation without --continue so the baseline commit is recorded."
  BASE="$(git rev-parse -q --verify "$(cat "$BASEFILE")^{commit}")"
  [ -n "$BASE" ] || die $EXIT_NO_BASE \
    "recorded baseline in $BASEFILE does not resolve to a commit. Start this delegation without --continue."
  touch "$CREATED" "$TOUCHED"
fi

ARGS=(run --agent executor)
[ "$CONTINUE" -eq 1 ] && ARGS+=(-c)
[ -n "$MODEL" ] && ARGS+=(-m "$MODEL")
ARGS+=(-f "$BRIEF" -- "$MESSAGE")

echo "dispatch: round $ROUND -> opencode ${ARGS[*]}"
echo "dispatch: base -> $(git rev-parse --short "$BASE")"
echo "dispatch: log -> $LOG"

BEFORE_FILES="$(mktemp)"; AFTER_FILES="$(mktemp)"; BEFORE_REFS="$(mktemp)"; AFTER_REFS="$(mktemp)"
trap 'rm -f "$BEFORE_FILES" "$AFTER_FILES" "$BEFORE_REFS" "$AFTER_REFS"' EXIT
snapshot_untracked "$TOP" > "$BEFORE_FILES"
snapshot_refs > "$BEFORE_REFS"

# macOS ships no timeout(1), so run the command in the background and let a
# watchdog subshell kill it. A TERM-killed child reports 143.
#
# `set -m` puts opencode in its own process group so the watchdog can signal
# the group, not just opencode itself: the executor spawns children that hold
# the same edit and bash permissions, and signalling the leader alone leaves
# them orphaned but still writing to the repository the advisor is about to
# review. stdin comes from /dev/null so a job-controlled background process
# can never be stopped by SIGTTIN.
set -m
opencode "${ARGS[@]}" >"$LOG" 2>&1 </dev/null &
CMD_PID=$!
set +m
( sleep "$TIMEOUT" && {
    kill -TERM -"$CMD_PID" 2>/dev/null
    sleep 3
    kill -KILL -"$CMD_PID" 2>/dev/null
  } ) >/dev/null 2>&1 &
WATCHDOG_PID=$!

wait "$CMD_PID"; RC=$?
pkill -P "$WATCHDOG_PID" >/dev/null 2>&1
kill -TERM "$WATCHDOG_PID" 2>/dev/null
wait "$WATCHDOG_PID" 2>/dev/null

if [ "$RC" -eq 143 ]; then
  # Reaping the leader does not dissolve the group: sweep whatever ignored
  # the TERM, so nothing survives this script to keep editing the tree.
  kill -KILL -"$CMD_PID" 2>/dev/null
fi

# Attribute this round's untracked-file changes before anything else can
# exit: even a failed or timed-out round may have created files, and
# rollback.sh deletes only what this ledger names. A path the executor
# created in an earlier round is its own work in progress, not a
# pre-existing file it touched.
snapshot_untracked "$TOP" > "$AFTER_FILES"
awk -v created="$CREATED" -v touched="$TOUCHED" '
  FILENAME == created { mine[$0] = 1; next }
  { i = index($0, " "); h = substr($0, 1, i - 1); p = substr($0, i + 1) }
  FILENAME == ARGV[2] { before[p] = h; next }
  { if (!(p in before)) print p >> created
    else if (before[p] != h && !(p in mine)) print "changed: " p >> touched
    seen[p] = 1 }
  END { for (p in before) if (!(p in seen) && !(p in mine)) print "deleted: " p >> touched }
' "$CREATED" "$BEFORE_FILES" "$AFTER_FILES"
for ledger in "$CREATED" "$TOUCHED"; do
  sort -u -o "$ledger" "$ledger"
done

# The deny list in executor.md is prefix-matched, so `sh -c "git commit"`
# walks past it. This check is the one that holds: whatever command did it,
# a moved ref means the history under review is no longer the one recorded.
snapshot_refs > "$AFTER_REFS"
if ! cmp -s "$BEFORE_REFS" "$AFTER_REFS"; then
  echo "dispatch: the executor changed git refs during this round:" >&2
  diff "$BEFORE_REFS" "$AFTER_REFS" | grep '^[<>]' >&2
  die $EXIT_GIT_MUTATED "do not accept this round. Show the user the change above; 'git reflog' has the history."
fi

if [ "$RC" -eq 143 ]; then
  die $EXIT_TIMEOUT "timed out after ${TIMEOUT}s"
fi
if [ "$RC" -ne 0 ]; then
  die $EXIT_EXECUTOR "opencode exited $RC — see $LOG"
fi

# list_or_none <file> -- each line of a report section, or "(none)".
list_or_none() { if [ -s "$1" ]; then cat "$1"; else echo "(none)"; fi; }

echo
echo "=== diff --stat (against base $(git rev-parse --short "$BASE")) ==="
git --no-pager diff --stat "$BASE"
# No form of `git diff` shows an untracked file, so a file the executor
# created -- its most likely out-of-scope error -- is listed from the ledger.
echo "=== new files (created by the executor since base) ==="
EXISTING="$(mktemp)"
while IFS= read -r p; do
  [ -e "$TOP/$p" ] && printf '%s\n' "$p"
done < "$CREATED" > "$EXISTING"
list_or_none "$EXISTING"
rm -f "$EXISTING"
echo "=== pre-existing untracked files the executor changed or deleted ==="
list_or_none "$TOUCHED"
echo "=== end ==="
exit $EXIT_OK
