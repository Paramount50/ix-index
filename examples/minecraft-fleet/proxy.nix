{
  forwardingSecret,
  survivalNodes,
}:
{
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
            secretFile = forwardingSecret.path;
          };

          servers = {
            lobby = "${nodes.lobby.config.networking.hostName}:25565";
          }
          // builtins.listToAttrs (
            map (name: {
              inherit name;
              value = "${nodes.${name}.config.networking.hostName}:25565";
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

        networking.firewall.allowedTCPPorts = [ 25565 ];
        networking.firewall.allowedUDPPorts = [ 19132 ];
      }
    )
  ];
}
