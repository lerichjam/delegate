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

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
