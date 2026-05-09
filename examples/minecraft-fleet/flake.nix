{
  inputs.ix-images.url = "github:indexable-inc/images";

  outputs =
    { ix-images, ... }:
    let
      ix = ix-images;
      fleet = import ./default.nix { inherit ix; };
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
    in
    {
      apps.x86_64-linux = {
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

      packages = builtins.listToAttrs (
        map (system: {
          name = system;
          value = fleet.packages // {
            inherit (fleet) command switch;
          };
        }) systems
      );
    };
}
