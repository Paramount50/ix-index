<script lang="ts">
  import type { LogLine } from '../lib/types';

  let { logs, max = 12 }: { logs: LogLine[]; max?: number } = $props();

  let visible = $derived(logs.slice(-max));
  let hidden = $derived(Math.max(0, logs.length - visible.length));
</script>

{#if logs.length > 0}
  <div class="tail">
    {#if hidden > 0}
      <div class="more">+{hidden} earlier</div>
    {/if}
    {#each visible as log (log.ts)}
      <div class="line {log.stream}">{log.text || ' '}</div>
    {/each}
  </div>
{/if}

<style>
  .tail {
    margin-top: 6px;
    padding-left: 16px;
    border-left: 1px solid #1e1e22;
    display: grid;
    gap: 1px;
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    font-size: 11.5px;
    line-height: 1.45;
  }

  .more {
    color: #52525b;
    font-style: italic;
  }

  .line {
    color: #a1a1aa;
    white-space: pre-wrap;
    overflow-wrap: anywhere;
  }

  .line.stderr {
    color: #fca5a5;
  }
</style>
