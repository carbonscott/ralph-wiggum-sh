#!/usr/bin/env bash
set -euo pipefail

# Byte-identical prompt regression test.
#
# Asserts two contracts that are otherwise guarded only by a comment in
# cc/ralph-prep.sh:
#
#   1. The two runners build BYTE-IDENTICAL prompts:
#        - cc-headless/ralph.sh pipes build_prompt to `claude -p` (ralph.sh:152)
#        - cc/ralph-prep.sh writes the same bytes to a file (ralph-prep.sh:125)
#      We reconstruct the headless runner's prompt by sourcing the shared lib
#      and calling build_prompt the same way ralph.sh does (path A), and we run
#      cc/ralph-prep.sh and read the file it actually writes (path B). They must
#      cmp/diff identical, exact bytes — no whitespace/case normalization.
#
#   2. Ordering: history is queried BEFORE the iteration's own `start` entry is
#      logged, so the prompt's "Recent History" block never contains the current
#      iteration's own start line.
#
# Mechanics (mirrors tests/setup-sandbox.sh):
#   - Resolve the repo via BASH_SOURCE, never `which ralph` (the installed ralph
#     may resolve to a different checkout).
#   - Run each capture in its own throwaway $TMPDIR sandbox seeded with
#     tests/tasks.json; clean up on exit. Works in a plain non-git dir (ralph is
#     git-optional; nothing here invokes git).
#   - Read the prompt-out path from a SINGLE source: the line ralph-prep.sh
#     prints to stdout ("Wrote iteration N prompt to <PATH>"). When handoff 03
#     moves the file (e.g. to .ralph/prompt.md) this test follows automatically.
#   - Neutralize the time-varying recent_history input by running each capture
#     against a fresh, empty notebook so query_recent_history returns the same
#     constant string for both runners. (Empirically that string is "(no
#     results)", not "(no history yet)" — but the test does not hardcode it; it
#     relies only on both runners querying the same empty store.)

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- Sandbox bookkeeping ---
# A single parent-owned temp root holds every sandbox + scratch file. Some
# sandboxes are created inside subshells (path A runs in a subshell so the
# sourced lib + vars don't leak), and a subshell can't mutate a parent array —
# so we rm the whole root in the trap rather than tracking individual dirs.
WORKROOT="${TMPDIR:-/tmp}/ralph-promptdiff-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$WORKROOT"
cleanup() { cd /; rm -rf "$WORKROOT"; }
trap cleanup EXIT

new_sandbox() {
    # Echoes a fresh sandbox under $WORKROOT, seeded with tests/tasks.json.
    local sb
    sb="$(mktemp -d "$WORKROOT/sandbox.XXXXXX")"
    cp "$REPO_DIR/tests/tasks.json" "$sb/tasks.json"
    echo "$sb"
}

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# --- Path A: reconstruct the headless runner's prompt (mirrors ralph.sh) ---
# Runs in its own fresh sandbox against an empty notebook, then prints the
# built prompt to stdout. Subshell so the sourced lib + vars don't leak.
capture_headless_prompt() {
    local out="$1"
    (
        local sb
        sb="$(new_sandbox)"
        cd "$sb"

        # The same vars the runners resolve before sourcing the lib.
        local SHARED_DIR="$REPO_DIR/shared"
        local PROMPT_FILE="$SHARED_DIR/PROMPT.md"
        local TASK_FILE="tasks.json"
        local NOTEBOOK_DIR=".ralph/.lnb"
        local CONTEXT=""
        local ARCHIVE_DIR="archive"
        local LAST_BRANCH_FILE=".ralph-last-branch"

        # shellcheck source=/dev/null
        source "$SHARED_DIR/ralph-lib.sh"

        local BRANCH PROJECT
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

        # Mirror ralph.sh's main path: bookkeeping, then RECALL + build.
        archive_previous_run
        ensure_notebook
        local history
        history=$(query_recent_history)   # empty notebook -> constant string
        build_prompt "$history"
    ) > "$out"
}

# --- Path B: run cc/ralph-prep.sh and read the file it writes ---
# Returns the absolute path to the prompt file written by ralph-prep.sh, by
# parsing the single status line it prints. The cwd is left at the sandbox so
# a relative path the runner reports still resolves.
PREP_PROMPT_PATH=""
run_prep() {
    local sb status rel
    sb="$(new_sandbox)"
    cd "$sb"
    # Only stdout carries the status line; diagnostics + the start-entry echo
    # go to stderr.
    status=$("$REPO_DIR/cc/ralph-prep.sh" --task-file tasks.json "$@")
    rel=$(printf '%s\n' "$status" | sed -n 's/^Wrote iteration [0-9]* prompt to //p')
    [[ -n "$rel" ]] || fail "could not parse prompt path from ralph-prep.sh stdout: [$status]"
    # Resolve relative to the sandbox cwd we are still in.
    if [[ "$rel" = /* ]]; then
        PREP_PROMPT_PATH="$rel"
    else
        PREP_PROMPT_PATH="$sb/${rel#./}"
    fi
    [[ -f "$PREP_PROMPT_PATH" ]] || fail "ralph-prep.sh reported '$rel' but no file at '$PREP_PROMPT_PATH'"
}

###############################################################################
# Assertion 1: byte-identical prompts
###############################################################################
echo "== Assertion 1: cc-headless/ralph.sh and cc/ralph-prep.sh build byte-identical prompts =="

A_PROMPT="$WORKROOT/headless-prompt.md"

capture_headless_prompt "$A_PROMPT"
run_prep
B_PROMPT="$PREP_PROMPT_PATH"

# Exact comparison only: cmp for the byte verdict, diff to print the offender.
if cmp -s "$A_PROMPT" "$B_PROMPT"; then
    echo "  OK: prompts are byte-identical"
else
    echo "  Prompts DIFFER (headless reconstruction <  > ralph-prep.sh output):" >&2
    diff "$A_PROMPT" "$B_PROMPT" >&2 || true
    fail "byte-identical prompt contract broken"
fi

###############################################################################
# Assertion 2: ordering — history queried before the iteration's own start log
###############################################################################
echo "== Assertion 2: prompt history excludes the current iteration's own start entry =="

# Seed iteration 1 (writes one `start` entry), then run iteration 2 in the SAME
# notebook. Iteration 2's prompt history must contain iteration 1's start line
# (proving history is read) but NOT iteration 2's own start line (proving the
# query happens before the start is logged).
ORDER_SB="$(new_sandbox)"
cd "$ORDER_SB"
"$REPO_DIR/cc/ralph-prep.sh" --task-file tasks.json --iteration 1 --max-iterations 2 >/dev/null 2>&1

status=$("$REPO_DIR/cc/ralph-prep.sh" --task-file tasks.json --iteration 2 --max-iterations 2)
rel=$(printf '%s\n' "$status" | sed -n 's/^Wrote iteration [0-9]* prompt to //p')
[[ -n "$rel" ]] || fail "could not parse prompt path from ralph-prep.sh (iter 2): [$status]"
if [[ "$rel" = /* ]]; then ORDER_PROMPT="$rel"; else ORDER_PROMPT="$ORDER_SB/${rel#./}"; fi
[[ -f "$ORDER_PROMPT" ]] || fail "iteration-2 prompt not found at '$ORDER_PROMPT'"

# Isolate the Recent History section so we only inspect history, not the rest
# of the prompt template (which also mentions `start`).
HISTORY_BLOCK=$(awk '
    /^## Recent History/ { inblock=1; next }
    /^## / { if (inblock) inblock=0 }
    inblock { print }
' "$ORDER_PROMPT")

if ! printf '%s\n' "$HISTORY_BLOCK" | grep -q "iteration 1/2"; then
    echo "  Recent History block was:" >&2
    printf '%s\n' "$HISTORY_BLOCK" >&2
    fail "iteration-2 history does not contain iteration 1's start entry (history not being read?)"
fi
if printf '%s\n' "$HISTORY_BLOCK" | grep -q "iteration 2/2"; then
    echo "  Recent History block was:" >&2
    printf '%s\n' "$HISTORY_BLOCK" >&2
    fail "iteration-2 history contains its OWN start entry — start was logged before history was queried"
fi
echo "  OK: history has the prior start entry and not the current one"

echo ""
echo "PASS: prompt-diff contracts hold."
