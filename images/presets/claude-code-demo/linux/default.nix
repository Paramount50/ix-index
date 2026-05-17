{ ix }:
let
  inherit (ix) pkgs;
  inherit (pkgs) lib;

  linuxCompileLibraries = [
    pkgs.elfutils
    pkgs.ncurses
    pkgs.openssl
    pkgs.zlib
  ];
  linuxCompileIncludes = lib.concatMapStringsSep " " (path: "-I${path}") (
    lib.splitString ":" (lib.makeSearchPathOutput "dev" "include" linuxCompileLibraries)
  );
  linuxCompileLibraryPath = lib.concatMapStringsSep " " (path: "-L${path}") (
    lib.splitString ":" (lib.makeLibraryPath linuxCompileLibraries)
  );

  compileLinux = ix.writeNushellApplication pkgs {
    name = "compile";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.git
      pkgs.gnumake
      pkgs.systemd
    ];
    text = ''
      $env.PKG_CONFIG_PATH = "${lib.makeSearchPathOutput "dev" "lib/pkgconfig" linuxCompileLibraries}"
      $env.NIX_CFLAGS_COMPILE = "${linuxCompileIncludes}"
      $env.NIX_LDFLAGS = "${linuxCompileLibraryPath}"

      def env-or [name: string, fallback: string] {
        let value = ($env | get --optional $name)
        if $value == null or ($value | is-empty) {
          $fallback
        } else {
          $value
        }
      }

      def run-throttled [cpu_quota: string, memory_max: string, command: list<string>] {
        let limits = [
          "-p"
          $"CPUQuota=($cpu_quota)"
          "-p"
          $"MemoryMax=($memory_max)"
        ]

        if ("/run/systemd/private" | path exists) {
          ^systemd-run --quiet --wait --collect ...$limits ...$command
        } else {
          ^$command.0 ...($command | skip 1)
        }
      }

      def source-ready [source_dir: string] {
        [
          "Makefile"
          "kernel"
          "scripts"
          "arch/x86/boot"
        ] | all {|path| ($source_dir | path join $path) | path exists }
      }

      def ensure-source [source_dir: string] {
        if (source-ready $source_dir) {
          return
        }

        if ($source_dir | path exists) {
          rm --recursive --force $source_dir
        }

        mkdir ($source_dir | path dirname)
        ^${lib.getExe pkgs.git} clone --quiet --depth 1 --single-branch https://github.com/torvalds/linux.git $source_dir

        if not (source-ready $source_dir) {
          error make {
            msg: $"Linux source tree bootstrap did not produce a complete checkout at ($source_dir)."
          }
        }
      }

      def main [...targets: string] {
        let source_dir = (env-or LINUX_SOURCE_DIR "/src/linux")
        ensure-source $source_dir

        cd $source_dir

        let cpu_quota = (env-or LINUX_BUILD_CPU_QUOTA "1600%")
        let memory_max = (env-or LINUX_BUILD_MEMORY_MAX "64G")
        let nproc = (^nproc | str trim | into int)
        let default_jobs = ([ $nproc 16 ] | math min | into string)
        let jobs = (env-or LINUX_BUILD_JOBS $default_jobs)

        if not (".config" | path exists) {
          run-throttled $cpu_quota $memory_max ["${lib.getExe pkgs.gnumake}" "defconfig"]
        }

        run-throttled $cpu_quota $memory_max (["${lib.getExe pkgs.gnumake}" $"-j($jobs)"] ++ $targets)
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
    pkgs.zlib
  ];
in
{
  tags = [ "web" ];
  deployment.l7ProxyPorts = [ 80 ];
  modules = [
    (_: {
      environment.systemPackages = linuxBuildPackages ++ [
        pkgs.btop
        compileLinux
        pkgs.curl
      ];

      services.git-clone = {
        enable = true;
        activation = "timer";
        url = "https://github.com/torvalds/linux.git";
        dest = "/src/linux";
      };

      systemd.services.git-clone.serviceConfig.ExecStartPost =
        "${lib.getExe' pkgs.coreutils "ln"} -sfn ${lib.getExe compileLinux} /src/linux/compile";

      services.resource-monitor = {
        enable = true;
        port = 80;
      };
    })
  ];
}
