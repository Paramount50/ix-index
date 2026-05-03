# Fabric server jar. Pinned via the upstream meta API URL: minecraft version
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
  urlFor =
    cfg:
    "https://meta.fabricmc.net/v2/versions/loader/${cfg.minecraftVersion}/${cfg.loaderVersion}/${cfg.installerVersion}/server/jar";
  extraOptions = lib': {
    minecraftVersion = lib'.mkOption { type = lib'.types.str; };
    loaderVersion = lib'.mkOption { type = lib'.types.str; };
    installerVersion = lib'.mkOption { type = lib'.types.str; };
  };
}
