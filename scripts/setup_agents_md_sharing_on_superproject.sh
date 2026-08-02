#!/bin/bash
# scripts/setup_agents_md_sharing_on_superproject.sh
# 2026-05-24 | CR

set -e

SOURCE_DIR="$PWD"   # Source must ba a absolute (non-relative) path, so "ln -s" works as expected
TARGET_DIR="$PWD/packages"

SCRIPT_DIR="$(dirname "$0")"
if [ "${SCRIPT_DIR}" = "." ]; then
    SCRIPT_DIR="$PWD"
else
    cd "${SCRIPT_DIR}"
    SCRIPT_DIR="$(pwd)"
    cd -
fi

ACTION="$1"
if [ "$ACTION" = "" ]; then
    echo ""
    echo "Share superproject Claude.md across code agent tools (Gemini, Codex, Cursor, Agents) on all packages."
    echo "Usage: $0 <add|remove>"
    echo ""
    exit 1
fi

# PACKAGE_LIST is defined in get_package_list.sh
source "${SCRIPT_DIR}/get_package_list.sh" > /dev/null 2>&1

remove_shared_agents_md() {
    echo ""
    echo "** Removing shared CLAUDE.md on '$SOURCE_DIR' and '$TARGET_DIR' **"
    echo ""
    for PACKAGE in "${PACKAGE_LIST[@]}"; do
        bash "${SCRIPT_DIR}/setup_agents_md_sharing.sh" remove symlink "$TARGET_DIR/$PACKAGE" "$TARGET_DIR/$PACKAGE"
    done
    bash "${SCRIPT_DIR}/setup_agents_md_sharing.sh" remove symlink "$SOURCE_DIR" "$SOURCE_DIR"
}

share_agents_md() {
    echo ""
    echo "** Sharing CLAUDE.md as AGENTS.md/GEMINI.md on '$SOURCE_DIR' and '$TARGET_DIR' **"
    echo ""
    for PACKAGE in "${PACKAGE_LIST[@]}"; do
        bash "${SCRIPT_DIR}/setup_agents_md_sharing.sh" add symlink "$TARGET_DIR/$PACKAGE" "$TARGET_DIR/$PACKAGE"
    done
    bash "${SCRIPT_DIR}/setup_agents_md_sharing.sh" add symlink "$SOURCE_DIR" "$SOURCE_DIR"
}

# Main procedure

if [ "$ACTION" = "add" ]; then
    share_agents_md
elif [ "$ACTION" = "remove" ]; then
    remove_shared_agents_md
else
    echo ""
    echo "Invalid action: $ACTION"
    exit 1
fi
