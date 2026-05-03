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
  extraOptions ? _: { },
}:
let
  cfg = config.services.minecraft.${name};
in
{
  options.services.minecraft.${name} = {
    enable = lib.mkEnableOption "${name} server jar";
    hash = lib.mkOption {
      type = lib.types.str;
      description = "SRI hash of the server jar (sha256-...=).";
    };
  } // (extraOptions lib);

  config = lib.mkIf cfg.enable {
    services.minecraft.enable = lib.mkDefault true;
    services.minecraft.serverJar = pkgs.fetchurl {
      url = urlFor cfg;
      inherit (cfg) hash;
    };
  };
}
