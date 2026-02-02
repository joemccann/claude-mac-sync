//! Local process lock to prevent multiple daemon instances on the same machine
//!
//! NOTE: This is NOT a distributed lock. Dropbox-based distributed locking was removed
//! because it fundamentally cannot work with Dropbox's eventual consistency model.
//! Dropbox sync creates race conditions that generate thousands of "conflicted copy" files.
//!
//! Conflict resolution between machines is handled by:
//! - mtime comparison (newer wins)
//! - checksum verification
//! - backup-first workflow

use anyhow::{bail, Context, Result};
use std::fs;
use std::path::PathBuf;

/// Local process lock (prevents multiple daemons on same machine)
pub struct ProcessLock {
    lock_path: PathBuf,
}

impl ProcessLock {
    /// Create a new process lock
    pub fn new(lock_path: PathBuf) -> Self {
        Self { lock_path }
    }

    /// Attempt to acquire the process lock
    ///
    /// Returns Ok(()) if lock acquired, Err if another process holds it
    #[allow(dead_code)]
    pub fn acquire(&self) -> Result<()> {
        // Ensure parent directory exists
        if let Some(parent) = self.lock_path.parent() {
            fs::create_dir_all(parent)?;
        }

        // Check for existing lock
        if self.lock_path.exists() {
            if let Ok(content) = fs::read_to_string(&self.lock_path) {
                if let Ok(pid) = content.trim().parse::<u32>() {
                    // Check if the process is still running
                    if process_exists(pid) {
                        bail!(
                            "Another sync daemon is already running (PID {}). \
                             Stop it first with: ./claude-sync-daemon.sh stop",
                            pid
                        );
                    }
                    // Process is dead, stale lock file
                    log::debug!("Removing stale lock file from dead process {}", pid);
                }
            }
        }

        // Write our PID to the lock file
        let pid = std::process::id();
        fs::write(&self.lock_path, pid.to_string())
            .with_context(|| format!("Failed to write lock file: {:?}", self.lock_path))?;

        log::debug!("Acquired process lock (PID {})", pid);
        Ok(())
    }

    /// Release the lock (only if we own it)
    pub fn release(&self) {
        if let Ok(content) = fs::read_to_string(&self.lock_path) {
            if let Ok(pid) = content.trim().parse::<u32>() {
                if pid == std::process::id() {
                    if let Err(e) = fs::remove_file(&self.lock_path) {
                        log::warn!("Failed to release process lock: {}", e);
                    } else {
                        log::debug!("Released process lock");
                    }
                }
            }
        }
    }

    /// Check if another process holds the lock
    pub fn is_locked_by_other(&self) -> bool {
        if let Ok(content) = fs::read_to_string(&self.lock_path) {
            if let Ok(pid) = content.trim().parse::<u32>() {
                return pid != std::process::id() && process_exists(pid);
            }
        }
        false
    }

    /// Get the PID of the process holding the lock, if any
    pub fn holder_pid(&self) -> Option<u32> {
        fs::read_to_string(&self.lock_path).ok().and_then(|content| {
            content.trim().parse::<u32>().ok().filter(|&pid| process_exists(pid))
        })
    }
}

impl Drop for ProcessLock {
    fn drop(&mut self) {
        self.release();
    }
}

/// Check if a process with the given PID exists
#[cfg(unix)]
fn process_exists(pid: u32) -> bool {
    // On Unix, sending signal 0 checks if process exists without affecting it
    unsafe { libc::kill(pid as i32, 0) == 0 }
}

#[cfg(not(unix))]
fn process_exists(_pid: u32) -> bool {
    // Conservative fallback: assume process exists
    true
}
