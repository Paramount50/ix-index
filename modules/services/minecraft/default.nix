# Minecraft server runtime.
#
# Loader-agnostic. Provides systemd unit, mods, Java runtime, port.
# `serverJar` and `dropDir` are slots filled by a loader module (fabric,
# folia, neoforge, paper, purpur, spigot, sponge, vanilla) via module merging.
# `dropDir` is where mod jars get symlinked: fabric/neoforge/sponge use
# `mods`, paper/folia/purpur/spigot use `plugins`.
#
# All server config files (server.properties, bukkit.yml, spigot.yml, etc.)
# go through `serverFiles`. Mod config files go through `configFiles` (placed
# under config/).
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
  managedRoot = "/etc/minecraft";

  modCatalogType = types.submodule {
    options = {
      url = mkOption { type = types.str; };
      src = mkOption {
        type = types.path;
        description = "Locked mod artifact.";
      };
    };
  };

  modJars = lib.mapAttrsToList (
    slug: _:
    let
      entry = cfg.modCatalog.${slug} or (throw "mod '${slug}' not in modCatalog");
    in
    {
      name = "${slug}.jar";
      path = entry.src;
    }
  ) cfg.mods;

  loaderEnabled = {
    fabric = config.services.minecraft.fabric.enable;
    folia = config.services.minecraft.folia.enable;
    paper = config.services.minecraft.paper.enable;
    purpur = config.services.minecraft.purpur.enable;
    spigot = config.services.minecraft.spigot.enable;
    sponge = config.services.minecraft.sponge.enable;
  };

  bukkitLoaderEnabled = lib.any (name: loaderEnabled.${name}) [
    "folia"
    "paper"
    "purpur"
    "spigot"
  ];

  autoReloadDriver =
    if cfg.autoReload.driver != "auto" then
      cfg.autoReload.driver
    else if loaderEnabled.fabric then
      "jvm"
    else if bukkitLoaderEnabled then
      "plugman"
    else
      "none";

  autoReloadEnabled = cfg.autoReload.enable && autoReloadDriver != "none";
  jvmReloadEnabled = autoReloadEnabled && autoReloadDriver == "jvm";
  plugmanReloadEnabled = autoReloadEnabled && autoReloadDriver == "plugman";

  managedJars =
    modJars
    ++ lib.optionals plugmanReloadEnabled [
      {
        name = "PlugManX.jar";
        path = ix.artifacts.minecraft.plugins.plugmanx;
      }
    ];

  managedDropins = pkgs.runCommand "minecraft-managed-${cfg.dropDir}" { } (
    ''
      mkdir -p "$out"
    ''
    + lib.concatMapStringsSep "\n" (jar: ''ln -s ${jar.path} "$out/${jar.name}"'') managedJars
  );

  # Infer serialization format from file extension.
  formatFor =
    path:
    let
      ext = lib.last (lib.splitString "." path);
    in
    {
      toml = pkgs.formats.toml { };
      json = pkgs.formats.json { };
      yaml = pkgs.formats.yaml { };
      yml = pkgs.formats.yaml { };
      properties = pkgs.formats.keyValue { };
    }
    .${ext} or (throw "configFiles: unsupported extension .${ext} on '${path}'");

  configLinks = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      path: value:
      let
        file = (formatFor path).generate (builtins.baseNameOf path) value;
      in
      "mkdir -p $out/${builtins.dirOf path}\nln -sf ${file} $out/${path}"
    ) cfg.configFiles
  );

  serverFiles =
    cfg.serverFiles
    // lib.optionalAttrs plugmanReloadEnabled {
      "server.properties" = (cfg.serverFiles."server.properties" or { }) // {
        enable-rcon = true;
        "rcon.port" = cfg.autoReload.rconPort;
        "rcon.password" = cfg.autoReload.rconPassword;
        broadcast-rcon-to-ops = false;
      };
    };

  serverFileLinks = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      path: value:
      let
        file = (formatFor path).generate (builtins.baseNameOf path) value;
      in
      "mkdir -p $out/${builtins.dirOf path}\nln -sf ${file} $out/${path}"
    ) serverFiles
  );

  managedConfig = pkgs.runCommand "minecraft-managed-config" { } ''
    mkdir -p "$out"
    ${configLinks}
  '';

  managedServerFiles = pkgs.runCommand "minecraft-managed-server-files" { } ''
    mkdir -p "$out"
    ${serverFileLinks}
  '';

  syncManaged = pkgs.writeShellApplication {
    name = "minecraft-sync-managed";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
    ];
    text = ''
      data_dir=${lib.escapeShellArg dataDir}
      drop_dir=${lib.escapeShellArg cfg.dropDir}

      sync_tree() {
        source_dir="$1"
        target_dir="$2"
        manifest="$3"

        mkdir -p "$target_dir" "$(dirname "$manifest")"
        if [ -f "$manifest" ]; then
          while IFS= read -r rel; do
            if [ -n "$rel" ]; then
              rm -f "$target_dir/$rel"
            fi
          done < "$manifest"
        fi

        tmp="$manifest.tmp"
        : > "$tmp"
        if [ -d "$source_dir" ]; then
          (
            cd "$source_dir"
            find . \( -type f -o -type l \) -print
          ) | while IFS= read -r rel; do
            rel="''${rel#./}"
            mkdir -p "$target_dir/$(dirname "$rel")"
            ln -sfn "$source_dir/$rel" "$target_dir/$rel"
            printf '%s\n' "$rel" >> "$tmp"
          done
        fi

        mv "$tmp" "$manifest"
      }

      sync_tree ${managedRoot}/managed-dropins "$data_dir/$drop_dir" "$data_dir/.ix-managed-$drop_dir"
      sync_tree ${managedRoot}/managed-config "$data_dir/config" "$data_dir/.ix-managed-config"
      sync_tree ${managedRoot}/managed-server-files "$data_dir" "$data_dir/.ix-managed-server-files"
    '';
  };

  reloadCommand = pkgs.writeShellApplication {
    name = "minecraft-reload";
    runtimeInputs = [
      pkgs.minecraft-rcon
      syncManaged
    ];
    text = ''
      minecraft-sync-managed

      case ${lib.escapeShellArg autoReloadDriver} in
        jvm)
          socket=${lib.escapeShellArg cfg.autoReload.socketPath}
          if [ ! -S "$socket" ]; then
            echo "minecraft hot reload socket is not ready at $socket; synced managed files only" >&2
            exit 0
          fi
          exec ${cfg.javaPackage}/bin/java \
            -cp ${pkgs.minecraft-hot-reload-agent}/share/minecraft-hot-reload-agent/minecraft-hot-reload-agent.jar \
            dev.ix.minecraft.hotreload.HotReloadAgent \
            "$socket" \
            redefine-dir \
            ${managedRoot}/managed-dropins
          ;;
        plugman)
          exec minecraft-rcon \
            --host 127.0.0.1 \
            --port ${toString cfg.autoReload.rconPort} \
            --password ${lib.escapeShellArg cfg.autoReload.rconPassword} \
            plugman reload all
          ;;
        none)
          exit 0
          ;;
        *)
          echo "unsupported minecraft auto reload driver: ${autoReloadDriver}" >&2
          exit 1
          ;;
      esac
    '';
  };

  autoReloadJvmFlags = lib.optionals jvmReloadEnabled [
    "-javaagent:${pkgs.minecraft-hot-reload-agent}/share/minecraft-hot-reload-agent/minecraft-hot-reload-agent.jar=socket=${cfg.autoReload.socketPath}"
    "-XX:+AllowEnhancedClassRedefinition"
  ];

  javaArgs = [
    "${cfg.javaPackage}/bin/java"
    "-XX:MaxRAMPercentage=${toString cfg.maxRAMPercentage}"
  ]
  ++ cfg.jvmFlags
  ++ autoReloadJvmFlags
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

    dropDir = mkOption {
      type = types.str;
      default = "mods";
      description = "Subdirectory under the data dir where mod jars are symlinked. Loaders set this: fabric uses mods, paper uses plugins.";
    };

    maxRAMPercentage = mkOption {
      type = types.int;
      default = 85;
      description = "Max heap as a percentage of available system RAM. The JVM auto-scales to the VM's memory.";
    };

    mods = mkOption {
      type = types.attrsOf types.attrs;
      default = { };
      description = "Mods to install, keyed by Modrinth slug. Empty {} includes the jar with defaults. Attrsets with fields configure the mod (mod modules read these and generate config files).";
    };

    modCatalog = mkOption {
      type = types.attrsOf modCatalogType;
      default = { };
      description = "Slug to locked mod artifact mapping. Set by the image and version overlays from JSON catalogs generated by tools/update-mods.py and flake inputs.";
    };

    javaPackage = mkOption {
      type = types.package;
      default = pkgs.temurin-jre-bin-25;
    };

    jvmFlags = mkOption {
      type = types.listOf types.str;
      default = [
        # Aikar's flags: https://mcflags.emc.gs
        "-XX:+UseG1GC"
        "-XX:+ParallelRefProcEnabled"
        "-XX:MaxGCPauseMillis=200"
        "-XX:+DisableExplicitGC" # prevent plugins from triggering full GC

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

    autoReload = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Reload managed mods/plugins during NixOS switch without restarting the Minecraft service when the active loader has a reload driver.";
      };

      driver = mkOption {
        type = types.enum [
          "auto"
          "jvm"
          "plugman"
          "none"
        ];
        default = "auto";
        description = "Reload driver. auto uses JVM class redefinition for Fabric and PlugManX for Bukkit-family loaders.";
      };

      socketPath = mkOption {
        type = types.str;
        default = "/run/minecraft-hot-reload/socket";
        description = "Unix-domain socket used by the JVM class redefinition agent.";
      };

      rconPort = mkOption {
        type = types.port;
        default = 25575;
        description = "Local RCON port used to ask PlugManX to reload Bukkit-family plugins.";
      };

      rconPassword = mkOption {
        type = types.str;
        default = "ix-auto-reload";
        description = "RCON password used only for the local PlugManX reload command.";
      };
    };

    configFiles = mkOption {
      type = types.attrsOf types.attrs;
      default = { };
      description = "Config files to place under config/. Keys are relative paths (format inferred from extension: .toml, .json, .yaml, .yml, .properties). Values are Nix attrsets.";
    };

    serverFiles = mkOption {
      type = types.attrsOf types.anything;
      default = { };
      description = "Files to place relative to the server root. Keys are paths (server.properties, bukkit.yml, etc.). Format inferred from extension.";
    };

    port = mkOption {
      type = types.port;
      default = 25565;
    };
  };

  config = mkIf cfg.enable {
    services.minecraft.serverFiles."server.properties".server-port = lib.mkDefault cfg.port;

    networking.firewall.allowedTCPPorts = [ cfg.port ];
    environment.etc."minecraft/managed-dropins".source = managedDropins;
    environment.etc."minecraft/managed-config".source = managedConfig;
    environment.etc."minecraft/managed-server-files".source = managedServerFiles;

    systemd.services.minecraft = {
      description = "Minecraft server";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      reloadTriggers = lib.optionals autoReloadEnabled [
        managedDropins
        managedConfig
        managedServerFiles
      ];
      restartTriggers = lib.optionals (!autoReloadEnabled) [
        managedDropins
        managedConfig
        managedServerFiles
      ];
      serviceConfig = {
        Type = "simple";
        WorkingDirectory = dataDir;
        ExecStart = lib.escapeShellArgs javaArgs;
        ExecReload = "${reloadCommand}/bin/minecraft-reload";
        Restart = "on-failure";
        StateDirectory = "minecraft";

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
      }
      // lib.optionalAttrs jvmReloadEnabled {
        RuntimeDirectory = "minecraft-hot-reload";
      };
      preStart = ''
        mkdir -p ${dataDir}/${cfg.dropDir}
        echo "eula=true" > ${dataDir}/eula.txt
        ${syncManaged}/bin/minecraft-sync-managed
      '';
    };
  };
}
