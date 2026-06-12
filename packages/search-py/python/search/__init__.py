"""Async read-only search over the shared Mixedbread corpus store.

Three query verbs run over the same store the ``indexer`` populates (code plus
agent/shell history across the fleet):

* ``semantic(query)`` runs a natural-language semantic search.
* ``grep(pattern)`` runs a regular expression over the same chunks.
* ``recent()`` lists the newest records (descending timestamp), no semantic
  scoring -- a deterministic "what happened lately" feed.

None of them indexes: this is a pure query surface, so importing ``search``
never uploads the local checkout. Scope a query server-side with any of
``source``, ``not_source``, ``repo``, ``user``, ``host``, ``project``, and a
time window ``since``/``until`` (epoch seconds or relative spans like
``"24h"``/``"7d"``); with no selector the whole corpus is searched.

    hits = await search.semantic("where is retry backoff configured")
    for hit in hits:
        print(hit["path"], hit["score"], hit.get("timestamp"))

    # only Claude history, only my records, last two weeks, token-frugal
    hits = await search.semantic(
        "deploy steps", source=["claude_history"], user=["andrew"],
        since="2w", compact=True,
    )

    # my shell commands of the last six hours, newest first
    rows = await search.recent(source=["shell"], user=["andrew"], since="6h")

    hits = await search.grep(r"fn \\w+\\(", source=["code"], repo="indexable-inc/index")

Each awaitable is a native asyncio coroutine bridged from Rust via
pyo3-async-runtimes, so ``await`` it on your own event loop. Each hit is a dict
with keys ``path``, ``score``, ``start_line``, ``num_lines``, ``text``, and
``source``, plus provenance keys when the record carries them: ``timestamp``
(epoch seconds), ``user``, ``host``, ``session_id``, ``external_id``, ``url``,
``repo``, ``project``. Valid sources: ``claude_history``, ``codex``, ``shell``,
``claude_debug``, ``git``, ``github``, ``slack``, ``linear``, ``code``,
``web`` -- an unknown source raises ``ValueError`` instead of silently
returning zero hits.

``compact=True`` collapses repeated chunks of one document and caps snippets
at 400 chars (a default ``top_k=10`` full response measured ~20k tokens).
``agentic`` defaults to ``False`` everywhere: it costs 10-23s and ~5x the
per-query price, and may return fewer than ``top_k`` hits.

Authentication mirrors the ``search`` CLI: ``MXBAI_API_KEY``, or the token
written by ``mgrep login``.
"""

from __future__ import annotations

from ._search import __version__, grep, recent, semantic

__all__ = ["__version__", "grep", "recent", "semantic"]
