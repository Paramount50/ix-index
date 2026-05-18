{ index }:

index.lib.mkFleet {
  defaults = [ { ix.image.tag = "survival-server"; } ];

  nodes.survival = {
    deployment.ipv4 = true;
    modules = [ ./minecraft.nix ];
  };
}
