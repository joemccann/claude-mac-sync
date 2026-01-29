#!/usr/bin/env bash
#
# test_sync.sh - Comprehensive tests for Claude Code Dropbox sync
#
# Usage: ./test_sync.sh
#
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Test directories
TEST_DIR="/tmp/claude-sync-test-$$"
TEST_LOCAL_DIR="$TEST_DIR/local/.claude"
TEST_DROPBOX_DIR="$TEST_DIR/dropbox/ClaudeCodeSync"
TEST_BACKUP_DIR="$TEST_DIR/local/.claude_backup"
TEST_CONFIG_FILE="$TEST_DIR/local/.claude_sync_config"

# Track test results
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# ─────────────────────────────────────────────────────────────────────────────
# Test Helpers
# ─────────────────────────────────────────────────────────────────────────────

setup_test_env() {
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_LOCAL_DIR"
    mkdir -p "$TEST_DROPBOX_DIR"
    echo "DROPBOX_BASE=\"$TEST_DIR/dropbox\"" > "$TEST_CONFIG_FILE"
}

cleanup_test_env() {
    rm -rf "$TEST_DIR"
}

log_test() {
    echo -e "${YELLOW}[TEST]${NC} $1"
}

pass() {
    ((TESTS_PASSED++))
    echo -e "${GREEN}[PASS]${NC} $1"
}

fail() {
    ((TESTS_FAILED++))
    echo -e "${RED}[FAIL]${NC} $1"
}

run_test() {
    local test_name="$1"
    local test_func="$2"

    ((TESTS_RUN++))
    log_test "$test_name"

    if $test_func; then
        pass "$test_name"
    else
        fail "$test_name"
    fi
}

# Create a valid JSON file
create_valid_json() {
    local path="$1"
    local content="${2:-{\"test\": \"value\", \"number\": 42}}"
    echo "$content" > "$path"
}

# Create an invalid/corrupt JSON file
create_corrupt_json() {
    local path="$1"
    echo "{corrupt json missing bracket" > "$path"
}

# Create an empty file
create_empty_file() {
    local path="$1"
    : > "$path"
}

# Validate JSON syntax
is_valid_json() {
    local path="$1"
    if [[ ! -f "$path" ]]; then
        return 1
    fi
    # Use python for JSON validation (available on macOS)
    python3 -c "import json; json.load(open('$path'))" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# Integrity Validation Functions (to be added to sync scripts)
# ─────────────────────────────────────────────────────────────────────────────

# Check if a file is empty
is_file_empty() {
    local file="$1"
    [[ ! -s "$file" ]]
}

# Validate JSON file integrity
validate_json_file() {
    local file="$1"

    # Check if file exists
    if [[ ! -f "$file" ]]; then
        echo "File does not exist: $file" >&2
        return 1
    fi

    # Check if file is empty
    if [[ ! -s "$file" ]]; then
        echo "File is empty: $file" >&2
        return 1
    fi

    # Check JSON syntax
    if ! python3 -c "import json; json.load(open('$file'))" 2>/dev/null; then
        echo "Invalid JSON syntax: $file" >&2
        return 1
    fi

    return 0
}

# Validate file integrity by comparing checksums
validate_file_copy() {
    local src="$1"
    local dst="$2"

    if [[ ! -f "$src" || ! -f "$dst" ]]; then
        return 1
    fi

    local src_sum dst_sum
    src_sum=$(shasum -a 256 "$src" | cut -d' ' -f1)
    dst_sum=$(shasum -a 256 "$dst" | cut -d' ' -f1)

    [[ "$src_sum" == "$dst_sum" ]]
}

# Validate directory integrity by comparing file counts and checksums
validate_dir_copy() {
    local src="$1"
    local dst="$2"

    if [[ ! -d "$src" || ! -d "$dst" ]]; then
        return 1
    fi

    # Compare file counts
    local src_count dst_count
    src_count=$(find "$src" -type f | wc -l | tr -d ' ')
    dst_count=$(find "$dst" -type f | wc -l | tr -d ' ')

    if [[ "$src_count" != "$dst_count" ]]; then
        echo "File count mismatch: src=$src_count, dst=$dst_count" >&2
        return 1
    fi

    # Compare each file's checksum
    while IFS= read -r -d '' file; do
        local rel_path="${file#$src/}"
        local dst_file="$dst/$rel_path"

        if [[ ! -f "$dst_file" ]]; then
            echo "Missing file in destination: $rel_path" >&2
            return 1
        fi

        if ! validate_file_copy "$file" "$dst_file"; then
            echo "Checksum mismatch: $rel_path" >&2
            return 1
        fi
    done < <(find "$src" -type f -print0)

    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Tests: JSON File Integrity
# ─────────────────────────────────────────────────────────────────────────────

test_detect_empty_json_file() {
    local test_file="$TEST_DIR/empty.json"
    create_empty_file "$test_file"

    # Should detect as empty
    is_file_empty "$test_file"
}

test_detect_corrupt_json_file() {
    local test_file="$TEST_DIR/corrupt.json"
    create_corrupt_json "$test_file"

    # Should NOT be valid JSON
    ! is_valid_json "$test_file"
}

test_detect_valid_json_file() {
    local test_file="$TEST_DIR/valid.json"
    create_valid_json "$test_file"

    # Should be valid JSON
    is_valid_json "$test_file"
}

test_validate_json_rejects_empty() {
    local test_file="$TEST_DIR/empty.json"
    create_empty_file "$test_file"

    # validate_json_file should fail
    ! validate_json_file "$test_file" 2>/dev/null
}

test_validate_json_rejects_corrupt() {
    local test_file="$TEST_DIR/corrupt.json"
    create_corrupt_json "$test_file"

    # validate_json_file should fail
    ! validate_json_file "$test_file" 2>/dev/null
}

test_validate_json_accepts_valid() {
    local test_file="$TEST_DIR/valid.json"
    create_valid_json "$test_file"

    # validate_json_file should pass
    validate_json_file "$test_file" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# Tests: File Copy Integrity
# ─────────────────────────────────────────────────────────────────────────────

test_file_copy_checksum_match() {
    local src="$TEST_DIR/src.json"
    local dst="$TEST_DIR/dst.json"

    create_valid_json "$src" '{"key": "value123"}'
    cp "$src" "$dst"

    validate_file_copy "$src" "$dst"
}

test_file_copy_checksum_mismatch() {
    local src="$TEST_DIR/src.json"
    local dst="$TEST_DIR/dst.json"

    create_valid_json "$src" '{"key": "value123"}'
    create_valid_json "$dst" '{"key": "different"}'

    ! validate_file_copy "$src" "$dst"
}

test_copy_preserves_content() {
    local src="$TEST_DIR/src.json"
    local dst="$TEST_DIR/dst.json"
    local content='{"settings": {"theme": "dark", "fontSize": 14}, "array": [1, 2, 3]}'

    echo "$content" > "$src"
    cp -p "$src" "$dst"

    # Validate the copy matches
    validate_file_copy "$src" "$dst" && is_valid_json "$dst"
}

# ─────────────────────────────────────────────────────────────────────────────
# Tests: Directory Copy Integrity
# ─────────────────────────────────────────────────────────────────────────────

test_dir_copy_integrity() {
    local src_dir="$TEST_DIR/src_dir"
    local dst_dir="$TEST_DIR/dst_dir"

    # Create source directory with files
    mkdir -p "$src_dir/subdir"
    create_valid_json "$src_dir/file1.json"
    create_valid_json "$src_dir/file2.json" '{"key": "file2"}'
    create_valid_json "$src_dir/subdir/nested.json" '{"nested": true}'

    # Copy directory
    cp -rp "$src_dir" "$dst_dir"

    validate_dir_copy "$src_dir" "$dst_dir"
}

test_dir_copy_detects_missing_file() {
    local src_dir="$TEST_DIR/src_dir"
    local dst_dir="$TEST_DIR/dst_dir"

    # Create source directory with files
    mkdir -p "$src_dir"
    create_valid_json "$src_dir/file1.json"
    create_valid_json "$src_dir/file2.json"

    # Copy but remove one file from destination
    cp -rp "$src_dir" "$dst_dir"
    rm "$dst_dir/file2.json"

    ! validate_dir_copy "$src_dir" "$dst_dir" 2>/dev/null
}

test_dir_copy_detects_corrupt_file() {
    local src_dir="$TEST_DIR/src_dir"
    local dst_dir="$TEST_DIR/dst_dir"

    # Create source directory with files
    mkdir -p "$src_dir"
    create_valid_json "$src_dir/file1.json" '{"original": "content"}'

    # Copy then corrupt destination
    cp -rp "$src_dir" "$dst_dir"
    echo "corrupted" > "$dst_dir/file1.json"

    ! validate_dir_copy "$src_dir" "$dst_dir" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# Tests: Push/Pull Simulation
# ─────────────────────────────────────────────────────────────────────────────

test_push_creates_valid_copies() {
    setup_test_env

    # Create local files
    create_valid_json "$TEST_LOCAL_DIR/settings.json" '{"setting": "value"}'
    create_valid_json "$TEST_LOCAL_DIR/mcp.json" '{"servers": []}'
    mkdir -p "$TEST_LOCAL_DIR/skills/test-skill"
    echo "# Test skill" > "$TEST_LOCAL_DIR/skills/test-skill/skill.md"

    # Simulate push
    for file in settings.json mcp.json; do
        local src="$TEST_LOCAL_DIR/$file"
        local dst="$TEST_DROPBOX_DIR/$file"
        if [[ -f "$src" ]]; then
            cp -p "$src" "$dst"
        fi
    done

    cp -rp "$TEST_LOCAL_DIR/skills" "$TEST_DROPBOX_DIR/skills"

    # Validate all copies
    validate_file_copy "$TEST_LOCAL_DIR/settings.json" "$TEST_DROPBOX_DIR/settings.json" &&
    validate_file_copy "$TEST_LOCAL_DIR/mcp.json" "$TEST_DROPBOX_DIR/mcp.json" &&
    validate_dir_copy "$TEST_LOCAL_DIR/skills" "$TEST_DROPBOX_DIR/skills"
}

test_pull_creates_valid_copies() {
    setup_test_env

    # Create Dropbox files (simulating source)
    create_valid_json "$TEST_DROPBOX_DIR/settings.json" '{"setting": "from_dropbox"}'
    create_valid_json "$TEST_DROPBOX_DIR/mcp.json" '{"servers": ["server1"]}'
    mkdir -p "$TEST_DROPBOX_DIR/skills/remote-skill"
    echo "# Remote skill" > "$TEST_DROPBOX_DIR/skills/remote-skill/skill.md"

    # Simulate pull
    for file in settings.json mcp.json; do
        local src="$TEST_DROPBOX_DIR/$file"
        local dst="$TEST_LOCAL_DIR/$file"
        if [[ -f "$src" ]]; then
            cp -p "$src" "$dst"
        fi
    done

    rm -rf "$TEST_LOCAL_DIR/skills"
    cp -rp "$TEST_DROPBOX_DIR/skills" "$TEST_LOCAL_DIR/skills"

    # Validate all copies
    validate_file_copy "$TEST_DROPBOX_DIR/settings.json" "$TEST_LOCAL_DIR/settings.json" &&
    validate_file_copy "$TEST_DROPBOX_DIR/mcp.json" "$TEST_LOCAL_DIR/mcp.json" &&
    validate_dir_copy "$TEST_DROPBOX_DIR/skills" "$TEST_LOCAL_DIR/skills"
}

test_pull_rejects_empty_source() {
    setup_test_env

    # Create empty source file (simulating Dropbox sync in progress)
    create_empty_file "$TEST_DROPBOX_DIR/settings.json"

    # Should fail validation before copy
    ! validate_json_file "$TEST_DROPBOX_DIR/settings.json" 2>/dev/null
}

test_pull_rejects_corrupt_source() {
    setup_test_env

    # Create corrupt source file
    create_corrupt_json "$TEST_DROPBOX_DIR/settings.json"

    # Should fail validation before copy
    ! validate_json_file "$TEST_DROPBOX_DIR/settings.json" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# Tests: Symlink Handling
# ─────────────────────────────────────────────────────────────────────────────

test_detect_symlink() {
    setup_test_env

    # Create a symlink
    create_valid_json "$TEST_DROPBOX_DIR/settings.json"
    ln -s "$TEST_DROPBOX_DIR/settings.json" "$TEST_LOCAL_DIR/settings.json"

    # Should detect as symlink
    [[ -L "$TEST_LOCAL_DIR/settings.json" ]]
}

test_replace_symlink_with_file() {
    setup_test_env

    # Create a symlink
    create_valid_json "$TEST_DROPBOX_DIR/settings.json" '{"real": "content"}'
    ln -s "$TEST_DROPBOX_DIR/settings.json" "$TEST_LOCAL_DIR/settings.json"

    # Replace symlink with real file (simulate pull)
    rm -f "$TEST_LOCAL_DIR/settings.json"
    cp -p "$TEST_DROPBOX_DIR/settings.json" "$TEST_LOCAL_DIR/settings.json"

    # Should now be a regular file, not a symlink
    [[ -f "$TEST_LOCAL_DIR/settings.json" && ! -L "$TEST_LOCAL_DIR/settings.json" ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# Tests: Dropbox-specific issues
# ─────────────────────────────────────────────────────────────────────────────

test_detect_dropbox_conflict() {
    setup_test_env

    # Create conflict files like Dropbox does
    create_valid_json "$TEST_DROPBOX_DIR/settings.json"
    create_valid_json "$TEST_DROPBOX_DIR/settings (Joe's MacBook Pro's conflicted copy 2025-01-28).json"

    # Should detect conflicts
    local conflicts
    conflicts=$(find "$TEST_DROPBOX_DIR" -name "*conflicted copy*" 2>/dev/null)
    [[ -n "$conflicts" ]]
}

test_detect_dropbox_sync_in_progress() {
    setup_test_env

    # Dropbox creates .dropbox.attrs and temp files during sync
    touch "$TEST_DROPBOX_DIR/.dropbox.attrs"
    touch "$TEST_DROPBOX_DIR/settings.json.tmp"
    create_empty_file "$TEST_DROPBOX_DIR/settings.json"

    # Should detect the main file as potentially problematic
    is_file_empty "$TEST_DROPBOX_DIR/settings.json"
}

# ─────────────────────────────────────────────────────────────────────────────
# Tests: CLAUDE.md handling (non-JSON)
# ─────────────────────────────────────────────────────────────────────────────

test_markdown_file_copy_integrity() {
    setup_test_env

    local src="$TEST_LOCAL_DIR/CLAUDE.md"
    local dst="$TEST_DROPBOX_DIR/CLAUDE.md"
    local content="# My Claude Instructions\n\nAlways be helpful."

    echo -e "$content" > "$src"
    cp -p "$src" "$dst"

    validate_file_copy "$src" "$dst"
}

test_markdown_not_validated_as_json() {
    setup_test_env

    local file="$TEST_DIR/CLAUDE.md"
    echo "# Not JSON" > "$file"

    # Should NOT be valid JSON (expected)
    ! is_valid_json "$file"
}

# ─────────────────────────────────────────────────────────────────────────────
# Tests: Undo/Restore Functionality
# ─────────────────────────────────────────────────────────────────────────────

test_backup_creates_last_backup_marker() {
    setup_test_env

    # Create local files
    create_valid_json "$TEST_LOCAL_DIR/settings.json" '{"local": "data"}'

    # Simulate backup (like pull does)
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_path="$TEST_DIR/local/.claude_backup.$timestamp"
    cp -a "$TEST_LOCAL_DIR" "$backup_path"
    echo "$backup_path" > "$TEST_DIR/local/.claude_sync_last_backup"

    # Verify marker exists and contains correct path
    [[ -f "$TEST_DIR/local/.claude_sync_last_backup" ]] &&
    [[ "$(cat "$TEST_DIR/local/.claude_sync_last_backup")" == "$backup_path" ]]
}

test_undo_restores_previous_state() {
    setup_test_env

    # Create original local files
    echo '{"original": "data"}' > "$TEST_LOCAL_DIR/settings.json"

    # Simulate backup before pull
    local backup_path="$TEST_DIR/local/.claude_backup.test"
    cp -a "$TEST_LOCAL_DIR" "$backup_path"
    echo "$backup_path" > "$TEST_DIR/local/.claude_sync_last_backup"

    # Simulate pull changing the file
    echo '{"pulled": "newdata"}' > "$TEST_LOCAL_DIR/settings.json"

    # Verify file was changed
    grep -q '"pulled"' "$TEST_LOCAL_DIR/settings.json" || return 1

    # Simulate undo
    rm -rf "$TEST_LOCAL_DIR"
    cp -a "$backup_path" "$TEST_LOCAL_DIR"
    rm -f "$TEST_DIR/local/.claude_sync_last_backup"

    # Verify original data is restored
    grep -q '"original"' "$TEST_LOCAL_DIR/settings.json" &&
    [[ ! -f "$TEST_DIR/local/.claude_sync_last_backup" ]]
}

test_restore_from_specific_backup() {
    setup_test_env

    # Create multiple backups
    mkdir -p "$TEST_DIR/local/.claude_backup.20250128_100000"
    echo '{"backup": "first"}' > "$TEST_DIR/local/.claude_backup.20250128_100000/settings.json"

    mkdir -p "$TEST_DIR/local/.claude_backup.20250128_120000"
    echo '{"backup": "second"}' > "$TEST_DIR/local/.claude_backup.20250128_120000/settings.json"

    # Current state
    echo '{"current": "state"}' > "$TEST_LOCAL_DIR/settings.json"

    # Restore from first backup
    rm -rf "$TEST_LOCAL_DIR"
    cp -a "$TEST_DIR/local/.claude_backup.20250128_100000" "$TEST_LOCAL_DIR"

    # Verify correct backup was restored
    grep -q '"first"' "$TEST_LOCAL_DIR/settings.json"
}

test_backup_integrity_after_restore() {
    setup_test_env

    # Create backup with multiple files
    local backup_path="$TEST_DIR/local/.claude_backup.test"
    mkdir -p "$backup_path/skills/myskill"
    create_valid_json "$backup_path/settings.json" '{"setting": 1}'
    create_valid_json "$backup_path/mcp.json" '{"servers": []}'
    echo "# Skill" > "$backup_path/skills/myskill/skill.md"

    # Restore
    rm -rf "$TEST_LOCAL_DIR"
    cp -a "$backup_path" "$TEST_LOCAL_DIR"

    # Verify all files are present and valid
    [[ -f "$TEST_LOCAL_DIR/settings.json" ]] &&
    [[ -f "$TEST_LOCAL_DIR/mcp.json" ]] &&
    [[ -f "$TEST_LOCAL_DIR/skills/myskill/skill.md" ]] &&
    validate_file_copy "$backup_path/settings.json" "$TEST_LOCAL_DIR/settings.json" &&
    validate_file_copy "$backup_path/mcp.json" "$TEST_LOCAL_DIR/mcp.json"
}

# ─────────────────────────────────────────────────────────────────────────────
# Main Test Runner
# ─────────────────────────────────────────────────────────────────────────────

main() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Claude Code Sync - Test Suite"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Setup
    mkdir -p "$TEST_DIR"

    # JSON File Integrity Tests
    echo -e "\n${YELLOW}=== JSON File Integrity ===${NC}"
    run_test "Detect empty JSON file" test_detect_empty_json_file
    run_test "Detect corrupt JSON file" test_detect_corrupt_json_file
    run_test "Detect valid JSON file" test_detect_valid_json_file
    run_test "Validate rejects empty JSON" test_validate_json_rejects_empty
    run_test "Validate rejects corrupt JSON" test_validate_json_rejects_corrupt
    run_test "Validate accepts valid JSON" test_validate_json_accepts_valid

    # File Copy Integrity Tests
    echo -e "\n${YELLOW}=== File Copy Integrity ===${NC}"
    run_test "File copy checksum match" test_file_copy_checksum_match
    run_test "File copy checksum mismatch detected" test_file_copy_checksum_mismatch
    run_test "Copy preserves file content" test_copy_preserves_content

    # Directory Copy Integrity Tests
    echo -e "\n${YELLOW}=== Directory Copy Integrity ===${NC}"
    run_test "Directory copy integrity" test_dir_copy_integrity
    run_test "Detect missing file in directory" test_dir_copy_detects_missing_file
    run_test "Detect corrupt file in directory" test_dir_copy_detects_corrupt_file

    # Push/Pull Simulation Tests
    echo -e "\n${YELLOW}=== Push/Pull Simulation ===${NC}"
    run_test "Push creates valid copies" test_push_creates_valid_copies
    run_test "Pull creates valid copies" test_pull_creates_valid_copies
    run_test "Pull rejects empty source" test_pull_rejects_empty_source
    run_test "Pull rejects corrupt source" test_pull_rejects_corrupt_source

    # Symlink Handling Tests
    echo -e "\n${YELLOW}=== Symlink Handling ===${NC}"
    run_test "Detect symlink" test_detect_symlink
    run_test "Replace symlink with file" test_replace_symlink_with_file

    # Dropbox-specific Tests
    echo -e "\n${YELLOW}=== Dropbox-specific Issues ===${NC}"
    run_test "Detect Dropbox conflicts" test_detect_dropbox_conflict
    run_test "Detect Dropbox sync in progress" test_detect_dropbox_sync_in_progress

    # Markdown Tests
    echo -e "\n${YELLOW}=== CLAUDE.md Handling ===${NC}"
    run_test "Markdown file copy integrity" test_markdown_file_copy_integrity
    run_test "Markdown not validated as JSON" test_markdown_not_validated_as_json

    # Undo/Restore Tests
    echo -e "\n${YELLOW}=== Undo/Restore Functionality ===${NC}"
    run_test "Backup creates last backup marker" test_backup_creates_last_backup_marker
    run_test "Undo restores previous state" test_undo_restores_previous_state
    run_test "Restore from specific backup" test_restore_from_specific_backup
    run_test "Backup integrity after restore" test_backup_integrity_after_restore

    # Cleanup
    cleanup_test_env

    # Summary
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  Tests Run: $TESTS_RUN  |  ${GREEN}Passed: $TESTS_PASSED${NC}  |  ${RED}Failed: $TESTS_FAILED${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    if [[ $TESTS_FAILED -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
