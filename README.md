# Claude Code Configuration Sync via Dropbox

Synchronize `~/.claude` configuration files between multiple Macs using Dropbox with direct file copies.

## Overview

This solution copies Claude Code configuration files to a shared Dropbox location, enabling synchronization between machines using `--push` and `--pull` commands.

**Synchronized Items:**
- `settings.json` - Claude Code settings
- `mcp.json` - MCP server configurations
- `CLAUDE.md` - Personal instructions
- `skills/` - Custom skills directory
- `plugins/` - Plugins directory

**Architecture:**
```
Machine A                          Machine B
~/.claude/                         ~/.claude/
  settings.json                      settings.json
  mcp.json                           mcp.json
  CLAUDE.md                          CLAUDE.md
  skills/                            skills/
  plugins/                           plugins/
         \                               /
          \  --push               --pull /
           \                           /
            v                         v
        ~/Dropbox/ClaudeCodeSync/
          settings.json
          mcp.json
          CLAUDE.md
          skills/
          plugins/
```

---

## Quick Start

```bash
# Make executable
chmod +x claude-sync-setup.sh

# On primary machine (push config to Dropbox):
./claude-sync-setup.sh --push

# Wait for Dropbox to sync, then on secondary machine:
./claude-sync-setup.sh --pull

# Check sync status anytime:
./claude-sync-setup.sh --status
```

---

## Commands

| Command | Description |
|---------|-------------|
| `--push` | Copy `~/.claude` files TO Dropbox (overwrites Dropbox) |
| `--pull` | Copy Dropbox files TO `~/.claude` (overwrites local) |
| `--status` | Show sync status and file differences |
| `--config` | Configure/reconfigure Dropbox folder location |
| `--backup` | Create timestamped backup of `~/.claude` |

---

## Setup Guide

### 1. First Run (Configure Dropbox Location)

On first run, the script prompts for your Dropbox folder location:

```
[INFO] Dropbox folder location required.

  Detected: /Users/you/Dropbox

Enter your Dropbox folder path [/Users/you/Dropbox]:
[OK] Saved Dropbox location to /Users/you/.claude_sync_config
```

The script auto-detects common locations:
- `~/Dropbox`
- `~/Library/CloudStorage/Dropbox`

### 2. Push from Primary Machine

```bash
./claude-sync-setup.sh --push
```

This:
1. Creates a timestamped backup of `~/.claude`
2. Copies all config files to `~/Dropbox/ClaudeCodeSync/`

### 3. Pull on Secondary Machine

After Dropbox syncs (check menu bar icon), run on the other machine:

```bash
./claude-sync-setup.sh --pull
```

This:
1. Creates a backup of local `~/.claude`
2. Copies all files from Dropbox to `~/.claude`

### 4. Ongoing Sync

After initial setup, use `--push` and `--pull` to sync changes:

```bash
# Made changes on Machine A? Push them:
./claude-sync-setup.sh --push

# Want those changes on Machine B? Pull them:
./claude-sync-setup.sh --pull
```

---

## Shell Functions for .zshrc

Add quick-access functions to your shell:

```bash
# Add to ~/.zshrc
source /path/to/claude-mac-sync/zshrc-functions.sh
```

**Available Commands:**

| Command | Description |
|---------|-------------|
| `claude-sync-status` | Quick status check |
| `claude-sync-push` | Quick push to Dropbox |
| `claude-sync-pull` | Quick pull from Dropbox |
| `claude-sync-conflicts` | List Dropbox conflicts |

---

## Conflict Management

### When Conflicts Occur

If both machines push changes before syncing, Dropbox creates conflicted copies:

```
settings.json
settings (Joe's MacBook Pro's conflicted copy 2025-01-28).json
```

### Check for Conflicts

```bash
./claude-sync-setup.sh --status
# or
claude-sync-conflicts
```

### Resolve Conflicts

```bash
# Compare files
diff ~/Dropbox/ClaudeCodeSync/settings.json \
     ~/Dropbox/ClaudeCodeSync/"settings (*conflicted*).json"

# Keep one version
mv ~/Dropbox/ClaudeCodeSync/"settings (*conflicted*).json" \
   ~/Dropbox/ClaudeCodeSync/settings.json

# Or delete the conflict
rm ~/Dropbox/ClaudeCodeSync/"settings (*conflicted*).json"
```

---

## Backups

Every `--push` and `--pull` operation automatically creates a timestamped backup:

```
~/.claude_backup.20250128_143022/
```

Manual backup:
```bash
./claude-sync-setup.sh --backup
```

Restore from backup:
```bash
cp -a ~/.claude_backup.TIMESTAMP/* ~/.claude/
```

---

## Troubleshooting

### "Dropbox source does not exist"

Run `--push` on your primary machine first to initialize the Dropbox folder.

### Local files are symlinks

If you previously used symlink-based sync, the script detects this:
```
[SYMLINK] settings.json is a symlink (run --pull to fix)
```

Run `--pull` to replace symlinks with real files.

### Reconfigure Dropbox Location

```bash
./claude-sync-setup.sh --config
```

---

## Files

| File | Purpose |
|------|---------|
| `claude-sync-setup.sh` | Main sync script |
| `zshrc-functions.sh` | Shell functions for quick access |
| `~/.claude_sync_config` | Saved Dropbox location (per-machine) |
| `~/.claude_backup.*` | Timestamped backups |
