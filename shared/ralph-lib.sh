# Shared helpers for ralph.sh and ralph-prep.sh.
# Source this file after defining: SCRIPT_DIR, SHARED_DIR, PROMPT_FILE,
# TASK_FILE, NOTEBOOK_DIR, CONTEXT, ARCHIVE_DIR, STATE_FILE. The
# functions below also use BRANCH and PROJECT, which callers typically
# resolve via read_task_meta after sourcing.
#
# SHARED_DIR must point at the repo's shared/ directory so ensure_notebook
# can locate coding-dev.yaml. Both runners set it as "$SCRIPT_DIR/../shared".
#
# STATE_FILE is the gitignored batch cursor (.ralph/state.json). It is the
# successor to the leaking flat-file branch cursor it replaces. Schema
# (minimal, jq-friendly):
#   {
#     "branch":           "<current branch from tasks.json>",
#     "last_run":         "<ISO 8601 timestamp of the last run>",
#     "completed_branch": "<branch whose all-green batch was recorded
#                          complete, or null if none>"
#   }
# `branch` is the archive cursor; `completed_branch` gates the refuse-respin
# guard (see batch_already_complete). The notebook self-archives, so no
# notebook copy is ever made.

# --- Read task file metadata ---
read_task_meta() {
    local key="$1"
    jq -r ".$key // empty" "$TASK_FILE" 2>/dev/null || echo ""
}

# --- State (.ralph/state.json) helpers ---
# Read a single field from the state cursor. Echoes "" when the file is
# missing, empty, malformed, or the field is absent/null.
read_state() {
    local key="$1"
    [[ -s "$STATE_FILE" ]] || { echo ""; return; }
    jq -r ".$key // empty" "$STATE_FILE" 2>/dev/null || echo ""
}

# Write the run cursor (branch + last_run) WITHOUT disturbing the recorded
# completion marker. Always preserves any existing completed_branch so the
# refuse-respin guard survives ordinary same-branch re-runs and archives.
write_state_cursor() {
    local prev_completed
    prev_completed=$(read_state "completed_branch")
    mkdir -p "$(dirname "$STATE_FILE")"
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    jq -n \
        --arg branch "${BRANCH:-}" \
        --arg last_run "$now" \
        --arg completed "$prev_completed" \
        '{branch: $branch, last_run: $last_run,
          completed_branch: (if $completed == "" then null else $completed end)}' \
        > "$STATE_FILE"
}

# Record the current branch's batch as complete (sets completed_branch to the
# current BRANCH). Refreshes last_run; keeps the branch cursor pointing at the
# current branch.
record_batch_complete() {
    mkdir -p "$(dirname "$STATE_FILE")"
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    jq -n \
        --arg branch "${BRANCH:-}" \
        --arg last_run "$now" \
        --arg completed "${BRANCH:-}" \
        '{branch: $branch, last_run: $last_run,
          completed_branch: (if $completed == "" then null else $completed end)}' \
        > "$STATE_FILE"
}

# --- Completion / refuse-respin support ---
# True (exit 0) iff every story in TASK_FILE has passes:true and there is at
# least one story.
tasks_all_pass() {
    [[ -f "$TASK_FILE" ]] || return 1
    local total passing
    total=$(jq '[.stories[]?] | length' "$TASK_FILE" 2>/dev/null || echo 0)
    [[ "$total" -gt 0 ]] || return 1
    passing=$(jq '[.stories[]? | select(.passes == true)] | length' "$TASK_FILE" 2>/dev/null || echo 0)
    [[ "$passing" == "$total" ]]
}

# True (exit 0) iff the current branch's batch is all-green AND was recorded
# complete in state.json. This is the refuse-respin condition.
batch_already_complete() {
    [[ -n "${BRANCH:-}" ]] || return 1
    local completed
    completed=$(read_state "completed_branch")
    [[ "$completed" == "$BRANCH" ]] || return 1
    tasks_all_pass
}

# --- Archive support ---
# Archive trigger (resolved spec rule): archive iff a recorded cursor
# (STATE_FILE) exists, is non-empty, AND its `branch` differs from the current
# BRANCH. On first run (no cursor) record the cursor and archive nothing; on a
# same-branch re-run, archive nothing. A MISSING state.json means "first run,
# archive nothing" — never "transition, archive". On a real transition we
# snapshot ONLY tasks.json (the notebook self-archives by context).
archive_previous_run() {
    if [[ -f "$TASK_FILE" && -s "$STATE_FILE" ]]; then
        local last_branch
        last_branch=$(read_state "branch")
        if [[ -n "$BRANCH" && -n "$last_branch" && "$BRANCH" != "$last_branch" ]]; then
            local date_str folder_name archive_folder
            date_str=$(date +%Y-%m-%d)
            folder_name=$(echo "$last_branch" | sed 's|^ralph/||; s|/|-|g')
            archive_folder="$ARCHIVE_DIR/$date_str-$folder_name"

            echo "Archiving previous run: $last_branch" >&2
            mkdir -p "$archive_folder"
            cp "$TASK_FILE" "$archive_folder/"
            echo "  Archived to: $archive_folder (tasks.json only)" >&2
        fi
    fi
    # Always (re)record the run cursor so the next run can detect a transition.
    # Preserves any existing completed_branch marker.
    if [[ -n "$BRANCH" ]]; then
        write_state_cursor
    fi
}

# --- Notebook helpers ---
ensure_notebook() {
    if [[ ! -d "$NOTEBOOK_DIR" ]]; then
        # `lab-notebook init .ralph` forces a `/.lnb` leaf and writes a root
        # .lnb.env pointing at it with an ABSOLUTE path, plus the notebook's
        # own .gitignore — all in one call. That lands the notebook directly
        # at .ralph/.lnb (the NOTEBOOK_DIR default), so no separate mv + sed
        # patch of .lnb.env is needed.
        mkdir -p .ralph
        lab-notebook init .ralph --template-path "$SHARED_DIR/coding-dev.yaml" >/dev/null

        echo "Initialized notebook at $NOTEBOOK_DIR" >&2
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
        # Double up any single quotes in CONTEXT (SQL-standard escape)
        # so a branch like ralph/feature's-test can't break out of the
        # WHERE clause.
        local escaped_context="${CONTEXT//\'/\'\'}"
        LAB_NOTEBOOK_DIR="$NOTEBOOK_DIR" lab-notebook sql \
            "SELECT ts, type, issue, substr(content,1,200) FROM entries WHERE context='$escaped_context' ORDER BY ts DESC LIMIT 10" \
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
