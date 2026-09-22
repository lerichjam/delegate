#!/usr/bin/env bash
# Plain-bash test suite for dispatch.sh. No bats on this machine.
set -uo pipefail

DISPATCH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/dispatch.sh"
STUBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0; FAIL=0

check() { # check <name> <expected-code> <actual-code>
  if [ "$2" = "$3" ]; then
    echo "  PASS: $1"; PASS=$((PASS+1))
  else
    echo "  FAIL: $1 (expected $2, got $3)"; FAIL=$((FAIL+1))
  fi
}

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

echo "test: executor failure -> 20"
new_fixture
STUB_EXIT=1 "$DISPATCH" --brief .advisor/briefs/001-test.md >/dev/null 2>&1
check "executor nonzero" 20 $?

echo "test: timeout -> 24"
new_fixture
STUB_HANG=5 "$DISPATCH" --brief .advisor/briefs/001-test.md --timeout 1 >/dev/null 2>&1
check "timeout" 24 $?

echo "test: --continue passes -c to opencode"
new_fixture
# Round 1 first: a continuation needs the baseline commit round 1 records.
STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief .advisor/briefs/001-test.md >/dev/null 2>&1
STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief .advisor/briefs/001-test.md --round 2 --continue >/dev/null 2>&1
if grep -q -- ' -c ' "$FIX/.advisor/runs/001-test-r2.log"; then
  echo "  PASS: -c forwarded"; PASS=$((PASS+1))
else
  echo "  FAIL: -c not forwarded"; FAIL=$((FAIL+1))
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
DIFF_PART="$(printf '%s\n' "$OUT" | sed -n '/=== diff --stat/,/=== untracked/p')"
UNTRACKED_PART="$(printf '%s\n' "$OUT" | sed -n '/=== untracked/,/=== end ===/p')"
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

echo "test: no new files -> untracked section says (none), and never lists .advisor/"
new_fixture
echo "new brief" > .advisor/briefs/002-new.md
OUT="$(STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief .advisor/briefs/002-new.md 2>&1)"
UNTRACKED_PART="$(printf '%s\n' "$OUT" | sed -n '/=== untracked/,/=== end ===/p')"
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

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
