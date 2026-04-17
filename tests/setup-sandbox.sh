#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="${TMPDIR:-/tmp}/ralph-smoke-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$SANDBOX"

# The sandbox mimics a user's project dir: just tasks.json. The runners
# resolve shared/PROMPT.md from the repo automatically, so a project
# needs no local prompt copy unless it wants to customize the template.
cp "$REPO_DIR/tests/tasks.json" "$SANDBOX/tasks.json"

cat <<EOF
Sandbox ready: $SANDBOX

Headless mode:
  cd $SANDBOX && ralph --max-iterations 3

Claude Code mode:
  cd $SANDBOX && claude
  then in the session: /ralph-lnb max-iterations 3

Not installed yet? Run $REPO_DIR/install.sh first. For headless-only
use without install, the script can be invoked by absolute path:
  $REPO_DIR/cc-headless/ralph.sh --max-iterations 3
EOF
