{
  ix,
  lib,
  pkgs,
  viewer,
}:

let
  loop.src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.intersection (lib.fileset.gitTracked ./.) (
      lib.fileset.unions [
        ./Cargo.toml
        ./Cargo.lock
        ./src
      ]
    );
  };

  loop.binary = ix.cargoUnit.buildBinary {
    pname = "loop";
    inherit (loop) src;
    workspaceRoot = ./.;
    binary = "loop";
    policy = {
      denyUnusedCrateDependencies = false;
      cargoAudit.enable = false;
      cargoMachete.enable = false;
      clippy.enable = false;
    };
  };
in
pkgs.runCommand "loop"
  {
    nativeBuildInputs = [ pkgs.makeWrapper ];
    passthru.unwrapped = loop.binary;
    meta = {
      description = "Run agent loops and health checks with a Loro-backed web UI";
      mainProgram = "loop";
      license = lib.licenses.mit;
    };
  }
  ''
    mkdir -p "$out/bin"
    makeWrapper "${loop.binary}/bin/loop" "$out/bin/loop" \
      --set LOOP_VIEWER_DIR "${viewer}/share/loop-viewer"
  ''
