{
  ix,
  lib,
  openssl,
  pkg-config,
  pkgs,
  rust-bin,
  zlib,
}:
let
  pname = "hyperion";
  version = "0-unstable-2025-10-06";

  upstreamSrc = pkgs.fetchFromGitHub {
    owner = "hyperion-mc";
    repo = "hyperion";
    rev = "313503c0820dfbd0156443b12ca5a76b237936cf";
    hash = "sha256-jnMJcN/0JkP1yY515rrP+5utmJ+XyC7OjGXJg9mFpCM=";
  };

  src = pkgs.applyPatches {
    name = "${pname}-source";
    src = upstreamSrc;
    patches = [ ./bedwars-proxy-addr-env.patch ];
    postPatch = ''
      substituteInPlace Cargo.toml \
        --replace-fail "    'tools/packet-inspector'," "" \
        --replace-fail "    'tools/rust-mc-bot'," ""

      cp ${./Cargo.lock} Cargo.lock
    '';
  };

  rustToolchain = rust-bin.fromRustupToolchainFile (src + "/rust-toolchain.toml");
  workspace = (ix.cargoUnitFor pkgs).buildWorkspace {
    inherit pname src rustToolchain;
    # The checked-in lock matches the patched workspace above. Upstream's full
    # lock keeps a removed tool's second Valence branch, which collides in
    # nixpkgs' name-version keyed git output hash map.
    cargoLock = ./Cargo.lock;
    # The build source is a patched upstream derivation, so there is no
    # repo-local workspace root for cargo-unit to rescan per package.
    workspaceRoot = src;
    cargoArgs = [
      "--package"
      "bedwars"
      "--package"
      "hyperion-proxy"
    ];
    outputHashes = {
      "git+https://github.com/TestingPlant/bvh-data#9bffb03a4b894a7884c9ec0da986bdde732ac704" =
        "sha256-QjsyP9XdR53JDNFC8IX1qgTlJQZmanAZU+246QG4v9s=";
      "git+https://github.com/TestingPlant/valence?branch=feat-bytes#fb792dcb6669b64c5dc2366eb3d074b293def046" =
        "sha256-rpuJSz8KxEwG5qeT4HYVtTxHJ24nrYZJwDurv+mjPxM=";
      "git+https://github.com/nvzqz/divan#bca5c9676a35751d0a8164df7d79bda70f23286b" =
        "sha256-WmzYLzLwXUGuX0K151Kh+fEV6nJJQLq/vb4ijXu01Vg=";
    };
    nativeBuildInputs = [
      pkg-config
      pkgs.cmake
    ];
    env = {
      OPENSSL_NO_VENDOR = "1";
      OPENSSL_LIB_DIR = "${lib.getLib openssl}/lib";
      OPENSSL_INCLUDE_DIR = "${lib.getDev openssl}/include";
      ZLIB_LIB_DIR = "${lib.getLib zlib}/lib";
      ZLIB_INCLUDE_DIR = "${lib.getDev zlib}/include";
    };
    policy = {
      denyUnusedCrateDependencies = false;
      cargoAudit.enable = false;
      cargoMachete.enable = false;
      clippy.enable = false;
    };
  };

  package = pkgs.symlinkJoin {
    name = "${pname}-${version}";
    paths = [
      workspace.binaries.bedwars
      workspace.binaries."hyperion-proxy"
    ];
    passthru = {
      inherit src workspace;
    };
    meta = {
      description = "Minecraft game engine for massive custom events";
      homepage = "https://github.com/hyperion-mc/hyperion";
      license = lib.licenses.asl20;
      mainProgram = "bedwars";
      platforms = lib.platforms.linux ++ lib.platforms.darwin;
    };
  };
in
package
// {
  inherit pname version;
}
