# Minestom hello-world image.
{
  ix,
  lib,
  pkgs,
  ...
}:
let
  serverJar = import ../../../packages/minestom/servers/hello {
    inherit ix lib pkgs;
  };
in
{
  ix.image.name = "minestom-hello";

  services.minestom = {
    enable = true;
    inherit serverJar;
  };
}
