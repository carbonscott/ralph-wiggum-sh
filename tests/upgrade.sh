#!/usr/bin/env bash
set -euo pipefail

# One-time OLD-layout -> .ralph/ upgrade shim test (handoff 08), reworked for
# the minimal `lnb` CLI.
#
# WHAT WAS REMOVED AND WHY:
#   The pre-min harness used the old lab notebook CLI, which had an `init` step
#   and a project-local `.lnb.env` pointer file (an exported absolute-path env
#   line) that migrate_old_layout had to create/rewrite/reconcile. The minimal
#   `lnb` CLI has NEITHER: there is no `init` (a notebook dir auto-creates on
#   the first `lnb note`) and no `.lnb.env` (discovery is `$LNB_DIR`, else the
#   nearest `.lnb/` walking up). So every assertion about `.lnb.env`
#   content/format, the exported pointer line, pointer reconciliation
#   (dangling-pointer repair, discovery-via-.lnb.env), the both-notebooks-exist
#   warning, and the old `init` layout has been DELETED — it tests machinery
#   that no longer exists. The end-to-end PART B through cc/ralph-prep.sh was
#   also dropped: its distinctive value (a migrated cursor drives a transition
#   archive) is already covered by tests/archive.sh, and its remaining
#   assertions were dominated by the removed `.lnb.env`/init machinery.
#
# WHAT REMAINS TESTED (the surviving, still-meaningful properties of
# migrate_old_layout in shared/ralph-lib.sh):
#   (a) the notebook dir MOVE (./.lnb -> .ralph/.lnb) preserves entries — the
#       pre-move records are still returned by `lnb log` afterward;
#   (b) the branch cursor ./.ralph-last-branch -> .ralph/state.json (carrying
#       the OLD branch verbatim, in the landed schema);
#   (c) ./archive -> .ralph/archive with its snapshot intact;
#   (d) the OLD root files are removed;
#   (e) a SECOND migrate is a clean no-op (idempotence): no re-move, entry
#       intact;
#   (f) a half-migrated tree converges: an already-moved notebook is NOT
#       re-moved (no data loss) while lingering cursor + archive complete.
#
# migrate_old_layout MUST NOT invoke git (ralph is git-optional and must work
# in a plain non-git dir); this test runs entirely in non-git dirs.
#
# Mechanics (mirrors tests/archive.sh / tests/setup-sandbox.sh):
#   - Resolve the repo via BASH_SOURCE, never `which ralph` (the installed
#     ralph may resolve to a different checkout).
#   - Throwaway $TMPDIR workroot; clean up on exit.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHARED_DIR="$REPO_DIR/shared"

if ! command -v lnb &>/dev/null; then
    echo "SKIP: lnb not on PATH; cannot run upgrade test." >&2
    exit 0
fi

WORKROOT="${TMPDIR:-/tmp}/ralph-upgrade-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$WORKROOT"
cleanup() { cd /; rm -rf "$WORKROOT"; }
trap cleanup EXIT

pass() { echo "  OK: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# Known fixtures.
KNOWN_ENTRY="known entry alpha (pre-migration)"
OLD_BRANCH="ralph/old-batch"
ARCHIVE_SNAPSHOT_REL="archive/2025-01-01-old-batch/tasks.json"

# entry_present <lnb-dir>: 0 iff KNOWN_ENTRY is returned by `lnb log` there.
# `lnb log` streams JSONL (one record per line); jq slurps and checks any match.
entry_present() {
    LNB_DIR="$1" lnb log 2>/dev/null \
        | jq -e -s --arg e "$KNOWN_ENTRY" 'any(.[]; .content == $e)' >/dev/null
}

# seed_old_layout <dir>: scaffold a full OLD-layout project at <dir>:
#   ./.lnb (with ONE known entry), ./.ralph-last-branch, ./archive/<snapshot>.
# The min CLI has no init and no .lnb.env: the notebook is created simply by
# writing one entry into ./.lnb via `lnb note`.
seed_old_layout() {
    local dir="$1"
    mkdir -p "$dir"
    cp "$REPO_DIR/tests/tasks.json" "$dir/tasks.json"
    (
        cd "$dir"
        # First `lnb note` auto-creates ./.lnb and appends the known entry.
        LNB_DIR="$dir/.lnb" \
            lnb note "$KNOWN_ENTRY" --type impl --context "$OLD_BRANCH" >/dev/null
        printf '%s\n' "$OLD_BRANCH" > ./.ralph-last-branch
        mkdir -p "$(dirname "$ARCHIVE_SNAPSHOT_REL")"
        printf 'old snapshot marker\n' > "$ARCHIVE_SNAPSHOT_REL"
    )
    [[ -d "$dir/.lnb" && -f "$dir/.ralph-last-branch" \
        && -f "$dir/$ARCHIVE_SNAPSHOT_REL" ]] || fail "seed: OLD layout incomplete in $dir"
}

###############################################################################
echo "== migrate_old_layout in isolation =="
###############################################################################
A_DIR="$WORKROOT/partA"
seed_old_layout "$A_DIR"
[[ ! -d "$A_DIR/.git" ]] || fail "partA sandbox unexpectedly has .git"
pass "seeded OLD layout (./.lnb + 1 entry, ./.ralph-last-branch=$OLD_BRANCH, $ARCHIVE_SNAPSHOT_REL)"

# Drive the real shim, isolated in a subshell so the sourced lib/vars don't leak.
(
    cd "$A_DIR"
    STATE_FILE=".ralph/state.json"
    # shellcheck source=/dev/null
    source "$SHARED_DIR/ralph-lib.sh"
    migrate_old_layout
)

# (a) Known entry survives the MOVE and is returned by `lnb log` at .ralph/.lnb.
[[ -d "$A_DIR/.ralph/.lnb" ]] || fail "A: .ralph/.lnb not present after migrate"
entry_present "$A_DIR/.ralph/.lnb" \
    || fail "A: known entry NOT returned by lnb log through .ralph/.lnb (history lost!)"
pass "known entry survives the MOVE and is returned by lnb log through .ralph/.lnb"

# (b) state.json carries the OLD branch verbatim and is schema-valid.
SF="$A_DIR/.ralph/state.json"
[[ -s "$SF" ]] || fail "A: .ralph/state.json missing"
jq -e . "$SF" >/dev/null 2>&1 || fail "A: state.json not valid JSON"
[[ "$(jq -r '.branch' "$SF")" == "$OLD_BRANCH" ]] \
    || fail "A: state.json branch is '$(jq -r '.branch' "$SF")', expected '$OLD_BRANCH'"
[[ "$(jq -r '.last_run' "$SF")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
    || fail "A: state.json last_run not ISO8601: $(jq -r '.last_run' "$SF")"
[[ "$(jq -r '.completed_branch' "$SF")" == "null" ]] \
    || fail "A: migrated completed_branch should be null"
# Exactly the landed schema's three keys.
[[ "$(jq -r 'keys | sort | join(",")' "$SF")" == "branch,completed_branch,last_run" ]] \
    || fail "A: state.json keys are '$(jq -c 'keys' "$SF")', expected branch/completed_branch/last_run"
pass "state.json carries OLD branch ($OLD_BRANCH), schema-valid (branch/last_run/completed_branch)"

# (c) Archive moved with snapshot intact.
[[ -f "$A_DIR/.ralph/$ARCHIVE_SNAPSHOT_REL" ]] \
    || fail "A: archive snapshot not at .ralph/$ARCHIVE_SNAPSHOT_REL"
grep -q "old snapshot marker" "$A_DIR/.ralph/$ARCHIVE_SNAPSHOT_REL" \
    || fail "A: archive snapshot content lost"
pass "./archive moved to .ralph/archive with snapshot intact"

# (d) Old root files gone.
[[ ! -e "$A_DIR/.lnb" ]]               || fail "A: old ./.lnb still present"
[[ ! -e "$A_DIR/.ralph-last-branch" ]] || fail "A: old ./.ralph-last-branch still present"
[[ ! -e "$A_DIR/archive" ]]            || fail "A: old ./archive still present"
pass "old root files gone (./.lnb, ./.ralph-last-branch, ./archive)"

# (e) Idempotence: a SECOND migrate_old_layout is a clean no-op. No "Migrated"
#     lines, the migrated notebook is NOT re-moved (its inode is stable — a
#     re-move would change it), and the entry is still queryable.
nb_inode_before=$(stat -c '%i' "$A_DIR/.ralph/.lnb")
A2LOG="$WORKROOT/partA-run2.log"
(
    cd "$A_DIR"
    STATE_FILE=".ralph/state.json"
    # shellcheck source=/dev/null
    source "$SHARED_DIR/ralph-lib.sh"
    migrate_old_layout
) >"$A2LOG" 2>&1
grep -qi 'Migrated ' "$A2LOG" && fail "A: second migrate re-migrated (not idempotent): $(cat "$A2LOG")"
[[ "$(stat -c '%i' "$A_DIR/.ralph/.lnb")" == "$nb_inode_before" ]] \
    || fail "A: .ralph/.lnb was re-moved on second migrate (inode changed)"
entry_present "$A_DIR/.ralph/.lnb" || fail "A: known entry lost after no-op second migrate"
pass "second migrate_old_layout is a CLEAN no-op (no Migrated lines; notebook not re-moved; entry intact)"

# (f) Partial-migration convergence: a tree where the notebook is ALREADY moved
#     but the OLD cursor + archive linger must converge without re-moving (and
#     so without clobbering) the already-migrated notebook, and without erroring
#     under set -euo pipefail.
P_DIR="$WORKROOT/partial"
seed_old_layout "$P_DIR"
# Simulate an interrupted migration: notebook already moved, but
# ./.ralph-last-branch and ./archive still at root and no state.json yet.
mkdir -p "$P_DIR/.ralph"
mv "$P_DIR/.lnb" "$P_DIR/.ralph/.lnb"
# Mark the already-migrated notebook so we can prove it is NOT re-moved.
P_NB_INODE_BEFORE=$(stat -c '%i' "$P_DIR/.ralph/.lnb")
(
    cd "$P_DIR"
    STATE_FILE=".ralph/state.json"
    # shellcheck source=/dev/null
    source "$SHARED_DIR/ralph-lib.sh"
    migrate_old_layout
)
# Notebook must be untouched (no re-move / re-init); its entry still queryable.
entry_present "$P_DIR/.ralph/.lnb" || fail "partial: notebook clobbered (entry lost)"
[[ "$(stat -c '%i' "$P_DIR/.ralph/.lnb")" == "$P_NB_INODE_BEFORE" ]] \
    || fail "partial: .ralph/.lnb was re-moved (inode changed) despite already being migrated"
# The lingering OLD cursor + archive must now be converged.
[[ "$(jq -r '.branch' "$P_DIR/.ralph/state.json")" == "$OLD_BRANCH" ]] \
    || fail "partial: cursor not converged from lingering ./.ralph-last-branch"
[[ ! -e "$P_DIR/.ralph-last-branch" ]] || fail "partial: ./.ralph-last-branch not removed"
[[ -f "$P_DIR/.ralph/$ARCHIVE_SNAPSHOT_REL" ]] || fail "partial: ./archive not converged"
[[ ! -e "$P_DIR/archive" ]] || fail "partial: ./archive not removed"
pass "partial-migration tree converges: notebook untouched, cursor + archive completed"

###############################################################################
echo "== No git was invoked anywhere (git-optional) =="
###############################################################################
for d in "$A_DIR" "$P_DIR"; do
    [[ ! -d "$d/.git" ]] || fail "a .git dir appeared in $d (git was invoked?)"
done
pass "ran entirely in non-git dirs; no .git created"

echo ""
echo "PASS: upgrade shim moves the OLD notebook without data loss, migrates cursor + archive, converges partial trees, and is idempotent."
