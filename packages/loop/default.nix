{
  ix,
  lib,
  pkgs,
  viewer,
}:

ix.buildRustPackage pkgs {
  pname = "loop";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.intersection (lib.fileset.gitTracked ./.) (
      lib.fileset.unions [
        ./Cargo.toml
        ./Cargo.lock
        ./src
      ]
    );
  };

  cargoLock.lockFile = ./Cargo.lock;

  postInstall = ''
    wrapProgram "$out/bin/loop" \
      --set LOOP_VIEWER_DIR "${viewer}/share/loop-viewer"
  '';

  nativeBuildInputs = [ pkgs.makeWrapper ];

  meta = {
    description = "Run agent loops and health checks with a Loro-backed web UI";
    mainProgram = "loop";
    license = lib.licenses.mit;
  };
}
