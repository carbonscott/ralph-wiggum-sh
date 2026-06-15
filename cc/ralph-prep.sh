#!/usr/bin/env bash
set -euo pipefail

# Per-iteration bookkeeping + prompt builder for the /ralph-lnb skill.
# Writes the filled prompt to .ralph/prompt.md in the project dir and prints
# only a one-line status to stdout, so the Claude Code session can point a
# subagent at the file without holding the prompt in its own context.
# Diagnostics go to stderr.

# --- Defaults ---
PROMPT_FILE=""
TASK_FILE="tasks.json"
NOTEBOOK_DIR=".ralph/.lnb"
CONTEXT=""
ARCHIVE_DIR=".ralph/archive"
ITERATION="1"
MAX_ITERATIONS=""
STATE_FILE=".ralph/state.json"
FORCE=0
RECORD_COMPLETE=0

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
query, prompt fill) and writes the filled prompt to .ralph/prompt.md in the
project dir, printing only a one-line status to stdout. Intended to be
invoked by a Claude Code session that then points a subagent at that file
via the Agent() tool — see the /ralph-lnb skill (skill/SKILL.md.template).

Options:
  --prompt FILE           Custom prompt template (default: repo's shared/PROMPT.md)
  --task-file FILE        Task file with stories (default: tasks.json)
  --notebook DIR          Lab-notebook directory (default: .ralph/.lnb)
  --context SLUG          Notebook context (default: derived from branch)
  --archive-dir DIR       Where to archive old runs (default: .ralph/archive)
  --iteration N           Iteration number, used in the start log entry
                          (default: 1)
  --max-iterations N      Iteration cap, recorded alongside --iteration
                          in the start log entry (optional). Does not
                          affect the loop — the Claude Code session
                          enforces the cap via the /ralph-lnb skill.
  --force                 Bypass the refuse-respin guard: prep a prompt even
                          when this branch's all-green batch was already
                          recorded complete in .ralph/state.json. Only
                          overrides the guard; archive behavior is unchanged.
  --record-complete       Record this branch's batch as complete in
                          .ralph/state.json and exit (do not prep a prompt).
                          The /ralph-lnb skill calls this after a subagent
                          returns <promise>ALL_DONE</promise>, so a later
                          re-spin of the all-green batch is refused (the
                          headless runner records this inline on ALL_DONE).
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
        --force)           FORCE=1; shift ;;
        --record-complete) RECORD_COMPLETE=1; shift ;;
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

# --- Record batch completion and exit (G3) ---
# Called by the /ralph-lnb skill after a subagent returns ALL_DONE, so a later
# re-spin of the all-green batch is refused. Records and exits without prepping
# a prompt or touching the notebook.
if [[ "$RECORD_COMPLETE" -eq 1 ]]; then
    record_batch_complete
    echo "Recorded batch complete for branch '${BRANCH:-<none>}' in $STATE_FILE"
    exit 0
fi

# --- Refuse re-spinning an already-completed batch (G3) ---
# If this branch's batch is all-green AND was recorded complete in
# .ralph/state.json, do not prep another prompt — print a clear message and
# exit non-zero so the /ralph-lnb skill stops the loop instead of looping on a
# fully-passing tasks.json. --force bypasses this guard (archive behavior is
# unchanged). Checked before archiving so a finished batch never touches state.
if [[ "$FORCE" -ne 1 ]] && batch_already_complete; then
    echo "Batch already complete for branch '${BRANCH:-<none>}': all stories pass and this batch was recorded complete in $STATE_FILE." >&2
    echo "Nothing to do. Add or unset stories in $TASK_FILE (or start a new branch), or pass --force to re-spin anyway." >&2
    exit 3
fi

# --- Bookkeeping ---
# archive_previous_run and ensure_notebook are both idempotent — safe to
# call on every iteration. archive_previous_run only actually archives on a
# real branch transition (recorded cursor in $STATE_FILE differs from BRANCH).
archive_previous_run
ensure_notebook

# --- Write filled prompt to .ralph/prompt.md ---
# Query history BEFORE logging "start" so the recent_history block sees
# only prior iterations' entries — matches cc-headless/ralph.sh ordering
# (see ralph.sh:150-154) so both runners build byte-identical prompts.
history=$(query_recent_history)

# Write the filled prompt to .ralph/prompt.md in the cwd instead of stdout,
# so the /ralph-lnb main agent never has to hold the full prompt in its
# context. The subagent reads this file at the same fixed path (the skill's
# Agent() call hardcodes .ralph/prompt.md), so anchor it to the cwd here.
mkdir -p .ralph
PROMPT_OUT=".ralph/prompt.md"
build_prompt "$history" > "$PROMPT_OUT"
echo "Wrote iteration $ITERATION prompt to $PROMPT_OUT"

# Route lab-notebook's start-entry output to stderr so stdout stays a single status line.
if [[ -n "$MAX_ITERATIONS" ]]; then
    log_to_notebook "start" "ralph-lnb: starting iteration $ITERATION/$MAX_ITERATIONS" >&2
else
    log_to_notebook "start" "ralph-lnb: starting iteration $ITERATION" >&2
fi
