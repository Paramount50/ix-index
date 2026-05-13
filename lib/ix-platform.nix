# Target platform applied to every image.
#
# All images run on EPYC Gen 5 (Turin, Zen 5). Setting hostPlatform.gcc.arch
# propagates -march=znver5 -mtune=znver5 to every package in the closure.
# No binary cache hits: everything builds from source.
{ config, lib, ... }:
{
  options.ix.networking = {
    eastWest = {
      hostName = lib.mkOption {
        type = lib.types.str;
        default = config.networking.hostName;
      };
      firewall.allowedTCPPorts = lib.mkOption {
        type = lib.types.listOf lib.types.port;
        default = [ ];
      };
    };

    northSouth.firewall = {
      allowedTCPPorts = lib.mkOption {
        type = lib.types.listOf lib.types.port;
        default = [ ];
      };
      allowedUDPPorts = lib.mkOption {
        type = lib.types.listOf lib.types.port;
        default = [ ];
      };
    };
  };

  config = {
    nixpkgs.hostPlatform = {
      system = "x86_64-linux";
      # TODO: add back znver5 tuning for EPYC Gen 5
      # gcc = {
      #   arch = "znver5";
      #   tune = "znver5";
      # };
    };

    boot.isContainer = true;
    networking = {
      # ix provisions the guest address, route, and DNS before systemd reaches
      # normal service startup. Leaving NixOS DHCP enabled makes dhcpcd wait
      # for a lease that will never arrive, which keeps network-online.target
      # pending and blocks services such as minecraft.
      useDHCP = false;

      # In-guest firewall is the NixOS nftables backend, enforcing each
      # module's `services.*.openFirewall` and `networking.firewall.allowed*`
      # declarations. ix VMs are `boot.isContainer = true` and share the
      # host's linux-ix kernel (CONFIG_NF_TABLES); nft rules run in this
      # container's own net namespace.
      #
      # This is defense in depth, not the trust boundary. Per-VM
      # north-south ingress filtering is being built on the ix host against
      # the VM's public /128 and the `ix.networking.northSouth` options
      # below; the image declares ports, ix enforces. See
      # https://github.com/indexable-inc/index/issues/41.
      firewall.enable = true;
    };
    system.stateVersion = "25.05";
  };
}
