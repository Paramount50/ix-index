# Minecraft Fleet

Hypothetical target shape for a production Minecraft network on ix:

- Velocity is the edge proxy. Prefer it over BungeeCord or Waterfall; Waterfall is end-of-life.
- Geyser runs on the proxy as the Bedrock-to-Java protocol bridge.
- Floodgate runs on the proxy as the Bedrock identity/auth bridge, so Bedrock players can join without Java accounts.
- Java players enter on TCP 25565. Bedrock players enter on UDP 19132.
- Folia runs the lobby and survival shards.
- `survival` expands into stable VM identities: `survival-0`, `survival-1`, `survival-2`.

The Velocity/Geyser/Floodgate modules shown here are the intended API shape, not a claim that those modules all exist in this repo today. The OCI image is only the bootstrap artifact; normal updates use `switch` to activate a new NixOS system closure in place.

```nix
let
  ix-images = builtins.getFlake "github:indexable-inc/images";
  fleet = import ./default.nix { inherit ix-images; };
in
{
  apps.x86_64-linux.switch = {
    type = "app";
    program = "${fleet.switch}/bin/ix-fleet-switch";
  };
}
```

`nix run .#switch` snapshots and switches nodes in dependency order. Use `ix-fleet replace` only when VM recreation is intended.
