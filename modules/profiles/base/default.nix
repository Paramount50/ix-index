# Base runtime profile.
#
# Auto-enabled by `lib/ix-oci-layer.nix`. Ships cross-cutting CLI that should
# be available on every VM for debugging and introspection. Image-specific
# runtime dependencies still belong in the image or service that needs them.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ix.profiles.base;
in
{
  options.ix.profiles.base = {
    enable = lib.mkEnableOption "base runtime tools";

    shellWorkspace = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Pre-create a writable workspace directory and auto-cd login
          shells (Nushell `login.nu`) into it. Disable for sealed
          appliances where there is no interactive workflow to land in.
        '';
      };

      directory = lib.mkOption {
        type = lib.types.str;
        default = "/work/ix";
        description = "Workspace directory entered by login shells.";
      };
    };
  };

  config = lib.mkIf config.ix.profiles.base.enable {
    # Cubic halves cwnd on any loss, so a residential last-mile at
    # 30 ms and a couple percent loss caps a single TCP flow far
    # below the path's real capacity. BBR models bottleneck bandwidth
    # and RTT from delivery-rate measurements and is largely loss-
    # insensitive, which matches every workload here that accepts
    # inbound from arbitrary internet endpoints (Minecraft players,
    # Xpra browser clients, repo fetches via `git-clone`). fq is the
    # qdisc BBR was designed to pace with; BBR without fq leaves
    # bandwidth on the table.
    #
    # If `tcp_bbr` is not present in the running kernel, the sysctl
    # write is a no-op and Cubic stays in place. Per-socket buffer
    # caps (`rmem_max`, `wmem_max`, `tcp_{r,w}mem`) are deliberately
    # left at kernel defaults: a 64 MiB per-socket ceiling is real
    # memory cost on small VMs with many accepted sockets, and the
    # default 4 MiB cap fits the BDP of every workload shipped here.
    boot.kernel.sysctl = {
      "net.ipv4.tcp_congestion_control" = "bbr";
      "net.core.default_qdisc" = "fq";
    };

    # Per-tool config for root lives in Home Manager (used here as a
    # NixOS module per AGENTS.md). Nushell's config.nu ships as a real
    # `.nu` file next to this module; HM writes it to the right XDG path
    # under /root/.config/nushell/ and follow-up tool integrations
    # (atuin, zoxide, starship) hang off the same root user attrset.
    home-manager.users.root = {
      home.stateVersion = "25.05";
      programs = {
        nushell = {
          enable = true;
          configFile.source = ./config.nu;
          loginFile.source = ./login.nu;
          # env.nu is tiny machine-owned glue: one line that surfaces
          # the workspace path from the shellWorkspace option into the
          # Nushell session so login.nu can read it. Generating it
          # inline keeps the workspace path in one Nix source of truth.
          envFile.text = ''
            $env.IX_WORKDIR = "${cfg.shellWorkspace.directory}"
          '';
        };
        # Shared prompt across every shell on the system, so the same
        # rendering follows the operator whether they stay in Nushell or
        # chsh into bash/zsh/fish.
        starship = {
          enable = true;
          enableNushellIntegration = true;
          enableBashIntegration = true;
          enableZshIntegration = true;
          enableFishIntegration = true;
        };
        # SQLite-backed, searchable shell history that follows the
        # operator across bash/zsh/fish/nushell. Local-only by default;
        # sync to an atuin server only when the operator chooses to.
        atuin = {
          enable = true;
          enableNushellIntegration = true;
          enableBashIntegration = true;
          enableZshIntegration = true;
          enableFishIntegration = true;
        };
        # Frecency-ranked directory jumper: `z minecraft` jumps to the
        # most-used directory matching that fragment. SSH dev sessions
        # bounce between /etc, /var/log, /work/ix, and service data dirs
        # constantly; full paths get old fast.
        zoxide = {
          enable = true;
          enableNushellIntegration = true;
          enableBashIntegration = true;
          enableZshIntegration = true;
          enableFishIntegration = true;
        };
        # Per-directory environment loading. nix-direnv caches nix-shell
        # evaluation so cd'ing into a repo with a shell.nix or flake.nix
        # gets its environment without re-evaluating Nix every time.
        direnv = {
          enable = true;
          nix-direnv.enable = true;
          enableNushellIntegration = true;
          enableBashIntegration = true;
          enableZshIntegration = true;
          enableFishIntegration = true;
        };
        # Fuzzy finder. Closes the loop with atuin (Ctrl+R history) and
        # zoxide (z foo) so the same interaction model picks files,
        # processes, branches, anything the operator pipes into fzf.
        fzf = {
          enable = true;
          enableBashIntegration = true;
          enableZshIntegration = true;
          enableFishIntegration = true;
        };
        # Git baseline. main as the initial branch matches every modern
        # forge default; pull.rebase keeps history linear on an operator
        # box where merge commits add noise; autoSetupRemote means a
        # plain `git push` on a new branch sets upstream without the
        # explicit -u dance every time.
        git = {
          enable = true;
          extraConfig = {
            init.defaultBranch = "main";
            pull.rebase = true;
            push.autoSetupRemote = true;
          };
        };
      };
    };

    programs = {
      # Ship every common operator shell so an SSH session can chsh into
      # whatever the operator already knows. bash is implicit in NixOS;
      # zsh and fish get their NixOS modules so /etc/shells registration
      # and system-wide completion paths are wired without per-image
      # setup. Nushell is the platform default user shell (see
      # lib/ix-platform.nix) and lands as the login shell directly,
      # since Home Manager owns its config files via the root attrset.
      zsh.enable = true;
      fish.enable = true;

      # Neovim is the default $EDITOR system-wide (defaultEditor exports
      # EDITOR for both interactive and service contexts). vi/vim aliases
      # mean muscle memory from any other Unix box lands on nvim. Helix
      # and micro ride along as alternatives the operator can choose.
      neovim = {
        enable = true;
        defaultEditor = true;
        viAlias = true;
        vimAlias = true;
      };
    };

    environment.systemPackages = builtins.attrValues {
      inherit (pkgs)
        bat
        bpftrace
        btop
        eza
        fd
        file
        gdb
        # gnutar, gzip, and zstd ride along so any VM switched once stays
        # switchable: `ix switch --source` streams a tarball through
        # `tar -x -I zstd` inside the guest, and these binaries are not
        # on NixOS' default system PATH.
        gnutar
        gzip
        # Alternative editors next to the default neovim. Helix is the
        # modern single-binary editor; micro is the nano-style fallback
        # for operators who want predictable bindings without modes.
        helix
        htop
        micro
        jq
        lldb
        lsof
        ncdu
        # nh wraps nixos-rebuild/home-manager/darwin-rebuild with a
        # build tree (via nom), pre-activation diffs (via dix), and
        # confirmation prompts. nix-output-monitor is shipped
        # separately so plain `nom nix build .#foo` works outside nh.
        # nix-tree is the interactive TUI for exploring a derivation's
        # dependency graph.
        nh
        nix-output-monitor
        nix-tree
        pv
        ripgrep
        strace
        tcpdump
        zstd
        ;
    };

    # Pre-create the workspace at boot so login.nu can cd into it
    # without racing tmpfiles or relying on mkdir from the shell.
    systemd.tmpfiles.rules = lib.mkIf cfg.shellWorkspace.enable [
      "d ${cfg.shellWorkspace.directory} 0755 root root -"
    ];
  };
}
