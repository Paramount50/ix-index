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
disallow-untyped-defs) plus `ruff check` with the shared
[`lib/build/ruff-ann.nix`](lib/build/ruff-ann.nix) selector (`ANN` explicit
annotations + `TID251` no-`typing.cast`). So a new uv app or
`writePythonApplication` script must be fully annotated and pass strict checking
out of the box. Set `pyChecker = "ty"` (the older gradual checker) or `"mypy"`
for a deliberate reason; disable entirely with `check = false` only when
justified.

Enforcement is per-package via the build gate. The one remaining package on a
mixed footing is `packages/mcp` (its own `strictTypecheck` gate covers the
migrated modules; the rest is tracked in ENG-3136). Once mcp is fully clean, a
whole-repo `ruff check --select ANN .` lint stage can replace per-package
enforcement with a single tree-wide gate.

`typing.Any` in annotations is already banned everywhere by `ruff ANN401`, and
`typing.cast` is banned by `ruff TID251`: a cast lies to the type checker at zero
runtime cost, so a wrong one is a latent bug no checker can catch. For external or
untrusted JSON (an HTTP API response, a config file, a GraphQL reply), parse it
into a [pydantic](https://docs.pydantic.dev) model at the boundary rather than
casting or threading `dict[str, Any]`/`object` through the code: the model
validates the shape once and fails with a path-precise error when upstream drifts,
and every downstream access is typed. Worked examples: `packages/update-loaders` (a
`TypeAdapter` over the PaperMC response) and the bundled `linear`/`google_auth`
modules (typed models returned from the GraphQL/CLI boundary). For an untyped
stdlib boundary that genuinely returns the type you expect (e.g. an HTTP
`response.read()` that is `bytes`), prefer an explicit local annotation
(`body: bytes = response.read()`) over a cast. The rare genuinely-unavoidable cast
— casting a test double to the interface it stands in for — opts out per file with
`# noqa: TID251` plus a one-line reason. Reserve a bare `object` annotation for
genuinely opaque values where narrowing is the caller's job
(`def __eq__(self, other: object)`, `*args: object`), and leave a comment saying
why; do not use it as a shortcut to skip modeling data you actually read.
