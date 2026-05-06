{
  forwardingSecret,
  motd,
  extraServerProperties ? { },
}:
{
  tags = [ "minecraft" ];
  modules = [
    (
      { name, ... }:
      {
        services.minecraft = {
          folia = {
            enable = true;
            version = "1.21.10";
            build = 12;
          };

          serverFiles = {
            "server.properties" = {
              motd = "${motd} ${name}";
              online-mode = false;
              enforce-secure-profile = false;
            }
            // extraServerProperties;

            "config/paper-global.yml".proxies.velocity = {
              enabled = true;
              online-mode = true;
              secret = "@secret:${forwardingSecret.path}";
            };
          };
        };
      }
    )
  ];
}
