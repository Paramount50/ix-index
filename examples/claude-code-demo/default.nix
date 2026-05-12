{
  ix,
  hostSystem ? ix.lib.system,
  minecraftServer ? ix.lib.artifacts.minecraft.servers."26.2-snapshot-6-fabric",
}:
let
  pkgs = ix.lib.pkgs;
  inherit (pkgs) lib;
  fs = lib.fileset;
  demoSiteSrc = fs.toSource {
    root = ./site;
    fileset = fs.unions [
      ./site/index.html
      ./site/jsconfig.json
      ./site/package-lock.json
      ./site/package.json
      ./site/src/App.svelte
      ./site/src/main.js
      ./site/src/style.css
      ./site/vite.config.js
    ];
  };
  demoSite = pkgs.buildNpmPackage {
    pname = "claude-code-demo-site";
    version = "0.1.0";
    src = demoSiteSrc;
    npmDepsHash = "sha256-A4BvJKJGxDpfn65Es0bYT2k3Ugu57jbtQNOau2f3QtQ=";

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/share/claude-code-demo-site"
      cp -R dist/. "$out/share/claude-code-demo-site/"
      runHook postInstall
    '';
  };

  writeStats = pkgs.writeShellApplication {
    name = "claude-code-demo-write-stats";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
      pkgs.jq
    ];
    text = ''
      set -euo pipefail

      out_dir=/run/claude-code-demo
      mkdir -p "$out_dir"

      read_cpu() {
        awk '/^cpu / {
          total = $2 + $3 + $4 + $5 + $6 + $7 + $8 + $9 + $10
          idle = $5 + $6
          printf "%.0f %.0f\n", total, idle
        }' /proc/stat
      }

      read -r total_a idle_a < <(read_cpu)
      sleep 0.2
      read -r total_b idle_b < <(read_cpu)

      cpu_percent=$(
        awk -v total_a="$total_a" -v idle_a="$idle_a" -v total_b="$total_b" -v idle_b="$idle_b" '
          BEGIN {
            total_delta = total_b - total_a
            idle_delta = idle_b - idle_a
            if (total_delta <= 0) {
              printf "0.0000"
            } else {
              printf "%.4f", ((total_delta - idle_delta) / total_delta) * 100
            }
          }
        '
      )

      mem_used_bytes=$(
        awk '
          /^MemTotal:/ { total = $2 }
          /^MemAvailable:/ { available = $2 }
          END { printf "%.0f", (total - available) * 1024 }
        ' /proc/meminfo
      )
      disk_used_bytes=$(df -B1 --output=used / | awk 'NR == 2 { print $1 }')
      now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

      cpu_total_cores=64
      mem_total_bytes=$((256 * 1024 * 1024 * 1024))
      disk_total_bytes=$((1024 * 1024 * 1024 * 1024 * 1024))

      tmp=$(mktemp "$out_dir/stats.XXXXXX")
      jq -n \
        --arg generatedAt "$now" \
        --argjson cpuPercent "$cpu_percent" \
        --argjson cpuTotalCores "$cpu_total_cores" \
        --argjson memoryUsedBytes "$mem_used_bytes" \
        --argjson memoryTotalBytes "$mem_total_bytes" \
        --argjson diskUsedBytes "$disk_used_bytes" \
        --argjson diskTotalBytes "$disk_total_bytes" '
          def round4: (. * 10000) | round / 10000;
          def round6: (. * 1000000) | round / 1000000;

          ($cpuTotalCores * $cpuPercent / 100) as $cpuUsedCores
          | ($memoryUsedBytes / 1024 / 1024 / 1024) as $memoryUsedGiB
          | ($diskUsedBytes / 1024 / 1024 / 1024 / 1024) as $diskUsedTiB
          | {
              generatedAt: $generatedAt,
              cpu: {
                usedCores: ($cpuUsedCores | round4),
                totalCores: $cpuTotalCores,
                percent: ($cpuPercent | round4)
              },
              memory: {
                usedBytes: $memoryUsedBytes,
                totalBytes: $memoryTotalBytes,
                percent: (($memoryUsedBytes / $memoryTotalBytes * 100) | round4)
              },
              disk: {
                usedBytes: $diskUsedBytes,
                totalBytes: $diskTotalBytes,
                percent: (($diskUsedBytes / $diskTotalBytes * 100) | round6)
              },
              costPerSecondUsd: (
                ($cpuUsedCores * (20 / (30 * 24 * 60 * 60)))
                + ($memoryUsedGiB * ((0.005 / (60 * 60)) * 2))
                + ($diskUsedTiB * ((0.0031 / (60 * 60)) * 2))
              )
            }
        ' > "$tmp"
      mv "$tmp" "$out_dir/stats.json"
    '';
  };

  statsLoop = pkgs.writeShellApplication {
    name = "claude-code-demo-stats-loop";
    runtimeInputs = [
      pkgs.coreutils
      writeStats
    ];
    text = ''
      set -euo pipefail
      while true; do
        claude-code-demo-write-stats
        sleep 1
      done
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

    # This example flake depends on `github:indexable-inc/index`. During local
    # development, point that input back at the checkout running the command so
    # `nix run .#switch` uses your edited modules instead of the published repo.
    overrideInputs.index = ".";
  };

  nodes = {
    demo = {
      tags = [ "web" ];
      deployment.l7ProxyPorts = [ 80 ];
      modules = [
        (
          { ... }:
          {
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
          }
        )
      ];
    };

    minecraft = {
      deployment.ipv4 = true;
      modules = [
        (
          { ... }:
          {
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
                src = minecraftServer;
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
          }
        )
      ];
    };
  };
}
