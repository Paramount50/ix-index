{
  description = "Pre-built OCI images for ix VMs";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.llm-agents = {
    url = "github:numtide/llm-agents.nix";
    inputs.nixpkgs.follows = "nixpkgs";
  };
  inputs.claude-code-nix = {
    url = "github:sadjow/claude-code-nix";
    inputs.nixpkgs.follows = "nixpkgs";
  };
  inputs.codex-cli-nix = {
    url = "github:sadjow/codex-cli-nix";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      llm-agents,
      claude-code-nix,
      codex-cli-nix,
    }:
    let
      ix = import ./lib {
        inherit
          nixpkgs
          llm-agents
          claude-code-nix
          codex-cli-nix
          ;
      };
      devSystems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
    in
    {
      lib = ix;
      modules = import ./modules;

      packages.${ix.system} = ix.discoverImages ./images;
      checks.${ix.system}.eval = import ./tests { inherit nixpkgs ix; };
      formatter = builtins.listToAttrs (
        map (system: {
          name = system;
          value = nixpkgs.legacyPackages.${system}.nixfmt;
        }) devSystems
      );

      templates.default = {
        path = ./template;
        description = "Starter ix image";
      };

      # Developer tooling. Exposed for both Linux CI and macOS dev machines.
      devShells = builtins.listToAttrs (
        map (system: {
          name = system;
          value.default =
            let
              pkgs = nixpkgs.legacyPackages.${system};
            in
            pkgs.mkShell {
              packages = [
                pkgs.ast-grep
                pkgs.jdk25
                pkgs.maven
                pkgs.nixfmt
              ];

              JAVA_HOME = pkgs.jdk25.home;
            };
        }) devSystems
      );

      apps = builtins.listToAttrs (
        map (system: {
          name = system;
          value.update-mods =
            let
              pkgs = nixpkgs.legacyPackages.${system};
            in
            {
              type = "app";
              program = "${
                pkgs.writeShellApplication {
                  name = "update-mods";
                  runtimeInputs = [ pkgs.python3 ];
                  text = ''exec python3 ${./tools/update-mods.py} "$@"'';
                }
              }/bin/update-mods";
            };
        }) devSystems
      );
    };
}
