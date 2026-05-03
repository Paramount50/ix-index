# Minecraft server runtime.
#
# Loader-agnostic. Provides systemd unit, server.properties templating, mods,
# Java runtime, port. `serverJar` is required: a loader module (`./fabric.nix`,
# `./paper.nix`, `./vanilla.nix`, ...) supplies it via module merging.
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
  cfg = config.services.minecraft;

  dataDir = "/var/lib/minecraft";

  # Pin server-port so the systemd-managed firewall and the running server agree.
  propsFile = pkgs.writeText "server.properties" (
    ix.toProperties (cfg.serverProperties // { server-port = cfg.port; })
  );

  modLinks = lib.concatMapStrings (mod: "ln -sf ${mod} ${dataDir}/mods/\n") cfg.mods;

  javaArgs = [
    "${cfg.javaPackage}/bin/java"
    "-Xms${cfg.memory}"
    "-Xmx${cfg.memory}"
  ]
  ++ cfg.jvmFlags
  ++ [
    "-jar"
    "${cfg.serverJar}"
    "nogui"
  ];
in
{
  options.services.minecraft = {
    enable = mkEnableOption "Minecraft server runtime";

    serverJar = mkOption {
      type = types.package;
      description = "Server jar to launch. Set by a loader module (fabric/paper/vanilla).";
    };

    memory = mkOption {
      type = types.str;
      default = "2G";
    };

    mods = mkOption {
      type = types.listOf types.package;
      default = [ ];
    };

    javaPackage = mkOption {
      type = types.package;
      default = pkgs.graalvmPackages.graalvm-ce;
    };

    jvmFlags = mkOption {
      type = types.listOf types.str;
      default = [
        # Aikar's flags: https://mcflags.emc.gs
        "-XX:+UseG1GC"
        "-XX:+ParallelRefProcEnabled"
        "-XX:MaxGCPauseMillis=200"
        "-XX:+DisableExplicitGC" # prevent plugins from triggering full GC
        "-XX:+AlwaysPreTouch" # zero pages at startup so allocation never page-faults

        # large young gen: MC allocates heavily per tick, then discards
        "-XX:G1NewSizePercent=30"
        "-XX:G1MaxNewSizePercent=40"
        "-XX:G1HeapRegionSize=8M" # fewer regions = less bookkeeping
        "-XX:G1ReservePercent=20" # headroom so promotion doesn't force emergency collection

        # mixed GC tuning: reclaim old-gen without long pauses
        "-XX:G1MixedGCCountTarget=4"
        "-XX:InitiatingHeapOccupancyPercent=15" # start concurrent mark early
        "-XX:G1MixedGCLiveThresholdPercent=90"
        "-XX:G1RSetUpdatingPauseTimePercent=5"

        "-XX:SurvivorRatio=32" # tiny survivor spaces: most objects die in eden
        "-XX:+PerfDisableSharedMem" # avoid mmap that causes GC stalls on some filesystems
        "-XX:MaxTenuringThreshold=1" # promote survivors immediately, don't copy between survivor spaces

        "-Dusing.aikars.flags=https://mcflags.emc.gs"
        "-Daikars.new.flags=true"
      ];
      description = "JVM flags used after heap sizing and before -jar.";
    };

    serverProperties = mkOption {
      type = types.attrsOf types.str;
      default = { };
    };

    port = mkOption {
      type = types.port;
      default = 25565;
    };
  };

  config = mkIf cfg.enable {
    networking.firewall.allowedTCPPorts = [ cfg.port ];

    systemd.services.minecraft = {
      description = "Minecraft server";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        WorkingDirectory = dataDir;
        ExecStart = lib.escapeShellArgs javaArgs;
        Restart = "on-failure";
      };
      preStart = ''
        mkdir -p ${dataDir}/mods
        ln -sf ${propsFile} ${dataDir}/server.properties
        echo "eula=true" > ${dataDir}/eula.txt
        ${modLinks}
      '';
    };
  };
}
