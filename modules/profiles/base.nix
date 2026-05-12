# Base runtime profile.
#
# Auto-enabled by `lib/ix-base.nix` so every image has the runtime tools needed
# for source switches. Images that want a smaller closure can opt out with
# `ix.profiles.base.enable = false;`.
{
  config,
  lib,
  pkgs,
  ...
}:
{
  options.ix.profiles.base.enable = lib.mkEnableOption "base runtime tools for source switches";

  config = lib.mkIf config.ix.profiles.base.enable {
    environment.systemPackages = builtins.attrValues {
      # `ix switch --source` relies on these being present after the first
      # switch. Developer tools belong in the specific image that needs them.
      inherit (pkgs)
        gzip
        gnutar
        zstd
        ;
    };
  };
}
