# Remote desktop image: Xpra HTML5 desktop, plus firefox for first boot.
{ pkgs, ... }:
{
  ix.image.name = "ix-remote-desktop";

  environment.systemPackages = [
    pkgs.xterm
    pkgs.firefox
  ];

  services.remote-desktop = {
    enable = true;
    openFirewall = true;
    allowUnauthenticated = true;
  };
}
