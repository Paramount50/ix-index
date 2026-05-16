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
  fileExt = path: lib.last (lib.splitString "." path);

  flattenProperties =
    value:
    let
      pairsFor =
        prefix: current:
        if builtins.isAttrs current && !lib.isDerivation current then
          lib.concatMap (name: pairsFor (prefix ++ [ name ]) current.${name}) (lib.attrNames current)
        else
          [
            {
              name = lib.concatStringsSep "." prefix;
              value = current;
            }
          ];
      pairs = pairsFor [ ] value;
      names = map (pair: pair.name) pairs;
      duplicateNames = lib.filter (
        name: builtins.length (lib.filter (candidate: candidate == name) names) > 1
      ) (lib.unique names);
    in
    assert lib.assertMsg (
      duplicateNames == [ ]
    ) "duplicate .properties keys after flattening: ${lib.concatStringsSep ", " duplicateNames}";
    lib.listToAttrs pairs;

  modCatalogType = types.submodule {
    options = {
      url = mkOption { type = types.str; };
      hash = mkOption {
        type = types.str;
        description = "SRI hash of the artifact at `url`. Used by `ix.artifacts.attachArtifactSources` to build the fetchurl derivation.";
      };
      src = mkOption {
        type = types.path;
        description = "Locked mod artifact.";
      };
      pluginName = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Runtime Bukkit plugin name, when it differs from the catalog slug.";
      };
    };
  };

  formatValueType = (pkgs.formats.json { }).type;

  modConfigType = types.submodule {
    freeformType = formatValueType;
  };

  pluginType = types.submodule {
    options = {
      src = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Plugin jar. Leave unset to resolve the plugin from pluginCatalog by slug.";
      };
      pluginName = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Runtime Bukkit plugin name used by PlugManX reloads.";
      };
    };
  };

  modJars = lib.mapAttrsToList (
    slug: _:
    let
      entry = cfg.modCatalog.${slug} or (throw "mod '${slug}' not in modCatalog");
      pluginName =
        cfg.autoReload.plugman.pluginNames.${slug}
          or (if entry.pluginName == null then slug else entry.pluginName);
    in
    {
      name = "${slug}.jar";
      path = entry.src;
      inherit pluginName;
    }
  ) cfg.mods;

  pluginJars = lib.mapAttrsToList (
    slug: plugin:
    let
      entry =
        if plugin.src == null then
          cfg.pluginCatalog.${slug} or (throw "plugin '${slug}' not in pluginCatalog")
        else
          plugin;
      pluginName =
        cfg.autoReload.plugman.pluginNames.${slug}
          or (if entry.pluginName == null then slug else entry.pluginName);
    in
    {
      name = "${slug}.jar";
      path = entry.src;
      inherit pluginName;
    }
  ) cfg.plugins;

  loaderEnabled = lib.genAttrs [
    "fabric"
    "folia"
    "paper"
    "purpur"
    "spigot"
    "sponge"
  ] (name: cfg.${name}.enable);

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
  rconEnabled = cfg.rcon.enable || plugmanReloadEnabled;
  rconPort = if cfg.rcon.enable then cfg.rcon.port else cfg.autoReload.rconPort;
  rconPasswordFile =
    if cfg.rcon.enable then cfg.rcon.passwordFile else cfg.autoReload.rconPasswordFile;
  rconBroadcastToOps = if cfg.rcon.enable then cfg.rcon.broadcastToOps else false;
  java = lib.getExe' cfg.javaPackage "java";
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
    ++ pluginJars
    ++ lib.optionals plugmanReloadEnabled [
      {
        name = "PlugManX.jar";
        path = ix.artifacts.minecraft.plugins.plugmanx;
        pluginName = "PlugManX";
      }
    ];

  # Infer serialization format from file extension.
  formatFor =
    path:
    let
      ext = fileExt path;
    in
    {
      toml = pkgs.formats.toml { };
      json = pkgs.formats.json { };
      yaml = pkgs.formats.yaml { };
      yml = pkgs.formats.yaml { };
      properties = pkgs.formats.keyValue { };
    }
    .${ext} or (throw "configFiles: unsupported extension .${ext} on '${path}'");

  normalizeFor = path: value: if fileExt path == "properties" then flattenProperties value else value;

  serverFiles = cfg.serverFiles // pluginConfigFiles;

  mkManaged =
    label: source:
    pkgs.runCommand "minecraft-managed-${label}" { } ''
      mkdir -p "$out"
      ${lib.concatStringsSep "\n" (
        lib.mapAttrsToList (
          path: value:
          let
            file = (formatFor path).generate (baseNameOf path) (normalizeFor path value);
          in
          "mkdir -p $out/${dirOf path}\nln -sf ${file} $out/${path}"
        ) source
      )}
    '';

  managed =
    let
      dropins = pkgs.runCommand "minecraft-managed-${cfg.dropDir}" { } (
        ''
          mkdir -p "$out"
        ''
        + lib.concatMapStringsSep "\n" (jar: ''
          ln -s ${jar.path} "$out/${jar.name}"
          printf '%s\n' ${lib.escapeShellArg jar.pluginName} > "$out/${jar.name}.plugin-name"
        '') managedJars
      );
      configFiles = mkManaged "config" cfg.configFiles;
      serverRootFiles = mkManaged "server-files" serverFiles;
    in
    {
      inherit dropins;
      config = configFiles;
      serverFiles = serverRootFiles;
      roots = [
        dropins
        configFiles
        serverRootFiles
      ];
    };

  syncManaged = ix.mkMinecraftSyncManaged {
    inherit
      pkgs
      dataDir
      managedRoot
      plugmanReloadEnabled
      rconEnabled
      rconPort
      rconPasswordFile
      rconBroadcastToOps
      ;
    inherit (cfg) dropDir;
    inherit (cfg.autoReload.plugman) ignoredPlugins;
  };

  reloadCommand = ix.writeNushellApplication pkgs {
    name = "minecraft-reload";
    runtimeInputs = [
      pkgs.minecraft-rcon
      syncManaged
    ];
    text = ''
      const driver = ${builtins.toJSON autoReloadDriver}
      const socket = ${builtins.toJSON cfg.autoReload.socketPath}
      const plan = ${builtins.toJSON "${dataDir}/.ix-managed-${cfg.dropDir}.reload-plan"}

      def main [] {
        minecraft-sync-managed

        match $driver {
          "jvm" => {
            if not (($socket | path type) == "socket") {
              print --stderr $"minecraft hot reload socket is not ready at ($socket); synced managed files only"
              return
            }

            exec ${java} -cp ${pkgs.minecraft-hot-reload-agent}/share/minecraft-hot-reload-agent/minecraft-hot-reload-agent.jar dev.ix.minecraft.hotreload.HotReloadAgent $socket redefine-dir ${managedRoot}/managed-dropins
          }
          "plugman" => {
            if not ($plan | path exists) or ((open --raw $plan | str trim | is-empty)) {
              return
            }

            mut failed = false
            for row in (open --raw $plan | lines | parse "{action} {plugin}") {
              if (do --ignore-errors {
                minecraft-rcon --host 127.0.0.1 --port ${toString rconPort} --password-file ${builtins.toJSON rconPasswordFile} plugman $row.action $row.plugin
              }) == null {
                $failed = true
              }
            }

            if $failed {
              exit 1
            }
          }
          "none" => {}
          _ => {
            print --stderr $"unsupported minecraft auto reload driver: ($driver)"
            exit 1
          }
        }
      }
    '';
  };

  autoReloadJvmFlags = lib.optionals jvmReloadEnabled [
    "-javaagent:${pkgs.minecraft-hot-reload-agent}/share/minecraft-hot-reload-agent/minecraft-hot-reload-agent.jar=socket=${cfg.autoReload.socketPath}"
  ];

  javaArgs = [
    java
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

    version = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "1.21.11";
      description = ''
        Minecraft game version. Single source of truth for the server jar
        and mod catalog: loader modules derive `src` from
        `ix.artifacts.minecraft.servers."''${version}-''${loader}"` and the
        default `modCatalog` is built from
        `ix.artifacts.minecraft.modCatalogs.''${version}` (plus the
        cross-version `common` catalog).
      '';
    };

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
      type = types.attrsOf modConfigType;
      default = { };
      description = "Mods to install, keyed by Modrinth slug. Empty {} includes the jar with defaults. Attrsets with fields configure the mod (mod modules read these and generate config files).";
    };

    plugins = mkOption {
      type = types.attrsOf pluginType;
      default = { };
      description = "Bukkit-family plugins to install. Empty {} resolves a pinned catalog plugin by slug; attrsets with src install a local or private plugin jar.";
    };

    modCatalog = mkOption {
      type = types.attrsOf modCatalogType;
      default =
        let
          catalogs = ix.artifacts.minecraft.modCatalogs;
        in
        (catalogs.common or { })
        // (lib.optionalAttrs (cfg.version != null) (catalogs.${cfg.version} or { }));
      defaultText = lib.literalMD ''
        `ix.artifacts.minecraft.modCatalogs.common` merged with
        `ix.artifacts.minecraft.modCatalogs.''${version}` when
        `services.minecraft.version` is set.
      '';
      description = "Slug to locked mod artifact mapping. Defaults from `services.minecraft.version`; override per-key to add private or unpinned mods.";
    };

    pluginCatalog = mkOption {
      type = types.attrsOf modCatalogType;
      default = { };
      description = "Slug to locked Bukkit plugin artifact mapping.";
    };

    javaPackage = mkOption {
      type = types.package;
      default = pkgs.temurin-jre-bin-25;
    };

    jvmFlags = mkOption {
      type = types.listOf types.str;
      default = [
        # Aikar's flags: https://mcflags.emc.gs
        "-XX:+UnlockExperimentalVMOptions"
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

    rcon = {
      enable = mkEnableOption "Minecraft RCON";

      port = mkOption {
        type = types.port;
        default = 25575;
        description = "TCP port for Minecraft RCON.";
      };

      passwordFile = mkOption {
        type = types.str;
        default = "${dataDir}/.ix-rcon-password";
        description = "State-local RCON password file. Generated on first start when absent.";
      };

      openFirewall = mkOption {
        type = types.bool;
        default = false;
        description = "Whether to open the RCON port in the firewall.";
      };

      broadcastToOps = mkOption {
        type = types.bool;
        default = false;
        description = "Whether RCON commands should be broadcast to operators.";
      };
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

        pluginNames = mkOption {
          type = types.attrsOf types.str;
          default = { };
          description = "Managed plugin slug to Bukkit plugin name mapping for PlugManX commands when the jar slug differs from the runtime plugin name.";
        };
      };
    };

    configFiles = mkOption {
      type = types.attrsOf formatValueType;
      default = { };
      description = "Config files to place under config/. Keys are relative paths (format inferred from extension: .toml, .json, .yaml, .yml, .properties). Values are Nix attrsets.";
    };

    serverFiles = mkOption {
      type = types.attrsOf formatValueType;
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

    networking.firewall.allowedTCPPorts = [
      cfg.port
    ]
    ++ lib.optionals cfg.rcon.openFirewall [ rconPort ];
    environment.etc = {
      "minecraft/managed-dropins".source = managed.dropins;
      "minecraft/managed-config".source = managed.config;
      "minecraft/managed-server-files".source = managed.serverFiles;
    };

    systemd.services.minecraft = {
      description = "Minecraft server";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      reloadTriggers = lib.optionals autoReloadEnabled managed.roots;
      restartTriggers = lib.optionals (!autoReloadEnabled) managed.roots;
      serviceConfig =
        ix.systemdHardening
        // {
          Type = "simple";
          WorkingDirectory = dataDir;
          ExecStart = lib.escapeShellArgs javaArgs;
          ExecReload = lib.getExe reloadCommand;
          Restart = "on-failure";
          StateDirectory = "minecraft";
        }
        // lib.optionalAttrs jvmReloadEnabled {
          RuntimeDirectory = "minecraft-hot-reload";
        };
      preStart = ''
        mkdir -p ${dataDir}/${cfg.dropDir}
        echo "eula=true" > ${dataDir}/eula.txt
        ${lib.getExe syncManaged}
      '';
    };
  };
}
