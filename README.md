# ix/images

NixOS images and modules for [ix](https://ix.dev) VMs. Built with `-march=znver5` for AMD EPYC Gen 5.

## Fleets

Fleets are VM-level NixOS systems, not primarily OCI rollouts. The OCI image is only the bootstrap artifact for creating or intentionally replacing a VM; normal updates use `switch` to activate a new NixOS system closure in place.

See [examples/minecraft-fleet/README.md](examples/minecraft-fleet/README.md) for a multi-file hypothetical Minecraft network using Velocity, Geyser, Floodgate, and replicated Folia shards.

Outputs `packages.<node>` (bootstrap OCI archives), `plan` (JSON), `command`, and `switch`.

```nix
apps.switch.program = "${fleet.switch}/bin/ix-fleet-switch";
```

`nix run .#switch` snapshots and switches nodes in dependency order. Use `ix-fleet replace` only when VM recreation is intended.

## Contributing

Drop `images/<category>/<name>/default.nix`. See [AGENTS.md](AGENTS.md). [MIT](LICENSE).
