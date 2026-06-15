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

# --- Branch slug + writer identity ---
# Normalize a branch name into a filesystem-safe slug: strip a leading
# "ralph/" then turn any remaining "/" into "-". E.g. ralph/foo -> foo,
# feature/x -> feature-x, main -> main. ONE definition shared by both the
# archive-folder name and the notebook writer id, so they can't drift.
# NOTE: not injective — `ralph/foo` and `foo` both slug to `foo` (likewise
# `ralph/a/b` and `a-b`), so two branches differing only by a leading `ralph/`
# (or `/` vs `-`) share an archive folder and, in shared-notebook mode, a writer.
branch_slug() {
    echo "$1" | sed 's|^ralph/||; s|/|-|g'
}

# Per-loop notebook writer id, derived from BRANCH alone so it is identical
# between both runners (byte-identical prompt contract) and reproducible from
# BRANCH for the prompt-diff test. Defaults to "main" (same as build_prompt's
# branch default). E.g. ralph/foo -> ralph-foo, ralph/smoke-test ->
# ralph-smoke-test, feature/x -> ralph-feature-x, <unset> -> ralph-main.
# Set as a PROCESS ENV VAR on the lab-notebook emit call, never in .lnb.env.
notebook_writer() {
    echo "ralph-$(branch_slug "${BRANCH:-main}")"
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
            folder_name=$(branch_slug "$last_branch")
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

# --- One-time upgrade shim: OLD layout -> .ralph/ layout ---
# Older installs scattered ralph state across the project root:
#   ./.lnb/            the notebook        -> .ralph/.lnb
#   ./.lnb.env         pointer (abs path)  -> rewritten to point at .ralph/.lnb
#   ./.ralph-last-branch  bare branch cursor -> .ralph/state.json
#   ./archive/         old snapshots       -> .ralph/archive
#
# This migrates such a tree ONCE, in place, without data loss, and is a clean
# no-op on every later run. It runs at the top of ensure_notebook (BEFORE the
# fresh-init check) so a fresh `.ralph/.lnb` is never created over a user's
# existing history. Both runners reach it via ensure_notebook.
#
# Each step is independently guarded on "new target absent", so a tree that was
# only partially migrated by an interrupted run converges safely: no step ever
# double-moves or clobbers, and the whole helper is safe under set -euo pipefail.
# It MUST NOT invoke git (ralph is git-optional and must work in a plain
# non-git dir); when it migrates files that may be git-tracked it only PRINTS
# guidance to stderr, leaving untracking to the user.
migrate_old_layout() {
    # Nothing to do unless at least one OLD-layout artifact is present. Avoids
    # creating a stray .ralph/ on fresh projects (the shim must be inert there).
    if [[ ! -e ./.lnb && ! -e ./.lnb.env && ! -e ./.ralph-last-branch && ! -e ./archive ]]; then
        return 0
    fi

    mkdir -p .ralph
    local migrated_tracked=0

    # 1) Notebook: MOVE ./.lnb -> .ralph/.lnb (never re-init over it). Guarded so
    #    a second run (target present) is a no-op. The pointer is reconciled
    #    separately below so an interrupted move (moved, but died before the
    #    pointer rewrite) still converges on a later run.
    if [[ -d ./.lnb && ! -e .ralph/.lnb ]]; then
        local abs_nb
        mv ./.lnb .ralph/.lnb
        abs_nb="$(cd .ralph/.lnb && pwd)"
        write_notebook_pointer "$abs_nb"
        echo "Migrated notebook: ./.lnb -> .ralph/.lnb (pointer .lnb.env -> $abs_nb)" >&2
    elif [[ -d ./.lnb && -d .ralph/.lnb ]]; then
        # Both old and new notebooks exist — an earlier interrupted run or manual
        # state stranded ./.lnb. We never auto-merge or delete history; warn
        # loudly so the user reconciles, otherwise ./.lnb is silently ignored.
        echo "WARNING: both ./.lnb and .ralph/.lnb exist; ./.lnb is left in place and its history is NOT used." >&2
        echo "  Reconcile manually, then 'rm -rf ./.lnb' once you've confirmed .ralph/.lnb is the notebook to keep." >&2
    fi

    # Reconcile the .lnb.env pointer even when the MOVE happened in a prior
    # (possibly interrupted) run that died before rewriting it: if the notebook
    # lives at .ralph/.lnb but the pointer resolves to a missing dir, repoint it.
    # Idempotent — a pointer already resolving to a real dir is left untouched,
    # so a deliberate custom LAB_NOTEBOOK_DIR is never clobbered.
    if [[ -d .ralph/.lnb && -f ./.lnb.env ]]; then
        local abs_nb cur_dir
        abs_nb="$(cd .ralph/.lnb && pwd)"
        cur_dir="$(sed -n 's|^[[:space:]]*\(export[[:space:]]\+\)\?LAB_NOTEBOOK_DIR=\(.*\)|\2|p' ./.lnb.env | head -1)"
        if [[ -n "$cur_dir" && ! -d "$cur_dir" ]]; then
            write_notebook_pointer "$abs_nb"
            echo "Reconciled stale notebook pointer: .lnb.env -> $abs_nb" >&2
        fi
    fi

    # 2) Cursor: translate ./.ralph-last-branch (a bare branch string) into
    #    .ralph/state.json in the LANDED schema, then remove the old file.
    #    Guarded so we never overwrite an existing state.json.
    if [[ -f ./.ralph-last-branch && ! -e .ralph/state.json ]]; then
        local old_branch now
        old_branch="$(tr -d '\n' < ./.ralph-last-branch | sed 's/[[:space:]]*$//')"
        now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        jq -n \
            --arg branch "$old_branch" \
            --arg last_run "$now" \
            '{branch: $branch, last_run: $last_run, completed_branch: null}' \
            > .ralph/state.json
        rm -f ./.ralph-last-branch
        migrated_tracked=1
        echo "Migrated cursor: ./.ralph-last-branch (branch '$old_branch') -> .ralph/state.json" >&2
    fi

    # 3) Archive: MOVE ./archive -> .ralph/archive. Guarded on target absent.
    if [[ -d ./archive && ! -e .ralph/archive ]]; then
        mv ./archive .ralph/archive
        migrated_tracked=1
        echo "Migrated archive: ./archive -> .ralph/archive" >&2
    fi

    # If we moved files that the user may have committed (the OLD cursor /
    # archive leaked into git), point them at the manual cleanup. We NEVER run
    # git ourselves — ralph is git-optional and untracking is the user's call.
    if [[ "$migrated_tracked" -eq 1 ]]; then
        echo "If these were tracked in git, run: git rm --cached .ralph-last-branch archive" >&2
        echo "  (drops the now-migrated, gitignored files from the index; safe to skip in a non-git dir)" >&2
    fi
}

# Write/replace the LAB_NOTEBOOK_DIR line in ./.lnb.env so it points at $1 (an
# absolute notebook dir), matching the `export LAB_NOTEBOOK_DIR=<abs>` format
# `lab-notebook init` writes (lab-notebook parses only that key). Surgically
# replaces just that line if present (preserving the comment + any
# LAB_NOTEBOOK_WRITER line); otherwise (re)writes the pointer in canonical init
# format. The replacement is escaped so a `\`, `&`, or the `|` sed delimiter in
# the path can't corrupt the expression.
write_notebook_pointer() {
    local abs_nb="$1" esc tmp_env
    if [[ -f ./.lnb.env ]] && grep -q '^[[:space:]]*\(export[[:space:]]\+\)\?LAB_NOTEBOOK_DIR=' ./.lnb.env; then
        # Escape sed-replacement metacharacters; backslashes FIRST so the ones we
        # add below aren't doubled again.
        esc=${abs_nb//\\/\\\\}
        esc=${esc//&/\\&}
        esc=${esc//|/\\|}
        tmp_env="$(mktemp ./.lnb.env.XXXXXX)"
        sed "s|^\([[:space:]]*\(export[[:space:]]\+\)\?\)LAB_NOTEBOOK_DIR=.*|\1LAB_NOTEBOOK_DIR=$esc|" \
            ./.lnb.env > "$tmp_env"
        mv "$tmp_env" ./.lnb.env
    else
        printf '# Project-local lab-notebook configuration\nexport LAB_NOTEBOOK_DIR=%s\n' \
            "$abs_nb" > ./.lnb.env
    fi
}

# --- Notebook helpers ---
ensure_notebook() {
    # Migrate any OLD-layout state in place BEFORE the fresh-init check, so we
    # never init a fresh empty .ralph/.lnb over a user's existing notebook.
    migrate_old_layout
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
        # Attribute the entry to a per-loop writer (ralph-<branch-slug>), set as
        # a process env var on the same command line so it is exported into the
        # lab-notebook subprocess. This keeps several worktrees/loops pointed at
        # one shared --notebook contention-free (per-writer JSONL).
        LAB_NOTEBOOK_DIR="$NOTEBOOK_DIR" LAB_NOTEBOOK_WRITER="$(notebook_writer)" \
            lab-notebook emit \
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

    # Replace FILL markers. The writer is derived from BRANCH alone (same as the
    # runner's log_to_notebook), so both runners render the identical value and
    # the byte-identical prompt contract holds.
    prompt="${prompt//<!-- FILL:context -->/$CONTEXT}"
    prompt="${prompt//<!-- FILL:notebook_dir -->/$NOTEBOOK_DIR}"
    prompt="${prompt//<!-- FILL:branch -->/${BRANCH:-main}}"
    prompt="${prompt//<!-- FILL:writer -->/$(notebook_writer)}"
    prompt="${prompt//<!-- FILL:tasks -->/$tasks_content}"
    prompt="${prompt//<!-- FILL:recent_history -->/$history}"

    echo "$prompt"
}
