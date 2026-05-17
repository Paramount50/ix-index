# Index

**Ready-to-run ix VMs. Zero plumbing.**

## Why You'll Like This

- **Images that just boot.** Minecraft, Postgres, remote desktop, and the long tail you'd otherwise babysit.
- **Services that compose.** Mix them like LEGO™. (The metaphor breaks the first time two services want port 25565.)
- **[`llm-clippy`](packages/llm-clippy/) included.** A Rust linter that emits diagnostics an LLM can actually parse.
- **~67 OCI layers per closure, every package compiled for znver5.** No [nixpkgs](https://github.com/NixOS/nixpkgs) cache hits, on purpose.

## Try It

```sh
nix build .#minecraft              # build an image
nix run .#claude-code-demo-up      # spin up the demo fleet
```

The first build is slow: every package compiles from source for AMD EPYC Gen 5. After that the nix store does its job and rebuilds are cheap.

## Bad Fit If

You're on aarch64, FreeBSD, or any CPU that isn't znver5. The "from source" rule isn't negotiable: the whole closure recompiles for `-march=znver5`, and there's no fallback path to a generic x86_64 cache.

## Want More?

- [`packages/`](packages/) for tools (including [`llm-clippy`](packages/llm-clippy/))
- [`modules/`](modules/) for services to plug in
- [`images/`](images/) for runnable systems
- [`examples/`](examples/) for downstream-style fleets such as a daily Python scraper
- [`lib/`](lib/) for the shared helpers the rest stands on

See [AGENTS.md](AGENTS.md) and [CONTRIBUTING.md](CONTRIBUTING.md) when you're ready to dig in.
