# Minestom hello-world image.
#
# Builds a fat jar from ./project via maven.buildMavenPackage. nixpkgs handles
# the two-phase build: a fixed-output derivation fetches all Maven artifacts,
# then a regular derivation compiles offline with maven-shade-plugin.
{ lib, pkgs, ... }:
let
  fs = lib.fileset;
  projectSrc = fs.toSource {
    root = ./project;
    fileset = fs.unions [
      ./project/pom.xml
      ./project/src/main/java/dev/ix/minestom/Main.java
      ./project/src/main/resources/logback.xml
    ];
  };

  serverJar = pkgs.maven.buildMavenPackage {
    pname = "minestom-hello";
    version = "0.1.0";
    src = projectSrc;
    mvnJdk = pkgs.jdk25;
    mvnHash = "sha256-BPHNg6l/b08zHvnWbuXMHVq7fsGysymjlHG7ZJ88WoM=";

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
