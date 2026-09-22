#!/usr/bin/env bash
# Symlinks the delegate toolkit's two externally-located files into their
# global homes, so this repo stays the single source of truth.
set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p ~/.config/opencode/agent ~/.claude/commands
ln -sf "$SRC/agent/executor.md"    ~/.config/opencode/agent/executor.md
ln -sf "$SRC/command/delegate.md"  ~/.claude/commands/delegate.md

echo "linked:"
ls -l ~/.config/opencode/agent/executor.md ~/.claude/commands/delegate.md

if opencode agent list 2>/dev/null | grep -q '^executor'; then
  echo "OK: opencode resolves the 'executor' agent"
else
  echo "WARN: opencode does not list 'executor' — check the frontmatter" >&2
  exit 1
fi
