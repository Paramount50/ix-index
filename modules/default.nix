# Module registry. Single source of truth for both:
#   - `nixosSystem { modules = ... }` (consumed via attrValues by lib/)
#   - the `modules` flake output (consumed by external users who want one
#     module without depending on ix-base)
#
# Every module is gated on its own `enable` flag. Listing it here only makes
# the options visible; it does not turn anything on. The one exception is
# `profiles/base.nix`, which `ix-base.nix` enables by default.
{
  base = ./profiles/base.nix;
  git-clone = ./services/git-clone.nix;
  minecraft = ./services/minecraft;
  postgresql = ./services/postgresql.nix;
  minecraft-fabric = ./services/minecraft/fabric.nix;
  minecraft-paper = ./services/minecraft/paper.nix;
  minecraft-vanilla = ./services/minecraft/vanilla.nix;
  minecraft-mod-bluemap = ./services/minecraft/mods/bluemap.nix;
  minecraft-mod-distant-horizons = ./services/minecraft/mods/distant-horizons.nix;
  remote-desktop = ./services/remote-desktop.nix;
}
