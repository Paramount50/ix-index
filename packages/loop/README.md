# loop

Runs an agent CLI (codex, claude, aider, anything that takes a prompt on
argv) in a checked commit-and-push loop, with a live web UI you can open in
a browser to watch progress.

The runner is Rust. It stores run events in a Loro CRDT document and serves
a Svelte viewer at <http://localhost:7878>. `codex exec` subprocesses get
stdin from `/dev/null`, which avoids the upstream prompt-plus-stdin hang when
the parent process has an open pipe.

## Run

```
nix run .#loop -- --once
```

A prompt source is required. There is no built-in default, since a giant
repo-specific prompt should not live inside an agent-agnostic binary. The
prompt is resolved in this order, first match wins:

1. `--prompt "..."` literal
2. `--prompt-file path/to/prompt.md`
3. `LOOP_PROMPT_FILE` environment variable
4. `./loop-prompt.md` in the working directory

If none of those resolve, loop exits with a clear error.

`nix run .#health-checks-loro` starts the same viewer on port 7879 and runs
the health-check DAG through the Loro event stream.

## Layout

- `Cargo.toml`, `Cargo.lock` — Rust runner dependencies.
- `src/main.rs` — CLI parsing, Loro event document, HTTP/SSE server,
  agent loop, and health-check DAG mode.
- `site/` — Svelte viewer. It imports Loro's Wasm package and decodes
  `/api/state` snapshots client-side.
- `default.nix` — Nix package, builds the Svelte assets and wraps the Rust
  binary with `LOOP_VIEWER_DIR`.

## Bad fit if

- You want a one-shot CLI with no live observers and zero dep closure.
  This ships Rust web dependencies plus Loro's Wasm viewer bundle.
- You need a durable multi-user collaboration server. The Loro document is
  in-memory process state today.
