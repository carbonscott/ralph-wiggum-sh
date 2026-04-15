# Shared helpers for ralph.sh and ralph-prep.sh.
# Source this file after defining: SCRIPT_DIR, PROMPT_FILE, TASK_FILE,
# NOTEBOOK_DIR, CONTEXT, ARCHIVE_DIR, LAST_BRANCH_FILE. The functions
# below also use BRANCH and PROJECT, which callers typically resolve via
# read_task_meta after sourcing.

# --- Read task file metadata ---
read_task_meta() {
    local key="$1"
    jq -r ".$key // empty" "$TASK_FILE" 2>/dev/null || echo ""
}

# --- Archive support ---
archive_previous_run() {
    if [[ -f "$TASK_FILE" && -f "$LAST_BRANCH_FILE" ]]; then
        local last_branch
        last_branch=$(cat "$LAST_BRANCH_FILE" 2>/dev/null || echo "")
        if [[ -n "$BRANCH" && -n "$last_branch" && "$BRANCH" != "$last_branch" ]]; then
            local date_str folder_name archive_folder
            date_str=$(date +%Y-%m-%d)
            folder_name=$(echo "$last_branch" | sed 's|^ralph/||; s|/|-|g')
            archive_folder="$ARCHIVE_DIR/$date_str-$folder_name"

            echo "Archiving previous run: $last_branch" >&2
            mkdir -p "$archive_folder"
            cp "$TASK_FILE" "$archive_folder/"
            if [[ -d "$NOTEBOOK_DIR" ]]; then
                cp -r "$NOTEBOOK_DIR" "$archive_folder/"
            fi
            echo "  Archived to: $archive_folder" >&2
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
            LAB_NOTEBOOK_DIR="$NOTEBOOK_DIR" lab-notebook init "$NOTEBOOK_DIR" >&2 2>/dev/null || true
        else
            LAB_NOTEBOOK_DIR="$NOTEBOOK_DIR" lab-notebook init --local >&2 2>/dev/null || true
        fi
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
