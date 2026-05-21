<script lang="ts">
  import { getNow } from '../lib/clock.svelte';
  import { formatDuration } from '../lib/format';

  let {
    startedAt,
    finishedAt
  }: {
    startedAt: number;
    finishedAt?: number;
  } = $props();

  let elapsed = $derived(
    finishedAt !== undefined ? finishedAt - startedAt : getNow() - startedAt
  );
</script>

<time class:running={finishedAt === undefined}>{formatDuration(elapsed)}</time>

<style>
  time {
    color: #71717a;
    font-variant-numeric: tabular-nums;
    font-size: 12px;
    letter-spacing: 0.02em;
  }

  time.running {
    color: #d4b066;
  }
</style>
