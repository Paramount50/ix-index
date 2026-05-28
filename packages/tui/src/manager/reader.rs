//! Low-level request helpers: issue one [`PtyCommand`] and await its reply.
//!
//! Every read and write is the same handshake: build a command carrying a
//! fresh oneshot sender, push it onto the actor channel, and await the
//! response. [`request`] captures that handshake once; the public helpers just
//! name the command they send.

use std::time::Duration;

use ndarray::Array2;
use tokio::sync::{mpsc, oneshot};
use uuid::Uuid;

use crate::actor::PtyCommand;
use crate::types::{FullOutput, StyledCell};
use crate::{Error, Result};

const POLL_INTERVAL: Duration = Duration::from_millis(50);

/// Send the command built by `build` and await its reply. A closed channel
/// (the actor has exited) surfaces as [`Error::TuiNotFound`].
async fn request<T>(
    id: Uuid,
    command_tx: &mpsc::Sender<PtyCommand>,
    build: impl FnOnce(oneshot::Sender<Result<T>>) -> PtyCommand,
) -> Result<T> {
    let (response_tx, response_rx) = oneshot::channel();
    command_tx
        .send(build(response_tx))
        .await
        .map_err(|_| Error::TuiNotFound { id })?;
    response_rx.await.map_err(|_| Error::TuiNotFound { id })?
}

pub(super) async fn write(
    id: Uuid,
    command_tx: &mpsc::Sender<PtyCommand>,
    data: Vec<u8>,
) -> Result<()> {
    request(id, command_tx, |response| PtyCommand::Write { data, response }).await
}

pub(super) async fn read_viewport(
    id: Uuid,
    command_tx: &mpsc::Sender<PtyCommand>,
) -> Result<Vec<String>> {
    request(id, command_tx, |response| PtyCommand::ReadViewport { response }).await
}

pub(super) async fn read_scrollback(
    id: Uuid,
    command_tx: &mpsc::Sender<PtyCommand>,
) -> Result<Vec<String>> {
    request(id, command_tx, |response| PtyCommand::ReadScrollback { response }).await
}

pub(super) async fn read_chars(
    id: Uuid,
    command_tx: &mpsc::Sender<PtyCommand>,
) -> Result<Vec<Vec<char>>> {
    request(id, command_tx, |response| PtyCommand::ReadChars { response }).await
}

pub(super) async fn read_styled_cells(
    id: Uuid,
    command_tx: &mpsc::Sender<PtyCommand>,
) -> Result<Array2<StyledCell>> {
    request(id, command_tx, |response| PtyCommand::ReadStyledCells { response }).await
}

pub(super) async fn read_full(
    id: Uuid,
    command_tx: &mpsc::Sender<PtyCommand>,
) -> Result<FullOutput> {
    let scrollback = read_scrollback(id, command_tx).await?;
    let viewport = read_viewport(id, command_tx).await?;
    Ok(FullOutput {
        scrollback,
        viewport,
    })
}

pub(super) async fn read_blocking(
    id: Uuid,
    command_tx: &mpsc::Sender<PtyCommand>,
    timeout: Duration,
) -> Result<Vec<String>> {
    let deadline = tokio::time::Instant::now() + timeout;

    loop {
        match read_viewport(id, command_tx).await {
            Ok(lines) => return Ok(lines),
            Err(Error::NoOutputAvailable { .. }) if tokio::time::Instant::now() < deadline => {
                tokio::time::sleep(POLL_INTERVAL).await;
            }
            Err(err) => return Err(err),
        }
    }
}
