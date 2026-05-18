{
  lib,
  stdenvNoCC,
  fetchurl,
}:
let
  # URL + hash per platform.  When ix.dev ships a new CLI, update the
  # hash here (one place) instead of running `nix flake update`.
  sources = {
    "x86_64-linux" = {
      url = "https://ix.dev/cli/linux-x86_64/ix";
      hash = "sha256-6TpD+Wrme2pl0BV/Z+UqOqz/qeAHv+Bqdo1DyIdXzpo=";
    };
    "aarch64-darwin" = {
      url = "https://ix.dev/cli/darwin-arm64/ix";
      hash = "sha256-lPxd7XkazzfTkM2Az4R1ENlEmXzaF70O93OagH1Kn2s=";
    };
    "x86_64-darwin" = {
      url = "https://ix.dev/cli/darwin-x86_64/ix";
      hash = "sha256-ivkOJr+NUsoeyZ5m90LcS1BC89ibnzVKPui+Z7GdjkQ=";
    };
  };
  platform = stdenvNoCC.hostPlatform.system;
  src = fetchurl sources.${platform};
in
assert lib.assertMsg (builtins.hasAttr platform sources)
  "ix CLI: no precompiled binary for ${platform}";

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
    platforms = [
      "x86_64-linux"
      "aarch64-darwin"
      "x86_64-darwin"
    ];
  };
}
