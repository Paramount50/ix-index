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
{
  imports = [
    (ix.mkMinecraftLoader {
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
    })
  ];

  # Default the JVM to JetBrains Runtime (JBR) on Fabric. The shared
  # minecraft runtime enables its hot-reload Java agent and the JBR-only
  # `-XX:+AllowEnhancedClassRedefinition` flag when autoReload selects the
  # Fabric/JVM driver, so Fabric gets structural class redefinition for
  # already-loaded mod classes without a full service restart.
  #
  # This still does not make Fabric dynamically load new mods or mutate
  # frozen registries; it is a development reload path for code that is
  # already present in the running JVM.
  #
  # Refs:
  #   https://docs.fabricmc.net/develop/getting-started/launching-the-game#hotswapping-classes
  #   https://github.com/JetBrains/JetBrainsRuntime/issues/205
  config = lib.mkIf config.services.minecraft.fabric.enable {
    services.minecraft.javaPackage = lib.mkDefault pkgs.jetbrains.jdk-no-jcef;
  };
}
