{
  forwardingSecret,
  motd,
  extraModules ? [ ],
  extraServerProperties ? { },
}:
import ../modules/folia.nix {
  inherit
    extraModules
    extraServerProperties
    forwardingSecret
    motd
    ;
}
