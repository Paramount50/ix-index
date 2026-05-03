# BlueMap: 3D web map of the Minecraft world.
#
# Activated when `services.minecraft.mods.bluemap` is set.
# Opens the web server port in the firewall.
{ config, lib, ... }:
let
  modCfg = config.services.minecraft.mods.bluemap or null;
  defaults = {
    port = 8100;
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
  };
}
