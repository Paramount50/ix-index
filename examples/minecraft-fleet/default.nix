{ ix-images }:
let
  forwardingSecretFile = /run/secrets/velocity-forwarding-secret;
  survivalNodes = [
    "survival-0"
    "survival-1"
    "survival-2"
  ];
  survival = import ./folia-node.nix {
    inherit forwardingSecretFile;
    motd = "ix survival";
    extraServerProperties = {
      view-distance = 10;
      simulation-distance = 8;
    };
  };
in
ix-images.lib.mkFleet {
  nodes = {
    proxy = import ./proxy.nix {
      inherit forwardingSecretFile survivalNodes;
    };

    lobby = import ./folia-node.nix {
      inherit forwardingSecretFile;
      motd = "ix lobby";
    };

    survival = survival // {
      replicas = 3;
    };
  };
}
