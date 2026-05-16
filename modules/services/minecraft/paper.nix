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
  dropDir = "plugins";
  configFragment = _: {
    services.minecraft.pluginCatalog = ix.artifacts.minecraft.paperPluginCatalog;
  };
}
