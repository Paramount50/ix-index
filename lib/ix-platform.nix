# Target platform applied to every image.
#
# All images run on EPYC Gen 5 (Turin, Zen 5). Setting hostPlatform.gcc.arch
# propagates -march=znver5 -mtune=znver5 to every package in the closure.
# No binary cache hits: everything builds from source.
{
  nixpkgs.hostPlatform = {
    system = "x86_64-linux";
    # TODO: add back znver5 tuning for EPYC Gen 5
    # gcc = {
    #   arch = "znver5";
    #   tune = "znver5";
    # };
  };

  boot.isContainer = true;
  system.stateVersion = "25.05";
}
