{
  tmux,
  symlinkJoin,
  makeWrapper,
}:

# tmux with modern defaults baked in (truecolor, undercurl, mouse, vi copy mode,
# sane history/escape-time). `-f` points at our config, which sources the user's
# own ~/.config/tmux/tmux.conf last so personal settings still win. symlinkJoin
# (not a bare wrapper) keeps tmux's man pages and the rest of the output intact.
symlinkJoin {
  name = "tmux-${tmux.version}";
  paths = [ tmux ];
  nativeBuildInputs = [ makeWrapper ];
  postBuild = ''
    wrapProgram $out/bin/tmux --add-flags "-f ${./tmux.conf}"
  '';
  meta = tmux.meta // {
    description = "${tmux.meta.description}, with modern truecolor defaults baked in";
    mainProgram = "tmux";
  };
}
