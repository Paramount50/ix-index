<script lang="ts">
  import { onMount } from 'svelte';
  import { LoroDoc } from 'loro-crdt';

  type EventRecord = {
    kind: string;
    ts_ms: number;
    name?: string;
    node?: string;
    stream?: string;
    text?: string;
    exit_code?: number;
    iteration?: number;
    url?: string;
  };

  let connected = $state(false);
  let events = $state<EventRecord[]>([]);
  let lines = $state<string[]>([]);
  let snapshotBytes = $state(0);

  const decodeSnapshot = (encoded: string) => {
    const raw = atob(encoded);
    const bytes = Uint8Array.from(raw, (char) => char.charCodeAt(0));
    const doc = new LoroDoc();
    doc.import(bytes);
    snapshotBytes = bytes.byteLength;
    const value = doc.toJSON() as { events?: EventRecord[] };
    events = value.events ?? [];
  };

  const loadState = async () => {
    const response = await fetch('/api/state');
    const payload = await response.json() as { snapshot: string; lines: string[] };
    lines = payload.lines;
    decodeSnapshot(payload.snapshot);
  };

  onMount(() => {
    loadState();
    const source = new EventSource('/events');
    source.addEventListener('open', () => {
      connected = true;
    });
    source.addEventListener('error', () => {
      connected = false;
    });
    source.addEventListener('loro', (message) => {
      lines = [...lines.slice(-499), message.data];
      loadState();
    });

    return () => source.close();
  });

  let statusCounts = $derived.by(() => {
    const counts = new Map<string, number>();
    for (const event of events) {
      counts.set(event.kind, (counts.get(event.kind) ?? 0) + 1);
    }
    return [...counts.entries()];
  });

  let latest = $derived(events.slice(-120).reverse());
</script>

<main>
  <header>
    <div>
      <h1>loop</h1>
      <p>Loro-backed run stream</p>
    </div>
    <span class:online={connected}>{connected ? 'connected' : 'offline'}</span>
  </header>

  <section class="summary">
    <div>
      <strong>{events.length}</strong>
      <span>events</span>
    </div>
    <div>
      <strong>{snapshotBytes}</strong>
      <span>Loro bytes</span>
    </div>
    {#each statusCounts as [kind, count]}
      <div>
        <strong>{count}</strong>
        <span>{kind}</span>
      </div>
    {/each}
  </section>

  <section class="events">
    {#each latest as event}
      <article>
        <div class="meta">
          <b>{event.kind}</b>
          <span>{event.name ?? event.node ?? event.iteration ?? ''}</span>
        </div>
        {#if event.text}
          <pre>{event.text}</pre>
        {:else}
          <code>{JSON.stringify(event)}</code>
        {/if}
      </article>
    {/each}
  </section>
</main>
