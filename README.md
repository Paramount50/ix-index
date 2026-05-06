# ix/images

Pre-built OCI images for [ix](https://ix.dev) VMs.

```bash
ix new minecraft          # Fabric server
ix new minecraft-bedrock  # Bedrock dedicated server
ix new remote-desktop     # Xpra HTML5 desktop
ix new kernel-dev         # Linux kernel source + build tools
```

See [`images/`](images) for all available images.

## Goals

A cosy starter pack of NixOS images for [ix](https://ix.dev) VMs. Pick one, deploy, get a server. Each image is a real NixOS system with systemd as PID 1, so you compose modules instead of patching shell scripts. Every package compiles with `-march=znver5` for AMD EPYC Gen 5.

Where this is heading:

- More images covering game servers, dev environments, media servers, self-hosted apps. If you'd otherwise spin it up by piping a `curl` into `bash`, it belongs here.
- WireGuard mesh so you can reach any of your VMs by hostname from your laptop over ix's internal network, without exposing public ports.
- GPU presets (CUDA, ROCm, llama.cpp, ComfyUI) ready for when the platform exposes GPUs.
- One-file additions: drop a file into `images/`, the flake picks it up, you get an OCI artifact you can `ix push`.

Suggestions and PRs welcome. Open an [issue](https://github.com/indexable-inc/images/issues) or send a patch.

## Build from source

```bash
nix build github:indexable-inc/images#minecraft
ix push ./result minecraft
```

## Custom images

Compose with NixOS modules:

```nix
ix-images.lib.mkImage {
  modules = [({ pkgs, ... }: {
    ix.image.name = "my-server";
    services.minecraft.enable = true;
    services.remote-desktop.enable = true;
    environment.systemPackages = [ pkgs.htop pkgs.vim ];
  })];
}
```

## Fleets

For Colmena-style groups of ix VMs, use `ix-images.lib.mkFleet`. Each node is
still a normal NixOS image module, but the fleet evaluates all nodes together
so modules can reference `nodes.<name>.config`.

```nix
ix-images.lib.mkFleet {
  deployment.region = "hil-1";

  nodes = {
    db = { ... }: {
      services.ix-postgresql.enable = true;
    };

    lobby = { nodes, ... }: {
      services.minecraft = {
        paper.enable = true;
        serverFiles."server.properties".motd =
          "database host: ${nodes.db.config.networking.hostName}";
      };
    };
  };
}
```

The result exposes:

- `packages.<node>`: OCI archives for each VM image.
- `nodes.<node>`: evaluated NixOS configs.
- `plan`: a JSON deployment plan with image archive paths, destination refs,
  region, tags, ports, env, and update policy.

Deployment should live in the ix CLI or TypeScript SDK apply engine. The Nix
side owns evaluation and graph shape; the imperative runner should consume
`plan` and perform typed create/update operations.

### Minecraft Bedrock

`minecraft-bedrock` runs Mojang's native Bedrock Dedicated Server through `services.minecraft-bedrock`. It listens on UDP 19132 and 19133 by default.

```nix
{
  ix.image.name = "my-bedrock";

  services.minecraft-bedrock = {
    enable = true;
    settings = {
      server-name = "ix-powered Bedrock";
      max-players = 20;
    };
  };
}
```

### Minecraft with Folia

[Folia](https://papermc.io/software/folia) is PaperMC's regionized multithreading fork. Supported loaders:

- [Fabric](modules/services/minecraft/fabric.nix) - mod loader
- [Folia](modules/services/minecraft/folia.nix) - regionized multithreading (Paper fork)
- [NeoForge](modules/services/minecraft/neoforge.nix) - Forge successor
- [Paper](modules/services/minecraft/paper.nix) - performance-focused server
- [Purpur](modules/services/minecraft/purpur.nix) - Paper fork with extra patches
- [Spigot](modules/services/minecraft/spigot.nix) - CraftBukkit fork
- [Sponge](modules/services/minecraft/sponge.nix) - SpongeVanilla standalone
- [Vanilla](modules/services/minecraft/vanilla.nix) - Mojang's official server

```nix
# images/games/my-mc/default.nix
{
  ix.image.name = "my-mc";

  services.minecraft = {
    folia = {
      enable = true;
      version = "1.21.4";
      build = 97;
    };
    serverFiles = {
      "server.properties" = {
        view-distance = 32;
        simulation-distance = 12;
        max-players = 20;
      };
      "bukkit.yml" = {
        settings.spawn-radius = 25000;
      };
    };
    mods = {
      distanthorizons = { maxRenderDistance = 512; };
      chunky = {};
      bluemap = { mysql = true; };
      luckperms = { mysql = true; };
      simple-voice-chat = {};
      spark = {};
    };
  };
}
```

Mods are keyed by [Modrinth](https://modrinth.com) slug. Empty `{}` includes the jar. Attrsets with fields configure the mod. Setting `mysql = true` auto-provisions MariaDB with the right databases and users.

All [NixOS options](https://search.nixos.org/options) work. Images are NixOS configs with systemd as PID 1.

## Contributing

Community contributions are welcome through [issues](https://github.com/indexable-inc/images/issues) and [pull requests](https://github.com/indexable-inc/images/pulls). Add `images/<category>/<name>/default.nix`; discovery wires it into the flake. See [AGENTS.md](AGENTS.md) for conventions.

## Related

- [ix](https://ix.dev) - the platform
- [ix docs](https://github.com/indexable-inc/docs) - platform documentation
- [ix CLI](https://github.com/indexable-inc/ix) - command-line interface
- [NixOS](https://nixos.org) - the module system and packages underneath

Inspired by [nixpkgs](https://github.com/NixOS/nixpkgs), [Colmena](https://github.com/zhaofengli/colmena), and [Raycast Extensions](https://github.com/raycast/extensions).

## License

[MIT](LICENSE). The license applies to the Nix expressions and modules in this repository, not to the software packaged within the images.
