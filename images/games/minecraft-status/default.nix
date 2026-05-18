{
  ix.image = {
    name = "minecraft-status";
    tag = "1.21.11-fabric";
  };

  services.minecraft = {
    enable = true;
    version = "1.21.11";
    fabric.enable = true;
    openFirewall = false;

    properties = {
      motd = "ix status Minecraft";
      max-players = 8;
      online-mode = false;
      enforce-secure-profile = false;
      spawn-protection = 0;
      # The status canary only needs six bot logins and a loaded spawn area.
      # Smaller distances keep the five-minute lifecycle probe cheap.
      view-distance = 6;
      simulation-distance = 4;
    };
  };
}
