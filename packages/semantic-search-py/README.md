# semantic-search-py

PyO3 bindings for [`semantic-search-core`](../semantic-search-core), the
content-addressed semantic code search engine. Imported as `semantic_search`.

All indexing, dedup, and search logic lives in the Rust core crate; this package
is a thin binding that exposes one async entry point and converts results at the
boundary.

```python
import semantic_search

hits = await semantic_search.search("where is retry backoff configured", ".")
for hit in hits:
    print(hit["path"], hit["score"])
```

`search` indexes the checkout at `path` (uploading only new file content,
deduplicated across worktrees), then returns the hits scoped to that checkout.
It returns a native asyncio coroutine, so `await` it on your own event loop.

## `search(query, path, ...)`

Keyword arguments mirror the `semantic-search` CLI:

- `top_k` (default `10`): maximum results.
- `store`: store name (default `semantic-search`).
- `base_url`: Mixedbread API base URL (default the client's built-in).
- `no_sync` (default `False`): skip indexing and search the store as-is.
- `rerank` (default `True`): apply the second-stage reranker.
- `web` (default `False`): mix in web results.

Each hit is a dict with `path`, `score`, `start_line`, `num_lines`, `text`, and
`is_web`. Authentication mirrors the CLI: `MXBAI_API_KEY`, or the token written
by `mgrep login`.

## Distribution

Built by Nix, not a PEP 517 backend. `nix build .#semantic-search-py` compiles
the cdylib through the shared cargo-unit workspace graph and packages it as the
`ix-semantic-search` wheel (Linux-only manylinux tags).

It is also bundled into the [`ix-mcp`](../mcp) interpreter straight from the
workspace graph, so every MCP Python session can `import semantic_search` with
no install step on both Linux and macOS.
