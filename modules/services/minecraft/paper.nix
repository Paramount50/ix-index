# Paper server jar. Pinned to a (minecraftVersion, build) pair from the
# PaperMC API: https://api.papermc.io/v2/projects/paper/versions/<v>/builds/<b>
{
  ix,
  config,
  lib,
  pkgs,
  ...
}:
ix.mkMinecraftLoader {
  inherit config lib pkgs;
  name = "paper";
  urlFor =
    cfg:
    "https://api.papermc.io/v2/projects/paper/versions/${cfg.minecraftVersion}/builds/${toString cfg.build}/downloads/paper-${cfg.minecraftVersion}-${toString cfg.build}.jar";
  extraOptions = lib': {
    minecraftVersion = lib'.mkOption { type = lib'.types.str; };
    build = lib'.mkOption { type = lib'.types.int; };
  };
}
