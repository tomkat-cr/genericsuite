#!/bin/bash
# setup_ai_skills_sharing_on_superproject.sh
# 2026-05-22 | CR

# Reference:
# Sharing ai "Skills" Across Models Claude, Gemini & Codex. The Ultimate Al Abstraction Layer
# https://www.youtube.com/watch?v=6HQ-NbrWylo&t=426s

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
    echo "Share superproject AI skills/commands across code agent tools (Claude, Gemini, Codex, Cursor, Agents) on all packages."
    echo "Usage: $0 <add|remove>"
    echo ""
    exit 1
fi

# PACKAGE_LIST is defined in get_package_list.sh
source "${SCRIPT_DIR}/get_package_list.sh" > /dev/null 2>&1

remove_shared_skills() {
    echo ""
    echo "** Removing shared skills on '$SOURCE_DIR' and '$TARGET_DIR' **"
    echo ""
    for PACKAGE in "${PACKAGE_LIST[@]}"; do
        bash "${SCRIPT_DIR}/setup_ai_skills_sharing.sh" remove "$TARGET_DIR/$PACKAGE"
    done
    bash "${SCRIPT_DIR}/setup_ai_skills_sharing.sh" remove "$SOURCE_DIR"
}

share_skills() {
    echo ""
    echo "** Sharing skills from '$SOURCE_DIR' to '$TARGET_DIR' **"
    echo ""
    for PACKAGE in "${PACKAGE_LIST[@]}"; do
        bash "${SCRIPT_DIR}/setup_ai_skills_sharing.sh" add "$SOURCE_DIR" "$TARGET_DIR/$PACKAGE"
    done
    bash "${SCRIPT_DIR}/setup_ai_skills_sharing.sh" add "$SOURCE_DIR" "$SOURCE_DIR"
}

# Main procedure

if [ "$ACTION" = "add" ]; then
    share_skills
elif [ "$ACTION" = "remove" ]; then
    remove_shared_skills
else
    echo ""
    echo "Invalid action: $ACTION"
    exit 1
fi
