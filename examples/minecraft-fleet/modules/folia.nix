{
  forwardingSecret,
  motd,
  extraModules ? [ ],
  extraServerProperties ? { },
}:
{
  tags = [ "minecraft" ];
  modules = [
    (
      { name, pkgs, ... }:
      {
        services.minecraft = {
          folia = {
            enable = true;
            version = "1.21.10";
            build = 12;
            src = pkgs.emptyFile;
          };

          serverFiles = {
            "server.properties" = {
              motd = "${motd} ${name}";
              online-mode = false;
              enforce-secure-profile = false;
            }
            // extraServerProperties;

            "config/paper-global.yml".proxies.velocity = {
              enabled = true;
              online-mode = true;
              secret = forwardingSecret;
            };
          };
        };

        # Backends are private. Public Java and Bedrock clients enter through
        # Velocity; only the proxy should reach Folia directly.
        ix.networking.eastWest.firewall.allowedTCPPorts = [ 25565 ];
      }
    )
  ]
  ++ extraModules;
}
