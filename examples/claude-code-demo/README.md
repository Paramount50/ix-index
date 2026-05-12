# Claude Code Demo

Two VMs:

- `demo`: a shellable ix VM with `btop`, Linux source in `/src/linux`, and a tiny Svelte status page on port 80.
- `minecraft`: a Fabric server pinned to `26.2-snapshot-6`, creative mode, flat world, public Java port 25565.

## Run

```bash
nix run .#claude-code-demo-plan
nix run .#claude-code-demo-switch
```

## Demo Flow

Open the first VM shell and show the machine:

```bash
ix shell demo
btop
cd /src/linux
make -j$(nproc) defconfig bzImage
```

Open the `demo` web URL. The page is hosted inside the VM and shows live CPU usage out of 64 cores, memory usage out of 256 GiB, disk usage out of 1 PiB, and current cost per second.

Then use Minecraft:

```bash
ix shell minecraft
```

Join the server, take a snapshot, blow up the flat creative world with TNT, then switch or restore to show the stateful VM workflow. `switch` snapshots existing nodes before applying the new NixOS systems; `replace` is only for recreating VMs from OCI images.

## Behind The Hood Slides

1. Plan: `nix run .#claude-code-demo-plan` evaluates the fleet and shows the two target VMs, their systems, and their exposed ports.
2. Switch: `nix run .#claude-code-demo-switch` creates missing VMs, snapshots existing ones, then activates the NixOS systems in dependency order.
3. Demo VM: `ix shell demo` opens the build box with Linux source already cloned, live stats served by nginx, and enough CPU/memory/disk to make the machine feel real.
4. Web view: open the demo URL to show the VM reporting its own CPU, memory, disk, and cost numbers while the kernel build runs.
5. Minecraft VM: `ix shell minecraft` shows the second VM is managed by the same fleet, but runs a different workload: a Fabric server with a pinned snapshot jar and declarative `server.properties`.
6. Stateful moment: snapshot, break the world with TNT, then switch or restore. The point is that normal updates preserve VM state; replacement images are only for explicit recreation.
7. Wrap: the same source tree defines both machines, their packages, service config, exposed ports, and rollout behavior.
