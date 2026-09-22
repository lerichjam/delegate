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
STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief .advisor/briefs/001-test.md --round 2 --continue >/dev/null 2>&1
if grep -q -- ' -c ' "$FIX/.advisor/runs/001-test-r2.log"; then
  echo "  PASS: -c forwarded"; PASS=$((PASS+1))
else
  echo "  FAIL: -c not forwarded"; FAIL=$((FAIL+1))
fi

echo "test: dispatch through command substitution does not hang or leak sleep"
new_fixture
# Census sleep 600 processes before (using system-wide view, not children of test script)
before=$(pgrep -f '^sleep 600' | wc -l | tr -d ' ')
# Run dispatch through command substitution with default timeout
# (would hang if watchdog holds pipe; orphan would be unmistakable sleep 600)
OUT="$(STUB_EDIT="$FIX/file.txt" "$DISPATCH" --brief .advisor/briefs/001-test.md 2>&1)"
RC=$?
# Census after
after=$(pgrep -f '^sleep 600' | wc -l | tr -d ' ')
# Check exit code
if [ $RC -eq 0 ]; then
  echo "  PASS: command substitution completed with exit 0"; PASS=$((PASS+1))
else
  echo "  FAIL: command substitution returned $RC (expected 0)"; FAIL=$((FAIL+1))
fi
# Check that no orphaned sleep 600 processes were left behind
if [ "$after" -eq "$before" ]; then
  echo "  PASS: no orphaned sleep 600 processes"; PASS=$((PASS+1))
else
  echo "  FAIL: orphaned sleep 600 processes found (before: $before, after: $after)"; FAIL=$((FAIL+1))
fi

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
