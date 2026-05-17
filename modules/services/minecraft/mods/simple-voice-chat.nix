# Simple Voice Chat: proximity voice chat.
#
# Activated when `services.minecraft.mods.simple-voice-chat` or
# `services.minecraft.plugins.simple-voice-chat` is set.
# Opens the voice chat UDP port in the firewall.
{ config, lib, ... }:
let
  modCfg = config.services.minecraft.mods.simple-voice-chat or null;
  pluginCfg = config.services.minecraft.plugins.simple-voice-chat or null;
  defaults = {
    port = 24454;
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
in
{
  config = lib.mkIf (modCfg != null || pluginCfg != null) {
    ix.networking.portClaims.simple-voice-chat = {
      protocol = "udp";
      inherit (merged) port;
      address = "0.0.0.0";
      description = "Simple Voice Chat";
    };

    networking.firewall.allowedUDPPorts = [ merged.port ];

    services.minecraft = {
      configFiles = lib.mkIf (modCfg != null) {
        "voicechat/voicechat-server.properties" = {
          inherit (merged) port;
        };
      };

      serverFiles = lib.mkIf (pluginCfg != null) {
        "plugins/voicechat/voicechat-server.properties" = {
          inherit (merged) port;
        };
      };
    };
  };
}
