//! Configuration loading for claude-sync-watch

use anyhow::{Context, Result};
use std::fs;
use std::path::PathBuf;

/// Conflict resolution strategy
#[derive(Debug, Clone, Copy, Default)]
pub enum ConflictStrategy {
    /// Use the newest file (by mtime)
    #[default]
    Newest,
    /// Prefer local over remote
    Local,
    /// Prefer remote over local
    Remote,
}

/// Configuration for the sync daemon
#[derive(Debug, Clone)]
pub struct Config {
    /// Base Dropbox directory (e.g., ~/Dropbox)
    pub dropbox_base: PathBuf,
    /// Claude sync directory in Dropbox (e.g., ~/Dropbox/ClaudeCodeSync)
    pub dropbox_claude_dir: PathBuf,
    /// Local Claude config directory (~/.claude)
    pub claude_dir: PathBuf,
    /// Debounce time in seconds before triggering sync
    pub debounce_secs: f64,
    /// Maximum batch time in seconds
    pub max_batch_secs: f64,
    /// Conflict resolution strategy
    pub conflict_strategy: ConflictStrategy,
    /// Log level (reserved for future use)
    #[allow(dead_code)]
    pub log_level: log::Level,
    /// Files to sync
    pub sync_files: Vec<String>,
    /// Directories to sync
    pub sync_dirs: Vec<String>,
}

impl Config {
    /// Load configuration from ~/.claude_sync_config
    pub fn load() -> Result<Self> {
        let home = dirs::home_dir().context("Could not determine home directory")?;
        let config_path = home.join(".claude_sync_config");

        let mut dropbox_base: Option<PathBuf> = None;
        let mut debounce_secs = 3.0;
        let mut max_batch_secs = 10.0;
        let mut conflict_strategy = ConflictStrategy::Newest;
        let mut log_level = log::Level::Info;

        // Parse bash-style KEY="value" config file
        if config_path.exists() {
            let content = fs::read_to_string(&config_path)
                .with_context(|| format!("Failed to read config file: {:?}", config_path))?;

            for line in content.lines() {
                let line = line.trim();
                if line.is_empty() || line.starts_with('#') {
                    continue;
                }

                if let Some((key, value)) = line.split_once('=') {
                    let key = key.trim();
                    // Remove surrounding quotes
                    let value = value.trim().trim_matches('"').trim_matches('\'');

                    match key {
                        "DROPBOX_BASE" => {
                            let expanded = shellexpand::tilde(value);
                            dropbox_base = Some(PathBuf::from(expanded.as_ref()));
                        }
                        "DEBOUNCE_SECS" => {
                            if let Ok(v) = value.parse() {
                                debounce_secs = v;
                            }
                        }
                        "MAX_BATCH_SECS" => {
                            if let Ok(v) = value.parse() {
                                max_batch_secs = v;
                            }
                        }
                        "CONFLICT_STRATEGY" => match value.to_lowercase().as_str() {
                            "local" => conflict_strategy = ConflictStrategy::Local,
                            "remote" => conflict_strategy = ConflictStrategy::Remote,
                            _ => conflict_strategy = ConflictStrategy::Newest,
                        },
                        "LOG_LEVEL" => match value.to_lowercase().as_str() {
                            "debug" => log_level = log::Level::Debug,
                            "warn" => log_level = log::Level::Warn,
                            "error" => log_level = log::Level::Error,
                            _ => log_level = log::Level::Info,
                        },
                        _ => {}
                    }
                }
            }
        }

        // Try to detect Dropbox location if not configured
        let dropbox_base = dropbox_base.or_else(|| {
            let candidates = [
                home.join("Dropbox"),
                home.join("Library/CloudStorage/Dropbox"),
                PathBuf::from("/Users/Shared/Dropbox"),
            ];
            candidates.into_iter().find(|p| p.exists())
        });

        let dropbox_base =
            dropbox_base.context("Dropbox location not configured. Run claude-sync-setup.sh --config first.")?;

        if !dropbox_base.exists() {
            anyhow::bail!("Dropbox directory does not exist: {:?}", dropbox_base);
        }

        let dropbox_claude_dir = dropbox_base.join("ClaudeCodeSync");
        let claude_dir = home.join(".claude");

        Ok(Config {
            dropbox_base,
            dropbox_claude_dir,
            claude_dir,
            debounce_secs,
            max_batch_secs,
            conflict_strategy,
            log_level,
            sync_files: vec![
                "settings.json".to_string(),
                "mcp.json".to_string(),
                "CLAUDE.md".to_string(),
            ],
            sync_dirs: vec!["skills".to_string(), "plugins".to_string()],
        })
    }

    /// Get the machine ID (hostname)
    pub fn machine_id() -> String {
        hostname::get()
            .map(|h| h.to_string_lossy().to_string())
            .unwrap_or_else(|_| "unknown".to_string())
    }
}

// Simple tilde expansion since we don't want to add another dependency
mod shellexpand {
    use std::borrow::Cow;

    pub fn tilde(path: &str) -> Cow<'_, str> {
        if path.starts_with('~') {
            if let Some(home) = dirs::home_dir() {
                let rest = path.strip_prefix('~').unwrap_or("");
                let rest = rest.strip_prefix('/').unwrap_or(rest);
                return Cow::Owned(home.join(rest).to_string_lossy().to_string());
            }
        }
        Cow::Borrowed(path)
    }
}
