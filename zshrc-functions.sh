# ─────────────────────────────────────────────────────────────────────────────
# Claude Code Dropbox Sync - Shell Functions
# Add this to your ~/.zshrc
# ─────────────────────────────────────────────────────────────────────────────

# Configuration
CLAUDE_SYNC_CONFIG_FILE="$HOME/.claude_sync_config"
CLAUDE_SYNC_LOCAL_DIR="$HOME/.claude"
CLAUDE_SYNC_FILES=("settings.json" "mcp.json" "CLAUDE.md")
CLAUDE_SYNC_DIRS=("skills" "plugins")

# ─────────────────────────────────────────────────────────────────────────────
# File Integrity Validation Functions
# ─────────────────────────────────────────────────────────────────────────────

_claude_sync_is_file_empty() {
    [[ ! -s "$1" ]]
}

_claude_sync_validate_json() {
    local file="$1"
    [[ -f "$file" && -s "$file" ]] && python3 -c "import json; json.load(open('$file'))" 2>/dev/null
}

_claude_sync_validate_copy() {
    local src="$1" dst="$2"
    [[ -f "$src" && -f "$dst" ]] && [[ "$(shasum -a 256 "$src" | cut -d' ' -f1)" == "$(shasum -a 256 "$dst" | cut -d' ' -f1)" ]]
}

_claude_sync_validate_dir() {
    local src="$1" dst="$2"
    [[ -d "$src" && -d "$dst" ]] || return 1
    local src_count=$(find "$src" -type f | wc -l | tr -d ' ')
    local dst_count=$(find "$dst" -type f | wc -l | tr -d ' ')
    [[ "$src_count" == "$dst_count" ]]
}

# Check if two directories have identical content (for backup comparison)
_claude_sync_dirs_identical() {
    local dir1="$1" dir2="$2"
    [[ -d "$dir1" && -d "$dir2" ]] || return 1

    # Quick check: file counts
    local count1=$(find "$dir1" -type f | wc -l | tr -d ' ')
    local count2=$(find "$dir2" -type f | wc -l | tr -d ' ')
    [[ "$count1" == "$count2" ]] || return 1

    # Compare each file's checksum
    while IFS= read -r -d '' file; do
        local rel_path="${file#$dir1/}"
        local other_file="$dir2/$rel_path"
        [[ -f "$other_file" ]] || return 1

        local sum1=$(shasum -a 256 "$file" 2>/dev/null | cut -d' ' -f1)
        local sum2=$(shasum -a 256 "$other_file" 2>/dev/null | cut -d' ' -f1)
        [[ "$sum1" == "$sum2" ]] || return 1
    done < <(find "$dir1" -type f -print0)

    return 0
}

# Remove backup if identical to current state
_claude_sync_cleanup_backup() {
    local backup_path="$1"
    [[ -z "$backup_path" || ! -d "$backup_path" ]] && return 0

    if _claude_sync_dirs_identical "$backup_path" "$CLAUDE_SYNC_LOCAL_DIR"; then
        echo "\033[0;34m[INFO]\033[0m No changes detected, removing unnecessary backup"
        rm -rf "$backup_path"

        # Clear last backup marker if it pointed to this backup
        local last_backup_file="$HOME/.claude_sync_last_backup"
        if [[ -f "$last_backup_file" ]]; then
            local stored_backup=$(cat "$last_backup_file")
            if [[ "$stored_backup" == "$backup_path" ]]; then
                rm -f "$last_backup_file"
            fi
        fi
        return 0  # Backup was removed
    fi
    return 1  # Backup was kept
}

_claude_sync_safe_copy_file() {
    local src="$1" dst="$2" is_json="${3:-false}"

    if [[ ! -f "$src" ]]; then
        echo "\033[0;31m[ERROR]\033[0m Source does not exist: $src"
        return 1
    fi

    if _claude_sync_is_file_empty "$src"; then
        echo "\033[0;31m[ERROR]\033[0m Source is empty (Dropbox syncing?): $src"
        return 1
    fi

    if [[ "$is_json" == "true" ]] && ! _claude_sync_validate_json "$src"; then
        echo "\033[0;31m[ERROR]\033[0m Invalid JSON: $src"
        return 1
    fi

    cp -p "$src" "$dst"

    if ! _claude_sync_validate_copy "$src" "$dst"; then
        echo "\033[0;31m[ERROR]\033[0m Copy verification failed: $src"
        rm -f "$dst"
        return 1
    fi
    return 0
}

_claude_sync_safe_copy_dir() {
    local src="$1" dst="$2"

    if [[ ! -d "$src" ]]; then
        echo "\033[0;31m[ERROR]\033[0m Source dir does not exist: $src"
        return 1
    fi

    # Check for empty files
    local empty_files=$(find "$src" -type f -empty 2>/dev/null)
    if [[ -n "$empty_files" ]]; then
        echo "\033[0;31m[ERROR]\033[0m Source contains empty files (Dropbox syncing?)"
        return 1
    fi

    # Validate JSON files
    while IFS= read -r -d '' json_file; do
        if ! _claude_sync_validate_json "$json_file"; then
            echo "\033[0;31m[ERROR]\033[0m Invalid JSON in source: ${json_file##*/}"
            return 1
        fi
    done < <(find "$src" -type f -name "*.json" -print0 2>/dev/null)

    rm -rf "$dst"
    cp -rp "$src" "$dst"

    if ! _claude_sync_validate_dir "$src" "$dst"; then
        echo "\033[0;31m[ERROR]\033[0m Directory copy verification failed"
        rm -rf "$dst"
        return 1
    fi
    return 0
}

# Load Dropbox location from config or use default
_claude_sync_load_config() {
    if [[ -f "$CLAUDE_SYNC_CONFIG_FILE" ]]; then
        source "$CLAUDE_SYNC_CONFIG_FILE"
        CLAUDE_SYNC_DROPBOX_DIR="$DROPBOX_BASE/ClaudeCodeSync"
    else
        # Fallback to common locations
        if [[ -d "$HOME/Dropbox" ]]; then
            CLAUDE_SYNC_DROPBOX_DIR="$HOME/Dropbox/ClaudeCodeSync"
        elif [[ -d "$HOME/Library/CloudStorage/Dropbox" ]]; then
            CLAUDE_SYNC_DROPBOX_DIR="$HOME/Library/CloudStorage/Dropbox/ClaudeCodeSync"
        else
            CLAUDE_SYNC_DROPBOX_DIR=""
        fi
    fi
}

# Initialize on source
_claude_sync_load_config

# ─────────────────────────────────────────────────────────────────────────────
# claude-sync-status: Quick status check
# ─────────────────────────────────────────────────────────────────────────────
claude-sync-status() {
    _claude_sync_load_config

    if [[ -z "$CLAUDE_SYNC_DROPBOX_DIR" ]]; then
        echo "\033[0;31m[ERROR]\033[0m Dropbox location not configured. Run claude-sync-setup.sh --config"
        return 1
    fi

    if [[ ! -d "$CLAUDE_SYNC_DROPBOX_DIR" ]]; then
        echo "\033[1;33m[WARN]\033[0m Dropbox sync directory not found. Run --push to initialize."
        return 0
    fi

    local issues=0

    for file in "${CLAUDE_SYNC_FILES[@]}"; do
        local local_file="$CLAUDE_SYNC_LOCAL_DIR/$file"
        local dropbox_file="$CLAUDE_SYNC_DROPBOX_DIR/$file"

        if [[ -L "$local_file" ]]; then
            echo "\033[0;31m[SYMLINK]\033[0m $file is a symlink (run --pull to fix)"
            ((issues++))
        elif [[ -f "$local_file" && -f "$dropbox_file" ]]; then
            if ! diff -q "$local_file" "$dropbox_file" > /dev/null 2>&1; then
                echo "\033[1;33m[DIFF]\033[0m $file differs"
                ((issues++))
            fi
        elif [[ -f "$local_file" && ! -f "$dropbox_file" ]]; then
            echo "\033[1;33m[LOCAL ONLY]\033[0m $file"
            ((issues++))
        elif [[ ! -f "$local_file" && -f "$dropbox_file" ]]; then
            echo "\033[1;33m[DROPBOX ONLY]\033[0m $file"
            ((issues++))
        fi
    done

    # Check for conflicts
    local conflicts
    conflicts=$(find "$CLAUDE_SYNC_DROPBOX_DIR" -maxdepth 2 -name "*conflicted copy*" 2>/dev/null | head -5)
    if [[ -n "$conflicts" ]]; then
        echo "\033[0;31m[CONFLICT]\033[0m Dropbox conflicts detected"
        ((issues++))
    fi

    if (( issues == 0 )); then
        echo "\033[0;32m[OK]\033[0m Claude config in sync"
    fi

    return $issues
}

# ─────────────────────────────────────────────────────────────────────────────
# claude-sync-push: Quick push to Dropbox
# ─────────────────────────────────────────────────────────────────────────────
claude-sync-push() {
    _claude_sync_load_config

    if [[ -z "$CLAUDE_SYNC_DROPBOX_DIR" ]]; then
        echo "Dropbox not configured. Run: claude-sync-setup.sh --config"
        return 1
    fi

    mkdir -p "$CLAUDE_SYNC_DROPBOX_DIR"

    local failed=0

    for file in "${CLAUDE_SYNC_FILES[@]}"; do
        local src="$CLAUDE_SYNC_LOCAL_DIR/$file"
        local dst="$CLAUDE_SYNC_DROPBOX_DIR/$file"
        if [[ -f "$src" && ! -L "$src" ]]; then
            local is_json="false"
            [[ "$file" == *.json ]] && is_json="true"

            if _claude_sync_safe_copy_file "$src" "$dst" "$is_json"; then
                echo "\033[0;32m[PUSHED]\033[0m $file (verified)"
            else
                ((failed++))
            fi
        fi
    done

    for dir in "${CLAUDE_SYNC_DIRS[@]}"; do
        local src="$CLAUDE_SYNC_LOCAL_DIR/$dir"
        local dst="$CLAUDE_SYNC_DROPBOX_DIR/$dir"
        if [[ -d "$src" && ! -L "$src" ]]; then
            if _claude_sync_safe_copy_dir "$src" "$dst"; then
                echo "\033[0;32m[PUSHED]\033[0m $dir/ (verified)"
            else
                ((failed++))
            fi
        fi
    done

    if [[ $failed -gt 0 ]]; then
        echo "\033[0;31m[ERROR]\033[0m Push completed with $failed error(s)"
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# claude-sync-pull: Quick pull from Dropbox
# ─────────────────────────────────────────────────────────────────────────────
claude-sync-pull() {
    _claude_sync_load_config

    if [[ -z "$CLAUDE_SYNC_DROPBOX_DIR" || ! -d "$CLAUDE_SYNC_DROPBOX_DIR" ]]; then
        echo "Dropbox source not found. Run --push on source machine first."
        return 1
    fi

    # Pre-flight validation
    echo "\033[0;34m[INFO]\033[0m Validating source files..."
    local validation_failed=0

    for file in "${CLAUDE_SYNC_FILES[@]}"; do
        local src="$CLAUDE_SYNC_DROPBOX_DIR/$file"
        if [[ -f "$src" ]]; then
            if _claude_sync_is_file_empty "$src"; then
                echo "\033[0;31m[ERROR]\033[0m $file is empty (Dropbox syncing?)"
                ((validation_failed++))
            elif [[ "$file" == *.json ]] && ! _claude_sync_validate_json "$src"; then
                echo "\033[0;31m[ERROR]\033[0m $file has invalid JSON"
                ((validation_failed++))
            fi
        fi
    done

    for dir in "${CLAUDE_SYNC_DIRS[@]}"; do
        local src="$CLAUDE_SYNC_DROPBOX_DIR/$dir"
        if [[ -d "$src" ]]; then
            local empty_files=$(find "$src" -type f -empty 2>/dev/null)
            if [[ -n "$empty_files" ]]; then
                echo "\033[0;31m[ERROR]\033[0m $dir/ contains empty files (Dropbox syncing?)"
                ((validation_failed++))
            fi
        fi
    done

    if [[ $validation_failed -gt 0 ]]; then
        echo "\033[0;31m[ERROR]\033[0m Validation failed. Wait for Dropbox to finish syncing."
        return 1
    fi

    # Create backup before pull for undo capability
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_path="$HOME/.claude_backup.$timestamp"
    if [[ -d "$CLAUDE_SYNC_LOCAL_DIR" ]]; then
        cp -a "$CLAUDE_SYNC_LOCAL_DIR" "$backup_path"
        echo "\033[0;34m[INFO]\033[0m Backup created: $backup_path"

        # Update last backup marker for undo
        echo "$backup_path" > "$HOME/.claude_sync_last_backup"
    fi

    mkdir -p "$CLAUDE_SYNC_LOCAL_DIR"

    local failed=0

    for file in "${CLAUDE_SYNC_FILES[@]}"; do
        local src="$CLAUDE_SYNC_DROPBOX_DIR/$file"
        local dst="$CLAUDE_SYNC_LOCAL_DIR/$file"
        if [[ -f "$src" ]]; then
            [[ -L "$dst" ]] && rm -f "$dst"

            local is_json="false"
            [[ "$file" == *.json ]] && is_json="true"

            if _claude_sync_safe_copy_file "$src" "$dst" "$is_json"; then
                echo "\033[0;32m[PULLED]\033[0m $file (verified)"
            else
                ((failed++))
            fi
        fi
    done

    for dir in "${CLAUDE_SYNC_DIRS[@]}"; do
        local src="$CLAUDE_SYNC_DROPBOX_DIR/$dir"
        local dst="$CLAUDE_SYNC_LOCAL_DIR/$dir"
        if [[ -d "$src" ]]; then
            [[ -L "$dst" ]] && rm -f "$dst"

            if _claude_sync_safe_copy_dir "$src" "$dst"; then
                echo "\033[0;32m[PULLED]\033[0m $dir/ (verified)"
            else
                ((failed++))
            fi
        fi
    done

    if [[ $failed -gt 0 ]]; then
        echo "\033[0;31m[ERROR]\033[0m Pull completed with $failed error(s)"
        echo "\033[1;33m[HINT]\033[0m Run 'claude-sync-undo' to restore previous state"
        return 1
    else
        echo "\033[0;32m[OK]\033[0m Pull complete."

        # Cleanup backup if no changes were made
        _claude_sync_cleanup_backup "$backup_path"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# claude-sync-undo: Restore previous state after a pull
# ─────────────────────────────────────────────────────────────────────────────
claude-sync-undo() {
    local last_backup_file="$HOME/.claude_sync_last_backup"

    if [[ ! -f "$last_backup_file" ]]; then
        echo "\033[0;31m[ERROR]\033[0m No recent pull to undo."
        echo "Run 'claude-sync-backups' to see available backups."
        return 1
    fi

    local backup_path
    backup_path=$(cat "$last_backup_file")

    if [[ ! -d "$backup_path" ]]; then
        echo "\033[0;31m[ERROR]\033[0m Backup not found: $backup_path"
        echo "Run 'claude-sync-backups' to see available backups."
        return 1
    fi

    echo "\033[1;33mThis will restore ~/.claude from:\033[0m"
    echo "  $backup_path"
    echo ""
    echo -n "\033[1;33mProceed? [y/N]:\033[0m "
    read -r response

    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        return 0
    fi

    # Remove current and restore from backup
    rm -rf "$CLAUDE_SYNC_LOCAL_DIR"
    cp -a "$backup_path" "$CLAUDE_SYNC_LOCAL_DIR"

    # Remove the last backup marker (can't undo twice)
    rm -f "$last_backup_file"

    echo "\033[0;32m[OK]\033[0m Restored from $backup_path"
}

# ─────────────────────────────────────────────────────────────────────────────
# claude-sync-backups: List available backups
# ─────────────────────────────────────────────────────────────────────────────
claude-sync-backups() {
    echo "\033[0;36mAvailable backups:\033[0m"
    local found=0

    for backup in "$HOME"/.claude_backup.*; do
        if [[ -d "$backup" ]]; then
            local timestamp="${backup##*.claude_backup.}"
            local formatted
            # Try to format the timestamp nicely
            if [[ "$timestamp" =~ ^[0-9]{8}_[0-9]{6}$ ]]; then
                local date_part="${timestamp:0:4}-${timestamp:4:2}-${timestamp:6:2}"
                local time_part="${timestamp:9:2}:${timestamp:11:2}:${timestamp:13:2}"
                formatted="$date_part $time_part"
            else
                formatted="$timestamp"
            fi
            echo "  $formatted  ->  $backup"
            ((found++))
        fi
    done

    if [[ $found -eq 0 ]]; then
        echo "  (no backups found)"
    else
        echo ""
        echo "To restore a specific backup, run:"
        echo "  rm -rf ~/.claude && cp -a <backup_path> ~/.claude"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# claude-sync-restore: Restore from a specific backup
# ─────────────────────────────────────────────────────────────────────────────
claude-sync-restore() {
    local backup_path="$1"

    if [[ -z "$backup_path" ]]; then
        echo "Usage: claude-sync-restore <backup_path>"
        echo ""
        echo "Available backups:"
        claude-sync-backups
        return 1
    fi

    if [[ ! -d "$backup_path" ]]; then
        echo "\033[0;31m[ERROR]\033[0m Backup not found: $backup_path"
        return 1
    fi

    echo "\033[1;33mThis will restore ~/.claude from:\033[0m"
    echo "  $backup_path"
    echo ""
    echo -n "\033[1;33mProceed? [y/N]:\033[0m "
    read -r response

    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        return 0
    fi

    # Create a backup of current state first
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local current_backup="$HOME/.claude_backup.$timestamp"
    if [[ -d "$CLAUDE_SYNC_LOCAL_DIR" ]]; then
        cp -a "$CLAUDE_SYNC_LOCAL_DIR" "$current_backup"
        echo "\033[0;34m[INFO]\033[0m Current state backed up to: $current_backup"
    fi

    # Restore
    rm -rf "$CLAUDE_SYNC_LOCAL_DIR"
    cp -a "$backup_path" "$CLAUDE_SYNC_LOCAL_DIR"

    echo "\033[0;32m[OK]\033[0m Restored from $backup_path"
}

# ─────────────────────────────────────────────────────────────────────────────
# claude-sync-conflicts: List Dropbox conflicts
# ─────────────────────────────────────────────────────────────────────────────
claude-sync-conflicts() {
    _claude_sync_load_config

    if [[ -z "$CLAUDE_SYNC_DROPBOX_DIR" || ! -d "$CLAUDE_SYNC_DROPBOX_DIR" ]]; then
        echo "Dropbox sync directory not found."
        return 1
    fi

    local conflicts
    conflicts=$(find "$CLAUDE_SYNC_DROPBOX_DIR" -name "*conflicted copy*" 2>/dev/null)

    if [[ -z "$conflicts" ]]; then
        echo "\033[0;32mNo Dropbox conflicts found.\033[0m"
        return 0
    fi

    echo "\033[1;33mDropbox Conflicted Files:\033[0m"
    echo "$conflicts"
}

# ─────────────────────────────────────────────────────────────────────────────
# File Watcher Daemon Functions
# ─────────────────────────────────────────────────────────────────────────────

# Path to daemon control script (update this if installed elsewhere)
CLAUDE_SYNC_DAEMON_SCRIPT="${CLAUDE_SYNC_DAEMON_SCRIPT:-$HOME/dev/apps/util/claude-mac-sync/claude-sync-daemon.sh}"

# Main watcher control function
claude-sync-watch() {
    if [[ ! -f "$CLAUDE_SYNC_DAEMON_SCRIPT" ]]; then
        echo "\033[0;31m[ERROR]\033[0m Daemon script not found: $CLAUDE_SYNC_DAEMON_SCRIPT"
        echo "Set CLAUDE_SYNC_DAEMON_SCRIPT to the correct path."
        return 1
    fi

    "$CLAUDE_SYNC_DAEMON_SCRIPT" "$@"
}

# Convenience aliases
claude-watch-start() {
    claude-sync-watch start
}

claude-watch-stop() {
    claude-sync-watch stop
}

claude-watch-restart() {
    claude-sync-watch restart
}

claude-watch-status() {
    claude-sync-watch status
}

claude-watch-logs() {
    claude-sync-watch follow
}

claude-watch-install() {
    claude-sync-watch install
}
