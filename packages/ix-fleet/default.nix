{
  ix,
  lib,
  pkgs ? ix.pkgs,
}:
let
  fs = lib.fileset;
  src = fs.toSource {
    root = ./.;
    fileset = fs.unions [
      ./pyproject.toml
      ./src
      ./uv.lock
    ];
  };
in
ix.buildUvApplication pkgs {
  pname = "ix-fleet";
  version = "0.1.0";
  inherit src;
  mainProgram = "ix-fleet";
}
