# tui (Python)

Python bindings for the [`tui`](../tui) Rust crate. Spawn and control multiple
PTY-backed processes from Python with full vt100 emulation, scrollback, and
optional NumPy access to per-cell character data.

The Python API is a single class, `Tui`. Construct it, drive it, read it. A
single process-wide tokio runtime drives every spawned PTY; every blocking
I/O method has an `a`-prefixed coroutine variant that bridges a real Rust
future into asyncio via [pyo3-async-runtimes][pyo3-async-runtimes] — no
thread-pool hop.

PyPI distribution name: `ix-tui`. Import name: `tui`.

## Build

The wheel is built by Nix, not maturin. The PyO3 cdylib comes out of the shared
`cargo-unit` workspace graph (the same one the rest of the repo's Rust builds
from) and [`wheel/mkwheel.py`](wheel/mkwheel.py) packages it with the Python
source into a PEP 427 wheel. There is no PEP 517 backend; `pip install .` is not
a supported path.

```sh
nix build .#tui-py     # writes ix_tui-<version>-cp311-abi3-manylinux_2_34_<arch>.whl
```

The wheel is Linux-only, like ix's native SDK wheels: a PyO3 extension cdylib
links cleanly only where a shared object may carry undefined symbols (Linux);
macOS needs `-undefined dynamic_lookup`, which the shared cargo-unit graph does
not thread through. From a macOS checkout, build it on a Linux builder with
`nix build .#packages.x86_64-linux.tui-py`. The extension is abi3
(`pyo3/abi3-py311`), so one wheel loads on CPython 3.11+; `pip install` it from
`result/`.

## Quick start

```python
import re
from tui import Tui

with Tui("python", "-q") as tui:
    tui.enter("1 + 2")
    snap = tui.wait_for(re.compile(r"^3$", re.MULTILINE), timeout=2.0)
    print(snap.viewport[-3:])
    # ('>>> 1 + 2', '3', '>>> ')
```

`tui.snapshot()` returns a frozen `Snapshot` (viewport, scrollback, size). It
supports `str(snap)`, `"needle" in snap`, and `.text` / `.full_text`.

The terminal opens at 80x24 with 10,000 lines of scrollback. Override per
instance with keyword args:

```python
Tui("bash", "--norc", "-i", rows=40, cols=120, scrollback_lines=50_000)
```

## Examples

### Drive a REPL and read its output

```python
from tui import Tui

with Tui("python", "-q") as tui:
    tui.enter("1 + 2")
    snap = tui.wait_for("3", timeout=2.0)
    print(snap.text.splitlines()[-2:])
```

### Async: many TUIs in parallel

Every I/O method has an `a`-prefixed coroutine variant. These are real Rust
futures bridged into asyncio — no `to_thread` shim.

```python
import asyncio
from tui import Tui

async def run(cmd: str, *args: str) -> str:
    async with Tui(cmd, *args) as t:
        await t.aenter("printf READY")
        snap = await t.await_for("READY", timeout=2.0)
        return snap.text

async def main() -> None:
    out = await asyncio.gather(
        run("bash", "--norc", "-i"),
        run("bash", "--norc", "-i"),
        run("bash", "--norc", "-i"),
    )
    for text in out:
        print(text.strip().splitlines()[-1])

asyncio.run(main())
```

### Send keystrokes

`Key` is a `StrEnum` whose members are raw ANSI sequences, so they
concatenate with literal text and pass straight to `Tui.send`:

```python
from tui import Key, Tui

with Tui("less", "/etc/hosts") as t:
    t.send(Key.PAGE_DOWN, Key.PAGE_DOWN)
    t.send(Key.ctrl("g"))          # any Ctrl-letter
    t.send(Key.alt("x"))           # any Alt-letter
    t.send("q")
```

### Match with regex or a predicate

`wait_for` accepts a substring, a compiled `re.Pattern`, or a callable that
takes the current `Snapshot`:

```python
import re
from tui import Tui

with Tui("bash", "--norc", "-i") as t:
    t.enter("ls /etc | head -3")
    snap = t.wait_for(re.compile(r"\.conf$", re.MULTILINE), timeout=2.0)
    snap = t.wait_for(lambda s: len(s.viewport) >= 5, timeout=1.0)
```

### Per-cell data

`tui.chars()` returns a `numpy.uint32` array of Unicode codepoints, shape
`(rows, cols)`. `tui.styled_cells()` returns a nested list of `StyledCell`
objects (`char`, `fg`, `bg`, `bold`, `italic`, `underline`, `inverse`).

`fg` and `bg` are `Color` values: `None` for the terminal default, an `int` in
`0..=255` for a palette index, or an `(r, g, b)` tuple for truecolor.

```python
import numpy as np
from tui import Tui

with Tui("bash", "--norc", "-i") as t:
    t.enter("printf 'AAA-MARKER'")
    t.wait_for("AAA-MARKER", timeout=1.0)

    cells = t.chars()                         # NDArray[uint32], (rows, cols)
    has_a = bool(np.any(cells == ord("A")))
    styled = t.styled_cells()
    bolds = [(r, c) for r, row in enumerate(styled)
                    for c, cell in enumerate(row) if cell.bold]
    reds = [cell.char for row in styled for cell in row if cell.fg == 1]
```

### Handle timeouts

```python
from tui import Tui, WaitTimeout

with Tui("bash", "--norc", "-i") as t:
    try:
        t.wait_for("never gonna happen", timeout=0.25)
    except WaitTimeout as exc:
        print("missed it:", exc)
```

### List live instances

`Tui.list_all()` returns every `Tui` still tracked in this process — handy in
tests or REPLs:

```python
from tui import Tui
Tui("bash", "--norc", "-i")
Tui("python", "-q")
print(len(Tui.list_all()))   # 2
```

### Process lifecycle

A spawned process is more than a screen: you can wait on it, read its exit
code, and stop it for real.

```python
from tui import Tui

t = Tui("bash", "-c", "echo hi; exit 7")
code = t.wait(timeout=3)        # blocks until exit; raises WaitTimeout on deadline
print(code, t.is_alive())       # 7 False
print(t.exit_code)              # 7 (None while running or if killed by a signal)
```

`interrupt()` sends a cooperative Ctrl+C. `kill()` sends `SIGKILL`, which a
program that traps interrupts (an editor in normal mode, a stuck REPL) cannot
ignore. `close()` force-kills and drops the terminal from `list_all()` and the
dashboard; `with`/`async with` blocks call it on exit, so an editor left open
still goes away. The async twins are `akill()` and `await_exit()`.

A terminal whose child has exited keeps its final screen readable, so you can
inspect output after the fact; writing to it raises instead.

### Web dashboard

`serve()` starts a read-only web dashboard that shows a live grid of every
`Tui` in this process. The server, the [Loro][loro] CRDT document, and the
Server-Sent-Events stream all live in Rust; the browser holds its own
`loro-crdt` document and paints each terminal's viewport. Exited terminals stay
on the grid, dimmed and marked `exited`.

```python
from tui import Tui, serve

Tui("bash", "--norc", "-i")
Tui("python", "-q")

dash = serve(port=8080)        # non-blocking; returns immediately
print(dash.url)                # http://127.0.0.1:8080/
# dash.open()                  # open in the default browser
...
dash.stop()                    # or use `with serve() as dash:`
```

Pass `host="0.0.0.0"` to expose it on the network (the host must be an IP
literal), `port=0` for an ephemeral port read back from `dash.url`, and `poll`
to tune the viewport sampling interval in seconds.

[loro]: https://loro.dev/

## Public surface

| Name           | Purpose                                                |
| -------------- | ------------------------------------------------------ |
| `Tui`          | One spawned process. Construct it and you have a PTY.  |
| `Snapshot`     | Frozen viewport + scrollback + size.                   |
| `Size`         | `(rows, cols)` dataclass.                              |
| `Key`          | ANSI keystroke constants + `Key.ctrl`/`Key.alt`.       |
| `StyledCell`   | One cell: `char`, `fg`/`bg`, and VT100 attributes.     |
| `Color`        | `None` (default), `int` (palette), or `(r, g, b)`.     |
| `WaitTimeout`  | Raised by `wait_for` / `await_for` on deadline expiry. |
| `serve`        | Start the web dashboard for every live `Tui`.          |
| `Dashboard`    | Handle to a running dashboard: `url`, `open`, `stop`.   |

[pyo3-async-runtimes]: https://docs.rs/pyo3-async-runtimes/
