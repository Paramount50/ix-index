# Minecraft server image.
#
# This file is the version-agnostic base. Per-version data (upstream version
# strings, server JAR hash, mod selection) lives in `./versions.nix` as
# overlay modules layered on top of this one by `lib.discoverImages`.
#
# Cross-version baseline mods come from the shared `common` catalog under
# `ix.artifacts.minecraft.modCatalogs`. Every variant gets these for free;
# per-version mods are added by the version overlay. Catalog data is owned
# by the library (see `lib/default.nix`); update it through `nix run .#update-mods`.
{ ix, lib, ... }:
let
  commonCatalog = ix.artifacts.minecraft.modCatalogs.common;
in
{
  ix.image.name = "minecraft";

  services.minecraft = {
    enable = true;
    serverFiles."server.properties" = {
      motd = "ix-powered Minecraft";
      max-players = 20;
    };
    mods = lib.mapAttrs (_: _: { }) commonCatalog;
    modCatalog = commonCatalog;
  };
}
