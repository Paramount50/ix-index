{
  lib,
  pkgs,
}:
let
  fromUvHash =
    hash:
    let
      parts = lib.splitString ":" hash;
    in
    if builtins.length parts == 2 then
      builtins.convertHash {
        hashAlgo = builtins.elemAt parts 0;
        hash = builtins.elemAt parts 1;
        toHashFormat = "sri";
      }
    else
      hash;

  packageKey = lockedPackage: "${lockedPackage.name}-${lockedPackage.version}";

  distributionFor =
    lockedPackage: distribution:
    assert lib.assertMsg (
      distribution ? url
    ) "uv.lock package ${packageKey lockedPackage} has a distribution without a url";
    assert lib.assertMsg (
      distribution ? hash
    ) "uv.lock package ${packageKey lockedPackage} distribution ${distribution.url} is missing a hash";
    {
      inherit (lockedPackage) name version;
      inherit (distribution) url;
      fileName = builtins.baseNameOf distribution.url;
      hash = fromUvHash distribution.hash;
      key = packageKey lockedPackage;
    };

  distributionsFor =
    lockedPackage:
    let
      wheels = lockedPackage.wheels or [ ];
      sdist = lib.optional (lockedPackage ? sdist) lockedPackage.sdist;
    in
    map (distributionFor lockedPackage) (wheels ++ sdist);

  self = {
    /**
      Parse a `uv.lock` file into normalized package and distribution metadata.

      Only locked archive distributions are fetched: registry packages with
      `wheels` and/or `sdist` entries. Local workspace packages remain in the
      source tree and are built by `uv` during the application build.

      Arguments:
      - `uvRoot`: project root containing `uv.lock`.
      - `uvLock`: optional lockfile contents override.

      Returns:
      - `raw`: parsed TOML lockfile.
      - `packages`: lockfile package entries.
      - `distributions`: normalized archive entries with SRI hashes.
    */
    importLock =
      {
        uvRoot,
        uvLock ? builtins.readFile (uvRoot + "/uv.lock"),
      }:
      let
        raw = builtins.fromTOML uvLock;
        packages = raw.package or [ ];
      in
      {
        inherit raw packages;
        distributions = lib.concatMap distributionsFor packages;
      };

    /**
      Build a wheelhouse from the archive distributions pinned in `uv.lock`.

      The resulting directory contains symlinks named like the original wheel or
      sdist files. It is suitable for `uv pip install --no-index --find-links`.

      Arguments:
      - `uvRoot`: project root containing `uv.lock`.
      - `uvLock`: optional lockfile contents override.
      - `fetcherOpts`: per-package fetcher overrides keyed by
        `<name>-<version>`, for unusual URLs that need extra `fetchurl` flags.

      Returns a derivation with `passthru.lock` containing the parsed metadata.
    */
    buildWheelhouse =
      {
        uvRoot,
        uvLock ? builtins.readFile (uvRoot + "/uv.lock"),
        fetcherOpts ? { },
      }:
      let
        lock = self.importLock { inherit uvRoot uvLock; };
        fetchedDistributions = map (distribution: {
          inherit distribution;
          src = pkgs.fetchurl (
            {
              inherit (distribution) url hash;
              name = distribution.fileName;
            }
            // (fetcherOpts.${distribution.key} or { })
          );
        }) lock.distributions;
      in
      pkgs.runCommand "uv-wheelhouse"
        {
          passthru = {
            inherit lock;
          };
        }
        ''
          mkdir -p "$out"
          ${lib.concatMapStringsSep "\n" (fetchedDistribution: ''
            ln -sf ${lib.escapeShellArg "${fetchedDistribution.src}"} "$out"/${lib.escapeShellArg fetchedDistribution.distribution.fileName}
          '') fetchedDistributions}
        '';
  };
in
self
