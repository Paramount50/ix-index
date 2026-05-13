# OCI layer: builds the final OCI archive from the NixOS system closure.
#
# The closure is split into ~67 OCI layers (`streamLayeredImage`) so the
# registry deduplicates shared store paths across images. A `systemRoot`
# layer adds FHS entries (/bin, /etc, /usr, ...) needed at boot.
#
# nixpkgs only ships a docker-archive streamer, so we transcode to OCI on
# the fly via `docker-to-oci.py`.
{
  config,
  pkgs,
  lib,
  ...
}:
{
  options.ix = {
    image = {
      name = lib.mkOption {
        type = lib.types.str;
        description = "Image name (the OCI repository).";
      };
      tag = lib.mkOption {
        type = lib.types.str;
        default = "latest";
        description = "Image tag.";
      };
    };
    build.ociImage = lib.mkOption {
      type = lib.types.package;
      internal = true;
    };
  };

  config.ix = {
    profiles.base.enable = lib.mkDefault true;

    build.ociImage =
      let
        inherit (config.system.build) toplevel;

        # FHS layout pointing into the NixOS toplevel. Keep activation-owned
        # paths writable: NixOS first boot populates /etc and creates /bin/sh
        # and /usr/bin/env, so those cannot be symlinks into the immutable store.
        systemRoot = pkgs.runCommand "system-root" { } ''
          mkdir -p $out
          ln -s ${toplevel}/init $out/init
          mkdir -p $out/etc
          mkdir -p $out/bin
          ln -s ${toplevel}/sw/sbin $out/sbin
          ln -s ${toplevel}/sw/lib $out/lib
          mkdir -p $out/usr/bin
          ln -s ${toplevel}/sw/lib $out/usr/lib
          ln -s ${toplevel}/sw/sbin $out/usr/sbin
          mkdir -p $out/tmp $out/var $out/run $out/proc $out/sys $out/dev $out/root
        '';

        stream = pkgs.dockerTools.streamLayeredImage {
          inherit (config.ix.image) name tag;
          # Below the 127-layer registry limit with headroom for systemRoot
          # plus a few user layers.
          maxLayers = 67;
          contents = [ systemRoot ];
          config.Entrypoint = [ "${toplevel}/init" ];
        };
      in
      pkgs.runCommand "${config.ix.image.name}-oci.tar" { nativeBuildInputs = [ pkgs.python3 ]; } ''
        ${stream} | python3 ${./docker-to-oci.py} > "$out"
      '';
  };
}
