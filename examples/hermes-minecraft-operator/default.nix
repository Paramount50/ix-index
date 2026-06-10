{ index }:

# A Hermes agent operating a Paper Minecraft server. Two nodes:
#
#   minecraft (Paper + RCON)  <-east-west-  hermes (agent + RCON MCP server)
#
# The agent gets one typed `run_command` MCP tool that speaks RCON to
# the game server, so "whitelist my friend", "shrink the world border",
# or a daily player-count report are chat requests instead of console
# sessions. See README.md for the workflows.
let
  # RCON is only routable inside this group; the public internet sees
  # the game port (the minecraft node has ipv4 for player traffic), not
  # the console.
  eastWestGroup = "hermes-minecraft";
in
index.lib.mkFleet {
  defaults = [ { ix.image.tag = "hermes-minecraft-operator"; } ];

  nodes = {
    minecraft = {
      groups = [ eastWestGroup ];
      deployment = {
        ipv4 = true;
        healthChecks = [ "minecraft" ];
      };
      modules = [ ./minecraft.nix ];
    };

    hermes = {
      dependsOn = [ "minecraft" ];
      groups = [ eastWestGroup ];
      modules = [
        index.lib.hermesAgent.nixosModules.default
        ../hermes-agent/hermes.nix
        ./operator.nix
      ];
    };
  };
}
