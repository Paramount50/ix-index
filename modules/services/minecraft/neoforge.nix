# NeoForge server jar. https://neoforged.net
# NeoForge uses an installer that generates server files, so this takes a
# direct URL to the final server jar.
{
  ix,
  config,
  lib,
  pkgs,
  ...
}:
ix.mkMinecraftLoader {
  inherit config lib pkgs;
  name = "neoforge";
  dropDir = "mods";
  urlFor = cfg: cfg.url;
  extraOptions = {
    url = lib.mkOption {
      type = lib.types.str;
      description = "Direct URL to a NeoForge server jar.";
    };
  };
}
