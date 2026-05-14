{
  ix,
  hostSystem ? ix.lib.system,
}:
let
  inherit (ix.lib) pkgs;
  inherit (pkgs) lib;

  fleet = (ix.lib.mkFleetFor hostSystem) {
    # TODO: re-enable source switch settings when the demo uses switch again.
    # For now it publishes raw replacement OCI images and replaces VMs from
    # those images, so source-switch derivation inputs should stay out of the
    # example wiring.
    # deployment.switch = {
    #   buildOn = "remote";
    #   overrideInputs.index = ".";
    # };

    # Tag every node's replacement image with the demo name so registry
    # destinations read e.g. `linux:claude-code-demo` instead of the
    # less-informative `:latest`. Fleet defaults are prepended to each
    # node's module list, so this applies to both VMs at once.
    defaults = [ { ix.image.tag = "claude-code-demo"; } ];

    nodes = {
      linux = import ./linux {
        ix = ix.lib;
        inherit pkgs lib;
      };
      minecraft = import ./minecraft;
    };
  };
in
fleet
