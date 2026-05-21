{
  config,
  lib,
  pkgs,
  ...
}:
let
  httpPort = 8080;
in
{
  services.nginx = {
    enable = true;
    virtualHosts."east-west-firewall" = {
      default = true;
      listen = [
        {
          addr = "0.0.0.0";
          port = httpPort;
        }
      ];
      locations."/".return = "200 'east-west private service\n'";
    };
  };

  networking.firewall.allowedTCPPorts = [ httpPort ];

  environment.systemPackages = [ pkgs.curl ];

  ix.networking.portClaims.http = {
    protocol = "tcp";
    port = httpPort;
    description = "private HTTP service for east-west group members";
  };

  ix.healthChecks = {
    nginx = {
      command = [
        (lib.getExe' config.systemd.package "systemctl")
        "is-active"
        "--quiet"
        "nginx.service"
      ];
    };

    http-loopback = {
      description = "private HTTP service answers locally";
      command = [
        (lib.getExe pkgs.curl)
        "--fail"
        "--silent"
        "--show-error"
        "http://127.0.0.1:${toString httpPort}/"
      ];
    };
  };
}
