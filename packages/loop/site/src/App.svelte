<script lang="ts">
  import { onMount } from 'svelte';
  import { LoroDoc } from 'loro-crdt';

  import Header from './components/Header.svelte';
  import Iteration from './components/Iteration.svelte';
  import Run from './components/Run.svelte';
  import { reduceEvents } from './lib/reduce';
  import { parseApiState, parseSnapshot } from './lib/schema';

  let connected = $state(false);
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
    source.addEventListener('open', () => {
      connected = true;
    });
    source.addEventListener('error', () => {
      connected = false;
    });
    source.addEventListener('loro', () => {
      void loadState();
    });
    return () => source.close();
  });

  let timeline = $derived(reduceEvents(rawEvents));
  let reversed = $derived([...timeline.iterations].reverse());
  let current = $derived(reversed[0]?.n);
  let orphans = $derived(timeline.orphans);
</script>

<main>
  <Header connected={connected} serverUrl={timeline.serverUrl} currentIteration={current} />

  {#if reversed.length === 0 && orphans.length === 0}
    <p class="empty">
      {connected ? 'waiting for the first event…' : 'connecting…'}
    </p>
  {/if}

  {#if orphans.length > 0}
    <section class="orphans">
      {#each orphans as run (run.id)}
        <Run {run} />
      {/each}
    </section>
  {/if}

  {#each reversed as iteration (iteration.startedAt)}
    <Iteration {iteration} />
  {/each}
</main>
