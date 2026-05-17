{
  ix,
  lib,
  pkgs,
}:

ix.buildRustPackage pkgs {
  pname = "oci-image-builder";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.gitTracked ./.;
  };

  cargoLock.lockFile = ./Cargo.lock;

  meta.mainProgram = "oci-image-builder";
}
