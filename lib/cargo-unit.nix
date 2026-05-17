{
  lib,
  pkgs,
  nixCargoUnit,
}:
let
  defaultRustToolchain = pkgs.symlinkJoin {
    name = "cargo-unit-rust-toolchain";
    paths = [
      pkgs.cargo
      pkgs.rustc
    ];
  };

  profileArgs =
    profile:
    if profile == "release" then
      [ "--release" ]
    else if profile == "dev" then
      [ ]
    else
      [
        "--profile"
        profile
      ];

  resolveVendorDir =
    {
      cargoLock,
      outputHashes,
      vendorDir,
    }:
    if vendorDir != null then
      vendorDir
    else
      pkgs.rustPlatform.importCargoLock {
        lockFile = cargoLock;
        inherit outputHashes;
      };

  vendorConfigScript =
    {
      cargoExtraConfig,
      vendorDir,
    }:
    let
      cargoExtraConfigFile = pkgs.writeText "cargo-extra-config.toml" cargoExtraConfig;
    in
    ''
      export CARGO_HOME="$TMPDIR/cargo-home"
      mkdir -p "$CARGO_HOME"

      if [ -f "${vendorDir}/.cargo/config.toml" ]; then
        sed 's|directory = "cargo-vendor-dir"|directory = "${vendorDir}"|' \
          "${vendorDir}/.cargo/config.toml" > "$CARGO_HOME/config.toml"
      else
        {
          printf '%s\n' '[source.crates-io]'
          printf '%s\n' 'replace-with = "vendored-sources"'
          printf '\n'
          printf '%s\n' '[source.vendored-sources]'
          printf '%s\n' 'directory = "${vendorDir}"'
        } > "$CARGO_HOME/config.toml"
      fi
    ''
    + lib.optionalString (cargoExtraConfig != "") ''

      printf '\n' >> "$CARGO_HOME/config.toml"
      cat ${cargoExtraConfigFile} >> "$CARGO_HOME/config.toml"
    '';

  commonArgs = args: {
    inherit (args) src;
    cargoLock = args.cargoLock or (args.src + "/Cargo.lock");
    cargoArgs = args.cargoArgs or [ "--workspace" ];
    profile = args.profile or "release";
    rustToolchain = args.rustToolchain or defaultRustToolchain;
    nativeBuildInputs = args.nativeBuildInputs or [ ];
    env = args.env or { };
    cargoExtraConfig = args.cargoExtraConfig or "";
    vendorDir = args.vendorDir or null;
    outputHashes = args.outputHashes or { };
    contentAddressed = args.contentAddressed or false;
  };

  renderCargoArgs =
    args:
    lib.escapeShellArgs (
      [
        "build"
        "--unit-graph"
        "-Z"
        "unstable-options"
      ]
      ++ profileArgs args.profile
      ++ args.cargoArgs
      ++ [
        "--frozen"
        "--offline"
      ]
    );

  /**
    Generate Cargo's `--unit-graph` JSON for a vendored Rust workspace.

    This is the first IFD stage used by `buildWorkspace`: Cargo resolves the
    exact rustc units from the caller's locked workspace, with registry and git
    crates supplied by `rustPlatform.importCargoLock`.
  */
  generateUnitGraph =
    rawArgs:
    let
      args = commonArgs rawArgs;
      vendorDir = resolveVendorDir {
        inherit (args) cargoLock outputHashes vendorDir;
      };
    in
    pkgs.runCommand "cargo-unit-graph.json"
      (
        {
          nativeBuildInputs = [
            args.rustToolchain
            pkgs.cacert
          ]
          ++ args.nativeBuildInputs;
          SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
          # Cargo still gates `--unit-graph` behind `-Z unstable-options`.
          # This helper keeps the input graph generation local to the IFD
          # planner derivation instead of requiring a flake-wide Rust overlay.
          RUSTC_BOOTSTRAP = "1";
        }
        // args.env
      )
      ''
        ${vendorConfigScript {
          inherit vendorDir;
          inherit (args) cargoExtraConfig;
        }}

        export CARGO_TARGET_DIR="$TMPDIR/cargo-target"
        cd ${args.src}
        cargo ${renderCargoArgs args} > "$out"
      '';

  /**
    Render `units.nix` from a Cargo unit graph.

    The result is imported by `buildWorkspace`, so this derivation is the
    second IFD stage. It is separated from `generateUnitGraph` so callers can
    inspect either artifact when debugging graph or renderer behavior.
  */
  generateUnitsNix =
    rawArgs:
    let
      args = commonArgs rawArgs;
      vendorDir = resolveVendorDir {
        inherit (args) cargoLock outputHashes vendorDir;
      };
      unitGraphJson = rawArgs.unitGraphJson or (generateUnitGraph rawArgs);
      toolchainId = builtins.baseNameOf (builtins.toString args.rustToolchain);
      renderFlags = [
        "render"
        "--workspace-root"
        (builtins.toString args.src)
        "--vendor-root"
        (builtins.toString vendorDir)
        "--toolchain-id"
        toolchainId
      ]
      ++ lib.optional args.contentAddressed "--content-addressed";
    in
    pkgs.runCommand "cargo-units.nix"
      {
        nativeBuildInputs = [ nixCargoUnit ];
      }
      ''
        nix-cargo-unit ${lib.escapeShellArgs renderFlags} < ${unitGraphJson} > "$out"
      '';

  /**
    Build a Rust workspace as one Nix derivation per Cargo rustc unit.

    Returns the generated attrset with `units`, `roots`, `packages`,
    `binaries`, `libraries`, `default`, plus the intermediate `unitGraphJson`,
    `unitsNix`, and `vendorDir` derivations for inspection.
  */
  buildWorkspace =
    rawArgs:
    let
      args = commonArgs rawArgs;
      vendorDir = resolveVendorDir {
        inherit (args) cargoLock outputHashes vendorDir;
      };
      unitGraphJson = generateUnitGraph (rawArgs // { inherit vendorDir; });
      unitsNix = generateUnitsNix (
        rawArgs
        // {
          inherit unitGraphJson vendorDir;
        }
      );
      units = import unitsNix {
        inherit pkgs vendorDir;
        inherit (args) src rustToolchain;
        extraNativeBuildInputs = args.nativeBuildInputs;
        extraEnv = args.env;
      };
    in
    units
    // {
      inherit unitGraphJson unitsNix vendorDir;
    };

  /**
    Build one package from a workspace by passing `-p <package>` to Cargo
    during unit-graph generation.
  */
  buildPackage =
    {
      package,
      cargoArgs ? [ ],
      ...
    }@args:
    buildWorkspace (
      builtins.removeAttrs args [
        "package"
        "cargoArgs"
      ]
      // {
        cargoArgs = [
          "-p"
          package
        ]
        ++ cargoArgs;
      }
    );

  /**
    Build one binary target from a workspace by passing `--bin <binary>` to
    Cargo during unit-graph generation.
  */
  buildBinary =
    {
      binary,
      cargoArgs ? [ ],
      ...
    }@args:
    let
      workspace = buildWorkspace (
        builtins.removeAttrs args [
          "binary"
          "cargoArgs"
        ]
        // {
          cargoArgs = [
            "--bin"
            binary
          ]
          ++ cargoArgs;
        }
      );
    in
    workspace.binaries.${binary} or workspace.default;
in
{
  inherit
    buildBinary
    buildPackage
    buildWorkspace
    generateUnitGraph
    generateUnitsNix
    ;
}
