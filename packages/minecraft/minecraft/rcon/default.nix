{
  writePythonApplication,
}:

writePythonApplication {
  name = "minecraft-rcon";
  src = ./minecraft-rcon.py;
  pyChecker = "zuban";
}
