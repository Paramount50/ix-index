# One Ray cluster spanning the tailnet, plus the ix-mcp engine that drives it.
#
# This is the deployment side of the `fleet` Python module bundled in ix-mcp.
# `fleet.run`/`fleet.submit` ship cloudpickled callables to Ray and the Ray
# object store (Plasma: zero-copy on-node, peer-to-peer transfer between nodes,
# spill-to-disk under memory pressure) carries the data; `fleet.in_kernel` runs
# code in a node's live ix-mcp session over the token-gated `/api/exec`. For
# either to work cluster-wide, every node needs (a) a Ray daemon attached to one
# cluster and (b) an ix-mcp engine whose kernel can `ray.init(address="auto")`.
# This module wires both.
#
# Topology: ONE Ray cluster. Exactly one node sets `role = "head"` (it holds the
# GCS); the rest set `role = "worker"` and point `headAddress` at the head's
# tailscale IP. The control plane is centralized on the head, but object
# transfer between workers is peer-to-peer. All daemons bind their *tailscale*
# IPv4 (resolved at runtime, since it is host state, not a Nix value), so the
# cluster lives entirely on the tailnet -- which is also the trust boundary, as
# Ray has no per-call auth of its own.
{
  config,
  ix,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    mkPackageOption
    optional
    optionalAttrs
    optionals
    types
    ;

  cfg = config.services.ix-fleet;
  dataDir = "/var/lib/ray";

  # Ray binds its tailscale IPv4, which is runtime host state (not known at Nix
  # eval), so every daemon is launched through this wrapper: resolve the IP, fail
  # loudly if tailscale is not up (a daemon on the wrong interface would silently
  # never join), then exec the real command with the __IP__ placeholder in its
  # args replaced by the resolved address.
  rayLauncher = ix.writeNushellApplication pkgs {
    name = "ix-fleet-launch";
    meta.description = "Resolve this node's tailscale IPv4 and exec a ray daemon bound to it";
    runtimeInputs = [
      pkgs.tailscale
      cfg.package
    ];
    text = ''
      def main [...args: string] {
        let ip = (do --ignore-errors {
          ^tailscale ip -4 | lines | where ($it | str trim | is-not-empty) | first
        } | default "")
        if ($ip | str trim | is-empty) {
          print --stderr "ix-fleet: no tailscale IPv4 yet; is tailscaled up?"
          exit 1
        }
        # `--block` keeps the daemon in the foreground for systemd Type=simple.
        let resolved = ($args | each {|a| $a | str replace --all "__IP__" $ip })
        exec ($resolved | first) ...($resolved | skip 1)
      }
    '';
  };

  ray = lib.getExe' cfg.package "ray";

  headArgs = [
    ray
    "start"
    "--head"
    "--node-ip-address=__IP__"
    "--port=${toString cfg.gcsPort}"
    "--dashboard-host=0.0.0.0"
    "--dashboard-port=${toString cfg.dashboardPort}"
    "--temp-dir=${dataDir}/session"
    "--block"
  ]
  ++ optional (
    cfg.objectStoreMemory != null
  ) "--object-store-memory=${toString cfg.objectStoreMemory}";

  workerArgs = [
    ray
    "start"
    "--address=${cfg.headAddress}:${toString cfg.gcsPort}"
    "--node-ip-address=__IP__"
    "--temp-dir=${dataDir}/session"
    "--block"
  ]
  ++ optional (
    cfg.objectStoreMemory != null
  ) "--object-store-memory=${toString cfg.objectStoreMemory}";

  rayExecStart = lib.escapeShellArgs (
    [ (lib.getExe rayLauncher) ] ++ (if cfg.role == "head" then headArgs else workerArgs)
  );

  # The ix-mcp engine (no MCP transport: `notebook` is the daemon shape). Its
  # kernel auto-connects to the local Ray, and its dashboard data API exposes the
  # token-gated `/api/exec` that `fleet.in_kernel` reaches on `execPort`.
  notebookEnv = {
    # Bind the data API to the tailscale IP (cli falls back to it when unset, but
    # be explicit) on the fleet-wide exec port the `fleet` module expects.
    IX_MCP_DASHBOARD_PORT = toString cfg.execPort;
    IX_FLEET_EXEC_PORT = toString cfg.execPort;
  }
  // optionalAttrs (cfg.tokenFile != null) {
    IX_MCP_EXEC_TOKEN_FILE = toString cfg.tokenFile;
  };
in
{
  options.services.ix-fleet = {
    enable = mkEnableOption "Ray cluster node + ix-mcp engine for the `fleet` distributed API";

    role = mkOption {
      type = types.enum [
        "head"
        "worker"
      ];
      default = "worker";
      description = ''
        This node's role in the single cluster. Exactly one node in the fleet
        must be `head` (it runs the GCS); every other node is a `worker` and
        must set {option}`services.ix-fleet.headAddress`.
      '';
    };

    headAddress = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "100.64.0.1";
      description = ''
        The head node's tailscale IPv4. Required on workers (they join
        `<headAddress>:<gcsPort>`); ignored on the head.
      '';
    };

    package = mkPackageOption pkgs.python3Packages "ray" {
      extraDescription = ''
        The `ray` daemon. Comes from the same nixpkgs pin as the ray bundled in
        the ix-mcp interpreter, so the cluster and the kernels driving it run the
        identical Ray version (Ray requires matching versions cluster-wide).
      '';
    };

    gcsPort = mkOption {
      type = types.port;
      default = 6379;
      description = "Head GCS port; workers connect here.";
    };

    dashboardPort = mkOption {
      type = types.port;
      default = 8265;
      description = "Ray's own web dashboard port (head only).";
    };

    execPort = mkOption {
      type = types.port;
      default = 8799;
      description = ''
        Port the node's ix-mcp data API (and its `/api/exec`) binds. Must match
        the `fleet` module's `IX_FLEET_EXEC_PORT` (it defaults to this) so peers
        reach each other's live kernels.
      '';
    };

    objectStoreMemory = mkOption {
      type = types.nullOr types.ints.positive;
      default = null;
      example = 8000000000;
      description = ''
        Bytes of RAM for this node's object store (Plasma). Null lets Ray
        autodetect (~30% of RAM); either way Ray spills to disk under
        `${dataDir}/session` when the store fills, so referenced objects are not
        lost.
      '';
    };

    notebook.enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Run the ix-mcp engine on this node so its kernel can drive Ray and
        `fleet.in_kernel` can reach its live session. Turn off on a node that
        should only contribute Ray compute.
      '';
    };

    tokenFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        File holding the shared bearer token that gates `/api/exec`. Hand every
        node the SAME secret. Null leaves the endpoint disabled (Ray still works;
        `fleet.in_kernel` does not). Provide it out of band (sops/agenix or a
        deployed file); it is read at service start, not baked into the store.
      '';
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Open the GCS, Ray dashboard, and exec ports. Usually unnecessary: the
        cluster lives on the tailnet, where peers reach each other directly.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.role == "head" -> cfg.headAddress == null;
        message = "services.ix-fleet: the head node must not set headAddress.";
      }
      {
        assertion = cfg.role == "worker" -> cfg.headAddress != null;
        message = "services.ix-fleet: a worker must set headAddress to the head's tailscale IP.";
      }
    ];

    users.users.ray = {
      isSystemUser = true;
      group = "ray";
      home = dataDir;
      description = "ix-fleet Ray daemon";
    };
    users.groups.ray = { };

    ix.networking.portClaims = {
      ix-fleet-exec = {
        protocol = "tcp";
        port = cfg.execPort;
        description = "ix-mcp /api/exec (fleet.in_kernel)";
      };
    }
    // optionalAttrs (cfg.role == "head") {
      ix-fleet-gcs = {
        protocol = "tcp";
        port = cfg.gcsPort;
        description = "Ray GCS (workers join here)";
      };
      ix-fleet-dashboard = {
        protocol = "tcp";
        port = cfg.dashboardPort;
        description = "Ray web dashboard";
      };
    };

    networking.firewall.allowedTCPPorts = optionals cfg.openFirewall (
      [ cfg.execPort ]
      ++ optionals (cfg.role == "head") [
        cfg.gcsPort
        cfg.dashboardPort
      ]
    );

    ix.healthChecks.ix-fleet = {
      from = "guest";
      description = "Ray node is up and attached to the cluster";
      command = [
        (lib.getExe' cfg.package "ray")
        "status"
        "--address"
        "127.0.0.1:${toString cfg.gcsPort}"
      ];
    };

    systemd.services.ix-fleet-ray = {
      description = "ix-fleet Ray ${cfg.role}";
      after = [
        "network-online.target"
        "tailscaled.service"
      ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = ix.systemdHardening // {
        Type = "simple";
        User = "ray";
        Group = "ray";
        StateDirectory = "ray";
        WorkingDirectory = dataDir;
        ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p ${dataDir}/session";
        ExecStart = rayExecStart;
        # `ray start --block` exits non-zero on stop; restart so a transient GCS
        # blip (head restart) re-joins rather than leaving the node detached.
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    systemd.services.ix-fleet-notebook = mkIf cfg.notebook.enable {
      description = "ix-mcp engine driving the fleet Ray cluster";
      after = [
        "network-online.target"
        "ix-fleet-ray.service"
      ];
      wants = [ "network-online.target" ];
      requires = [ "ix-fleet-ray.service" ];
      wantedBy = [ "multi-user.target" ];
      environment = notebookEnv;
      serviceConfig = ix.systemdHardening // {
        Type = "simple";
        User = "ray";
        Group = "ray";
        StateDirectory = "ray";
        WorkingDirectory = dataDir;
        # The engine alone (kernel + dashboard data API, no MCP transport): the
        # daemon shape. Its `/api/exec` backs fleet.in_kernel; its kernel joins
        # the local Ray on the first `fleet` call.
        ExecStart = "${lib.getExe' ix.packages.mcp "ix-notebook"}";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };
  };
}
