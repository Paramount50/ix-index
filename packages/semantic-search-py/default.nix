{
  ix,
  lib,
  pkgs ? ix.pkgs,
}:
let
  pyproject = lib.importTOML ./pyproject.toml;
  inherit (pyproject.project) version;

  # The PyO3 cdylib is already built by the shared workspace unit graph (the
  # same one mcp selects its binary from), so the wheel is just packaging: no
  # maturin, no second compile.
  library = ix.rustWorkspace.units.libraries.semantic_search_py;

  # Linux-only: the package set restricts semantic-search-py to Linux (see
  # package.nix), so only the manylinux tags are reachable here.
  platformTag =
    {
      x86_64-linux = "manylinux_2_34_x86_64";
      aarch64-linux = "manylinux_2_34_aarch64";
    }
    .${pkgs.stdenv.hostPlatform.system}
      or (throw "semantic-search-py: wheel is Linux-only, got ${pkgs.stdenv.hostPlatform.system}");

  pythonSource = builtins.path {
    name = "semantic-search-py-python-source";
    path = ./python;
  };
in
pkgs.runCommand "ix-semantic-search-wheel"
  {
    strictDeps = true;
    nativeBuildInputs = [
      pkgs.coreutils
      pkgs.python3
      pkgs.patchelf
      pkgs.removeReferencesTo
    ];
    passthru = { inherit library; };
    meta.description = "ix-semantic-search Python wheel (PyO3 bindings for content-addressed code search)";
  }
  ''
    set -euo pipefail

    cdylib=""
    for candidate in \
      ${library}/lib/libsemantic_search_py.so \
      ${library}/lib/libsemantic_search_py-*.so \
      ${library}/lib/libsemantic_search_py.dylib \
      ${library}/lib/libsemantic_search_py-*.dylib
    do
      if [ -f "$candidate" ]; then
        cdylib="$candidate"
        break
      fi
    done
    if [ -z "$cdylib" ]; then
      echo "semantic-search-py: no cdylib under ${library}/lib" >&2
      ls -la ${library}/lib >&2 || true
      exit 1
    fi

    sanitized="$TMPDIR/$(basename "$cdylib")"
    cp "$cdylib" "$sanitized"
    chmod u+w "$sanitized"

    # Strip the build-time rpath and nixpkgs toolchain references so the wheel
    # is not pinned to this store path.
    if patchelf --print-rpath "$sanitized" >/dev/null 2>&1; then
      patchelf --remove-rpath "$sanitized"
    fi
    remove-references-to \
      -t ${pkgs.glibc} \
      -t ${pkgs.stdenv.cc.cc.lib} \
      "$sanitized"

    mkdir -p "$out"
    python3 ${./wheel/mkwheel.py} \
      --cdylib "$sanitized" \
      --python-src ${pythonSource} \
      --version ${version} \
      --platform-tag ${platformTag} \
      --out "$out"
  ''
