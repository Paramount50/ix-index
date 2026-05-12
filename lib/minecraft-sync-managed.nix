{
  pkgs,
  writePythonApplication,
  src,
  dataDir,
  dropDir,
  managedRoot,
  plugmanReloadEnabled,
  ignoredPlugins,
  rconPort,
  rconPasswordFile,
}:

writePythonApplication pkgs {
  name = "minecraft-sync-managed";
  inherit src;
  args = [
    "--data-dir"
    dataDir
    "--drop-dir"
    dropDir
    "--managed-root"
    managedRoot
  ]
  ++ pkgs.lib.optionals plugmanReloadEnabled [ "--plugman-reload" ]
  ++ pkgs.lib.concatMap (plugin: [
    "--plugman-ignored-plugin"
    plugin
  ]) ignoredPlugins
  ++ [
    "--rcon-port"
    (toString rconPort)
    "--rcon-password-file"
    rconPasswordFile
  ];
}
