#!/usr/bin/env bash
set -euo pipefail

# --- Defaults ---
MAX_ITERATIONS=10
PROMPT_FILE="PROMPT.md"
TASK_FILE="tasks.json"
NOTEBOOK_DIR=".lnb"
CONTEXT=""
ARCHIVE_DIR="archive"
COMPLETION_PROMISE="DONE"
ALL_DONE_PROMISE="ALL_DONE"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'EOF'
Usage: ralph.sh [OPTIONS]

Autonomous agent loop for code development tasks.
Spawns a fresh Claude instance per iteration, tracking state via a task
file (tasks.json) and a lab-notebook.

Options:
  --max-iterations N      Safety cap (default: 10)
  --prompt FILE           Prompt template (default: PROMPT.md)
  --task-file FILE        Task file with stories (default: tasks.json)
  --notebook DIR          Lab-notebook directory (default: .lnb)
  --context SLUG          Notebook context (default: derived from branch)
  --archive-dir DIR       Where to archive old runs (default: archive/)
  -h, --help              Show this help

The loop exits when:
  - Agent outputs <promise>ALL_DONE</promise> (all stories complete)
  - Max iterations reached
  - Agent exits with non-zero status

Each iteration the agent completes one story and outputs <promise>DONE</promise>.

Example:
  ralph.sh --max-iterations 5 --task-file tasks.json
EOF
    exit 0
}

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --max-iterations)  MAX_ITERATIONS="$2"; shift 2 ;;
        --prompt)          PROMPT_FILE="$2"; shift 2 ;;
        --task-file)       TASK_FILE="$2"; shift 2 ;;
        --notebook)        NOTEBOOK_DIR="$2"; shift 2 ;;
        --context)         CONTEXT="$2"; shift 2 ;;
        --archive-dir)     ARCHIVE_DIR="$2"; shift 2 ;;
        -h|--help)         usage ;;
        *)                 echo "Unknown option: $1" >&2; usage ;;
    esac
done

# --- Validate ---
if [[ ! -f "$PROMPT_FILE" ]]; then
    echo "Error: Prompt file '$PROMPT_FILE' not found." >&2
    echo "Copy the template: cp $SCRIPT_DIR/PROMPT.md ." >&2
    exit 1
fi

if [[ ! -f "$TASK_FILE" ]]; then
    echo "Error: Task file '$TASK_FILE' not found." >&2
    echo "Copy the example: cp $SCRIPT_DIR/tasks.json.example tasks.json" >&2
    exit 1
fi

# Resolve the claude command
if command -v claude &>/dev/null; then
    CLAUDE_CMD="claude"
elif command -v claude-code &>/dev/null; then
    CLAUDE_CMD="claude-code"
else
    echo "Error: claude (or claude-code) not found in PATH." >&2
    exit 1
fi

# --- Shared helpers ---
LAST_BRANCH_FILE=".ralph-last-branch"
source "$SCRIPT_DIR/ralph-lib.sh"

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

# --- Output formatting ---
format_stream() {
    jq --unbuffered -r '
        if .type == "assistant" then
            (.message.content[]? | select(.type == "text") | .text)
        elif .type == "result" then
            "\n=== Result (cost: \(.cost_usd // "?")) ==="
        elif .type == "tool_use" then
            ">>> \(.tool // .name): \(.input.command // .input.pattern // .input.file_path // "" | tostring | .[0:120])"
        else
            empty
        end
    ' 2>/dev/null
}

# --- Main ---
archive_previous_run
ensure_notebook

TMPFILE=$(mktemp /tmp/ralph-output.XXXXXX)
trap 'rm -f "$TMPFILE"' EXIT

echo "=== Ralph Wiggum ==="
echo "Project:    ${PROJECT:-<none>}"
echo "Branch:     ${BRANCH:-<none>}"
echo "Context:    $CONTEXT"
echo "Task file:  $TASK_FILE"
echo "Notebook:   $NOTEBOOK_DIR"
echo "Max iter:   $MAX_ITERATIONS"
echo "============="

for i in $(seq 1 "$MAX_ITERATIONS"); do
    echo ""
    echo "--- Iteration $i / $MAX_ITERATIONS ---"

    # Harness does RECALL: query notebook and inject into prompt
    history=$(query_recent_history)
    prompt=$(build_prompt "$history")

    log_to_notebook "start" "ralph.sh: starting iteration $i/$MAX_ITERATIONS"

    # Run the agent
    exit_code=0
    $CLAUDE_CMD \
        --permission-mode acceptEdits \
        --print --output-format stream-json \
        "$prompt" 2>&1 \
        | tee "$TMPFILE" \
        | format_stream || exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        echo "Agent exited with code $exit_code"
        log_to_notebook "blocker" "ralph.sh: iteration $i ended with exit code $exit_code"
        echo "Stopping due to non-zero exit."
        break
    fi

    # Check for promises (ALL_DONE first since it also contains DONE)
    if grep -q "<promise>${ALL_DONE_PROMISE}</promise>" "$TMPFILE" 2>/dev/null; then
        echo ""
        echo "=== All stories complete! ==="
        log_to_notebook "done" "ralph.sh: all stories complete at iteration $i"
        break
    elif grep -q "<promise>${COMPLETION_PROMISE}</promise>" "$TMPFILE" 2>/dev/null; then
        echo ""
        echo "=== Iteration $i: story complete, continuing ==="
        log_to_notebook "done" "ralph.sh: story completed at iteration $i, continuing"
        continue
    fi

    log_to_notebook "impl" "ralph.sh: iteration $i ended without promise"
done

if [[ $i -ge $MAX_ITERATIONS ]]; then
    echo ""
    echo "=== Max iterations ($MAX_ITERATIONS) reached ==="
    log_to_notebook "blocker" "ralph.sh: stopped after reaching max iterations ($MAX_ITERATIONS)"
fi

echo "Done."
