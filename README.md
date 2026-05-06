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

Outputs `packages.<node>` (OCI archives), `plan` (JSON), `command`, and `deploy`.

```nix
apps.deploy.program = "${fleet.deploy}/bin/ix-fleet-deploy";
```

`nix run .#deploy` builds the fleet images, pushes them, and deploys nodes in dependency order.

## Contributing

Drop `images/<category>/<name>/default.nix`. See [AGENTS.md](AGENTS.md). [MIT](LICENSE).
