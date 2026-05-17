{
  inputs.index.url = "github:indexable-inc/index";

  outputs =
    { index, ... }:
    let
      fleet = import ./default.nix { inherit index; };
      package = import ./package.nix {
        ix = index.lib;
        inherit (index.lib.pkgs) lib;
      };
    in
    {
      apps.x86_64-linux = {
        plan = {
          type = "app";
          program = "${fleet.planCommand}/bin/ix-fleet-plan";
        };

        diff = {
          type = "app";
          program = "${fleet.diff}/bin/ix-fleet-diff";
        };

        up = {
          type = "app";
          program = "${fleet.up}/bin/ix-fleet-up";
        };

        switch = {
          type = "app";
          program = "${fleet.switch}/bin/ix-fleet-switch";
        };

        replace = {
          type = "app";
          program = "${fleet.replace}/bin/ix-fleet-replace";
        };
      };

      packages.x86_64-linux = fleet.packages // {
        daily-scraper = package;
        inherit (fleet)
          command
          diff
          planCommand
          replace
          switch
          up
          ;
      };
    };
}
