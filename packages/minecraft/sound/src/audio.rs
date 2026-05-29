use std::fs::File;
use std::io::BufReader;
use std::path::Path;

use anyhow::{Context, Result};
use rodio::{Decoder, OutputStream, Sink};

/// Decode and play an OGG/Vorbis file, blocking until playback finishes.
///
/// # Errors
/// Returns an error if the audio output device cannot be opened, the file
/// cannot be read, or the stream cannot be decoded.
pub fn play_ogg(path: &Path) -> Result<()> {
    let (_stream, handle) =
        OutputStream::try_default().context("Failed to open audio output device")?;

    let file = File::open(path)
        .with_context(|| format!("Failed to open sound file: {}", path.display()))?;
    let source = Decoder::new(BufReader::new(file)).context("Failed to decode OGG file")?;

    let sink = Sink::try_new(&handle).context("Failed to create audio sink")?;
    sink.append(source);
    sink.sleep_until_end();

    Ok(())
}
