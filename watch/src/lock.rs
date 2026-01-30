//! Distributed lock via Dropbox for preventing concurrent syncs

use anyhow::{bail, Context, Result};
use chrono::Utc;
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};

/// Lock timeout in seconds (auto-release stale locks)
const LOCK_TIMEOUT_SECS: i64 = 60;

/// Lock file content
#[derive(Debug, Serialize, Deserialize)]
struct LockFile {
    machine_id: String,
    timestamp: i64,
    pid: u32,
}

/// Distributed sync lock
pub struct SyncLock {
    lock_path: PathBuf,
    machine_id: String,
}

/// Guard that releases the lock when dropped
pub struct LockGuard {
    path: PathBuf,
    machine_id: String,
}

impl SyncLock {
    /// Create a new sync lock
    pub fn new(dropbox_claude_dir: &Path, machine_id: String) -> Self {
        Self {
            lock_path: dropbox_claude_dir.join(".sync_lock"),
            machine_id,
        }
    }

    /// Attempt to acquire the lock
    pub fn acquire(&self) -> Result<LockGuard> {
        // Ensure parent directory exists
        if let Some(parent) = self.lock_path.parent() {
            fs::create_dir_all(parent)?;
        }

        // Check for existing lock
        if let Ok(content) = fs::read_to_string(&self.lock_path) {
            if let Ok(lock) = serde_json::from_str::<LockFile>(&content) {
                let age = Utc::now().timestamp() - lock.timestamp;

                if age < LOCK_TIMEOUT_SECS && lock.machine_id != self.machine_id {
                    bail!(
                        "Sync locked by {} ({} seconds ago). Will auto-release after {} seconds.",
                        lock.machine_id,
                        age,
                        LOCK_TIMEOUT_SECS - age
                    );
                }
                // Lock is stale or ours - we can take it
                log::debug!(
                    "Taking over lock from {} (age: {}s)",
                    lock.machine_id,
                    age
                );
            }
        }

        // Write our lock
        let lock = LockFile {
            machine_id: self.machine_id.clone(),
            timestamp: Utc::now().timestamp(),
            pid: std::process::id(),
        };

        let content = serde_json::to_string_pretty(&lock)?;
        fs::write(&self.lock_path, &content)
            .with_context(|| format!("Failed to write lock file: {:?}", self.lock_path))?;

        log::debug!("Acquired sync lock");

        Ok(LockGuard {
            path: self.lock_path.clone(),
            machine_id: self.machine_id.clone(),
        })
    }

    /// Check if the lock is currently held by another machine
    pub fn is_locked_by_other(&self) -> bool {
        if let Ok(content) = fs::read_to_string(&self.lock_path) {
            if let Ok(lock) = serde_json::from_str::<LockFile>(&content) {
                let age = Utc::now().timestamp() - lock.timestamp;
                return age < LOCK_TIMEOUT_SECS && lock.machine_id != self.machine_id;
            }
        }
        false
    }

    /// Get info about who holds the lock
    pub fn lock_info(&self) -> Option<(String, i64)> {
        fs::read_to_string(&self.lock_path).ok().and_then(|content| {
            serde_json::from_str::<LockFile>(&content)
                .ok()
                .map(|lock| {
                    let age = Utc::now().timestamp() - lock.timestamp;
                    (lock.machine_id, age)
                })
        })
    }
}

impl Drop for LockGuard {
    fn drop(&mut self) {
        // Only remove the lock if it's still ours
        if let Ok(content) = fs::read_to_string(&self.path) {
            if let Ok(lock) = serde_json::from_str::<LockFile>(&content) {
                if lock.machine_id == self.machine_id {
                    if let Err(e) = fs::remove_file(&self.path) {
                        log::warn!("Failed to release lock: {}", e);
                    } else {
                        log::debug!("Released sync lock");
                    }
                }
            }
        }
    }
}

impl LockGuard {
    /// Refresh the lock timestamp (for long operations)
    #[allow(dead_code)]
    pub fn refresh(&self) -> Result<()> {
        let lock = LockFile {
            machine_id: self.machine_id.clone(),
            timestamp: Utc::now().timestamp(),
            pid: std::process::id(),
        };

        let content = serde_json::to_string_pretty(&lock)?;
        fs::write(&self.path, &content)?;
        log::debug!("Refreshed lock timestamp");
        Ok(())
    }
}
