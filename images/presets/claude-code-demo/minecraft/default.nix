{
  deployment.ipv4 = true;
  modules = [
    (_: {
      services.minecraft = {
        enable = true;
        version = "1.21.11";
        paper.enable = true;
        rcon.enable = true;

        plugins = {
          luckperms = { };
        };

        serverFiles."server.properties" = {
          motd = "Claude Code Demo";
          max-players = 20;
          online-mode = true;
          gamemode = "creative";
          force-gamemode = true;
          level-seed = "1143653337750952406";
          spawn-protection = 0;
          allow-flight = true;
          difficulty = "peaceful";
          view-distance = 12;
          simulation-distance = 10;
        };
      };
    })
  ];
}
