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
# The binary is explicit, so a second install earlier on PATH cannot be picked
# up by accident. See docs/opencode-2-compatibility.md.
OC="${OPENCODE_BIN:-opencode}"

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

command -v "$OC" >/dev/null 2>&1 \
  || die $EXIT_NO_OPENCODE "'$OC' not found. Install OpenCode 2, or set OPENCODE_BIN to its path."

# 1.x and 2.x are both supported; they differ in flags and in how runs and
# sessions work (see oc_major in lib.sh). Anything else is refused, not guessed at.
MAJOR="$(oc_major "$OC")"
case "$MAJOR" in
  1|2) ;;
  *) die $EXIT_WRONG_OPENCODE "'$OC' is not a supported OpenCode (1.x or 2.x). Put one first on PATH or set OPENCODE_BIN." ;;
esac

git rev-parse --git-dir >/dev/null 2>&1 \
  || die $EXIT_NOT_REPO "not inside a git repository. Run 'git init' and make a baseline commit first."

[ -r "$BRIEF" ] \
  || die $EXIT_NO_BRIEF "brief not readable: ${BRIEF:-<none>}"
# The run changes into the repository root, so the brief path must not be relative.
BRIEF_ABS="$(cd "$(dirname "$BRIEF")" && pwd)/$(basename "$BRIEF")"

# 1.x only: the executor must be listed by `agent list`. Before this check the
# published 1.x skill relied on opencode itself to fail on a missing agent. On
# 2.x the same refusal is detected from the run's log instead, below.
if [ "$MAJOR" -eq 1 ]; then
  AGENTS_TMP="$(mktemp)"
  if ! oc_v1_agent_listed "$OC" "$AGENTS_TMP"; then
    WHY="$(oc_error_line "$AGENTS_TMP")"
    rm -f "$AGENTS_TMP"
    die $EXIT_NO_AGENT "OpenCode does not resolve the 'executor' agent${WHY:+ ($WHY)}. Run ~/.claude/skills/delegate/install.sh, then retry."
  fi
  rm -f "$AGENTS_TMP"
fi

# --model takes a name the user used ("deepseek flash") or a provider/model id.
# Resolve it here, then confirm OpenCode actually offers that model, so a typo
# or a retired model is refused before anything runs.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVED="$("$SCRIPT_DIR/resolve-model.sh" "$MODEL")" \
  || die $EXIT_NO_MODEL "unknown model '${MODEL:-<default>}'. Names are listed in config/models.tsv; pass a provider/model id to use one not listed there."
MODELS_TMP="$(mktemp)"
oc_models "$OC" "$MAJOR" "$MODELS_TMP"
if ! grep -qxF -- "$RESOLVED" "$MODELS_TMP"; then
  rm -f "$MODELS_TMP"
  die $EXIT_NO_MODEL "OpenCode does not offer '$RESOLVED'. It may be retired or misspelled; update config/models.tsv."
fi
rm -f "$MODELS_TMP"
MODEL="$RESOLVED"

BRIEF_STEM="$(basename "$BRIEF" .md)"
TOP="$(git rev-parse --show-toplevel)"
# OpenCode keys sessions by the directory it runs in, so every run starts from
# the repository root, whatever directory the advisor was in.
cd "$TOP" || die $EXIT_NOT_REPO "cannot enter the repository root $TOP."
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
SESSIONFILE="$(session_file "$RUNDIR" "$BRIEF_STEM")"

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

if [ "$MAJOR" -eq 2 ]; then
  # A fresh round gets a new session. A continuation resumes the one round 1
  # recorded, and refuses rather than falling back to whatever session is newest.
  if [ "$CONTINUE" -eq 0 ]; then
    SESSION="ses_$(od -An -N13 -tx1 /dev/urandom | tr -d ' \n')"
    printf '%s\n' "$SESSION" > "$SESSIONFILE"
  else
    [ -r "$SESSIONFILE" ] || die $EXIT_NO_BASE \
      "no recorded session for '$BRIEF_STEM', so there is nothing to continue. Start this delegation without --continue."
    SESSION="$(cat "$SESSIONFILE")"
  fi
  # --standalone gives this run a private server, so the process that owns the
  # executor is the one the watchdog below can kill. A shared background service
  # would keep the executor alive after a timeout. The agent comes from the
  # global agent directory, which a private server loads on its own.
  ARGS=(run --agent executor --standalone --session "$SESSION" -m "$MODEL" -f "$BRIEF_ABS" -- "$MESSAGE")
  SESSION_NOTE="session -> $SESSION"
else
  # 1.x runs in-process and has no session ids to pin. A continuation resumes
  # the last session in this directory, as the published 1.x skill always did.
  ARGS=(run --agent executor)
  [ "$CONTINUE" -eq 1 ] && ARGS+=(-c)
  ARGS+=(-m "$MODEL" -f "$BRIEF_ABS" -- "$MESSAGE")
  SESSION_NOTE="session -> last session in this directory (OpenCode 1.x)"
fi

echo "dispatch: round $ROUND -> $OC ${ARGS[*]}"
echo "dispatch: base -> $(git rev-parse --short "$BASE")"
echo "dispatch: $SESSION_NOTE"
echo "dispatch: log -> $LOG"

BEFORE_FILES="$(mktemp)"; AFTER_FILES="$(mktemp)"; BEFORE_REFS="$(mktemp)"; AFTER_REFS="$(mktemp)"
FIRED="$(mktemp)"
trap 'rm -f "$BEFORE_FILES" "$AFTER_FILES" "$BEFORE_REFS" "$AFTER_REFS" "$FIRED"' EXIT
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
"$OC" "${ARGS[@]}" >"$LOG" 2>&1 </dev/null &
CMD_PID=$!
set +m
# The watchdog records that it fired. The exit status cannot say so: OpenCode
# exits 130 on SIGTERM, not 143, and a KILL leaves no status at all.
( sleep "$TIMEOUT" && {
    echo fired > "$FIRED"
    # The tree is captured first, so children that moved to their own process
    # group, or were reparented when OpenCode died, are still signalled.
    TREE="$(descendants "$CMD_PID")"
    kill -TERM -"$CMD_PID" $TREE 2>/dev/null
    sleep 3
    kill -KILL -"$CMD_PID" $TREE 2>/dev/null
  } ) >/dev/null 2>&1 &
WATCHDOG_PID=$!

wait "$CMD_PID"; RC=$?
pkill -P "$WATCHDOG_PID" >/dev/null 2>&1
kill -TERM "$WATCHDOG_PID" 2>/dev/null
wait "$WATCHDOG_PID" 2>/dev/null

TIMED_OUT=0
grep -q fired "$FIRED" && TIMED_OUT=1
if [ "$TIMED_OUT" -eq 1 ]; then
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

# OpenCode exits nonzero and says so when it cannot resolve the agent. Nothing
# ran in that case: the error comes before any model call. Report it as a
# harness refusal (14), not as an executor failure (20).
if [ "$RC" -ne 0 ] && grep -q 'Agent not found: "executor"' "$LOG"; then
  die $EXIT_NO_AGENT "OpenCode cannot find the 'executor' agent. No model call was made. Run ~/.claude/skills/delegate/install.sh, then retry."
fi
if [ "$TIMED_OUT" -eq 1 ]; then
  die $EXIT_TIMEOUT "timed out after ${TIMEOUT}s"
fi
if [ "$RC" -ne 0 ]; then
  die $EXIT_EXECUTOR "OpenCode exited $RC — see $LOG"
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
# The executor exits cleanly when it refuses a brief, so exit status alone would
# read as success. Its marker is the signal that the round did not implement anything.
if grep -q 'BRIEF PROBLEM:' "$LOG"; then
  die $EXIT_BRIEF_PROBLEM "the executor stopped with a BRIEF PROBLEM. Any changes it made are shown above. Read the problem in $LOG before anything else."
fi
exit $EXIT_OK
