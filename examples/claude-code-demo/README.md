# Claude Code Demo

This directory is a small ix fleet for demoing Claude Code against a live Paper server. Paper is used because Bukkit-family plugins have the best reload story in this repo: managed plugin changes trigger the Minecraft unit's `reload` path, and PlugManX reloads the changed plugin over local RCON without restarting the server.

```text
examples/claude-code-demo/
  flake.nix                       # declares inputs and exposes runnable commands
  default.nix                     # fleet definition imported by flake outputs/tests
  claude-code-scoreboard-plugin/  # local Paper plugin Maven project
```

## Topology

- `minecraft` is the only VM.
- Paper 1.21.11 runs the server.
- LuckPerms comes from the repo's Paper plugin catalog and is selected by slug.
- `ClaudeCodeDemoScoreboard` is a local Paper plugin built from source by the example and installed through `services.minecraft.plugins`.
- PlugManX is added automatically by `services.minecraft.autoReload` when the `plugman` driver is active.
- Java players enter on TCP 25565.

## Network Exposure

Every VM automatically has both network planes. This example only exposes the Minecraft port publicly:

```nix
deployment.expose.northSouth.tcp = [ 25565 ];
```

## Hot Reload

`services.minecraft.autoReload.driver = "plugman"` makes managed plugin changes reload instead of restarting the Minecraft service. The runtime syncs declarative plugins into `/var/lib/minecraft/plugins`, computes a per-plugin plan from the previous manifest, and sends `plugman load`, `plugman reload`, or `plugman unload` over local RCON.

`services.minecraft.plugins` mirrors Paper's own vocabulary. Empty `{}` means "use the pinned plugin catalog"; setting `src` means "install this local or private plugin jar". Fabric-style mods still use `services.minecraft.mods`.

The local plugin is a normal Maven project. Its `pom.xml` depends on `paper-api` with Maven's `provided` scope, so the plugin compiles against Paper's API without bundling server classes into the jar.

The two Nix files split responsibilities: `flake.nix` is the executable wrapper that declares inputs and exposes `nix run .#switch`; `default.nix` is the actual fleet value. Keeping the fleet in `default.nix` makes it easy for tests and other flakes to import the same definition without going through flake output plumbing.

## Use

From this directory:

```bash
nix run .#plan              # show the resolved fleet plan
nix run .#diff              # compare desired systems with live ix state
nix run .#switch
nix run .#replace
```

`switch` snapshots and switches nodes in dependency order. Use `replace` only when VM recreation is intended.

If ix grows a first-class command wrapper, the same flow should become:

```bash
ix fleet plan
ix fleet diff
ix switch
ix replace
```
