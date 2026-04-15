#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="${TMPDIR:-/tmp}/ralph-smoke-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$SANDBOX"

for f in PROMPT.md ralph.sh ralph-prep.sh ralph-lib.sh RALPH-CC.md; do
    ln -s "$REPO_DIR/$f" "$SANDBOX/$f"
done

cp "$REPO_DIR/tests/tasks.json" "$SANDBOX/tasks.json"

cat <<EOF
Sandbox ready: $SANDBOX

Headless mode:
  cd $SANDBOX && ./ralph.sh --max-iterations 3

Claude Code mode:
  cd $SANDBOX && claude
  then in the session: follow RALPH-CC.md, max-iterations 3
EOF
