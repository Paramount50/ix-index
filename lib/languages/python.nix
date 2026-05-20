{ errors }:
let
  /**
    Mapping from human version strings (`"3.12"`) to the matching
    nixpkgs interpreter attribute. Listed explicitly so the error from
    an unknown version names the supported set; bump the top entry when
    the platform follows nixpkgs onto a newer Python.
  */
  interpretersFor = pkgs: {
    "3.10" = pkgs.python310;
    "3.11" = pkgs.python311;
    "3.12" = pkgs.python312;
    "3.13" = pkgs.python313;
    "3.14" = pkgs.python314;
  };

  defaultVersion = "3.14";
in
/**
  Return the nixpkgs Python interpreter for `version`.

  `version` is a `major.minor` string matching one of the supported
  entries; unknown versions throw with the supported set listed so a
  typo or a too-new pin is fixable from the error message alone.

  The default tracks `writePythonApplication` and `buildUvApplication`
  so callers that only need the same interpreter the rest of the repo
  uses do not have to repeat the version string.

  Arguments:
  - `pkgs`: nixpkgs instance to look the interpreter up in. Modules pass
    their own `pkgs` so the returned package is from the image's
    evaluation rather than the lib's default.
  - `version`: optional `major.minor` string. Defaults to `"3.14"`.

  Example:
  ```nix
  { pkgs, ix, ... }:
  let python = ix.languages.python pkgs { version = "3.12"; };
  in { environment.systemPackages = [ python ]; }
  ```
*/
pkgs:
{
  version ? defaultVersion,
}:
errors.requireAttr {
  context = "ix.languages.python: unknown version";
  attrset = interpretersFor pkgs;
  key = version;
}
