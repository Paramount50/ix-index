# ix/images public lib.
#
# `mkIxImage` builds one self-contained OCI archive from a list of NixOS
# modules. Each image is independent: ix does not stack images at runtime, it
# runs one. `./ix-base.nix` is the implicit base layer (container marker, OCI
# packaging, base profile enabled by default). The `../modules` registry is
# pulled in so option declarations are available to every image, but each
# module is gated on its own `enable` flag and stays inert unless the image
# turns it on.
#
# `discoverImages` walks `images/<category>/<name>/` and turns each directory
# into a flake package. If a directory has a `versions.nix` sibling, every
# version produces `<name>_<ver>` and the `default` key picks the unsuffixed
# `<name>` alias.
#
# `mkMinecraftLoader` is one of several cross-cutting helpers exposed to
# modules via `specialArgs.ix`. Modules access them as `{ ix, ... }: ix.foo`
# instead of relative-path imports.
{
  nixpkgs,
  llm-agents,
  claude-code-nix,
  codex-cli-nix,
}:
let
  inherit (nixpkgs) lib;

  system = "x86_64-linux";

  # Overlays: llm-agents base + claude/codex from dedicated flakes.
  overlays = [
    llm-agents.overlays.default
    (final: prev: {
      llm-agents = prev.llm-agents // {
        claude-code = claude-code-nix.packages.${final.stdenv.hostPlatform.system}.claude-code;
        codex = codex-cli-nix.packages.${final.stdenv.hostPlatform.system}.codex;
      };
    })
  ];

  # The module registry. collect picks all leaf paths from the nested attrset.
  moduleList = lib.collect builtins.isPath (import ../modules);

  mkMinecraftLoader = import ./minecraft-loader.nix;

  # Helpers exposed to every module via specialArgs. Keep this surface small
  # and stable: anything here is part of the cross-module contract.
  ixSpecialArgs = {
    inherit mkMinecraftLoader;
  };

  mkIxImage =
    {
      modules ? [ ],
    }:
    (lib.nixosSystem {
      specialArgs.ix = ixSpecialArgs;
      modules = [
        { nixpkgs.overlays = overlays; }
        ./ix-platform.nix
        ./ix-oci-layer.nix
      ] ++ moduleList ++ modules;
    }).config.ix.build.ociImage;

  # Subdirectories of `dir`. Used to walk images/<cat>/<name>/.
  subdirs =
    dir:
    let
      entries = builtins.readDir dir;
    in
    lib.filter (n: entries.${n} == "directory") (builtins.attrNames entries);

  # One image directory -> { <name> = pkg; <name>_<ver> = pkg; ... }.
  # Without versions.nix, the dir is a single module.
  # With versions.nix, each version is layered on top of the base module and
  # the `default` key picks which version gets the unsuffixed alias.
  imagePackages =
    name: path:
    let
      versionsPath = path + "/versions.nix";
    in
    if builtins.pathExists versionsPath then
      let
        versions = import versionsPath { inherit lib; };
        defaultVer = versions.default;
        verMods = builtins.removeAttrs versions [ "default" ];
        verPkgs = lib.mapAttrs' (
          ver: mod:
          lib.nameValuePair "${name}_${ver}" (mkIxImage {
            modules = [
              path
              mod
            ];
          })
        ) verMods;
        defaultKey = "${name}_${defaultVer}";
      in
      assert lib.assertMsg (builtins.hasAttr defaultKey verPkgs)
        "image '${name}': versions.nix default = \"${defaultVer}\" but no version with that key";
      verPkgs // { ${name} = verPkgs.${defaultKey}; }
    else
      { ${name} = mkIxImage { modules = [ path ]; }; };

  discoverImages =
    root:
    lib.foldl' (
      acc: cat:
      lib.foldl' (acc': name: acc' // imagePackages name (root + "/${cat}/${name}")) acc (
        subdirs (root + "/${cat}")
      )
    ) { } (subdirs root);
in
{
  inherit
    system
    mkIxImage
    discoverImages
    mkMinecraftLoader
    ;
}
