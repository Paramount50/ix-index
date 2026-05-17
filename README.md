# Index

**Ready-to-run ix VMs. One flake. Zero plumbing.**

## Why You'll Like This

- **Images that just boot.** Minecraft, Postgres, remote desktop, more.
- **Compose, don't glue.** Mix services like Lego — no config soup.
- **`llm-clippy`** — Rust linter tuned for LLM-friendly output. Ships in the box.
- **One lockfile.** One catalog. One source of truth.

## Try It

```sh
nix build .#minecraft              # build an image
nix run .#claude-code-demo-up      # spin up the demo fleet
```

Done.

## Want More?

- `packages/` — tools (incl. `llm-clippy`)
- `modules/` — services to plug in
- `images/` — runnable systems

See [AGENTS.md](AGENTS.md) and [CONTRIBUTING.md](CONTRIBUTING.md) when you're ready to dig in.
