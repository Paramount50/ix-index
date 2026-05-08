# Helper for declaring a minecraft loader module (Fabric, Paper, Vanilla, ...).
#
# Each loader is structurally identical: declare options under
# `services.minecraft.<name>`, fetch a server jar, and assign it to
# `services.minecraft.serverJar`. Only the URL shape and the per-loader
# fields differ.
#
# Reached from modules via `specialArgs.ix.mkMinecraftLoader`. Loader files
# call it and return the resulting module attrset directly.
{
  config,
  lib,
  pkgs,
  name,
  urlFor,
  dropDir ? "mods",
  extraOptions ? { },
}:
let
  cfg = config.services.minecraft.${name};
in
{
  options.services.minecraft.${name} = {
    enable = lib.mkEnableOption "${name} server jar";
    src = lib.mkOption {
      type = lib.types.path;
      description = "Locked server jar artifact.";
    };
  }
  // extraOptions;

  config = lib.mkIf cfg.enable {
    services.minecraft.enable = lib.mkDefault true;
    services.minecraft.dropDir = lib.mkDefault dropDir;
    services.minecraft.serverJar = cfg.src;
  };
}
