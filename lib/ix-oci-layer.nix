# OCI layer: builds the final OCI archive from the NixOS system closure.
#
# The closure is split into ~67 OCI layers (`streamLayeredImage`) so the
# registry deduplicates shared store paths across images. A `systemRoot`
# layer adds FHS symlinks (/bin, /etc, /usr, ...) pointing into the toplevel.
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
    image.name = lib.mkOption {
      type = lib.types.str;
      description = "Image name (the OCI repository).";
    };
    image.tag = lib.mkOption {
      type = lib.types.str;
      default = "latest";
      description = "Image tag.";
    };
    build.ociImage = lib.mkOption {
      type = lib.types.package;
      internal = true;
    };
  };

  config = {
    ix.profiles.base.enable = lib.mkDefault true;

    ix.build.ociImage =
      let
        toplevel = config.system.build.toplevel;

        # FHS layout pointing into the NixOS toplevel. dockerTools doesn't
        # ship `/init` or the standard /bin, /etc, /usr paths, so we stage
        # symlinks as a separate input and let dockerTools layer them in.
        systemRoot = pkgs.runCommand "system-root" { __structuredAttrs = true; } ''
          mkdir -p $out
          ln -s ${toplevel}/init $out/init
          ln -s ${toplevel}/etc $out/etc
          ln -s ${toplevel}/sw/bin $out/bin
          ln -s ${toplevel}/sw/sbin $out/sbin
          ln -s ${toplevel}/sw/lib $out/lib
          mkdir -p $out/usr
          ln -s ${toplevel}/sw/bin $out/usr/bin
          ln -s ${toplevel}/sw/lib $out/usr/lib
          ln -s ${toplevel}/sw/sbin $out/usr/sbin
          mkdir -p $out/tmp $out/var $out/run $out/proc $out/sys $out/dev $out/root
        '';

        stream = pkgs.dockerTools.streamLayeredImage {
          name = config.ix.image.name;
          tag = config.ix.image.tag;
          # Below the 127-layer registry limit with headroom for systemRoot
          # plus a few user layers.
          maxLayers = 67;
          contents = [
            toplevel
            systemRoot
          ];
          config.Entrypoint = [ "${toplevel}/init" ];
        };
      in
      pkgs.runCommand "${config.ix.image.name}-oci.tar"
        {
          __structuredAttrs = true;
          nativeBuildInputs = [ pkgs.python3 ];
        }
        ''
          ${stream} | python3 ${./docker-to-oci.py} > "$out"
        '';
  };
}
