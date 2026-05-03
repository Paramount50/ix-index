# Vanilla server jar. https://www.minecraft.net
# Mojang's manifest is dynamic, so we take the URL directly instead of
# modeling the piston-meta lookup. Find URLs at
# https://piston-meta.mojang.com/mc/game/version_manifest_v2.json.
{
  ix,
  config,
  lib,
  pkgs,
  ...
}:
ix.mkMinecraftLoader {
  inherit config lib pkgs;
  name = "vanilla";
  urlFor = cfg: cfg.url;
  extraOptions = {
    url = lib.mkOption {
      type = lib.types.str;
      description = "Direct URL to the Mojang server jar.";
    };
  };
}
