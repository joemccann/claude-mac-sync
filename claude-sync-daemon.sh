#!/usr/bin/env bash
#
# claude-sync-daemon.sh
# Daemon control for claude-sync-watch (start/stop/status/install)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST_NAME="com.claude.sync-watch"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_NAME.plist"
BINARY="$SCRIPT_DIR/watch/target/release/claude-sync-watch"
LOG_DIR="$HOME/.claude_sync_logs"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# ─────────────────────────────────────────────────────────────────────────────
# Commands
# ─────────────────────────────────────────────────────────────────────────────

cmd_build() {
    log_info "Building claude-sync-watch..."

    if ! command -v cargo &> /dev/null; then
        log_error "Rust/Cargo not installed. Install from https://rustup.rs"
        exit 1
    fi

    cd "$SCRIPT_DIR/watch"
    cargo build --release

    if [[ -f "$BINARY" ]]; then
        log_success "Built: $BINARY"
    else
        log_error "Build failed"
        exit 1
    fi
}

cmd_install() {
    log_info "Installing claude-sync-watch daemon..."

    # Build if needed
    if [[ ! -f "$BINARY" ]]; then
        cmd_build
    fi

    # Create log directory
    mkdir -p "$LOG_DIR"

    # Create LaunchAgents directory if needed
    mkdir -p "$HOME/Library/LaunchAgents"

    # Generate plist
    cat > "$PLIST_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$PLIST_NAME</string>

    <key>ProgramArguments</key>
    <array>
        <string>$BINARY</string>
        <string>--daemon</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>

    <key>StandardOutPath</key>
    <string>$LOG_DIR/sync-watch.log</string>

    <key>StandardErrorPath</key>
    <string>$LOG_DIR/sync-watch.err</string>

    <key>LowPriorityIO</key>
    <true/>

    <key>ProcessType</key>
    <string>Background</string>

    <key>ThrottleInterval</key>
    <integer>10</integer>
</dict>
</plist>
EOF

    log_success "Created launchd plist: $PLIST_PATH"
    log_info "Logs will be written to: $LOG_DIR/sync-watch.log"

    # Load the agent
    cmd_start

    log_success "Installation complete!"
    echo ""
    log_info "The daemon will now start automatically on login."
    log_info "Use 'claude-sync-daemon.sh status' to check status."
    log_info "Use 'claude-sync-daemon.sh logs' to view logs."
}

cmd_uninstall() {
    log_info "Uninstalling claude-sync-watch daemon..."

    # Stop if running
    cmd_stop 2>/dev/null || true

    # Remove plist
    if [[ -f "$PLIST_PATH" ]]; then
        rm -f "$PLIST_PATH"
        log_success "Removed launchd plist"
    fi

    log_success "Uninstalled (binary and logs preserved)"
}

cmd_start() {
    if [[ ! -f "$PLIST_PATH" ]]; then
        log_error "Daemon not installed. Run: $0 install"
        exit 1
    fi

    if launchctl list | grep -q "$PLIST_NAME"; then
        log_warn "Daemon already running"
        return 0
    fi

    log_info "Starting daemon..."
    launchctl load "$PLIST_PATH"

    sleep 1
    if launchctl list | grep -q "$PLIST_NAME"; then
        log_success "Daemon started"
    else
        log_error "Failed to start daemon. Check logs: $0 logs"
        exit 1
    fi
}

cmd_stop() {
    if [[ ! -f "$PLIST_PATH" ]]; then
        log_warn "Daemon not installed"
        return 0
    fi

    if ! launchctl list | grep -q "$PLIST_NAME"; then
        log_warn "Daemon not running"
        return 0
    fi

    log_info "Stopping daemon..."
    launchctl unload "$PLIST_PATH"
    log_success "Daemon stopped"
}

cmd_restart() {
    cmd_stop
    sleep 1
    cmd_start
}

cmd_status() {
    echo ""
    echo "Claude Sync Watch Daemon Status"
    echo "================================"
    echo ""

    # Check binary
    if [[ -f "$BINARY" ]]; then
        echo -e "Binary:  ${GREEN}installed${NC} ($BINARY)"
    else
        echo -e "Binary:  ${YELLOW}not built${NC}"
    fi

    # Check plist
    if [[ -f "$PLIST_PATH" ]]; then
        echo -e "Plist:   ${GREEN}installed${NC}"
    else
        echo -e "Plist:   ${YELLOW}not installed${NC}"
    fi

    # Check running
    if launchctl list 2>/dev/null | grep -q "$PLIST_NAME"; then
        local pid
        pid=$(launchctl list | grep "$PLIST_NAME" | awk '{print $1}')
        if [[ "$pid" != "-" ]]; then
            echo -e "Status:  ${GREEN}running${NC} (PID: $pid)"
        else
            echo -e "Status:  ${YELLOW}loaded but not running${NC}"
        fi
    else
        echo -e "Status:  ${YELLOW}not running${NC}"
    fi

    # Show log info
    echo ""
    if [[ -f "$LOG_DIR/sync-watch.log" ]]; then
        local log_size
        log_size=$(du -h "$LOG_DIR/sync-watch.log" | cut -f1)
        local last_line
        last_line=$(tail -1 "$LOG_DIR/sync-watch.log" 2>/dev/null || echo "")
        echo "Log file: $LOG_DIR/sync-watch.log ($log_size)"
        if [[ -n "$last_line" ]]; then
            echo "Last log: $last_line"
        fi
    fi

    # Run status command if binary exists
    if [[ -f "$BINARY" ]]; then
        echo ""
        "$BINARY" --status 2>/dev/null || true
    fi

    echo ""
}

cmd_logs() {
    if [[ ! -f "$LOG_DIR/sync-watch.log" ]]; then
        log_warn "No log file yet. Daemon may not have started."
        exit 1
    fi

    local lines="${1:-50}"
    log_info "Showing last $lines lines (use 'logs N' for different count)..."
    echo ""
    tail -n "$lines" "$LOG_DIR/sync-watch.log"
}

cmd_logs_follow() {
    if [[ ! -f "$LOG_DIR/sync-watch.log" ]]; then
        log_warn "No log file yet. Waiting..."
        touch "$LOG_DIR/sync-watch.log"
    fi

    log_info "Following log file (Ctrl+C to exit)..."
    echo ""
    tail -f "$LOG_DIR/sync-watch.log"
}

cmd_once() {
    if [[ ! -f "$BINARY" ]]; then
        log_error "Binary not built. Run: $0 build"
        exit 1
    fi

    log_info "Running one-time sync..."
    "$BINARY" --once
}

cmd_validate() {
    if [[ ! -f "$BINARY" ]]; then
        log_error "Binary not built. Run: $0 build"
        exit 1
    fi

    "$BINARY" --validate
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

usage() {
    cat << EOF
Usage: $0 <command>

Commands:
  build       Build the Rust binary
  install     Build, create launchd plist, and start daemon
  uninstall   Stop daemon and remove launchd plist
  start       Start the daemon
  stop        Stop the daemon
  restart     Restart the daemon
  status      Show daemon status
  logs [N]    Show last N log lines (default: 50)
  follow      Follow log file in real-time
  once        Run one-time sync (no watch)
  validate    Validate configuration

Examples:
  $0 install     # First-time setup
  $0 status      # Check if running
  $0 follow      # Watch logs live
  $0 once        # Manual sync
EOF
}

main() {
    case "${1:-}" in
        build)     cmd_build ;;
        install)   cmd_install ;;
        uninstall) cmd_uninstall ;;
        start)     cmd_start ;;
        stop)      cmd_stop ;;
        restart)   cmd_restart ;;
        status)    cmd_status ;;
        logs)      cmd_logs "${2:-50}" ;;
        follow)    cmd_logs_follow ;;
        once)      cmd_once ;;
        validate)  cmd_validate ;;
        --help|-h|help|"")
            usage
            exit 0
            ;;
        *)
            log_error "Unknown command: $1"
            usage
            exit 1
            ;;
    esac
}

main "$@"
