# Fabric server jar. https://fabricmc.net
# Pinned via the upstream meta API URL: minecraft version
# + Fabric loader version + Fabric installer version are all part of the URL.
{
  ix,
  config,
  lib,
  pkgs,
  ...
}:
ix.mkMinecraftLoader {
  inherit config lib pkgs;
  name = "fabric";
  dropDir = "mods";
  urlFor =
    cfg:
    "https://meta.fabricmc.net/v2/versions/loader/${cfg.version}/${cfg.loaderVersion}/${cfg.installerVersion}/server/jar";
  extraOptions = {
    version = lib.mkOption { type = lib.types.str; };
    loaderVersion = lib.mkOption { type = lib.types.str; };
    installerVersion = lib.mkOption { type = lib.types.str; };
  };
}
