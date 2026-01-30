//! Sync state tracking (checksums, mtimes)

use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{BufReader, Read};
use std::path::{Path, PathBuf};
use std::time::SystemTime;

/// State of a single file
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileState {
    /// SHA-256 checksum of the file
    pub sha256: String,
    /// Modification time as Unix timestamp
    pub mtime: i64,
    /// File size in bytes
    pub size: u64,
}

/// Sync state for tracking file changes
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncState {
    /// Version of the state format
    pub version: u32,
    /// Machine ID that last updated this state
    pub machine_id: String,
    /// Last sync timestamp
    pub last_sync: DateTime<Utc>,
    /// State of each synced file (relative path -> state)
    pub files: HashMap<String, FileState>,
}

impl Default for SyncState {
    fn default() -> Self {
        Self {
            version: 1,
            machine_id: String::new(),
            last_sync: Utc::now(),
            files: HashMap::new(),
        }
    }
}

impl SyncState {
    /// Load state from a JSON file
    pub fn load(path: &Path) -> Result<Self> {
        if !path.exists() {
            return Ok(Self::default());
        }

        let content = fs::read_to_string(path)
            .with_context(|| format!("Failed to read state file: {:?}", path))?;

        serde_json::from_str(&content)
            .with_context(|| format!("Failed to parse state file: {:?}", path))
    }

    /// Save state to a JSON file
    pub fn save(&self, path: &Path) -> Result<()> {
        // Ensure parent directory exists
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }

        let content = serde_json::to_string_pretty(self)?;
        fs::write(path, content).with_context(|| format!("Failed to write state file: {:?}", path))
    }

    /// Compute SHA-256 checksum of a file
    pub fn sha256_file(path: &Path) -> Result<String> {
        let file = File::open(path).with_context(|| format!("Failed to open file: {:?}", path))?;
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

    /// Get file state from the filesystem
    pub fn get_file_state(path: &Path) -> Result<FileState> {
        let metadata = fs::metadata(path)
            .with_context(|| format!("Failed to get metadata for: {:?}", path))?;

        let mtime = metadata
            .modified()
            .unwrap_or(SystemTime::UNIX_EPOCH)
            .duration_since(SystemTime::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);

        let sha256 = Self::sha256_file(path)?;

        Ok(FileState {
            sha256,
            mtime,
            size: metadata.len(),
        })
    }

    /// Get the current state of a file if it exists, None if it doesn't
    pub fn current_file_state(path: &Path) -> Option<FileState> {
        if path.exists() && path.is_file() {
            Self::get_file_state(path).ok()
        } else {
            None
        }
    }

    /// Update state for a file
    pub fn update_file(&mut self, rel_path: &str, state: FileState) {
        self.files.insert(rel_path.to_string(), state);
        self.last_sync = Utc::now();
    }

    /// Remove a file from state
    #[allow(dead_code)]
    pub fn remove_file(&mut self, rel_path: &str) {
        self.files.remove(rel_path);
        self.last_sync = Utc::now();
    }

    /// Check if a file has changed compared to recorded state
    #[allow(dead_code)]
    pub fn file_changed(&self, rel_path: &str, current: &FileState) -> bool {
        match self.files.get(rel_path) {
            Some(recorded) => recorded.sha256 != current.sha256,
            None => true, // New file
        }
    }
}

/// Type of change detected
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[allow(dead_code)]
pub enum ChangeType {
    Created,
    Modified,
    Deleted,
}

/// A detected change
#[derive(Debug, Clone)]
pub struct Change {
    /// Relative path of the file
    pub rel_path: String,
    /// Type of change
    pub change_type: ChangeType,
    /// Source path (for sync operations)
    pub src: PathBuf,
    /// Destination path (for sync operations)
    pub dst: PathBuf,
}

/// Detect changes between local and remote directories
pub fn detect_changes(
    local_dir: &Path,
    remote_dir: &Path,
    sync_files: &[String],
    sync_dirs: &[String],
    state: &SyncState,
) -> Vec<Change> {
    let mut changes = Vec::new();

    // Check individual files
    for file_name in sync_files {
        let local_path = local_dir.join(file_name);
        let remote_path = remote_dir.join(file_name);

        let local_state = SyncState::current_file_state(&local_path);
        let remote_state = SyncState::current_file_state(&remote_path);

        match (&local_state, &remote_state) {
            (Some(local), Some(remote)) => {
                // Both exist - check which is newer
                if local.sha256 != remote.sha256 {
                    if local.mtime > remote.mtime {
                        // Local is newer -> push to remote
                        changes.push(Change {
                            rel_path: file_name.clone(),
                            change_type: ChangeType::Modified,
                            src: local_path,
                            dst: remote_path,
                        });
                    } else if remote.mtime > local.mtime {
                        // Remote is newer -> pull to local
                        changes.push(Change {
                            rel_path: file_name.clone(),
                            change_type: ChangeType::Modified,
                            src: remote_path,
                            dst: local_path,
                        });
                    }
                    // If same mtime but different hash, that's a conflict - use config strategy
                }
            }
            (Some(_), None) => {
                // Local exists, remote doesn't -> push
                changes.push(Change {
                    rel_path: file_name.clone(),
                    change_type: ChangeType::Created,
                    src: local_path,
                    dst: remote_path,
                });
            }
            (None, Some(_)) => {
                // Remote exists, local doesn't -> pull
                changes.push(Change {
                    rel_path: file_name.clone(),
                    change_type: ChangeType::Created,
                    src: remote_path,
                    dst: local_path,
                });
            }
            (None, None) => {
                // Neither exists - nothing to do
            }
        }
    }

    // Check directories
    for dir_name in sync_dirs {
        let local_dir_path = local_dir.join(dir_name);
        let remote_dir_path = remote_dir.join(dir_name);

        if local_dir_path.exists() {
            scan_directory_changes(
                &local_dir_path,
                &remote_dir_path,
                dir_name,
                state,
                &mut changes,
                true, // local is source
            );
        }

        if remote_dir_path.exists() {
            scan_directory_changes(
                &remote_dir_path,
                &local_dir_path,
                dir_name,
                state,
                &mut changes,
                false, // remote is source
            );
        }
    }

    changes
}

/// Scan a directory for changes
fn scan_directory_changes(
    src_dir: &Path,
    dst_dir: &Path,
    prefix: &str,
    state: &SyncState,
    changes: &mut Vec<Change>,
    local_is_src: bool,
) {
    if let Ok(entries) = fs::read_dir(src_dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            let file_name = entry.file_name();
            let file_name_str = file_name.to_string_lossy();

            // Skip hidden files
            if file_name_str.starts_with('.') {
                continue;
            }

            let rel_path = format!("{}/{}", prefix, file_name_str);
            let dst_path = dst_dir.join(&*file_name_str);

            if path.is_file() {
                let src_state = SyncState::current_file_state(&path);
                let dst_state = SyncState::current_file_state(&dst_path);

                let should_add = match (&src_state, &dst_state) {
                    (Some(_src), None) => true,
                    (Some(src), Some(dst)) => {
                        if src.sha256 != dst.sha256 {
                            // Different content - check which is newer
                            if local_is_src {
                                src.mtime > dst.mtime
                            } else {
                                src.mtime > dst.mtime
                            }
                        } else {
                            false
                        }
                    }
                    _ => false,
                };

                if should_add {
                    // Check if we already have this change (avoid duplicates)
                    let already_exists = changes.iter().any(|c| c.rel_path == rel_path);
                    if !already_exists {
                        changes.push(Change {
                            rel_path,
                            change_type: if dst_state.is_some() {
                                ChangeType::Modified
                            } else {
                                ChangeType::Created
                            },
                            src: path,
                            dst: dst_path,
                        });
                    }
                }
            } else if path.is_dir() {
                // Recurse into subdirectory
                scan_directory_changes(&path, &dst_path, &rel_path, state, changes, local_is_src);
            }
        }
    }
}
