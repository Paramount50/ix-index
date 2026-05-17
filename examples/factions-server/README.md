# Factions Server

Standalone downstream-style example for a Paper factions server on ix. It is
intended to be runnable as-is, then customized with real player UUIDs and
spawn/claim policy once the world exists.

It uses Paper `26.1.2` with a generated Paper plugin catalog entry for:

- PvPIndex Factions, TeamsAPI, PlaceholderAPI, and LuckPerms
- EssentialsX and EssentialsX Spawn for player/admin command basics
- CoreProtect for block, container, and rollback auditing
- VaultUnlocked, EternalEconomy, QuickShop-Hikari, and TradePost for money,
  chest shops, and an auction-house style market
- WorldEdit and WorldGuard for spawn/admin regions and claim-adjacent tooling
- TerraformGenerator for custom overworld generation
- CombatLog for PvP logout protection
- Simple Voice Chat and Distant Horizons Support
- BlueMap for a 3D browser map on TCP `8100`
- Skript for server-side scripted gameplay and admin automation

The example also sets:

- a vanilla world border at `0,0` with a `12000` block diameter
- a generated max-height datapack, raising dimension height to the valid
  4064-block maximum from Y `-2032` through Y `2031`
- `server.properties` gameplay defaults for a public factions server
- `bukkit.yml` spawn and autosave policy
- `spigot.yml` entity, hopper, high-TNT, tracking, and message policy
- Paper `paper-global.yml` and `paper-world-defaults.yml` performance,
  cannon, and raid policy

The plugin URLs and hashes are not owned by this example. They come from
`images/games/minecraft/plugins/paper/manifest.json`, regenerated from the repo
root with:

```bash
nix run .#update-mods -- --manifest images/games/minecraft/plugins/paper/manifest.json
```

The world border is applied after startup through local RCON. The RCON port is
not opened in the firewall by default; it exists so ix can apply the border and
reload managed Paper plugins during a switch.

BlueMap opens TCP `8100` for the rendered 3D web map. The Minecraft and BlueMap
ports are the only public TCP ports in this example.

## Layout

- `default.nix` defines the ix fleet node.
- `minecraft.nix` wires the Minecraft service and shared world settings.
- `plugins.nix` selects catalog plugins and PlugManX reload policy.
- `bukkit.nix`, `paper.nix`, and `spigot.nix` hold loader config files.
- `world.nix` keeps the seed and world-border constants in one place.
- `world-height.nix` contains the generated max-height dimension-type datapack.

## Use

From this directory:

```bash
nix run .#plan      # show the resolved fleet plan
nix run .#diff      # compare desired systems with live ix state
nix run .#up        # build/upload the image and create or start the VM
nix run .#switch    # switch the VM in place
nix run .#replace   # recreate the VM from the replacement image
```
