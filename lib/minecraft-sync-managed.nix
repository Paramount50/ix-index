{
  pkgs,
  writeNushellApplication,
  package,
  dataDir,
  dropinDir,
  managedRoot,
  plugmanReloadEnabled,
  rconEnabled,
  ignoredPlugins,
  rconPort,
  rconPasswordFile,
  rconBroadcastToOps,
}:
let
  inherit (pkgs) lib;

  rootArgs = [
    "--data-dir"
    dataDir
    "--dropin-dir"
    dropinDir
    "--managed-root"
    managedRoot
  ];

  reloadArgs = lib.optionals plugmanReloadEnabled [ "--plugman-reload" ];

  ignoredPluginArgs = lib.concatMap (plugin: [
    "--plugman-ignored-plugin"
    plugin
  ]) ignoredPlugins;

  rconArgs = [
    "--rcon-port"
    (toString rconPort)
    "--rcon-password-file"
    rconPasswordFile
    "--rcon-broadcast-to-ops"
    (if rconBroadcastToOps then "true" else "false")
  ]
  ++ lib.optionals rconEnabled [ "--rcon-enable" ];

  args = rootArgs ++ reloadArgs ++ ignoredPluginArgs ++ rconArgs;
in
writeNushellApplication pkgs {
  name = "minecraft-sync-managed";
  text = ''
    def main [] {
      exec ${lib.getExe package} ${lib.escapeShellArgs args}
    }
  '';
}
