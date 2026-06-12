//! Python bindings for `astlog-core`.
//!
//! Three thin sync entry points over [`astlog_core::analyze`]: [`query`]
//! returns derived relations as plain dicts, [`fixes`] returns the planned
//! edits, and [`fix`] returns the unified diff (optionally writing files).
//! All language, evaluation, and rewrite logic lives in the core crate; this
//! module only converts at the boundary.

use std::path::PathBuf;

use astlog_core::{Analysis, Value};
use pyo3::exceptions::PyValueError;
use pyo3::prelude::*;
use pyo3::types::{PyDict, PyList};

fn to_py_err(error: &astlog_core::Error) -> PyErr {
    let mut message = error.to_string();
    let mut source = std::error::Error::source(error);
    while let Some(cause) = source {
        message.push_str(": ");
        message.push_str(&cause.to_string());
        source = cause.source();
    }
    PyValueError::new_err(message)
}

fn run(rules: &str, paths: &[PathBuf]) -> PyResult<Analysis> {
    astlog_core::analyze(rules, paths).map_err(|error| to_py_err(&error))
}

fn value_to_py<'py>(
    py: Python<'py>,
    analysis: &Analysis,
    value: &Value,
) -> PyResult<Bound<'py, PyAny>> {
    match value {
        Value::Text(text) => Ok(text.to_string().into_pyobject(py)?.into_any()),
        Value::Node(node) => {
            let info = analysis.corpus.node_info(*node);
            let at = analysis.corpus.position(node.file, info.start);
            let dict = PyDict::new(py);
            dict.set_item("path", &analysis.corpus.files[node.file].path)?;
            dict.set_item("kind", info.kind)?;
            dict.set_item("start", info.start)?;
            dict.set_item("end", info.end)?;
            dict.set_item("line", at.line)?;
            dict.set_item("column", at.column)?;
            dict.set_item("text", analysis.corpus.node_text(*node))?;
            Ok(dict.into_any())
        }
    }
}

/// Evaluate a rules program and return `{relation: [{column: value}]}`.
///
/// A node value is a dict with `path`, `kind`, `start`, `end`, `line`,
/// `column`, and `text`; a derived text value is a plain `str`. Pass
/// `relation` to keep just one relation in the result.
#[pyfunction]
#[pyo3(signature = (rules, paths, relation = None))]
#[expect(
    clippy::needless_pass_by_value,
    reason = "PyO3 extracts arguments into owned values; the by-value Vec is the FFI boundary"
)]
fn query<'py>(
    py: Python<'py>,
    rules: &str,
    paths: Vec<PathBuf>,
    relation: Option<&str>,
) -> PyResult<Bound<'py, PyDict>> {
    let analysis = run(rules, &paths)?;
    let out = PyDict::new(py);
    for (name, rel) in &analysis.database.relations {
        if relation.is_some_and(|wanted| wanted != name) {
            continue;
        }
        let rows = PyList::empty(py);
        for row in rel.rows() {
            let cells = PyDict::new(py);
            for (column, value) in rel.columns.iter().zip(row) {
                cells.set_item(column, value_to_py(py, &analysis, value)?)?;
            }
            rows.append(cells)?;
        }
        out.set_item(name, rows)?;
    }
    if let Some(wanted) = relation
        && !out.contains(wanted)?
    {
        let available: Vec<&String> = analysis.database.relations.keys().collect();
        return Err(PyValueError::new_err(format!(
            "relation `{wanted}` is not defined; available: {available:?}"
        )));
    }
    Ok(out)
}

/// Evaluate a rules program and return the planned edits as
/// `[{path, start, end, replacement}]` without touching any file.
#[pyfunction]
#[expect(
    clippy::needless_pass_by_value,
    reason = "PyO3 extracts arguments into owned values; the by-value Vec is the FFI boundary"
)]
fn fixes<'py>(py: Python<'py>, rules: &str, paths: Vec<PathBuf>) -> PyResult<Bound<'py, PyList>> {
    let analysis = run(rules, &paths)?;
    let out = PyList::empty(py);
    for edit in &analysis.edits {
        let dict = PyDict::new(py);
        dict.set_item("path", &analysis.corpus.files[edit.file].path)?;
        dict.set_item("start", edit.start)?;
        dict.set_item("end", edit.end)?;
        dict.set_item("replacement", &edit.replacement)?;
        out.append(dict)?;
    }
    Ok(out)
}

/// Evaluate a rules program and return the unified diff of every rewrite.
///
/// With `write=True` the rewritten files are also saved to disk.
#[pyfunction]
#[pyo3(signature = (rules, paths, write = false))]
#[expect(
    clippy::needless_pass_by_value,
    reason = "PyO3 extracts arguments into owned values; the by-value Vec is the FFI boundary"
)]
fn fix(rules: &str, paths: Vec<PathBuf>, write: bool) -> PyResult<String> {
    let analysis = run(rules, &paths)?;
    let diff = analysis.diff();
    if write {
        for fixed in analysis.rewritten() {
            std::fs::write(&fixed.path, &fixed.content).map_err(|error| {
                PyValueError::new_err(format!("write {}: {error}", fixed.path.display()))
            })?;
        }
    }
    Ok(diff)
}

#[pymodule]
fn _astlog(module: &Bound<'_, PyModule>) -> PyResult<()> {
    module.add_function(wrap_pyfunction!(query, module)?)?;
    module.add_function(wrap_pyfunction!(fixes, module)?)?;
    module.add_function(wrap_pyfunction!(fix, module)?)?;
    module.add("__version__", env!("CARGO_PKG_VERSION"))?;
    Ok(())
}
