{
  pkgs,
  writeNushellApplication,
  package,
  dataDir,
  dropDir,
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
in
writeNushellApplication pkgs {
  name = "minecraft-sync-managed";
  text = ''
    def main [] {
      exec ${lib.getExe package} ${
        lib.escapeShellArgs (
          [
            "--data-dir"
            dataDir
            "--drop-dir"
            dropDir
            "--managed-root"
            managedRoot
          ]
          ++ lib.optionals plugmanReloadEnabled [ "--plugman-reload" ]
          ++ lib.optionals rconEnabled [ "--rcon-enable" ]
          ++ lib.concatMap (plugin: [
            "--plugman-ignored-plugin"
            plugin
          ]) ignoredPlugins
          ++ [
            "--rcon-port"
            (toString rconPort)
            "--rcon-password-file"
            rconPasswordFile
            "--rcon-broadcast-to-ops"
            (if rconBroadcastToOps then "true" else "false")
          ]
        )
      }
    }
  '';
}
