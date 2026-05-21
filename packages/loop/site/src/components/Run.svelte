<script lang="ts">
  import type { Run } from '../lib/types';
  import Duration from './Duration.svelte';
  import LogTail from './LogTail.svelte';
  import StatusDot from './StatusDot.svelte';
  import Self from './Run.svelte';

  let { run, depth = 0 }: { run: Run; depth?: number } = $props();

  let hasChildren = $derived(run.children.length > 0);
  let hasLogs = $derived(run.logs.length > 0);
  let expandable = $derived(hasChildren || hasLogs);

  let expanded = $state(false);
  $effect(() => {
    if (run.status === 'running') expanded = true;
  });

  const toggle = () => {
    if (expandable) expanded = !expanded;
  };
</script>

<div class="run depth-{Math.min(depth, 3)}" data-status={run.status}>
  {#if expandable}
    <button type="button" class="row" onclick={toggle}>
      <StatusDot status={run.status} />
      <span class="label">{run.label}</span>
      {#if run.detail}
        <span class="detail">{run.detail}</span>
      {/if}
      <span class="spacer"></span>
      {#if run.exitCode !== undefined && run.exitCode !== 0}
        <span class="exit">exit {run.exitCode}</span>
      {/if}
      <Duration startedAt={run.startedAt} finishedAt={run.finishedAt} />
      <span class="chev" class:open={expanded}>›</span>
    </button>
  {:else}
    <div class="row">
      <StatusDot status={run.status} />
      <span class="label">{run.label}</span>
      {#if run.detail}
        <span class="detail">{run.detail}</span>
      {/if}
      <span class="spacer"></span>
      {#if run.exitCode !== undefined && run.exitCode !== 0}
        <span class="exit">exit {run.exitCode}</span>
      {/if}
      <Duration startedAt={run.startedAt} finishedAt={run.finishedAt} />
    </div>
  {/if}

  {#if expanded}
    {#if hasChildren}
      <div class="children">
        {#each run.children as child (child.id)}
          <Self run={child} depth={depth + 1} />
        {/each}
      </div>
    {/if}
    {#if hasLogs}
      <LogTail logs={run.logs} />
    {/if}
  {/if}
</div>

<style>
  .run {
    display: grid;
    gap: 4px;
  }

  .row {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 6px 0;
    width: 100%;
    min-width: 0;
    background: transparent;
    border: 0;
    color: inherit;
    font: inherit;
    text-align: left;
  }

  button.row {
    cursor: pointer;
  }

  button.row:hover .label,
  button.row:focus-visible .label {
    color: #fafafa;
  }

  button.row:focus-visible {
    outline: 1px solid #3f3f46;
    outline-offset: 2px;
    border-radius: 4px;
  }

  .label {
    color: #e4e4e7;
    font-size: 12.5px;
    letter-spacing: 0.02em;
    text-transform: lowercase;
    flex: none;
  }

  .detail {
    color: #a1a1aa;
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    font-size: 12px;
    line-height: 1.4;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    min-width: 0;
    flex: 1;
  }

  .run[data-status='running'] .detail {
    color: #fde68a;
  }

  .run[data-status='failed'] .label {
    color: #fca5a5;
  }

  .spacer {
    flex: 0;
  }

  .exit {
    color: #fca5a5;
    font-size: 11px;
    font-variant-numeric: tabular-nums;
  }

  .chev {
    color: #52525b;
    font-size: 14px;
    transition: transform 120ms ease;
    width: 10px;
    text-align: center;
  }

  .chev.open {
    transform: rotate(90deg);
  }

  .children {
    margin-left: 17px;
    border-left: 1px solid #18181b;
    padding-left: 12px;
  }
</style>
