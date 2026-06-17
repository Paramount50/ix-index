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

The Python helpers run a type checker at build time, selected with `pyChecker`:
`"ty"` (default, the legacy gradual checker), `"zuban"`, or `"mypy"`. The
`"zuban"`/`"mypy"` options run that checker `--strict` (correctness, including
disallow-untyped-defs) plus `ruff check --select ANN` (explicit annotations).
The repo is migrating every package off `ty` onto strict checking; flip a package
to `pyChecker = "zuban"` once its sources are fully annotated and clean. Disable
the check (`check = false`) only when the package has a deliberate reason.

Explicit annotations are also enforced repo-wide by the `ruff-ann` lint stage
(`nix run .#lint`), scoped to an allowlist of migrated directories that grows
until it covers the whole tree.
