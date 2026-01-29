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

create_backup() {
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_path="$BACKUP_DIR.$timestamp"

    log_info "Creating backup of ~/.claude..."

    if [[ ! -d "$CLAUDE_DIR" ]]; then
        log_warn "~/.claude does not exist. Nothing to backup."
        return 0
    fi

    cp -a "$CLAUDE_DIR" "$backup_path"
    log_success "Backup created: $backup_path"

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
            cp -p "$src" "$dst"
            log_success "Copied $file"
            ((copied++))
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
            rm -rf "$dst"
            cp -rp "$src" "$dst"
            log_success "Copied $dir/"
            ((copied++))
        else
            log_warn "$dir/ does not exist locally, skipping"
            ((skipped++))
        fi
    done

    echo ""
    log_success "Push complete. Copied: $copied, Skipped: $skipped"
    log_info "Files are now in: $DROPBOX_CLAUDE_DIR"
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

    # Create backup first
    create_backup

    # Ensure local directory exists
    mkdir -p "$CLAUDE_DIR"

    local copied=0
    local skipped=0

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
            cp -p "$src" "$dst"
            log_success "Copied $file"
            ((copied++))
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
            rm -rf "$dst"
            cp -rp "$src" "$dst"
            log_success "Copied $dir/"
            ((copied++))
        else
            log_warn "$dir/ does not exist in Dropbox, skipping"
            ((skipped++))
        fi
    done

    echo ""
    log_success "Pull complete. Copied: $copied, Skipped: $skipped"
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
Usage: $0 [--push | --pull | --status | --config | --backup]

Options:
  --push      Copy ~/.claude files TO Dropbox (overwrites Dropbox)
  --pull      Copy Dropbox files TO ~/.claude (overwrites local)
  --status    Show sync status and file differences
  --config    Reconfigure Dropbox folder location
  --backup    Create timestamped backup of ~/.claude

Workflow:
  1. On primary machine:   ./claude-sync-setup.sh --push
  2. Wait for Dropbox to sync
  3. On secondary machine: ./claude-sync-setup.sh --pull
  4. Check status anytime: ./claude-sync-setup.sh --status

After initial setup, use --push/--pull to sync changes between machines.
EOF
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
