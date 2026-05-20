{ index }:

index.lib.mkFleet {
  defaults = [ { ix.image.tag = "survival"; } ];

  nodes.survival = {
    deployment = {
      ipv4 = true;
      healthChecks = [ "minecraft" ];
    };
    modules = [ ./minecraft.nix ];
  };
}
