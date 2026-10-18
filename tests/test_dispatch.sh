#!/usr/bin/env bash
# Plain-bash test suite for dispatch.sh. No bats on this machine.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISPATCH="$ROOT/bin/dispatch.sh"
ROLLBACK="$ROOT/bin/rollback.sh"
STUBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0; FAIL=0
# OC_TEST_MAJOR selects the OpenCode major the stub plays: 1 or 2 (default 2).
# Checks that only one major has are guarded on $MAJOR, so the whole suite runs
# under each.
MAJOR="${OC_TEST_MAJOR:-2}"
if [ "$MAJOR" = 1 ]; then export STUB_VERSION="1.18.21"; else export STUB_VERSION="opencode v2.0.27"; fi
echo "suite: OpenCode major $MAJOR"

check() { # check <name> <expected-code> <actual-code>
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

# Each test runs in a fresh temp git repo with the stub first on PATH.
new_fixture() {
  FIX="$(mktemp -d)"
  cd "$FIX" || exit 1
  git init -q
  git config user.email t@t.t; git config user.name t
  echo baseline > file.txt
  mkdir -p .advisor/briefs
  echo "Goal: test brief" > .advisor/briefs/001-test.md
  printf '.advisor/runs/\n' > .gitignore
  git add -A && git commit -q -m baseline
  export PATH="$STUBDIR/fakebin:$PATH"
}

# fakebin holds a symlink named exactly `opencode` pointing at the stub.
mkdir -p "$STUBDIR/fakebin"
ln -sf "$STUBDIR/stub-opencode" "$STUBDIR/fakebin/opencode"

echo "test: opencode missing -> 10"
new_fixture
PATH="/usr/bin:/bin" "$DISPATCH" --brief .advisor/briefs/001-test.md >/dev/null 2>&1
check "missing opencode" 10 $?

echo "test: OPENCODE_BIN selects the binary, even when it is not on PATH"
new_fixture
OPENCODE_BIN="$STUBDIR/no-such-opencode" "$DISPATCH" --brief .advisor/briefs/001-test.md >/dev/null 2>&1
check "OPENCODE_BIN names a missing binary" 10 $?
new_fixture
OPENCODE_BIN="$STUBDIR/stub-opencode" PATH="/usr/bin:/bin" STUB_EDIT="$FIX/file.txt" \
  "$DISPATCH" --brief .advisor/briefs/001-test.md >/dev/null 2>&1
check "OPENCODE_BIN runs the named binary off PATH" 0 $?

echo "test: an OpenCode that is neither 1.x nor 2.x is refused -> 18, before anything runs"
new_fixture
ARGLOG="$(mktemp)"
STUB_VERSION="opencode v3.0.0" STUB_LOG="$ARGLOG" "$DISPATCH" --brief .advisor/briefs/001-test.md >/dev/null 2>&1
check "unsupported major" 18 $?
refute "no run was attempted on it" grep -q '^run ' "$ARGLOG"

echo "test: the preflight is per major: 1.x asks agent list and runs in-process; 2.x never asks and runs standalone"
new_fixture
ARGLOG="$(mktemp)"
STUB_LOG="$ARGLOG" STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief .advisor/briefs/001-test.md >/dev/null 2>&1
if [ "$MAJOR" = 1 ]; then
  assert "1.x: agent list ran before the run" grep -q '^agent list' "$ARGLOG"
  refute "1.x: the run is not standalone (no such flag)" grep -q -- '--standalone' "$ARGLOG"
else
  refute "2.x: no 'agent' subcommand was invoked" grep -q '^agent' "$ARGLOG"
  assert "2.x: the run is standalone, with the executor agent" grep -q '^run --agent executor --standalone' "$ARGLOG"
fi

if [ "$MAJOR" = 2 ]; then
echo "test: a continuation with no recorded session -> 15, and never guesses one"
new_fixture
STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief .advisor/briefs/001-test.md >/dev/null 2>&1
rm -f "$FIX/.advisor/runs/001-test-session"
"$DISPATCH" --brief .advisor/briefs/001-test.md --round 2 --continue >/dev/null 2>&1
check "continuation without a session" 15 $?

echo "test: rollback forgets the session, so a continuation cannot resume undone work"
new_fixture
STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief .advisor/briefs/001-test.md >/dev/null 2>&1
"$ROLLBACK" --brief .advisor/briefs/001-test.md >/dev/null 2>&1
"$DISPATCH" --brief .advisor/briefs/001-test.md --round 2 --continue >/dev/null 2>&1
check "continuation after rollback" 15 $?
fi

echo "test: dispatch runs from the repository root whatever directory it is called from"
new_fixture
mkdir -p sub && cd sub
STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief ../.advisor/briefs/001-test.md >/dev/null 2>&1
check "dispatch from a subdirectory with a relative brief" 0 $?
cd "$FIX"
assert "the brief reaches opencode as an absolute path" \
  grep -q -- "-f $FIX/.advisor/briefs/001-test.md" "$FIX/.advisor/runs/001-test-r1.log"

echo "test: install.sh links the files and reports whether the executor resolves"
INSTALL="$ROOT/install.sh"
H_OK="$(mktemp -d)"
HOME="$H_OK" OPENCODE_BIN="$STUBDIR/stub-opencode" "$INSTALL" >/dev/null 2>&1
check "install with a resolvable executor" 0 $?
assert "the agent file is linked into the global config" [ -L "$H_OK/.config/opencode/agent/executor.md" ]
H_BAD="$(mktemp -d)"
HOME="$H_BAD" OPENCODE_BIN="$STUBDIR/stub-opencode" STUB_NO_AGENT=1 "$INSTALL" >/dev/null 2>&1
check "install when the executor does not resolve" 1 $?

echo "test: not a git repo -> 11"
NOREPO="$(mktemp -d)"; cd "$NOREPO"
mkdir -p .advisor/briefs; echo x > .advisor/briefs/001-test.md
"$DISPATCH" --brief .advisor/briefs/001-test.md >/dev/null 2>&1
check "not a repo" 11 $?

echo "test: dirty tree -> 12"
new_fixture
echo "uncommitted change" >> file.txt
"$DISPATCH" --brief .advisor/briefs/001-test.md >/dev/null 2>&1
check "dirty tree" 12 $?

echo "test: untracked .advisor/ does NOT count as dirty -> 0"
new_fixture
echo "new brief" > .advisor/briefs/002-new.md
"$DISPATCH" --brief .advisor/briefs/002-new.md >/dev/null 2>&1
check "advisor dir ignored by dirty check" 0 $?

echo "test: missing brief -> 13"
new_fixture
"$DISPATCH" --brief .advisor/briefs/nope.md >/dev/null 2>&1
check "missing brief" 13 $?

echo "test: happy path logs the run and reports the executor's edit"
new_fixture
OUT="$(STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief .advisor/briefs/001-test.md 2>&1)"
RC=$?
check "happy path exit" 0 $RC
# Assert consequences, not the stub's own exit code: the log must capture what
# opencode was actually asked to do, and the diff must surface the stub's edit.
if grep -q -- '--agent executor' "$FIX/.advisor/runs/001-test-r1.log"; then
  echo "  PASS: log captured the invocation"; PASS=$((PASS+1))
else
  echo "  FAIL: log missing or did not capture the invocation"; FAIL=$((FAIL+1))
fi
if echo "$OUT" | grep -q 'file.txt'; then
  echo "  PASS: diff reported the edited file"; PASS=$((PASS+1))
else
  echo "  FAIL: diff did not report the edited file"; FAIL=$((FAIL+1))
fi

echo "test: message after -f is passed as a message, not a filename"
new_fixture
# The real opencode CLI declares -f/--file as a yargs array option, so it
# greedily swallows positionals after it. If dispatch.sh ever regresses to
# putting the message right after -f with no -- terminator, the stub (which
# mirrors that array behaviour) will reject the message text as a missing
# file and opencode will exit nonzero before the executor is ever invoked.
OUT="$(STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief .advisor/briefs/001-test.md 2>&1)"
RC=$?
check "dispatch succeeds with -- terminator in place" 0 $RC
LOGFILE="$FIX/.advisor/runs/001-test-r1.log"
if grep -q -- '-- Implement the attached brief\. Follow it exactly\.' "$LOGFILE"; then
  echo "  PASS: message reached the stub after a -- terminator, not as a filename"; PASS=$((PASS+1))
else
  echo "  FAIL: message did not appear after -- in the logged invocation"; FAIL=$((FAIL+1))
fi
if grep -q 'File not found' "$LOGFILE"; then
  echo "  FAIL: stub rejected the message text as a missing file"; FAIL=$((FAIL+1))
else
  echo "  PASS: stub did not reject the message as a missing file"; PASS=$((PASS+1))
fi

echo "test: --message replaces the default instruction so a delta round says so"
new_fixture
STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief .advisor/briefs/001-test.md >/dev/null 2>&1
STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief .advisor/briefs/001-test.md --round 2 --continue \
  --message "Apply the '## Round 2 delta' section at the end of the attached brief. Do not redo the rest." \
  >/dev/null 2>&1
DELTALOG="$FIX/.advisor/runs/001-test-r2.log"
if grep -q -- "-- Apply the '## Round 2 delta' section" "$DELTALOG"; then
  echo "  PASS: the delta message reached opencode after the -- terminator"; PASS=$((PASS+1))
else
  echo "  FAIL: --message did not reach opencode"; FAIL=$((FAIL+1))
fi
if grep -q 'Implement the attached brief' "$DELTALOG"; then
  echo "  FAIL: the default message was sent as well -- --message must replace it"; FAIL=$((FAIL+1))
else
  echo "  PASS: the default 'implement it all' instruction was replaced, not appended"; PASS=$((PASS+1))
fi

if [ "$MAJOR" = 1 ]; then
echo "test: 1.x: a failing 'agent list' is refused -> 14, and the refusal names OpenCode's error"
new_fixture
ERRFILE="$(mktemp)"
STUB_AGENT_LIST_ERROR="no such column: project_id" "$DISPATCH" --brief .advisor/briefs/001-test.md >/dev/null 2>"$ERRFILE"
check "agent list fails" 14 $?
assert "the message carries the error, not just 'not resolved'" grep -q 'no such column' "$ERRFILE"
fi

echo "test: executor agent does not resolve -> 14, and nothing was edited"
new_fixture
STUB_NO_AGENT=1 STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief .advisor/briefs/001-test.md >/dev/null 2>&1
check "unresolved executor agent" 14 $?
# OpenCode resolves the agent before it calls a model, so the refusal comes
# from the run's own log. The stub's edit runs after resolution: if it
# happened, the agent was never really refused.
if [ "$MAJOR" = 2 ]; then
  assert "the log names the missing agent" grep -q 'Agent not found: "executor"' "$FIX/.advisor/runs/001-test-r1.log"
else
  refute "1.x refuses in the preflight, so no run log exists" [ -e "$FIX/.advisor/runs/001-test-r1.log" ]
fi
refute "the stub's edit never landed, so the executor never ran" grep -q 'edited by stub' "$FIX/file.txt"

echo "test: executor failure -> 20"
new_fixture
STUB_EXIT=1 "$DISPATCH" --brief .advisor/briefs/001-test.md >/dev/null 2>&1
check "executor nonzero" 20 $?

echo "test: an executor that refuses the brief exits 19, not 0, and still shows the report"
new_fixture
OUT="$(STUB_PROBLEM="the brief names a file that does not exist" "$DISPATCH" --brief .advisor/briefs/001-test.md 2>&1)"
check "BRIEF PROBLEM in the log" 19 $?
assert "the report still prints, so the advisor sees what was and was not changed" \
  grep -q '=== diff --stat' <<<"$OUT"

echo "test: timeout -> 24"
new_fixture
STUB_HANG=5 "$DISPATCH" --brief .advisor/briefs/001-test.md --timeout 1 >/dev/null 2>&1
check "timeout" 24 $?

echo "test: a timeout is reported as 24 even when the executor exits 130 on TERM, as the real CLI does"
new_fixture
STUB_TERM_EXIT=130 STUB_HANG=30 "$DISPATCH" --brief .advisor/briefs/001-test.md --timeout 1 >/dev/null 2>&1
check "timeout with a 130 exit on TERM" 24 $?

echo "test: a timeout kills the executor's whole process group"
new_fixture
# A real executor spawns subprocesses. Signalling only opencode leaves them
# orphaned with edit and bash permissions intact, still mutating the repo
# while the advisor reads the diff. `sleep 593` stands in for one.
PIDFILE="$FIX/child.pid"
STUB_CHILD=593 STUB_CHILD_PIDFILE="$PIDFILE" STUB_HANG=30 \
  "$DISPATCH" --brief .advisor/briefs/001-test.md --timeout 1 >/dev/null 2>&1
check "timeout still maps to 24" 24 $?
if [ -s "$PIDFILE" ]; then
  echo "  PASS: the run really did spawn a child (precondition)"; PASS=$((PASS+1))
else
  echo "  FAIL: no child was spawned -- the orphan check below proves nothing"; FAIL=$((FAIL+1))
fi
CHILD_PID="$(cat "$PIDFILE" 2>/dev/null)"
sleep 1   # let the TERM/KILL escalation land
if [ -n "$CHILD_PID" ] && kill -0 "$CHILD_PID" 2>/dev/null; then
  echo "  FAIL: orphaned executor child $CHILD_PID survived the timeout"; FAIL=$((FAIL+1))
  kill -KILL "$CHILD_PID" 2>/dev/null   # never leave it behind for the next test
else
  echo "  PASS: the executor's child died with the group"; PASS=$((PASS+1))
fi

echo "test: a timeout also kills a child that moved to its own process group"
new_fixture
# An executor's shell command can leave the group (setsid). A group kill alone
# misses it; the tree captured before the signal must catch it.
PIDFILE="$FIX/child-newgroup.pid"
STUB_CHILD=593 STUB_CHILD_NEWGROUP=1 STUB_CHILD_PIDFILE="$PIDFILE" STUB_HANG=30 \
  "$DISPATCH" --brief .advisor/briefs/001-test.md --timeout 1 >/dev/null 2>&1
check "timeout still maps to 24" 24 $?
CHILD_PID="$(cat "$PIDFILE" 2>/dev/null)"
sleep 1
if [ -n "$CHILD_PID" ] && kill -0 "$CHILD_PID" 2>/dev/null; then
  echo "  FAIL: a child that left the process group survived the timeout"; FAIL=$((FAIL+1))
  kill -KILL "$CHILD_PID" 2>/dev/null
else
  echo "  PASS: the child that left the process group died"; PASS=$((PASS+1))
fi

echo "test: a continuation resumes the executor's session: by id on 2.x, by -c on 1.x"
new_fixture
# Round 1 first: a continuation needs the baseline commit and session round 1 records.
STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief .advisor/briefs/001-test.md >/dev/null 2>&1
STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief .advisor/briefs/001-test.md --round 2 --continue >/dev/null 2>&1
if [ "$MAJOR" = 1 ]; then
  assert "1.x: round 2 passes -c" grep -q -- ' -c ' "$FIX/.advisor/runs/001-test-r2.log"
  refute "1.x: no --session flag" grep -q -- '--session' "$FIX/.advisor/runs/001-test-r2.log"
else
  SESSION1="$(grep -oE -- '--session ses_[0-9a-f]+' "$FIX/.advisor/runs/001-test-r1.log" | head -1)"
  SESSION2="$(grep -oE -- '--session ses_[0-9a-f]+' "$FIX/.advisor/runs/001-test-r2.log" | head -1)"
  assert "round 1 starts a session with a generated ses_ id" [ -n "$SESSION1" ]
  check "round 2 resumes the same session" "$SESSION1" "$SESSION2"
  refute "no -c anywhere in the continuation" grep -q -- ' -c ' "$FIX/.advisor/runs/001-test-r2.log"
fi

echo "test: a correction round runs on the tree round 1 dirtied, but a new round 1 still refuses"
new_fixture
# Round 1 on a clean tree. The stub edits a tracked file, so afterwards the
# tree is necessarily dirty -- which is the whole point: before the BASE fix,
# every correction round died in preflight with 12 and the CORRECT verdict
# was unreachable.
STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief .advisor/briefs/001-test.md >/dev/null 2>&1
check "round 1 on a clean tree" 0 $?
# Guard against a vacuous test: if the round left the tree clean, the next
# assertion would pass for the wrong reason.
if [ -n "$(git status --porcelain | grep -v '\.advisor/')" ]; then
  echo "  PASS: round 1 left the tree dirty (precondition for the next check)"; PASS=$((PASS+1))
else
  echo "  FAIL: round 1 left the tree clean -- the continuation check below proves nothing"; FAIL=$((FAIL+1))
fi
STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief .advisor/briefs/001-test.md --round 2 --continue >/dev/null 2>&1
check "continuation round on a dirty tree" 0 $?
# Starting a fresh delegation on that same dirty tree must still be refused:
# the fix relaxes nothing about beginning a round-1 run.
"$DISPATCH" --brief .advisor/briefs/001-test.md >/dev/null 2>&1
check "new round 1 on the dirty tree still refused" 12 $?

echo "test: continuation with no recorded baseline -> 15"
new_fixture
# No round 1 was ever run here, so .advisor/runs/001-test-base does not exist.
"$DISPATCH" --brief .advisor/briefs/001-test.md --round 2 --continue >/dev/null 2>&1
check "continuation without a recorded base" 15 $?

echo "test: the diff is pinned to the recorded base, not to the working tree"
new_fixture
STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief .advisor/briefs/001-test.md >/dev/null 2>&1
# Stage round 1's change. A bare `git diff` now shows nothing at all, so a
# diff that is not pinned to BASE would hide the work under review.
git add -A
OUT="$(STUB_EXIT=0 "$DISPATCH" --brief .advisor/briefs/001-test.md --round 2 --continue 2>&1)"
if [ -z "$(git --no-pager diff --stat)" ]; then
  echo "  PASS: unpinned 'git diff' is empty here (precondition)"; PASS=$((PASS+1))
else
  echo "  FAIL: unpinned 'git diff' is non-empty -- this test cannot discriminate"; FAIL=$((FAIL+1))
fi
if echo "$OUT" | grep -q 'file.txt'; then
  echo "  PASS: diff against BASE still shows the staged round-1 change"; PASS=$((PASS+1))
else
  echo "  FAIL: diff lost the staged round-1 change"; FAIL=$((FAIL+1))
fi

echo "test: .advisor/runs ignores itself so logs cannot be committed"
new_fixture
STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief .advisor/briefs/001-test.md >/dev/null 2>&1
rm -f .gitignore   # remove the repo-level ignore; the runs dir must stand alone
git add -A >/dev/null 2>&1
if git diff --cached --name-only | grep -q '\.advisor/runs/'; then
  echo "  FAIL: 'git add -A' staged a raw executor log"; FAIL=$((FAIL+1))
else
  echo "  PASS: 'git add -A' could not stage anything under .advisor/runs"; PASS=$((PASS+1))
fi

echo "test: a file the executor CREATES is surfaced, though git diff cannot show it"
new_fixture
OUT="$(STUB_CREATE="$FIX/created.txt" "$DISPATCH" --brief .advisor/briefs/001-test.md 2>&1)"
check "create-only round exits 0" 0 $?
# The diff half of the output must NOT mention the new file -- that is the
# whole defect: an advisor reading only the diff sees nothing. If this ever
# starts failing because git learned to show untracked files in a diff, the
# assertion below stops proving anything and must be revisited.
DIFF_PART="$(section "$OUT" 'diff --stat')"
UNTRACKED_PART="$(section "$OUT" 'new files')"
if printf '%s\n' "$DIFF_PART" | grep -q 'created.txt'; then
  echo "  FAIL: diff section named the new file -- this test no longer discriminates"; FAIL=$((FAIL+1))
else
  echo "  PASS: diff section is blind to the new file (precondition)"; PASS=$((PASS+1))
fi
if printf '%s\n' "$UNTRACKED_PART" | grep -q 'created.txt'; then
  echo "  PASS: untracked section surfaced the created file"; PASS=$((PASS+1))
else
  echo "  FAIL: created file appeared nowhere in dispatch's output"; FAIL=$((FAIL+1))
fi

echo "test: no new files -> new-files section says (none), and never lists the advisor's brief"
new_fixture
echo "new brief" > .advisor/briefs/002-new.md
OUT="$(STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief .advisor/briefs/002-new.md 2>&1)"
UNTRACKED_PART="$(section "$OUT" 'new files')"
if printf '%s\n' "$UNTRACKED_PART" | grep -q '(none)'; then
  echo "  PASS: reports (none) when the executor created nothing"; PASS=$((PASS+1))
else
  echo "  FAIL: untracked section did not report (none)"; FAIL=$((FAIL+1))
fi
if printf '%s\n' "$UNTRACKED_PART" | grep -q '\.advisor/'; then
  echo "  FAIL: untracked section listed the advisor's own brief"; FAIL=$((FAIL+1))
else
  echo "  PASS: the advisor's own untracked brief is excluded"; PASS=$((PASS+1))
fi

echo "test: dispatch through command substitution does not hang or leak sleep"
new_fixture
# Census orphaned sleep 600 processes (PPID 1 only, not system-wide)
before_pids=$(pgrep -P 1 -f '^sleep 600' | sort)
before=$(echo "$before_pids" | wc -l | tr -d ' ')
# Run dispatch through command substitution with default timeout
# (would hang if watchdog holds pipe; orphan would be unmistakable sleep 600)
OUT="$(STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief .advisor/briefs/001-test.md 2>&1)"
RC=$?
# Census after
after_pids=$(pgrep -P 1 -f '^sleep 600' | sort)
after=$(echo "$after_pids" | wc -l | tr -d ' ')
# Check exit code
if [ $RC -eq 0 ]; then
  echo "  PASS: command substitution completed with exit 0"; PASS=$((PASS+1))
else
  echo "  FAIL: command substitution returned $RC (expected 0)"; FAIL=$((FAIL+1))
fi
# Check that no orphaned sleep 600 processes were left behind.
# Compare the PID sets directly rather than counts: `echo "" | wc -l` is 1,
# not 0, so an empty-vs-one-orphan case would be indistinguishable by count
# alone (before=1, after=1 -> false PASS on a clean machine with one leak).
if [ "$before_pids" = "$after_pids" ]; then
  echo "  PASS: no orphaned sleep 600 processes"; PASS=$((PASS+1))
else
  # Report which PIDs are new orphans. printf (not echo "") keeps a blank
  # before_pids from introducing a spurious empty line into comm's input.
  new_orphans=$(comm -13 <(printf '%s\n' "$before_pids" | grep -v '^$') <(printf '%s\n' "$after_pids" | grep -v '^$'))
  echo "  FAIL: orphaned sleep 600 processes found (before: $before, after: $after); new PIDs: $new_orphans"; FAIL=$((FAIL+1))
fi

echo "test: a repository with no commits -> 16, distinct from 'not a repo'"
EMPTY="$(mktemp -d)"; cd "$EMPTY"; git init -q
mkdir -p .advisor/briefs; echo x > .advisor/briefs/001-test.md
"$DISPATCH" --brief .advisor/briefs/001-test.md >/dev/null 2>&1
check "no commits" 16 $?

echo "test: --continue on round 1, or a non-numeric round, is a malformed invocation -> 2"
new_fixture
"$DISPATCH" --brief .advisor/briefs/001-test.md --round 1 --continue >/dev/null 2>&1
check "--continue with --round 1" 2 $?
"$DISPATCH" --brief .advisor/briefs/001-test.md --round two >/dev/null 2>&1
check "--round two" 2 $?

echo "test: a later round WITHOUT --continue is a fresh start, so it refuses a dirty tree"
new_fixture
STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief .advisor/briefs/001-test.md >/dev/null 2>&1
"$DISPATCH" --brief .advisor/briefs/001-test.md --round 2 >/dev/null 2>&1
check "--round 2 alone on round 1's dirty tree" 12 $?
if [ "$MAJOR" = 2 ]; then
  S1="$(cat "$FIX/.advisor/runs/001-test-session")"
  # The refusal happens before a session is written, so round 1's id survives it.
  assert "round 1 recorded a session id" [ -n "$S1" ]
  assert "the refused fresh round left that session id in place" \
    [ "$(cat "$FIX/.advisor/runs/001-test-session")" = "$S1" ]
fi

echo "test: the executor moving a ref trips the wire -> 21, whatever the deny list missed"
new_fixture
# `sh -c` wraps the command, which is exactly what a prefix-anchored deny
# pattern cannot see. The check that catches it must be after the fact.
ERRFILE="$(mktemp)"
STUB_EDIT="$FIX/file.txt" STUB_RUN='sh -c "git commit -qam sneaky"' \
  "$DISPATCH" --brief .advisor/briefs/001-test.md >/dev/null 2>"$ERRFILE"
check "wrapped git commit" 21 $?
assert "the refusal names the moved ref" grep -q "refs/heads/" "$ERRFILE"
new_fixture
STUB_RUN='git tag sneaky' "$DISPATCH" --brief .advisor/briefs/001-test.md >/dev/null 2>&1
check "git tag" 21 $?
new_fixture
# Negative control: staging touches no ref, and the diff is pinned to the
# base, so it hides nothing. The wire must not trip on it.
STUB_EDIT="$FIX/file.txt" STUB_RUN='git add -A' \
  "$DISPATCH" --brief .advisor/briefs/001-test.md >/dev/null 2>&1
check "git add alone does not trip the wire" 0 $?

echo "test: a file the executor creates under .advisor/ is reported like any other"
new_fixture
OUT="$(STUB_CREATE="$FIX/.advisor/notes.md" "$DISPATCH" --brief .advisor/briefs/001-test.md 2>&1)"
assert ".advisor/notes.md is listed as new" lists "$(section "$OUT" 'new files')" '.advisor/notes.md'

echo "test: the executor editing the advisor's untracked brief is reported"
new_fixture
echo "new brief" > .advisor/briefs/002-new.md
OUT="$(STUB_EDIT="$FIX/.advisor/briefs/002-new.md" "$DISPATCH" --brief .advisor/briefs/002-new.md 2>&1)"
assert "the brief is listed as changed" lists "$(section "$OUT" 'pre-existing')" 'changed: .advisor/briefs/002-new.md'
assert "and not as new" [ "$(section "$OUT" 'new files')" = "(none)" ]

echo "test: new files accumulate across rounds, and a user's file dropped between rounds is not one"
new_fixture
STUB_CREATE="$FIX/a.txt" "$DISPATCH" --brief .advisor/briefs/001-test.md >/dev/null 2>&1
echo "mine" > scratch.txt
OUT="$(STUB_CREATE="$FIX/b.txt" "$DISPATCH" --brief .advisor/briefs/001-test.md --round 2 --continue 2>&1)"
NEW="$(section "$OUT" 'new files')"
assert "round 1's file is still reported on round 2" lists "$NEW" 'a.txt'
assert "round 2's file is reported" lists "$NEW" 'b.txt'
refute "the user's scratch file is not attributed to the executor" lists "$NEW" 'scratch.txt'
OUT="$(STUB_EDIT="$FIX/a.txt" "$DISPATCH" --brief .advisor/briefs/001-test.md --round 3 --continue 2>&1)"
assert "editing its own earlier file is not reported as pre-existing" \
  [ "$(section "$OUT" 'pre-existing')" = "(none)" ]

echo "test: rollback undoes the executor's work and nothing else"
new_fixture
STUB_EDIT="$FIX/file.txt" STUB_CREATE="$FIX/new/dir/x.txt" \
  "$DISPATCH" --brief .advisor/briefs/001-test.md >/dev/null 2>&1
echo "mine" > scratch.txt
echo "draft" > .advisor/briefs/002-next.md
"$ROLLBACK" --brief .advisor/briefs/001-test.md >/dev/null 2>&1
check "rollback exit" 0 $?
assert "the tracked edit is reverted" [ "$(cat file.txt)" = "baseline" ]
assert "the executor's file is deleted" [ ! -e new/dir/x.txt ]
assert "the directories it created are removed" [ ! -e new ]
assert "the user's untracked file survives" [ -f scratch.txt ]
assert "the advisor's untracked brief survives" [ -f .advisor/briefs/002-next.md ]

echo "test: rollback removes a new file the executor staged"
new_fixture
STUB_CREATE="$FIX/staged.txt" STUB_RUN='git add -A' \
  "$DISPATCH" --brief .advisor/briefs/001-test.md >/dev/null 2>&1
assert "precondition: the executor staged its file" git ls-files --error-unmatch staged.txt >/dev/null 2>&1
"$ROLLBACK" --brief .advisor/briefs/001-test.md >/dev/null 2>&1
assert "the staged file is gone" [ ! -e staged.txt ]
assert "the index matches the base again" git diff --cached --quiet

echo "test: rollback deletes only what is untracked inside the repo, whatever the ledger says"
new_fixture
STUB_CREATE="$FIX/x.txt" "$DISPATCH" --brief .advisor/briefs/001-test.md >/dev/null 2>&1
OUTSIDE="$(mktemp -d)/victim.txt"; echo keep > "$OUTSIDE"
# The ledger lives in a directory the executor can write to. A forged entry
# must not turn rollback into a delete-anything primitive.
printf '%s\nfile.txt\n' "$OUTSIDE" >> .advisor/runs/001-test-created
"$ROLLBACK" --brief .advisor/briefs/001-test.md >/dev/null 2>&1
assert "a path outside the repo survives" [ -f "$OUTSIDE" ]
assert "a tracked file named in the ledger is restored, not deleted" [ -f file.txt ]
assert "the genuine new file is still deleted" [ ! -e x.txt ]

echo "test: rollback refuses without a baseline -> 15, and when HEAD has moved -> 21"
new_fixture
"$ROLLBACK" --brief .advisor/briefs/001-test.md >/dev/null 2>&1
check "rollback with no recorded base" 15 $?
new_fixture
STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief .advisor/briefs/001-test.md >/dev/null 2>&1
git commit -qam "someone committed mid-delegation"
"$ROLLBACK" --brief .advisor/briefs/001-test.md >/dev/null 2>&1
check "rollback after HEAD moved" 21 $?
assert "and it changed nothing" grep -q 'edited by stub' file.txt

echo "test: a fresh round after rollback starts a fresh ledger"
new_fixture
STUB_CREATE="$FIX/old.txt" "$DISPATCH" --brief .advisor/briefs/001-test.md >/dev/null 2>&1
"$ROLLBACK" --brief .advisor/briefs/001-test.md >/dev/null 2>&1
OUT="$(STUB_CREATE="$FIX/fresh.txt" "$DISPATCH" --brief .advisor/briefs/001-test.md --round 2 2>&1)"
check "fresh round 2 on the rolled-back tree" 0 $?
assert "only this attempt's file is reported" [ "$(section "$OUT" 'new files')" = "fresh.txt" ]

echo "test: with no --model, the executor runs on the default model, passed explicitly"
new_fixture
STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief .advisor/briefs/001-test.md >/dev/null 2>&1
assert "argv carries -m with the default id" grep -q -- '-m opencode-go/deepseek-v4.1-flash' "$FIX/.advisor/runs/001-test-r1.log"

echo "test: a model name from the chat resolves to its id"
new_fixture
STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief .advisor/briefs/001-test.md --model "DeepSeek Pro" >/dev/null 2>&1
check "named model dispatches" 0 $?
assert "argv carries the resolved id, not the name" grep -q -- '-m opencode-go/deepseek-v4-pro' "$FIX/.advisor/runs/001-test-r1.log"

echo "test: a provider/model id passes through unchanged"
new_fixture
STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief .advisor/briefs/001-test.md --model opencode-go/deepseek-v4-pro >/dev/null 2>&1
assert "explicit id reaches argv" grep -q -- '-m opencode-go/deepseek-v4-pro' "$FIX/.advisor/runs/001-test-r1.log"

echo "test: an unknown model name is refused -> 17, before anything runs"
new_fixture
"$DISPATCH" --brief .advisor/briefs/001-test.md --model "gpt nine" >/dev/null 2>&1
check "unknown model name" 17 $?
assert "no run log: the executor was never invoked" [ ! -e "$FIX/.advisor/runs/001-test-r1.log" ]

echo "test: a model the provider does not offer is refused -> 17, before anything runs"
new_fixture
STUB_NO_MODEL=opencode-go/deepseek-v4.1-flash "$DISPATCH" --brief .advisor/briefs/001-test.md >/dev/null 2>&1
check "default model not offered" 17 $?
assert "no run log: the executor was never invoked" [ ! -e "$FIX/.advisor/runs/001-test-r1.log" ]

echo "test: the resolver maps names, refuses unknowns, and never guesses across versions"
RES="$ROOT/bin/resolve-model.sh"
assert "no argument gives the default" [ "$("$RES")" = "opencode-go/deepseek-v4.1-flash" ]
assert "'deepseek-flash' resolves" [ "$("$RES" deepseek-flash)" = "opencode-go/deepseek-v4.1-flash" ]
assert "'deepseek-v4-flash' does NOT resolve to v4.1" [ -z "$("$RES" deepseek-v4-flash 2>/dev/null)" ]
assert "unknown names exit 1 with nothing on stdout" \
  bash -c '[ -z "$("$1" nonsense 2>/dev/null)" ] && ! "$1" nonsense >/dev/null 2>&1' _ "$RES"

echo "test: the executor's frontmatter model matches the default, so the two cannot drift"
FM_MODEL="$(sed -n 's/^model: *//p' "$ROOT/agent/executor.md" | head -1)"
check_eq() { [ "$1" = "$2" ] && { echo "  PASS: $3"; PASS=$((PASS+1)); } || { echo "  FAIL: $3 (agent says '$1', resolver says '$2')"; FAIL=$((FAIL+1)); }; }
check_eq "$FM_MODEL" "$("$RES")" "executor.md model: equals the resolver default"

echo "test: SKILL.md documents every exit code and flag the scripts implement"
SKILL="$(dirname "$STUBDIR")/SKILL.md"
for code in $(grep -oE '^readonly EXIT_[A-Z_]+=[0-9]+' "$ROOT/bin/lib.sh" | grep -oE '[0-9]+$'); do
  if grep -q "^| $code |" "$SKILL"; then
    echo "  PASS: exit code $code is in the advisor's table"; PASS=$((PASS+1))
  else
    echo "  FAIL: the scripts can exit $code but SKILL.md never says what it means"; FAIL=$((FAIL+1))
  fi
done
for flag in $(cat "$DISPATCH" "$ROLLBACK" | grep -oE '^    --[a-z]+\)' | tr -d ' )' | sort -u); do
  if grep -q -- "$flag" "$SKILL"; then
    echo "  PASS: $flag is documented"; PASS=$((PASS+1))
  else
    echo "  FAIL: the scripts implement $flag but SKILL.md never mentions it"; FAIL=$((FAIL+1))
  fi
done

echo "test: the executor agent cannot run git commands that erase the diff"
AGENT="$(dirname "$STUBDIR")/agent/executor.md"   # STUBDIR is absolute; cwd is a fixture
# The advisor's whole verification is reading the diff. An executor that can
# commit, stash, checkout or reset empties that diff before the advisor looks.
for pat in 'git commit\*' 'git reset\*' 'git checkout\*' 'git restore\*' 'git switch\*' 'git stash\*' 'git clean\*' 'git push\*'; do
  if grep -qE "^ +\"$pat\": *deny" "$AGENT"; then
    echo "  PASS: ${pat%\\*} denied"; PASS=$((PASS+1))
  else
    echo "  FAIL: ${pat%\\*} is not denied in executor.md"; FAIL=$((FAIL+1))
  fi
done
# The executor must not read secrets through its read tool. OpenCode prepends
# `read *.env ask` by default, and an ask stalls a run with no terminal; the
# explicit deny has to come after the allow, because rules are last-match-wins.
for pat in '\*\.env' '\*\.env\.\*'; do
  if grep -qE "^ +\"$pat\": *deny" "$AGENT"; then
    echo "  PASS: read of ${pat//\\/} denied"; PASS=$((PASS+1))
  else
    echo "  FAIL: read of ${pat//\\/} is not denied in executor.md"; FAIL=$((FAIL+1))
  fi
done
refute "no read rule asks, which would stall a run with no terminal" grep -qE '"\*\.env[^"]*": *ask' "$AGENT"
# Non-git bash must still be allowed, or the executor cannot run tests.
if grep -qE '^ +"\*": *allow' "$AGENT"; then
  echo "  PASS: bash is otherwise allowed"; PASS=$((PASS+1))
else
  echo "  FAIL: bash '*' allow entry is missing -- the executor cannot run anything"; FAIL=$((FAIL+1))
fi
# A malformed permission block would silently break the agent, so parse the
# frontmatter when a YAML parser happens to be available. Skipped, never
# failed, where there is none: the suite must not grow a dependency.
if python3 -c 'import yaml' >/dev/null 2>&1; then
  if python3 - "$AGENT" <<'PYEOF'
import sys, yaml
fm = open(sys.argv[1]).read().split('---')[1]
d = yaml.safe_load(fm)
b = d['permission']['bash']
assert isinstance(b, dict) and b['*'] == 'allow', b
assert b['git commit*'] == 'deny', b
PYEOF
  then
    echo "  PASS: executor.md frontmatter parses and the bash map is well-formed"; PASS=$((PASS+1))
  else
    echo "  FAIL: executor.md frontmatter does not parse as expected"; FAIL=$((FAIL+1))
  fi
else
  echo "  SKIP: no yaml parser available for the frontmatter check"
fi

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
