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

# --- Read task file metadata ---
read_task_meta() {
    local key="$1"
    jq -r ".$key // empty" "$TASK_FILE" 2>/dev/null || echo ""
}

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

# --- Archive support ---
LAST_BRANCH_FILE=".ralph-last-branch"

archive_previous_run() {
    if [[ -f "$TASK_FILE" && -f "$LAST_BRANCH_FILE" ]]; then
        local last_branch
        last_branch=$(cat "$LAST_BRANCH_FILE" 2>/dev/null || echo "")
        if [[ -n "$BRANCH" && -n "$last_branch" && "$BRANCH" != "$last_branch" ]]; then
            local date_str folder_name archive_folder
            date_str=$(date +%Y-%m-%d)
            folder_name=$(echo "$last_branch" | sed 's|^ralph/||; s|/|-|g')
            archive_folder="$ARCHIVE_DIR/$date_str-$folder_name"

            echo "Archiving previous run: $last_branch"
            mkdir -p "$archive_folder"
            cp "$TASK_FILE" "$archive_folder/"
            if [[ -d "$NOTEBOOK_DIR" ]]; then
                cp -r "$NOTEBOOK_DIR" "$archive_folder/"
            fi
            echo "  Archived to: $archive_folder"
        fi
    fi
    if [[ -n "$BRANCH" ]]; then
        echo "$BRANCH" > "$LAST_BRANCH_FILE"
    fi
}

# --- Notebook helpers ---
ensure_notebook() {
    if [[ ! -d "$NOTEBOOK_DIR" ]]; then
        if [[ -f "$SCRIPT_DIR/coding-dev.yaml" ]]; then
            mkdir -p "$NOTEBOOK_DIR"
            cp "$SCRIPT_DIR/coding-dev.yaml" "$NOTEBOOK_DIR/schema.yaml"
            LAB_NOTEBOOK_DIR="$NOTEBOOK_DIR" lab-notebook init "$NOTEBOOK_DIR" 2>/dev/null || true
        else
            LAB_NOTEBOOK_DIR="$NOTEBOOK_DIR" lab-notebook init --local 2>/dev/null || true
        fi
        echo "Initialized notebook at $NOTEBOOK_DIR"
    fi
}

log_to_notebook() {
    local entry_type="$1"
    local message="$2"
    if command -v lab-notebook &>/dev/null && [[ -d "$NOTEBOOK_DIR" ]]; then
        LAB_NOTEBOOK_DIR="$NOTEBOOK_DIR" lab-notebook emit \
            --context "$CONTEXT" --type "$entry_type" \
            --branch "${BRANCH:-}" --tags "ralph-harness" \
            "$message" 2>/dev/null || true
    fi
}

query_recent_history() {
    if command -v lab-notebook &>/dev/null && [[ -d "$NOTEBOOK_DIR" ]]; then
        LAB_NOTEBOOK_DIR="$NOTEBOOK_DIR" lab-notebook sql \
            "SELECT ts, type, issue, substr(content,1,200) FROM entries WHERE context='$CONTEXT' ORDER BY ts DESC LIMIT 10" \
            2>/dev/null || echo "(no history yet)"
    else
        echo "(notebook not available)"
    fi
}

# --- Prompt building ---
build_prompt() {
    local history="$1"
    local tasks_content
    tasks_content=$(cat "$TASK_FILE")

    local prompt
    prompt=$(cat "$PROMPT_FILE")

    # Replace FILL markers
    prompt="${prompt//<!-- FILL:context -->/$CONTEXT}"
    prompt="${prompt//<!-- FILL:notebook_dir -->/$NOTEBOOK_DIR}"
    prompt="${prompt//<!-- FILL:branch -->/${BRANCH:-main}}"
    prompt="${prompt//<!-- FILL:tasks -->/$tasks_content}"
    prompt="${prompt//<!-- FILL:recent_history -->/$history}"

    echo "$prompt"
}

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

    # Extract only assistant text from stream-json for promise detection.
    # Grepping the raw TMPFILE would match promise strings found in tool
    # results (e.g. when the agent reads PROMPT.md or ralph.sh).
    AGENT_TEXT=$(jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text' "$TMPFILE" 2>/dev/null || true)

    # Check for promises (ALL_DONE first since DONE is a substring)
    if echo "$AGENT_TEXT" | grep -q "<promise>${ALL_DONE_PROMISE}</promise>"; then
        echo ""
        echo "=== All stories complete! ==="
        log_to_notebook "done" "ralph.sh: all stories complete at iteration $i"
        break
    elif echo "$AGENT_TEXT" | grep -q "<promise>${COMPLETION_PROMISE}</promise>"; then
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
