{
  description = "Pre-built OCI images for ix VMs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    {
      nixpkgs,
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
        examples.claudeCodeDemo = ./examples/claude-code-demo;
        minecraftMods = ./images/games/minecraft/mods;
        packages = {
          minecraftHotReloadAgent = ./packages/minecraft-hot-reload-agent;
          minecraftRcon = ./packages/minecraft-rcon;
          minecraftSyncManaged = ./packages/minecraft-sync-managed;
          minestom.servers.hello = ./packages/minestom/servers/hello;
          ociImageBuilder = ./packages/oci-image-builder;
          tonboArtifacts = ./packages/tonbo-artifacts;
        };
        tools = {
          ixFleet = ./tools/ix-fleet.py;
          updateMods = ./tools/update-mods.py;
        };
      };

      ix = import ./lib {
        inherit nixpkgs paths;
      };
      devSystems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
      perSystem = lib.genAttrs devSystems (
        system:
        import ./lib/per-system.nix {
          inherit
            system
            ix
            nixpkgs
            paths
            ;
        }
      );
      collect = key: lib.mapAttrs (_: out: out.${key}) perSystem;
    in
    {
      lib = ix;
      nixosModules = import ./modules;
      overlays.default = ix.overlay;
      templates.default = {
        path = ./template;
        description = "Starter ix image";
      };
      packages = collect "packages";
      apps = collect "apps";
      checks = collect "checks";
      formatter = collect "formatter";
    };
}
