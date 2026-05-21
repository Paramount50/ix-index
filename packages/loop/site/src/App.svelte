<script lang="ts">
  import { onMount } from 'svelte';
  import { LoroDoc } from 'loro-crdt';

  import { reduceEvents } from './lib/reduce';
  import { parseApiState, parseSnapshot } from './lib/schema';

  let rawEvents = $state<unknown[]>([]);

  const decodeSnapshot = (encoded: string): unknown[] => {
    const bytes = Uint8Array.from(atob(encoded), (ch) => ch.charCodeAt(0));
    const doc = new LoroDoc();
    doc.import(bytes);
    return parseSnapshot(doc.toJSON());
  };

  const loadState = async () => {
    try {
      const response = await fetch('/api/state');
      const payload = parseApiState(await response.json());
      rawEvents = decodeSnapshot(payload.snapshot);
    } catch (err) {
      console.error('loop: failed to load state', err);
    }
  };

  onMount(() => {
    void loadState();
    const source = new EventSource('/events');
    source.addEventListener('loro', () => {
      void loadState();
    });
    return () => source.close();
  });

  let view = $derived(reduceEvents(rawEvents));
  let past = $derived([...view.history].reverse());
</script>

<main>
  {#if view.current}
    <pre class="line running">$ {view.current.text}</pre>
  {/if}
  {#each past as cmd}
    <pre class="line" class:failed={cmd.status === 'failed'}>$ {cmd.text}</pre>
  {/each}
</main>

<style>
  main {
    max-width: 1000px;
    margin: 0 auto;
    padding: 28px 32px 80px;
  }

  .line {
    margin: 0;
    padding: 4px 0;
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    font-size: 14px;
    line-height: 1.55;
    color: #a1a1aa;
    white-space: pre-wrap;
    overflow-wrap: anywhere;
  }

  .line.failed {
    color: #f87171;
  }

  .running {
    color: #fafafa;
    animation: flash 1.1s ease-in-out infinite;
  }

  @keyframes flash {
    0%, 100% {
      opacity: 0.55;
    }
    50% {
      opacity: 1;
    }
  }
</style>
