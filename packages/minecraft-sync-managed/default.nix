{
  lib,
  rustPlatform,
}:

rustPlatform.buildRustPackage {
  pname = "minecraft-sync-managed";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.gitTracked ./.;
  };

  cargoLock.lockFile = ./Cargo.lock;

  meta.mainProgram = "minecraft-sync-managed";
}
