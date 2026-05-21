{
  config,
  ix,
  lib,
  pkgs,
  ...
}:
let
  dataDir = "/var/lib/daily-scraper";
  scraper = {
    package = import ./package.nix { inherit ix lib pkgs; };
    repository = "indexable-inc/index";
    githubApiUrl = "https://api.github.com";
    userAgent = "ix-daily-scraper-example/0.1";
    schedule = "*-*-* 03:17:00 UTC";
    randomizedDelaySec = "20m";
    extraArgs = [ ];
    environment = { };
    inherit dataDir;
    outputDir = "${dataDir}/parquet";
    s3 = {
      uri = null;
      deleteRemoved = false;
      awsEnvironmentFile = null;
    };
  };

  systemctl = lib.getExe' config.systemd.package "systemctl";

  scraperArgs = [
    (lib.getExe scraper.package)
    "--output-dir"
    scraper.outputDir
    "--repo"
    scraper.repository
    "--github-api-url"
    scraper.githubApiUrl
    "--user-agent"
    scraper.userAgent
  ]
  ++ scraper.extraArgs;

  environment = [
    "PYTHONUNBUFFERED=1"
  ]
  ++ lib.mapAttrsToList (name: value: "${name}=${value}") scraper.environment;

  s3Args = [
    (lib.getExe pkgs.awscli2)
    "s3"
    "sync"
    "--only-show-errors"
    scraper.outputDir
    scraper.s3.uri
  ]
  ++ lib.optionals scraper.s3.deleteRemoved [ "--delete" ];
in
{
  environment.systemPackages = [ scraper.package ];

  ix.healthChecks.daily-scraper = {
    from = "guest";
    description = "Daily scraper timer is active";
    command = [
      systemctl
      "is-active"
      "--quiet"
      "daily-scraper.timer"
    ];
  };

  systemd.services.daily-scraper = {
    description = "Daily Python data scraper";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig =
      ix.systemdHardening
      // {
        Type = "oneshot";
        DynamicUser = true;
        StateDirectory = "daily-scraper";
        StateDirectoryMode = "0750";
        WorkingDirectory = scraper.dataDir;
        ExecStart = lib.escapeShellArgs scraperArgs;
        Environment = environment;
      }
      // lib.optionalAttrs (scraper.s3.uri != null) {
        ExecStartPost = lib.escapeShellArgs s3Args;
      }
      // lib.optionalAttrs (scraper.s3.awsEnvironmentFile != null) {
        LoadCredential = [ "aws-env:${scraper.s3.awsEnvironmentFile}" ];
        EnvironmentFile = "%d/aws-env";
      };
  };

  systemd.timers.daily-scraper = {
    description = "Run the daily Python scraper";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = scraper.schedule;
      Persistent = true;
      RandomizedDelaySec = scraper.randomizedDelaySec;
      AccuracySec = "5m";
      Unit = "daily-scraper.service";
    };
  };
}
