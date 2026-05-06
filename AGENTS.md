# ix/images

## Workflow

Commit and push after making changes by default.

## Overview

Pre-built OCI images for ix VMs, plus composable NixOS modules. All images target AMD EPYC Gen 5 (Turin, Zen 5). The base layer sets `nixpkgs.hostPlatform.gcc.arch = "znver5"` so every package in the closure is compiled with `-march=znver5 -mtune=znver5`. No binary cache hits: everything builds from source.

## How it works

Every image is an independent NixOS system closure: `boot.isContainer = true`, systemd as PID 1, no kernel, no bootloader. `lib.mkImage` runs `nixpkgs.lib.nixosSystem` over the platform config (`lib/ix-platform.nix`), OCI packaging (`lib/ix-oci-layer.nix`), the module registry (`modules/`), and any caller modules, then packages the toplevel into an OCI archive via `dockerTools.streamLayeredImage` plus a small docker-archive-to-OCI converter (`lib/docker-to-oci.py`).

Images are not stacked at runtime. ix runs one image. Layering is purely a build-time concern: the closure is split into ~67 OCI layers so the registry stores each shared store path once and clients only pay for deltas. Single-layer would force every image to ship a private copy of the multi-hundred-MB base closure.

## VM assumptions

ix VMs implicitly have snapshots and effectively unbounded disk. Fleet and stateful-service designs should lean on those primitives: take snapshots before destructive or data-format-changing operations, prefer in-place NixOS/system switches for stateful nodes, and do not design around fixed-root-disk exhaustion as a primary constraint.

## Layout

```
flake.nix                                  # pure: ix.discoverImages ./images
lib/
  default.nix                              # mkImage, discoverImages, helpers
  ix-platform.nix                          # target platform: EPYC Gen 5 (znver5), container mode
  ix-oci-layer.nix                               # OCI packaging, base profile
  minecraft-loader.nix                     # helper used by loader modules
  docker-to-oci.py                         # docker-archive -> OCI archive transcoder
modules/
  default.nix                              # canonical module registry (attrset)
  profiles/base.nix                        # CLI tools, on by default
  services/<name>.nix                      # opt-in service
  services/<family>/{default,...}.nix      # service family (runtime + plugins)
images/
  <category>/<name>/default.nix            # NixOS module
  <category>/<name>/versions.nix           # optional: per-version overlay modules
template/                                  # `nix flake init` starter
nix/rules/                                 # ast-grep lint rules
```

## Adding an image

Drop a NixOS module at `images/<category>/<name>/default.nix`. That's it: discovery picks it up on the next eval and exposes `packages.x86_64-linux.<name>`. No flake edits, no registry edits.

For a versioned image (multiple variants ship at once), add a `versions.nix` sibling:

```nix
{ lib, ... }:
let
  default = "26w17a-fabric";
  variants = {
    "26w17a-fabric" = {
      loader = "fabric";
      /* loader-specific args */
    };
  };
in
{
  inherit default;
}
// lib.mapAttrs (tag: { loader, ... }@cfg: {
  ix.image.tag = tag;
  services.minecraft.${loader} = (builtins.removeAttrs cfg [ "loader" ]) // {
    enable = true;
  };
}) variants
```

Discovery then exposes `<name>_<ver>` for each version key plus `<name>` as an alias for the `default` version.

## Adding a module

Drop the file at `modules/services/<name>.nix` (or `modules/profiles/<name>.nix`) and register it in `modules/default.nix`. Keep modules independent: declare `options`, gate everything behind `mkIf cfg.enable`, never import another module. The registry exists so option sets are visible to every image; modules stay inert until their `enable` flag is set.

## Service families

When several modules vary along one axis (e.g. minecraft + fabric/paper/vanilla loaders), put the runtime in `modules/services/<name>/default.nix` and each variant in `modules/services/<name>/<variant>.nix`. The runtime declares a "slot" option; variants fill it. Wire each file into `modules/default.nix` as a separate registry entry.

For minecraft this means:
- `services.minecraft.serverJar` is the slot, declared by the runtime.
- Each loader module (fabric, folia, neoforge, paper, purpur, spigot, sponge, vanilla) sets `services.minecraft.serverJar` from its own URL/version options.
- Enabling a loader auto-enables the runtime via `mkDefault`.
- Enabling two loaders is a module-merge conflict → loud eval error.

## Mods

All mods go in `services.minecraft.mods`, keyed by Modrinth slug. Empty `{}` includes the jar with defaults. Attrsets with fields configure the mod.

```nix
services.minecraft.mods = {
  fabric-api = {};
  lithium = {};
  distanthorizons.maxRenderDistance = 512;
};
```

The `modCatalog` option maps slugs to `{ url, hash }`. Set by the image base (from `common.json`) and version overlays (from `<version>.json`). The runtime resolves every key in `mods` against the catalog via `pkgs.fetchurl`.

### Mod modules

Mods with config files get a NixOS module at `modules/services/minecraft/mods/<name>.nix`. The module activates when `services.minecraft.mods.<slug>` is present, reads the user's attrset (with defaults), and generates `configFiles`.

```nix
# modules/services/minecraft/mods/distant-horizons.nix
{ config, lib, ... }:
let
  modCfg = config.services.minecraft.mods.distanthorizons or null;
  defaults = { serverSideLodGeneration = true; maxRenderDistance = 256; };
  merged = defaults // (if modCfg == null then {} else modCfg);
in
{
  config = lib.mkIf (modCfg != null) {
    services.minecraft.configFiles."DistantHorizons.toml" = {
      server = { inherit (merged) serverSideLodGeneration maxRenderDistance; };
    };
  };
}
```

Mods without config (lithium, krypton, chunky) do not need a module. The slug in `mods` is sufficient. Register mod modules in `modules/default.nix` under `minecraft.mods.<name>`.

### Config file format inference

`configFiles` keys are relative paths under `config/`. The serialization format is inferred from the file extension: `.toml`, `.json`, `.yaml`/`.yml`, `.properties`. Values are plain Nix attrsets. Mod modules never import `pkgs.formats` directly.

```nix
services.minecraft.configFiles."SomeMod.toml" = { section.key = "value"; };
services.minecraft.configFiles."other.yml" = { setting = true; };
```

### Writable vs read-only configs

Config files are symlinked to the Nix store (read-only). Some mods write to their config at runtime. If a mod needs a writable config, the mod module should copy instead of symlink. This is not yet implemented but is a known gap (see nix-minecraft's `files` vs `symlinks` pattern for reference).

## Cross-cutting helpers (`specialArgs.ix`)

Helpers shared across modules go in `lib/` and are exposed to every module through `specialArgs.ix`. Modules consume them as ordinary module args:

```nix
# modules/services/minecraft/fabric.nix
{ ix, config, lib, pkgs, ... }:
ix.mkMinecraftLoader {
  inherit config lib pkgs;
  name = "fabric";
  urlFor = cfg: "https://meta.fabricmc.net/v2/...";
  extraOptions = { /* loader-specific options */ };
}
```

This is the only way modules in this repo reach helpers in `lib/`. **Never** use `../` or `../../` paths to climb out of `modules/`. Relative-path imports between modules and lib break the abstraction (modules become coupled to lib's filesystem layout) and make module files harder to relocate. If a helper needs to be shared, expose it through `specialArgs.ix`. The helper bundle is also part of the public flake `lib` output, so external users get the same surface.

## Module conventions

- Modules declare options and config. They never `imports` another module.
- Top-level options live under `services.<name>` for services, `ix.profiles.<name>` for profiles. Never reach into another module's namespace.
- Everything in `config` is wrapped in `mkIf cfg.enable`. The base profile is the only exception: it ships an enable flag so users can opt out.
- Module options take strings, paths, or packages — not factory arguments. Versioning belongs in `versions.nix`, not in a function wrapping the module.
- Cross-module helpers come from `specialArgs.ix`. No `..` paths.

## Image conventions

- Images set `ix.image.name`. They may set `ix.image.tag` (defaults to `latest`, or comes from `versions.nix`).
- Images compose by enabling services and adding packages. They do not declare options. They do not `imports` anything.
- Images stay version-agnostic when they have a `versions.nix`. The base file is what every variant shares; per-version data lives in the overlay.
- Use a single `services.<name>` block per service. Nest sub-options (loaders, mods) inside it instead of writing separate `services.<name>.<sub> = ...;` assignments.
- Options that are redundant with their namespace should be shortened. `services.minecraft.folia.version`, not `services.minecraft.folia.minecraftVersion`.

## Hashes

Hashes are an internal concern of the module or library that declares the fetch. Consumers (images, `versions.nix`) should never need to provide a hash. If a loader module fetches a server jar, the hash belongs inside that module alongside the URL, not in the consumer's config.

Fetcher hashes (`pkgs.fetchurl { hash = "sha256-..."; }`) live **inline next to the URL**, in whichever file declares the fetch. For per-package artifacts that's the module declaring the fetch.

`flake.lock` only tracks flake inputs (other flakes you import). It does not track arbitrary fetchurl calls. Putting per-image hashes in `flake.nix` would force every version to become a flake input. Inline is the nixpkgs convention; follow it.

Tracked Nix files must contain real SRI hashes. Do not write `lib.fakeHash`, `lib.fakeSha256`, `lib.fakeSha512`, or placeholder hashes such as `sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=` into the repo, even temporarily. Compute the real hash first, then edit the file. For direct URL fetches, run `nix-prefetch-url --type sha256 <url>` and convert with `nix hash to-sri --type sha256 <hex>`. For other fixed-output derivations, use a pure scratch expression or command outside tracked files to obtain the `got:` hash.

## Target platform

All images run on AMD EPYC Gen 5 (Turin, Zen 5). `lib/ix-platform.nix` sets `nixpkgs.hostPlatform.gcc.arch = "znver5"` and `tune = "znver5"`, which propagates `-march=znver5 -mtune=znver5` to every package in the closure. This enables AVX-512, VNNI, and other Zen 5 instructions across the board.

Because the arch differs from the nixpkgs binary cache (generic x86_64), every package builds from source. This is intentional: these images run on known hardware and the build cost is paid once.

When adding new modules or packages, do not override compiler flags per-package. The base layer handles it globally. If a package needs arch-specific tuning beyond compiler flags (e.g. PostgreSQL `huge_pages`, JVM `-XX:+UseAVX`), set those in the module.

## Nix philosophy

- **Single source of truth.** `modules/default.nix` is the only place modules are listed; `lib.collect` derives the flat list from the nested attrset. Versions live next to the image in `versions.nix`, not in `flake.nix`. Hashes live next to URLs.
- **No backwards compat.** This repo is young and has no external consumers. Rename freely, change signatures, delete dead code. No shims, no aliases, no `// removed` comments, no feature flags for the old way. Update callers in the same change.
- **Auto-discover, don't enumerate.** `flake.nix` walks `images/`. Adding an image is `mkdir + edit one file`. Hand-wired registries rot.
- **DRY at the data layer, not the abstraction layer.** `inherit (pkgs) ...` over a wrapper helper. `lib.collect` over a parallel list. Don't introduce a function unless it has at least two callers; the minecraft-loader helper qualifies because eight loaders share the same shape.
- **Comments explain why, not what.** Headers say what each file is for and what's load-bearing (e.g. `maxLayers = 67` with the registry-cap rationale, base profile auto-enabled). Don't restate what the code obviously does.
- **Trust module merging.** Layer per-version overlays via the module system, not by passing args to factory functions. Service families (runtime + variants) compose through option slots, not through wrappers.
- **Pure eval.** No `builtins.currentSystem`, no `builtins.getEnv`, no `<nixpkgs>` channel refs, no `path:` flake refs. Every input flows through `flake.nix`.
- **Strict, named failures.** `lib.assertMsg` over bare `assert`. Required options have no default so misuse fails at eval with the option name. Two loaders enabled → module-merge conflict, not silently-last-wins.

## Nix style (ast-grep enforced)

Run `nix run nixpkgs#ast-grep -- scan` before committing. Hard rules:

- No `with pkgs;` or `with lib;`. Use `inherit (pkgs) ...` or `lib.foo` directly.
- No `rec { }`. Use `let ... in` or `final/prev` instead.
- No `mkForce`. Resolve conflicts with priority composition or fix the module boundary.
- No `lib.recursiveUpdate`. Build the attrset in one place or use `lib.mkMerge`.
- No `builtins.currentSystem`, `builtins.getEnv`, `<nixpkgs>`, or `path:` flake refs.
- No `(import ./foo.nix)` inside `imports = [ ... ]`. NixOS auto-imports paths.
- No `..` paths inside `modules/`. Cross-cutting helpers come through `specialArgs.ix`.
- No `writeShellScriptBin`. Use `writeShellScript` (or `writeShellApplication` for orchestrators).
- No bare `assert cond;`. Use `assert lib.assertMsg cond "why";`.
- `strictDeps = true` on every `mkDerivation`. `__structuredAttrs` is the nixpkgs default; do not set it explicitly.
- `hash = "sha256-...="` (SRI) on fetchers. Never `sha256 = ...`.
- No fake hash helpers or placeholder hashes in tracked Nix files. Compute the real SRI hash first.
- x86_64-linux only. `system` is a single string, not a `forAllSystems` fold.

## Issues

Keep issue bodies short. State the problem, the context, and the desired outcome. Don't prescribe implementation steps or section headers unless explicitly asked. A few sentences is enough.

## Searching

Use `mgrep search -c {natural language}` to search the codebase. Do not use subagents for search.

## Linting

```
nix run nixpkgs#ast-grep -- scan
```
