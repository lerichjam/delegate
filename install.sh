#!/usr/bin/env bash
# Symlinks the delegate toolkit's two externally-located files into their
# global homes, so this repo stays the single source of truth.
set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OC="${OPENCODE_BIN:-opencode}"

# link <source> <target> -- symlink, but never over a file that is not already
# this repository's link: someone else's `executor` agent or `/delegate`
# command would be silently replaced.
link() {
  if [ -e "$2" ] || [ -L "$2" ]; then
    if [ "$(readlink "$2")" != "$1" ]; then
      echo "ERROR: $2 already exists and is not a link to $1. Move it aside, then re-run." >&2
      exit 1
    fi
  fi
  ln -sf "$1" "$2"
}

mkdir -p ~/.config/opencode/agent ~/.claude/commands
link "$SRC/agent/executor.md"   ~/.config/opencode/agent/executor.md
link "$SRC/command/delegate.md" ~/.claude/commands/delegate.md

echo "linked:"
ls -l ~/.config/opencode/agent/executor.md ~/.claude/commands/delegate.md

command -v "$OC" >/dev/null 2>&1 || {
  echo "WARN: '$OC' not found. Install OpenCode 1.x or 2.x, or set OPENCODE_BIN." >&2
  exit 1
}
# shellcheck source=bin/lib.sh
. "$SRC/bin/lib.sh"
MAJOR="$(oc_major "$OC")"
case "$MAJOR" in
  1|2) ;;
  *) echo "WARN: '$OC' is not a supported OpenCode (1.x or 2.x)." >&2; exit 1 ;;
esac

if [ "$MAJOR" -eq 1 ]; then
  # 1.x: the agent is listed by `agent list`. The output is written to a file
  # because piping it truncates it at 1 MiB.
  AGENTS_TMP="$(mktemp)"
  if oc_v1_agent_listed "$OC" "$AGENTS_TMP"; then
    echo "OK: OpenCode 1.x resolves the 'executor' agent"
    rm -f "$AGENTS_TMP"
  else
    WHY="$(oc_error_line "$AGENTS_TMP")"
    echo "WARN: OpenCode does not list 'executor'${WHY:+: $WHY}. Check the frontmatter and the symlink above." >&2
    rm -f "$AGENTS_TMP"
    exit 1
  fi
  exit 0
fi

# 2.x: the probe runs a model name that does not exist. OpenCode resolves the
# agent first, so a reply of "Model unavailable" means the agent was found and
# no model call was made. The run happens in a scratch directory, so the session
# it leaves behind belongs to a throwaway project.
PROBE_DIR="$(mktemp -d)"
OUT="$(mktemp)"
( cd "$PROBE_DIR" && "$OC" run --standalone --agent executor -m delegate-probe/none -- "probe" ) >"$OUT" 2>&1
if grep -q 'Agent not found: "executor"' "$OUT"; then
  echo "WARN: OpenCode does not find the 'executor' agent. Check $SRC/agent/executor.md and the symlink above." >&2
  rm -rf "$PROBE_DIR" "$OUT"
  exit 1
fi
if grep -q 'Model unavailable' "$OUT"; then
  echo "OK: OpenCode 2.x resolves the 'executor' agent"
  rm -rf "$PROBE_DIR" "$OUT"
else
  echo "WARN: unexpected output from the agent probe; the run log is kept at $OUT" >&2
  rm -rf "$PROBE_DIR"
  exit 1
fi
