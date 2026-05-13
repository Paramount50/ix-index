_: {
  deployment.ipv4 = true;
  modules = [
    (_: {
      services.minecraft = {
        enable = true;
        version = "1.21.11";
        fabric.enable = true;
        rcon.enable = true;

        # spark is the in-server profiler. Run `/spark profiler` from the
        # console (or as op) to capture CPU samples during the demo.
        # The 1.21.11 catalog is owned by the library; bumps go through
        # `nix run .#update-mods`.
        mods.spark = { };

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
