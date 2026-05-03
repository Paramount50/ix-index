# Spigot server jar. https://www.spigotmc.org
# CraftBukkit fork. No direct download API (official method is BuildTools),
# so this takes a URL like the vanilla loader.
{
  ix,
  config,
  lib,
  pkgs,
  ...
}:
ix.mkMinecraftLoader {
  inherit config lib pkgs;
  name = "spigot";
  dropDir = "plugins";
  urlFor = cfg: cfg.url;
  extraOptions = {
    url = lib.mkOption {
      type = lib.types.str;
      description = "Direct URL to a pre-built Spigot server jar.";
    };
  };
}
