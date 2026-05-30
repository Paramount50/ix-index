"""Async semantic code search over a content-addressed Mixedbread index.

`search(query, path)` indexes the checkout at `path` (uploading only new file
content, deduplicated across worktrees) and returns the hits scoped to it. The
whole indexing and search pipeline lives in the Rust `semantic-search-core`
crate; this package is a thin PyO3 binding over it.

    hits = await semantic_search.search("where is retry backoff configured", ".")
    for hit in hits:
        print(hit["path"], hit["score"])

The awaitable is a native asyncio coroutine bridged from Rust via
pyo3-async-runtimes, so `await` it on your own event loop. Each hit is a dict
with keys `path`, `score`, `start_line`, `num_lines`, `text`, and `is_web`.
Authentication mirrors the `semantic-search` CLI: `MXBAI_API_KEY`, or the token
written by `mgrep login`.
"""

from __future__ import annotations

from ._semantic_search import __version__, search

__all__ = ["__version__", "search"]
