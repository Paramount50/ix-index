{
  forwardingSecret,
  motd,
  extraServerProperties ? { },
}:
import ../modules/folia.nix {
  inherit
    extraServerProperties
    forwardingSecret
    motd
    ;
}
