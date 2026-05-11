{
  inputs.index.url = "github:indexable-inc/index";

  outputs =
    { index, ... }:
    let
      ix = index;
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
      forSystems = f: builtins.listToAttrs (map f systems);
      fleetFor = hostSystem: import ./default.nix { inherit ix hostSystem; };
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
              program = "${fleet.switch}/bin/ix-fleet-switch";
            };

            plan = {
              type = "app";
              program = "${fleet.planCommand}/bin/ix-fleet-plan";
            };

            diff = {
              type = "app";
              program = "${fleet.diff}/bin/ix-fleet-diff";
            };

            replace = {
              type = "app";
              program = "${fleet.replace}/bin/ix-fleet-replace";
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
          value = fleet.packages // fleet.systemPackages // {
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
