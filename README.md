# Index

**Ready-to-run ix VMs. One flake. Zero plumbing.**

## Why You'll Like This

- **Images that just boot.** Minecraft, Postgres, remote desktop, more.
- **Services that compose.** Mix them like Lego.
- **`llm-clippy` included.** A Rust linter tuned for LLM-friendly output.
- **One lockfile, one catalog, one source of truth.**

## Try It

```sh
nix build .#minecraft              # build an image
nix run .#claude-code-demo-up      # spin up the demo fleet
```

Done.

## Want More?

- `packages/` for tools (including `llm-clippy`)
- `modules/` for services to plug in
- `images/` for runnable systems

See [AGENTS.md](AGENTS.md) and [CONTRIBUTING.md](CONTRIBUTING.md) when you're ready to dig in.
