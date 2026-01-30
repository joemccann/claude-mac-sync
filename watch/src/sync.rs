//! Sync engine - backup-first, copy, validate

use crate::config::Config;
use crate::lock::SyncLock;
use crate::state::{detect_changes, SyncState};
use anyhow::{bail, Context, Result};
use sha2::{Digest, Sha256};
use std::ffi::OsStr;
use std::fs::{self, File};
use std::io::{BufReader, Read};
use std::path::{Path, PathBuf};

/// Direction of sync
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SyncDirection {
    /// Local -> Remote (push)
    Push,
    /// Remote -> Local (pull)
    Pull,
    /// Bidirectional (merge based on timestamps)
    Bidirectional,
}

/// Result of a sync operation
#[derive(Debug)]
pub struct SyncResult {
    /// Number of files copied
    pub copied: usize,
    /// Number of files skipped
    pub skipped: usize,
    /// Path to backup created
    pub backup_path: Option<PathBuf>,
    /// Any warnings encountered
    pub warnings: Vec<String>,
}

/// Sync engine
pub struct SyncEngine {
    config: Config,
    lock: SyncLock,
    state_path: PathBuf,
}

impl SyncEngine {
    /// Create a new sync engine
    pub fn new(config: Config) -> Self {
        let machine_id = Config::machine_id();
        let lock = SyncLock::new(&config.dropbox_claude_dir, machine_id);
        let state_path = config.dropbox_claude_dir.join(".sync_state.json");

        Self {
            config,
            lock,
            state_path,
        }
    }

    /// Perform a sync operation
    pub fn sync(&self, direction: SyncDirection) -> Result<SyncResult> {
        log::info!("Starting {:?} sync...", direction);

        // 1. Acquire distributed lock
        let _lock_guard = self.lock.acquire().context("Failed to acquire sync lock")?;

        // 2. CREATE BACKUP FIRST (mandatory!)
        let backup_path = self.create_backup()?;
        log::info!("Backup created: {:?}", backup_path);

        // 3. Ensure directories exist
        fs::create_dir_all(&self.config.claude_dir)?;
        fs::create_dir_all(&self.config.dropbox_claude_dir)?;

        // 4. Load sync state
        let mut state = SyncState::load(&self.state_path).unwrap_or_default();
        state.machine_id = Config::machine_id();

        // 5. Detect changes
        let changes = detect_changes(
            &self.config.claude_dir,
            &self.config.dropbox_claude_dir,
            &self.config.sync_files,
            &self.config.sync_dirs,
            &state,
        );

        log::info!("Detected {} change(s)", changes.len());

        // 6. Apply changes based on direction
        let mut copied = 0;
        let mut skipped = 0;
        let mut warnings = Vec::new();

        for change in &changes {
            // Determine if this change should be applied based on direction
            let should_apply = match direction {
                SyncDirection::Push => {
                    // Only push: local -> remote
                    change.src.starts_with(&self.config.claude_dir)
                }
                SyncDirection::Pull => {
                    // Only pull: remote -> local
                    change.src.starts_with(&self.config.dropbox_claude_dir)
                }
                SyncDirection::Bidirectional => {
                    // Apply all changes
                    true
                }
            };

            if !should_apply {
                skipped += 1;
                continue;
            }

            // Validate and copy
            match self.safe_copy_file(&change.src, &change.dst) {
                Ok(()) => {
                    log::info!(
                        "{:?}: {} -> {}",
                        change.change_type,
                        change.src.display(),
                        change.dst.display()
                    );

                    // Update state
                    if let Ok(file_state) = SyncState::get_file_state(&change.dst) {
                        state.update_file(&change.rel_path, file_state);
                    }

                    copied += 1;
                }
                Err(e) => {
                    let warning = format!(
                        "Failed to copy {}: {}",
                        change.rel_path,
                        e
                    );
                    log::warn!("{}", warning);
                    warnings.push(warning);
                    skipped += 1;
                }
            }
        }

        // 7. Save updated state
        state.save(&self.state_path)?;

        log::info!(
            "Sync complete: {} copied, {} skipped",
            copied,
            skipped
        );

        Ok(SyncResult {
            copied,
            skipped,
            backup_path: Some(backup_path),
            warnings,
        })
    }

    /// Create a timestamped backup of ~/.claude
    fn create_backup(&self) -> Result<PathBuf> {
        let timestamp = chrono::Local::now().format("%Y%m%d_%H%M%S");
        let backup_path = PathBuf::from(format!(
            "{}/.claude_backup.{}",
            dirs::home_dir()
                .map(|p| p.to_string_lossy().to_string())
                .unwrap_or_else(|| "/tmp".to_string()),
            timestamp
        ));

        if !self.config.claude_dir.exists() {
            log::info!("~/.claude does not exist, skipping backup");
            return Ok(backup_path);
        }

        // Use cp -a to preserve metadata
        copy_dir_all(&self.config.claude_dir, &backup_path)?;

        // Save path for undo capability
        let last_backup_file = dirs::home_dir()
            .unwrap_or_else(|| PathBuf::from("/tmp"))
            .join(".claude_sync_last_backup");
        fs::write(&last_backup_file, backup_path.to_string_lossy().as_bytes())?;

        Ok(backup_path)
    }

    /// Copy a file with validation
    fn safe_copy_file(&self, src: &Path, dst: &Path) -> Result<()> {
        // Check source exists
        if !src.exists() {
            bail!("Source does not exist: {:?}", src);
        }

        // Check source is not empty (sign of Dropbox sync in progress)
        let metadata = fs::metadata(src)?;
        if metadata.len() == 0 {
            bail!(
                "Source file is empty (Dropbox sync in progress?): {:?}",
                src
            );
        }

        // Validate JSON if applicable
        if src.extension() == Some(OsStr::new("json")) {
            self.validate_json(src)?;
        }

        // Ensure destination directory exists
        if let Some(parent) = dst.parent() {
            fs::create_dir_all(parent)?;
        }

        // Copy preserving metadata
        fs::copy(src, dst).with_context(|| format!("Failed to copy {:?} to {:?}", src, dst))?;

        // Verify checksum
        let src_hash = sha256_file(src)?;
        let dst_hash = sha256_file(dst)?;

        if src_hash != dst_hash {
            fs::remove_file(dst).ok();
            bail!(
                "Checksum mismatch after copy: {} vs {}",
                src_hash,
                dst_hash
            );
        }

        log::debug!("Copied and verified: {:?} -> {:?}", src, dst);
        Ok(())
    }

    /// Validate a JSON file
    fn validate_json(&self, path: &Path) -> Result<()> {
        let content = fs::read_to_string(path)
            .with_context(|| format!("Failed to read JSON file: {:?}", path))?;

        serde_json::from_str::<serde_json::Value>(&content)
            .with_context(|| format!("Invalid JSON in file: {:?}", path))?;

        Ok(())
    }

    /// Check if sync is currently locked by another machine
    pub fn is_locked(&self) -> bool {
        self.lock.is_locked_by_other()
    }

    /// Get lock info
    pub fn lock_info(&self) -> Option<(String, i64)> {
        self.lock.lock_info()
    }

    /// Validate source files before sync (pre-flight check)
    pub fn validate_sources(&self, direction: SyncDirection) -> Result<Vec<String>> {
        let mut errors = Vec::new();

        let check_dir = match direction {
            SyncDirection::Push => &self.config.claude_dir,
            SyncDirection::Pull => &self.config.dropbox_claude_dir,
            SyncDirection::Bidirectional => {
                // Check both
                errors.extend(self.validate_directory(&self.config.claude_dir)?);
                &self.config.dropbox_claude_dir
            }
        };

        errors.extend(self.validate_directory(check_dir)?);

        Ok(errors)
    }

    /// Validate a directory for empty/invalid files
    fn validate_directory(&self, dir: &Path) -> Result<Vec<String>> {
        let mut errors = Vec::new();

        if !dir.exists() {
            return Ok(errors);
        }

        // Check sync files
        for file_name in &self.config.sync_files {
            let file_path = dir.join(file_name);
            if file_path.exists() {
                // Check for empty file
                if let Ok(metadata) = fs::metadata(&file_path) {
                    if metadata.len() == 0 {
                        errors.push(format!(
                            "{} is empty (Dropbox may still be syncing)",
                            file_name
                        ));
                        continue;
                    }
                }

                // Validate JSON files
                if file_path.extension() == Some(OsStr::new("json")) {
                    if let Err(e) = self.validate_json(&file_path) {
                        errors.push(format!("{}: {}", file_name, e));
                    }
                }
            }
        }

        // Check sync directories for empty files
        for dir_name in &self.config.sync_dirs {
            let dir_path = dir.join(dir_name);
            if dir_path.exists() && dir_path.is_dir() {
                for entry in walkdir(&dir_path) {
                    if entry.is_file() {
                        if let Ok(metadata) = fs::metadata(&entry) {
                            if metadata.len() == 0 {
                                let rel_path = entry.strip_prefix(dir).unwrap_or(&entry);
                                errors.push(format!(
                                    "{} is empty",
                                    rel_path.display()
                                ));
                            }
                        }

                        // Validate JSON files
                        if entry.extension() == Some(OsStr::new("json")) {
                            if let Err(e) = self.validate_json(&entry) {
                                let rel_path = entry.strip_prefix(dir).unwrap_or(&entry);
                                errors.push(format!("{}: {}", rel_path.display(), e));
                            }
                        }
                    }
                }
            }
        }

        Ok(errors)
    }
}

/// Calculate SHA-256 of a file
fn sha256_file(path: &Path) -> Result<String> {
    let file = File::open(path)?;
    let mut reader = BufReader::new(file);
    let mut hasher = Sha256::new();
    let mut buffer = [0u8; 8192];

    loop {
        let bytes_read = reader.read(&mut buffer)?;
        if bytes_read == 0 {
            break;
        }
        hasher.update(&buffer[..bytes_read]);
    }

    Ok(format!("{:x}", hasher.finalize()))
}

/// Recursively copy a directory
fn copy_dir_all(src: &Path, dst: &Path) -> Result<()> {
    fs::create_dir_all(dst)?;

    for entry in fs::read_dir(src)? {
        let entry = entry?;
        let file_type = entry.file_type()?;
        let src_path = entry.path();
        let dst_path = dst.join(entry.file_name());

        if file_type.is_dir() {
            copy_dir_all(&src_path, &dst_path)?;
        } else if file_type.is_file() {
            fs::copy(&src_path, &dst_path)?;
        } else if file_type.is_symlink() {
            // Copy symlink target
            let target = fs::read_link(&src_path)?;
            #[cfg(unix)]
            std::os::unix::fs::symlink(&target, &dst_path)?;
        }
    }

    Ok(())
}

/// Simple directory walker
fn walkdir(dir: &Path) -> Vec<PathBuf> {
    let mut results = Vec::new();

    if let Ok(entries) = fs::read_dir(dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                results.extend(walkdir(&path));
            } else {
                results.push(path);
            }
        }
    }

    results
}
