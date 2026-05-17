{
  lib,
  makeWrapper,
  pkgs,
}:

let
  src = pkgs.fetchFromGitHub {
    owner = "indexable-inc";
    repo = "clippy";
    rev = "90e243bec8e5e298d04a68cf10226d0b6568c91f";
    hash = "sha256-KOaPrFbuDxCGdUMjWPHeqV9a53VZsRRI61YzIAGMZaw=";
  };

  toolchain = pkgs.rust-bin.fromRustupToolchainFile (src + "/rust-toolchain.toml");

  rustPlatform = pkgs.makeRustPlatform {
    cargo = toolchain;
    rustc = toolchain;
  };

  rustcLibPathVar =
    if pkgs.stdenv.hostPlatform.isDarwin then "DYLD_LIBRARY_PATH" else "LD_LIBRARY_PATH";
in
rustPlatform.buildRustPackage {
  pname = "llm-clippy";
  version = "0.1.97";

  inherit src;
  cargoLock.lockFile = ./Cargo.lock;
  cargoPatches = [ ./cargo-lock.patch ];

  nativeBuildInputs = [ makeWrapper ];
  buildInputs = [
    pkgs.zlib
  ]
  ++ lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
    pkgs.libiconv
  ];
  doCheck = false;

  # This Clippy fork links against rustc_private crates from the pinned nightly.
  RUSTC_BOOTSTRAP = "1";

  postInstall = ''
    for bin in "$out/bin/cargo-clippy" "$out/bin/clippy-driver"; do
      wrapProgram "$bin" \
        --prefix ${rustcLibPathVar} : "${toolchain}/lib"
    done
  '';

  meta = {
    description = "Clippy tuned for LLM-assisted codebases";
    homepage = "https://github.com/indexable-inc/clippy";
    license = with lib.licenses; [
      asl20
      mit
    ];
    mainProgram = "clippy-driver";
  };
}
