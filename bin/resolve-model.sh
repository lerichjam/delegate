#!/usr/bin/env bash
# resolve-model.sh [name] — print the provider/model id for a name the user used.
# No name means the default: the `model:` in agent/executor.md, the one place it
# is set. A provider/model id passes through unchanged; dispatch.sh still checks
# it against `opencode models`.
# Exit 1 with nothing on stdout when the name is not in config/models.tsv.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TABLE="$HERE/config/models.tsv"

# Case-insensitive, ignoring everything but letters and digits, so
# "DeepSeek Flash", "deepseek-flash" and "deepseekflash" all match.
norm() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9'; }

NAME="${1:-$(sed -n 's/^model: *//p' "$HERE/agent/executor.md" | head -1)}"
case "$NAME" in
  */*) printf '%s\n' "$NAME"; exit 0 ;;
esac

WANT="$(norm "$NAME")"
[ -n "$WANT" ] || { echo "resolve-model: empty model name" >&2; exit 1; }

while IFS=$'\t' read -r id names; do
  case "$id" in ''|\#*) continue ;; esac
  [ "$(norm "$id")" = "$WANT" ] && { printf '%s\n' "$id"; exit 0; }
  IFS=',' read -r -a aliases <<<"$names"
  for alias_name in "${aliases[@]}"; do
    [ "$(norm "$alias_name")" = "$WANT" ] && { printf '%s\n' "$id"; exit 0; }
  done
done < "$TABLE"

echo "resolve-model: unknown model '$NAME'" >&2
exit 1
