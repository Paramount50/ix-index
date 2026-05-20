{ lib }:
let
  inherit (lib) concatStringsSep filterAttrs attrNames;
  inherit (builtins) elem head length;

  enabledKeys = options: attrNames (filterAttrs (_: v: v == true) options);
in
{
  /**
    Validate that `value` is one of `valid`. Returns `value` unchanged on
    success; throws naming the option and listing every valid alternative
    on failure.

    Use at option boundaries where `lib.types.enum` is the right shape but
    the consumer wants the value back as an expression (a `let` binding,
    a default that derives from another option, etc).

    Arguments:
    - `name`: human-readable option path used in the error message
      (for example `"languages.rust.channel"`).
    - `value`: the value supplied by the caller.
    - `valid`: list of accepted values.

    Returns the validated `value`.
  */
  assertEnum =
    {
      name,
      value,
      valid,
    }:
    if elem value valid then
      value
    else
      throw "ix: invalid ${name} = ${toString value}. Valid values: ${concatStringsSep ", " valid}.";

  /**
    Assert that at most one of the boolean flags in `options` is true.

    The `context` string heads the error and should name the surface the
    flags belong to (for example `"services.rust: linker selection"`). On
    failure the message lists every flag the caller declared and which
    ones were set to `true`, so the conflict is fixable without reading
    the module source.

    Returns `null` on success so the call can be sequenced inside a `let`
    binding before the value that depends on the assertion.
  */
  atMostOne =
    {
      context,
      options,
    }:
    let
      enabled = enabledKeys options;
      keys = attrNames options;
    in
    if length enabled <= 1 then
      null
    else
      throw ''
        ix: ${context}
          At most one of [${concatStringsSep ", " keys}] may be true.
          Got: ${concatStringsSep ", " enabled}.
      '';

  /**
    Assert that exactly one of the boolean flags in `options` is true.
    Returns the name of the chosen flag, so the caller can use the result
    to select a downstream value without re-checking the booleans.

    Errors distinguish "none set" from "multiple set" because the fix
    is different in each case.
  */
  exactlyOne =
    {
      context,
      options,
    }:
    let
      enabled = enabledKeys options;
      keys = attrNames options;
    in
    if length enabled == 1 then
      head enabled
    else if enabled == [ ] then
      throw ''
        ix: ${context}
          Exactly one of [${concatStringsSep ", " keys}] must be true.
          Got: none.
      ''
    else
      throw ''
        ix: ${context}
          Exactly one of [${concatStringsSep ", " keys}] must be true.
          Got: ${concatStringsSep ", " enabled}.
      '';

  /**
    Look up `key` in `attrset` and return the value. Throws with the list
    of available keys when the lookup misses, so a typo in a catalog key
    or a missing entry produces a fixable error instead of `attribute
    'foo' missing` from somewhere deep in eval.

    `context` should name the lookup surface (for example
    `"services.minecraft.modCatalog"`).
  */
  requireAttr =
    {
      context,
      attrset,
      key,
    }:
    attrset.${key} or (throw ''
      ix: ${context}
        Missing key '${toString key}'. Available: ${concatStringsSep ", " (attrNames attrset)}.
    '');

  /**
    Return `inputs.${name}` if present; otherwise throw with a ready-to-paste
    `flake.nix` snippet that adds the input. `usedBy` names the consuming
    option or helper, so the message points back to the caller that needs
    the input. `follows` lists inputs that should pin through nixpkgs (or
    similar) and is reflected in the snippet.

    Pattern borrowed from [devenv's `getInput`](https://github.com/cachix/devenv/blob/main/src/modules/lib.nix);
    adapted for this repo's single-flake layout (no `devenv.yaml`).
  */
  requireInput =
    {
      inputs,
      name,
      url,
      usedBy,
      follows ? [ ],
    }:
    inputs.${name} or (throw ''
      ix: ${usedBy} requires the '${name}' flake input.

      Add to flake.nix:
        inputs.${name}.url = "${url}";${
          if follows == [ ] then
            ""
          else
            "\n" + concatStringsSep "\n" (map (i: "  inputs.${name}.inputs.${i}.follows = \"${i}\";") follows)
        }
    '');
}
