#!/usr/bin/env bash
#
# claude-sync-setup.sh
# Synchronize ~/.claude configuration files via Dropbox using file copies
#
# Usage:
#   ./claude-sync-setup.sh [--push | --pull | --status | --config | --backup]
#
# Options:
#   --push      Copy ~/.claude files TO Dropbox (overwrites Dropbox)
#   --pull      Copy Dropbox files TO ~/.claude (overwrites local)
#   --status    Show sync status and file differences
#   --config    Configure Dropbox folder location
#   --backup    Create timestamped backup of ~/.claude
#
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────

CLAUDE_DIR="$HOME/.claude"
BACKUP_DIR="$HOME/.claude_backup"
CONFIG_FILE="$HOME/.claude_sync_config"

# Will be set by prompt or config file
DROPBOX_BASE=""
DROPBOX_CLAUDE_DIR=""

# Files and directories to sync
SYNC_FILES=("settings.json" "mcp.json" "CLAUDE.md")
SYNC_DIRS=("skills" "plugins")

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ─────────────────────────────────────────────────────────────────────────────
# Helper Functions
# ─────────────────────────────────────────────────────────────────────────────

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# ─────────────────────────────────────────────────────────────────────────────
# File Integrity Validation Functions
# ─────────────────────────────────────────────────────────────────────────────

# Check if a file is empty
is_file_empty() {
    local file="$1"
    [[ ! -s "$file" ]]
}

# Validate JSON file integrity
validate_json_file() {
    local file="$1"

    # Check if file exists
    if [[ ! -f "$file" ]]; then
        return 1
    fi

    # Check if file is empty
    if [[ ! -s "$file" ]]; then
        return 1
    fi

    # Check JSON syntax using python3 (available on macOS)
    if ! python3 -c "import json; json.load(open('$file'))" 2>/dev/null; then
        return 1
    fi

    return 0
}

# Validate file copy integrity via checksum
validate_file_copy() {
    local src="$1"
    local dst="$2"

    if [[ ! -f "$src" || ! -f "$dst" ]]; then
        return 1
    fi

    local src_sum dst_sum
    src_sum=$(shasum -a 256 "$src" | cut -d' ' -f1)
    dst_sum=$(shasum -a 256 "$dst" | cut -d' ' -f1)

    [[ "$src_sum" == "$dst_sum" ]]
}

# Validate directory copy integrity
validate_dir_copy() {
    local src="$1"
    local dst="$2"

    if [[ ! -d "$src" || ! -d "$dst" ]]; then
        return 1
    fi

    # Compare file counts
    local src_count dst_count
    src_count=$(find "$src" -type f | wc -l | tr -d ' ')
    dst_count=$(find "$dst" -type f | wc -l | tr -d ' ')

    if [[ "$src_count" != "$dst_count" ]]; then
        return 1
    fi

    # Compare each file's checksum
    while IFS= read -r -d '' file; do
        local rel_path="${file#$src/}"
        local dst_file="$dst/$rel_path"

        if [[ ! -f "$dst_file" ]]; then
            return 1
        fi

        if ! validate_file_copy "$file" "$dst_file"; then
            return 1
        fi
    done < <(find "$src" -type f -print0)

    return 0
}

# Check if two directories have identical content (for backup comparison)
dirs_are_identical() {
    local dir1="$1"
    local dir2="$2"

    # Both must exist
    if [[ ! -d "$dir1" || ! -d "$dir2" ]]; then
        return 1
    fi

    # Compare file counts first (quick check)
    local count1 count2
    count1=$(find "$dir1" -type f | wc -l | tr -d ' ')
    count2=$(find "$dir2" -type f | wc -l | tr -d ' ')

    if [[ "$count1" != "$count2" ]]; then
        return 1
    fi

    # Compare each file's checksum
    while IFS= read -r -d '' file; do
        local rel_path="${file#$dir1/}"
        local other_file="$dir2/$rel_path"

        if [[ ! -f "$other_file" ]]; then
            return 1
        fi

        local sum1 sum2
        sum1=$(shasum -a 256 "$file" 2>/dev/null | cut -d' ' -f1)
        sum2=$(shasum -a 256 "$other_file" 2>/dev/null | cut -d' ' -f1)

        if [[ "$sum1" != "$sum2" ]]; then
            return 1
        fi
    done < <(find "$dir1" -type f -print0)

    return 0
}

# Compare only synced files between two directories
# Ignores debug/, file-history/, todos/, etc.
synced_files_are_identical() {
    local dir1="$1"
    local dir2="$2"

    # Both must exist
    if [[ ! -d "$dir1" || ! -d "$dir2" ]]; then
        return 1
    fi

    # Compare individual sync files
    for file in "${SYNC_FILES[@]}"; do
        local file1="$dir1/$file"
        local file2="$dir2/$file"

        # If file exists in one but not the other, they differ
        if [[ -f "$file1" && ! -f "$file2" ]] || [[ ! -f "$file1" && -f "$file2" ]]; then
            return 1
        fi

        # If both exist, compare checksums
        if [[ -f "$file1" ]]; then
            local sum1 sum2
            sum1=$(shasum -a 256 "$file1" 2>/dev/null | cut -d' ' -f1)
            sum2=$(shasum -a 256 "$file2" 2>/dev/null | cut -d' ' -f1)

            if [[ "$sum1" != "$sum2" ]]; then
                return 1
            fi
        fi
    done

    # Compare sync directories
    for dir in "${SYNC_DIRS[@]}"; do
        local dir1_path="$dir1/$dir"
        local dir2_path="$dir2/$dir"

        # If directory exists in one but not the other, they differ
        if [[ -d "$dir1_path" && ! -d "$dir2_path" ]] || [[ ! -d "$dir1_path" && -d "$dir2_path" ]]; then
            return 1
        fi

        # If both exist, compare all files within
        if [[ -d "$dir1_path" ]]; then
            # Check file counts
            local count1 count2
            count1=$(find "$dir1_path" -type f | wc -l | tr -d ' ')
            count2=$(find "$dir2_path" -type f | wc -l | tr -d ' ')

            if [[ "$count1" != "$count2" ]]; then
                return 1
            fi

            # Compare each file
            while IFS= read -r -d '' file; do
                local rel_path="${file#$dir1_path/}"
                local other_file="$dir2_path/$rel_path"

                if [[ ! -f "$other_file" ]]; then
                    return 1
                fi

                local sum1 sum2
                sum1=$(shasum -a 256 "$file" 2>/dev/null | cut -d' ' -f1)
                sum2=$(shasum -a 256 "$other_file" 2>/dev/null | cut -d' ' -f1)

                if [[ "$sum1" != "$sum2" ]]; then
                    return 1
                fi
            done < <(find "$dir1_path" -type f -print0)
        fi
    done

    return 0
}

# Remove a backup if synced files are identical (no synced changes occurred)
# Only compares synced files, ignoring debug/, file-history/, todos/, etc.
cleanup_backup_if_unchanged() {
    local backup_path="$1"

    if [[ -z "$backup_path" || ! -d "$backup_path" ]]; then
        return 0
    fi

    if synced_files_are_identical "$backup_path" "$CLAUDE_DIR"; then
        log_info "No synced files changed, removing unnecessary backup: $backup_path"
        rm -rf "$backup_path"

        # Update symlink to point to previous backup if exists
        if [[ -L "$BACKUP_DIR" ]]; then
            rm -f "$BACKUP_DIR"
            # Find most recent remaining backup
            local latest_backup
            latest_backup=$(ls -dt "$HOME"/.claude_backup.* 2>/dev/null | head -1)
            if [[ -n "$latest_backup" && -d "$latest_backup" ]]; then
                ln -s "$latest_backup" "$BACKUP_DIR"
            fi
        fi

        # Clear last backup marker if it pointed to this backup
        if [[ -f "$HOME/.claude_sync_last_backup" ]]; then
            local stored_backup
            stored_backup=$(cat "$HOME/.claude_sync_last_backup")
            if [[ "$stored_backup" == "$backup_path" ]]; then
                rm -f "$HOME/.claude_sync_last_backup"
            fi
        fi

        return 0  # Backup was removed (no changes)
    fi

    return 1  # Backup was kept (changes occurred)
}

# Copy file with integrity validation
safe_copy_file() {
    local src="$1"
    local dst="$2"
    local is_json="${3:-false}"

    # Check source exists
    if [[ ! -f "$src" ]]; then
        log_error "Source file does not exist: $src"
        return 1
    fi

    # Check source is not empty
    if is_file_empty "$src"; then
        log_error "Source file is empty (possibly Dropbox sync in progress): $src"
        return 1
    fi

    # Validate JSON syntax if applicable
    if [[ "$is_json" == "true" ]]; then
        if ! validate_json_file "$src"; then
            log_error "Source file has invalid JSON: $src"
            return 1
        fi
    fi

    # Perform the copy
    cp -p "$src" "$dst"

    # Validate the copy succeeded
    if ! validate_file_copy "$src" "$dst"; then
        log_error "Copy verification failed (checksum mismatch): $src -> $dst"
        rm -f "$dst"
        return 1
    fi

    return 0
}

# Copy directory with integrity validation
safe_copy_dir() {
    local src="$1"
    local dst="$2"

    # Check source exists
    if [[ ! -d "$src" ]]; then
        log_error "Source directory does not exist: $src"
        return 1
    fi

    # Check for any empty files in source (sign of incomplete sync)
    local empty_files
    empty_files=$(find "$src" -type f -empty 2>/dev/null)
    if [[ -n "$empty_files" ]]; then
        log_error "Source directory contains empty files (possibly Dropbox sync in progress):"
        echo "$empty_files" | head -5
        return 1
    fi

    # Validate any JSON files in the source
    while IFS= read -r -d '' json_file; do
        if ! validate_json_file "$json_file"; then
            log_error "Invalid JSON file in source directory: $json_file"
            return 1
        fi
    done < <(find "$src" -type f -name "*.json" -print0)

    # Perform the copy
    rm -rf "$dst"
    cp -rp "$src" "$dst"

    # Validate the copy succeeded
    if ! validate_dir_copy "$src" "$dst"; then
        log_error "Directory copy verification failed: $src -> $dst"
        rm -rf "$dst"
        return 1
    fi

    return 0
}

confirm() {
    local prompt="$1"
    local response
    echo -en "${YELLOW}$prompt [y/N]:${NC} "
    read -r response
    [[ "$response" =~ ^[Yy]$ ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# Dropbox Location Configuration
# ─────────────────────────────────────────────────────────────────────────────

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        if [[ -n "$DROPBOX_BASE" && -d "$DROPBOX_BASE" ]]; then
            DROPBOX_CLAUDE_DIR="$DROPBOX_BASE/ClaudeCodeSync"
            return 0
        fi
    fi
    return 1
}

prompt_dropbox_location() {
    echo ""
    log_info "Dropbox folder location required."
    echo ""

    # Try to detect common Dropbox locations
    local detected=""
    local candidates=(
        "$HOME/Dropbox"
        "$HOME/Library/CloudStorage/Dropbox"
        "/Users/Shared/Dropbox"
    )

    for candidate in "${candidates[@]}"; do
        if [[ -d "$candidate" ]]; then
            detected="$candidate"
            break
        fi
    done

    if [[ -n "$detected" ]]; then
        echo -e "  Detected: ${GREEN}$detected${NC}"
        echo ""
    fi

    local default_prompt=""
    if [[ -n "$detected" ]]; then
        default_prompt=" [$detected]"
    fi

    while true; do
        echo -en "${BLUE}Enter your Dropbox folder path${default_prompt}:${NC} "
        read -r user_input

        # Use detected path if user just presses Enter
        if [[ -z "$user_input" && -n "$detected" ]]; then
            user_input="$detected"
        fi

        # Expand ~ if present
        user_input="${user_input/#\~/$HOME}"

        # Validate the path
        if [[ -z "$user_input" ]]; then
            log_error "Path cannot be empty."
            continue
        fi

        if [[ ! -d "$user_input" ]]; then
            log_error "Directory does not exist: $user_input"
            continue
        fi

        DROPBOX_BASE="$user_input"
        DROPBOX_CLAUDE_DIR="$DROPBOX_BASE/ClaudeCodeSync"
        break
    done

    # Save for future use
    echo "DROPBOX_BASE=\"$DROPBOX_BASE\"" > "$CONFIG_FILE"
    log_success "Saved Dropbox location to $CONFIG_FILE"
    echo ""
}

ensure_config() {
    if ! load_config; then
        prompt_dropbox_location
    else
        log_info "Using Dropbox location: $DROPBOX_BASE"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Backup
# ─────────────────────────────────────────────────────────────────────────────

# Creates backup and stores path in LAST_CREATED_BACKUP variable for later cleanup
LAST_CREATED_BACKUP=""

create_backup() {
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_path="$BACKUP_DIR.$timestamp"

    log_info "Creating backup of ~/.claude..."

    if [[ ! -d "$CLAUDE_DIR" ]]; then
        log_warn "~/.claude does not exist. Nothing to backup."
        LAST_CREATED_BACKUP=""
        return 0
    fi

    cp -a "$CLAUDE_DIR" "$backup_path"
    log_success "Backup created: $backup_path"

    # Store for potential cleanup later
    LAST_CREATED_BACKUP="$backup_path"

    # Save the backup path for undo capability
    echo "$backup_path" > "$HOME/.claude_sync_last_backup"

    # Also update the "latest" backup symlink
    if [[ -L "$BACKUP_DIR" ]]; then
        rm -f "$BACKUP_DIR"
    elif [[ -d "$BACKUP_DIR" ]]; then
        # Old directory exists, rename it with timestamp
        mv "$BACKUP_DIR" "$BACKUP_DIR.old.$timestamp"
        log_info "Renamed existing backup dir to $BACKUP_DIR.old.$timestamp"
    fi
    ln -s "$backup_path" "$BACKUP_DIR"
    log_info "Latest backup link: $BACKUP_DIR -> $backup_path"
}

# ─────────────────────────────────────────────────────────────────────────────
# Push: Copy local files TO Dropbox
# ─────────────────────────────────────────────────────────────────────────────

push_to_dropbox() {
    ensure_config

    log_info "Pushing ~/.claude to Dropbox..."
    echo ""

    # Create Dropbox target directory
    if [[ ! -d "$DROPBOX_CLAUDE_DIR" ]]; then
        mkdir -p "$DROPBOX_CLAUDE_DIR"
        log_success "Created $DROPBOX_CLAUDE_DIR"
    fi

    # Create backup first
    create_backup

    local copied=0
    local skipped=0
    local failed=0

    # Copy files
    for file in "${SYNC_FILES[@]}"; do
        local src="$CLAUDE_DIR/$file"
        local dst="$DROPBOX_CLAUDE_DIR/$file"

        if [[ -f "$src" ]]; then
            # Skip if it's a symlink (from old setup)
            if [[ -L "$src" ]]; then
                log_warn "$file is a symlink, skipping (resolve manually)"
                ((skipped++))
                continue
            fi

            # Determine if file is JSON
            local is_json="false"
            [[ "$file" == *.json ]] && is_json="true"

            # Use safe copy with validation
            if safe_copy_file "$src" "$dst" "$is_json"; then
                log_success "Copied $file (verified)"
                ((copied++))
            else
                log_error "Failed to copy $file"
                ((failed++))
            fi
        else
            log_warn "$file does not exist locally, skipping"
            ((skipped++))
        fi
    done

    # Copy directories
    for dir in "${SYNC_DIRS[@]}"; do
        local src="$CLAUDE_DIR/$dir"
        local dst="$DROPBOX_CLAUDE_DIR/$dir"

        if [[ -d "$src" ]]; then
            # Skip if it's a symlink (from old setup)
            if [[ -L "$src" ]]; then
                log_warn "$dir/ is a symlink, skipping (resolve manually)"
                ((skipped++))
                continue
            fi

            # Use safe copy with validation
            if safe_copy_dir "$src" "$dst"; then
                log_success "Copied $dir/ (verified)"
                ((copied++))
            else
                log_error "Failed to copy $dir/"
                ((failed++))
            fi
        else
            log_warn "$dir/ does not exist locally, skipping"
            ((skipped++))
        fi
    done

    echo ""
    if [[ $failed -gt 0 ]]; then
        log_error "Push completed with errors. Copied: $copied, Skipped: $skipped, Failed: $failed"
        return 1
    else
        log_success "Push complete. Copied: $copied, Skipped: $skipped (all verified)"
        log_info "Files are now in: $DROPBOX_CLAUDE_DIR"

        # Cleanup backup if no changes were made
        if [[ -n "$LAST_CREATED_BACKUP" ]]; then
            cleanup_backup_if_unchanged "$LAST_CREATED_BACKUP"
        fi
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Pull: Copy Dropbox files TO local
# ─────────────────────────────────────────────────────────────────────────────

pull_from_dropbox() {
    ensure_config

    log_info "Pulling from Dropbox to ~/.claude..."
    echo ""

    if [[ ! -d "$DROPBOX_CLAUDE_DIR" ]]; then
        log_error "Dropbox source does not exist: $DROPBOX_CLAUDE_DIR"
        log_error "Run --push first on the source machine."
        exit 1
    fi

    # Pre-flight validation: check all source files before making any changes
    log_info "Validating source files..."
    local validation_failed=0

    for file in "${SYNC_FILES[@]}"; do
        local src="$DROPBOX_CLAUDE_DIR/$file"
        if [[ -f "$src" ]]; then
            if is_file_empty "$src"; then
                log_error "$file is empty (Dropbox may still be syncing)"
                ((validation_failed++))
            elif [[ "$file" == *.json ]]; then
                if ! validate_json_file "$src"; then
                    log_error "$file has invalid JSON content"
                    ((validation_failed++))
                fi
            fi
        fi
    done

    for dir in "${SYNC_DIRS[@]}"; do
        local src="$DROPBOX_CLAUDE_DIR/$dir"
        if [[ -d "$src" ]]; then
            local empty_files
            empty_files=$(find "$src" -type f -empty 2>/dev/null)
            if [[ -n "$empty_files" ]]; then
                log_error "$dir/ contains empty files (Dropbox may still be syncing)"
                ((validation_failed++))
            fi

            # Check JSON files in directory
            while IFS= read -r -d '' json_file; do
                if ! validate_json_file "$json_file"; then
                    log_error "Invalid JSON in $dir/: ${json_file##*/}"
                    ((validation_failed++))
                fi
            done < <(find "$src" -type f -name "*.json" -print0 2>/dev/null)
        fi
    done

    if [[ $validation_failed -gt 0 ]]; then
        echo ""
        log_error "Pre-flight validation failed with $validation_failed error(s)."
        log_error "Please wait for Dropbox to finish syncing and try again."
        log_info "Tip: Check Dropbox menu bar icon for sync status."
        exit 1
    fi

    log_success "All source files validated"
    echo ""

    # Create backup first
    create_backup

    # Ensure local directory exists
    mkdir -p "$CLAUDE_DIR"

    local copied=0
    local skipped=0
    local failed=0

    # Copy files
    for file in "${SYNC_FILES[@]}"; do
        local src="$DROPBOX_CLAUDE_DIR/$file"
        local dst="$CLAUDE_DIR/$file"

        if [[ -f "$src" ]]; then
            # Remove existing symlink if present (from old setup)
            if [[ -L "$dst" ]]; then
                rm -f "$dst"
                log_info "Removed old symlink: $file"
            fi

            # Determine if file is JSON
            local is_json="false"
            [[ "$file" == *.json ]] && is_json="true"

            # Use safe copy with validation
            if safe_copy_file "$src" "$dst" "$is_json"; then
                log_success "Copied $file (verified)"
                ((copied++))
            else
                log_error "Failed to copy $file"
                ((failed++))
            fi
        else
            log_warn "$file does not exist in Dropbox, skipping"
            ((skipped++))
        fi
    done

    # Copy directories
    for dir in "${SYNC_DIRS[@]}"; do
        local src="$DROPBOX_CLAUDE_DIR/$dir"
        local dst="$CLAUDE_DIR/$dir"

        if [[ -d "$src" ]]; then
            # Remove existing symlink if present (from old setup)
            if [[ -L "$dst" ]]; then
                rm -f "$dst"
                log_info "Removed old symlink: $dir/"
            fi

            # Use safe copy with validation
            if safe_copy_dir "$src" "$dst"; then
                log_success "Copied $dir/ (verified)"
                ((copied++))
            else
                log_error "Failed to copy $dir/"
                ((failed++))
            fi
        else
            log_warn "$dir/ does not exist in Dropbox, skipping"
            ((skipped++))
        fi
    done

    echo ""
    if [[ $failed -gt 0 ]]; then
        log_error "Pull completed with errors. Copied: $copied, Skipped: $skipped, Failed: $failed"
        log_info "Your previous config was backed up. Check the backup if needed."
        return 1
    else
        log_success "Pull complete. Copied: $copied, Skipped: $skipped (all verified)"

        # Cleanup backup if no changes were made
        if [[ -n "$LAST_CREATED_BACKUP" ]]; then
            cleanup_backup_if_unchanged "$LAST_CREATED_BACKUP"
        fi
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Undo: Restore previous state after a pull
# ─────────────────────────────────────────────────────────────────────────────

LAST_BACKUP_FILE="$HOME/.claude_sync_last_backup"

undo_pull() {
    if [[ ! -f "$LAST_BACKUP_FILE" ]]; then
        log_error "No recent pull to undo."
        log_info "Run --backups to see available backups."
        exit 1
    fi

    local backup_path
    backup_path=$(cat "$LAST_BACKUP_FILE")

    if [[ ! -d "$backup_path" ]]; then
        log_error "Backup not found: $backup_path"
        log_info "Run --backups to see available backups."
        exit 1
    fi

    log_warn "This will restore ~/.claude from:"
    echo "  $backup_path"
    echo ""

    if ! confirm "Proceed with undo?"; then
        log_info "Aborted."
        exit 0
    fi

    # Remove current and restore from backup
    rm -rf "$CLAUDE_DIR"
    cp -a "$backup_path" "$CLAUDE_DIR"

    # Remove the last backup marker (can't undo twice)
    rm -f "$LAST_BACKUP_FILE"

    log_success "Restored from $backup_path"
}

# ─────────────────────────────────────────────────────────────────────────────
# List Backups: Show all available backups
# ─────────────────────────────────────────────────────────────────────────────

list_backups() {
    echo ""
    echo -e "${CYAN}Available backups:${NC}"
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
            echo -e "  ${GREEN}$formatted${NC}  ->  $backup"
            ((found++))
        fi
    done

    if [[ $found -eq 0 ]]; then
        echo "  (no backups found)"
    else
        echo ""
        log_info "To restore a specific backup, run:"
        echo "  $0 --restore <backup_path>"
    fi
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# Restore: Restore from a specific backup
# ─────────────────────────────────────────────────────────────────────────────

restore_backup() {
    local backup_path="$1"

    if [[ -z "$backup_path" ]]; then
        log_error "Usage: $0 --restore <backup_path>"
        echo ""
        list_backups
        exit 1
    fi

    if [[ ! -d "$backup_path" ]]; then
        log_error "Backup not found: $backup_path"
        list_backups
        exit 1
    fi

    log_warn "This will restore ~/.claude from:"
    echo "  $backup_path"
    echo ""

    if ! confirm "Proceed with restore?"; then
        log_info "Aborted."
        exit 0
    fi

    # Create a backup of current state first
    create_backup

    # Restore
    rm -rf "$CLAUDE_DIR"
    cp -a "$backup_path" "$CLAUDE_DIR"

    log_success "Restored from $backup_path"
}

# ─────────────────────────────────────────────────────────────────────────────
# Cleanup Backups: Remove redundant backups keeping only unique ones
# ─────────────────────────────────────────────────────────────────────────────

cleanup_backups() {
    local max_unique_backups="${1:-10}"  # Keep at most 10 unique backups by default
    local dry_run="${2:-false}"

    echo ""
    log_info "Analyzing backups for redundant copies (comparing synced files only)..."
    log_info "Retention limit: $max_unique_backups unique backups"

    # Collect all backups sorted by timestamp (oldest first)
    local backups=()
    while IFS= read -r backup; do
        [[ -d "$backup" ]] && backups+=("$backup")
    done < <(ls -dt "$HOME"/.claude_backup.* 2>/dev/null | tail -r)

    local total=${#backups[@]}
    if [[ $total -eq 0 ]]; then
        log_info "No backups found."
        return 0
    fi

    log_info "Found $total backup(s). Comparing synced files only..."

    local removed=0
    local kept=0
    local unique_kept=0
    local prev_backup=""
    local unique_backups=()

    for backup in "${backups[@]}"; do
        if [[ -z "$prev_backup" ]]; then
            # Keep the first (oldest) backup
            log_success "Keeping: $backup (oldest)"
            prev_backup="$backup"
            unique_backups+=("$backup")
            ((kept++))
            ((unique_kept++))
            continue
        fi

        # Compare synced files only with previous unique backup
        if synced_files_are_identical "$backup" "$prev_backup"; then
            log_info "Removing redundant: $backup (synced files identical)"
            if [[ "$dry_run" != "true" ]]; then
                rm -rf "$backup"
            fi
            ((removed++))
        else
            log_success "Keeping: $backup (synced files changed)"
            prev_backup="$backup"
            unique_backups+=("$backup")
            ((kept++))
            ((unique_kept++))
        fi
    done

    # Apply retention limit: keep only the most recent N unique backups
    local excess=$((unique_kept - max_unique_backups))
    if [[ $excess -gt 0 ]]; then
        echo ""
        log_info "Applying retention limit: removing $excess oldest unique backup(s)..."
        for ((i=0; i<excess; i++)); do
            local old_backup="${unique_backups[$i]}"
            log_info "Removing old backup: $old_backup"
            if [[ "$dry_run" != "true" ]]; then
                rm -rf "$old_backup"
            fi
            ((removed++))
            ((kept--))
        done
    fi

    echo ""
    if [[ "$dry_run" == "true" ]]; then
        log_success "Dry run complete. Would remove: $removed, Would keep: $kept"
    else
        log_success "Cleanup complete. Removed: $removed, Kept: $kept"
    fi

    # Update symlink to point to most recent remaining backup
    if [[ "$dry_run" != "true" ]]; then
        local latest_backup
        latest_backup=$(ls -dt "$HOME"/.claude_backup.* 2>/dev/null | head -1)
        if [[ -n "$latest_backup" && -d "$latest_backup" ]]; then
            if [[ -L "$BACKUP_DIR" ]]; then
                rm -f "$BACKUP_DIR"
            fi
            ln -s "$latest_backup" "$BACKUP_DIR"
            log_info "Latest backup link updated: $BACKUP_DIR -> $latest_backup"
        fi
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Status: Show sync status and differences
# ─────────────────────────────────────────────────────────────────────────────

show_status() {
    ensure_config

    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  Claude Code Sync Status${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  Local:   ${BLUE}$CLAUDE_DIR${NC}"
    echo -e "  Dropbox: ${BLUE}$DROPBOX_CLAUDE_DIR${NC}"
    echo ""

    if [[ ! -d "$DROPBOX_CLAUDE_DIR" ]]; then
        log_warn "Dropbox directory does not exist. Run --push to initialize."
        return 0
    fi

    echo -e "${CYAN}Files:${NC}"
    for file in "${SYNC_FILES[@]}"; do
        local local_file="$CLAUDE_DIR/$file"
        local dropbox_file="$DROPBOX_CLAUDE_DIR/$file"

        echo -n "  $file: "

        if [[ -L "$local_file" ]]; then
            echo -e "${YELLOW}LOCAL IS SYMLINK${NC} (run --pull to fix)"
        elif [[ ! -f "$local_file" && ! -f "$dropbox_file" ]]; then
            echo -e "${YELLOW}missing both${NC}"
        elif [[ ! -f "$local_file" ]]; then
            echo -e "${YELLOW}missing locally${NC} (run --pull)"
        elif [[ ! -f "$dropbox_file" ]]; then
            echo -e "${YELLOW}missing in Dropbox${NC} (run --push)"
        elif diff -q "$local_file" "$dropbox_file" > /dev/null 2>&1; then
            echo -e "${GREEN}in sync${NC}"
        else
            local local_mod dropbox_mod
            local_mod=$(stat -f %m "$local_file" 2>/dev/null || stat -c %Y "$local_file" 2>/dev/null)
            dropbox_mod=$(stat -f %m "$dropbox_file" 2>/dev/null || stat -c %Y "$dropbox_file" 2>/dev/null)

            if [[ "$local_mod" -gt "$dropbox_mod" ]]; then
                echo -e "${YELLOW}local is newer${NC} (run --push)"
            else
                echo -e "${YELLOW}Dropbox is newer${NC} (run --pull)"
            fi
        fi
    done

    echo ""
    echo -e "${CYAN}Directories:${NC}"
    for dir in "${SYNC_DIRS[@]}"; do
        local local_dir="$CLAUDE_DIR/$dir"
        local dropbox_dir="$DROPBOX_CLAUDE_DIR/$dir"

        echo -n "  $dir/: "

        if [[ -L "$local_dir" ]]; then
            echo -e "${YELLOW}LOCAL IS SYMLINK${NC} (run --pull to fix)"
        elif [[ ! -d "$local_dir" && ! -d "$dropbox_dir" ]]; then
            echo -e "${YELLOW}missing both${NC}"
        elif [[ ! -d "$local_dir" ]]; then
            echo -e "${YELLOW}missing locally${NC} (run --pull)"
        elif [[ ! -d "$dropbox_dir" ]]; then
            echo -e "${YELLOW}missing in Dropbox${NC} (run --push)"
        else
            local local_count dropbox_count
            local_count=$(find "$local_dir" -type f 2>/dev/null | wc -l | tr -d ' ')
            dropbox_count=$(find "$dropbox_dir" -type f 2>/dev/null | wc -l | tr -d ' ')
            echo -e "${GREEN}exists${NC} (local: $local_count files, Dropbox: $dropbox_count files)"
        fi
    done

    # Check for conflicts
    echo ""
    local conflicts
    conflicts=$(find "$DROPBOX_CLAUDE_DIR" -name "*conflicted copy*" 2>/dev/null || true)
    if [[ -n "$conflicts" ]]; then
        echo -e "${RED}Dropbox Conflicts Detected:${NC}"
        echo "$conflicts" | while read -r f; do
            echo -e "  ${RED}!${NC} $f"
        done
    else
        echo -e "${GREEN}No Dropbox conflicts.${NC}"
    fi

    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# Main Entry Point
# ─────────────────────────────────────────────────────────────────────────────

usage() {
    cat << EOF
Usage: $0 [--push | --pull | --status | --config | --backup | --undo | --backups | --restore <path>]
       $0 [--watch-start | --watch-stop | --watch-status | --watch-install]

Options:
  --push           Copy ~/.claude files TO Dropbox (overwrites Dropbox)
  --pull           Copy Dropbox files TO ~/.claude (overwrites local)
  --status         Show sync status and file differences
  --config         Reconfigure Dropbox folder location
  --backup         Create timestamped backup of ~/.claude
  --undo           Restore previous state after a pull
  --backups        List all available backups
  --restore <path> Restore from a specific backup
  --cleanup-backups [N] [--dry-run]
                    Remove redundant backups (keeps only unique synced files)
                    N: max unique backups to keep (default: 10)
                    --dry-run: preview what would be deleted without removing

Watch Daemon (automatic two-way sync):
  --watch-install  Build and install the watch daemon
  --watch-start    Start the watch daemon
  --watch-stop     Stop the watch daemon
  --watch-status   Show watch daemon status
  --watch-logs     Follow daemon logs

Workflow:
  1. On primary machine:   ./claude-sync-setup.sh --push
  2. Wait for Dropbox to sync
  3. On secondary machine: ./claude-sync-setup.sh --pull
  4. Check status anytime: ./claude-sync-setup.sh --status

For automatic two-way sync:
  1. Install daemon:  ./claude-sync-setup.sh --watch-install
  2. Check status:    ./claude-sync-setup.sh --watch-status
  3. View logs:       ./claude-sync-setup.sh --watch-logs

After initial setup, use --push/--pull to sync changes between machines.
Use --undo immediately after a pull to revert to your previous state.
EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# Watch Daemon Commands
# ─────────────────────────────────────────────────────────────────────────────

DAEMON_SCRIPT="$(dirname "${BASH_SOURCE[0]}")/claude-sync-daemon.sh"

run_daemon_cmd() {
    if [[ ! -f "$DAEMON_SCRIPT" ]]; then
        log_error "Daemon script not found: $DAEMON_SCRIPT"
        exit 1
    fi
    "$DAEMON_SCRIPT" "$@"
}

main() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Claude Code Configuration Sync"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    case "${1:-}" in
        --push)
            if confirm "This will overwrite Dropbox with local files. Continue?"; then
                push_to_dropbox
            else
                log_info "Aborted."
            fi
            ;;
        --pull)
            if confirm "This will overwrite local files with Dropbox. Continue?"; then
                pull_from_dropbox
            else
                log_info "Aborted."
            fi
            ;;
        --status)
            show_status
            ;;
        --config)
            rm -f "$CONFIG_FILE"
            prompt_dropbox_location
            ;;
        --backup)
            create_backup
            ;;
        --undo)
            undo_pull
            ;;
        --backups)
            list_backups
            ;;
        --restore)
            restore_backup "${2:-}"
            ;;
        --cleanup-backups)
            shift
            local max_backups=10
            local dry_run=false

            # Parse optional arguments
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --dry-run)
                        dry_run=true
                        shift
                        ;;
                    [0-9]*)
                        max_backups="$1"
                        shift
                        ;;
                    *)
                        break
                        ;;
                esac
            done

            if [[ "$dry_run" == "true" ]]; then
                log_info "Running in dry-run mode (no files will be deleted)..."
                cleanup_backups "$max_backups" "true"
            else
                if confirm "This will remove redundant backups (keeping max $max_backups unique). Continue?"; then
                    cleanup_backups "$max_backups" "false"
                else
                    log_info "Aborted."
                fi
            fi
            ;;
        --watch-install)
            run_daemon_cmd install
            ;;
        --watch-start)
            run_daemon_cmd start
            ;;
        --watch-stop)
            run_daemon_cmd stop
            ;;
        --watch-restart)
            run_daemon_cmd restart
            ;;
        --watch-status)
            run_daemon_cmd status
            ;;
        --watch-logs)
            run_daemon_cmd follow
            ;;
        --watch-build)
            run_daemon_cmd build
            ;;
        --help|-h|"")
            usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
}

main "$@"
