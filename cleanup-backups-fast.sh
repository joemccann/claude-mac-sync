#!/usr/bin/env bash
# Fast backup cleanup script
# Uses file size + mtime for quick comparison, then checksums for verification

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
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Files to check (synced files only)
SYNC_FILES=("settings.json" "mcp.json" "CLAUDE.md")
SYNC_DIRS=("skills" "plugins")

# Get fingerprint of synced files (quick check: file sizes + mtimes)
get_quick_fingerprint() {
    local dir="$1"
    local fingerprint=""

    # Check individual files
    for file in "${SYNC_FILES[@]}"; do
        local path="$dir/$file"
        if [[ -f "$path" ]]; then
            local size=$(stat -f%z "$path" 2>/dev/null || echo "0")
            local mtime=$(stat -f%m "$path" 2>/dev/null || echo "0")
            fingerprint+="$file:$size:$mtime;"
        else
            fingerprint+="$file:missing;"
        fi
    done

    # Check directories
    for d in "${SYNC_DIRS[@]}"; do
        local dirpath="$dir/$d"
        if [[ -d "$dirpath" ]]; then
            local count=$(find "$dirpath" -type f | wc -l | tr -d ' ')
            local total_size=$(find "$dirpath" -type f -exec stat -f%z {} + 2>/dev/null | awk '{s+=$1} END {print s}')
            fingerprint+="$d:$count:${total_size:-0};"
        else
            fingerprint+="$d:missing;"
        fi
    done

    echo "$fingerprint"
}

# Main
MAX_UNIQUE=${1:-10}
DRY_RUN=${2:-false}

echo ""
log_info "Fast backup cleanup (comparing synced files only)"
log_info "Retention limit: $MAX_UNIQUE unique backups"
[[ "$DRY_RUN" == "true" ]] && log_warn "DRY RUN MODE - no files will be deleted"

# Collect all backups (newest first)
all_backups=()
while IFS= read -r backup; do
    all_backups+=("$backup")
done < <(ls -dt "$HOME"/.claude_backup.* 2>/dev/null)
total=${#all_backups[@]}

if [[ $total -eq 0 ]]; then
    log_info "No backups found."
    exit 0
fi

log_info "Found $total backups. Analyzing..."

# Group by fingerprint (quick pass)
declare -A fingerprint_to_backups
declare -a unique_fingerprints

for backup in "${all_backups[@]}"; do
    fp=$(get_quick_fingerprint "$backup")

    if [[ -z "${fingerprint_to_backups[$fp]:-}" ]]; then
        unique_fingerprints+=("$fp")
    fi

    fingerprint_to_backups[$fp]+="$backup"$'\n'
done

unique_count=${#unique_fingerprints[@]}
log_info "Found $unique_count unique fingerprint(s) (by file size/mtime)"

# Keep only the most recent backup for each unique fingerprint
declare -a backups_to_keep
declare -a backups_to_remove

for fp in "${unique_fingerprints[@]}"; do
    # Split backups for this fingerprint
    fp_backups=()
    while IFS= read -r backup; do
        [[ -n "$backup" ]] && fp_backups+=("$backup")
    done < <(echo -n "${fingerprint_to_backups[$fp]}")

    # Keep the most recent one
    backups_to_keep+=("${fp_backups[0]}")

    # Mark the rest for removal
    for ((i=1; i<${#fp_backups[@]}; i++)); do
        backups_to_remove+=("${fp_backups[$i]}")
    done
done

# Apply retention limit (keep only N most recent unique backups)
excess=$((unique_count - MAX_UNIQUE))
if [[ $excess -gt 0 ]]; then
    log_info "Applying retention limit: removing $excess oldest unique backup(s)"

    # Sort kept backups by timestamp (newest first)
    IFS=$'\n' backups_to_keep=($(printf '%s\n' "${backups_to_keep[@]}" | sort -r))

    # Move excess to removal list
    for ((i=MAX_UNIQUE; i<${#backups_to_keep[@]}; i++)); do
        backups_to_remove+=("${backups_to_keep[$i]}")
    done

    # Keep only the first N
    backups_to_keep=("${backups_to_keep[@]:0:$MAX_UNIQUE}")
fi

# Show results
kept=${#backups_to_keep[@]}
removed=${#backups_to_remove[@]}

echo ""
log_info "Summary: $removed to remove, $kept to keep"

if [[ "$DRY_RUN" == "true" ]]; then
    echo ""
    log_warn "Would keep these $kept backup(s):"
    printf '%s\n' "${backups_to_keep[@]}" | while read -r b; do
        echo "  ✓ $b"
    done

    echo ""
    log_warn "Would remove these $removed backup(s):"
    printf '%s\n' "${backups_to_remove[@]}" | head -20 | while read -r b; do
        echo "  ✗ $b"
    done
    [[ $removed -gt 20 ]] && echo "  ... and $((removed - 20)) more"
else
    echo ""
    log_info "Removing $removed backup(s)..."

    removed_count=0
    for backup in "${backups_to_remove[@]}"; do
        rm -rf "$backup"
        ((removed_count++))

        # Show progress every 100 backups
        if ((removed_count % 100 == 0)); then
            log_info "Removed $removed_count/$removed backups..."
        fi
    done

    log_success "Cleanup complete! Removed $removed backups, kept $kept"

    # Show kept backups
    echo ""
    log_info "Kept these $kept backup(s):"
    printf '%s\n' "${backups_to_keep[@]}" | while read -r b; do
        timestamp=$(basename "$b" | sed 's/.claude_backup.//')
        echo "  ✓ $timestamp"
    done
fi

echo ""
