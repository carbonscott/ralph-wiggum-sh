#!/usr/bin/env bash
set -euo pipefail

# Undo what install.sh did. Only removes artifacts that clearly belong to
# ralph-wiggum-lnb — refuses to touch anything unfamiliar.

# --- Resolve this script's real location (symlink-safe) ---
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
    DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
REPO="$(cd "$(dirname "$SOURCE")" && pwd)"

BIN_DIR="${RALPH_BIN_DIR:-$HOME/.local/bin}"
SKILL_DIR="$HOME/.claude/skills/ralph-lnb"
BIN_TARGET="$BIN_DIR/ralph"
SKILL_TARGET="$SKILL_DIR/SKILL.md"
MARKER="Managed by ralph-wiggum-lnb install.sh"

removed_any=0

# --- Uninstall 1: remove the ralph symlink if it points at this repo ---
if [[ -L "$BIN_TARGET" ]]; then
    existing="$(readlink "$BIN_TARGET")"
    if [[ "$existing" == "$REPO/cc-headless/ralph.sh" ]]; then
        rm -f "$BIN_TARGET"
        echo "Removed: $BIN_TARGET"
        removed_any=1
    else
        echo "Leaving $BIN_TARGET alone (points at $existing, not this repo)."
    fi
elif [[ -e "$BIN_TARGET" ]]; then
    echo "Leaving $BIN_TARGET alone (not a symlink)."
fi

# --- Uninstall 2: remove the skill file if managed ---
if [[ -f "$SKILL_TARGET" ]]; then
    if grep -q "$MARKER" "$SKILL_TARGET"; then
        rm -f "$SKILL_TARGET"
        echo "Removed: $SKILL_TARGET"
        removed_any=1
        # Clean up the parent dir if it's now empty.
        if [[ -d "$SKILL_DIR" ]] && [[ -z "$(ls -A "$SKILL_DIR")" ]]; then
            rmdir "$SKILL_DIR"
            echo "Removed empty dir: $SKILL_DIR"
        fi
    else
        echo "Leaving $SKILL_TARGET alone (not managed by this installer)."
    fi
fi

if [[ $removed_any -eq 0 ]]; then
    echo "Nothing to remove."
fi
