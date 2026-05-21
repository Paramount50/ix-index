<script lang="ts">
  import { onMount } from 'svelte';
  import { LoroDoc } from 'loro-crdt';

  import { getNow } from './lib/clock.svelte';
  import { formatDuration } from './lib/format';
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

  let view = $derived(reduceEvents(rawEvents));
  let currentElapsed = $derived(
    view.current ? getNow() - view.current.startedAt : 0
  );
  let recent = $derived([...view.history].slice(-6).reverse());
</script>

<main>
  <header>
    <span class="dot" class:online={connected}></span>
    <span class="tag">loop</span>
    {#if view.iteration !== undefined}
      <span class="iter">#{view.iteration}</span>
    {/if}
    {#if view.outcome === 'pushed'}
      <span class="badge pushed">pushed{view.pathCount ? ` ${view.pathCount}` : ''}</span>
    {:else if view.outcome === 'clean'}
      <span class="badge clean">clean</span>
    {/if}
    <span class="grow"></span>
    {#if view.serverUrl}
      <a class="url" href={view.serverUrl}>{view.serverUrl.replace(/^https?:\/\//, '')}</a>
    {/if}
  </header>

  {#if view.current}
    <section class="now" data-state="running">
      <pre class="cmd">{view.current.text}</pre>
      <div class="meta">
        <span class="dur">{formatDuration(currentElapsed)}</span>
        {#if view.current.tail}
          <span class="tail">{view.current.tail}</span>
        {/if}
      </div>
    </section>
  {:else}
    <section class="now" data-state="pending">
      <pre class="cmd muted">pending</pre>
    </section>
  {/if}

  {#if recent.length > 0}
    <ol class="trail">
      {#each recent as cmd (cmd.startedAt)}
        <li data-status={cmd.status}>
          <span class="d"></span>
          <pre class="t">{cmd.text}</pre>
          <span class="dur">
            {formatDuration((cmd.finishedAt ?? cmd.startedAt) - cmd.startedAt)}
          </span>
        </li>
      {/each}
    </ol>
  {/if}
</main>

<style>
  main {
    max-width: 920px;
    margin: 0 auto;
    padding: 24px 28px 80px;
    color: #e4e4e7;
    font-family: ui-sans-serif, system-ui, -apple-system, sans-serif;
  }

  header {
    display: flex;
    align-items: center;
    gap: 10px;
    padding-bottom: 28px;
    font-size: 12px;
    letter-spacing: 0.04em;
  }

  .dot {
    width: 7px;
    height: 7px;
    border-radius: 999px;
    background: #3f3f46;
  }
  .dot.online {
    background: #4ade80;
    box-shadow: 0 0 8px rgba(74, 222, 128, 0.5);
  }

  .tag {
    color: #f4f4f5;
    font-weight: 600;
  }

  .iter {
    color: #71717a;
    font-variant-numeric: tabular-nums;
  }

  .badge {
    font-size: 10.5px;
    letter-spacing: 0.06em;
    padding: 2px 7px;
    border-radius: 999px;
    border: 1px solid #27272a;
    color: #a1a1aa;
    text-transform: lowercase;
  }
  .badge.pushed {
    color: #86efac;
    border-color: #1f3a2a;
  }

  .grow {
    flex: 1;
  }

  .url {
    color: #52525b;
    font-size: 11px;
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    text-decoration: none;
  }
  .url:hover {
    color: #a1a1aa;
  }

  .now {
    border: 1px solid #1f1f23;
    border-radius: 10px;
    padding: 22px 24px;
    background: #0c0c0e;
    position: relative;
    overflow: hidden;
  }

  .now[data-state='running'] {
    border-color: #3a2f12;
  }
  .now[data-state='running']::before {
    content: '';
    position: absolute;
    inset: 0;
    background: radial-gradient(
      circle at top left,
      rgba(251, 191, 36, 0.08),
      transparent 60%
    );
    animation: pulse 2.2s ease-in-out infinite;
    pointer-events: none;
  }

  .now[data-state='pending'] {
    border-style: dashed;
    border-color: #27272a;
  }

  .cmd {
    margin: 0;
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    font-size: 14px;
    line-height: 1.55;
    color: #fafafa;
    white-space: pre-wrap;
    overflow-wrap: anywhere;
  }
  .cmd.muted {
    color: #52525b;
    animation: blink 1.6s ease-in-out infinite;
  }
  .now[data-state='running'] .cmd {
    color: #fde68a;
  }

  .meta {
    margin-top: 14px;
    display: flex;
    align-items: baseline;
    gap: 14px;
    font-size: 11.5px;
    color: #71717a;
  }

  .dur {
    font-variant-numeric: tabular-nums;
    color: #a1a1aa;
  }
  .now[data-state='running'] .dur {
    color: #fbbf24;
  }

  .tail {
    color: #71717a;
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    min-width: 0;
    flex: 1;
  }

  .trail {
    margin: 22px 0 0;
    padding: 0;
    list-style: none;
    display: grid;
    gap: 2px;
  }

  .trail li {
    display: grid;
    grid-template-columns: 10px 1fr auto;
    align-items: center;
    gap: 10px;
    padding: 4px 6px;
    border-radius: 4px;
    color: #71717a;
    font-size: 11.5px;
  }

  .trail .d {
    width: 5px;
    height: 5px;
    border-radius: 999px;
    background: #3f3f46;
  }
  .trail li[data-status='done'] .d {
    background: #2f5e3c;
  }
  .trail li[data-status='failed'] .d {
    background: #7f1d1d;
  }
  .trail li[data-status='failed'] {
    color: #fca5a5;
  }

  .trail .t {
    margin: 0;
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .trail .dur {
    color: #52525b;
  }

  @keyframes pulse {
    0%, 100% {
      opacity: 0.55;
    }
    50% {
      opacity: 1;
    }
  }

  @keyframes blink {
    0%, 100% {
      opacity: 0.45;
    }
    50% {
      opacity: 0.9;
    }
  }
</style>
