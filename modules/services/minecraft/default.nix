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
  pluginConfigFiles = lib.optionalAttrs plugmanReloadEnabled {
    "plugins/PlugManX/config.yml" = {
      ignored-plugins = cfg.autoReload.plugman.ignoredPlugins;
      notify-on-broken-command-removal = true;
      auto-load = {
        enabled = false;
        check-every-seconds = 10;
      };
      auto-unload = {
        enabled = false;
        check-every-seconds = 10;
      };
      auto-reload = {
        enabled = false;
        check-every-seconds = 10;
      };
      showPaperWarning = true;
      version = 3;
    };
  };

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

  serverFiles = cfg.serverFiles // pluginConfigFiles;

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
      pkgs.gnugrep
      pkgs.gnused
    ];
    text = ''
      data_dir=${lib.escapeShellArg dataDir}
      drop_dir=${lib.escapeShellArg cfg.dropDir}
      plugman_reload=${if plugmanReloadEnabled then "1" else "0"}
      plugman_ignored_plugins=${lib.escapeShellArg (lib.concatStringsSep " " cfg.autoReload.plugman.ignoredPlugins)}
      rcon_port=${toString cfg.autoReload.rconPort}
      rcon_password_file=${lib.escapeShellArg cfg.autoReload.rconPasswordFile}

      sync_tree() {
        source_dir="$1"
        target_dir="$2"
        manifest="$3"

        mkdir -p "$target_dir" "$(dirname "$manifest")"
        if [ -f "$manifest" ]; then
          while IFS= read -r line; do
            rel="''${line%% *}"
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
            source_path="$source_dir/$rel"
            mkdir -p "$target_dir/$(dirname "$rel")"
            ln -sfn "$source_path" "$target_dir/$rel"
            printf '%s %s\n' "$rel" "$(readlink -f "$source_path")" >> "$tmp"
          done
        fi

        mv "$tmp" "$manifest"
      }

      managed_target_for() {
        manifest="$1"
        rel="$2"

        if [ ! -f "$manifest" ]; then
          return 1
        fi

        grep -F -- "$rel " "$manifest" | head -n1 | cut -d ' ' -f2-
      }

      plugin_name_for() {
        basename "$1" .jar
      }

      plugin_name_from_config_path() {
        rel="$1"
        case "$rel" in
          plugins/*/*)
            rel="''${rel#plugins/}"
            printf '%s\n' "''${rel%%/*}"
            ;;
        esac
      }

      is_ignored_plugin() {
        case " $plugman_ignored_plugins " in
          *" $1 "*) return 0 ;;
          *) return 1 ;;
        esac
      }

      plan_plugman_reload() {
        dropin_manifest="$data_dir/.ix-managed-$drop_dir"
        server_manifest="$data_dir/.ix-managed-server-files"
        plan="$data_dir/.ix-managed-$drop_dir.reload-plan"
        : > "$plan"

        if [ -f "$dropin_manifest" ] && [ -d ${managedRoot}/managed-dropins ]; then
          (
            cd ${managedRoot}/managed-dropins
            find . -maxdepth 1 \( -type f -o -type l \) -name '*.jar' -print
          ) | while IFS= read -r rel; do
            rel="''${rel#./}"
            [ "$rel" = "PlugManX.jar" ] && continue
            target="$(readlink -f "${managedRoot}/managed-dropins/$rel")"
            old_target="$(managed_target_for "$dropin_manifest" "$rel" || true)"
            plugin="$(plugin_name_for "$rel")"
            is_ignored_plugin "$plugin" && continue

            if [ -z "$old_target" ]; then
              printf 'load %s\n' "$plugin" >> "$plan"
            elif [ "$old_target" != "$target" ]; then
              printf 'reload %s\n' "$plugin" >> "$plan"
            fi
          done

          while IFS= read -r line; do
            rel="''${line%% *}"
            case "$rel" in
              *.jar)
                [ "$rel" = "PlugManX.jar" ] && continue
                plugin="$(plugin_name_for "$rel")"
                is_ignored_plugin "$plugin" && continue
                if [ ! -e "${managedRoot}/managed-dropins/$rel" ]; then
                  printf 'unload %s\n' "$plugin" >> "$plan"
                fi
                ;;
            esac
          done < "$dropin_manifest"
        fi

        if [ -f "$server_manifest" ] && [ -d ${managedRoot}/managed-server-files ]; then
          (
            cd ${managedRoot}/managed-server-files
            find . \( -type f -o -type l \) -print
          ) | while IFS= read -r rel; do
            rel="''${rel#./}"
            plugin="$(plugin_name_from_config_path "$rel" || true)"
            [ -n "$plugin" ] || continue
            is_ignored_plugin "$plugin" && continue
            target="$(readlink -f "${managedRoot}/managed-server-files/$rel")"
            old_target="$(managed_target_for "$server_manifest" "$rel" || true)"
            if [ -z "$old_target" ] || [ "$old_target" != "$target" ]; then
              printf 'reload %s\n' "$plugin" >> "$plan"
            fi
          done

          while IFS= read -r line; do
            rel="''${line%% *}"
            plugin="$(plugin_name_from_config_path "$rel" || true)"
            [ -n "$plugin" ] || continue
            is_ignored_plugin "$plugin" && continue
            if [ ! -e "${managedRoot}/managed-server-files/$rel" ]; then
              printf 'reload %s\n' "$plugin" >> "$plan"
            fi
          done < "$server_manifest"
        fi

        sort -u "$plan" -o "$plan"
      }

      ensure_rcon_password() {
        mkdir -p "$(dirname "$rcon_password_file")"
        if [ ! -s "$rcon_password_file" ]; then
          od -An -N32 -tx1 /dev/urandom | tr -d ' \n' > "$rcon_password_file"
          printf '\n' >> "$rcon_password_file"
          chmod 0600 "$rcon_password_file"
        fi
      }

      set_property() {
        file="$1"
        key="$2"
        value="$3"
        escaped_value="$(printf '%s\n' "$value" | sed 's/[\/&]/\\&/g')"

        if grep -q "^$key=" "$file"; then
          sed -i "s/^$key=.*/$key=$escaped_value/" "$file"
        else
          printf '%s=%s\n' "$key" "$value" >> "$file"
        fi
      }

      configure_rcon() {
        ensure_rcon_password
        server_properties="$data_dir/server.properties"

        if [ -L "$server_properties" ]; then
          cp --remove-destination "$server_properties" "$server_properties.tmp"
          mv "$server_properties.tmp" "$server_properties"
        elif [ ! -e "$server_properties" ]; then
          : > "$server_properties"
        fi

        chmod 0600 "$server_properties"
        password="$(head -n1 "$rcon_password_file")"
        set_property "$server_properties" "enable-rcon" "true"
        set_property "$server_properties" "rcon.port" "$rcon_port"
        set_property "$server_properties" "rcon.password" "$password"
        set_property "$server_properties" "broadcast-rcon-to-ops" "false"
      }

      if [ "$plugman_reload" = "1" ]; then
        plan_plugman_reload
      fi

      sync_tree ${managedRoot}/managed-dropins "$data_dir/$drop_dir" "$data_dir/.ix-managed-$drop_dir"
      sync_tree ${managedRoot}/managed-config "$data_dir/config" "$data_dir/.ix-managed-config"
      sync_tree ${managedRoot}/managed-server-files "$data_dir" "$data_dir/.ix-managed-server-files"

      if [ "$plugman_reload" = "1" ]; then
        configure_rcon
      fi
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
      driver=${lib.escapeShellArg autoReloadDriver}

      case "$driver" in
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
          plan=${lib.escapeShellArg "${dataDir}/.ix-managed-${cfg.dropDir}.reload-plan"}
          if [ ! -s "$plan" ]; then
            exit 0
          fi

          failed=0
          while read -r action plugin; do
            [ -n "$action" ] || continue
            minecraft-rcon \
              --host 127.0.0.1 \
              --port ${toString cfg.autoReload.rconPort} \
              --password-file ${lib.escapeShellArg cfg.autoReload.rconPasswordFile} \
              plugman "$action" "$plugin" || failed=1
          done < "$plan"

          exit "$failed"
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

      rconPasswordFile = mkOption {
        type = types.str;
        default = "${dataDir}/.ix-rcon-password";
        description = "State-local RCON password file used by the PlugManX reload command. Generated on first start when absent.";
      };

      plugman = {
        ignoredPlugins = mkOption {
          type = types.listOf types.str;
          default = [
            "PlugMan"
            "PlugManX"
            "PlugManBungee"
            "ViaVersion"
            "ViaBackwards"
            "ViaRewind"
            "ProtocolSupport"
            "ProtocolLib"
          ];
          description = "Plugins PlugManX should never manage during enable, disable, restart, load, reload, or unload operations.";
        };
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
