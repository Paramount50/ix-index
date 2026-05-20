{
  ix,
  lib,
  pkgs,
}:

ix.buildRustPackage pkgs {
  pname = "dag-runner";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.gitTracked ./.;
  };

  cargoLock.lockFile = ./Cargo.lock;

  meta.mainProgram = "dag-runner";
}
