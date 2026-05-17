# Paper server jar. https://papermc.io
# Server jar comes from `ix.artifacts.minecraft.servers."${version}-paper"`,
# which aliases to `ix.artifacts.minecraft.paperServers.${version}.src`.
{
  ix,
  config,
  lib,
  ...
}:
ix.mkMinecraftLoader {
  inherit ix config lib;
  name = "paper";
  dropinDir = "plugins";
  configFragment =
    _:
    let
      cfg = config.services.minecraft;
      versionCatalogs = ix.artifacts.minecraft.paperPluginCatalogs;
    in
    {
      services.minecraft.pluginCatalog =
        if cfg.version != null && builtins.hasAttr cfg.version versionCatalogs then
          versionCatalogs.${cfg.version}
        else
          ix.artifacts.minecraft.paperPluginCatalog;
    };
}
