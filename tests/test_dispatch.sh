#!/usr/bin/env bash
# Plain-bash test suite for dispatch.sh, rollback.sh and install.sh. No bats.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISPATCH="$ROOT/bin/dispatch.sh"
ROLLBACK="$ROOT/bin/rollback.sh"
INSTALL="$ROOT/install.sh"
STUB="$ROOT/tests/stub-opencode"
PASS=0; FAIL=0
# OC_TEST_MAJOR selects the OpenCode major the stub plays: 1 or 2 (default 2).
# Checks that only one major has are guarded on $MAJOR, so the whole suite runs
# under each.
MAJOR="${OC_TEST_MAJOR:-2}"
if [ "$MAJOR" = 1 ]; then export STUB_VERSION="1.18.21"; else export STUB_VERSION="opencode v2.0.27"; fi
echo "suite: OpenCode major $MAJOR"

# Everything the suite creates -- fixtures, fake HOMEs, the fake PATH entry --
# lives under one directory that is removed on exit. Nothing is written into
# this repository.
WORK="$(mktemp -d)"
trap 'cd /; rm -rf "$WORK"' EXIT
tmpdir() { mktemp -d "$WORK/XXXXXX"; }
tmpfile() { mktemp "$WORK/XXXXXX"; }
# A directory holding a symlink named exactly `opencode` pointing at the stub.
mkdir -p "$WORK/bin"
ln -s "$STUB" "$WORK/bin/opencode"
export PATH="$WORK/bin:$PATH"

check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "  PASS: $1"; PASS=$((PASS+1))
  else
    echo "  FAIL: $1 (expected $2, got $3)"; FAIL=$((FAIL+1))
  fi
}
# assert <description> <command...> -- PASS when the command succeeds.
assert() {
  local desc="$1"; shift
  if "$@"; then
    echo "  PASS: $desc"; PASS=$((PASS+1))
  else
    echo "  FAIL: $desc"; FAIL=$((FAIL+1))
  fi
}
# refute <description> <command...> -- PASS when the command fails.
refute() {
  local desc="$1"; shift
  if "$@"; then
    echo "  FAIL: $desc"; FAIL=$((FAIL+1))
  else
    echo "  PASS: $desc"; PASS=$((PASS+1))
  fi
}
# section <output> <header-prefix> -- the lines of one dispatch report section.
section() { printf '%s\n' "$1" | sed -n "/^=== $2/,/^=== /p" | sed '1d;$d'; }
lists() { printf '%s\n' "$1" | grep -qx -- "$2"; }
mentions() { printf '%s\n' "$1" | grep -q -- "$2"; }
alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }
dirty() { [ -n "$(git status --porcelain -- . ':(exclude).advisor')" ]; }

# Each test runs in a fresh git repo with the stub first on PATH.
new_fixture() {
  FIX="$(tmpdir)"
  cd "$FIX" || exit 1
  git init -q
  git config user.email t@t.t; git config user.name t
  echo baseline > file.txt
  mkdir -p .advisor/briefs
  echo "Goal: test brief" > .advisor/briefs/001-test.md
  printf '.advisor/runs/\n' > .gitignore
  git add -A && git commit -q -m baseline
  R1LOG="$FIX/.advisor/runs/001-test-r1.log"
}
BRIEF=.advisor/briefs/001-test.md

echo "test: opencode missing -> 10"
new_fixture
PATH="/usr/bin:/bin" "$DISPATCH" --brief $BRIEF >/dev/null 2>&1
check "missing opencode" 10 $?

echo "test: OPENCODE_BIN selects the binary, even when it is not on PATH"
new_fixture
OPENCODE_BIN="$WORK/no-such-opencode" "$DISPATCH" --brief $BRIEF >/dev/null 2>&1
check "OPENCODE_BIN names a missing binary" 10 $?
new_fixture
OPENCODE_BIN="$STUB" PATH="/usr/bin:/bin" STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief $BRIEF >/dev/null 2>&1
check "OPENCODE_BIN runs the named binary off PATH" 0 $?

echo "test: an OpenCode that is neither 1.x nor 2.x is refused -> 18, before anything runs"
new_fixture
ARGLOG="$(tmpfile)"
STUB_VERSION="opencode v3.0.0" STUB_LOG="$ARGLOG" "$DISPATCH" --brief $BRIEF >/dev/null 2>&1
check "unsupported major" 18 $?
refute "no run was attempted on it" grep -q '^run ' "$ARGLOG"

echo "test: the preflight is per major: 1.x asks agent list and runs in-process; 2.x never asks and runs standalone"
new_fixture
ARGLOG="$(tmpfile)"
STUB_LOG="$ARGLOG" STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief $BRIEF >/dev/null 2>&1
if [ "$MAJOR" = 1 ]; then
  assert "1.x: agent list ran before the run" grep -q '^agent list' "$ARGLOG"
  refute "1.x: the run is not standalone (no such flag)" grep -q -- '--standalone' "$ARGLOG"
else
  refute "2.x: no 'agent' subcommand was invoked" grep -q '^agent' "$ARGLOG"
  assert "2.x: the run is standalone, with the executor agent" grep -q '^run --agent executor --standalone' "$ARGLOG"
fi

echo "test: dispatch runs from the repository root whatever directory it is called from"
new_fixture
mkdir -p sub && cd sub
STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief ../$BRIEF >/dev/null 2>&1
check "dispatch from a subdirectory with a relative brief" 0 $?
cd "$FIX"
assert "the brief reaches opencode as an absolute path" grep -q -- "-f $FIX/$BRIEF" "$R1LOG"

echo "test: install.sh links the files, reports whether the executor resolves, and never clobbers"
H_OK="$(tmpdir)"
HOME="$H_OK" OPENCODE_BIN="$STUB" "$INSTALL" >/dev/null 2>&1
check "install with a resolvable executor" 0 $?
assert "the agent file is linked into the global config" [ -L "$H_OK/.config/opencode/agent/executor.md" ]
HOME="$H_OK" OPENCODE_BIN="$STUB" "$INSTALL" >/dev/null 2>&1
check "re-running over its own links" 0 $?
H_BAD="$(tmpdir)"
HOME="$H_BAD" OPENCODE_BIN="$STUB" STUB_NO_AGENT=1 "$INSTALL" >/dev/null 2>&1
check "install when the executor does not resolve" 1 $?
H_TAKEN="$(tmpdir)"
mkdir -p "$H_TAKEN/.config/opencode/agent"
echo "someone else's agent" > "$H_TAKEN/.config/opencode/agent/executor.md"
HOME="$H_TAKEN" OPENCODE_BIN="$STUB" "$INSTALL" >/dev/null 2>&1
check "install refuses when executor.md is someone else's file" 1 $?
assert "and leaves that file as it was" \
  [ "$(cat "$H_TAKEN/.config/opencode/agent/executor.md")" = "someone else's agent" ]

echo "test: not a git repo -> 11"
NOREPO="$(tmpdir)"; cd "$NOREPO"
mkdir -p .advisor/briefs; echo x > $BRIEF
"$DISPATCH" --brief $BRIEF >/dev/null 2>&1
check "not a repo" 11 $?

echo "test: dirty tree -> 12"
new_fixture
echo "uncommitted change" >> file.txt
"$DISPATCH" --brief $BRIEF >/dev/null 2>&1
check "dirty tree" 12 $?
new_fixture
echo "stray" > untracked.txt
"$DISPATCH" --brief $BRIEF >/dev/null 2>&1
check "an untracked file outside .advisor/ is dirty too" 12 $?

echo "test: untracked .advisor/ does NOT count as dirty -> 0"
new_fixture
echo "new brief" > ".advisor/briefs/002 new.md"
"$DISPATCH" --brief ".advisor/briefs/002 new.md" >/dev/null 2>&1
check "advisor dir ignored by dirty check, even with a space in the name" 0 $?

echo "test: missing brief -> 13"
new_fixture
"$DISPATCH" --brief .advisor/briefs/nope.md >/dev/null 2>&1
check "missing brief" 13 $?

echo "test: happy path logs the run and reports the executor's edit"
new_fixture
OUT="$(STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief $BRIEF 2>&1)"
check "happy path exit" 0 $?
assert "log captured the invocation" grep -q -- '--agent executor' "$R1LOG"
assert "diff reported the edited file" mentions "$OUT" 'file.txt'

echo "test: message after -f is passed as a message, not a filename"
new_fixture
# 1.x declares -f as an array option, so it swallows positionals after it; the
# stub mirrors that. Without the -- terminator the message would be read as a
# missing file and OpenCode would exit before the executor ran.
STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief $BRIEF >/dev/null 2>&1
check "dispatch succeeds with -- terminator in place" 0 $?
assert "message reached the stub after a -- terminator" \
  grep -q -- '-- Implement the attached brief\. Follow it exactly\.' "$R1LOG"
refute "stub did not reject the message as a missing file" grep -q 'File not found' "$R1LOG"

echo "test: --message replaces the default instruction so a delta round says so"
new_fixture
STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief $BRIEF >/dev/null 2>&1
STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief $BRIEF --round 2 --continue \
  --message "Apply the '## Round 2 delta' section at the end of the attached brief. Do not redo the rest." \
  >/dev/null 2>&1
DELTALOG="$FIX/.advisor/runs/001-test-r2.log"
assert "the delta message reached opencode after the -- terminator" \
  grep -q -- "-- Apply the '## Round 2 delta' section" "$DELTALOG"
refute "the default 'implement it all' instruction was replaced, not appended" \
  grep -q 'Implement the attached brief' "$DELTALOG"

if [ "$MAJOR" = 1 ]; then
echo "test: 1.x: a failing 'agent list' is refused -> 14, and the refusal names OpenCode's error"
new_fixture
ERRFILE="$(tmpfile)"
STUB_AGENT_LIST_ERROR="no such column: project_id" "$DISPATCH" --brief $BRIEF >/dev/null 2>"$ERRFILE"
check "agent list fails" 14 $?
assert "the message carries the error, not just 'not resolved'" grep -q 'no such column' "$ERRFILE"
fi

echo "test: executor agent does not resolve -> 14, and nothing was edited"
new_fixture
STUB_NO_AGENT=1 STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief $BRIEF >/dev/null 2>&1
check "unresolved executor agent" 14 $?
# OpenCode resolves the agent before it calls a model, so on 2.x the refusal
# comes from the run's own log. The stub's edit runs after resolution: if it
# happened, the agent was never really refused.
if [ "$MAJOR" = 2 ]; then
  assert "the log names the missing agent" grep -q 'Agent not found: "executor"' "$R1LOG"
else
  refute "1.x refuses in the preflight, so no run log exists" [ -e "$R1LOG" ]
fi
refute "the stub's edit never landed, so the executor never ran" grep -q 'edited by stub' "$FIX/file.txt"

echo "test: executor failure -> 20"
new_fixture
STUB_EXIT=1 "$DISPATCH" --brief $BRIEF >/dev/null 2>&1
check "executor nonzero" 20 $?

echo "test: an executor that refuses the brief exits 19, not 0, and still shows the report"
new_fixture
OUT="$(STUB_PROBLEM="the brief names a file that does not exist" "$DISPATCH" --brief $BRIEF 2>&1)"
check "BRIEF PROBLEM in the log" 19 $?
assert "the report still prints, so the advisor sees what was and was not changed" \
  mentions "$OUT" '=== diff --stat'

echo "test: --timeout must be a positive integer, or the run would have no limit -> 2"
new_fixture
ARGLOG="$(tmpfile)"
STUB_LOG="$ARGLOG" "$DISPATCH" --brief $BRIEF --timeout 10m >/dev/null 2>&1
check "--timeout 10m" 2 $?
refute "nothing ran" grep -q '^run ' "$ARGLOG"

echo "test: timeout -> 24"
new_fixture
STUB_HANG=5 "$DISPATCH" --brief $BRIEF --timeout 1 >/dev/null 2>&1
check "timeout" 24 $?

echo "test: a timeout is reported as 24 even when the executor exits 130 on TERM, as the real CLI does"
new_fixture
STUB_TERM_EXIT=130 STUB_HANG=30 "$DISPATCH" --brief $BRIEF --timeout 1 >/dev/null 2>&1
check "timeout with a 130 exit on TERM" 24 $?

echo "test: a timeout kills the executor's whole process group"
new_fixture
# A real executor spawns subprocesses. Signalling only opencode leaves them
# orphaned with edit and bash permissions intact, still mutating the repo
# while the advisor reads the diff. `sleep 593` stands in for one.
PIDFILE="$FIX/child.pid"
STUB_CHILD=593 STUB_CHILD_PIDFILE="$PIDFILE" STUB_HANG=30 \
  "$DISPATCH" --brief $BRIEF --timeout 1 >/dev/null 2>&1
check "timeout still maps to 24" 24 $?
assert "the run really did spawn a child (precondition)" [ -s "$PIDFILE" ]
CHILD_PID="$(cat "$PIDFILE" 2>/dev/null)"
sleep 1   # let the TERM/KILL escalation land
refute "the executor's child died with the group" alive "$CHILD_PID"
kill -KILL "$CHILD_PID" 2>/dev/null   # never leave it behind for the next test

echo "test: a timeout also kills a child that moved to its own process group"
new_fixture
# An executor's shell command can leave the group (setsid). A group kill alone
# misses it; the tree captured before the signal must catch it.
PIDFILE="$FIX/child-newgroup.pid"
STUB_CHILD=593 STUB_CHILD_NEWGROUP=1 STUB_CHILD_PIDFILE="$PIDFILE" STUB_HANG=30 \
  "$DISPATCH" --brief $BRIEF --timeout 1 >/dev/null 2>&1
check "timeout still maps to 24" 24 $?
CHILD_PID="$(cat "$PIDFILE" 2>/dev/null)"
sleep 1
refute "the child that left the process group died" alive "$CHILD_PID"
kill -KILL "$CHILD_PID" 2>/dev/null

echo "test: killing dispatch itself stops the executor -> 130"
new_fixture
# The executor runs in its own process group, so a signal aimed at dispatch (a
# tool timeout, Ctrl-C) does not reach it. Dispatch has to pass it on.
PIDFILE="$FIX/child-int.pid"
STUB_CHILD=591 STUB_CHILD_PIDFILE="$PIDFILE" STUB_HANG=60 \
  "$DISPATCH" --brief $BRIEF >/dev/null 2>&1 &
DPID=$!
for _ in $(seq 1 50); do [ -s "$PIDFILE" ] && break; sleep 0.2; done
CHILD_PID="$(cat "$PIDFILE" 2>/dev/null)"
assert "the executor was running (precondition)" alive "$CHILD_PID"
kill -TERM "$DPID"; wait "$DPID"
check "interrupted dispatch" 130 $?
refute "the executor's child did not outlive dispatch" alive "$CHILD_PID"
kill -KILL "$CHILD_PID" 2>/dev/null

echo "test: the executor cannot read .env files, however it asks; .env.example stays readable"
new_fixture
printf '.advisor/runs/\n.env\n.env.*\n!.env.example\n' > .gitignore
echo 'DB_PASSWORD=hunter2' > .env
echo 'TOKEN=hunter2' > .env.local
echo 'DB_PASSWORD=' > .env.example
git add -A && git commit -qm "env files"
OUT="$(STUB_RUN='cat .env > leak1.txt 2>&1; cat "$PWD/.env.local" > leak2.txt 2>&1;
                 ln -s .env via-link; cat via-link > leak3.txt 2>&1;
                 cp .env.example example-copy.txt' \
  "$DISPATCH" --brief $BRIEF 2>&1)"
check "the round still succeeds" 0 $?
if command -v sandbox-exec >/dev/null 2>&1; then
  assert "the report says the secrets are protected" mentions "$OUT" 'secrets -> .env files are unreadable'
  refute "a plain cat of .env got nothing" grep -q hunter2 leak1.txt
  refute "an absolute path to .env.local got nothing" grep -q hunter2 leak2.txt
  refute "a symlink to .env got nothing" grep -q hunter2 leak3.txt
  assert ".env itself is untouched" grep -q hunter2 .env
  assert ".env.example was readable" grep -q 'DB_PASSWORD=' example-copy.txt

  echo "test: where the sandbox cannot apply, the run goes ahead and says it is unprotected"
  new_fixture
  # A sandbox cannot be applied inside another one, as when the caller is sandboxed.
  OUT="$(STUB_EDIT="$FIX/file.txt" sandbox-exec -p '(version 1)(allow default)' \
    "$DISPATCH" --brief $BRIEF 2>&1)"
  check "the round still runs" 0 $?
  assert "and the report says it is not protected" mentions "$OUT" 'secrets -> NOT protected'
else
  assert "no sandbox here, and the report says so" mentions "$OUT" 'secrets -> NOT protected'
fi

echo "test: a continuation resumes the executor's session: by id on 2.x, by -c on 1.x"
new_fixture
STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief $BRIEF >/dev/null 2>&1
STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief $BRIEF --round 2 --continue >/dev/null 2>&1
R2LOG="$FIX/.advisor/runs/001-test-r2.log"
if [ "$MAJOR" = 1 ]; then
  assert "1.x: round 2 passes -c" grep -q -- ' -c ' "$R2LOG"
  refute "1.x: no --session flag" grep -q -- '--session' "$R2LOG"
else
  SESSION1="$(grep -oE -- '--session ses_[0-9a-f]+' "$R1LOG" | head -1)"
  SESSION2="$(grep -oE -- '--session ses_[0-9a-f]+' "$R2LOG" | head -1)"
  assert "round 1 starts a session with a generated ses_ id" [ -n "$SESSION1" ]
  check "round 2 resumes the same session" "$SESSION1" "$SESSION2"
  refute "no -c anywhere in the continuation" grep -q -- ' -c ' "$R2LOG"
fi

if [ "$MAJOR" = 2 ]; then
echo "test: 2.x: a continuation with no recorded session -> 15, and never guesses one"
new_fixture
STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief $BRIEF >/dev/null 2>&1
rm -f "$FIX/.advisor/runs/001-test-session"
"$DISPATCH" --brief $BRIEF --round 2 --continue >/dev/null 2>&1
check "continuation without a session" 15 $?
fi

echo "test: a correction round runs on the tree round 1 dirtied, but a new round 1 still refuses"
new_fixture
STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief $BRIEF >/dev/null 2>&1
check "round 1 on a clean tree" 0 $?
assert "round 1 left the tree dirty (precondition for the next check)" dirty
STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief $BRIEF --round 2 --continue >/dev/null 2>&1
check "continuation round on a dirty tree" 0 $?
"$DISPATCH" --brief $BRIEF >/dev/null 2>&1
check "new round 1 on the dirty tree still refused" 12 $?

echo "test: continuation with no recorded baseline -> 15"
new_fixture
"$DISPATCH" --brief $BRIEF --round 2 --continue >/dev/null 2>&1
check "continuation without a recorded base" 15 $?

echo "test: the diff is pinned to the recorded base, not to the working tree"
new_fixture
STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief $BRIEF >/dev/null 2>&1
# Stage round 1's change. A bare `git diff` now shows nothing at all, so a
# diff that is not pinned to BASE would hide the work under review.
git add -A
OUT="$("$DISPATCH" --brief $BRIEF --round 2 --continue 2>&1)"
assert "unpinned 'git diff' is empty here (precondition)" [ -z "$(git --no-pager diff --stat)" ]
assert "diff against BASE still shows the staged round-1 change" mentions "$OUT" 'file.txt'

echo "test: .advisor/runs ignores itself so logs cannot be committed"
new_fixture
STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief $BRIEF >/dev/null 2>&1
rm -f .gitignore   # remove the repo-level ignore; the runs dir must stand alone
git add -A >/dev/null 2>&1
refute "'git add -A' could not stage anything under .advisor/runs" \
  bash -c 'git diff --cached --name-only | grep -q "\.advisor/runs/"'

echo "test: a file the executor CREATES is surfaced, though git diff cannot show it"
new_fixture
OUT="$(STUB_CREATE="$FIX/created.txt" "$DISPATCH" --brief $BRIEF 2>&1)"
check "create-only round exits 0" 0 $?
# If git ever learns to show untracked files in a diff, the precondition fails
# and this test must be revisited.
refute "diff section is blind to the new file (precondition)" mentions "$(section "$OUT" 'diff --stat')" 'created.txt'
assert "new-files section surfaced the created file" lists "$(section "$OUT" 'new files')" 'created.txt'

echo "test: no new files -> new-files section says (none), and never lists the advisor's brief"
new_fixture
echo "new brief" > .advisor/briefs/002-new.md
OUT="$(STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief .advisor/briefs/002-new.md 2>&1)"
check "the section is exactly (none)" "(none)" "$(section "$OUT" 'new files')"

echo "test: dispatch through command substitution does not hang or leak sleep"
new_fixture
before_pids=$(pgrep -P 1 -f '^sleep 600' | sort)
OUT="$(STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief $BRIEF 2>&1)"
check "command substitution completed" 0 $?
after_pids=$(pgrep -P 1 -f '^sleep 600' | sort)
# Compare PID sets, not counts: `echo "" | wc -l` is 1, not 0.
check "no orphaned watchdog sleep" "$before_pids" "$after_pids"

echo "test: a repository with no commits -> 16, distinct from 'not a repo'"
EMPTY="$(tmpdir)"; cd "$EMPTY"; git init -q
mkdir -p .advisor/briefs; echo x > $BRIEF
"$DISPATCH" --brief $BRIEF >/dev/null 2>&1
check "no commits" 16 $?

echo "test: --continue on round 1, or a non-numeric round, is a malformed invocation -> 2"
new_fixture
"$DISPATCH" --brief $BRIEF --round 1 --continue >/dev/null 2>&1
check "--continue with --round 1" 2 $?
"$DISPATCH" --brief $BRIEF --round two >/dev/null 2>&1
check "--round two" 2 $?

echo "test: a later round WITHOUT --continue is a fresh start, so it refuses a dirty tree"
new_fixture
STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief $BRIEF >/dev/null 2>&1
BASE1="$(cat "$FIX/.advisor/runs/001-test-base")"
S1="$(cat "$FIX/.advisor/runs/001-test-session" 2>/dev/null)"
"$DISPATCH" --brief $BRIEF --round 2 >/dev/null 2>&1
check "--round 2 alone on round 1's dirty tree" 12 $?
# Refusals come before anything is written, so round 1's state survives them.
check "the refused round left the base in place" "$BASE1" "$(cat "$FIX/.advisor/runs/001-test-base")"
check "and the session" "$S1" "$(cat "$FIX/.advisor/runs/001-test-session" 2>/dev/null)"

echo "test: the executor moving a ref trips the wire -> 21, whatever the deny list missed"
new_fixture
# `sh -c` wraps the command, which is exactly what a prefix-anchored deny
# pattern cannot see. The check that catches it must be after the fact.
ERRFILE="$(tmpfile)"
STUB_EDIT="$FIX/file.txt" STUB_RUN='sh -c "git commit -qam sneaky"' \
  "$DISPATCH" --brief $BRIEF >/dev/null 2>"$ERRFILE"
check "wrapped git commit" 21 $?
assert "the refusal names the moved ref" grep -q "refs/heads/" "$ERRFILE"
new_fixture
STUB_RUN='git tag sneaky' "$DISPATCH" --brief $BRIEF >/dev/null 2>&1
check "git tag" 21 $?
new_fixture
# Negative control: staging touches no ref, and the diff is pinned to the
# base, so it hides nothing. The wire must not trip on it.
STUB_EDIT="$FIX/file.txt" STUB_RUN='git add -A' "$DISPATCH" --brief $BRIEF >/dev/null 2>&1
check "git add alone does not trip the wire" 0 $?

echo "test: a file the executor creates under .advisor/ is reported like any other"
new_fixture
OUT="$(STUB_CREATE="$FIX/.advisor/notes.md" "$DISPATCH" --brief $BRIEF 2>&1)"
assert ".advisor/notes.md is listed as new" lists "$(section "$OUT" 'new files')" '.advisor/notes.md'

echo "test: the executor editing the advisor's untracked brief is reported"
new_fixture
echo "new brief" > .advisor/briefs/002-new.md
OUT="$(STUB_EDIT="$FIX/.advisor/briefs/002-new.md" "$DISPATCH" --brief .advisor/briefs/002-new.md 2>&1)"
assert "the brief is listed as changed" lists "$(section "$OUT" 'pre-existing')" 'changed: .advisor/briefs/002-new.md'
check "and not as new" "(none)" "$(section "$OUT" 'new files')"

echo "test: new files accumulate across rounds, and a user's file dropped between rounds is not one"
new_fixture
STUB_CREATE="$FIX/a.txt" "$DISPATCH" --brief $BRIEF >/dev/null 2>&1
echo "mine" > scratch.txt
OUT="$(STUB_CREATE="$FIX/b.txt" "$DISPATCH" --brief $BRIEF --round 2 --continue 2>&1)"
NEW="$(section "$OUT" 'new files')"
assert "round 1's file is still reported on round 2" lists "$NEW" 'a.txt'
assert "round 2's file is reported" lists "$NEW" 'b.txt'
refute "the user's scratch file is not attributed to the executor" lists "$NEW" 'scratch.txt'
OUT="$(STUB_EDIT="$FIX/a.txt" "$DISPATCH" --brief $BRIEF --round 3 --continue 2>&1)"
check "editing its own earlier file is not reported as pre-existing" "(none)" "$(section "$OUT" 'pre-existing')"

echo "test: rollback undoes the executor's work and nothing else"
new_fixture
STUB_EDIT="$FIX/file.txt" STUB_CREATE="$FIX/new/dir/x.txt" "$DISPATCH" --brief $BRIEF >/dev/null 2>&1
echo "mine" > scratch.txt
echo "draft" > .advisor/briefs/002-next.md
"$ROLLBACK" --brief $BRIEF >/dev/null 2>&1
check "rollback exit" 0 $?
assert "the tracked edit is reverted" [ "$(cat file.txt)" = "baseline" ]
assert "the executor's file is deleted" [ ! -e new/dir/x.txt ]
assert "the directories it created are removed" [ ! -e new ]
assert "the user's untracked file survives" [ -f scratch.txt ]
assert "the advisor's untracked brief survives" [ -f .advisor/briefs/002-next.md ]

echo "test: rollback ends the delegation, so a continuation cannot resume undone work -> 15"
new_fixture
STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief $BRIEF >/dev/null 2>&1
"$ROLLBACK" --brief $BRIEF >/dev/null 2>&1
"$DISPATCH" --brief $BRIEF --round 2 --continue >/dev/null 2>&1
check "continuation after rollback, on either major" 15 $?

echo "test: rollback removes a new file the executor staged"
new_fixture
STUB_CREATE="$FIX/staged.txt" STUB_RUN='git add -A' "$DISPATCH" --brief $BRIEF >/dev/null 2>&1
assert "precondition: the executor staged its file" git ls-files --error-unmatch staged.txt >/dev/null 2>&1
"$ROLLBACK" --brief $BRIEF >/dev/null 2>&1
assert "the staged file is gone" [ ! -e staged.txt ]
assert "the index matches the base again" git diff --cached --quiet

echo "test: rollback deletes only what is untracked inside the repo, whatever the ledger says"
new_fixture
STUB_CREATE="$FIX/x.txt" "$DISPATCH" --brief $BRIEF >/dev/null 2>&1
OUTSIDE="$(tmpdir)/victim.txt"; echo keep > "$OUTSIDE"
# The ledger lives in a directory the executor can write to. A forged entry
# must not turn rollback into a delete-anything primitive.
printf '%s\nfile.txt\n' "$OUTSIDE" >> .advisor/runs/001-test-created
"$ROLLBACK" --brief $BRIEF >/dev/null 2>&1
assert "a path outside the repo survives" [ -f "$OUTSIDE" ]
assert "a tracked file named in the ledger is restored, not deleted" [ -f file.txt ]
assert "the genuine new file is still deleted" [ ! -e x.txt ]

echo "test: rollback refuses without a baseline -> 15, and when HEAD has moved -> 21"
new_fixture
"$ROLLBACK" --brief $BRIEF >/dev/null 2>&1
check "rollback with no recorded base" 15 $?
new_fixture
STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief $BRIEF >/dev/null 2>&1
git commit -qam "someone committed mid-delegation"
"$ROLLBACK" --brief $BRIEF >/dev/null 2>&1
check "rollback after HEAD moved" 21 $?
assert "and it changed nothing" grep -q 'edited by stub' file.txt

echo "test: a fresh round after rollback starts a fresh ledger"
new_fixture
STUB_CREATE="$FIX/old.txt" "$DISPATCH" --brief $BRIEF >/dev/null 2>&1
"$ROLLBACK" --brief $BRIEF >/dev/null 2>&1
OUT="$(STUB_CREATE="$FIX/fresh.txt" "$DISPATCH" --brief $BRIEF --round 2 2>&1)"
check "fresh round 2 on the rolled-back tree" 0 $?
check "only this attempt's file is reported" "fresh.txt" "$(section "$OUT" 'new files')"

echo "test: with no --model, the executor runs on its frontmatter model, passed explicitly"
new_fixture
STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief $BRIEF >/dev/null 2>&1
FM_MODEL="$(sed -n 's/^model: *//p' "$ROOT/agent/executor.md" | head -1)"
assert "argv carries -m with the frontmatter id" grep -q -- "-m $FM_MODEL " "$R1LOG"

echo "test: a model name from the chat resolves to its id"
new_fixture
STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief $BRIEF --model "DeepSeek Pro" >/dev/null 2>&1
check "named model dispatches" 0 $?
assert "argv carries the resolved id, not the name" grep -q -- '-m opencode-go/deepseek-v4-pro' "$R1LOG"

echo "test: a provider/model id passes through unchanged"
new_fixture
STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief $BRIEF --model opencode-go/deepseek-v4-pro >/dev/null 2>&1
assert "explicit id reaches argv" grep -q -- '-m opencode-go/deepseek-v4-pro' "$R1LOG"

echo "test: an unknown model name is refused -> 17, before anything runs"
new_fixture
"$DISPATCH" --brief $BRIEF --model "gpt nine" >/dev/null 2>&1
check "unknown model name" 17 $?
refute "no run log: the executor was never invoked" [ -e "$R1LOG" ]

echo "test: a model the provider does not offer is refused -> 17, before anything runs"
new_fixture
STUB_NO_MODEL=opencode-go/deepseek-v4.1-flash "$DISPATCH" --brief $BRIEF >/dev/null 2>&1
check "default model not offered" 17 $?
refute "no run log: the executor was never invoked" [ -e "$R1LOG" ]

echo "test: the resolver maps names, refuses unknowns, and never guesses across versions"
RES="$ROOT/bin/resolve-model.sh"
check "no argument gives the frontmatter model" "$FM_MODEL" "$("$RES")"
check "'deepseek-flash' resolves" "opencode-go/deepseek-v4.1-flash" "$("$RES" deepseek-flash)"
check "'deepseek-v4-flash' does NOT resolve to v4.1" "" "$("$RES" deepseek-v4-flash 2>/dev/null)"
refute "unknown names exit nonzero" "$RES" nonsense
assert "with nothing on stdout" [ -z "$("$RES" nonsense 2>/dev/null)" ]

echo "test: SKILL.md documents every exit code and flag the scripts implement"
SKILL="$ROOT/SKILL.md"
for code in $(grep -oE '^readonly EXIT_[A-Z_]+=[0-9]+' "$ROOT/bin/lib.sh" | grep -oE '[0-9]+$'); do
  assert "exit code $code is in the advisor's table" grep -q "^| $code |" "$SKILL"
done
for flag in $(cat "$DISPATCH" "$ROLLBACK" | grep -oE '^    --[a-z]+\)' | tr -d ' )' | sort -u); do
  assert "$flag is documented" grep -q -- "$flag" "$SKILL"
done

echo "test: the executor agent cannot run git commands that erase the diff"
AGENT="$ROOT/agent/executor.md"
# The advisor's whole verification is reading the diff. An executor that can
# commit, stash, checkout or reset empties that diff before the advisor looks.
for pat in commit reset checkout restore switch stash clean push; do
  assert "git $pat denied" grep -qE "^ +\"git $pat\\*\": *deny" "$AGENT"
done
# OpenCode prepends `read *.env ask` by default, and an ask stalls a run with no
# terminal; the explicit deny has to come after the allow (last match wins).
assert "read of *.env denied" grep -qE '^ +"\*\.env": *deny' "$AGENT"
assert "read of *.env.* denied" grep -qE '^ +"\*\.env\.\*": *deny' "$AGENT"
refute "no read rule asks, which would stall a run with no terminal" grep -qE '"\*\.env[^"]*": *ask' "$AGENT"
# A malformed permission block would silently break the agent, so parse the
# frontmatter when a YAML parser happens to be available. Skipped, never
# failed, where there is none: the suite must not grow a dependency.
if python3 -c 'import yaml' >/dev/null 2>&1; then
  assert "executor.md frontmatter parses and the permission maps are well-formed" python3 - "$AGENT" <<'PYEOF'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]).read().split('---')[1])
b, r = d['permission']['bash'], d['permission']['read']
assert b['*'] == 'allow' and b['git commit*'] == 'deny', b
assert list(r)[0] == '*' and r['*.env'] == 'deny', r
PYEOF
else
  echo "  SKIP: no yaml parser available for the frontmatter check"
fi

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
