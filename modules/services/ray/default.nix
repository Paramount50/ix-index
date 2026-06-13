# One Ray cluster spanning the tailnet, plus the ix-mcp engine that drives it.
#
# Deployment side of the `fleet` Python module bundled in ix-mcp:
# `fleet.run`/`fleet.submit` ship cloudpickled callables to Ray and the Ray
# object store (Plasma) carries the data; `fleet.in_kernel` runs code in a
# node's live ix-mcp session over the token-gated `/api/exec`.
#
# Topology: ONE Ray cluster. Exactly one node sets `role = "head"` (it holds the
# GCS); the rest are `role = "worker"` pointing `headAddress` at the head's
# tailscale IP. Daemons bind their *tailscale* IPv4 (runtime host state), so the
# cluster lives on the tailnet, which is also the trust boundary (Ray has no
# per-call auth of its own).
#
# The node-level correctness here (pinned inter-node ports, a SHORT `/run/ray`
# temp-dir so Ray's AF_UNIX plasma socket stays under the 108-byte sun_path
# limit, and PrivateDevices/PrivateUsers off so an attaching kernel can map the
# shared-memory object store) mirrors the proven `examples/ray-cluster`
# cluster-node module. We use nixpkgs `python3Packages.ray` -- the same Ray the
# ix-mcp interpreter imports, so the cluster and the kernels driving it run an
# identical version (Ray requires matching versions cluster-wide) and the
# daemons are FHS-correct with no nix-ld shim.
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

  cfg = config.services.ix-ray;

  # Spill target lives on real disk (the StateDirectory), NOT under the tmpfs
  # `/run/ray` temp-dir -- otherwise "spill to disk under memory pressure" would
  # just consume RAM. directory_path is created by Ray under the StateDirectory.
  spillDir = "/var/lib/ray/spill";
  spillConfig = builtins.toJSON {
    type = "filesystem";
    params.directory_path = spillDir;
  };

  ray = lib.getExe' cfg.package "ray";

  # Mode-specific `ray start` flags. Common flags (pinned ports, temp-dir, spill,
  # --node-ip-address, --block) are appended in the launcher once the tailscale
  # IP is resolved. Ray's web dashboard needs the `ray[default]` extras nixpkgs
  # core ray omits, so it is disabled; cluster state comes from `fleet.nodes()`.
  modeArgs =
    if cfg.role == "head" then
      [
        "--head"
        "--port"
        (toString cfg.gcsPort)
        "--include-dashboard"
        "false"
      ]
    else
      [
        "--address"
        "${cfg.headAddress}:${toString cfg.gcsPort}"
      ];

  commonArgs = [
    "--node-manager-port"
    (toString cfg.nodeManagerPort)
    "--object-manager-port"
    (toString cfg.objectManagerPort)
    "--min-worker-port"
    (toString cfg.workerPortLow)
    "--max-worker-port"
    (toString cfg.workerPortHigh)
    "--temp-dir"
    "/run/ray"
    "--object-spilling-config"
    spillConfig
  ]
  ++ optionals (cfg.objectStoreMemory != null) [
    "--object-store-memory"
    (toString cfg.objectStoreMemory)
  ];

  startArgsNu = "[ ${lib.concatMapStringsSep " " builtins.toJSON (modeArgs ++ commonArgs)} ]";

  # Resolve this node's tailscale IPv4 at runtime (it is host state, not a Nix
  # value), fail loudly if tailscale is not up, then exec `ray start` bound to
  # it. `--block` keeps the daemon in the foreground for systemd Type=simple.
  rayLauncher = ix.writeNushellApplication pkgs {
    name = "ix-ray-launch";
    meta.description = "Resolve this node's tailscale IPv4 and exec the ray daemon bound to it";
    runtimeInputs = [
      pkgs.tailscale
      cfg.package
    ];
    text = ''
      def main [] {
        let ip = (do --ignore-errors {
          ^tailscale ip -4 | lines | where ($it | str trim | is-not-empty) | first
        } | default "")
        if ($ip | str trim | is-empty) {
          print --stderr "ix-ray: no tailscale IPv4 yet; is tailscaled up?"
          exit 1
        }
        let args = [ ...${startArgsNu} "--node-ip-address" $ip "--block" ]
        exec ${ray} ...$args
      }
    '';
  };

  # The ix-mcp engine (no MCP transport: `notebook` is the daemon shape). Its
  # kernel auto-connects to the local Ray, and its dashboard data API exposes the
  # token-gated `/api/exec` that `fleet.in_kernel` reaches on `execPort`.
  notebookEnv = {
    IX_MCP_DASHBOARD_PORT = toString cfg.execPort;
    IX_FLEET_EXEC_PORT = toString cfg.execPort;
  }
  // optionalAttrs (cfg.tokenFile != null) {
    IX_MCP_EXEC_TOKEN_FILE = toString cfg.tokenFile;
  };
in
{
  options.services.ix-ray = {
    enable = mkEnableOption "Ray cluster node + ix-mcp engine for the `fleet` distributed API";

    role = mkOption {
      type = types.enum [
        "head"
        "worker"
      ];
      default = "worker";
      description = ''
        This node's role in the single cluster. Exactly one node must be `head`
        (it runs the GCS); every other node is a `worker` and must set
        {option}`services.ix-ray.headAddress`.
      '';
    };

    headAddress = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "100.64.0.1";
      description = ''
        The head node's tailscale IPv4. Required on workers (they join
        `<headAddress>:<gcsPort>`); must be null on the head.
      '';
    };

    package = mkPackageOption pkgs.python3Packages "ray" {
      extraDescription = ''
        The `ray` daemon, from the same nixpkgs pin as the ray bundled in the
        ix-mcp interpreter, so the cluster and the kernels driving it run an
        identical Ray version (required cluster-wide).
      '';
    };

    gcsPort = mkOption {
      type = types.port;
      default = 6379;
      description = "Head GCS port; workers connect here.";
    };

    nodeManagerPort = mkOption {
      type = types.port;
      default = 6380;
      description = "Ray node-manager port (inter-node scheduling). Pinned so the firewall can name it.";
    };

    objectManagerPort = mkOption {
      type = types.port;
      default = 6381;
      description = "Ray object-manager port (object-store transfers). Pinned so the firewall can name it.";
    };

    workerPortLow = mkOption {
      type = types.port;
      default = 10002;
      description = "Low end of the pinned per-worker port range (inter-node worker RPC).";
    };

    workerPortHigh = mkOption {
      type = types.port;
      default = 10031;
      description = "High end of the pinned per-worker port range.";
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
        autodetect (~30% of RAM). Either way Ray spills to disk under
        `${spillDir}` when the store fills, so referenced objects are not lost.
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
        Open the inter-node Ray ports (node/object manager, worker range), the
        exec port, and on the head the GCS port. Usually unnecessary on a tailnet
        where peers reach each other directly, but required if a firewall guards
        the tailscale interface.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.role == "head" -> cfg.headAddress == null;
        message = "services.ix-ray: the head node must not set headAddress.";
      }
      {
        assertion = cfg.role == "worker" -> cfg.headAddress != null;
        message = "services.ix-ray: a worker must set headAddress to the head's tailscale IP.";
      }
    ];

    ix.networking.portClaims = {
      ix-ray-exec = {
        protocol = "tcp";
        port = cfg.execPort;
        description = "ix-mcp /api/exec (fleet.in_kernel)";
      };
      ix-ray-node-manager = {
        protocol = "tcp";
        port = cfg.nodeManagerPort;
        description = "Ray node manager (inter-node scheduling)";
      };
      ix-ray-object-manager = {
        protocol = "tcp";
        port = cfg.objectManagerPort;
        description = "Ray object manager (object-store transfers)";
      };
    }
    // optionalAttrs (cfg.role == "head") {
      ix-ray-gcs = {
        protocol = "tcp";
        port = cfg.gcsPort;
        description = "Ray GCS (workers join here)";
      };
    };

    networking.firewall = mkIf cfg.openFirewall {
      allowedTCPPorts = [
        cfg.execPort
        cfg.nodeManagerPort
        cfg.objectManagerPort
      ]
      ++ optional (cfg.role == "head") cfg.gcsPort;
      allowedTCPPortRanges = [
        {
          from = cfg.workerPortLow;
          to = cfg.workerPortHigh;
        }
      ];
    };

    ix.healthChecks.ix-ray = {
      from = "guest";
      description = "Ray node is up and attached to the cluster";
      command = [
        ray
        "status"
        "--address"
        "127.0.0.1:${toString cfg.gcsPort}"
      ];
    };

    systemd.services.ix-ray = {
      description = "ix-ray Ray ${cfg.role}";
      after = [
        "network-online.target"
        "tailscaled.service"
      ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      environment = {
        HOME = "/run/ray";
        RAY_DISABLE_USAGE_STATS = "1";
      };
      serviceConfig = ix.systemdHardening // {
        Type = "simple";
        ExecStart = lib.getExe rayLauncher;
        Restart = "on-failure";
        RestartSec = 5;
        DynamicUser = true;
        RuntimeDirectory = "ray";
        StateDirectory = "ray";
        WorkingDirectory = "/run/ray";
        # Ray's object store is host shared memory and an attaching kernel maps it
        # from outside this unit's namespace; a private /dev (hence /dev/shm) or
        # user namespace would block that, so both are disabled here.
        PrivateDevices = false;
        PrivateUsers = false;
      };
    };

    systemd.services.ix-ray-notebook = mkIf cfg.notebook.enable {
      description = "ix-mcp engine driving the fleet Ray cluster";
      after = [
        "network-online.target"
        "ix-ray.service"
      ];
      wants = [ "network-online.target" ];
      requires = [ "ix-ray.service" ];
      wantedBy = [ "multi-user.target" ];
      environment = notebookEnv;
      serviceConfig = ix.systemdHardening // {
        Type = "simple";
        ExecStart = lib.getExe' ix.packages.mcp "ix-notebook";
        Restart = "on-failure";
        RestartSec = 5;
        StateDirectory = "ix-ray-notebook";
        WorkingDirectory = "/var/lib/ix-ray-notebook";
      };
    };
  };
}
