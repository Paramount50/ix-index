# Minestom server runtime.
#
# Runs a user-built fat jar. Unlike the Minecraft module, there are no loaders,
# mods, or EULA: Minestom is a from-scratch server library.
{
  config,
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
  cfg = config.services.minestom;

  dataDir = "/var/lib/minestom";
  java = lib.getExe' cfg.javaPackage "java";

  javaArgs = [
    java
    "-XX:MaxRAMPercentage=${toString cfg.maxRAMPercentage}"
  ]
  ++ cfg.jvmFlags
  ++ [
    "-jar"
    "${cfg.serverJar}"
  ];
in
{
  options.services.minestom = {
    enable = mkEnableOption "Minestom server";

    serverJar = mkOption {
      type = types.package;
      description = "Fat jar to launch. Built from a Gradle/Maven project that depends on Minestom.";
    };

    maxRAMPercentage = mkOption {
      type = types.int;
      default = 85;
    };

    javaPackage = mkOption {
      type = types.package;
      default = pkgs.temurin-jre-bin-25;
    };

    jvmFlags = mkOption {
      type = types.listOf types.str;
      default = [ ];
    };

    port = mkOption {
      type = types.port;
      default = 25565;
    };
  };

  config = mkIf cfg.enable {
    networking.firewall.allowedTCPPorts = [ cfg.port ];

    systemd.services.minestom = {
      description = "Minestom server";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        WorkingDirectory = dataDir;
        ExecStart = lib.escapeShellArgs javaArgs;
        Restart = "on-failure";
        StateDirectory = "minestom";

        CapabilityBoundingSet = [ "" ];
        DeviceAllow = [ "" ];
        LockPersonality = true;
        PrivateDevices = true;
        PrivateTmp = true;
        PrivateUsers = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        UMask = "0077";
      };
    };
  };
}
