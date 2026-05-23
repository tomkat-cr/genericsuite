#!/bin/bash
# setup_ai_skills_sharing.sh
# 2026-05-19 | CR

# Reference:
# Sharing ai "Skills" Across Models Claude, Gemini & Codex. The Ultimate Al Abstraction Layer
# https://www.youtube.com/watch?v=6HQ-NbrWylo&t=426s

set -e

AI_DIR=".ai"

ACTION="$1"
SOURCE_DIR="$2"   # Source must be converted to an absolute (non-relative) path, so "ln -s" works as expected
TARGET_DIR="$3"

SCRIPT_DIR="$(dirname "$0")"
if [ "${SCRIPT_DIR}" = "." ]; then
    SCRIPT_DIR="$PWD"
else
    cd "${SCRIPT_DIR}"
    SCRIPT_DIR="$(pwd)"
    cd -
fi

if [ "${ACTION}" = "" ]; then
    echo ""
    echo "Share AI skills/commands ('${AI_DIR}' directory) across code agent tools: Claude, Gemini, Codex, Cursor, Agents."
    echo "Usage: $0 <action> <source directory> <target directory>"
    echo ""
    echo "Where:"
    echo "  <action> must be 'add' or 'remove'"
    echo "  <source directory> is the path where the '${AI_DIR}' directory is located. Default is the current directory."
    echo "  <target directory> is the path to the target directory where the AI skills/commands will be symlinked. Default is the current directory."
    echo ""
    echo ""
    exit 1
fi

set_default_values() {
    if [ "${SOURCE_DIR}" = "" ]; then
        SOURCE_DIR="."
    fi
    if [ "${TARGET_DIR}" = "" ]; then
        TARGET_DIR="."
    fi
}

fix_dir_path_to_be_absolute() {
    local path_to_fix="$1"
    if [ "${path_to_fix}" = "." ]; then
        echo "$PWD"
    else
        cd "${path_to_fix}"
        echo $(pwd)
    fi
}    

verify_ai_dir_exists() {
    if [ ! -d "${SOURCE_DIR}/${AI_DIR}" ]; then
        echo "ERROR: ${SOURCE_DIR}/${AI_DIR} directory not found"
        exit 1
    fi
}

fix_dir_paths() {
    set_default_values
    SOURCE_DIR=$(fix_dir_path_to_be_absolute "${SOURCE_DIR}")
    TARGET_DIR=$(fix_dir_path_to_be_absolute "${TARGET_DIR}")
    verify_ai_dir_exists
}

remove_shared_skills() {
    echo ""
    echo "** Removing shared skills on '$SOURCE_DIR' and '$TARGET_DIR' **"
    echo ""
    remove_one_shared "$SOURCE_DIR"
}

remove_one_shared() {
    local source_dir="$1"
    local code_tool_dirs=(
        ".claude"
        ".codex"
        ".cursor"
        ".gemini"
        ".agents"
    )

    if [ -z "$source_dir" ]; then
        echo "ERROR: source_dir is not set in remove_one_shared"
        exit 1
    fi

    echo "Cleaning up shared skills/commands in '$source_dir'..."

    for tool_dir in "${code_tool_dirs[@]}"; do
        local path="$source_dir/$tool_dir"
        if [ -d "$path" ]; then
            # Remove settings.json symlink
            if [ -L "$path/settings.json" ]; then
                echo "Removing symlink $path/settings.json"
                rm -f "$path/settings.json"
            fi

            # Remove mcp.json symlink
            if [ -L "$path/mcp.json" ]; then
                echo "Removing symlink $path/mcp.json"
                rm -f "$path/mcp.json"
            fi

            # Remove skills symlink or individual symlinks
            if [ -L "$path/skills" ]; then
                echo "Removing symlink $path/skills"
                rm -f "$path/skills"
            elif [ -d "$path/skills" ]; then
                # Remove all symlinks inside skills/
                for item in "$path/skills"/*; do
                    [ -e "$item" ] || [ -L "$item" ] || continue
                    if [ -L "$item" ]; then
                        echo "Removing symlink $item"
                        rm -f "$item"
                    fi
                done
                # If skills directory is now empty, remove it
                if [ -z "$(ls -A "$path/skills" 2>/dev/null)" ]; then
                    echo "Removing empty directory $path/skills"
                    rmdir "$path/skills"
                fi
            fi

            # Remove commands symlink or individual symlinks
            if [ -L "$path/commands" ]; then
                echo "Removing symlink $path/commands"
                rm -f "$path/commands"
            elif [ -d "$path/commands" ]; then
                # Remove all symlinks inside commands/
                for item in "$path/commands"/*; do
                    [ -e "$item" ] || [ -L "$item" ] || continue
                    if [ -L "$item" ]; then
                        echo "Removing symlink $item"
                        rm -f "$item"
                    fi
                done
                # If commands directory is now empty, remove it
                if [ -z "$(ls -A "$path/commands" 2>/dev/null)" ]; then
                    echo "Removing empty directory $path/commands"
                    rmdir "$path/commands"
                fi
            fi

            # If the tool_dir itself has a .DS_Store and nothing else, remove the .DS_Store
            if [ -f "$path/.DS_Store" ] && [ "$(ls -A "$path" 2>/dev/null | wc -l | tr -d ' ')" -eq 1 ]; then
                rm -f "$path/.DS_Store"
            fi

            # If the tool_dir is empty, remove it
            if [ -z "$(ls -A "$path" 2>/dev/null)" ]; then
                echo "Removing empty directory: $path"
                rmdir "$path"
            fi
        fi
    done
}

setup_tool_dir_by_dir() {
    local source_dir="$1"
    local target_dir="$2"
    local destroy_target_dirs="$3"

    if [ "$source_dir" = "" ]; then
        echo "ERROR: source_dir is not set"
        exit 1
    fi
    if [ "$target_dir" = "" ]; then
        echo "ERROR: target_dir is not set"
        exit 1
    fi
    if [ "$destroy_target_dirs" = "" ]; then
        destroy_target_dirs="false"
    fi


    if [ ! -d "$target_dir" ]; then
        echo "(1) mkdir -p \"$target_dir\""
        mkdir -p "$target_dir"
    fi
    if [ "$destroy_target_dirs" = "true" ]; then
        # Remove the target directory/symlink, re-create it and symlink all source to target
        target_subdir="$target_dir/$(basename "$source_dir")"
        if [ -d "$target_subdir" ]; then
            echo "(2) rm -rf \"$target_subdir\""
            rm -rf "$target_subdir"
        fi
    fi

    # For each sub-directory of the source directory, symlink it
    source_mid_dir="$(basename "$source_dir")"
    for source_subdir in "$source_dir"/*; do
        if [ ! -d "$target_dir" ]; then
            echo "(4) mkdir -p \"$target_dir\""
            mkdir -p "$target_dir"
        fi
        if [ ! -d "$target_dir/$source_mid_dir" ]; then
            echo "(4) mkdir -p \"$target_dir/$source_mid_dir\""
            mkdir -p "$target_dir/$source_mid_dir"
        fi
        if [ -d "$source_subdir" ]; then
            target_subdir="$target_dir/$source_mid_dir/$(basename "$source_subdir")"
            if [ -d "$target_subdir" ]; then
                echo "(5) rm -rf \"$target_subdir\""
                rm -rf "$target_subdir"
            fi
            echo "(6) ln -s \"$source_subdir\" \"$target_dir/$source_mid_dir\""
            ln -s "$source_subdir" "$target_dir/$source_mid_dir"
        fi
    done
}

setup_shared_skills_and_commands() {
    local source_dir="$1"
    local target_dir="$2"
    local destroy_target_dirs="$3"

    if [ "$source_dir" = "" ]; then
        echo "ERROR: source_dir is not set"
        exit 1
    fi
    if [ "$target_dir" = "" ]; then
        echo "ERROR: target_dir is not set"
        exit 1
    fi
    if [ "$destroy_target_dirs" = "" ]; then
        destroy_target_dirs="false"
    fi

    echo ""
    echo "Setting up '$target_dir' from '$source_dir'..."
    echo ""

    # Ensure code agent tool config directories exist
    mkdir -p "$target_dir/.claude" "$target_dir/.codex" "$target_dir/.cursor" "$target_dir/.gemini" "$target_dir/.agents"

    # Skills symlinks (unified skills → each code agent tool)
    if [ -d "$source_dir/${AI_DIR}/skills" ]; then
        setup_tool_dir_by_dir "$source_dir/${AI_DIR}/skills" "$target_dir/.claude" "$destroy_target_dirs"
        setup_tool_dir_by_dir "$source_dir/${AI_DIR}/skills" "$target_dir/.cursor" "$destroy_target_dirs"
        setup_tool_dir_by_dir "$source_dir/${AI_DIR}/skills" "$target_dir/.agents" "$destroy_target_dirs"
        setup_tool_dir_by_dir "$source_dir/${AI_DIR}/skills" "$target_dir/.codex" "$destroy_target_dirs"
        setup_tool_dir_by_dir "$source_dir/${AI_DIR}/skills" "$target_dir/.gemini" "$destroy_target_dirs"
    fi

    # Commands symlinks (unified commands → each code agent tool)
    if [ -d "$source_dir/${AI_DIR}/commands" ]; then
        setup_tool_dir_by_dir "$source_dir/${AI_DIR}/commands" "$target_dir/.claude" "$destroy_target_dirs"
        setup_tool_dir_by_dir "$source_dir/${AI_DIR}/commands" "$target_dir/.cursor" "$destroy_target_dirs"
        setup_tool_dir_by_dir "$source_dir/${AI_DIR}/commands" "$target_dir/.agents" "$destroy_target_dirs"
    fi

    # Settings symlinks (unified settings → each applicable code agent tool)
    if [ -f "$source_dir/${AI_DIR}/settings.json" ]; then
        ln -sfn "$source_dir/${AI_DIR}/settings.json" "$target_dir/.claude/settings.json"
    fi

    # MCP config symlinks (unified config → each applicable code agent tool)
    if [ -f "$source_dir/${AI_DIR}/mcp.json" ]; then
        ln -sfn "$source_dir/${AI_DIR}/mcp.json" "$target_dir/.claude/mcp.json"
        ln -sfn "$source_dir/${AI_DIR}/mcp.json" "$target_dir/.cursor/mcp.json"
    fi

    if [ "$source_dir" != "$target_dir" ]; then
        # If source and target are different, means we need to check if it has its own skills/commands
        if [ -d "$target_dir/${AI_DIR}" ]; then
            # If the package directory has an .ai directorty, means it has its own skills/commands...
            echo ""
            echo "Package directory '$target_dir' has its own skills/commands..."
            setup_shared_skills_and_commands "$target_dir" "$target_dir" false
        fi
    fi

    # NOTE: Claude Desktop can't be symlinked (needs 'preferences' key).
}

share_skills() {
    echo ""
    echo "** Sharing skills from '$SOURCE_DIR' to '$TARGET_DIR' **"
    echo ""
    setup_shared_skills_and_commands "$SOURCE_DIR" "$TARGET_DIR" true
}

# Main procedure

fix_dir_paths

if [ "$ACTION" = "add" ]; then
    share_skills
elif [ "$ACTION" = "remove" ]; then
    remove_shared_skills
else
    echo ""
    echo "Invalid action: $ACTION"
    exit 1
fi
