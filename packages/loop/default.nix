{
  lib,
  beamPackages,
  erlang,
  makeWrapper,
}:

# Hex deps come from `deps.nix`, which is regenerated with
# `nix shell nixpkgs#mix2nix -c mix2nix mix.lock > deps.nix` whenever
# `mix.lock` changes. Hashes ride in from the lockfile, so there is no
# floating FOD and no `lib.fakeHash` placeholder in tracked Nix.
let
  mixNixDeps = import ./deps.nix {
    inherit lib;
    inherit (beamPackages) beamPackages;
  };
  fs = lib.fileset;
  src = fs.toSource {
    root = ./.;
    fileset = fs.intersection (fs.gitTracked ./.) (
      fs.unions [
        ./mix.exs
        ./mix.lock
        ./lib
      ]
    );
  };
in
beamPackages.mixRelease {
  pname = "loop";
  version = "0.1.0";
  inherit src mixNixDeps;

  nativeBuildInputs = [ makeWrapper ];

  # Build an escript instead of a mix release: the loop tool is invoked as
  # a one-shot CLI (`loop --lint-program ... --once`), not a long-lived
  # OTP node that an operator attaches to. Escripts package the whole BEAM
  # closure into one self-extracting file and start the supervised app on
  # boot via `Application.ensure_all_started/1` in `Loop.CLI.main/1`.
  buildPhase = ''
    runHook preBuild
    mix escript.build --no-deps-check
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/libexec" "$out/bin"
    cp loop "$out/libexec/loop"

    makeWrapper ${erlang}/bin/escript "$out/bin/loop" \
      --add-flags "$out/libexec/loop"

    runHook postInstall
  '';

  meta = {
    description = "Run an agent CLI in a commit-and-push loop with a live web UI";
    mainProgram = "loop";
    license = lib.licenses.mit;
    platforms = erlang.meta.platforms;
  };
}
