//! Python bindings for the `tui` PTY-backed terminal management library.
//!
//! All blocking calls release the GIL via `Python::detach`, so multiple
//! Python threads can drive the same manager concurrently. Async methods
//! return native asyncio-awaitable coroutines bridged through
//! pyo3-async-runtimes.

#![allow(
    clippy::missing_const_for_fn,
    reason = "pyo3 getter methods cannot be const because they are dispatched through the pymethod vtable"
)]

mod manager;
mod types;

use pyo3::prelude::*;

#[pymodule]
fn _tui(module: &Bound<'_, PyModule>) -> PyResult<()> {
    module.add_class::<manager::TuiInstance>()?;
    module.add_class::<types::StyledCell>()?;
    module.add("__version__", env!("CARGO_PKG_VERSION"))?;
    Ok(())
}
