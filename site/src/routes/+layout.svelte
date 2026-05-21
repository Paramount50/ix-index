<script lang="ts">
  import type { Snippet } from 'svelte';
  import '../app.css';

  const { children }: { children: Snippet } = $props();
</script>

{@render children()}
