# Versioned overlays for the minecraft image.
#
# Each top-level key (other than `default`) is a NixOS module merged on top
# of `./default.nix`. Discovery exposes:
#   - `minecraft_<key>` for every version key
#   - `minecraft` as an alias for the version named in `default`
#
# Loaders compose: enable `services.minecraft.<loader>` to wire up a server
# jar. Each loader file (modules/services/minecraft/{fabric,paper,vanilla}.nix)
# documents its required fields. Hashes are SRI strings — get one by setting
# hash = lib.fakeHash, building, and copying the value Nix prints.
{
  default = "26w17a-fabric";

  "26w17a-fabric" = {
    ix.image.tag = "26w17a-fabric";
    services.minecraft.fabric = {
      enable = true;
      minecraftVersion = "26.2-snapshot-5";
      loaderVersion = "0.19.2";
      installerVersion = "1.1.1";
      hash = "sha256-IZctWQu9VH4Z5lU/VcEzvPGLfW8boOAXtCaQlKXyA5k=";
    };
  };

  # Add more variants the same way. Examples:
  #
  # "1.21.1-paper" = {
  #   ix.image.tag = "1.21.1-paper";
  #   services.minecraft.paper = {
  #     enable = true;
  #     minecraftVersion = "1.21.1";
  #     build = 132;
  #     hash = "sha256-...";
  #   };
  # };
  #
  # "1.21.1-vanilla" = {
  #   ix.image.tag = "1.21.1-vanilla";
  #   services.minecraft.vanilla = {
  #     enable = true;
  #     url = "https://piston-data.mojang.com/v1/objects/<obj>/server.jar";
  #     hash = "sha256-...";
  #   };
  # };
}
