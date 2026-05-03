# PostgreSQL 18 with performance-tuned defaults.
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
    types
    ;
  cfg = config.services.ix-postgresql;
in
{
  options.services.ix-postgresql = {
    enable = mkEnableOption "PostgreSQL 18";

    port = mkOption {
      type = types.port;
      default = 5432;
    };

    dataDir = mkOption {
      type = types.str;
      default = "/var/lib/postgresql/18";
    };

    extraSettings = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Additional postgresql.conf key-value pairs merged on top of tuned defaults.";
    };
  };

  config = mkIf cfg.enable {
    networking.firewall.allowedTCPPorts = [ cfg.port ];

    services.postgresql = {
      enable = true;
      package = pkgs.postgresql_18;
      inherit (cfg) dataDir port;
      enableJIT = true;
      settings = {
        # connections
        listen_addresses = "*";
        max_connections = "200";

        # memory: tuned for dedicated VM, adjust via extraSettings
        shared_buffers = "256MB";
        effective_cache_size = "768MB";
        work_mem = "4MB";
        maintenance_work_mem = "128MB";

        # WAL
        wal_buffers = "16MB";
        max_wal_size = "2GB";
        min_wal_size = "512MB";
        wal_level = "replica";
        checkpoint_completion_target = "0.9";

        # query planner
        random_page_cost = "1.1"; # SSD
        effective_io_concurrency = "200"; # SSD
        default_statistics_target = "100";

        # parallelism
        max_worker_processes = "4";
        max_parallel_workers_per_gather = "2";
        max_parallel_workers = "4";
        max_parallel_maintenance_workers = "2";

        # logging
        log_min_duration_statement = "1000"; # log queries over 1s

        # huge pages: let the kernel decide
        huge_pages = "try";

        # JIT: compile complex queries
        jit = "on";
      } // cfg.extraSettings;
    };
  };
}
