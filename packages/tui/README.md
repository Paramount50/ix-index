# tui

Spawn and drive multiple PTY-backed terminal programs from one process. Each
spawned child gets a real pseudo-terminal, so interactive programs (vim, less,
a shell, a REPL) behave as they would in a normal terminal instead of seeing a
dumb pipe.

The output of every child is fed through a [vt100] emulator, so you read back a
rendered screen (viewport, scrollback, per-cell styling) rather than a raw byte
stream full of escape sequences.

## Usage

```rust
use std::time::Duration;
use tui::{SpawnConfig, TuiManager};

let manager = TuiManager::new();

// Spawn on an 80x24 PTY with 10,000 lines of scrollback (the defaults).
let term = manager.spawn("cat".into(), vec![], SpawnConfig::default())?;

term.write("hello\n")?;

// Block until the child paints something, then read the rendered screen.
for line in term.read_blocking(Duration::from_secs(1))? {
    println!("{line}");
}

let snapshot = term.read_full()?;        // scrollback + viewport together
let cells = term.read_styled_cells()?;   // per-cell char + color + attrs
# Ok::<(), tui::Error>(())
```

Every blocking method has an `_async` twin (`write_async`, `read_viewport_async`,
…) that returns a future instead of driving the runtime itself, for callers that
already run inside tokio.

## Design

- **`TuiManager`** owns one multi-threaded tokio runtime, spawns processes, and
  tracks the live ones (`list`, `get`). It shares a clone of its runtime into
  every handle it hands out.
- **`TuiInstance`** is the handle for one child. It carries every read/write
  method and a clone of the runtime, so it keeps working for as long as you hold
  it. Cloning a handle is cheap and all clones address the same process.
- A per-child **actor task** owns the PTY master. It is the only thing that
  touches the PTY and the vt100 parser, so reads and writes from many threads
  serialize through one mailbox (`tokio::sync::mpsc`) instead of locking.

The PTY master is non-blocking and driven with async I/O; the slave handed to
the child is a real terminal device, so signals, line discipline, and terminal
sizing all work.

## Reading the screen

- `read_viewport` returns the visible screen, one `String` per row.
- `read_scrollback` returns lines that have scrolled above the viewport, oldest
  first.
- `read_full` returns both as a [`FullOutput`].
- `read_blocking(timeout)` polls the viewport until it has content or the
  timeout elapses; it errors with `NoOutputAvailable` only if nothing arrives.
- `read_chars` returns a `rows x cols` grid of `char`.
- `read_styled_cells` returns an `ndarray::Array2<StyledCell>`; each
  [`StyledCell`] carries its character, typed `fg`/`bg` [`Color`], and the bold,
  italic, underline, and inverse flags.

`slice_2d` with `RowRange`/`ColRange` extracts a rectangular sub-region of a
`Vec<String>` (1-indexed, inclusive) when you only want part of the screen.

## Configuration

Pass a [`SpawnConfig`] to set the terminal size and scrollback depth at spawn:

```rust
use tui::SpawnConfig;

let config = SpawnConfig { rows: 40, cols: 120, scrollback_lines: 50_000 };
```

Size is fixed for the life of the process; there is no runtime resize today.

## Errors

All fallible calls return `Result<T, Error>`, a `snafu`-derived enum:

- `ProcessSpawn` — the child failed to launch.
- `TuiNotFound` — the handle's actor has exited (the channel is closed).
- `WriteToTui` / `ReadFromTui` — a PTY I/O call failed.
- `NoOutputAvailable` — the screen is still empty.
- `InvalidRowRange` / `InvalidColRange` / `RowIndexOutOfBounds` /
  `ColIndexOutOfBounds` — bad arguments to `slice_2d`.
- `ArrayConversion` — building the styled-cell grid failed (carries the
  underlying `ndarray::ShapeError`).

## Known limitations

- Unix only: depends on PTY devices, so Linux and macOS, not Windows.
- No runtime resize and no force-kill. A `with`-style caller sends Ctrl+C; a
  child that ignores it keeps running until it exits on its own.

## Dependencies

[pty-process] for PTY creation, [tokio] for the async runtime, [vt100] for
terminal emulation, [ndarray] for the cell grid, `parking_lot` for the registry
lock, and `snafu` for errors.

[vt100]: https://docs.rs/vt100/
[pty-process]: https://docs.rs/pty-process/
[tokio]: https://tokio.rs/
[ndarray]: https://docs.rs/ndarray/
[`FullOutput`]: src/types.rs
[`StyledCell`]: src/types.rs
[`Color`]: src/types.rs
[`SpawnConfig`]: src/types.rs
