# Minecraft Fleet

This directory is a multi-file example of a production-shaped Minecraft network on ix.

```text
examples/minecraft-fleet/
  flake.nix        # exposes runnable fleet commands
  default.nix      # defines the fleet graph
  proxy.nix        # Velocity + Geyser + Floodgate edge node
  folia-node.nix   # shared Folia backend node module
```

## Topology

- Velocity is the edge proxy. Prefer it over BungeeCord or Waterfall; Waterfall is end-of-life.
- Geyser runs on the proxy as the Bedrock-to-Java protocol bridge.
- Floodgate runs on the proxy as the Bedrock identity/auth bridge, so Bedrock players can join without Java accounts.
- Java players enter on TCP 25565. Bedrock players enter on UDP 19132.
- Folia runs the lobby and survival shards.
- `survival` expands into stable VM identities: `survival-0`, `survival-1`, `survival-2`.

The Velocity/Geyser/Floodgate modules shown here are the intended API shape, not a claim that those modules all exist in this repo today. The OCI image is only the bootstrap artifact; normal updates use `switch` to activate a new NixOS system closure in place.

## Secrets

Velocity modern forwarding needs one shared secret. The proxy uses it to sign forwarded player identity, and the Folia backends use the same secret to trust only the proxy.

In this example the fleet asks ix to generate that secret once and mount it on the proxy and backend nodes:

```nix
secrets.velocityForwarding = {
  generate = true;
  path = "/run/ix-secrets/velocity-forwarding";
  sharedWith = [
    "proxy"
    "lobby"
    "survival"
  ];
};
```

Then the proxy reads `secretFile = forwardingSecret.path`, and the Folia nodes reference the same file from `paper-global.yml`. The exact `secrets` API is hypothetical here, but the invariant is real: generated once, shared with every node that participates in Velocity forwarding, and rotated deliberately.

## Use

From this directory:

```bash
nix run .#plan -- plan      # show the resolved fleet plan
nix run .#plan -- diff      # compare desired systems with live ix state
nix run .#switch
nix run .#replace -- replace
```

`switch` snapshots and switches nodes in dependency order. Use `replace` only when VM recreation is intended.

If ix grows a first-class command wrapper, the same flow should become:

```bash
ix fleet plan
ix fleet diff
ix switch
ix replace
```
