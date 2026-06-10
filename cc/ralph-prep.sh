#!/usr/bin/env bash
set -euo pipefail

# Per-iteration bookkeeping + prompt builder for the /ralph-lnb skill.
# Writes the filled prompt to RALPH-PROMPT.md in the project dir and prints
# only a one-line status to stdout, so the Claude Code session can point a
# subagent at the file without holding the prompt in its own context.
# Diagnostics go to stderr.

# --- Defaults ---
PROMPT_FILE=""
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
query, prompt fill) and writes the filled prompt to RALPH-PROMPT.md in the
project dir, printing only a one-line status to stdout. Intended to be
invoked by a Claude Code session that then points a subagent at that file
via the Agent() tool — see the /ralph-lnb skill (skill/SKILL.md.template).

Options:
  --prompt FILE           Custom prompt template (default: repo's shared/PROMPT.md)
  --task-file FILE        Task file with stories (default: tasks.json)
  --notebook DIR          Lab-notebook directory (default: .lnb)
  --context SLUG          Notebook context (default: derived from branch)
  --archive-dir DIR       Where to archive old runs (default: archive/)
  --iteration N           Iteration number, used in the start log entry
                          (default: 1)
  --max-iterations N      Iteration cap, recorded alongside --iteration
                          in the start log entry (optional). Does not
                          affect the loop — the Claude Code session
                          enforces the cap via the /ralph-lnb skill.
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

# Default to the repo's shared template if --prompt wasn't passed.
if [[ -z "$PROMPT_FILE" ]]; then
    PROMPT_FILE="$SHARED_DIR/PROMPT.md"
fi

# --- Validate ---
if [[ ! -f "$PROMPT_FILE" ]]; then
    echo "Error: Prompt file '$PROMPT_FILE' not found." >&2
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

# --- Write filled prompt to RALPH-PROMPT.md ---
# Query history BEFORE logging "start" so the recent_history block sees
# only prior iterations' entries — matches cc-headless/ralph.sh ordering
# (see ralph.sh:150-154) so both runners build byte-identical prompts.
history=$(query_recent_history)

# Write the filled prompt to RALPH-PROMPT.md in the cwd instead of stdout,
# so the /ralph-lnb main agent never has to hold the full prompt in its
# context. The subagent reads this file at the same fixed path (the skill's
# Agent() call hardcodes ./RALPH-PROMPT.md), so anchor it to the cwd here.
PROMPT_OUT="./RALPH-PROMPT.md"
build_prompt "$history" > "$PROMPT_OUT"
echo "Wrote iteration $ITERATION prompt to $PROMPT_OUT"

# Route lab-notebook's start-entry output to stderr so stdout stays a single status line.
if [[ -n "$MAX_ITERATIONS" ]]; then
    log_to_notebook "start" "ralph-lnb: starting iteration $ITERATION/$MAX_ITERATIONS" >&2
else
    log_to_notebook "start" "ralph-lnb: starting iteration $ITERATION" >&2
fi
