{ ix }:
let
  # TODO: settle the secret-ref implementation. The intended shape is opaque
  # refs: modules depend on a ref, ix infers sharing, materializes the file at
  # activation time, and owns rotation. Users should not hand-wire /run paths.
  secrets = {
    velocityForwarding.generate = true;
  };
  forwardingSecret = secrets.velocityForwarding;
  survivalReplicas = 3;
  replicaNames = name: count: builtins.genList (index: "${name}-${toString index}") count;
  survivalNodes = replicaNames "survival" survivalReplicas;
  survival = import ./nodes/survival.nix {
    inherit forwardingSecret;
    motd = "ix survival";
    extraServerProperties = {
      view-distance = 10;
      simulation-distance = 8;
    };
  };
in
ix.lib.mkFleet {
  inherit secrets;

  nodes = {
    proxy = import ./nodes/proxy.nix {
      inherit
        forwardingSecret
        survivalNodes
        ;
    };

    lobby = import ./nodes/lobby.nix {
      inherit forwardingSecret;
      motd = "ix lobby";
    };

    survival = survival // {
      replicas = survivalReplicas;
    };
  };
}
