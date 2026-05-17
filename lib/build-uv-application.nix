{
  uvLockFor,
}:

/**
  Build a Python application from a uv project.

  Dependency hashes come from `uv.lock`, so callers update dependencies with
  `uv lock` and do not maintain a separate Nix dependency hash. Locked
  distributions are fetched into a wheelhouse, installed offline into a virtual
  environment, and the local project is built as a wheel before installation.

  The default path supports registry packages with `wheels` or `sdist` entries
  in `uv.lock`. Projects that use a non-uv build backend may need to pass a
  `python` with that backend available and add `--no-build-isolation` through
  `buildFlags`.

  Arguments:
  - `pname`, `version`: derivation identity.
  - `src`: project root containing `pyproject.toml` and `uv.lock`.
  - `python`: Python interpreter used for the virtual environment.
  - `mainProgram`: executable to expose under `$out/bin`.
  - `dependencyGroups`, `extras`: uv dependency groups and extras to install.
  - `exportFlags`, `pipInstallFlags`, `buildFlags`: extra uv flags.
  - `extraNativeBuildInputs`: extra packages on PATH for the build.
  - `fetcherOpts`: per-package fetcher overrides for locked distributions.
  - `meta`: standard derivation meta.
*/
pkgs:
{
  pname,
  version ? "0.0.0",
  src,
  python ? pkgs.python3,
  mainProgram ? pname,
  dependencyGroups ? [ ],
  extras ? [ ],
  exportFlags ? [ ],
  pipInstallFlags ? [ ],
  buildFlags ? [ ],
  extraNativeBuildInputs ? [ ],
  fetcherOpts ? { },
  meta ? { },
}:
let
  inherit (pkgs) lib;

  uvLock = uvLockFor pkgs;
  uvWheelhouse = uvLock.buildWheelhouse {
    uvRoot = src;
    inherit fetcherOpts;
  };
  pythonExecutable = lib.getExe python;
  groupFlags = lib.concatMap (group: [
    "--group"
    group
  ]) dependencyGroups;
  extraFlags = lib.concatMap (extra: [
    "--extra"
    extra
  ]) extras;
  exportArgs = [
    "--frozen"
    "--no-dev"
    "--no-emit-project"
    "--no-editable"
    "--format"
    "requirements.txt"
  ]
  ++ groupFlags
  ++ extraFlags
  ++ exportFlags;
  pipInstallArgs = [
    "--offline"
    "--no-index"
    "--find-links"
    "${uvWheelhouse}"
    "--requirements"
    "requirements.txt"
  ]
  ++ pipInstallFlags;
  buildArgs = [
    "--wheel"
    "--offline"
    "--no-index"
    "--find-links"
    "${uvWheelhouse}"
    "--python"
    pythonExecutable
    "--no-managed-python"
    "--no-python-downloads"
    "--out-dir"
    "dist"
  ]
  ++ buildFlags;
in
pkgs.stdenvNoCC.mkDerivation (_: {
  inherit
    pname
    version
    src
    uvWheelhouse
    ;

  strictDeps = true;

  nativeBuildInputs = [
    pkgs.uv
    python
  ]
  ++ extraNativeBuildInputs;

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    export HOME="$TMPDIR/home"
    export UV_CACHE_DIR="$TMPDIR/uv-cache"
    mkdir -p "$HOME" "$UV_CACHE_DIR" "$out/bin"

    uv export ${lib.escapeShellArgs exportArgs} --output-file requirements.txt
    ${pythonExecutable} -m venv "$out/venv"
    uv pip install ${lib.escapeShellArgs pipInstallArgs} --python "$out/venv/bin/python"
    uv build ${lib.escapeShellArgs buildArgs}
    uv pip install \
      --offline \
      --no-index \
      --find-links dist \
      --python "$out/venv/bin/python" \
      dist/*.whl

    test -x "$out/venv/bin/${mainProgram}"
    ln -s "$out/venv/bin/${mainProgram}" "$out/bin/${mainProgram}"

    runHook postInstall
  '';

  passthru = {
    inherit uvWheelhouse;
  };

  meta = meta // {
    mainProgram = meta.mainProgram or mainProgram;
  };
})
