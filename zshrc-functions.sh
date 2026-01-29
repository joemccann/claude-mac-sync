# ─────────────────────────────────────────────────────────────────────────────
# Claude Code Dropbox Sync - Shell Functions
# Add this to your ~/.zshrc
# ─────────────────────────────────────────────────────────────────────────────

# Configuration
CLAUDE_SYNC_CONFIG_FILE="$HOME/.claude_sync_config"
CLAUDE_SYNC_LOCAL_DIR="$HOME/.claude"
CLAUDE_SYNC_FILES=("settings.json" "mcp.json" "CLAUDE.md")
CLAUDE_SYNC_DIRS=("skills" "plugins")

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

    for file in "${CLAUDE_SYNC_FILES[@]}"; do
        local src="$CLAUDE_SYNC_LOCAL_DIR/$file"
        if [[ -f "$src" && ! -L "$src" ]]; then
            cp -p "$src" "$CLAUDE_SYNC_DROPBOX_DIR/$file"
            echo "\033[0;32m[PUSHED]\033[0m $file"
        fi
    done

    for dir in "${CLAUDE_SYNC_DIRS[@]}"; do
        local src="$CLAUDE_SYNC_LOCAL_DIR/$dir"
        if [[ -d "$src" && ! -L "$src" ]]; then
            rm -rf "$CLAUDE_SYNC_DROPBOX_DIR/$dir"
            cp -rp "$src" "$CLAUDE_SYNC_DROPBOX_DIR/$dir"
            echo "\033[0;32m[PUSHED]\033[0m $dir/"
        fi
    done
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

    mkdir -p "$CLAUDE_SYNC_LOCAL_DIR"

    for file in "${CLAUDE_SYNC_FILES[@]}"; do
        local src="$CLAUDE_SYNC_DROPBOX_DIR/$file"
        local dst="$CLAUDE_SYNC_LOCAL_DIR/$file"
        if [[ -f "$src" ]]; then
            [[ -L "$dst" ]] && rm -f "$dst"
            cp -p "$src" "$dst"
            echo "\033[0;32m[PULLED]\033[0m $file"
        fi
    done

    for dir in "${CLAUDE_SYNC_DIRS[@]}"; do
        local src="$CLAUDE_SYNC_DROPBOX_DIR/$dir"
        local dst="$CLAUDE_SYNC_LOCAL_DIR/$dir"
        if [[ -d "$src" ]]; then
            [[ -L "$dst" ]] && rm -f "$dst"
            rm -rf "$dst"
            cp -rp "$src" "$dst"
            echo "\033[0;32m[PULLED]\033[0m $dir/"
        fi
    done
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
