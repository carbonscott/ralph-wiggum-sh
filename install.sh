#!/usr/bin/env bash
set -euo pipefail

# Install ralph-wiggum-lnb ergonomic entry points:
#   1. Symlink this repo's cc-headless/ralph.sh into $BIN_DIR (default: ~/.local/bin)
#      so `ralph` runs from any cwd.
#   2. Render skill/SKILL.md.template -> ~/.claude/skills/ralph-lnb/SKILL.md
#      with @@RALPH_REPO@@ substituted, so `/ralph-lnb` works in Claude Code chats.
#
# Idempotent: safe to re-run after moving or re-cloning the repo. Pass --force
# to overwrite install artifacts that don't belong to ralph-wiggum-lnb.

# --- Resolve this script's real location (symlink-safe) ---
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
    DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
REPO="$(cd "$(dirname "$SOURCE")" && pwd)"

# --- Parse args ---
FORCE=0
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        -h|--help)
            cat <<'EOF'
Usage: install.sh [--force]

Installs ralph-wiggum-lnb entry points. Run from a fresh git clone:

    git clone <url> ~/codes/ralph-wiggum-lnb
    ~/codes/ralph-wiggum-lnb/install.sh

Environment variables:
  RALPH_BIN_DIR   Where to put the `ralph` symlink. Default: ~/.local/bin

Options:
  --force         Overwrite install artifacts that don't belong to this repo
  -h, --help      Show this help

Run ./uninstall.sh from the repo to undo.
EOF
            exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

BIN_DIR="${RALPH_BIN_DIR:-$HOME/.local/bin}"
SKILL_DIR="$HOME/.claude/skills/ralph-lnb"
BIN_TARGET="$BIN_DIR/ralph"
SKILL_TARGET="$SKILL_DIR/SKILL.md"
TEMPLATE="$REPO/skill/SKILL.md.template"
MARKER="Managed by ralph-wiggum-lnb install.sh"

# --- Preflight: template must exist ---
if [[ ! -f "$TEMPLATE" ]]; then
    echo "Error: template not found at $TEMPLATE" >&2
    echo "Is this a complete ralph-wiggum-lnb checkout?" >&2
    exit 1
fi

# --- Install 1: symlink `ralph` into BIN_DIR ---
mkdir -p "$BIN_DIR"

install_bin=1
if [[ -e "$BIN_TARGET" || -L "$BIN_TARGET" ]]; then
    if [[ -L "$BIN_TARGET" ]]; then
        existing="$(readlink "$BIN_TARGET")"
        if [[ "$existing" == "$REPO/cc-headless/ralph.sh" ]]; then
            echo "Symlink $BIN_TARGET already points at this repo — refreshing."
        else
            if [[ $FORCE -eq 1 ]]; then
                echo "Overwriting $BIN_TARGET (was: $existing)"
            else
                echo "Warning: $BIN_TARGET is a symlink to $existing, not this repo." >&2
                echo "         Skipping. Re-run with --force to overwrite." >&2
                install_bin=0
            fi
        fi
    else
        if [[ $FORCE -eq 1 ]]; then
            echo "Overwriting non-symlink file at $BIN_TARGET"
        else
            echo "Warning: $BIN_TARGET exists and is not a symlink." >&2
            echo "         Skipping. Re-run with --force to overwrite." >&2
            install_bin=0
        fi
    fi
fi

if [[ $install_bin -eq 1 ]]; then
    ln -sf "$REPO/cc-headless/ralph.sh" "$BIN_TARGET"
    echo "Installed: $BIN_TARGET -> $REPO/cc-headless/ralph.sh"
fi

# --- Install 2: render skill template ---
mkdir -p "$SKILL_DIR"

install_skill=1
if [[ -f "$SKILL_TARGET" ]]; then
    if grep -q "$MARKER" "$SKILL_TARGET"; then
        echo "Skill $SKILL_TARGET is managed by install.sh — refreshing."
    else
        if [[ $FORCE -eq 1 ]]; then
            echo "Overwriting unmanaged skill at $SKILL_TARGET"
        else
            echo "Warning: $SKILL_TARGET exists and is not managed by this installer." >&2
            echo "         Skipping. Re-run with --force to overwrite." >&2
            install_skill=0
        fi
    fi
fi

if [[ $install_skill -eq 1 ]]; then
    # Render template: substitute @@RALPH_REPO@@ with the absolute repo path.
    # Escape \, |, & in $REPO — those are the three characters sed treats
    # specially in the replacement string. Backslash must go first so the
    # subsequent substitutions don't double-escape.
    REPO_ESCAPED=$(printf '%s\n' "$REPO" | sed 's/[\\|&]/\\&/g')
    sed "s|@@RALPH_REPO@@|$REPO_ESCAPED|g" "$TEMPLATE" > "$SKILL_TARGET"
    echo "Installed: $SKILL_TARGET (rendered with $REPO)"
fi

# --- PATH check (informational only) ---
case ":$PATH:" in
    *":$BIN_DIR:"*)
        path_on=1 ;;
    *)
        path_on=0 ;;
esac

# --- Post-install summary ---
cat <<EOF

Done. Quick usage:
  ralph --max-iterations 3                 # headless mode
  /ralph-lnb max-iterations 3              # in a Claude Code chat

EOF

if [[ $path_on -eq 0 ]]; then
    cat <<EOF
Note: $BIN_DIR is not on your \$PATH. Add this to your shell rc:
  export PATH="$BIN_DIR:\$PATH"

EOF
fi

cat <<EOF
Note: Claude Code caches its skill list per session. Restart any
running chat sessions to pick up /ralph-lnb.
EOF
