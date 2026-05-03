# Paper server jar. https://papermc.io
# API: https://api.papermc.io/v2/projects/paper/versions/<v>/builds/<b>
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
  dropDir = "plugins";
  urlFor =
    cfg:
    "https://api.papermc.io/v2/projects/paper/versions/${cfg.version}/builds/${toString cfg.build}/downloads/paper-${cfg.version}-${toString cfg.build}.jar";
  extraOptions = {
    version = lib.mkOption { type = lib.types.str; };
    build = lib.mkOption { type = lib.types.int; };
  };
}
