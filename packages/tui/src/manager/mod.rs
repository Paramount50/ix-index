mod reader;
mod spawn;

use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, SystemTime};

use ndarray::Array2;
use parking_lot::RwLock;
use tokio::runtime::Runtime;
use tokio::sync::mpsc;
use uuid::Uuid;

use crate::actor::PtyCommand;
use crate::types::{FullOutput, SpawnConfig, StyledCell};
use crate::{Error, Result};

/// A handle to one spawned PTY-backed process.
///
/// The handle owns everything it needs to talk to its process: the actor
/// channel and a clone of the manager's runtime. Blocking methods drive that
/// runtime to completion; each has an `_async` twin that returns a future
/// instead. Cloning a handle is cheap and every clone addresses the same
/// process.
#[derive(Clone)]
pub struct TuiInstance {
    /// Stable identifier assigned at spawn.
    pub id: Uuid,
    /// The command that was spawned.
    pub command: String,
    /// Positional arguments passed to the command.
    pub args: Vec<String>,
    /// When the process was spawned.
    pub spawned_at: SystemTime,
    /// Terminal height in rows.
    pub rows: u16,
    /// Terminal width in columns.
    pub cols: u16,
    /// Configured scrollback depth.
    pub scrollback_limit: usize,
    pub(crate) command_tx: mpsc::Sender<PtyCommand>,
    pub(crate) runtime: Arc<Runtime>,
}

impl TuiInstance {
    /// Send `data` to the PTY exactly as given.
    pub fn write(&self, data: &str) -> Result<()> {
        self.runtime
            .block_on(reader::write(self.id, &self.command_tx, data.as_bytes().to_vec()))
    }

    /// The current viewport as one string per visible row.
    pub fn read_viewport(&self) -> Result<Vec<String>> {
        self.runtime
            .block_on(reader::read_viewport(self.id, &self.command_tx))
    }

    /// Lines that have scrolled above the viewport, oldest first.
    pub fn read_scrollback(&self) -> Result<Vec<String>> {
        self.runtime
            .block_on(reader::read_scrollback(self.id, &self.command_tx))
    }

    /// Scrollback and viewport read together.
    pub fn read_full(&self) -> Result<FullOutput> {
        self.runtime
            .block_on(reader::read_full(self.id, &self.command_tx))
    }

    /// Read the viewport, retrying until output appears or `timeout` elapses.
    pub fn read_blocking(&self, timeout: Duration) -> Result<Vec<String>> {
        self.runtime
            .block_on(reader::read_blocking(self.id, &self.command_tx, timeout))
    }

    /// Viewport characters as a `rows x cols` grid.
    pub fn read_chars(&self) -> Result<Vec<Vec<char>>> {
        self.runtime
            .block_on(reader::read_chars(self.id, &self.command_tx))
    }

    /// Per-cell character and styling for the whole viewport.
    pub fn read_styled_cells(&self) -> Result<Array2<StyledCell>> {
        self.runtime
            .block_on(reader::read_styled_cells(self.id, &self.command_tx))
    }

    /// [`TuiInstance::write`] as a future.
    pub async fn write_async(&self, data: &str) -> Result<()> {
        reader::write(self.id, &self.command_tx, data.as_bytes().to_vec()).await
    }

    /// [`TuiInstance::read_viewport`] as a future.
    pub async fn read_viewport_async(&self) -> Result<Vec<String>> {
        reader::read_viewport(self.id, &self.command_tx).await
    }

    /// [`TuiInstance::read_scrollback`] as a future.
    pub async fn read_scrollback_async(&self) -> Result<Vec<String>> {
        reader::read_scrollback(self.id, &self.command_tx).await
    }

    /// [`TuiInstance::read_full`] as a future.
    pub async fn read_full_async(&self) -> Result<FullOutput> {
        reader::read_full(self.id, &self.command_tx).await
    }

    /// [`TuiInstance::read_blocking`] as a future.
    pub async fn read_blocking_async(&self, timeout: Duration) -> Result<Vec<String>> {
        reader::read_blocking(self.id, &self.command_tx, timeout).await
    }

    /// [`TuiInstance::read_chars`] as a future.
    pub async fn read_chars_async(&self) -> Result<Vec<Vec<char>>> {
        reader::read_chars(self.id, &self.command_tx).await
    }

    /// [`TuiInstance::read_styled_cells`] as a future.
    pub async fn read_styled_cells_async(&self) -> Result<Array2<StyledCell>> {
        reader::read_styled_cells(self.id, &self.command_tx).await
    }
}

/// Spawns PTY-backed processes and tracks the live ones.
///
/// The manager owns the tokio runtime that drives every spawned actor and
/// shares a clone of it into each [`TuiInstance`], so a handle keeps working
/// for as long as it is held.
pub struct TuiManager {
    instances: Arc<RwLock<HashMap<Uuid, TuiInstance>>>,
    runtime: Arc<Runtime>,
}

impl Default for TuiManager {
    fn default() -> Self {
        Self::new()
    }
}

impl TuiManager {
    /// Create a manager with a fresh multi-threaded tokio runtime.
    ///
    /// # Panics
    /// Panics if the tokio runtime cannot be created.
    #[must_use]
    pub fn new() -> Self {
        let runtime = Runtime::new()
            .unwrap_or_else(|e| panic!("failed to create tokio runtime for TUI manager: {e}"));

        Self {
            instances: Arc::new(RwLock::new(HashMap::new())),
            runtime: Arc::new(runtime),
        }
    }

    /// Spawn `command` with `args` on a fresh PTY sized per `config`.
    pub fn spawn(
        &self,
        command: String,
        args: Vec<String>,
        config: SpawnConfig,
    ) -> Result<TuiInstance> {
        let instance = spawn::spawn_tui(&self.runtime, command, args, config)?;
        self.instances.write().insert(instance.id, instance.clone());
        Ok(instance)
    }

    /// Every instance the manager currently tracks.
    #[must_use]
    pub fn list(&self) -> Vec<TuiInstance> {
        self.instances.read().values().cloned().collect()
    }

    /// Look up a tracked instance by id.
    pub fn get(&self, id: &Uuid) -> Result<TuiInstance> {
        self.instances
            .read()
            .get(id)
            .cloned()
            .ok_or(Error::TuiNotFound { id: *id })
    }
}
