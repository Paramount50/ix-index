{
  errors,
  rust-overlay,
}:
let
  validChannels = [
    "stable"
    "beta"
    "nightly"
  ];

  validProfiles = [
    "minimal"
    "default"
    "complete"
  ];

  /**
    Default nightly date used when the caller does not pin one. Bumping
    this advances every consumer that did not opt out, including the
    repo's own clippy and policy-check pipelines.
  */
  defaultNightlyDate = "2026-05-17";

  /**
    Channel-specific defaults for `version`. Stable/beta default to the
    rust-overlay `latest` alias so routine bumps follow the overlay
    flake update. Nightly pins a date so a wider rust-overlay update
    cannot silently shift the toolchain underneath a build.
  */
  defaultVersionFor = channel: if channel == "nightly" then defaultNightlyDate else "latest";

  /**
    Toolchain components everyone gets by default. The shape mirrors
    the `minimal` profile so the override surface is the same whether
    a caller selects `profile = "minimal"` or accepts the default
    component list.
  */
  defaultComponents = [
    "cargo"
    "rust-std"
    "rustc"
  ];

  /**
    Add rust-overlay to `pkgs` once. A second `extend` is wasted work
    and triggers a second nixpkgs evaluation, so check for `rust-bin`
    before re-applying.
  */
  pkgsWithOverlayFor =
    pkgs: if builtins.hasAttr "rust-bin" pkgs then pkgs else pkgs.extend rust-overlay.overlays.default;

  /**
    Build the rustup-style channel string `fromRustupToolchain` expects.

    rustup encodes selection as `"stable"`/`"beta"`/`"nightly"` for the
    latest of each channel, a bare semver like `"1.83.0"` for a pinned
    stable, and `"<channel>-YYYY-MM-DD"` for a pinned beta or nightly
    date. The user-facing API hides that with a `version = "latest"`
    default and a single `version` field for everything else.
  */
  rustupChannelFor =
    {
      channel,
      version,
    }:
    if version == "latest" then
      channel
    else if channel == "stable" then
      version
    else
      "${channel}-${version}";
in
/**
  Build a rust-overlay toolchain.

  Returns an aggregated toolchain package suitable for use as a system
  package or as the `rustc` + `cargo` source for downstream rust
  builders. Unknown channels, versions, and components throw with the
  valid alternatives listed so a typo is fixable from the message
  alone.

  Arguments (all optional):
  - `channel`: one of `"stable" | "beta" | "nightly"`. Default
    `"nightly"`.
  - `version`: `"latest"`, a semver like `"1.83.0"`, or an ISO date
    like `"2025-12-01"` (date is only valid on nightly). Defaults to
    the repo-wide pinned nightly date when channel is `"nightly"`,
    otherwise `"latest"`.
  - `components`: rustup components to include. Defaults to the
    minimal `[ "cargo" "rust-std" "rustc" ]` set; pass an extended
    list (for example `[ ... "rust-src" "rust-analyzer" ]`) when the
    consumer needs more.
  - `targets`: extra rustc targets beyond the host. Default `[ ]`.
  - `profile`: rust-overlay profile baseline. One of
    `"minimal" | "default" | "complete"`. Default `"minimal"`.

  Example:
  ```nix
  { pkgs, ix, ... }:
  let
    rust = ix.languages.rust pkgs {
      channel = "nightly";
      version = "2025-12-01";
      components = [ "cargo" "rust-std" "rustc" "rust-src" "rustfmt" ];
    };
  in {
    environment.systemPackages = [ rust ];
  }
  ```
*/
pkgs:
{
  channel ? "nightly",
  version ? defaultVersionFor channel,
  components ? defaultComponents,
  targets ? [ ],
  profile ? "minimal",
}:
let
  checkedChannel = errors.assertEnum {
    name = "ix.languages.rust.channel";
    value = channel;
    valid = validChannels;
  };

  checkedProfile = errors.assertEnum {
    name = "ix.languages.rust.profile";
    value = profile;
    valid = validProfiles;
  };

  pkgsWithOverlay = pkgsWithOverlayFor pkgs;
in
pkgsWithOverlay.rust-bin.fromRustupToolchain {
  channel = rustupChannelFor {
    channel = checkedChannel;
    inherit version;
  };
  inherit components targets;
  profile = checkedProfile;
}
