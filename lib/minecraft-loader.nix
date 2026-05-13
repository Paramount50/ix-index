# Helper for declaring a minecraft loader module (Fabric, Paper, Vanilla, ...).
#
# Each loader is structurally identical: declare options under
# `services.minecraft.<name>` and assign a locked server jar to
# `services.minecraft.serverJar`. The jar comes from a flake artifact input,
# either supplied explicitly as `src` or by a loader-specific default.
#
# Reached from modules via `specialArgs.ix.mkMinecraftLoader`. Loader files
# call it and return the resulting module attrset directly. Loaders that need
# to contribute more to `config` pass an `extraConfig cfg` hook; it merges into
# the gated config so the loader file stays a single expression.
{
  config,
  lib,
  name,
  dropDir ? "mods",
  extraOptions ? { },
  srcDefault ? null,
  extraConfig ? _: { },
}:
let
  cfg = config.services.minecraft.${name};
  srcOption = {
    type = lib.types.path;
    description = "Locked server jar artifact.";
  }
  // lib.optionalAttrs (srcDefault != null) {
    default = srcDefault cfg;
  };
in
{
  options.services.minecraft.${name} = {
    enable = lib.mkEnableOption "${name} server jar";
    src = lib.mkOption srcOption;
  }
  // extraOptions;

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        services.minecraft = {
          enable = lib.mkDefault true;
          dropDir = lib.mkDefault dropDir;
          serverJar = cfg.src;
        };
      }
      (extraConfig cfg)
    ]
  );
}
