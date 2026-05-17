# Target platform applied to every image.
#
# All images run on EPYC Gen 5 (Turin, Zen 5). Setting hostPlatform.gcc.arch
# propagates -march=znver5 -mtune=znver5 to every package in the closure.
# No binary cache hits: everything builds from source.
{ config, lib, ... }:
let
  portClaimType = lib.types.submodule (
    { name, ... }:
    {
      options = {
        protocol = lib.mkOption {
          type = lib.types.enum [
            "tcp"
            "udp"
          ];
          description = "Transport protocol claimed by this listener.";
        };

        port = lib.mkOption {
          type = lib.types.port;
          description = "Port claimed by this listener.";
        };

        address = lib.mkOption {
          type = lib.types.str;
          default = "*";
          description = "Bind address. Use * when the service binds every address or the bind behavior is implicit.";
        };

        namespace = lib.mkOption {
          type = lib.types.str;
          default = "default";
          description = "Network namespace for this listener. Ordinary image services use the default namespace.";
        };

        description = lib.mkOption {
          type = lib.types.str;
          default = name;
          description = "Human-readable listener owner used in collision errors.";
        };
      };
    }
  );

  portClaims = lib.mapAttrsToList (
    name: claim: claim // { inherit name; }
  ) config.ix.networking.portClaims;
  claimKey = claim: "${claim.namespace}/${claim.protocol}/${toString claim.port}";
  portClaimGroups = builtins.groupBy claimKey portClaims;
  isIpv4Address = address: lib.hasInfix "." address;
  isIpv6Address = address: lib.hasInfix ":" address;
  addressOverlaps =
    left: right:
    left == "*"
    || right == "*"
    || left == right
    || (left == "0.0.0.0" && !(isIpv6Address right))
    || (right == "0.0.0.0" && !(isIpv6Address left))
    || (left == "::" && !(isIpv4Address right))
    || (right == "::" && !(isIpv4Address left));
  groupConflicts =
    claims:
    lib.any (
      left: lib.any (right: left.name != right.name && addressOverlaps left.address right.address) claims
    ) claims;
  conflictingPortClaimGroups = lib.filterAttrs (_: groupConflicts) portClaimGroups;
  renderPortClaim = claim: "${claim.name} (${claim.address}, ${claim.description})";
  renderPortClaimConflict =
    key: claims: "${key}: ${lib.concatMapStringsSep ", " renderPortClaim claims}";
in
{
  options.ix.networking.portClaims = lib.mkOption {
    type = lib.types.attrsOf portClaimType;
    default = { };
    description = ''
      Sockets claimed by repo-owned service modules inside this image.

      The registry catches same-namespace listener collisions at eval time.
      Use separate fleet nodes or an explicit alternate port when two services
      need the same public protocol port.
    '';
  };

  # Networking policy (per-port filtering, L7, WAF, rate limiting, gateway
  # behavior) belongs to the image, not to ix. ix exposes two primitives:
  # east-west group membership (which VMs can reach each other) and
  # north-south on/off (whether the VM has internet ingress / egress).
  # Anything finer lives in `networking.firewall.*` inside the image, in a
  # sidecar, or behind a user-built gateway VM. `eastWest.hostName` stays
  # here because it is a name, not a policy.
  options.ix.networking.eastWest.hostName = lib.mkOption {
    type = lib.types.str;
    default = config.networking.hostName;
  };

  config = {
    assertions = [
      {
        assertion = conflictingPortClaimGroups == { };
        message = ''
          ix.networking.portClaims has same-namespace port collisions:
            ${lib.concatStringsSep "\n  " (
              lib.mapAttrsToList renderPortClaimConflict conflictingPortClaimGroups
            )}

          Put services that need the same public protocol port in separate fleet nodes/VMs, or choose an explicit alternate port when same-image co-location is intentional.
        '';
      }
    ];

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
      # This is the primary mechanism for port-level policy. ix provides only
      # the coarse primitives (east-west group membership, north-south
      # on/off); per-port allowlists, L7, WAF, rate limiting, etc. live here
      # in the image or in a user-built gateway VM. The "primitives only"
      # rule is recorded in `ix/AGENTS.md` under "Architecture that must not
      # drift". Tracking the ix-side north-south primitive in
      # https://github.com/indexable-inc/index/issues/41.
      firewall.enable = true;
    };
    system.stateVersion = "25.05";
  };
}
