{
  stdenvNoCC,
  fetchurl,
}:

let
  sources = {
    x86_64-linux = fetchurl {
      url = "https://ix.dev/cli/linux-x86_64/ix";
      hash = "sha256-U5vAZ1AKsk5XIwXoNwM4Bz7FJ1firsZddY9fwfChsNY=";
    };
    aarch64-darwin = fetchurl {
      url = "https://ix.dev/cli/darwin-arm64/ix";
      hash = "sha256-1Whto7SP/iogbInZSLXXIgcUpuuCXGDEH4im+7b0jK4=";
    };
    x86_64-darwin = fetchurl {
      url = "https://ix.dev/cli/darwin-x86_64/ix";
      hash = "sha256-PZ+WlN4L/cFj9tWothY0V4xaG3VRrVgY9sFKpPM9efg=";
    };
  };

  inherit (stdenvNoCC.hostPlatform) system;
in
stdenvNoCC.mkDerivation {
  pname = "ix";
  version = "precompiled";

  src = sources.${system} or (throw "ix CLI: no precompiled binary for ${system}");

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
    platforms = builtins.attrNames sources;
  };
}
