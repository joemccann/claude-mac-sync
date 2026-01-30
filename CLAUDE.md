# Claude Code Configuration Sync

This project provides tools to synchronize Claude Code configuration (`~/.claude`) between multiple machines via Dropbox.

## Project Structure

```
claude-mac-sync/
├── claude-sync-setup.sh    # Main CLI script (bash) - manual push/pull
├── claude-sync-daemon.sh   # Daemon control script (bash) - start/stop/install
├── zshrc-functions.sh      # Shell functions for ~/.zshrc
├── test_sync.sh            # Test suite for file integrity validation
├── watch/                  # Rust file watcher daemon
│   ├── Cargo.toml
│   └── src/
│       ├── main.rs         # CLI entry point (clap)
│       ├── config.rs       # Configuration loading
│       ├── watcher.rs      # File system watching (notify crate)
│       ├── sync.rs         # Sync engine (backup-first workflow)
│       ├── state.rs        # State tracking (checksums, mtimes)
│       └── lock.rs         # Distributed lock via Dropbox
└── README.md
```

## Key Concepts

### Two Sync Modes

1. **Manual sync** (`claude-sync-setup.sh`): Explicit `--push` and `--pull` commands
2. **Auto sync** (`watch/`): Rust daemon that watches file changes and syncs automatically

### Safety Features

All sync operations follow these safety principles:

1. **Backup first**: Always create a timestamped backup before any sync
2. **Validate before copy**: Reject empty files (Dropbox sync incomplete) and invalid JSON
3. **Checksum verification**: SHA-256 verify every file after copying
4. **Distributed lock**: Prevent concurrent syncs across machines (60s timeout)

### Files Synced

- `settings.json` - Claude Code settings
- `mcp.json` - MCP server configurations
- `CLAUDE.md` - Personal instructions
- `skills/` - Custom skills directory
- `plugins/` - Plugins directory

### Dropbox Integration

- Sync folder: `~/Dropbox/ClaudeCodeSync/`
- State file: `.sync_state.json` (tracks file checksums/mtimes)
- Lock file: `.sync_lock` (prevents concurrent syncs)
- Config: `~/.claude_sync_config` (stores DROPBOX_BASE path)

## Development

### Building the Rust Daemon

```bash
cd watch
cargo build --release
```

The binary is placed at `watch/target/release/claude-sync-watch`.

### Running Tests

```bash
# Bash test suite
./test_sync.sh

# Rust tests (when implemented)
cd watch && cargo test
```

### Daemon Commands

```bash
./claude-sync-daemon.sh build     # Build Rust binary
./claude-sync-daemon.sh install   # Build + create launchd plist + start
./claude-sync-daemon.sh start     # Start daemon
./claude-sync-daemon.sh stop      # Stop daemon
./claude-sync-daemon.sh status    # Show status
./claude-sync-daemon.sh logs      # View recent logs
./claude-sync-daemon.sh follow    # Tail logs
```

### Binary Commands

```bash
claude-sync-watch              # Run watcher in foreground
claude-sync-watch --daemon     # Run as daemon (for launchd)
claude-sync-watch --once       # Single sync pass, no watching
claude-sync-watch --status     # Show sync status
claude-sync-watch --validate   # Validate configuration
```

## Architecture Notes

### Watcher Debouncing

The file watcher uses a debouncing strategy:
- **Quiet period**: 3 seconds after last change before syncing
- **Max batch**: 10 seconds maximum to batch rapid changes
- This prevents thrashing during rapid edits or large copy operations

### Sync State

The `.sync_state.json` tracks:
- File SHA-256 checksums
- Modification times (mtime)
- File sizes
- Last sync timestamp
- Machine ID that performed last sync

### Lock Mechanism

The `.sync_lock` file contains:
- Machine ID holding the lock
- Timestamp when acquired
- PID of the process

Locks auto-expire after 60 seconds (handles crashed processes).

### Change Detection

Changes are detected by comparing:
1. File existence (local vs remote)
2. SHA-256 checksums
3. Modification times (newer wins for conflicts)

## Common Tasks

### Adding a New Synced File

1. Add to `SYNC_FILES` array in `claude-sync-setup.sh`
2. Add to `CLAUDE_SYNC_FILES` array in `zshrc-functions.sh`
3. Add to `sync_files` vector in `watch/src/config.rs`

### Adding a New Synced Directory

1. Add to `SYNC_DIRS` array in `claude-sync-setup.sh`
2. Add to `CLAUDE_SYNC_DIRS` array in `zshrc-functions.sh`
3. Add to `sync_dirs` vector in `watch/src/config.rs`

### Modifying Debounce Timing

Edit `~/.claude_sync_config`:
```bash
DEBOUNCE_SECS="5.0"      # Quiet period
MAX_BATCH_SECS="15.0"    # Max batch time
```

Or modify defaults in `watch/src/config.rs`.
