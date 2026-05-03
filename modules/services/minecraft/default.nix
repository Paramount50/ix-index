# Minecraft server runtime.
#
# Loader-agnostic. Provides systemd unit, server.properties templating, mods,
# JDK, port. `serverJar` is required: a loader module (`./fabric.nix`,
# `./paper.nix`, `./vanilla.nix`, ...) supplies it via module merging.
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
  cfg = config.services.minecraft;

  dataDir = "/var/lib/minecraft";

  # Caller-provided properties first; we then pin server-port so the
  # systemd-managed firewall and the running server agree.
  propsFile = pkgs.writeText "server.properties" (
    lib.concatStringsSep "\n" (
      lib.mapAttrsToList (k: v: "${k}=${v}") (
        cfg.serverProperties // { server-port = toString cfg.port; }
      )
    )
  );

  modLinks = lib.concatMapStrings (mod: "ln -sf ${mod} ${dataDir}/mods/\n") cfg.mods;
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

    jdk = mkOption {
      type = types.package;
      default = pkgs.temurin-jre-bin-25;
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
        ExecStart = "${cfg.jdk}/bin/java -Xms1G -Xmx${cfg.memory} -jar ${cfg.serverJar} nogui";
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
