{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    ix-images.url = "github:indexable-inc/images";
    ix-images.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { ix-images, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
      image = ix-images.lib.mkImage {
        modules = [
          (
            { pkgs, ... }:
            {
              ix.image.name = "my-image";
              environment.systemPackages = [
                pkgs.curl
                pkgs.htop
              ];
              services.git-clone = {
                enable = true;
                url = "https://github.com/torvalds/linux.git";
              };
            }
          )
        ];
      };
    in
    {
      packages = builtins.listToAttrs (
        map (system: {
          name = system;
          value.default = image;
        }) systems
      );
    };
}
