use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime};

use tokio::runtime::Runtime;
use tokio::sync::{RwLock, mpsc};
use uuid::Uuid;

use crate::actor::{PtyCommand, pty_actor};
use crate::manager::TuiInstance;
use crate::types::SpawnConfig;
use crate::{Error, Result};

const CHANNEL_BUFFER_SIZE: usize = 100;
const INITIAL_OUTPUT_TIMEOUT: Duration = Duration::from_millis(100);
const INITIAL_OUTPUT_POLL_INTERVAL: Duration = Duration::from_millis(5);

async fn has_output(parser: &Arc<RwLock<vt100::Parser>>) -> bool {
    !parser.read().await.screen().contents().is_empty()
}

/// Give the child a brief window to paint its first frame so callers that read
/// immediately after spawn see content instead of an empty screen.
fn wait_for_initial_output(runtime: &Runtime, parser: &Arc<RwLock<vt100::Parser>>) {
    let start = Instant::now();
    runtime.block_on(async {
        while !has_output(parser).await && start.elapsed() < INITIAL_OUTPUT_TIMEOUT {
            tokio::time::sleep(INITIAL_OUTPUT_POLL_INTERVAL).await;
        }
    });
}

fn process_spawn_error(command: &str, error: impl Into<Box<dyn std::error::Error + Send + Sync>>) -> Error {
    Error::ProcessSpawn {
        command: command.to_string(),
        source: std::io::Error::other(error),
    }
}

pub(super) fn spawn_tui(
    runtime: &Arc<Runtime>,
    command: String,
    args: Vec<String>,
    config: SpawnConfig,
) -> Result<TuiInstance> {
    let id = Uuid::new_v4();
    let SpawnConfig {
        rows,
        cols,
        scrollback_lines,
    } = config;
    let display = format!("{command} {}", args.join(" "));

    let (pty, child) = runtime.block_on(async {
        let pty = pty_process::Pty::new().map_err(|e| process_spawn_error(&display, e))?;

        let pty_slave = pty.pts().map_err(|e| process_spawn_error("get PTY slave", e))?;

        pty.resize(pty_process::Size::new(rows, cols))
            .map_err(|e| process_spawn_error("resize PTY", e))?;

        let mut cmd = pty_process::Command::new(&command);
        cmd.args(&args);

        let child = cmd
            .spawn(&pty_slave)
            .map_err(|e| process_spawn_error(&display, e))?;

        Ok::<_, Error>((pty, child))
    })?;

    let parser = Arc::new(RwLock::new(vt100::Parser::new(rows, cols, scrollback_lines)));

    let (command_tx, command_rx) = mpsc::channel::<PtyCommand>(CHANNEL_BUFFER_SIZE);

    let actor_parser = Arc::clone(&parser);
    runtime.spawn(async move {
        pty_actor(id, pty, command_rx, actor_parser).await;
    });

    // Own the child entirely in a reaper task. Calling wait() drives the
    // SIGCHLD reap so short-lived commands (echo, seq, ...) do not leave
    // zombies even though we never expose a kill path on TuiInstance.
    runtime.spawn(async move {
        let mut child = child;
        let _ = child.wait().await;
    });

    let instance = TuiInstance {
        id,
        command,
        args,
        spawned_at: SystemTime::now(),
        rows,
        cols,
        scrollback_limit: scrollback_lines,
        command_tx,
        runtime: Arc::clone(runtime),
    };

    wait_for_initial_output(runtime, &parser);

    Ok(instance)
}
