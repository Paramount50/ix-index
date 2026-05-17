{
  ix,
  lib,
  pkgs,
}:

ix.buildRustPackage pkgs {
  pname = "nix-cargo-unit";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.gitTracked ./.;
  };

  cargoLock.lockFile = ./Cargo.lock;

  meta.mainProgram = "nix-cargo-unit";
}
