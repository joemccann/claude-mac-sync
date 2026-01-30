//! File system watching with notify crate

use crate::config::Config;
use crate::sync::{SyncDirection, SyncEngine};
use anyhow::Result;
use notify::{Config as NotifyConfig, Event, EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// Change buffer for debouncing
struct ChangeBuffer {
    /// Pending changes: path -> (is_local, first_seen)
    pending: HashMap<PathBuf, (bool, Instant)>,
    /// First change in current batch
    first_change: Option<Instant>,
}

impl ChangeBuffer {
    fn new() -> Self {
        Self {
            pending: HashMap::new(),
            first_change: None,
        }
    }

    /// Add a change to the buffer
    fn add(&mut self, path: PathBuf, is_local: bool) {
        if self.first_change.is_none() {
            self.first_change = Some(Instant::now());
        }
        self.pending.insert(path, (is_local, Instant::now()));
    }

    /// Check if we should flush (debounce expired or max batch time reached)
    fn should_flush(&self, debounce_secs: f64, max_batch_secs: f64) -> bool {
        if self.pending.is_empty() {
            return false;
        }

        // Check max batch time
        if let Some(first) = self.first_change {
            if first.elapsed() >= Duration::from_secs_f64(max_batch_secs) {
                return true;
            }
        }

        // Check if all pending changes are older than debounce time
        let debounce = Duration::from_secs_f64(debounce_secs);
        self.pending.values().all(|(_, seen)| seen.elapsed() >= debounce)
    }

    /// Take all pending changes
    fn take(&mut self) -> Vec<(PathBuf, bool)> {
        self.first_change = None;
        self.pending
            .drain()
            .map(|(path, (is_local, _))| (path, is_local))
            .collect()
    }

    /// Check if buffer has any pending changes
    #[allow(dead_code)]
    fn has_pending(&self) -> bool {
        !self.pending.is_empty()
    }
}

/// File system watcher for bidirectional sync
pub struct SyncWatcher {
    config: Config,
    buffer: Arc<Mutex<ChangeBuffer>>,
    tx: Sender<WatchEvent>,
    rx: Receiver<WatchEvent>,
}

/// Internal watch event
enum WatchEvent {
    FileChange { path: PathBuf, is_local: bool },
    Error(notify::Error),
}

impl SyncWatcher {
    /// Create a new sync watcher
    pub fn new(config: Config) -> Result<Self> {
        let (tx, rx) = mpsc::channel();
        let buffer = Arc::new(Mutex::new(ChangeBuffer::new()));

        Ok(Self {
            config,
            buffer,
            tx,
            rx,
        })
    }

    /// Start watching and processing changes
    pub fn run(&self) -> Result<()> {
        log::info!("Starting file system watchers...");
        log::info!("  Local:   {:?}", self.config.claude_dir);
        log::info!("  Dropbox: {:?}", self.config.dropbox_claude_dir);

        // Create sync engine
        let sync_engine = SyncEngine::new(self.config.clone());

        // Create watchers
        let local_tx = self.tx.clone();
        let dropbox_tx = self.tx.clone();

        let mut local_watcher = RecommendedWatcher::new(
            move |res: Result<Event, notify::Error>| {
                Self::handle_event(res, true, &local_tx);
            },
            NotifyConfig::default().with_poll_interval(Duration::from_secs(2)),
        )?;

        let mut dropbox_watcher = RecommendedWatcher::new(
            move |res: Result<Event, notify::Error>| {
                Self::handle_event(res, false, &dropbox_tx);
            },
            NotifyConfig::default().with_poll_interval(Duration::from_secs(2)),
        )?;

        // Start watching
        if self.config.claude_dir.exists() {
            local_watcher.watch(&self.config.claude_dir, RecursiveMode::Recursive)?;
            log::info!("Watching local directory");
        } else {
            log::warn!("Local directory does not exist yet: {:?}", self.config.claude_dir);
        }

        if self.config.dropbox_claude_dir.exists() {
            dropbox_watcher.watch(&self.config.dropbox_claude_dir, RecursiveMode::Recursive)?;
            log::info!("Watching Dropbox directory");
        } else {
            log::warn!("Dropbox directory does not exist yet: {:?}", self.config.dropbox_claude_dir);
        }

        log::info!("Watchers started. Waiting for changes...");

        // Process events
        loop {
            // Check for new events (non-blocking with timeout)
            match self.rx.recv_timeout(Duration::from_millis(100)) {
                Ok(WatchEvent::FileChange { path, is_local }) => {
                    // Skip hidden files and state files
                    if self.should_ignore(&path) {
                        continue;
                    }

                    log::debug!(
                        "Change detected: {:?} ({})",
                        path,
                        if is_local { "local" } else { "dropbox" }
                    );

                    let mut buffer = self.buffer.lock().unwrap();
                    buffer.add(path, is_local);
                }
                Ok(WatchEvent::Error(e)) => {
                    log::error!("Watch error: {}", e);
                }
                Err(mpsc::RecvTimeoutError::Timeout) => {
                    // Check if we should flush the buffer
                }
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    log::error!("Watch channel disconnected");
                    break;
                }
            }

            // Check if we should flush and sync
            let should_sync = {
                let buffer = self.buffer.lock().unwrap();
                buffer.should_flush(self.config.debounce_secs, self.config.max_batch_secs)
            };

            if should_sync {
                let changes = {
                    let mut buffer = self.buffer.lock().unwrap();
                    buffer.take()
                };

                if !changes.is_empty() {
                    log::info!("Processing {} buffered change(s)...", changes.len());

                    // Determine direction based on changes
                    let has_local = changes.iter().any(|(_, is_local)| *is_local);
                    let has_remote = changes.iter().any(|(_, is_local)| !*is_local);

                    let direction = match (has_local, has_remote) {
                        (true, false) => SyncDirection::Push,
                        (false, true) => SyncDirection::Pull,
                        _ => SyncDirection::Bidirectional,
                    };

                    // Perform sync
                    match sync_engine.sync(direction) {
                        Ok(result) => {
                            log::info!(
                                "Sync complete: {} copied, {} skipped",
                                result.copied,
                                result.skipped
                            );
                            for warning in &result.warnings {
                                log::warn!("{}", warning);
                            }
                        }
                        Err(e) => {
                            log::error!("Sync failed: {}", e);
                        }
                    }
                }
            }
        }

        Ok(())
    }

    /// Handle a file system event
    fn handle_event(
        res: Result<Event, notify::Error>,
        is_local: bool,
        tx: &Sender<WatchEvent>,
    ) {
        match res {
            Ok(event) => {
                // Only care about create, modify, remove events
                match event.kind {
                    EventKind::Create(_)
                    | EventKind::Modify(_)
                    | EventKind::Remove(_) => {
                        for path in event.paths {
                            let _ = tx.send(WatchEvent::FileChange { path, is_local });
                        }
                    }
                    _ => {}
                }
            }
            Err(e) => {
                let _ = tx.send(WatchEvent::Error(e));
            }
        }
    }

    /// Check if a path should be ignored
    fn should_ignore(&self, path: &PathBuf) -> bool {
        let file_name = path
            .file_name()
            .map(|s| s.to_string_lossy())
            .unwrap_or_default();

        // Ignore hidden files
        if file_name.starts_with('.') {
            return true;
        }

        // Ignore sync state and lock files
        if file_name == ".sync_state.json" || file_name == ".sync_lock" {
            return true;
        }

        // Ignore macOS metadata
        if file_name == ".DS_Store" || file_name.starts_with("._") {
            return true;
        }

        // Ignore Dropbox conflict files (they should be handled manually)
        if file_name.contains("conflicted copy") {
            log::warn!("Dropbox conflict detected: {:?}", path);
            return true;
        }

        // Ignore temporary files
        if file_name.ends_with(".tmp") || file_name.ends_with("~") {
            return true;
        }

        false
    }

    /// Perform a single sync pass without watching
    pub fn sync_once(&self) -> Result<()> {
        log::info!("Performing one-time sync...");

        let sync_engine = SyncEngine::new(self.config.clone());

        // Validate sources first
        let errors = sync_engine.validate_sources(SyncDirection::Bidirectional)?;
        if !errors.is_empty() {
            for error in &errors {
                log::error!("Validation error: {}", error);
            }
            anyhow::bail!("Pre-flight validation failed with {} error(s)", errors.len());
        }

        // Perform bidirectional sync
        let result = sync_engine.sync(SyncDirection::Bidirectional)?;

        log::info!(
            "Sync complete: {} copied, {} skipped",
            result.copied,
            result.skipped
        );

        if let Some(backup) = &result.backup_path {
            log::info!("Backup created: {:?}", backup);
        }

        for warning in &result.warnings {
            log::warn!("{}", warning);
        }

        Ok(())
    }
}
