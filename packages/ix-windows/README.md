# ix-windows

Render each live MCP resource as its own borderless, square, ghostty-styled
native webview window.

`ix-windows` is a standalone consumer of the dashboard producer stream. The MCP
already publishes every resource onto the producer sockets as an `html` pane
keyed `resource/<id>` (see `packages/mcp`), so this process renders them with no
change to the MCP. A window opens when a resource appears, re-renders in place on
update, and closes when the resource closes or its producer disconnects.

```
nix run .#ix-windows            # watch the default discovery dir
nix run .#ix-windows -- --dir /tmp/ixw
```

## macOS

- **Square corners.** Windows are borderless (`with_decorations(false)`), exactly
  like ghostty's `window-decoration = none`. The macOS window server only rounds
  *titled* windows, so dropping decorations gives square corners for free.
- **120Hz.** WebKit's private experimental flag
  `PreferPageRenderingUpdatesNear60FPSEnabled` is disabled so the webview renders
  at the display's full refresh rate (ProMotion).

### Tiling under aerospace

A borderless window has no fullscreen button, so aerospace's dialog heuristic
floats it by default. This is the same reason terminals like `kitty` and
`alacritty` are special-cased in aerospace, and the reason `ghostty`'s bundle id
is hardcoded to tile. `ix-windows` is a bare binary with no bundle id, so tiling
relies on an `on-window-detected` rule matching the app name:

```toml
[[on-window-detected]]
if.app-name-regex-substring = 'ix-windows'
run = 'layout tiling'
```

yabai users want the equivalent `yabai -m rule --add app='^ix-windows$' manage=on`.
