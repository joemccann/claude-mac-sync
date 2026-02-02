# Uninstall Instructions

## Complete Cleanup (Start Fresh)

Run these commands on the machine you want to clean up:

```bash
# 1. Stop and unload the daemon
launchctl unload ~/Library/LaunchAgents/com.claude.sync-watch.plist 2>/dev/null || true

# 2. Remove daemon configuration
rm -f ~/Library/LaunchAgents/com.claude.sync-watch.plist

# 3. Remove all backup folders (optional - keeps last 5 by default)
# To remove ALL backups:
rm -rf ~/.claude_backup.*

# To keep just the 5 most recent:
ls -dt ~/.claude_backup.* 2>/dev/null | tail -n +6 | xargs rm -rf

# 4. Remove sync state and lock files
rm -f ~/.claude/.sync_state.json
rm -f ~/.claude/.sync.pid
rm -f ~/.claude_sync_last_backup

# 5. Remove config file
rm -f ~/.claude_sync_config

# 6. Remove log directory (optional)
rm -rf ~/.claude_sync_logs

# 7. Clean up Dropbox conflict files (if any remain)
find ~/Dropbox*/ClaudeCodeSync -name "*conflicted copy*" -type f -delete 2>/dev/null || true

# 8. (Optional) Remove synced Dropbox directory
# WARNING: This will delete your synced settings from Dropbox!
# rm -rf ~/Dropbox*/ClaudeCodeSync
```

## Verify Cleanup

```bash
# Check daemon is stopped
launchctl list | grep claude.sync-watch
# Should return nothing

# Check no backups exist (or only the ones you kept)
ls -d ~/.claude_backup.* 2>/dev/null | wc -l

# Check Dropbox directory
ls -la ~/Dropbox*/ClaudeCodeSync 2>/dev/null
```

## Fresh Install on Other Machine

After cleanup, install fresh with the new fixed version:

```bash
# 1. Clone/pull the latest version
cd ~/dev/apps/util/claude-mac-sync
git pull origin main

# 2. Configure Dropbox path
./claude-sync-setup.sh --config

# 3. Build and install daemon
./claude-sync-daemon.sh install

# 4. Verify it's running
./claude-sync-daemon.sh status

# 5. Watch logs to confirm it's working
./claude-sync-daemon.sh follow
```

## Quick Uninstall (Keep Settings)

If you just want to reinstall the daemon without removing settings:

```bash
# Stop daemon
./claude-sync-daemon.sh stop

# Rebuild and restart
./claude-sync-daemon.sh install

# Or just:
cd watch && cargo build --release
./claude-sync-daemon.sh start
```

## Troubleshooting

If the daemon won't stop:

```bash
# Find and kill the process
ps aux | grep claude-sync-watch
kill -9 <PID>

# Remove the plist and try again
rm ~/Library/LaunchAgents/com.claude.sync-watch.plist
```

If you want to preserve ONE backup before cleanup:

```bash
# Copy your most recent backup to a safe location
cp -a ~/.claude_backup.$(ls -t ~/.claude_backup.* | head -1 | sed 's/.*\.//') ~/claude-backup-safe

# Then do cleanup

# Later, restore if needed:
cp -a ~/claude-backup-safe ~/.claude
```
