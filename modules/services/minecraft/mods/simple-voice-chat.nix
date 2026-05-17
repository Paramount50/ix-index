# Simple Voice Chat: proximity voice chat.
#
# Activated when `services.minecraft.mods.simple-voice-chat` or
# `services.minecraft.plugins.simple-voice-chat` is set.
# Opens the voice chat UDP port in the firewall.
{ config, lib, ... }:
let
  cfg = config.services.minecraft;
  modCfg = cfg.mods.simple-voice-chat or null;
  pluginCfg = cfg.plugins.simple-voice-chat or null;
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
  settings = defaults // pluginSettings // (if modCfg == null then { } else modCfg);
  voiceChatFiles = {
    "voicechat-server.properties" = {
      inherit (settings) port;
    };
  };
  prefixedFiles =
    prefix:
    lib.mapAttrs' (path: value: {
      name = "${prefix}/${path}";
      inherit value;
    }) voiceChatFiles;
in
{
  config = lib.mkIf (modCfg != null || pluginCfg != null) {
    ix.networking.portClaims.simple-voice-chat = {
      protocol = "udp";
      inherit (settings) port;
      address = "0.0.0.0";
      description = "Simple Voice Chat";
    };

    networking.firewall.allowedUDPPorts = [ settings.port ];

    services.minecraft = {
      configFiles = lib.mkIf (modCfg != null) (prefixedFiles "voicechat");
      serverFiles = lib.mkIf (pluginCfg != null) (prefixedFiles "plugins/voicechat");
    };
  };
}
