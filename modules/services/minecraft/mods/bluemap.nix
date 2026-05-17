# BlueMap: 3D web map of the Minecraft world.
#
# Activated when `services.minecraft.mods.bluemap` or
# `services.minecraft.plugins.bluemap` is set.
# Opens the web server port in the firewall. Optionally provisions MariaDB
# for tile storage when `mysql = true`.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.minecraft;
  modCfg = cfg.mods.bluemap or null;
  pluginCfg = cfg.plugins.bluemap or null;
  defaults = {
    port = 8100;
    mysql = false;
  };
  pluginSettings =
    if pluginCfg == null then
      { }
    else
      builtins.removeAttrs pluginCfg [
        "pluginName"
        "src"
      ];
  merged = defaults // pluginSettings // (if modCfg == null then { } else modCfg);
  bluemapFiles = {
    "core.conf" = {
      accept-download = true;
    };

    "webserver.conf" = {
      inherit (merged) port;
      ip = "0.0.0.0";
    };

    "storages/sql.conf" = lib.mkIf merged.mysql {
      storage-type = "SQL";
      connection-url = "jdbc:mysql://localhost:3306/bluemap";
      connection-properties = {
        user = "minecraft";
      };
    };
  };
  prefixedFiles =
    prefix:
    lib.mapAttrs' (path: value: {
      name = "${prefix}/${path}";
      inherit value;
    }) bluemapFiles;
in
{
  config = lib.mkIf (modCfg != null || pluginCfg != null) {
    ix.networking.portClaims.bluemap = {
      protocol = "tcp";
      inherit (merged) port;
      address = "0.0.0.0";
      description = "BlueMap web server";
    };

    networking.firewall.allowedTCPPorts = [ merged.port ];

    services = {
      minecraft = {
        configFiles = lib.mkIf (modCfg != null) (prefixedFiles "bluemap");
        serverFiles = lib.mkIf (pluginCfg != null) (prefixedFiles "plugins/BlueMap");
      };

      mysql = lib.mkIf merged.mysql {
        enable = true;
        package = lib.mkDefault pkgs.mariadb;
        ensureDatabases = [ "bluemap" ];
        ensureUsers = [
          {
            name = "minecraft";
            ensurePermissions = {
              "bluemap.*" = "ALL PRIVILEGES";
            };
          }
        ];
      };
    };
  };
}
