{
  services.minecraft = {
    enable = true;
    version = "1.21.11";
    fabric.enable = true;

    properties = {
      motd = "ix Crazy Terrain";
      max-players = 20;
      online-mode = false;
      # The terrain pass is expensive, so give the server enough simulation
      # radius to actually exercise the generator without churning chunks.
      view-distance = 16;
      simulation-distance = 12;
    };

    mods = {
      fabric-api = { };
      # Diffusion-model world generator. The catalog jar at
      # images/games/minecraft/mods/1.21.11.json is the CPU build; the same
      # upstream release ships a GPU variant. Swap the manifest URL and
      # regenerate with `nix run .#update-mods -- --version 1.21.11` on a host
      # with a CUDA-capable GPU.
      terrain-diffusion = { };
    };
  };
}
