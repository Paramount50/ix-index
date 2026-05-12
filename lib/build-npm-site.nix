# Build a static frontend site from an npm project, with no manually managed
# dependency hash. `pkgs.importNpmLock` reads per-package integrity hashes
# straight from `package-lock.json`, so updating dependencies is just
# `npm install` plus a commit. The build runs `npm run <buildScript>`
# (default `build`) which should invoke svelte-check / eslint / vite or
# whatever the project's checks are, so the same checks gate local dev and
# Nix builds.
pkgs:
{
  pname,
  version ? "0.0.0",
  src,
  buildScript ? "build",
  distDir ? "dist",
  installDir ? "share/${pname}",
  extraNativeBuildInputs ? [ ],
  meta ? { },
}:
pkgs.stdenvNoCC.mkDerivation {
  inherit
    pname
    version
    src
    meta
    ;

  strictDeps = true;

  npmDeps = pkgs.importNpmLock.buildNodeModules {
    npmRoot = src;
    inherit (pkgs) nodejs;
  };

  nativeBuildInputs = [
    pkgs.nodejs
    pkgs.importNpmLock.npmConfigHook
  ]
  ++ extraNativeBuildInputs;

  buildPhase = ''
    runHook preBuild
    npm run ${buildScript}
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/${installDir}"
    cp -R "${distDir}/." "$out/${installDir}/"
    runHook postInstall
  '';
}
