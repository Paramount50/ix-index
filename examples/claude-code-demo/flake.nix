{
  inputs = {
    artifact-minecraft-server-26-2-snapshot-6-fabric = {
      url = "https://meta.fabricmc.net/v2/versions/loader/26.2-snapshot-6/0.19.2/1.1.1/server/jar";
      flake = false;
    };
    index.url = "github:indexable-inc/index";
  };

  outputs =
    {
      artifact-minecraft-server-26-2-snapshot-6-fabric,
      index,
      ...
    }:
    let
      ix = index;
      inherit (index.lib.pkgs) lib;
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
      forSystems = f: builtins.listToAttrs (map f systems);
      fleetFor =
        hostSystem:
        import ./default.nix {
          inherit ix hostSystem;
          minecraftServer = artifact-minecraft-server-26-2-snapshot-6-fabric;
        };
    in
    {
      apps = forSystems (
        system:
        let
          fleet = fleetFor system;
        in
        {
          name = system;
          value = {
            switch = {
              type = "app";
              program = lib.getExe fleet.switch;
            };

            plan = {
              type = "app";
              program = lib.getExe fleet.planCommand;
            };

            diff = {
              type = "app";
              program = lib.getExe fleet.diff;
            };

            replace = {
              type = "app";
              program = lib.getExe fleet.replace;
            };
          };
        }
      );

      packages = forSystems (
        system:
        let
          fleet = fleetFor system;
        in
        {
          name = system;
          value =
            fleet.packages
            // fleet.systemPackages
            // {
              inherit (fleet)
                command
                diff
                planCommand
                replace
                switch
                ;
            };
        }
      );
    };
}
