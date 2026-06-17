---
name: python-style
disclosure: progressive
description: "Python conventions: uv projects, buildUvApplication, writePythonApplication, type-checking (ty/zuban/mypy) and ruff ANN. Use when writing or packaging Python."
---

## Python style

Default repo-owned Python apps to uv: `pyproject.toml`, committed `uv.lock`,
normal `src/<package>/` files, and Nix packaging through
[`ix.buildUvApplication`](lib/build-uv-application.nix).

Use [`ix.writePythonApplication`](lib/default.nix) for tiny single-file commands
without PyPI dependencies or multiple source files. Once a script needs
dependencies, console entry points, or a package layout, give it the uv project
shape.

The Python helpers run a type checker at build time, selected with `pyChecker`,
which **defaults to `"zuban"`**: `zuban check --strict` (correctness, including
disallow-untyped-defs) plus `ruff check --select ANN` (explicit annotations). So
a new uv app or `writePythonApplication` script must be fully annotated and pass
strict checking out of the box. Set `pyChecker = "ty"` (the older gradual
checker) or `"mypy"` for a deliberate reason; disable entirely with
`check = false` only when justified.

Enforcement is per-package via the build gate. The one remaining package on a
mixed footing is `packages/mcp` (its own `strictTypecheck` gate covers the
migrated modules; the rest is tracked in ENG-3136). Once mcp is fully clean, a
whole-repo `ruff check --select ANN .` lint stage can replace per-package
enforcement with a single tree-wide gate.
