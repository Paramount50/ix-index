# ix/images

NixOS images and modules for [ix](https://ix.dev) VMs. Built with `-march=znver5` for AMD EPYC Gen 5.

## Minecraft Fleet

Use Velocity as the proxy, not BungeeCord or Waterfall. Velocity is the modern PaperMC proxy; Waterfall has reached end of life. In a complete crossplay module set, put Geyser and Floodgate on the proxy: Geyser is the Bedrock-to-Java protocol bridge, and Floodgate is the Bedrock identity/auth bridge so Bedrock players can join without Java accounts. Bedrock players enter over UDP 19132; Java players use the normal TCP 25565 entrypoint.

This is the hypothetical target shape for a production Minecraft fleet: one proxy, one lobby, and replicated Folia survival shards. The Velocity/Geyser/Floodgate modules shown here are the intended API shape, not a claim that those modules all exist in this repo today. The OCI image is only the bootstrap artifact; normal updates use `switch` to activate a new NixOS system closure in place.

```nix
let
  forwardingSecretFile = /run/secrets/velocity-forwarding-secret;
in
ix-images.lib.mkFleet {
  nodes = {
    proxy = {
      tags = [ "edge" ];
      dependsOn = [
        "lobby"
        "survival"
      ];
      deployment = {
        ipv4 = true;
        l7ProxyPorts = [ 25565 ];
      };

      modules = [
        (
          { nodes, ... }:
          {
            services.velocity = {
              enable = true;
              bind = "0.0.0.0:25565";
              onlineMode = true;
              forwarding = {
                mode = "modern";
                secretFile = forwardingSecretFile;
              };

              servers =
                {
                  lobby = "${nodes.lobby.config.networking.hostName}:25565";
                }
                // builtins.listToAttrs (
                  map (name: {
                    inherit name;
                    value = "${nodes.${name}.config.networking.hostName}:25565";
                  }) [
                    "survival-0"
                    "survival-1"
                    "survival-2"
                  ]
                );

              try = [ "lobby" ];
            };

            services.geyser = {
              enable = true;
              platform = "velocity";
              bedrock = {
                address = "0.0.0.0";
                port = 19132;
              };
              remote = {
                address = "127.0.0.1";
                port = 25565;
                authType = "floodgate";
              };
            };

            services.floodgate = {
              enable = true;
              platform = "velocity";
            };

            networking.firewall.allowedTCPPorts = [ 25565 ];
            networking.firewall.allowedUDPPorts = [ 19132 ];
          }
        )
      ];
    };

    lobby = {
      tags = [ "minecraft" ];
      modules = [
        {
          services.minecraft = {
            folia = {
              enable = true;
              version = "1.21.10";
              build = 12;
            };

            serverFiles = {
              "server.properties" = {
                motd = "ix lobby";
                online-mode = false;
                enforce-secure-profile = false;
              };

              "config/paper-global.yml".proxies.velocity = {
                enabled = true;
                online-mode = true;
                secret = "@secret:${toString forwardingSecretFile}";
              };
            };
          };
        }
      ];
    };

    survival = {
      replicas = 3;
      tags = [ "minecraft" ];
      modules = [
        (
          { name, ... }:
          {
            services.minecraft = {
              folia = {
                enable = true;
                version = "1.21.10";
                build = 12;
              };

              serverFiles = {
                "server.properties" = {
                  motd = "ix survival ${name}";
                  online-mode = false;
                  enforce-secure-profile = false;
                  view-distance = 10;
                  simulation-distance = 8;
                };

                "config/paper-global.yml".proxies.velocity = {
                  enabled = true;
                  online-mode = true;
                  secret = "@secret:${toString forwardingSecretFile}";
                };
              };
            };
          }
        )
      ];
    };
  };
}
```

The proxy is stateless and can be replaced. The Folia nodes have stable VM identities (`survival-0`, `survival-1`, `survival-2`) and persistent worlds, so they should be switched in place. ix VMs have implicit snapshots and effectively unbounded disk, so stateful services should snapshot before data-format changes and upgrade persistent data directly instead of replacing the VM.

Outputs `packages.<node>` (bootstrap OCI archives), `plan` (JSON), `command`, and `switch`.

```nix
apps.switch.program = "${fleet.switch}/bin/ix-fleet-switch";
```

`nix run .#switch` snapshots and switches nodes in dependency order. Use `ix-fleet replace` only when VM recreation is intended.

## Contributing

Drop `images/<category>/<name>/default.nix`. See [AGENTS.md](AGENTS.md). [MIT](LICENSE).
