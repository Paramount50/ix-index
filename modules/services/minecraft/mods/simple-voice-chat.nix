# Simple Voice Chat: proximity voice chat.
#
# Activated when `services.minecraft.mods.simple-voice-chat` is set.
# Opens the voice chat UDP port in the firewall.
{ config, lib, ... }:
let
  modCfg = config.services.minecraft.mods.simple-voice-chat or null;
  defaults = {
    port = 24454;
  };
  merged = defaults // (if modCfg == null then { } else modCfg);
in
{
  config = lib.mkIf (modCfg != null) {
    networking.firewall.allowedUDPPorts = [ merged.port ];
    services.minecraft.configFiles."voicechat/voicechat-server.properties" = {
      inherit (merged) port;
    };
  };
}
