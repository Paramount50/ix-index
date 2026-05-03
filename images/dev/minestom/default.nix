# Minestom hello-world image.
#
# Builds a fat jar from ./project via maven.buildMavenPackage. nixpkgs handles
# the two-phase build: a fixed-output derivation fetches all Maven artifacts,
# then a regular derivation compiles offline with maven-shade-plugin.
{ lib, pkgs, ... }:
let
  serverJar = pkgs.maven.buildMavenPackage {
    pname = "minestom-hello";
    version = "0.1.0";
    src = ./project;
    mvnHash = lib.fakeHash;

    installPhase = ''
      cp target/minestom-hello-0.1.0.jar $out
    '';
  };
in
{
  ix.image.name = "minestom-hello";

  services.minestom = {
    enable = true;
    serverJar = serverJar;
  };
}
