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
{
  options.ix.profiles.base.enable = lib.mkEnableOption "base runtime tools";

  config = lib.mkIf config.ix.profiles.base.enable {
    environment.systemPackages = builtins.attrValues {
      inherit (pkgs)
        bpftrace
        btop
        file
        gdb
        jq
        lldb
        lsof
        ncdu
        pv
        strace
        tcpdump
        ;
    };

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
  };
}
