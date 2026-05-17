{
  lib,
  stdenvNoCC,
  src,
}:

stdenvNoCC.mkDerivation {
  pname = "ix";
  version = "precompiled";

  inherit src;

  dontUnpack = true;
  dontBuild = true;
  strictDeps = true;

  installPhase = ''
    runHook preInstall

    install -Dm755 "$src" "$out/bin/ix"

    runHook postInstall
  '';

  meta = {
    description = "ix deployment platform CLI";
    mainProgram = "ix";
    platforms = [ "x86_64-linux" ];
  };
}
