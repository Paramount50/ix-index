{
  forwardingSecret,
  motd,
  extraModules ? [ ],
}:
import ../modules/folia.nix {
  inherit
    extraModules
    forwardingSecret
    motd
    ;
}
