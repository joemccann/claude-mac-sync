# Claude Code Configuration Sync via Dropbox

Synchronize `~/.claude` configuration files between multiple Macs using Dropbox with direct file copies.

## Overview

This solution provides two sync modes:
1. **Manual sync**: Push/pull commands for on-demand synchronization
2. **Auto sync**: File watching daemon for automatic bidirectional sync

**Synchronized Items:**
- `settings.json` - Claude Code settings
- `mcp.json` - MCP server configurations
- `CLAUDE.md` - Personal instructions
- `skills/` - Custom skills directory
- `plugins/` - Plugins directory

**Architecture (with auto-sync daemon):**
```
Machine A                          Dropbox                         Machine B
~/.claude/  <->  claude-sync-watch  <->  ClaudeCodeSync/  <->  claude-sync-watch  <->  ~/.claude/
                    (daemon)              .sync_state.json         (daemon)
                                          .sync_lock
```

**Manual sync architecture:**
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

### Automatic Sync (Recommended)

Install the file watcher daemon for automatic bidirectional sync:

```bash
# Build and install the daemon (requires Rust)
./claude-sync-setup.sh --watch-install

# Check status
./claude-sync-setup.sh --watch-status

# Follow logs
./claude-sync-setup.sh --watch-logs
```

The daemon will:
- Watch both `~/.claude` and the Dropbox sync folder
- Automatically sync changes in both directions
- Create backups before every sync
- Validate files before copying (prevents syncing empty/corrupted files)

### Manual Sync

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

### Manual Sync Commands

| Command | Description |
|---------|-------------|
| `--push` | Copy `~/.claude` files TO Dropbox (overwrites Dropbox) |
| `--pull` | Copy Dropbox files TO `~/.claude` (overwrites local) |
| `--status` | Show sync status and file differences |
| `--config` | Configure/reconfigure Dropbox folder location |
| `--backup` | Create timestamped backup of `~/.claude` |
| `--undo` | Restore previous state after a pull |
| `--backups` | List all available backups |
| `--restore <path>` | Restore from a specific backup |

### Watch Daemon Commands

| Command | Description |
|---------|-------------|
| `--watch-install` | Build and install the watch daemon (requires Rust) |
| `--watch-start` | Start the watch daemon |
| `--watch-stop` | Stop the watch daemon |
| `--watch-restart` | Restart the watch daemon |
| `--watch-status` | Show daemon status and sync info |
| `--watch-logs` | Follow daemon logs in real-time |
| `--watch-build` | Build the Rust binary only |

You can also use `claude-sync-daemon.sh` directly:
```bash
./claude-sync-daemon.sh once      # One-time sync (no watching)
./claude-sync-daemon.sh validate  # Validate configuration
```

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

**Manual Sync Commands:**

| Command | Description |
|---------|-------------|
| `claude-sync-status` | Quick status check |
| `claude-sync-push` | Quick push to Dropbox |
| `claude-sync-pull` | Quick pull from Dropbox |
| `claude-sync-undo` | Restore previous state after a pull |
| `claude-sync-backups` | List all available backups |
| `claude-sync-restore <path>` | Restore from a specific backup |
| `claude-sync-conflicts` | List Dropbox conflicts |

**Watch Daemon Commands:**

| Command | Description |
|---------|-------------|
| `claude-sync-watch <cmd>` | Control the watch daemon |
| `claude-watch-start` | Start the watch daemon |
| `claude-watch-stop` | Stop the watch daemon |
| `claude-watch-restart` | Restart the watch daemon |
| `claude-watch-status` | Show daemon status |
| `claude-watch-logs` | Follow daemon logs |
| `claude-watch-install` | Install the daemon |

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
# Undo the most recent pull
./claude-sync-setup.sh --undo

# Or use shell function
claude-sync-undo

# List all backups
./claude-sync-setup.sh --backups

# Restore from a specific backup
./claude-sync-setup.sh --restore ~/.claude_backup.20250128_143022
```

---

## File Integrity

The sync scripts validate all files before and after copying to prevent corruption:

- **Empty file detection**: Rejects empty files (often caused by Dropbox sync in progress)
- **JSON validation**: Validates JSON syntax for `settings.json` and `mcp.json`
- **Checksum verification**: Verifies SHA-256 checksums after every copy operation
- **Directory validation**: Ensures all files in directories are copied correctly

If validation fails, the operation is aborted and your original files remain unchanged.

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
| `claude-sync-daemon.sh` | Daemon control script |
| `zshrc-functions.sh` | Shell functions for quick access |
| `watch/` | Rust source for file watcher daemon |
| `~/.claude_sync_config` | Saved Dropbox location (per-machine) |
| `~/.claude_backup.*` | Timestamped backups |
| `~/.claude_sync_last_backup` | Marker for undo functionality |
| `~/.claude_sync_logs/` | Daemon log files |
| `test_sync.sh` | Test suite for integrity validation |

---

## Watch Daemon

The watch daemon is a Rust application that provides automatic bidirectional sync.

### Prerequisites

- [Rust](https://rustup.rs) toolchain for building

### Installation

```bash
# Build and install (one command)
./claude-sync-daemon.sh install

# Or step by step:
./claude-sync-daemon.sh build
./claude-sync-daemon.sh install
```

This will:
1. Build the Rust binary
2. Create a launchd agent plist
3. Start the daemon

The daemon starts automatically on login.

### Configuration

The daemon reads configuration from `~/.claude_sync_config`:

```bash
DROPBOX_BASE="/path/to/Dropbox"
DEBOUNCE_SECS="3.0"       # Wait time before syncing (default: 3s)
MAX_BATCH_SECS="10.0"     # Max time to batch changes (default: 10s)
CONFLICT_STRATEGY="newest" # newest, local, or remote
LOG_LEVEL="info"          # debug, info, warn, error
```

### Features

- **Debouncing**: Waits 3 seconds after the last change before syncing
- **Batch mode**: Batches rapid changes (max 10 seconds)
- **Distributed lock**: Prevents concurrent syncs across machines
- **Backup first**: Creates a backup before every sync operation
- **File validation**: Rejects empty files and invalid JSON
- **Checksum verification**: Verifies SHA-256 after every copy

### Log Files

```bash
# View daemon logs
./claude-sync-daemon.sh logs

# Follow logs in real-time
./claude-sync-daemon.sh follow

# Log location
~/.claude_sync_logs/sync-watch.log
~/.claude_sync_logs/sync-watch.err
```

### Uninstall

```bash
./claude-sync-daemon.sh uninstall
```

### Troubleshooting the Daemon

**Daemon won't start**
```bash
# Check if already running
./claude-sync-daemon.sh status

# Check for errors
cat ~/.claude_sync_logs/sync-watch.err

# Verify configuration
./watch/target/release/claude-sync-watch --validate
```

**"Sync locked by another machine"**

The lock auto-expires after 60 seconds. If a machine crashed while holding the lock:
```bash
# Wait 60 seconds, or manually remove the lock
rm ~/Dropbox/ClaudeCodeSync/.sync_lock
```

**Validation errors (empty files)**

This usually means Dropbox is still syncing:
```bash
# Check Dropbox status in menu bar
# Wait for sync to complete, then try again
./claude-sync-daemon.sh restart
```

**Daemon keeps restarting**

Check for configuration issues:
```bash
# View error log
cat ~/.claude_sync_logs/sync-watch.err

# Common issues:
# - Dropbox folder doesn't exist
# - ~/.claude_sync_config has wrong path
# - Permission issues
```

**Changes not syncing**

1. Check daemon is running: `./claude-sync-daemon.sh status`
2. Check logs for errors: `./claude-sync-daemon.sh logs`
3. Verify Dropbox is syncing (check menu bar icon)
4. Try manual sync: `./claude-sync-daemon.sh once`
