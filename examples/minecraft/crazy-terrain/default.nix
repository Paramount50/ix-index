{ index }:

index.lib.mkFleet {
  defaults = [ { ix.image.tag = "crazy-terrain"; } ];

  nodes.crazy-terrain = {
    deployment = {
      ipv4 = true;
      healthChecks = [ "minecraft" ];
    };
    modules = [ ./minecraft.nix ];
  };
}
