import { svelte } from '@sveltejs/vite-plugin-svelte';
import { defineConfig } from 'vite';
import topLevelAwait from 'vite-plugin-top-level-await';
import wasm from 'vite-plugin-wasm';

export default defineConfig({
  build: {
    target: 'esnext'
  },
  esbuild: {
    target: 'esnext'
  },
  plugins: [wasm(), topLevelAwait(), svelte()]
});
