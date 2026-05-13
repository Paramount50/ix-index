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
  inherit config lib;
  name = "fabric";
  dropDir = "mods";
  extraOptions = {
    version = lib.mkOption { type = lib.types.str; };
    loaderVersion = lib.mkOption { type = lib.types.str; };
    installerVersion = lib.mkOption { type = lib.types.str; };
  };
  # Fabric uses the shared Temurin JVM default. Hot reload can redefine ordinary
  # classes through the Java agent, but it does not dynamically load new mods or
  # mutate frozen registries.
  extraConfig = _: {
    services.minecraft.javaPackage = lib.mkDefault pkgs.temurin-jre-bin-25;
  };
}
