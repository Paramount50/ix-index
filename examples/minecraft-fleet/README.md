# Minecraft Fleet

This directory is a multi-file example of a production-shaped Minecraft network on ix.

```text
examples/minecraft-fleet/
  flake.nix          # exposes runnable fleet commands
  default.nix        # defines the fleet graph
  nodes/
    proxy.nix        # Velocity + Geyser + Floodgate edge node
    lobby.nix        # lobby node
    survival.nix     # replicated survival node group
  modules/
    folia.nix        # shared Folia backend shape
```

## Topology

- Velocity is the edge proxy. Prefer it over BungeeCord or Waterfall; Waterfall is end-of-life.
- Geyser runs on the proxy as the Bedrock-to-Java protocol bridge.
- Floodgate runs on the proxy as the Bedrock identity/auth bridge, so Bedrock players can join without Java accounts.
- Java players enter on TCP 25565. Bedrock players enter on UDP 19132.
- Folia runs the lobby and survival shards. These backends expose 25565 only on east-west and must be reached through Velocity.
- `survival` expands into stable VM identities: `survival-0`, `survival-1`, `survival-2`.
- Every VM automatically has two virtio-net devices: north-south for public ingress and east-west for the private mesh. Users do not define or attach these networks.

The Velocity/Geyser/Floodgate modules shown here are the intended API shape, not a claim that those modules all exist in this repo today. The OCI image is only the bootstrap artifact; normal updates use `switch` to activate a new NixOS system closure in place.

## Secrets

Velocity modern forwarding needs one shared secret. The proxy uses it to sign forwarded player identity, and the Folia backends use the same secret to trust only the proxy.

In this example the fleet asks ix to generate an opaque secret ref:

```nix
secrets.velocityForwarding.generate = true;
```

Modules consume the ref directly:

```nix
services.velocity.forwarding.secret = forwardingSecret;
services.minecraft.serverFiles."config/paper-global.yml".proxies.velocity.secret = forwardingSecret;
```

The exact `secrets` API is hypothetical here, but the invariant is real: generated once, shared with every node that references it, materialized at activation time, and rotated deliberately.

## Network Exposure

Every VM automatically has both network planes. The fleet config only decides what to expose.

Use north-south only for public ingress:

```nix
deployment.expose.northSouth = {
  tcp = [ 25565 ];
  udp = [ 19132 ];
};
```

Use east-west for private VM-to-VM traffic. Folia backends expose 25565 only here:

```nix
ix.networking.eastWest.firewall.allowedTCPPorts = [ 25565 ];
```

The proxy is the only north-south Minecraft entrypoint. It accepts public Java/Bedrock traffic, then talks to Folia backends over east-west hostnames.

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
