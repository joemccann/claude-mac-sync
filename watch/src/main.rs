//! claude-sync-watch - Two-way file watching sync daemon for Claude Code configuration
//!
//! Usage:
//!   claude-sync-watch              # Run daemon in foreground
//!   claude-sync-watch --daemon     # Daemonize (for launchd)
//!   claude-sync-watch --once       # Single sync pass (no watch)
//!   claude-sync-watch --status     # Show sync status

mod config;
mod lock;
mod state;
mod sync;
mod watcher;

use anyhow::Result;
use clap::Parser;
use config::Config;
use sync::SyncEngine;
use watcher::SyncWatcher;

/// Two-way file watching sync daemon for Claude Code configuration
#[derive(Parser, Debug)]
#[command(name = "claude-sync-watch")]
#[command(version = "0.1.0")]
#[command(about = "Bidirectional sync daemon for Claude Code config via Dropbox")]
struct Args {
    /// Run as a daemon (for launchd integration)
    #[arg(long)]
    daemon: bool,

    /// Perform a single sync pass without watching
    #[arg(long)]
    once: bool,

    /// Show sync status and exit
    #[arg(long)]
    status: bool,

    /// Validate configuration and exit
    #[arg(long)]
    validate: bool,

    /// Set log level (debug, info, warn, error)
    #[arg(long, default_value = "info")]
    log_level: String,
}

fn main() -> Result<()> {
    let args = Args::parse();

    // Initialize logging
    let log_level = match args.log_level.to_lowercase().as_str() {
        "debug" => log::LevelFilter::Debug,
        "warn" => log::LevelFilter::Warn,
        "error" => log::LevelFilter::Error,
        _ => log::LevelFilter::Info,
    };

    env_logger::Builder::new()
        .filter_level(log_level)
        .format_timestamp_secs()
        .init();

    // Load configuration
    let config = match Config::load() {
        Ok(c) => c,
        Err(e) => {
            log::error!("Failed to load configuration: {}", e);
            log::error!("Run claude-sync-setup.sh --config to configure Dropbox location");
            std::process::exit(1);
        }
    };

    log::info!("Claude Sync Watch v0.1.0");
    log::info!("Machine ID: {}", Config::machine_id());
    log::debug!("Local:   {:?}", config.claude_dir);
    log::debug!("Dropbox: {:?}", config.dropbox_claude_dir);

    // Handle commands
    if args.validate {
        return validate_config(&config);
    }

    if args.status {
        return show_status(&config);
    }

    if args.once {
        let watcher = SyncWatcher::new(config)?;
        return watcher.sync_once();
    }

    // Run watcher (foreground or daemon mode)
    if args.daemon {
        log::info!("Running in daemon mode");
    }

    let watcher = SyncWatcher::new(config)?;
    watcher.run()
}

/// Validate configuration
fn validate_config(config: &Config) -> Result<()> {
    println!("Configuration:");
    println!("  Dropbox base: {:?}", config.dropbox_base);
    println!("  Dropbox sync: {:?}", config.dropbox_claude_dir);
    println!("  Local config: {:?}", config.claude_dir);
    println!("  Debounce:     {:.1}s", config.debounce_secs);
    println!("  Max batch:    {:.1}s", config.max_batch_secs);
    println!("  Conflict:     {:?}", config.conflict_strategy);
    println!();

    // Check directories
    let mut ok = true;

    if config.dropbox_base.exists() {
        println!("  [OK] Dropbox base exists");
    } else {
        println!("  [ERROR] Dropbox base does not exist");
        ok = false;
    }

    if config.dropbox_claude_dir.exists() {
        println!("  [OK] Dropbox sync directory exists");
    } else {
        println!("  [WARN] Dropbox sync directory does not exist (will be created on first push)");
    }

    if config.claude_dir.exists() {
        println!("  [OK] Local config directory exists");
    } else {
        println!("  [WARN] Local config directory does not exist");
    }

    // Check for lock
    let sync_engine = SyncEngine::new(config.clone());
    if sync_engine.is_locked() {
        if let Some((machine, age)) = sync_engine.lock_info() {
            println!();
            println!("  [WARN] Sync is locked by {} ({} seconds ago)", machine, age);
        }
    }

    if ok {
        println!();
        println!("Configuration is valid.");
        Ok(())
    } else {
        anyhow::bail!("Configuration has errors");
    }
}

/// Show sync status
fn show_status(config: &Config) -> Result<()> {
    println!("Claude Sync Status");
    println!("==================");
    println!();
    println!("Machine: {}", Config::machine_id());
    println!("Local:   {:?}", config.claude_dir);
    println!("Dropbox: {:?}", config.dropbox_claude_dir);
    println!();

    // Load state
    let state_path = config.dropbox_claude_dir.join(".sync_state.json");
    if state_path.exists() {
        match state::SyncState::load(&state_path) {
            Ok(state) => {
                println!("Last sync: {} by {}", state.last_sync, state.machine_id);
                println!("Tracked files: {}", state.files.len());
            }
            Err(e) => {
                println!("Could not load sync state: {}", e);
            }
        }
    } else {
        println!("No sync state found (never synced)");
    }

    println!();

    // Check lock
    let sync_engine = SyncEngine::new(config.clone());
    if sync_engine.is_locked() {
        if let Some((machine, age)) = sync_engine.lock_info() {
            println!("[LOCKED] by {} ({} seconds ago)", machine, age);
        }
    } else {
        println!("[UNLOCKED] Ready to sync");
    }

    println!();

    // Check for differences
    let changes = state::detect_changes(
        &config.claude_dir,
        &config.dropbox_claude_dir,
        &config.sync_files,
        &config.sync_dirs,
        &state::SyncState::default(),
    );

    if changes.is_empty() {
        println!("No changes detected - files are in sync");
    } else {
        println!("Detected {} change(s):", changes.len());
        for change in &changes {
            let arrow = if change.src.starts_with(&config.claude_dir) {
                "->"
            } else {
                "<-"
            };
            println!(
                "  {:?} {} ({:?})",
                change.change_type, change.rel_path, arrow
            );
        }
    }

    // Check for Dropbox conflicts
    if config.dropbox_claude_dir.exists() {
        let conflicts = find_conflicts(&config.dropbox_claude_dir);
        if !conflicts.is_empty() {
            println!();
            println!("Dropbox Conflicts Detected:");
            for conflict in &conflicts {
                println!("  ! {:?}", conflict);
            }
        }
    }

    Ok(())
}

/// Find Dropbox conflict files
fn find_conflicts(dir: &std::path::Path) -> Vec<std::path::PathBuf> {
    let mut conflicts = Vec::new();

    if let Ok(entries) = std::fs::read_dir(dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            let name = entry.file_name().to_string_lossy().to_string();

            if name.contains("conflicted copy") {
                conflicts.push(path.clone());
            }

            if path.is_dir() {
                conflicts.extend(find_conflicts(&path));
            }
        }
    }

    conflicts
}
