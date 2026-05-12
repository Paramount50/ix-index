# Minestom hello-world image.
{
  ix,
  ...
}:
{
  ix.image.name = "minestom-hello";

  services.minestom = {
    enable = true;
    serverJar = ix.packages.minestom.helloServerJar;
  };
}
