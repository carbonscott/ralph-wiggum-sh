#!/usr/bin/env bash
set -euo pipefail

# One-time OLD-layout -> .ralph/ upgrade shim test (handoff 08).
#
# Older installs scattered ralph state across the project root:
#   ./.lnb/              notebook         -> .ralph/.lnb
#   ./.lnb.env           pointer (abs)    -> rewritten to point at .ralph/.lnb
#   ./.ralph-last-branch bare branch cur. -> .ralph/state.json
#   ./archive/           old snapshots    -> .ralph/archive
#
# migrate_old_layout migrates such a tree ONCE without data loss and is a clean
# no-op afterwards. Both runners call it (before archive bookkeeping, and again
# at the top of ensure_notebook). This test exercises it two ways:
#
#   PART A — the shim in isolation (source ralph-lib.sh, call migrate_old_layout
#   directly): proves the precise migration outcome, incl. that state.json
#   carries the OLD branch verbatim, and that a SECOND call is a clean no-op
#   (idempotence) and a half-migrated tree converges.
#
#   PART B — end-to-end through cc/ralph-prep.sh (the runnable bookkeeping entry
#   point — reaches migrate_old_layout + archive_previous_run + ensure_notebook
#   without needing `claude`): proves a real run migrates the layout, then the
#   migrated OLD branch drives archive_previous_run to snapshot under an
#   old-branch-named archive folder, and a second run is a clean no-op.
#
# Everything runs in plain NON-GIT dirs (ralph is git-optional; nothing here
# invokes git).
#
# Mechanics (mirrors tests/archive.sh / tests/setup-sandbox.sh):
#   - Resolve the repo via BASH_SOURCE, never `which ralph` (the installed
#     ralph may resolve to a different checkout).
#   - Throwaway $TMPDIR workroot; clean up on exit.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREP="$REPO_DIR/cc/ralph-prep.sh"
SHARED_DIR="$REPO_DIR/shared"
TEMPLATE="$SHARED_DIR/coding-dev.yaml"

if ! command -v lab-notebook &>/dev/null; then
    echo "SKIP: lab-notebook not on PATH; cannot run upgrade test." >&2
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

# seed_old_layout <dir>: scaffold a full OLD-layout project at <dir>.
#   ./.lnb (+ ./.lnb.env) with ONE known entry, ./.ralph-last-branch, ./archive.
seed_old_layout() {
    local dir="$1"
    mkdir -p "$dir"
    cp "$REPO_DIR/tests/tasks.json" "$dir/tasks.json"
    (
        cd "$dir"
        # `lab-notebook init .` forces a /.lnb leaf and writes ./.lnb.env with an
        # ABSOLUTE path to it — exactly the OLD on-disk shape.
        lab-notebook init . --template-path "$TEMPLATE" >/dev/null
        LAB_NOTEBOOK_DIR="$dir/.lnb" \
            lab-notebook emit --context "$OLD_BRANCH" --type impl "$KNOWN_ENTRY" >/dev/null
        printf '%s\n' "$OLD_BRANCH" > ./.ralph-last-branch
        mkdir -p "$(dirname "$ARCHIVE_SNAPSHOT_REL")"
        printf 'old snapshot marker\n' > "$ARCHIVE_SNAPSHOT_REL"
    )
    [[ -d "$dir/.lnb" && -f "$dir/.lnb.env" && -f "$dir/.ralph-last-branch" \
        && -f "$dir/$ARCHIVE_SNAPSHOT_REL" ]] || fail "seed: OLD layout incomplete in $dir"
}

###############################################################################
echo "== PART A: migrate_old_layout in isolation =="
###############################################################################
A_DIR="$WORKROOT/partA"
seed_old_layout "$A_DIR"
[[ ! -d "$A_DIR/.git" ]] || fail "partA sandbox unexpectedly has .git"
pass "seeded OLD layout (./.lnb + 1 entry, ./.lnb.env, ./.ralph-last-branch=$OLD_BRANCH, $ARCHIVE_SNAPSHOT_REL)"

# Drive the real shim, isolated in a subshell so the sourced lib/vars don't leak.
(
    cd "$A_DIR"
    STATE_FILE=".ralph/state.json"
    # shellcheck source=/dev/null
    source "$SHARED_DIR/ralph-lib.sh"
    migrate_old_layout
)

# (a) Known entry queryable through .ralph/.lnb.
[[ -d "$A_DIR/.ralph/.lnb" ]] || fail "A: .ralph/.lnb not present after migrate"
got=$(LAB_NOTEBOOK_DIR="$A_DIR/.ralph/.lnb" lab-notebook sql \
    "SELECT content FROM entries WHERE content='$KNOWN_ENTRY'" 2>/dev/null || true)
echo "$got" | grep -qF "$KNOWN_ENTRY" \
    || fail "A: known entry NOT queryable through .ralph/.lnb (history lost!); got: $got"
pass "known entry survives the MOVE and is queryable through .ralph/.lnb"

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

# (d) Old root files gone; .lnb.env repointed to the new ABSOLUTE export path.
[[ ! -e "$A_DIR/.lnb" ]]               || fail "A: old ./.lnb still present"
[[ ! -e "$A_DIR/.ralph-last-branch" ]] || fail "A: old ./.ralph-last-branch still present"
[[ ! -e "$A_DIR/archive" ]]            || fail "A: old ./archive still present"
NEW_ABS="$A_DIR/.ralph/.lnb"
env_val=$(sed -n 's/^[[:space:]]*\(export[[:space:]]\+\)\?LAB_NOTEBOOK_DIR=//p' "$A_DIR/.lnb.env" | head -1)
[[ "$env_val" == "$NEW_ABS" ]] \
    || fail "A: .lnb.env LAB_NOTEBOOK_DIR is '$env_val', expected absolute '$NEW_ABS'"
grep -q '^export LAB_NOTEBOOK_DIR=' "$A_DIR/.lnb.env" \
    || fail "A: .lnb.env not in 'export LAB_NOTEBOOK_DIR=...' init format"
pass "old root files gone; .lnb.env -> $NEW_ABS (absolute, export format)"

# (e) Discovery via .lnb.env (no explicit env var) resolves the migrated notebook.
disc=$(cd "$A_DIR" && lab-notebook sql \
    "SELECT content FROM entries WHERE content='$KNOWN_ENTRY'" 2>/dev/null || true)
echo "$disc" | grep -qF "$KNOWN_ENTRY" \
    || fail "A: discovery via .lnb.env broken (entry not found); got: $disc"
pass "notebook discovery via .lnb.env resolves the migrated notebook"

# (f) Idempotence: a SECOND migrate_old_layout is a clean no-op.
snapshot() { ( cd "$A_DIR" && find .ralph .lnb.env -printf '%P\t%s\t%T@\n' 2>/dev/null | sort ); }
before=$(snapshot)
env_before=$(cat "$A_DIR/.lnb.env")
state_before=$(cat "$SF")
A2LOG="$WORKROOT/partA-run2.log"
(
    cd "$A_DIR"
    STATE_FILE=".ralph/state.json"
    # shellcheck source=/dev/null
    source "$SHARED_DIR/ralph-lib.sh"
    migrate_old_layout
) >"$A2LOG" 2>&1
grep -qi 'Migrated ' "$A2LOG" && fail "A: second migrate re-migrated (not idempotent): $(cat "$A2LOG")"
[[ "$(snapshot)" == "$before" ]] || { diff <(printf '%s\n' "$before") <(printf '%s\n' "$(snapshot)") >&2; fail "A: second migrate mutated the .ralph tree"; }
[[ "$(cat "$A_DIR/.lnb.env")" == "$env_before" ]] || fail "A: second migrate changed .lnb.env"
[[ "$(cat "$SF")" == "$state_before" ]] || fail "A: second migrate changed state.json"
pass "second migrate_old_layout is a CLEAN no-op (no Migrated lines; tree/.lnb.env/state unchanged)"

# (g) Partial-migration convergence: a tree where the notebook is migrated but
#     the OLD cursor + archive linger must converge without clobbering the
#     already-migrated notebook (and without erroring under set -euo pipefail).
P_DIR="$WORKROOT/partial"
seed_old_layout "$P_DIR"
# Simulate an interrupted migration: notebook already moved (+ pointer fixed),
# but ./.ralph-last-branch and ./archive still at root and no state.json yet.
mkdir -p "$P_DIR/.ralph"
mv "$P_DIR/.lnb" "$P_DIR/.ralph/.lnb"
printf '# Project-local lab-notebook configuration\nexport LAB_NOTEBOOK_DIR=%s\n' \
    "$P_DIR/.ralph/.lnb" > "$P_DIR/.lnb.env"
# Mark the already-migrated notebook so we can prove it is NOT clobbered.
P_NB_MTIME_BEFORE=$(stat -c '%Y' "$P_DIR/.ralph/.lnb")
(
    cd "$P_DIR"
    STATE_FILE=".ralph/state.json"
    # shellcheck source=/dev/null
    source "$SHARED_DIR/ralph-lib.sh"
    migrate_old_layout
)
# Notebook must be untouched (no re-move / re-init); its entry still queryable.
gotp=$(LAB_NOTEBOOK_DIR="$P_DIR/.ralph/.lnb" lab-notebook sql \
    "SELECT content FROM entries WHERE content='$KNOWN_ENTRY'" 2>/dev/null || true)
echo "$gotp" | grep -qF "$KNOWN_ENTRY" || fail "partial: notebook clobbered (entry lost)"
[[ "$(stat -c '%Y' "$P_DIR/.ralph/.lnb")" == "$P_NB_MTIME_BEFORE" ]] \
    || fail "partial: .ralph/.lnb was re-moved (mtime changed) despite already being migrated"
# The lingering OLD cursor + archive must now be converged.
[[ "$(jq -r '.branch' "$P_DIR/.ralph/state.json")" == "$OLD_BRANCH" ]] \
    || fail "partial: cursor not converged from lingering ./.ralph-last-branch"
[[ ! -e "$P_DIR/.ralph-last-branch" ]] || fail "partial: ./.ralph-last-branch not removed"
[[ -f "$P_DIR/.ralph/$ARCHIVE_SNAPSHOT_REL" ]] || fail "partial: ./archive not converged"
[[ ! -e "$P_DIR/archive" ]] || fail "partial: ./archive not removed"
pass "partial-migration tree converges: notebook untouched, cursor + archive completed"

###############################################################################
echo "== PART B: end-to-end through cc/ralph-prep.sh =="
###############################################################################
B_DIR="$WORKROOT/partB"
seed_old_layout "$B_DIR"
[[ ! -d "$B_DIR/.git" ]] || fail "partB sandbox unexpectedly has .git"
cd "$B_DIR"

# Run 1: migrate, then archive_previous_run sees the migrated OLD branch as the
# cursor and the CURRENT tasks.json branch (ralph/smoke-test) as a transition.
BLOG1="$WORKROOT/partB-run1.log"
"$PREP" --task-file tasks.json --iteration 1 >"$BLOG1" 2>&1 \
    || fail "B run 1 exited non-zero: $(cat "$BLOG1")"

# The shim reported the migration.
grep -qi 'Migrated notebook' "$BLOG1" || fail "B: run 1 did not report notebook migration: $(cat "$BLOG1")"

# Notebook history survived end-to-end.
gotb=$(LAB_NOTEBOOK_DIR="$B_DIR/.ralph/.lnb" lab-notebook sql \
    "SELECT content FROM entries WHERE content='$KNOWN_ENTRY'" 2>/dev/null || true)
echo "$gotb" | grep -qF "$KNOWN_ENTRY" || fail "B: known entry lost end-to-end"

# Old root files gone; .lnb.env repointed.
[[ ! -e ./.lnb && ! -e ./.ralph-last-branch && ! -e ./archive ]] \
    || fail "B: old root artifacts not removed (ls: $(ls -a))"
NEW_ABS_B="$B_DIR/.ralph/.lnb"
env_val_b=$(sed -n 's/^[[:space:]]*\(export[[:space:]]\+\)\?LAB_NOTEBOOK_DIR=//p' ./.lnb.env | head -1)
[[ "$env_val_b" == "$NEW_ABS_B" ]] || fail "B: .lnb.env -> '$env_val_b', expected '$NEW_ABS_B'"

# The migrated OLD branch drove archive_previous_run: a transition from
# ralph/old-batch to ralph/smoke-test snapshots tasks.json under an
# old-branch-named folder. (branch_slug strips 'ralph/' -> 'old-batch'.)
DATE_STR="$(date +%Y-%m-%d)"
TRANS_FOLDER=".ralph/archive/$DATE_STR-old-batch"
[[ -f "$TRANS_FOLDER/tasks.json" ]] \
    || fail "B: migrated OLD branch did not drive a transition archive at $TRANS_FOLDER (have: $(ls -R .ralph/archive 2>/dev/null))"
# The pre-existing OLD snapshot also still lives under .ralph/archive.
[[ -f ".ralph/$ARCHIVE_SNAPSHOT_REL" ]] || fail "B: pre-existing OLD snapshot lost from archive"
# After the transition, the cursor advanced to the current branch.
[[ "$(jq -r '.branch' .ralph/state.json)" == "ralph/smoke-test" ]] \
    || fail "B: cursor did not advance to ralph/smoke-test after transition"
pass "run 1: migrated; OLD branch drove a transition archive ($TRANS_FOLDER); cursor advanced"

# Run 2: clean no-op for the shim. The migration is idempotent: no "Migrated"
# lines, no old artifacts reappear, the .lnb.env pointer the shim wrote is
# byte-identical, and the migrated notebook is NOT re-moved (its inode is
# stable — a re-move would change it). We do NOT assert the whole notebook tree
# is byte-stable: ralph-prep legitimately emits a `start` entry + rebuilds the
# index every run; that's normal notebook activity, not the shim.
nb_inode_before=$(stat -c '%i' .ralph/.lnb)
env_b2_before=$(cat ./.lnb.env)
BLOG2="$WORKROOT/partB-run2.log"
"$PREP" --task-file tasks.json --iteration 2 >"$BLOG2" 2>&1 \
    || fail "B run 2 exited non-zero: $(cat "$BLOG2")"
grep -qi 'Migrated ' "$BLOG2" && fail "B: run 2 re-migrated (shim not idempotent): $(grep -i 'Migrated ' "$BLOG2")"
[[ ! -e ./.lnb && ! -e ./.ralph-last-branch && ! -e ./archive ]] \
    || fail "B: old artifacts reappeared on run 2"
[[ "$(stat -c '%i' .ralph/.lnb)" == "$nb_inode_before" ]] \
    || fail "B: .ralph/.lnb was re-moved on run 2 (inode changed)"
[[ "$(cat ./.lnb.env)" == "$env_b2_before" ]] || fail "B: .lnb.env changed on run 2"
# Same-branch run created no NEW transition folder.
NEW_TRANS=$(find .ralph/archive -maxdepth 1 -type d -name "$DATE_STR-smoke-test" 2>/dev/null)
[[ -z "$NEW_TRANS" ]] || fail "B: same-branch run 2 created a spurious archive: $NEW_TRANS"
gotb2=$(LAB_NOTEBOOK_DIR="$B_DIR/.ralph/.lnb" lab-notebook sql \
    "SELECT content FROM entries WHERE content='$KNOWN_ENTRY'" 2>/dev/null || true)
echo "$gotb2" | grep -qF "$KNOWN_ENTRY" || fail "B: known entry lost after no-op run 2"
pass "run 2 is a clean no-op: no re-migration, shim files + .lnb.env unchanged, entry intact"

###############################################################################
echo "== No git was invoked anywhere (git-optional) =="
###############################################################################
for d in "$A_DIR" "$P_DIR" "$B_DIR"; do
    [[ ! -d "$d/.git" ]] || fail "a .git dir appeared in $d (git was invoked?)"
done
pass "ran entirely in non-git dirs; no .git created"

echo ""
echo "PASS: upgrade shim migrates OLD layout once, preserves data, converges partial trees, and is idempotent."
