{
  builderName,
  nixBuilder,
}:
{
  nodes,
  ...
}:
let
  builderHost = nodes.${builderName}.config.ix.networking.eastWest.hostName;
in
{
  nix = {
    distributedBuilds = true;
    buildMachines = [
      {
        hostName = builderHost;
        protocol = "ssh-ng";
        system = "x86_64-linux";
        sshUser = "root";
        sshKey = nixBuilder.clientKeyFile;
        maxJobs = 16;
        speedFactor = 8;
        supportedFeatures = [
          "big-parallel"
          "kvm"
          "nixos-test"
        ];
        publicHostKey = nixBuilder.hostPublicKey;
      }
    ];

    settings = {
      extra-substituters = [ "http://${builderHost}:5000" ];
      extra-trusted-public-keys = [ nixBuilder.publicCacheKey ];
      trusted-users = [ "root" ];
    };
  };
}
