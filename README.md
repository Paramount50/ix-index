# ix/images

NixOS images and modules for [ix](https://ix.dev) VMs. Built with `-march=znver5` for AMD EPYC Gen 5.

## Fleets

Groups of VMs that reference each other's config:

```nix
ix-images.lib.mkFleet {
  nodes = {
    db.services.ix-postgresql.enable = true;

    lobby = { nodes, ... }: {
      services.minecraft.paper = {
        enable = true;
        serverFiles."server.properties".motd =
          "db: ${nodes.db.config.networking.hostName}";
      };
    };
  };
}
```

Outputs `packages.<node>` (OCI archives) and `plan` (JSON for the ix CLI).

## Quick start

```bash
ix new minecraft          # Fabric server
ix new minecraft-bedrock  # Bedrock dedicated
ix new remote-desktop     # Xpra HTML5 desktop
ix new kernel-dev         # Linux kernel + build tools
```

See [`images/`](images).

## Custom images

```nix
ix-images.lib.mkImage {
  modules = [{
    ix.image.name = "my-mc";
    services.minecraft.folia = {
      enable = true;
      version = "1.21.4";
      mods = {
        distanthorizons.maxRenderDistance = 512;
        bluemap.mysql = true;
        chunky = {};
      };
    };
  }];
}
```

Mods are [Modrinth](https://modrinth.com) slugs. `mysql = true` auto-provisions MariaDB. Loaders: fabric, folia, neoforge, paper, purpur, spigot, sponge, vanilla. All [NixOS options](https://search.nixos.org/options) work.

## Build

```bash
nix build github:indexable-inc/images#minecraft
ix push ./result minecraft
```

## Contributing

Drop `images/<category>/<name>/default.nix`. See [AGENTS.md](AGENTS.md). [MIT](LICENSE).
