#!/usr/bin/env bash
set -euo pipefail

# Per-iteration bookkeeping + prompt builder for RALPH-CC.md.
# Prints the filled prompt to stdout so a Claude Code session can capture
# it and pass it to Agent(). Diagnostics go to stderr.

# --- Defaults ---
PROMPT_FILE="PROMPT.md"
TASK_FILE="tasks.json"
NOTEBOOK_DIR=".lnb"
CONTEXT=""
ARCHIVE_DIR="archive"
ITERATION="1"
MAX_ITERATIONS=""
LAST_BRANCH_FILE=".ralph-last-branch"

# Resolve symlinks so SHARED_DIR is correct when the runner is symlinked
# into $PATH. Walks a chain of relative or absolute symlinks.
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
    DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
SHARED_DIR="$SCRIPT_DIR/../shared"

usage() {
    cat <<'EOF' >&2
Usage: ralph-prep.sh [OPTIONS]

Runs one iteration of ralph bookkeeping (archive, notebook init, history
query, prompt fill) and prints the filled PROMPT.md to stdout. Intended
to be invoked by a Claude Code session that then passes the stdout to
the Agent() tool — see RALPH-CC.md.

Options:
  --prompt FILE           Prompt template (default: PROMPT.md)
  --task-file FILE        Task file with stories (default: tasks.json)
  --notebook DIR          Lab-notebook directory (default: .lnb)
  --context SLUG          Notebook context (default: derived from branch)
  --archive-dir DIR       Where to archive old runs (default: archive/)
  --iteration N           Iteration number, used in the start log entry
                          (default: 1)
  --max-iterations N      Iteration cap, recorded alongside --iteration
                          in the start log entry (optional). Does not
                          affect the loop — the Claude Code session
                          enforces the cap via RALPH-CC.md.
  -h, --help              Show this help
EOF
    exit 0
}

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --prompt)          PROMPT_FILE="$2"; shift 2 ;;
        --task-file)       TASK_FILE="$2"; shift 2 ;;
        --notebook)        NOTEBOOK_DIR="$2"; shift 2 ;;
        --context)         CONTEXT="$2"; shift 2 ;;
        --archive-dir)     ARCHIVE_DIR="$2"; shift 2 ;;
        --iteration)       ITERATION="$2"; shift 2 ;;
        --max-iterations)  MAX_ITERATIONS="$2"; shift 2 ;;
        -h|--help)         usage ;;
        *)                 echo "Unknown option: $1" >&2; usage ;;
    esac
done

# --- Validate ---
if [[ ! -f "$PROMPT_FILE" ]]; then
    echo "Error: Prompt file '$PROMPT_FILE' not found." >&2
    echo "Copy the template: cp $SHARED_DIR/PROMPT.md ." >&2
    exit 1
fi

if [[ ! -f "$TASK_FILE" ]]; then
    echo "Error: Task file '$TASK_FILE' not found." >&2
    echo "Copy the example: cp $SHARED_DIR/tasks.json.example tasks.json" >&2
    exit 1
fi

# --- Load shared helpers ---
source "$SHARED_DIR/ralph-lib.sh"

# --- Read task file metadata ---
BRANCH=$(read_task_meta "branch")
PROJECT=$(read_task_meta "project")

if [[ -z "$CONTEXT" ]]; then
    if [[ -n "$BRANCH" ]]; then
        CONTEXT="$BRANCH"
    elif [[ -n "$PROJECT" ]]; then
        CONTEXT="$PROJECT"
    else
        CONTEXT="ralph-dev"
    fi
fi

# --- Bookkeeping ---
# archive_previous_run and ensure_notebook are both idempotent — safe to
# call on every iteration. archive_previous_run only actually archives
# when BRANCH differs from $LAST_BRANCH_FILE's contents.
archive_previous_run
ensure_notebook

if [[ -n "$MAX_ITERATIONS" ]]; then
    log_to_notebook "start" "ralph-cc: starting iteration $ITERATION/$MAX_ITERATIONS"
else
    log_to_notebook "start" "ralph-cc: starting iteration $ITERATION"
fi

# --- Emit filled prompt to stdout ---
history=$(query_recent_history)
build_prompt "$history"
