# Index

**Ready-to-run ix VMs. Zero plumbing.**

## Why You'll Like This

- **Images that just boot.** Minecraft, Postgres, remote desktop, and the long tail you'd otherwise babysit.
- **Services that compose.** Mix them like LEGO™.
- **`llm-clippy` included.** A Rust linter tuned for output an LLM can actually read.
- **One lockfile pinning the whole catalog.**

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
