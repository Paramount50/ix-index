{ forwardingSecret, motd }:
import ../modules/folia.nix {
  inherit forwardingSecret motd;
}
