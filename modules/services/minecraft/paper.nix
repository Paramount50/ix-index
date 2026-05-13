# Paper server jar. https://papermc.io
# API: https://api.papermc.io/v2/projects/paper/versions/<v>/builds/<b>
{
  ix,
  config,
  lib,
  ...
}:
ix.mkMinecraftLoader {
  inherit config lib;
  name = "paper";
  dropDir = "plugins";
  srcDefault =
    cfg:
    let
      server = ix.artifacts.minecraft.paperServers.${cfg.version};
    in
    assert lib.assertMsg (cfg.build == server.build)
      "services.minecraft.paper.build = ${toString cfg.build}, but the pinned Paper ${cfg.version} artifact is build ${toString server.build}";
    server.src;
  extraOptions = {
    version = lib.mkOption { type = lib.types.str; };
    build = lib.mkOption { type = lib.types.int; };
  };
  extraConfig = _: {
    services.minecraft.pluginCatalog = ix.artifacts.minecraft.paperPluginCatalog;
  };
}
