{
  description = "Pre-built OCI images for ix VMs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    rust-overlay.url = "github:oxalica/rust-overlay";
    ixCliX86_64Linux = {
      url = "https://ix.dev/cli/linux-x86_64/ix";
      flake = false;
    };
    ixCliAarch64Darwin = {
      url = "https://ix.dev/cli/darwin-arm64/ix";
      flake = false;
    };
    ixCliX86_64Darwin = {
      url = "https://ix.dev/cli/darwin-x86_64/ix";
      flake = false;
    };
  };

  outputs =
    {
      nixpkgs,
      rust-overlay,
      ixCliAarch64Darwin,
      ixCliX86_64Linux,
      ixCliX86_64Darwin,
      ...
    }:
    let
      inherit (nixpkgs) lib;

      # All path literals the flake exposes. Centralized so lib/ and
      # lib/per-system.nix have a single source of truth.
      paths = {
        root = ./.;
        images = ./images;
        modules = ./modules;
        tests = ./tests;
        bench.filesystem = ./bench/filesystem;
        minecraftMods = ./images/games/minecraft/mods;
        minecraftPaperPlugins = ./images/games/minecraft/plugins/paper;
        packages = {
          ix = ./packages/ix;
          hyperion = ./packages/hyperion;
          ixFleet = ./packages/ix-fleet;
          minecraftHotReloadAgent = ./packages/minecraft-hot-reload-agent;
          minecraftNbt = ./packages/minecraft-nbt;
          minecraftRcon = ./packages/minecraft-rcon;
          minecraftSyncManaged = ./packages/minecraft-sync-managed;
          llmClippy = ./packages/llm-clippy;
          minestom.servers.hello = ./packages/minestom/servers/hello;
          nixCargoUnit = ./packages/nix-cargo-unit;
          ociImageBuilder = ./packages/oci-image-builder;
          pythonMcpServer = ./packages/python-mcp-server;
          tonboArtifacts = ./packages/tonbo-artifacts;
        };
        tools = {
          ixShellSyncIgnored = ./tools/ix-shell-sync-ignored.py;
          updateMods = ./tools/update-mods.py;
        };
      };

      ix = import ./lib {
        inherit nixpkgs paths rust-overlay;
        cliArtifacts = {
          aarch64-darwin = ixCliAarch64Darwin;
          x86_64-linux = ixCliX86_64Linux;
          x86_64-darwin = ixCliX86_64Darwin;
        };
      };
      devSystems = [
        "x86_64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      perSystem = lib.genAttrs devSystems (
        system:
        import ./lib/per-system.nix {
          inherit
            system
            ix
            nixpkgs
            paths
            rust-overlay
            ;
        }
      );
      collect = key: lib.mapAttrs (_: out: out.${key}) perSystem;
    in
    {
      lib = ix;
      nixosModules = import ./modules;
      overlays.default = ix.overlay;
      packages = collect "packages";
      apps = collect "apps";
      checks = collect "checks";
      formatter = collect "formatter";
    };
}
