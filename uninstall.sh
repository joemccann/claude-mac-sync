#!/usr/bin/env bash
#
# uninstall.sh
# Complete uninstall script for claude-mac-sync
#
# Usage:
#   ./uninstall.sh           Interactive uninstall with prompts
#   ./uninstall.sh --force   Remove everything without prompts
#   ./uninstall.sh --dry-run Show what would be removed
#
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────

PLIST_NAME="com.claude.sync-watch"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_NAME.plist"
CONFIG_FILE="$HOME/.claude_sync_config"
LOG_DIR="$HOME/.claude_sync_logs"
LAST_BACKUP_FILE="$HOME/.claude_sync_last_backup"
BACKUP_SYMLINK="$HOME/.claude_backup"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Flags
FORCE=false
DRY_RUN=false
KEEP_DROPBOX=false
KEEP_BACKUPS=false

# ─────────────────────────────────────────────────────────────────────────────
# Helper Functions
# ─────────────────────────────────────────────────────────────────────────────

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_dry()     { echo -e "${CYAN}[DRY-RUN]${NC} Would remove: $1"; }

confirm() {
    local prompt="$1"
    if [[ "$FORCE" == "true" ]]; then
        return 0
    fi
    local response
    echo -en "${YELLOW}$prompt [y/N]:${NC} "
    read -r response
    [[ "$response" =~ ^[Yy]$ ]]
}

remove_file() {
    local path="$1"
    local desc="${2:-$path}"
    if [[ -f "$path" || -L "$path" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log_dry "$desc"
        else
            rm -f "$path"
            log_success "Removed: $desc"
        fi
        return 0
    fi
    return 1
}

remove_dir() {
    local path="$1"
    local desc="${2:-$path}"
    if [[ -d "$path" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log_dry "$desc"
        else
            rm -rf "$path"
            log_success "Removed: $desc"
        fi
        return 0
    fi
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Detect Dropbox Location
# ─────────────────────────────────────────────────────────────────────────────

detect_dropbox() {
    local dropbox_base=""
    
    # Try config file first
    if [[ -f "$CONFIG_FILE" ]]; then
        dropbox_base=$(grep "^DROPBOX_BASE=" "$CONFIG_FILE" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | sed "s|^~|$HOME|" || true)
    fi
    
    # Fall back to detection
    if [[ -z "$dropbox_base" || ! -d "$dropbox_base" ]]; then
        for candidate in "$HOME/Dropbox" "$HOME/Dropbox (Personal)" "$HOME/Library/CloudStorage/Dropbox"; do
            if [[ -d "$candidate" ]]; then
                dropbox_base="$candidate"
                break
            fi
        done
    fi
    
    echo "$dropbox_base"
}

# ─────────────────────────────────────────────────────────────────────────────
# Uninstall Steps
# ─────────────────────────────────────────────────────────────────────────────

stop_daemon() {
    echo ""
    echo -e "${BOLD}Step 1: Stop and unload daemon${NC}"
    echo "─────────────────────────────────"
    
    local daemon_running=false
    
    if launchctl list 2>/dev/null | grep -q "$PLIST_NAME"; then
        daemon_running=true
        if [[ "$DRY_RUN" == "true" ]]; then
            log_dry "Would unload launchd agent: $PLIST_NAME"
        else
            log_info "Stopping daemon..."
            launchctl unload "$PLIST_PATH" 2>/dev/null || true
            log_success "Daemon stopped and unloaded"
        fi
    else
        log_info "Daemon not running"
    fi
    
    # Kill any orphan processes
    local pids
    pids=$(pgrep -f "claude-sync-watch" 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log_dry "Would kill processes: $pids"
        else
            log_info "Killing orphan processes: $pids"
            echo "$pids" | xargs kill -9 2>/dev/null || true
            log_success "Killed orphan processes"
        fi
    fi
    
    # Remove PID file
    remove_file "$HOME/.claude/.sync.pid" "~/.claude/.sync.pid (PID file)" || true
}

remove_launchd_plist() {
    echo ""
    echo -e "${BOLD}Step 2: Remove launchd plist${NC}"
    echo "─────────────────────────────────"
    
    if ! remove_file "$PLIST_PATH" "~/Library/LaunchAgents/$PLIST_NAME.plist"; then
        log_info "Plist not found (already removed or never installed)"
    fi
}

remove_config_files() {
    echo ""
    echo -e "${BOLD}Step 3: Remove configuration files${NC}"
    echo "─────────────────────────────────"
    
    remove_file "$CONFIG_FILE" "~/.claude_sync_config (Dropbox location config)" || true
    remove_file "$LAST_BACKUP_FILE" "~/.claude_sync_last_backup (undo marker)" || true
    remove_file "$HOME/.claude/.sync_state.json" "~/.claude/.sync_state.json (sync state)" || true
    remove_file "$BACKUP_SYMLINK" "~/.claude_backup (symlink to latest backup)" || true
}

remove_log_directory() {
    echo ""
    echo -e "${BOLD}Step 4: Remove log directory${NC}"
    echo "─────────────────────────────────"
    
    if [[ -d "$LOG_DIR" ]]; then
        local log_size
        log_size=$(du -sh "$LOG_DIR" 2>/dev/null | cut -f1 || echo "unknown")
        log_info "Log directory size: $log_size"
        
        if ! remove_dir "$LOG_DIR" "~/.claude_sync_logs/ (log directory)"; then
            log_warn "Failed to remove log directory"
        fi
    else
        log_info "Log directory not found"
    fi
}

remove_backups() {
    echo ""
    echo -e "${BOLD}Step 5: Remove backup directories and files${NC}"
    echo "─────────────────────────────────"

    if [[ "$KEEP_BACKUPS" == "true" ]]; then
        log_info "Keeping backups (--keep-backups specified)"
        return
    fi

    # Find backup directories
    local backup_dirs=()
    while IFS= read -r -d '' dir; do
        backup_dirs+=("$dir")
    done < <(find "$HOME" -maxdepth 1 -type d -name ".claude_backup.*" -print0 2>/dev/null)

    # Find backup files (.claude.json.backup.*)
    local backup_files=()
    while IFS= read -r -d '' file; do
        backup_files+=("$file")
    done < <(find "$HOME" -maxdepth 1 -type f -name ".claude.json.backup.*" -print0 2>/dev/null)

    local dir_count=${#backup_dirs[@]}
    local file_count=${#backup_files[@]}
    local total_count=$((dir_count + file_count))

    if [[ $total_count -eq 0 ]]; then
        log_info "No backup directories or files found"
        return
    fi

    # Report what was found
    [[ $dir_count -gt 0 ]] && log_info "Found $dir_count backup directory(s)"
    [[ $file_count -gt 0 ]] && log_info "Found $file_count backup file(s)"

    if [[ "$DRY_RUN" == "true" ]]; then
        if [[ $dir_count -gt 0 ]]; then
            if [[ $dir_count -gt 10 ]]; then
                log_dry "${backup_dirs[0]} ... and $((dir_count - 1)) more directories"
            else
                for backup in "${backup_dirs[@]}"; do
                    log_dry "$backup"
                done
            fi
        fi
        if [[ $file_count -gt 0 ]]; then
            for file in "${backup_files[@]}"; do
                log_dry "$file"
            done
        fi
    elif [[ "$FORCE" == "true" ]] || confirm "Remove all $total_count backup items?"; then
        local deleted=0
        local last_update=$SECONDS

        # Remove directories with progress
        if [[ $dir_count -gt 0 ]]; then
            for backup in "${backup_dirs[@]}"; do
                rm -rf "$backup"
                ((deleted++))
                if (( SECONDS - last_update >= 2 )); then
                    printf "\r${BLUE}[PROGRESS]${NC} Deleted %d / %d items (%.0f%%)..." \
                        "$deleted" "$total_count" "$((deleted * 100 / total_count))"
                    last_update=$SECONDS
                fi
            done
        fi

        # Remove files
        if [[ $file_count -gt 0 ]]; then
            for file in "${backup_files[@]}"; do
                rm -f "$file"
                ((deleted++))
            done
        fi

        printf "\r\033[K"
        [[ $dir_count -gt 0 ]] && log_success "Removed $dir_count backup directories"
        [[ $file_count -gt 0 ]] && log_success "Removed $file_count backup files"
    else
        log_info "Keeping backups"
    fi
}

remove_dropbox_sync() {
    echo ""
    echo -e "${BOLD}Step 6: Remove Dropbox sync directory${NC}"
    echo "─────────────────────────────────"
    
    if [[ "$KEEP_DROPBOX" == "true" ]]; then
        log_info "Keeping Dropbox directory (--keep-dropbox specified)"
        return
    fi
    
    local dropbox_base
    dropbox_base=$(detect_dropbox)
    
    if [[ -z "$dropbox_base" ]]; then
        log_info "Dropbox not found"
        return
    fi
    
    local sync_dir="$dropbox_base/ClaudeCodeSync"
    
    if [[ ! -d "$sync_dir" ]]; then
        log_info "Dropbox sync directory not found: $sync_dir"
        return
    fi
    
    local file_count
    file_count=$(find "$sync_dir" -type f 2>/dev/null | wc -l | tr -d ' ')
    
    echo -e "${YELLOW}WARNING:${NC} This will permanently delete your synced settings from Dropbox!"
    echo "         Directory: $sync_dir"
    echo "         Files: $file_count"
    echo ""
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "$sync_dir (and all contents)"
    elif [[ "$FORCE" == "true" ]] || confirm "Delete Dropbox sync directory? THIS CANNOT BE UNDONE"; then
        rm -rf "$sync_dir"
        log_success "Removed: $sync_dir"
    else
        log_info "Keeping Dropbox sync directory"
        
        # Still offer to clean conflict files
        local conflict_count
        conflict_count=$(find "$sync_dir" -name "*conflicted*" 2>/dev/null | wc -l | tr -d ' ')
        
        if [[ "$conflict_count" -gt 0 ]]; then
            if confirm "Remove $conflict_count Dropbox conflict files?"; then
                find "$sync_dir" -name "*conflicted*" -type f -delete 2>/dev/null || true
                log_success "Removed $conflict_count conflict files"
            fi
        fi
    fi
}

remove_binary() {
    echo ""
    echo -e "${BOLD}Step 7: Remove built binary${NC}"
    echo "─────────────────────────────────"
    
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local binary_dir="$script_dir/watch/target"
    
    if [[ -d "$binary_dir" ]]; then
        local binary_size
        binary_size=$(du -sh "$binary_dir" 2>/dev/null | cut -f1 || echo "unknown")
        log_info "Build artifacts size: $binary_size"
        
        if ! remove_dir "$binary_dir" "$script_dir/watch/target/ (built binary and cache)"; then
            log_warn "Failed to remove build directory"
        fi
    else
        log_info "No build artifacts found"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Verification
# ─────────────────────────────────────────────────────────────────────────────

verify_uninstall() {
    echo ""
    echo -e "${BOLD}Verification${NC}"
    echo "─────────────────────────────────"
    
    local issues=0
    
    # Check daemon
    if launchctl list 2>/dev/null | grep -q "$PLIST_NAME"; then
        log_error "Daemon still running"
        ((issues++))
    else
        log_success "Daemon not running"
    fi
    
    # Check plist
    if [[ -f "$PLIST_PATH" ]]; then
        log_error "Plist still exists: $PLIST_PATH"
        ((issues++))
    else
        log_success "Plist removed"
    fi
    
    # Check config
    if [[ -f "$CONFIG_FILE" ]]; then
        log_warn "Config file still exists: $CONFIG_FILE"
    else
        log_success "Config removed"
    fi
    
    # Check logs
    if [[ -d "$LOG_DIR" ]]; then
        log_warn "Log directory still exists: $LOG_DIR"
    else
        log_success "Logs removed"
    fi
    
    # Check backups
    local backup_count
    backup_count=$(find "$HOME" -maxdepth 1 -type d -name ".claude_backup.*" 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    if [[ "$backup_count" -gt 0 ]]; then
        log_warn "$backup_count backup(s) still exist"
    else
        log_success "Backups removed"
    fi
    
    # Check processes
    if pgrep -f "claude-sync-watch" >/dev/null 2>&1; then
        log_error "claude-sync-watch process still running"
        ((issues++))
    else
        log_success "No orphan processes"
    fi
    
    echo ""
    if [[ $issues -eq 0 ]]; then
        log_success "Uninstall complete!"
    else
        log_error "Uninstall completed with $issues issue(s)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Complete uninstall script for claude-mac-sync.

Options:
  --force           Remove everything without prompts
  --dry-run         Show what would be removed without removing
  --keep-backups    Keep ~/.claude_backup.* directories
  --keep-dropbox    Keep ~/Dropbox/ClaudeCodeSync directory
  --help, -h        Show this help message

What gets removed:
  1. LaunchAgent daemon (com.claude.sync-watch)
  2. Launchd plist (~/.Library/LaunchAgents/com.claude.sync-watch.plist)
  3. Configuration file (~/.claude_sync_config)
  4. Sync state files (~/.claude/.sync_state.json, ~/.claude/.sync.pid)
  5. Last backup marker (~/.claude_sync_last_backup)
  6. Log directory (~/.claude_sync_logs/)
  7. Backup directories (~/.claude_backup.*)
  8. Dropbox sync directory (~/Dropbox/ClaudeCodeSync/) [optional]
  9. Built binary and cache (watch/target/)

Examples:
  $0                    # Interactive uninstall
  $0 --dry-run          # Preview what would be removed
  $0 --force            # Remove everything without prompts
  $0 --keep-backups     # Keep backups, remove everything else

Note: This does NOT remove the claude-mac-sync source directory itself.
      Delete it manually if desired: rm -rf $(dirname "$0")
EOF
}

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force)
                FORCE=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --keep-backups)
                KEEP_BACKUPS=true
                shift
                ;;
            --keep-dropbox)
                KEEP_DROPBOX=true
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Claude Mac Sync - Complete Uninstall"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "  ${CYAN}DRY RUN MODE - No files will be removed${NC}"
    fi
    
    if [[ "$FORCE" == "true" ]]; then
        echo -e "  ${YELLOW}FORCE MODE - No prompts${NC}"
    fi
    
    echo ""
    
    if [[ "$DRY_RUN" != "true" && "$FORCE" != "true" ]]; then
        echo "This will remove all claude-mac-sync components from your system."
        echo ""
        if ! confirm "Proceed with uninstall?"; then
            log_info "Uninstall cancelled"
            exit 0
        fi
    fi
    
    # Run uninstall steps
    stop_daemon
    remove_launchd_plist
    remove_config_files
    remove_log_directory
    remove_backups
    remove_dropbox_sync
    remove_binary
    
    # Verify
    if [[ "$DRY_RUN" != "true" ]]; then
        verify_uninstall
    else
        echo ""
        log_info "Dry run complete. Run without --dry-run to perform uninstall."
    fi
    
    echo ""
}

main "$@"
