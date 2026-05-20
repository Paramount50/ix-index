{ index }:

index.lib.mkFleet {
  defaults = [ { ix.image.tag = "survival-server"; } ];

  nodes.survival = {
    deployment = {
      ipv4 = true;
      healthChecks = [ "minecraft" ];
    };
    modules = [ ./minecraft.nix ];
  };
}
