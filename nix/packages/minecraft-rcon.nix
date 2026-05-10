{
  python3,
  writeShellApplication,
}:

writeShellApplication {
  name = "minecraft-rcon";
  runtimeInputs = [ python3 ];
  text = ''exec python3 ${./minecraft-rcon.py} "$@"'';
}
