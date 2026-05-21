<script lang="ts">
  import type { Iteration } from '../lib/types';
  import Duration from './Duration.svelte';
  import Run from './Run.svelte';
  import StatusDot from './StatusDot.svelte';

  let { iteration }: { iteration: Iteration } = $props();
</script>

<section class="iteration" data-status={iteration.status}>
  <header>
    <div class="left">
      <StatusDot status={iteration.status} />
      <span class="n">iteration {iteration.n}</span>
      {#if iteration.outcome === 'pushed'}
        <span class="outcome pushed">pushed{iteration.pathCount ? ` ${iteration.pathCount}` : ''}</span>
      {:else if iteration.outcome === 'clean'}
        <span class="outcome clean">no changes</span>
      {/if}
    </div>
    <Duration startedAt={iteration.startedAt} finishedAt={iteration.finishedAt} />
  </header>

  <div class="runs">
    {#each iteration.runs as run (run.id)}
      <Run {run} />
    {/each}
  </div>
</section>

<style>
  .iteration {
    padding: 18px 0 22px;
    border-top: 1px solid #18181b;
  }

  .iteration:first-child {
    border-top: 0;
  }

  header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    margin-bottom: 6px;
  }

  .left {
    display: flex;
    align-items: center;
    gap: 10px;
  }

  .n {
    color: #71717a;
    font-size: 11px;
    letter-spacing: 0.18em;
    text-transform: uppercase;
  }

  .outcome {
    font-size: 11px;
    letter-spacing: 0.04em;
    text-transform: lowercase;
    padding: 1px 6px;
    border-radius: 999px;
    border: 1px solid #2a2a2f;
  }

  .outcome.pushed {
    color: #86efac;
    border-color: #1f3a2a;
  }

  .outcome.clean {
    color: #a1a1aa;
  }

  .runs {
    display: grid;
    gap: 1px;
  }
</style>
