# Crazy Terrain

One ix fleet node running a Fabric `1.21.11` server with
[`terrain-diffusion`](https://github.com/xandergos/terrain-diffusion-mc), a
diffusion-model world generator that replaces vanilla noise with neural
terrain.

## Run

```sh
ix up
```

## Shape

[`minecraft.nix`](minecraft.nix) is the whole image: Fabric loader,
`fabric-api`, and `terrain-diffusion`. View distance is bumped to `16` so the
generator actually has chunks to work on.

The mod catalog at `images/games/minecraft/mods/1.21.11.json` pins the **CPU**
build of `terrain-diffusion`. Upstream's `v2.1.0` release ships a sibling GPU
jar; to use it, swap the URL in
`images/games/minecraft/mods/manifest.json` and regenerate with `nix run
.#update-mods -- --version 1.21.11` on a host that has a CUDA-capable GPU
exposed to the VM. The CPU build still works, it is just slower per chunk.

## Bad Fit If

- You want vanilla terrain. The whole point of this example is the generator.
- You want Paper or Bukkit plugins. `terrain-diffusion` is Fabric-only; see
  [`../survival/`](../survival/) for the Paper-plus-Velocity shape.
