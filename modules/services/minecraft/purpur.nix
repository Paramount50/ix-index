# Purpur server jar. https://purpurmc.org
# Paper fork with extra gameplay and performance patches.
# API: https://api.purpurmc.org/v2/purpur/<version>/<build>/download
{
  ix,
  config,
  lib,
  pkgs,
  ...
}:
ix.mkMinecraftLoader {
  inherit config lib pkgs;
  name = "purpur";
  dropDir = "plugins";
  urlFor = cfg: "https://api.purpurmc.org/v2/purpur/${cfg.version}/${toString cfg.build}/download";
  extraOptions = {
    version = lib.mkOption { type = lib.types.str; };
    build = lib.mkOption { type = lib.types.int; };
  };
}
