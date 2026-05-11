{
  ix,
  hostSystem ? ix.lib.system,
}:
let
  # TODO: settle the secret-ref implementation. The intended shape is opaque
  # refs: modules depend on a ref, ix infers sharing, materializes the file at
  # activation time, and owns rotation. Users should not hand-wire /run paths.
  secrets = {
    velocityForwarding.generate = true;
    nixBuilderCacheSecretKey.generate = true;
    nixBuilderClientKey.generate = true;
  };
  forwardingSecret = secrets.velocityForwarding;
  nixBuilder = {
    cacheSecretKeyFile = "/run/ix/secrets/nix-builder-cache-secret-key";
    clientKeyFile = "/run/ix/secrets/nix-builder-client-key";
    clientPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMinecraftFleetBuilderClient example";
    hostPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMinecraftFleetBuilderHost example";
    publicCacheKey = "minecraft-fleet-builder.example:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  };
  nixBuilderClientModule = import ./modules/nix-builder-client.nix {
    inherit nixBuilder;
    builderName = "nix-builder";
  };
  survivalReplicas = 3;
  replicaNames = name: count: builtins.genList (index: "${name}-${toString index}") count;
  survivalNodes = replicaNames "survival" survivalReplicas;
  survival = import ./nodes/survival.nix {
    inherit forwardingSecret;
    extraModules = [ nixBuilderClientModule ];
    motd = "ix survival";
    extraServerProperties = {
      view-distance = 10;
      simulation-distance = 8;
    };
  };
in
ix.lib.mkFleetFor hostSystem {
  inherit secrets;

  deployment.switch = {
    buildOn = "local";
    overrideInputs.ix-images = ".";
  };

  nodes = {
    proxy = import ./nodes/proxy.nix {
      inherit
        forwardingSecret
        nixBuilderClientModule
        survivalNodes
        ;
    };

    lobby =
      import ./nodes/lobby.nix {
        inherit forwardingSecret;
        extraModules = [ nixBuilderClientModule ];
        motd = "ix lobby";
      }
      // {
        dependsOn = [ "nix-builder" ];
      };

    survival = survival // {
      dependsOn = [ "nix-builder" ];
      replicas = survivalReplicas;
    };

    nix-builder = import ./nodes/nix-builder.nix {
      inherit nixBuilder;
    };
  };
}
