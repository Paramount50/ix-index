{
  lib,
  ix,
  stdenv,
  fetchurl,
  makeBinaryWrapper,
  autoPatchelfHook,
  procps,
  ripgrep,
  minecraft-sound,
  bubblewrap,
  socat,
  nix,
  gnupg,
  formats,
  binName ? "claude",

  # Default posture: bake `--dangerously-skip-permissions` into the wrapper so
  # every session starts with the permission layer skipped. We run a trusted
  # config inside disposable sandboxes (ix guest VMs, the dev image, throwaway
  # checkouts) where a per-tool approval dialog buys nothing and only stalls an
  # agent that has nowhere unsafe to go. Mind the upstream uid-0 guard: the CLI
  # refuses this flag for an unsandboxed root user (no IS_SANDBOX=1 is baked
  # here, since a bare host genuinely is not a sandbox), so root consumers
  # either carry their own IS_SANDBOX=1 wrapper (the dev image does, plus a
  # managed-settings layer) or turn this off with
  # `claude-code.override { dangerouslySkipPermissions = false; }`.
  dangerouslySkipPermissions ? true,

  # Opt-in alternative posture: confine the agent to a fixed allow-list and
  # nothing else. Set to a list of permission rules (typically one MCP server,
  # e.g. `[ "mcp__index" "mcp__index__*" ]`) and the wrapper switches to plain
  # `default` permission mode, `allow`s exactly those rules, and bare-`deny`s
  # every other built-in tool (Bash, Read, Edit, Write, ...), stripping them from
  # the model's context. The agent can then only use the allowed tools; anything
  # else (shell, file IO, HTTP) it must do through whatever those tools expose
  # (e.g. a python/Jupyter MCP kernel). A built-in name listed here is removed
  # from the deny list, so you can also re-allow a specific built-in.
  # `bypassPermissions` cannot express this (it skips the permission layer
  # entirely, so deny rules are silently ignored) and `dontAsk` is intentionally
  # avoided. Takes PRECEDENCE over `dangerouslySkipPermissions`, since bypass
  # would void the deny rules. `null` (default) leaves the normal posture.
  restrictToTools ? null,

  # Tools dropped from the model's tool set via `--disallowedTools`, which works
  # regardless of permission mode (a `permissions.deny` would be skipped under
  # the default bypass posture). Empty by default: no tool blocking, every
  # built-in ships enabled. The groups this package used to block by default are
  # kept as data in `toolGroups` below (also on passthru), so the old lean
  # posture is one override away:
  #   claude-code.override {
  #     disallowedTools = with claude-code.toolGroups; autonomy ++ meta;
  #   }
  disallowedTools ? [ ],

  # Extra settings.json keys to ship through the read-only flagSettings layer
  # (the `--settings` file below), deep-merged UNDER the computed defaults so the
  # security-relevant keys this package controls (the restrictToTools / bypass
  # `permissions`) always win on a conflict. Lets a consumer keep its whole
  # static Claude config (hooks, statusLine, enabledPlugins, marketplaces, ...)
  # in Nix and out of a hand-maintained ~/.claude/settings.json: flagSettings
  # merges per-key ABOVE user settings and is a separate read-only layer, so it
  # never occupies (or symlinks) the writable settings.json the CLI churns at
  # runtime. `{ }` (default) ships only the computed defaults.
  extraSettings ? { },

  # Replace Claude Code's entire system prompt with this text. The string is
  # materialized to a store file and baked into the wrapper as
  # `--system-prompt-file <path>`: passing by path (not inline text) keeps
  # arbitrary content free of shell escaping and, since a store path has no
  # spaces, it survives makeBinaryWrapper's word splitting where an inline
  # `--system-prompt "<text with spaces>"` would shatter into separate argv.
  # This DROPS the default prompt wholesale (tool guidance, safety rules, coding
  # conventions), so the agent only knows what this text says. Baked with
  # `--add-flags` (prepended) so an explicit
  # `--system-prompt`/`--system-prompt-file` on the CLI still wins. Defaults to the
  # house prompt below (the shokunin craft ethos plus the pre-v1
  # backward-compatibility engineering rule, plus a preference for working in git
  # worktrees); set to `null` to bake no flag and keep Claude Code's stock prompt.
  # Authored as one paragraph per list element and joined with blank lines, so a
  # rule reads as a self-contained line of source instead of buried in a wall of
  # indented-string prose.
  systemPrompt ? lib.concatStringsSep "\n\n" [
    "Work as a shokunin. Be concise, readable, and clean by default, in code and in prose: it just works."
    "This codebase is pre-v1: no backward compatibility. Design the correct API and migrate every call site in the same change; add aliases, shims, or deprecated paths only when explicitly asked or when a real external consumer is out of reach."
    "One concept, one implementation. When you find duplicated logic or divergent variants, consolidate them into one composable path instead of adding another."

    "Fix problems at their source. If the cause is upstream, fix it there and open a PR against that project; a local workaround is a last resort and must link the upstream issue or PR."
    "ALWAYS work in a dedicated git worktree on its own branch; never edit the primary checkout. If you are about to change a file there, stop and make a worktree first."

    "When a task splits into genuinely independent pieces, spawn a background subagent per piece, each in its own worktree, committing to `main`; collect results as they finish. Foreground only when you cannot take a single useful step until it returns."

    "Spend the strongest model only on hard, high-stakes work: hand easy tasks to a subagent on a cheaper model. Planning is usually the hard part, so plan on the strongest model and let a cheaper subagent execute the settled plan."
    "Do your work through the index Python kernel (`python_exec` MCP tool), reusing its persistent namespace across turns. Search with the in-process `fff.grep`/`fff.find` (`api()` lists them); never shell out to `rg` or `fd` inside the kernel, where they run non-interactively and silently mislead (`rg` with no path argument searches empty stdin and returns nothing). Repo instructions routing Bash-tool searches through `rg`/`fd` still apply to the Bash tool. Use Bash only when the kernel is wedged: event loop frozen and neither `kernel_trace` nor a fresh `python_exec` revives it."
    "Prefer structured primitives over text munging: `view.ls`/`view.tree`/`view.cat` for the filesystem (polars frames, pre-imported), `fff.grep`/`fff.find` for search, and a CLI's JSON mode (`gh --json`, `cargo metadata`, `nix --json`) parsed with `.json()`/`.jsonl()`/`.df()` on the `sh` Output, never awk/sed/string splitting. ONE command per `sh()` call; combine results in Python. Return tabular answers as polars DataFrames."
    "Complete every task fully and autonomously. Never ask for confirmation or say you *will* do something: do it now and report what you did. You are not done until tests pass and your commits are pushed directly to `origin/main`. Pushing to `main` without waiting for CI is the normal case; open a PR and block on checks only when explicitly asked."
    "Squash merges rewrite history: rebasing a stacked branch directly onto `origin/main` replays the parent's already-merged commits and manufactures phantom conflicts. Instead fetch origin, read the parent base with `git cat-file -p refs/branch-metadata/<branch> | jq -r .parentBranchRevision`, then `git rebase --onto origin/main <parentBranchRevision> <branch>`."
    "Once a change merges into `origin/main`, delete its worktree and branch, locally and on the remote."
    "Announce every landing on `origin/main` with a one-line banner: `🚀 Pushed to main: [<summary>](<commit url>)` for a direct push, `🌸 PR merged: [<title or number>](<url>)` for a merged PR. These two emoji are deliberate signal and the one exception to the no-decorative-emoji rule. Also play `minecraft-sound play block/amethyst/resonate1`."
    "File an issue the moment you hit something worth capturing: a flaw in your own approach a later run should avoid, index friction (misleading tool surface, context-flooding output, a wedged kernel, a correction, a plainly better implementation), or anything that slowed you down. GitHub issue in the relevant repo (`indexable-inc/index` for index friction), Linear ticket for ix work. One observation per report: expected, actual, and the smallest change that would have helped."
    "Use a fenced ```mermaid diagram in issues, PRs, tickets, and design docs when a flow, state machine, architecture, or dependency graph reads better as a picture. Keep it to the one relationship that matters and pair it with a sentence of context."
    "Bug reports to other people must link a runnable minimal reproducible example, not just prose: a self-contained artifact (a `nix-shell` shebang script or small flake) in a GitHub gist. A secret gist is unlisted, not private, so scrub secrets first and use an access-controlled channel when the reproduction is sensitive."
    "Disclose AI authorship in every message another person will read (email, chat, social posts, issues, comments): append an attribution naming your model and version if your context says which model you are, otherwise a generic `(sent by an AI agent via Claude Code)`. Does not apply to replies to the user you are working with."
    "Never use em dashes, anywhere: restructure the sentence, or use a colon, comma, parentheses, or two sentences."
    "Other developers are actively working in this codebase. Treat unmerged branches as unfinished for a reason you may not see, and never work on someone else's feature or branch without coordinating."
  ],

  # Only the flake package set injects the Nushell writer; the overlay eval
  # context does not. The updater is a maintainer-facing flake output, so the
  # overlay build of `pkgs.claude-code` simply omits `passthru.updateScript`.
  writeNushellApplication ? null,
}:

let
  # Version and per-platform SRI hashes are generated, never hand-edited. Bump
  # with `nix run .#claude-code.updateScript -- <version>`, which refetches
  # Anthropic's per-version manifest and rewrites manifest.json. We pin by raw
  # version (not the npm `latest` tag) because Anthropic ships new builds to the
  # `next` prerelease tag days before promoting them to `latest`, and every
  # channel that normally surfaces an upgrade (the built-in updater, `claude
  # doctor`, sadjow/claude-code-nix) only watches `latest`.
  manifest = lib.importJSON ./manifest.json;
  inherit (manifest) version;

  # Env defaults applied through the wrapper, declared as data (single source)
  # and derived into flags below rather than hand-written into the install phase.
  # `--set-default` (not `--set`) so an explicit env or settings.json `env` value
  # still overrides per machine. Three groups:
  #  - Output-truncation caps raised to the CLI's built-in maxima: we run a
  #    trusted config (our own CLAUDE.md / AGENTS.md / hooks / MCP servers), so
  #    prefer full output over pruning. BASH_MAX_OUTPUT_LENGTH default 30000
  #    chars (binary clamp 150000); TASK_MAX_OUTPUT_LENGTH default 32000 (clamp
  #    160000); MAX_MCP_OUTPUT_TOKENS default ~25000 tokens (no clamp).
  #  - Feature toggles on by default fleet-wide: agent teams, still gated behind
  #    the EXPERIMENTAL_ env var in this build.
  #  - Context window: default every session to standard 200K Opus 4.8, not the
  #    1M window the `opus` alias is silently auto-upgraded to on
  #    Max/Team/Enterprise/API (1M reads past 200K are uncached and slower per
  #    turn). Per the inline note this is the env knob, not a `model` setting.
  wrapperEnvDefaults = {
    # Drops [1m] variants from /model without touching model selection (a `model`
    # settings key would, since flagSettings outranks user settings.json).
    # Re-enable 1M per machine: `export CLAUDE_CODE_DISABLE_1M_CONTEXT=`.
    CLAUDE_CODE_DISABLE_1M_CONTEXT = 1;
  };
  envDefaultFlags = lib.concatLists (
    lib.mapAttrsToList (name: value: [
      "--set-default"
      name
      (toString value)
    ]) wrapperEnvDefaults
  );

  # Tool groups this package used to pass to `--disallowedTools` by default,
  # kept as data (and exposed via `passthru.toolGroups`) so re-adding the old
  # posture is one `disallowedTools` override rather than archaeology. Nothing
  # here is blocked by default.
  #  - autonomy: self-watching (Monitor), self-scheduling (ScheduleWakeup, the
  #    cron family, and RemoteTrigger, which creates/runs claude.ai routines
  #    server-side), and the user-interrupting PushNotification. Monitor,
  #    PushNotification, and RemoteTrigger are server-gated with no env knob,
  #    so `--disallowedTools` is their only off-switch.
  #  - meta: the structured plan/task/team/worktree/question surface, dropped
  #    for a lean code-execution agent that works turn-by-turn through an MCP
  #    kernel instead of branching into those flows.
  toolGroups = {
    autonomy = [
      "Monitor"
      "ScheduleWakeup"
      "RemoteTrigger"
      "PushNotification"
      "CronCreate"
      "CronDelete"
      "CronList"
    ];
    meta = [
      "AskUserQuestion"
      "EnterPlanMode"
      "ExitPlanMode"
      "TaskCreate"
      "TaskList"
      "TaskGet"
      "TaskUpdate"
      "TeamCreate"
      "TeamDelete"
      "SendMessage"
      "EnterWorktree"
      "ExitWorktree"
      "WaitForMcpServers"
    ];
  };

  # Settings-key defaults that have no env knob, shipped as a JSON the wrapper
  # injects via `--settings`. The package wraps the binary, so it can carry env
  # vars and CLI flags but not a settings.json *key* directly. `--settings` adds
  # a `flagSettings` layer that merges per-key with the other settings sources
  # (precedence: managed > flagSettings > local > project > user; arrays concat),
  # so it overrides a user's settings.json value but leaves every other key
  # intact, and managed settings can still override it.
  #
  # IMPORTANT: between two `--settings` *flags* the CLI is first-wins (they do
  # NOT merge with each other), so this is injected with `--append-flags` (last
  # in argv): a user who passes their own `--settings` on the CLI wins (theirs
  # comes first), and ours applies only when they pass none. `--add-flags` would
  # prepend ours and silently shadow a user's `--settings`.
  #   cleanupPeriodDays: keep transcripts + the wrapper's --debug logs ~1yr for
  #     the optimize analysis and troubleshooting (CLI default 30).
  #   permissions.{allow,deny} (only when `restrictToTools` is set, opt-in):
  #     confine the agent to that allow-list and strip every other built-in tool
  #     from context. Arrays concat across layers and a deny at any scope wins, so
  #     a downstream user/project/local settings file cannot un-deny these; the
  #     only un-lock is dropping the nix `restrictToTools` override. Caveat: a
  #     managed `bypassPermissions` skips the whole permission layer, so these
  #     deny rules would be inert under one.
  #   skipDangerousModePermissionPrompt (the default, unless `restrictToTools`
  #     takes precedence): pre-accept the one-time dangerous-mode warning, which
  #     the baked `--dangerously-skip-permissions` flag alone does not suppress.
  #     Honored in every scope except *project* (a guard against untrusted
  #     repos), so it takes effect from this flagSettings layer. The dev image
  #     (images/dev/development-base) enforces the same posture via managed
  #     settings; see its comment for the full rationale.
  #
  # Bare tool names as deny rules remove the built-in tool from the model's
  # context entirely (per the permissions docs), not merely gate it behind a
  # prompt, so the agent never sees a shell/file/web/subagent tool. Read-only Bash
  # (`cat`, `ls`, ...) is otherwise always allowed in every mode, so denying bare
  # `Bash` is what actually closes the shell.
  deniedBuiltinTools = [
    "Agent"
    "Bash"
    "BashOutput"
    "Edit"
    "Glob"
    "Grep"
    "KillShell"
    "ListMcpResources"
    "NotebookEdit"
    "PowerShell"
    "Read"
    "ReadMcpResource"
    "Skill"
    "SlashCommand"
    "Task"
    "TodoWrite"
    "WebFetch"
    "WebSearch"
    "Write"
  ];

  # The lockdown is active whenever the caller pins an allow-list.
  restrictTools = restrictToTools != null;

  # Caller's extraSettings first, then the computed defaults recursively merged
  # ON TOP, so the security-relevant `permissions`/bypass keys below always win a
  # conflict while the caller's other keys (hooks, statusLine, ...) pass through.
  settingsDefaults = ix.deepMerge.rhs extraSettings (
    {
      cleanupPeriodDays = 365;
    }
    // lib.optionalAttrs restrictTools {
      permissions = {
        allow = restrictToTools;
        # A built-in named in the allow-list is re-allowed by dropping it here.
        deny = lib.subtractLists restrictToTools deniedBuiltinTools;
      };
    }
    # restrictToTools takes precedence: bypass would skip the permission layer
    # and void its deny rules, so the wrapper bakes the bypass flag (see
    # `postureWrapperArgs`) and this warning pre-accept only when no allow-list
    # is pinned.
    // lib.optionalAttrs (dangerouslySkipPermissions && !restrictTools) {
      skipDangerousModePermissionPrompt = true;
    }
  );
  settingsDefaultsFile =
    (formats.json { }).generate "claude-code-default-settings.json"
      settingsDefaults;

  # Posture flags derived from the args above (see their comments): the
  # opt-in `--disallowedTools` list and the default
  # `--dangerously-skip-permissions`. Baked with `--add-flags` and rendered
  # through escapeShellArgs, same as the system-prompt pair below; empty lists
  # contribute nothing.
  postureWrapperArgs =
    lib.optionals (disallowedTools != [ ]) [
      "--add-flags"
      "--disallowedTools ${lib.concatStringsSep "," disallowedTools}"
    ]
    ++ lib.optionals (dangerouslySkipPermissions && !restrictTools) [
      "--add-flags"
      "--dangerously-skip-permissions"
    ];

  # System-prompt override (see the `systemPrompt` arg). Materialize the text to
  # a store file and add `--system-prompt-file <path>` as makeBinaryWrapper args.
  # escapeShellArgs emits the `--system-prompt-file <path>` pair as one shell
  # word so makeBinaryWrapper re-splits it into the two argv tokens the CLI wants;
  # when unset the list is empty and contributes nothing.
  systemPromptWrapperArgs = lib.optionals (systemPrompt != null) [
    "--add-flags"
    "--system-prompt-file ${builtins.toFile "claude-code-system-prompt.txt" systemPrompt}"
  ];

  inherit (stdenv.hostPlatform) system;
  target =
    manifest.platforms.${system}
      or (throw "claude-code: no prebuilt binary for ${system}; supported: ${lib.concatStringsSep ", " (builtins.attrNames manifest.platforms)}");

  # Primary host is the Anthropic-branded CDN so the source is verifiable; the
  # GCS bucket is the direct origin and stays as a mirror if the CDN is down.
  # The hash pin guarantees both resolve to identical bytes, so this is a
  # mirror list, not a behavioral fallback.
  nativeBinary = fetchurl {
    urls = [
      "https://downloads.claude.ai/claude-code-releases/${version}/${target.slug}/claude"
      "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/${version}/${target.slug}/claude"
    ];
    inherit (target) hash;
  };

  # Refreshes manifest.json from Anthropic's published per-version manifest,
  # converting its hex checksums to the SRI hashes the fetcher pins. The slug
  # map lives here as the single owner; default.nix only reads it back. The
  # updater fails closed unless the manifest's detached GPG signature verifies
  # against the pinned release signing key (release-signing-key.asc, fingerprint
  # 31DD DE24 DDFA B679 F42D 7BD2 BAA9 29FF 1A7E CACE, published at
  # downloads.claude.ai/keys/claude-code.asc), so a spoofed manifest cannot
  # inject hashes for attacker-controlled binaries.
  updateScript =
    if writeNushellApplication == null then
      null
    else
      writeNushellApplication {
        name = "claude-code-update";
        runtimeInputs = [
          nix
          gnupg
        ];
        meta.description = "Refresh packages/claude-code/manifest.json to a signed Claude Code release";
        text = ''
          const base = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"
          const signing_key = "${./release-signing-key.asc}"
          const slugs = {
            "aarch64-darwin": "darwin-arm64",
            "x86_64-darwin": "darwin-x64",
            "x86_64-linux": "linux-x64",
            "aarch64-linux": "linux-arm64"
          }

          # Run from the repo root: `nix run .#claude-code.updateScript -- [version]`.
          # Without a version argument it tracks Anthropic's `latest` pointer.
          def main [version?: string] {
            let v = ($version | default (http get $"($base)/latest" | str trim))

            # Download the exact bytes we verify, then parse the same file.
            let work = (mktemp --directory)
            let manifest_path = $"($work)/manifest.json"
            let sig_path = $"($work)/manifest.json.sig"
            http get --raw $"($base)/($v)/manifest.json" | save --force $manifest_path
            http get --raw $"($base)/($v)/manifest.json.sig" | save --force $sig_path

            # Fail closed: only the pinned key lives in this GNUPGHOME, so a
            # zero exit from --verify proves Anthropic signed these exact bytes.
            let gnupghome = (mktemp --directory)
            with-env { GNUPGHOME: $gnupghome } {
              ^gpg --batch --quiet --import $signing_key
              let check = (do { ^gpg --batch --verify $sig_path $manifest_path } | complete)
              if $check.exit_code != 0 {
                error make { msg: $"claude-code: manifest signature verification failed for ($v)\n($check.stderr)" }
              }
            }

            let upstream = (open $manifest_path)
            let platforms = (
              $slugs
              | transpose system slug
              | reduce --fold {} {|row acc|
                  let hex = ($upstream.platforms | get $row.slug | get checksum)
                  let sri = (^nix hash convert --hash-algo sha256 --to sri $hex | str trim)
                  $acc | insert $row.system { slug: $row.slug, hash: $sri }
                }
            )
            let out = "packages/claude-code/manifest.json"
            { version: $v, platforms: $platforms } | to json --indent 2 | save --force $out
            print $"updated ($out) to ($v); signature verified"
          }
        '';
      };
in
stdenv.mkDerivation {
  pname = "claude-code";
  inherit version;

  dontUnpack = true;
  # Stripping rewrites the binary and corrupts the trailer Bun appends to its
  # single-file executables, so the stripped CLI aborts on launch.
  dontStrip = true;
  strictDeps = true;

  nativeBuildInputs = [
    makeBinaryWrapper
  ]
  ++ lib.optional stdenv.hostPlatform.isElf autoPatchelfHook;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/libexec

    # 1Password's "CLI access requested" prompt labels the request with the
    # basename of the process that spawns `op`, which is this real binary rather
    # than the wrapper. Keep it in libexec (off PATH, no leading-dot wrapper
    # convention) and name it for the product so the prompt reads "Claude Code"
    # instead of ".claude-unwrapped". The basename is the human-facing product
    # label, independent of the command alias, since it is only what macOS shows.
    # 1Password docs confirm the prompt shows "the process being authorized (for
    # example, iTerm2 or Terminal)", not the code signature or CFBundleName:
    # https://developer.1password.com/docs/cli/app-integration-security/
    helper="$out/libexec/Claude Code"
    install -m755 ${nativeBinary} "$helper"

    # The store output is read-only, so the bundled self-updater can never
    # write; disable it and the install checks, and pin the bundled ripgrep to
    # the Nix one so PATH stays reproducible. The wrapper owns the version pin.
    # Apply our env defaults (see `wrapperEnvDefaults` above).
    #
    # Start in debug mode by default (`--debug`): the CLI writes operational
    # telemetry (HTTP/API timings, auto-mode classifier, MCP/LSP lifecycle,
    # startup phases, permission decisions) to ~/.claude/debug/ for
    # troubleshooting and the optimize history analysis. It does not pollute
    # `claude -p` stdout (verified). Those logs prune on the cleanupPeriodDays
    # sweep, so we also ship a long retention via --settings (see
    # `settingsDefaults` above).
    #
    # Opt back into summarized thinking (`--thinking-display summarized`). The
    # API behavior here DIFFERS BY MODEL: `thinking.display` defaulted to
    # "summarized" on Opus 4.6 / Sonnet 4.6 and earlier, but Anthropic silently
    # flipped it to "omitted" on Opus 4.7 and Opus 4.8 (faster time-to-first-
    # token). With "omitted" the API returns thinking blocks whose `thinking`
    # field is empty (only the encrypted `signature` rides along), so on the
    # latest Opus the live UI shows nothing and the transcript persists no
    # reasoning. The harness never requests "summarized" itself, and
    # `showThinkingSummaries` does NOT fix it (it only drives the ctrl+o
    # renderer + a beta header, wired to nothing that sets the request's
    # display) -- see anthropics/claude-code#49268 (root cause) and #63358
    # (Opus 4.8). The hidden `--thinking-display summarized` flag is the only
    # lever that works, and it is verified to restore readable Opus-4.8 thinking
    # on 2.1.159. We want the reasoning for steering and for the optimize
    # analysis, so we trade the TTFT win for visible thinking fleet-wide. Safe
    # for Haiku (it already defaults to "summarized"); unlike CLAUDE_CODE_EXTRA_
    # BODY this does not force `type:adaptive`, which Haiku rejects. Via
    # `--add-flags` (prepended) so an explicit `--thinking-display omitted` on
    # the CLI still wins for anyone who wants the latency back.
    makeBinaryWrapper "$helper" $out/bin/${binName} \
      --inherit-argv0 \
      --add-flags --debug \
      --add-flags "--thinking-display summarized" \
      ${lib.escapeShellArgs postureWrapperArgs} \
      --append-flags "--settings ${settingsDefaultsFile}" \
      ${lib.escapeShellArgs systemPromptWrapperArgs} \
      --set DISABLE_AUTOUPDATER 1 \
      --set DISABLE_INSTALLATION_CHECKS 1 \
      --set USE_BUILTIN_RIPGREP 0 \
      ${lib.escapeShellArgs envDefaultFlags} \
      --prefix PATH : ${
        lib.makeBinPath (
          [
            procps
            ripgrep
            minecraft-sound
          ]
          ++ lib.optionals stdenv.hostPlatform.isLinux [
            bubblewrap
            socat
          ]
        )
      }

    runHook postInstall
  '';

  passthru = {
    inherit toolGroups;
  }
  // lib.optionalAttrs (updateScript != null) {
    inherit updateScript;
  };

  meta = {
    description = "Claude Code, Anthropic's agentic coding tool in the terminal";
    homepage = "https://www.anthropic.com/claude-code";
    # License omitted rather than `licenses.unfree`: the per-system flake
    # package set evaluates nixpkgs without `allowUnfree`, so tagging this
    # vendored binary unfree would block `nix run .#claude-code`. Distribution
    # terms are Anthropic's commercial Claude Code license.
    mainProgram = binName;
    platforms = builtins.attrNames manifest.platforms;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
