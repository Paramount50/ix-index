# loop

Runs an agent CLI (codex, claude, aider, anything that takes a prompt on
argv) in a checked commit-and-push loop, with a live web UI you can open in
a browser to watch progress.

Replaces the older `tools/codex-loop.py`. Same UX (`--lint-program`,
`--once`, `--branch`, etc.), plus a Bandit-served page at
<http://localhost:7878> with a WebSocket feed of every iteration line.

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

## Layout

- `mix.exs`, `mix.lock` — Hex deps (bandit, plug, websock_adapter).
- `deps.nix` — generated from `mix.lock` with
  `nix shell nixpkgs#mix2nix -c mix2nix mix.lock > deps.nix`.
  Regenerate whenever `mix.lock` changes.
- `default.nix` — Nix package, builds an escript via
  `pkgs.beamPackages.mixRelease`.
- `lib/loop/cli.ex` — escript entrypoint, argv parsing, prompt resolution.
- `lib/loop/runner.ex` — iteration loop, agent/lint/git orchestration,
  Port-based subprocess streaming.
- `lib/loop/git.ex` — short-lived `git` wrappers over `System.cmd/2`.
- `lib/loop/log_bus.ex` — `GenServer` pub/sub with a 500-line replay
  buffer for late subscribers.
- `lib/loop/web/` — Bandit server: `router.ex` exposes `/` and `/ws`,
  `socket.ex` is the WebSock handler, `page.ex` holds the static HTML.

## Bad fit if

- You want a one-shot CLI with no live observers and zero dep closure.
  The previous Python script was 160 lines and zero deps. This trades that
  for a real OTP supervision tree and a shared event bus.
- You need cross-platform Windows support. Escripts under nixpkgs target
  unix only.
