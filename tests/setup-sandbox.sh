#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="${TMPDIR:-/tmp}/ralph-smoke-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$SANDBOX"

# The sandbox mimics a user's project dir: only PROMPT.md + tasks.json.
# Runners are invoked by absolute path from $REPO_DIR, exercising the
# zero-copy invocation model that cc-headless and cc modes both use.
ln -s "$REPO_DIR/shared/PROMPT.md" "$SANDBOX/PROMPT.md"
cp "$REPO_DIR/tests/tasks.json" "$SANDBOX/tasks.json"

cat <<EOF
Sandbox ready: $SANDBOX

Headless mode:
  cd $SANDBOX && $REPO_DIR/cc-headless/ralph.sh --max-iterations 3

Claude Code mode:
  cd $SANDBOX && claude
  then in the session: follow $REPO_DIR/cc/RALPH-CC.md, max-iterations 3
EOF
