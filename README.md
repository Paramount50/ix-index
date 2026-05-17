# Index

Packages, services, and systems for ix.

This repo is the shared shelf for things ix can build, run, or compose:

- **Packages:** repo-owned tools like `llm-clippy`, `nix-cargo-unit`, and the OCI image builder.
- **Services:** reusable NixOS modules like Minecraft, Postgres, remote desktop, resource monitor, and git clone.
- **Systems:** ready-to-run images and fleets built from those packages and services.

## Why Use This

Use this when you want a working ix system without rebuilding the same plumbing again.

- One lockfile.
- One package catalog.
- One service module catalog.
- One place for examples that prove the APIs still work.

If a preset feels noisy, fix the shared package/service API so the next preset is smaller.

## Fast Paths

Build an image:

```sh
nix build .#minecraft
```

Plan the demo fleet:

```sh
nix run .#claude-code-demo-plan
```

Create or start the demo fleet:

```sh
nix run .#claude-code-demo-up
```

Regenerate Minecraft catalogs:

```sh
nix run .#update-mods
```

On macOS, Linux image builds still need a Linux builder.

## Where Things Go

- `packages/` - tools and binaries.
- `modules/` - reusable service/profile modules.
- `images/` - runnable systems.
- `images/presets/` - demos and fleet shapes.
- `lib/` - shared build/composition helpers.
- `tools/` - repo maintenance commands.

## Add Something

- New package: add `packages/<name>/default.nix`.
- New service: add `modules/services/<name>.nix`, then register it in `modules/default.nix`.
- New image: add `images/<category>/<name>/default.nix`.

See [AGENTS.md](AGENTS.md) for repo rules. See [CONTRIBUTING.md](CONTRIBUTING.md) for local checks.
