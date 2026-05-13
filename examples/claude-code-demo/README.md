# Claude Code Demo

Two VMs:

- `linux`: a shellable ix VM with `btop`, Linux source in `/src/linux`, and a tiny Svelte status page on port 80.
- `minecraft`: a Fabric server pinned to `1.21.11`, creative mode, village seed, public Java port 25565. Ships the [spark](https://modrinth.com/mod/spark) profiler so `/spark profiler` works from the server console.

## Run

For the Linux/website demo only:

```bash
nix run .#claude-code-demo-plan -- --on linux
nix run .#claude-code-demo-linux-up
ix shell linux
```

`claude-code-demo-linux-up` builds the Linux VM OCI archive, pushes it to ix as
`linux:claude-code-demo`, and creates or starts the `linux` VM with port 80
behind the ix L7 proxy.

The equivalent explicit commands are:

```bash
archive=$(nix build .#claude-code-demo-linux-image --print-out-paths --no-link)
ix push "$archive" linux:claude-code-demo
ix new linux:claude-code-demo --name linux --region hil-1 --no-shell --l7-proxy-port 80
ix shell linux
```

If `linux` already exists, use the wrapper command instead of `ix new`; it will
start an existing stopped VM and only recreates failed VMs.

For the full Linux plus Minecraft demo:

```bash
nix run .#claude-code-demo-plan
nix run .#claude-code-demo-up
```

`up` builds the fleet's OCI image derivations, uploads the archives with the ix
CLI, and creates or starts the VMs from those uploaded images. Use this while
`ix switch` source switching is still unstable.

To create or start only one VM:

```bash
nix run .#claude-code-demo-linux-up
nix run .#claude-code-demo-minecraft-up
```

## Demo Flow

Open the first VM shell and show the machine:

```bash
ix shell linux
btop
cd /src/linux
```

Open the `linux` web URL before starting the build. The page is hosted inside the VM and shows live CPU usage out of 64 cores, memory usage out of 256 GiB, disk usage out of 1 PiB, and current cost per second. Start with the VM doing almost nothing to show the very low cost per second, then build the Linux kernel and watch the web view update as CPU and memory usage increase. The cost is dynamic: the VM is charged for the resources it is actually using, not a fixed machine size.

```bash
make -j$(nproc) defconfig bzImage
```

Then use Minecraft:

```bash
ix shell minecraft
```

Join the server, take a snapshot, blow up the creative village world with TNT, then switch or restore to show the stateful VM workflow. `switch` snapshots existing nodes before applying the new NixOS systems; `replace` is only for recreating VMs from OCI images.

## Behind The Hood Slides

1. Plan: `nix run .#claude-code-demo-plan` evaluates the fleet and shows the two target VMs, their systems, and their exposed ports.
2. Switch: `nix run .#claude-code-demo-switch` creates missing VMs, snapshots existing ones, then activates the NixOS systems in dependency order.
3. Linux VM: `ix shell linux` opens the build box with Linux source already cloned, live stats served by nginx, and enough CPU/memory/disk to make the machine feel real.
4. Web view: open the Linux VM web URL first and show the idle VM costing very little per second.
5. Dynamic pricing: start the kernel build, then return to the web view to show CPU and memory usage rising and cost per second increasing with actual resource usage.
6. Minecraft VM: `ix shell minecraft` shows the second VM is managed by the same fleet, but runs a different workload: a Fabric 1.21.11 server with a pinned server jar, the spark profiler mod, and declarative `server.properties`.
7. Stateful moment: snapshot, break the world with TNT, then switch or restore. The point is that normal updates preserve VM state; replacement images are only for explicit recreation.
8. Wrap: the same source tree defines both machines, their packages, service config, exposed ports, and rollout behavior.
