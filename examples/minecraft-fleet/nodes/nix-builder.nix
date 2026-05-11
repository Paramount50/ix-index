{ nixBuilder }:
{
  tags = [ "builder" ];

  modules = [
    (
      { pkgs, ... }:
      {
        environment.systemPackages = builtins.attrValues {
          inherit (pkgs) git nix-output-monitor;
        };

        services.nix-serve = {
          enable = true;
          bindAddress = "0.0.0.0";
          port = 5000;
          secretKeyFile = nixBuilder.cacheSecretKeyFile;
        };

        services.openssh = {
          enable = true;
          settings = {
            PasswordAuthentication = false;
            PermitRootLogin = "prohibit-password";
          };
        };

        users.users.root.openssh.authorizedKeys.keys = [ nixBuilder.clientPublicKey ];

        nix = {
          settings = {
            max-jobs = 16;
            cores = 0;
            trusted-users = [ "root" ];
          };
        };

        ix.networking.eastWest.firewall.allowedTCPPorts = [
          22
          5000
        ];
      }
    )
  ];
}
