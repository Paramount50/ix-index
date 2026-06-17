# Single source of truth for the repo's ruff "explicit + safe" lint selector.
#
# Every Python build gate runs `ruff check ${ruffAnnArgs} <targets>` with these
# args so the policy never drifts across call sites:
#   lib/build/uv-application.nix   (all uv apps)
#   lib/util/writers.nix          (writePythonApplication scripts)
#   packages/mcp/default.nix      (bundled-module strict gate)
#   packages/agent/distiller/default.nix
#   sdk/python/default.nix
#
# Selected rules:
#   * ANN    -- flake8-annotations: explicit annotations everywhere (ANN001 arg
#               types, ANN201 return types, ANN401 bans bare `typing.Any`).
#   * TID251 -- flake8-tidy-imports banned-api: bans `typing.cast`. cast lies to
#               the type checker at zero runtime cost, so a wrong cast is a
#               latent bug no checker can catch. Parse untrusted/JSON data into a
#               pydantic model at the boundary instead, or fix the real type. The
#               rare genuinely-unavoidable case (e.g. casting a test double to
#               its interface) opts out per-file with `# noqa: TID251` + a reason.
#
# The ban is configured inline (`--config`) rather than via a checked-in
# ruff.toml because per-package builds run ruff inside sandboxes that do not
# contain the repo root, so an on-disk config would never be discovered.
{ lib }:
let
  banMessage =
    "typing.cast defeats the type checker (no runtime check), so a wrong cast "
    + "is a latent bug. Parse untrusted/JSON data into a pydantic model at the "
    + "boundary, or fix the real type. Only for an unavoidable case (e.g. a test "
    + "double): add a `# noqa: TID251` with a reason.";
  banConfig = ''lint.flake8-tidy-imports.banned-api."typing.cast".msg = "${banMessage}"'';
in
{
  inherit banMessage banConfig;
  # Drop-in replacement for the old bare `--select ANN`:
  #   ruff check ${ruffAnnArgs} <targets>
  ruffAnnArgs = "--select ANN,TID251 --config ${lib.escapeShellArg banConfig}";
}
