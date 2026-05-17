{
  lib,
  pkgs,
  nixCargoUnit,
  rust,
}:
let
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

  commonArgs = args: {
    inherit (args) src;
    cargoLock = args.cargoLock or (args.src + "/Cargo.lock");
    cargoArgs = args.cargoArgs or [ "--workspace" ];
    profile = args.profile or "release";
    rustToolchain = args.rustToolchain or rust.defaultRustToolchain;
    nativeBuildInputs = args.nativeBuildInputs or [ ];
    env = args.env or { };
    cargoExtraConfig = args.cargoExtraConfig or "";
    vendorDir = args.vendorDir or null;
    vendorSources = args.vendorSources or null;
    workspaceSourceRoot = args.workspaceSourceRoot or args.src;
    allowAggregateWorkspaceSource = args.allowAggregateWorkspaceSource or false;
    allowAggregateVendorSource = args.allowAggregateVendorSource or false;
    outputHashes = args.outputHashes or { };
    contentAddressed = args.contentAddressed or false;
    policy =
      let
        rawPolicy = args.policy or { };
        rawCargoAudit = rawPolicy.cargoAudit or { };
        resolved = rust.resolvePolicy rawPolicy;
      in
      resolved
      // {
        cargoAudit = resolved.cargoAudit // {
          enable = rawCargoAudit.enable or true;
        };
      };
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
      vendorDir = rust.resolveVendorDir {
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
        ${rust.vendorConfigScript {
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
      vendorDir = rust.resolveVendorDir {
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
      ++ lib.optional args.contentAddressed "--content-addressed"
      ++ lib.optional args.policy.denyUnusedCrateDependencies "--deny-unused-crate-dependencies";
    in
    pkgs.runCommand "cargo-units.nix"
      {
        nativeBuildInputs = [ nixCargoUnit ];
      }
      ''
        nix-cargo-unit ${lib.escapeShellArgs renderFlags} < ${unitGraphJson} > "$out"
      '';

  /**
    Audit a workspace `Cargo.lock` with `cargo-audit` as a pure Nix check.

    The advisory database is a pinned RustSec checkout by default, and
    `cargo-audit` runs with `--no-fetch --stale` so evaluation and builds do
    not depend on a user Cargo home or network access.
  */
  auditCargoLock =
    rawArgs:
    let
      args = commonArgs rawArgs;
    in
    rust.cargoAuditCheck (
      rawArgs
      // {
        pname = rawArgs.pname or "cargo-unit";
        inherit (args) policy;
      }
    );

  /**
    Build a Rust workspace as one Nix derivation per Cargo rustc unit.

    Each generated unit gets a scoped source input by default. Workspace crates
    receive their own package root, and registry/git crates receive their own
    vendored package directory. A source edit in `crates/api` does not change
    the Nix input for `crates/worker`, `itoa`, or `ryu`; a `Cargo.lock` update
    for one transitive crate leaves unrelated vendored crate derivations alone.
    Rendering fails when a unit path cannot be tied back to `src` or `vendorDir`.

    Returns the generated attrset with `units`, `roots`, `checkedRoots`,
    `packages`, `binaries`, `libraries`, `default`, `policyChecks`, plus the
    intermediate `unitGraphJson`, `unitsNix`, and `vendorDir` derivations for
    inspection.
  */
  buildWorkspace =
    rawArgs:
    let
      args = commonArgs rawArgs;
      vendorDir = rust.resolveVendorDir {
        inherit (args) cargoLock outputHashes vendorDir;
      };
      vendorSources = rust.resolveVendorSources {
        inherit (args) cargoLock outputHashes vendorSources;
      };
      unitGraphJson = generateUnitGraph (rawArgs // { inherit vendorDir; });
      unitsNix = generateUnitsNix (
        rawArgs
        // {
          inherit unitGraphJson vendorDir;
        }
      );
      units = import unitsNix {
        inherit pkgs vendorDir vendorSources;
        inherit (args)
          allowAggregateVendorSource
          allowAggregateWorkspaceSource
          src
          rustToolchain
          workspaceSourceRoot
          ;
        extraNativeBuildInputs = args.nativeBuildInputs ++ rust.nativeBuildInputsForPolicy args.policy;
        extraEnv = args.env;
        extraRustcArgs = rust.rustcArgsForPolicy args.policy;
        extraPolicyChecks = rust.policyChecksFor (
          rawArgs
          // {
            inherit vendorDir;
            inherit (args) policy;
          }
        );
      };
    in
    units
    // {
      inherit unitGraphJson unitsNix vendorDir;
      inherit (args) policy;
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
    auditCargoLock
    generateUnitGraph
    generateUnitsNix
    ;
}
