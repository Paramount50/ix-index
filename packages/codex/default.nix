{
  lib,
  codex,
  makeBinaryWrapper,
  symlinkJoin,
  binName ? "codex",
  # Config-key defaults, applied as highest-precedence runtime `-c key=value`
  # overrides (codex's `--config` layer wins over every file layer, so a baked
  # value here cannot be silently dropped by a churned ~/.codex/config.toml).
  # Declared as data so the flags below derive from one source; a consumer adds
  # or replaces keys with `codex.override { settings = { ... }; }`.
  #
  # We run a trusted config (our own AGENTS.md / hooks / MCP servers), so the
  # fleet-wide defaults we bake are (1) turning off the startup update check
  # (the store binary is read-only and the wrapper owns the version pin, so the
  # check only ever costs a network round-trip it can never act on) and (2)
  # raising the multi-agent fan-out so deep, highly-parallel task decomposition
  # stops hitting the stock limits (see below). Anything security-shaped
  # (sandbox mode, approval policy) is left to the user's config and codex's own
  # requirements layer, since a bare host is genuinely not a sandbox.
  settings ? {
    check_for_update_on_startup = false;

    # Multi-agent fan-out. Run the v2 runtime (stock default is 4 = root + 3
    # subagents) with a much higher cap so parallel research/implementation
    # tracks stop hitting AgentLimitReached. v2 counts the root thread plus
    # every open subagent, so 16 => root + 15 concurrent subagents.
    #
    # NOTE: v2 *rejects* `agents.max_threads` ("agents.max_threads cannot be set
    # when multi_agent_v2 is enabled"), so the concurrency cap lives here, not
    # under [agents]. Only `agents.max_depth` is still read under v2.
    features.multi_agent_v2 = {
      enabled = true;
      max_concurrent_threads_per_session = 16;
    };

    # Sub-agent nesting depth (root = 0); 3 allows parent -> child -> grandchild
    # -> great-grandchild before exceeds_thread_spawn_depth_limit kicks in.
    agents.max_depth = 3;
  },
}:
let
  # Encode a single scalar default as the TOML codex's `-c` layer expects:
  # booleans bare, strings quoted, numbers as-is. Nesting is handled by `flatten`
  # below, not here, so a value is always a leaf by the time it reaches this.
  toToml =
    value:
    if builtins.isBool value then
      (lib.boolToString value)
    else if builtins.isString value then
      builtins.toJSON value
    else if builtins.isInt value || builtins.isFloat value then
      toString value
    else
      throw "codex: unsupported config value type for ${builtins.toJSON value}";
  # Flatten the (possibly nested) `settings` attrset into the repeated
  # `--config dotted.key=value` flags codex accepts, recursing to leaf scalars.
  # This lets callers write idiomatic nested Nix (`features.multi_agent_v2.enabled
  # = true`) while each override stays ATOMIC: codex merges a dotted leaf into the
  # existing config tree, so we touch only that leaf and leave sibling keys (e.g.
  # `features.multi_agent` from the file layer) intact. Emitting a value as one
  # inline `{...}` table instead would replace the whole table and silently drop
  # those siblings. Leaf flags carry no spaces, so each survives makeBinaryWrapper
  # splitting `--add-flags` on whitespace.
  flatten =
    prefix: attrs:
    lib.concatLists (
      lib.mapAttrsToList (
        name: value:
        let
          key = if prefix == "" then name else "${prefix}.${name}";
        in
        if builtins.isAttrs value then flatten key value else [ "--config ${key}=${toToml value}" ]
      ) attrs
    );
  configFlags = flatten "" settings;
in
symlinkJoin {
  name = "codex-${codex.version}";
  paths = [ codex ];
  nativeBuildInputs = [ makeBinaryWrapper ];
  # symlinkJoin links the whole codex output (libexec, completions, ...); we only
  # re-wrap the entrypoint so our baked `-c` defaults ride every invocation while
  # everything else stays pristine. `--add-flags` (prepended) keeps a user's
  # explicit `-c` on the CLI winning, since codex is last-wins within the runtime
  # layer.
  postBuild = ''
    rm -f $out/bin/${binName}
    makeBinaryWrapper ${lib.getExe codex} $out/bin/${binName} \
      --inherit-argv0 \
      --add-flags ${lib.escapeShellArg (lib.concatStringsSep " " configFlags)}
  '';
  meta = codex.meta // {
    description = "${codex.meta.description or "OpenAI Codex CLI"} (index wrapper with baked defaults)";
    mainProgram = binName;
  };
}
