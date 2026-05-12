{
  ix,
  hostSystem ? ix.lib.system,
}:
let
  inherit (ix.lib) pkgs;
  inherit (pkgs) lib;
  fs = lib.fileset;
  demoSiteSrc = fs.toSource {
    root = ./site;
    fileset = fs.unions [
      ./site/index.html
      ./site/bun.lock
      ./site/eslint.config.js
      ./site/package.json
      ./site/tsconfig.json
      ./site/src/App.svelte
      ./site/src
      ./site/vite.config.js
    ];
  };
  demoSiteDeps = pkgs.stdenvNoCC.mkDerivation {
    pname = "claude-code-demo-site-deps";
    version = "0.1.0";
    src = demoSiteSrc;
    nativeBuildInputs = [
      pkgs.bun
      pkgs.nodejs
    ];
    # Fixed-output derivations cannot reference other store paths. The default
    # fixup phase rewrites shebangs inside node_modules to store-path Bash.
    dontFixup = true;

    buildPhase = ''
      runHook preBuild
      export HOME="$TMPDIR/home"
      export BUN_INSTALL_CACHE_DIR="$TMPDIR/bun-cache"
      mkdir -p "$HOME" "$BUN_INSTALL_CACHE_DIR"
      bun install --frozen-lockfile --backend copyfile
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cp -R node_modules "$out/node_modules"
      runHook postInstall
    '';

    outputHashAlgo = "sha256";
    outputHashMode = "recursive";
    outputHash = "sha256-PUayCvEbubpA3DTYBw5vjXVtD6fmvWKrDF/P5WIvdVc=";
  };
  demoSite = pkgs.stdenvNoCC.mkDerivation {
    pname = "claude-code-demo-site";
    version = "0.1.0";
    src = demoSiteSrc;
    nativeBuildInputs = [ pkgs.bun ];

    buildPhase = ''
      runHook preBuild
      export HOME="$TMPDIR/home"
      export BUN_INSTALL_CACHE_DIR="$TMPDIR/bun-cache"
      mkdir -p "$HOME" "$BUN_INSTALL_CACHE_DIR"
      cp -R ${demoSiteDeps}/node_modules ./node_modules
      chmod -R u+w node_modules
      bun install --frozen-lockfile --offline --backend copyfile
      ${lib.getExe pkgs.nodejs} node_modules/svelte-check/bin/svelte-check --tsconfig ./tsconfig.json
      ${lib.getExe pkgs.nodejs} node_modules/eslint/bin/eslint.js .
      ${lib.getExe pkgs.nodejs} node_modules/vite/bin/vite.js build
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/share/claude-code-demo-site"
      cp -R dist/. "$out/share/claude-code-demo-site/"
      runHook postInstall
    '';
  };

  writeStats = ix.lib.writeNushellApplication pkgs {
    name = "claude-code-demo-write-stats";
    runtimeInputs = [
      pkgs.coreutils
    ];
    text = ''
      def read-cpu [] {
        let values = (open --raw /proc/stat | lines | first | split row " " | where $it != "")
        let nums = ($values | skip 1 | each { into int })
        {
          total: ($nums | math sum)
          idle: (($nums | get 3) + ($nums | get 4))
        }
      }

      def round-to [places: int] {
        let factor = (10 ** $places)
        ($in * $factor | math round) / $factor
      }

      def main [] {
        let out_dir = /run/claude-code-demo
        mkdir $out_dir

        let cpu_a = (read-cpu)
        sleep 200ms
        let cpu_b = (read-cpu)
        let total_delta = ($cpu_b.total - $cpu_a.total)
        let idle_delta = ($cpu_b.idle - $cpu_a.idle)
        let cpu_percent = if $total_delta <= 0 {
          0.0
        } else {
          (($total_delta - $idle_delta) / $total_delta * 100)
        }

        let mem = (
          open --raw /proc/meminfo
          | lines
          | parse "{key}: {value} kB"
          | reduce -f {} {|row, acc| $acc | insert $row.key ($row.value | str trim | into int)}
        )
        let mem_used_bytes = (($mem.MemTotal - $mem.MemAvailable) * 1024)
        let disk_used_bytes = (^df -B1 --output=used / | lines | get 1 | str trim | into int)

        let cpu_total_cores = 64
        let mem_total_bytes = (256 * 1024 * 1024 * 1024)
        let disk_total_bytes = (1024 * 1024 * 1024 * 1024 * 1024)
        let cpu_used_cores = ($cpu_total_cores * $cpu_percent / 100)
        let memory_used_gib = ($mem_used_bytes / 1024 / 1024 / 1024)
        let disk_used_tib = ($disk_used_bytes / 1024 / 1024 / 1024 / 1024)

        let stats = {
          generatedAt: (date now | date to-timezone UTC | format date "%Y-%m-%dT%H:%M:%SZ")
          cpu: {
            usedCores: ($cpu_used_cores | round-to 4)
            totalCores: $cpu_total_cores
            percent: ($cpu_percent | round-to 4)
          }
          memory: {
            usedBytes: $mem_used_bytes
            totalBytes: $mem_total_bytes
            percent: (($mem_used_bytes / $mem_total_bytes * 100) | round-to 4)
          }
          disk: {
            usedBytes: $disk_used_bytes
            totalBytes: $disk_total_bytes
            percent: (($disk_used_bytes / $disk_total_bytes * 100) | round-to 6)
          }
          costPerSecondUsd: (
            ($cpu_used_cores * (20 / (30 * 24 * 60 * 60)))
            + ($memory_used_gib * ((0.005 / (60 * 60)) * 2))
            + ($disk_used_tib * ((0.0031 / (60 * 60)) * 2))
          )
        }

        let tmp = (^mktemp $"($out_dir)/stats.XXXXXX" | str trim)
        $stats | to json | save --force $tmp
        mv --force $tmp $"($out_dir)/stats.json"
      }
    '';
  };

  statsLoop = ix.lib.writeNushellApplication pkgs {
    name = "claude-code-demo-stats-loop";
    runtimeInputs = [
      pkgs.coreutils
      writeStats
    ];
    text = ''
      def main [] {
        loop {
          claude-code-demo-write-stats
          sleep 1sec
        }
      }
    '';
  };

  linuxBuildPackages = [
    pkgs.bc
    pkgs.bison
    pkgs.elfutils
    pkgs.findutils
    pkgs.flex
    pkgs.gcc
    pkgs.git
    pkgs.gnumake
    pkgs.gnugrep
    pkgs.ncurses
    pkgs.openssl
    pkgs.pahole
    pkgs.perl
    pkgs.pkg-config
    pkgs.python3
    pkgs.rsync
  ];

  minecraftVersion = "26.2-snapshot-6";
  minecraftLoaderVersion = "0.19.2";
  minecraftInstallerVersion = "1.1.1";
in
(ix.lib.mkFleetFor hostSystem) {
  deployment.switch = {
    # Build the target NixOS system on ix infrastructure. The local machine only
    # evaluates the plan and sends the derivation path to the switch command.
    buildOn = "remote";

    # Keep remote switch evaluation on the same source tree that produced the
    # local plan instead of whatever the example lock file last recorded.
    overrideInputs.index = ".";
  };

  nodes = {
    demo = {
      tags = [ "web" ];
      deployment.l7ProxyPorts = [ 80 ];
      modules = [
        (_: {
          ix.image.tag = "claude-code-demo";

          environment.systemPackages = linuxBuildPackages ++ [
            pkgs.btop
            pkgs.curl
          ];

          services.git-clone = {
            enable = true;
            url = "https://github.com/torvalds/linux.git";
            dest = "/src/linux";
          };

          systemd.services.claude-code-demo-stats = {
            description = "Claude Code demo VM stats";
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              Type = "simple";
              RuntimeDirectory = "claude-code-demo";
              RuntimeDirectoryMode = "0755";
              ExecStart = lib.getExe statsLoop;
            };
          };

          services.nginx = {
            enable = true;
            virtualHosts."claude-code-demo" = {
              default = true;
              root = "${demoSite}/share/claude-code-demo-site";
              locations."/stats.json".extraConfig = "root /run/claude-code-demo;";
              locations."/".extraConfig = "try_files $uri $uri/ /index.html;";
            };
          };

          networking.firewall.allowedTCPPorts = [ 80 ];
        })
      ];
    };

    minecraft = {
      deployment.ipv4 = true;
      modules = [
        (_: {
          # Fleets default ix.image.name to the node name (`minecraft` here).
          # Set a tag anyway so replacement images are named
          # `minecraft:claude-code-demo` instead of the less-informative
          # `minecraft:latest`.
          ix.image.tag = "claude-code-demo";

          services.minecraft = {
            enable = true;

            fabric = {
              enable = true;
              version = minecraftVersion;
              loaderVersion = minecraftLoaderVersion;
              installerVersion = minecraftInstallerVersion;
              src = ix.lib.artifacts.minecraft.servers."26.2-snapshot-6-fabric";
            };

            serverFiles."server.properties" = {
              motd = "Claude Code Demo TNT Lab";
              max-players = 20;
              online-mode = true;
              gamemode = "creative";
              force-gamemode = true;
              level-type = "minecraft:flat";
              spawn-protection = 0;
              allow-flight = true;
              view-distance = 10;
              simulation-distance = 8;
            };
          };
        })
      ];
    };
  };
}
