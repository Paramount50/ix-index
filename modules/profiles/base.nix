# Base runtime profile.
#
# Auto-enabled by `lib/ix-oci-layer.nix`. Ships cross-cutting CLI that should
# be available on every VM for debugging and introspection. Image-specific
# runtime dependencies still belong in the image or service that needs them.
{
  config,
  lib,
  pkgs,
  ...
}:
{
  options.ix.profiles.base.enable = lib.mkEnableOption "base runtime tools";

  config = lib.mkIf config.ix.profiles.base.enable {
    environment.systemPackages = builtins.attrValues {
      inherit (pkgs)
        bpftrace
        btop
        file
        gdb
        jq
        lldb
        lsof
        ncdu
        pv
        strace
        tcpdump
        ;
    };
  };
}
