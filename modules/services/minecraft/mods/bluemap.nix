# BlueMap: 3D web map of the Minecraft world.
#
# Activated when `services.minecraft.mods.bluemap` is set.
# Opens the web server port in the firewall. Optionally provisions MariaDB
# for tile storage when `mysql = true`.
{ config, lib, pkgs, ... }:
let
  modCfg = config.services.minecraft.mods.bluemap or null;
  defaults = {
    port = 8100;
    mysql = false;
  };
  merged = defaults // (if modCfg == null then { } else modCfg);
in
{
  config = lib.mkIf (modCfg != null) {
    networking.firewall.allowedTCPPorts = [ merged.port ];

    services.minecraft.configFiles."bluemap/webserver.conf" = {
      port = merged.port;
      ip = "0.0.0.0";
    };

    services.mysql = lib.mkIf merged.mysql {
      enable = true;
      package = lib.mkDefault pkgs.mariadb;
      ensureDatabases = [ "bluemap" ];
      ensureUsers = [
        { name = "minecraft"; ensurePermissions = { "bluemap.*" = "ALL PRIVILEGES"; }; }
      ];
    };

    services.minecraft.configFiles."bluemap/storages/sql.conf" = lib.mkIf merged.mysql {
      storage-type = "SQL";
      connection-url = "jdbc:mysql://localhost:3306/bluemap";
      connection-properties = {
        user = "minecraft";
      };
    };
  };
}
