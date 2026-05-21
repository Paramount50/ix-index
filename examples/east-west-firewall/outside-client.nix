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

  ix.healthChecks.private-service-denied = {
    description = "private service is unreachable outside the east-west group";
    attempts = 3;
    command = [
      (lib.getExe pkgs.bash)
      "-e"
      "-u"
      "-o"
      "pipefail"
      "-c"
      ''
        if ${lib.getExe pkgs.curl} --fail --silent --show-error --connect-timeout 2 http://${service.host}:${toString service.port}/; then
          echo "unexpectedly reached http://${service.host}:${toString service.port}/" >&2
          exit 1
        fi
      ''
    ];
  };
}
