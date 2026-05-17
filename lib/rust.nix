{
  lib,
  pkgs,
}:
let
  defaultRustToolchain = pkgs.symlinkJoin {
    name = "ix-rust-toolchain";
    paths = [
      pkgs.cargo
      pkgs.rustc
    ];
  };

  defaultRustsecAdvisoryDb = pkgs.fetchFromGitHub {
    owner = "rustsec";
    repo = "advisory-db";
    rev = "f2ae5fc8e5d208373b6c838f9676434525327a72";
    hash = "sha256-iqXYpuCoWoGypnpM5ceXN748QlYeBXDtZx0uI98qFLo=";
  };

  defaultPolicy = {
    denyUnusedCrateDependencies = true;
    cargoAudit = {
      enable = false;
      db = defaultRustsecAdvisoryDb;
      deny = [ ];
      ignore = [ ];
    };
    cargoMachete = {
      enable = true;
      extraArgs = [ ];
    };
    clippy = {
      enable = true;
      cargoArgs = [ "--all-targets" ];
      denyWarnings = true;
    };
    tests = {
      enable = true;
      useNextest = true;
    };
    linker = {
      useMold = pkgs.stdenv.hostPlatform.isLinux;
    };
  };

  cargoLockFile = cargoLock: if builtins.isAttrs cargoLock then cargoLock.lockFile else cargoLock;

  resolvePolicy =
    rawPolicy:
    let
      cargoAudit = rawPolicy.cargoAudit or { };
      cargoMachete = rawPolicy.cargoMachete or { };
      clippy = rawPolicy.clippy or { };
      tests = rawPolicy.tests or { };
      linker = rawPolicy.linker or { };
    in
    {
      denyUnusedCrateDependencies =
        rawPolicy.denyUnusedCrateDependencies or defaultPolicy.denyUnusedCrateDependencies;
      cargoAudit = {
        enable = cargoAudit.enable or defaultPolicy.cargoAudit.enable;
        db = cargoAudit.db or defaultPolicy.cargoAudit.db;
        deny = cargoAudit.deny or defaultPolicy.cargoAudit.deny;
        ignore = cargoAudit.ignore or defaultPolicy.cargoAudit.ignore;
      };
      cargoMachete = {
        enable = cargoMachete.enable or defaultPolicy.cargoMachete.enable;
        extraArgs = cargoMachete.extraArgs or defaultPolicy.cargoMachete.extraArgs;
      };
      clippy = {
        enable = clippy.enable or defaultPolicy.clippy.enable;
        cargoArgs = clippy.cargoArgs or defaultPolicy.clippy.cargoArgs;
        denyWarnings = clippy.denyWarnings or defaultPolicy.clippy.denyWarnings;
      };
      tests = {
        enable = tests.enable or defaultPolicy.tests.enable;
        useNextest = tests.useNextest or defaultPolicy.tests.useNextest;
      };
      linker = {
        useMold = linker.useMold or defaultPolicy.linker.useMold;
      };
    };

  rustcArgsForPolicy =
    policy:
    lib.optionals policy.linker.useMold [
      "-C"
      "link-arg=-fuse-ld=mold"
    ];

  rustFlagsStringForPolicy = policy: lib.concatStringsSep " " (rustcArgsForPolicy policy);

  nativeBuildInputsForPolicy = policy: lib.optionals policy.linker.useMold [ pkgs.mold ];

  exportRustFlagsScript =
    policy:
    let
      rustFlags = rustFlagsStringForPolicy policy;
    in
    lib.optionalString (rustFlags != "") ''
      export RUSTFLAGS="''${RUSTFLAGS:+$RUSTFLAGS }${rustFlags}"
    '';

  cargoTargetSelectors = [
    "--all-targets"
    "--lib"
    "--bin"
    "--bins"
    "--example"
    "--examples"
    "--test"
    "--tests"
    "--bench"
    "--benches"
  ];

  hasCargoTargetSelector = cargoArgs: lib.any (arg: builtins.elem arg cargoTargetSelectors) cargoArgs;

  clippyCargoArgs =
    rawArgs: args:
    let
      rawPolicy = rawArgs.policy or { };
      rawClippy = rawPolicy.clippy or { };
    in
    if hasCargoTargetSelector args.cargoArgs && !(rawClippy ? cargoArgs) then
      [ ]
    else
      args.policy.clippy.cargoArgs;

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
        lockFile = cargoLockFile cargoLock;
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
    pname = args.pname or args.name or "rust-package";
    cargoLock = args.cargoLock or (args.src + "/Cargo.lock");
    cargoArgs = args.cargoArgs or [ "--workspace" ];
    rustToolchain = args.rustToolchain or defaultRustToolchain;
    nativeBuildInputs = args.nativeBuildInputs or [ ];
    env = args.env or { };
    cargoExtraConfig = args.cargoExtraConfig or "";
    vendorDir = args.vendorDir or null;
    outputHashes = args.outputHashes or { };
    policy = resolvePolicy (args.policy or { });
  };

  policyCheckArgs =
    rawArgs:
    let
      args = commonArgs rawArgs;
      vendorDir = resolveVendorDir {
        inherit (args) cargoLock outputHashes vendorDir;
      };
    in
    args // { inherit vendorDir; };

  mkdirOut = ''
    mkdir -p "$out"
  '';

  linkPolicyChecks =
    policyChecks:
    lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: check: "ln -s ${check} \"$out/rust-policy/${name}\"") policyChecks
    );

  cargoAuditCheck =
    rawArgs:
    let
      args = commonArgs rawArgs;
      inherit (args.policy) cargoAudit;
      auditFlags = [
        "audit"
        "--file"
        (builtins.toString (cargoLockFile args.cargoLock))
        "--db"
        (builtins.toString cargoAudit.db)
        "--no-fetch"
        "--stale"
      ]
      ++ lib.concatMap (deny: [
        "--deny"
        deny
      ]) cargoAudit.deny
      ++ lib.concatMap (advisory: [
        "--ignore"
        advisory
      ]) cargoAudit.ignore;
    in
    pkgs.runCommand "${args.pname}-cargo-audit"
      {
        nativeBuildInputs = [ pkgs.cargo-audit ];
      }
      ''
        export CARGO_HOME="$TMPDIR/cargo-home"
        mkdir -p "$CARGO_HOME"
        cargo-audit ${lib.escapeShellArgs auditFlags}
        ${mkdirOut}
      '';

  cargoMacheteCheck =
    rawArgs:
    let
      args = policyCheckArgs rawArgs;
      macheteArgs = [
        "--with-metadata"
        "--skip-target-dir"
      ]
      ++ args.policy.cargoMachete.extraArgs
      ++ [ "." ];
    in
    pkgs.runCommand "${args.pname}-cargo-machete"
      (
        {
          nativeBuildInputs = [
            args.rustToolchain
            pkgs.cacert
            pkgs.cargo-machete
          ]
          ++ args.nativeBuildInputs;
          SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
          CARGO_NET_OFFLINE = "true";
        }
        // args.env
      )
      ''
        ${vendorConfigScript {
          inherit (args) cargoExtraConfig vendorDir;
        }}

        cd ${args.src}
        cargo-machete ${lib.escapeShellArgs macheteArgs}
        ${mkdirOut}
      '';

  cargoClippyCheck =
    rawArgs:
    let
      args = policyCheckArgs rawArgs;
      clippyArgs = [
        "clippy"
        "--frozen"
        "--offline"
      ]
      ++ args.cargoArgs
      ++ clippyCargoArgs rawArgs args
      ++ lib.optionals args.policy.clippy.denyWarnings [
        "--"
        "-D"
        "warnings"
      ];
    in
    pkgs.runCommand "${args.pname}-cargo-clippy"
      (
        {
          nativeBuildInputs = [
            args.rustToolchain
            pkgs.cacert
            pkgs.clippy
            pkgs.stdenv.cc
          ]
          ++ args.nativeBuildInputs
          ++ nativeBuildInputsForPolicy args.policy;
          SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
        }
        // args.env
      )
      ''
        ${vendorConfigScript {
          inherit (args) cargoExtraConfig vendorDir;
        }}

        export CARGO_TARGET_DIR="$TMPDIR/cargo-target"
        ${exportRustFlagsScript args.policy}
        cd ${args.src}
        cargo ${lib.escapeShellArgs clippyArgs}
        ${mkdirOut}
      '';

  policyChecksFor =
    rawArgs:
    let
      args = commonArgs rawArgs;
    in
    lib.optionalAttrs args.policy.cargoAudit.enable {
      cargoAudit = cargoAuditCheck rawArgs;
    }
    // lib.optionalAttrs args.policy.cargoMachete.enable {
      cargoMachete = cargoMacheteCheck rawArgs;
    }
    // lib.optionalAttrs args.policy.clippy.enable {
      cargoClippy = cargoClippyCheck rawArgs;
    };

  withPolicyChecks =
    {
      package,
      policyChecks,
      extraTests ? { },
      extraPassthru ? { },
    }:
    pkgs.symlinkJoin {
      name = "${package.name}-policy-checked";
      paths = [ package ];
      inherit (package) meta;
      passthru =
        (package.passthru or { })
        // extraPassthru
        // {
          unchecked = package;
          inherit policyChecks;
          tests = (package.passthru.tests or { }) // policyChecks // extraTests;
        };
      postBuild = lib.optionalString (policyChecks != { }) ''
        mkdir -p "$out/rust-policy"
        ${linkPolicyChecks policyChecks}
      '';
    };

  buildPackage =
    rawArgs:
    let
      args = commonArgs rawArgs;
      testEnabled = args.policy.tests.enable && (rawArgs.doCheck or true);
      rustcArgs = rustcArgsForPolicy args.policy;
      cargoTestFlags =
        (rawArgs.cargoTestFlags or [ ])
        ++ lib.optionals (testEnabled && args.policy.tests.useNextest) [ "--no-tests=pass" ];
      buildArgs =
        builtins.removeAttrs rawArgs [
          "cargoArgs"
          "cargoExtraConfig"
          "cargoTestFlags"
          "outputHashes"
          "policy"
          "rustToolchain"
          "vendorDir"
        ]
        //
          lib.optionalAttrs
            (
              !(rawArgs ? cargoLock)
              && !(rawArgs ? cargoHash)
              && !(rawArgs ? cargoDeps)
              && !(rawArgs ? cargoVendorDir)
            )
            {
              cargoLock.lockFile = cargoLockFile args.cargoLock;
            }
        // {
          nativeBuildInputs = (rawArgs.nativeBuildInputs or [ ]) ++ nativeBuildInputsForPolicy args.policy;
          inherit cargoTestFlags;
          useNextest = rawArgs.useNextest or (testEnabled && args.policy.tests.useNextest);
        }
        // lib.optionalAttrs (rustcArgs != [ ]) {
          RUSTFLAGS = (lib.toList (rawArgs.RUSTFLAGS or [ ])) ++ rustcArgs;
        };
      uncheckedPackage = pkgs.rustPlatform.buildRustPackage buildArgs;
      policyChecks = policyChecksFor rawArgs;
    in
    withPolicyChecks {
      package = uncheckedPackage;
      inherit policyChecks;
      extraPassthru = {
        inherit (args) policy;
      };
      extraTests = lib.optionalAttrs testEnabled {
        package = uncheckedPackage;
      };
    };
in
{
  inherit
    buildPackage
    cargoAuditCheck
    cargoClippyCheck
    cargoMacheteCheck
    cargoLockFile
    defaultPolicy
    defaultRustToolchain
    defaultRustsecAdvisoryDb
    nativeBuildInputsForPolicy
    policyChecksFor
    resolvePolicy
    resolveVendorDir
    rustcArgsForPolicy
    rustFlagsStringForPolicy
    vendorConfigScript
    withPolicyChecks
    ;
}
