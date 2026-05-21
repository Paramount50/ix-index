{
  lib,
  nodes,
  pkgs,
  ...
}:
let
  service = {
    host = nodes.service.config.ix.networking.eastWest.hostName;
    port = 8080;
  };
in
{
  environment.systemPackages = [ pkgs.curl ];

  ix.healthChecks.private-service = {
    description = "private service is reachable from an east-west group member";
    command = [
      (lib.getExe pkgs.curl)
      "--fail"
      "--silent"
      "--show-error"
      "http://${service.host}:${toString service.port}/"
    ];
  };
}
