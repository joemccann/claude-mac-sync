#!/usr/bin/env bash
# Simple backup cleanup - keeps most recent N backups, removes the rest
# Also cleans up Dropbox conflict files

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

# Main
MAX_KEEP=${1:-10}
DRY_RUN=${2:-false}

echo ""
log_info "Simple backup cleanup"
log_info "Will keep: $MAX_KEEP most recent backups"
[[ "$DRY_RUN" == "true" ]] && log_warn "DRY RUN MODE - no files will be deleted"

# Count all backups
total=$(ls -d "$HOME"/.claude_backup.* 2>/dev/null | wc -l | tr -d ' ')

if [[ $total -eq 0 ]]; then
    log_info "No backups found."
    exit 0
fi

log_info "Found $total backups"

if [[ $total -le $MAX_KEEP ]]; then
    log_success "Only $total backups exist (≤ $MAX_KEEP). Nothing to remove."
    # Don't exit - continue to Dropbox conflict cleanup
else
    to_remove=$((total - MAX_KEEP))
    log_info "Will remove: $to_remove oldest backups"

    echo ""
    if [[ "$DRY_RUN" == "true" ]]; then
    log_warn "Would keep these $MAX_KEEP most recent backup(s):"
    ls -dt "$HOME"/.claude_backup.* 2>/dev/null | head -$MAX_KEEP | while read -r b; do
        timestamp=$(basename "$b" | sed 's/.claude_backup.//')
        echo "  ✓ $timestamp"
    done

    echo ""
    log_warn "Would remove these $to_remove oldest backup(s):"
    ls -dt "$HOME"/.claude_backup.* 2>/dev/null | tail -n +$((MAX_KEEP + 1)) | head -20 | while read -r b; do
        timestamp=$(basename "$b" | sed 's/.claude_backup.//')
        echo "  ✗ $timestamp"
    done
    [[ $to_remove -gt 20 ]] && echo "  ... and $((to_remove - 20)) more"
else
    log_info "Removing $to_remove oldest backups..."

    removed=0
    ls -dt "$HOME"/.claude_backup.* 2>/dev/null | tail -n +$((MAX_KEEP + 1)) | while read -r backup; do
        rm -rf "$backup"
        ((removed++)) || true

        # Show progress every 500 backups
        if ((removed % 500 == 0)); then
            log_info "Removed $removed/$to_remove backups..."
        fi
    done

    # Final count
    remaining=$(ls -d "$HOME"/.claude_backup.* 2>/dev/null | wc -l | tr -d ' ')

    echo ""
    log_success "Cleanup complete!"
    log_success "Removed: $to_remove backups"
    log_success "Kept: $remaining backups"

    echo ""
    log_info "Most recent backups:"
    ls -dt "$HOME"/.claude_backup.* 2>/dev/null | head -5 | while read -r b; do
        timestamp=$(basename "$b" | sed 's/.claude_backup.//')
        echo "  ✓ $timestamp"
    done
    [[ $remaining -gt 5 ]] && echo "  ... and $((remaining - 5)) more"
    fi
fi

# Cleanup Dropbox conflict files
echo ""
log_info "Checking for Dropbox conflict files..."

conflict_count=$(find ~/Dropbox*/ClaudeCodeSync -name "*conflicted copy*" -type f 2>/dev/null | wc -l | tr -d ' ')

if [[ $conflict_count -eq 0 ]]; then
    log_success "No Dropbox conflict files found."
else
    log_info "Found $conflict_count Dropbox conflict file(s)"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "Would remove $conflict_count conflict file(s)"
        find ~/Dropbox*/ClaudeCodeSync -name "*conflicted copy*" -type f 2>/dev/null | head -10 | while read -r f; do
            echo "  ✗ $(basename "$f")"
        done
        [[ $conflict_count -gt 10 ]] && echo "  ... and $((conflict_count - 10)) more"
    else
        log_info "Removing $conflict_count conflict file(s)..."
        find ~/Dropbox*/ClaudeCodeSync -name "*conflicted copy*" -type f -delete 2>/dev/null
        log_success "Removed $conflict_count Dropbox conflict files"
    fi
fi

echo ""
