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
  runtimeLibraryInputs = [ pkgs.stdenv.cc.cc.lib ];
  buildUvApplication = ix.buildUvApplication pkgs;
  buildArgs = {
    pname = "daily-scraper";
    version = "0.1.0";
    inherit src;
  };
  supportsRuntimeLibraryInputs = (builtins.functionArgs buildUvApplication) ? runtimeLibraryInputs;
  package = buildUvApplication (
    buildArgs
    // lib.optionalAttrs supportsRuntimeLibraryInputs {
      inherit runtimeLibraryInputs;
    }
  );
in
if supportsRuntimeLibraryInputs then
  package
else
  pkgs.symlinkJoin {
    name = "daily-scraper-0.1.0";
    paths = [ package ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      rm "$out/bin/daily-scraper"
      makeWrapper ${lib.getExe package} "$out/bin/daily-scraper" \
        --prefix LD_LIBRARY_PATH : ${lib.escapeShellArg (lib.makeLibraryPath runtimeLibraryInputs)}
    '';
    inherit (package) meta;
  }
