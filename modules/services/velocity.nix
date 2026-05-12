{ lib, ... }:
let
  inherit (lib) mkEnableOption mkOption types;
in
{
  options.services.velocity = {
    enable = mkEnableOption "Velocity proxy";
    bind = mkOption {
      type = types.str;
      default = "0.0.0.0:25565";
    };
    onlineMode = mkOption {
      type = types.bool;
      default = true;
    };
    forwarding = {
      mode = mkOption {
        type = types.enum [
          "none"
          "legacy"
          "bungeeguard"
          "modern"
        ];
        default = "modern";
      };
      secret = mkOption {
        type = types.oneOf [
          types.str
          types.path
        ];
        description = "Velocity player-info forwarding secret, either inline or as a file path.";
      };
    };
    servers = mkOption {
      type = types.attrsOf types.str;
      default = { };
    };
    try = mkOption {
      type = types.listOf types.str;
      default = [ ];
    };
  };
}
