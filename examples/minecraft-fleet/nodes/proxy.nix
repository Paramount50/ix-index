{
  forwardingSecret,
  nixBuilderClientModule,
  survivalNodes,
}:
{
  tags = [ "edge" ];
  dependsOn = [
    "lobby"
    "nix-builder"
    "survival"
  ];
  deployment = {
    ipv4 = true;
    expose = {
      northSouth = {
        tcp = [ 25565 ];
        udp = [ 19132 ];
      };
    };
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
            secret = forwardingSecret;
          };

          servers = {
            lobby = "${nodes.lobby.config.ix.networking.eastWest.hostName}:25565";
          }
          // builtins.listToAttrs (
            map (name: {
              inherit name;
              value = "${nodes.${name}.config.ix.networking.eastWest.hostName}:25565";
            }) survivalNodes
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

        ix.networking = {
          eastWest.firewall.allowedTCPPorts = [ 25565 ];
          northSouth.firewall = {
            allowedTCPPorts = [ 25565 ];
            allowedUDPPorts = [ 19132 ];
          };
        };
      }
    )
    nixBuilderClientModule
  ];
}
