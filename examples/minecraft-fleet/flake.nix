{
  inputs.ix-images.url = "github:indexable-inc/images";

  outputs =
    { ix-images, ... }:
    let
      ix = ix-images;
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
      fleetFor = hostSystem: import ./default.nix { inherit ix hostSystem; };
    in
    {
      apps = builtins.listToAttrs (
        map (system: {
          name = system;
          value =
            let
              fleet = fleetFor system;
            in
            {
              switch = {
                type = "app";
                program = "${fleet.switch}/bin/ix-fleet-switch";
              };

              plan = {
                type = "app";
                program = "${fleet.command}/bin/ix-fleet";
              };

              replace = {
                type = "app";
                program = "${fleet.command}/bin/ix-fleet";
              };
            };
        }) systems
      );

      packages = builtins.listToAttrs (
        map (system: {
          name = system;
          value =
            let
              fleet = fleetFor system;
            in
            fleet.packages
            // fleet.systemPackages
            // {
              inherit (fleet) command switch;
            };
        }) systems
      );
    };
}
