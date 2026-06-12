# distiller

Distill **ReasoningBank-style lessons** from local Claude Code transcripts
into (a) human-readable facts markdown per `(user, project)` and (b) a
`source=distilled_facts` **corpus parquet slice** that the existing
archive → Iceberg-lake → Mixedbread funnel publishes automatically — the
leader fold ingests `(host, user, source)` slices generically, so this needs
zero Rust (see `packages/sink/parquet` and ix `docs/history-archive.md`).

## What it does

1. Reads `~/.claude/projects/**/*.jsonl` for one user over a `--days` window,
   groups sessions by project (`cwd`), and extracts signals: the goal (first
   user message), user corrections, tool errors (`is_error` tool_results),
   success markers ("Pushed to main", tests passing), and the final assistant
   message.
2. Distills via headless `claude -p` (default model
   `claude-haiku-4-5-20251001`): strategy-level, itemized lessons from
   successes **and** failures (guardrails), each one self-contained with
   title, ≤120-word body, scope (`user:<name>` or `shared`), outcome label,
   and provenance (session ids, repo, date range).
3. Merges **incrementally** with the previous run's items: stable item ids,
   `add`/`update` operations only, unmentioned items survive verbatim —
   never wholesale regeneration (ACE's brevity-bias / context-collapse
   warning). State lives under `<out>/state/<user>/<project>.json`.
4. Writes `<out>/facts/<user>/<project>.md` and the parquet slice at
   `<out>/corpus/host=<h>/user=<u>/source=distilled_facts/` with the exact
   9-column contract (`external_id, source, content_hash, title, url, host,
   timestamp, body, meta_json`) + `_manifest.json` sorted-pairs sha256,
   then validates the slice by re-reading it with polars (schema, dtypes,
   per-row `sha256:<hex>` body hashes, manifest hash, metadata limits).
5. `--upload` puts the slice into the fleet MinIO archive
   (`http://127.0.0.1:9010`, bucket `ix-history`, prefix `corpus`); the
   leader's hourly fold + view reconcile then make the facts searchable
   (`search.semantic(..., source=["distilled_facts"])`).

## Usage

```sh
ix-distiller --days 7 --user andrew --out /var/lib/ix-distiller \
  [--project index] [--model claude-haiku-4-5-20251001] \
  [--upload [--env-file /run/ix-secret-store/env/ix-indexer]]
```

Updates/deletes come free with the contract: rewriting the slice with the
current desired item set tombstones vanished ids on the next fold.

## Tests

`nix build .#distiller` runs the import smoke test; passthru checks run
pytest over the parquet contract (schema, content/manifest hashes, tamper
rejection), the incremental merge (stable ids, update-not-rewrite, caps),
and transcript signal extraction.
