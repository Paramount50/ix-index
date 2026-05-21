<script lang="ts">
  import { onMount } from 'svelte';
  import { LoroDoc } from 'loro-crdt';

  type JsonPrimitive = string | number | boolean | null;
  type JsonValue = JsonPrimitive | JsonValue[] | { [key: string]: JsonValue };

  type EventRecord = {
    [key: string]: JsonValue | undefined;
    kind: string;
    ts_ms: number;
    name?: string;
    node?: string;
    stream?: string;
    text?: string;
    exit_code?: number;
    iteration?: number;
    url?: string;
    mode?: string;
    program?: string;
    args?: string[];
    path_count?: number;
    event?: JsonValue;
  };

  let connected = $state(false);
  let events = $state<EventRecord[]>([]);
  let lines = $state<string[]>([]);
  let snapshotBytes = $state(0);

  const timeFormatter = new Intl.DateTimeFormat(undefined, {
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit'
  });

  const isObject = (value: unknown): value is Record<string, unknown> =>
    typeof value === 'object' && value !== null && !Array.isArray(value);

  const asString = (value: unknown) =>
    typeof value === 'string' && value.length > 0 ? value : undefined;

  const formatTime = (tsMs: number) => timeFormatter.format(new Date(tsMs));

  const humanize = (value: string) =>
    value
      .replace(/^codex-/, '')
      .replace(/[_.-]+/g, ' ')
      .replace(/\s+/g, ' ')
      .trim();

  const quotePart = (part: string) => (/[\s"']/.test(part) ? JSON.stringify(part) : part);

  const commandLine = (event: EventRecord) =>
    [event.program, ...(event.args ?? [])]
      .filter((part): part is string => typeof part === 'string' && part.length > 0)
      .map(quotePart)
      .join(' ');

  const codexRaw = (event: EventRecord) => (isObject(event.event) ? event.event : null);

  const codexPayload = (event: EventRecord) => {
    const raw = codexRaw(event);
    return raw ? (isObject(raw.item) ? raw.item : isObject(raw.payload) ? raw.payload : raw) : null;
  };

  const codexItemLabel = (event: EventRecord) => {
    const raw = codexRaw(event);
    const payload = codexPayload(event);
    return humanize(
      asString(payload?.type) ??
        asString(payload?.kind) ??
        asString(raw?.type) ??
        asString(raw?.kind) ??
        event.kind
    );
  };

  const codexStatus = (event: EventRecord) => {
    const kind = event.kind.replace(/^codex-/, '');
    if (kind.endsWith('.completed')) return 'completed';
    if (kind.endsWith('.started')) return 'started';
    if (kind.endsWith('.failed')) return 'failed';
    return humanize(kind);
  };

  const looksCommandLike = (event: EventRecord) => {
    const label = codexItemLabel(event);
    const text = event.text ?? '';
    return (
      /\b(command|exec|shell|tool)\b/.test(label) ||
      text.startsWith('/') ||
      text.includes(' -lc ')
    );
  };

  const eventGroup = (event: EventRecord) => {
    if (event.kind.startsWith('codex-')) return 'codex';
    if (event.kind.startsWith('process-')) return 'process';
    if (event.kind.startsWith('node-')) return 'node';
    if (event.kind.startsWith('iteration-')) return 'iteration';
    return humanize(event.kind).split(' ')[0] ?? event.kind;
  };

  const eventTitle = (event: EventRecord) => {
    if (event.kind === 'server') return 'viewer ready';
    if (event.kind === 'process-start') return `${event.name ?? 'process'} started`;
    if (event.kind === 'process-finish') return `${event.name ?? 'process'} finished`;
    if (event.kind === 'node-start') return `${event.node ?? 'node'} started`;
    if (event.kind === 'node-finish') return `${event.node ?? 'node'} finished`;
    if (event.kind === 'line') return `${event.stream ?? 'stdout'} line`;
    if (event.kind === 'pushed') return 'pushed changes';
    if (event.kind.startsWith('iteration-')) return humanize(event.kind);
    if (event.kind.startsWith('codex-')) return `${codexStatus(event)} ${codexItemLabel(event)}`;
    return humanize(event.kind);
  };

  const eventSubject = (event: EventRecord) => {
    if (event.name) return event.name;
    if (event.node) return event.node;
    if (event.iteration !== undefined) return `iteration ${event.iteration}`;
    if (event.stream) return event.stream;
    return '';
  };

  const eventTone = (event: EventRecord) => {
    if (event.exit_code !== undefined) return event.exit_code === 0 ? 'good' : 'bad';
    if (event.kind.endsWith('.failed')) return 'bad';
    if (event.kind === 'line' && event.stream === 'stderr') return 'warn';
    if (event.kind.endsWith('.started') || event.kind.endsWith('-start')) return 'active';
    if (event.kind.endsWith('.completed') || event.kind === 'server' || event.kind === 'pushed') {
      return 'good';
    }
    return 'neutral';
  };

  const detailPairs = (event: EventRecord): [string, string][] => {
    const pairs: [string, string][] = [];
    if (event.iteration !== undefined) pairs.push(['iteration', String(event.iteration)]);
    if (event.path_count !== undefined) pairs.push(['paths', String(event.path_count)]);
    if (event.exit_code !== undefined) pairs.push(['exit', String(event.exit_code)]);
    if (event.mode) pairs.push(['mode', event.mode]);
    return pairs;
  };

  const formatJson = (value: unknown) => JSON.stringify(value, null, 2) ?? '';

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
    return [...counts.entries()].sort((left, right) => right[1] - left[1]);
  });

  let latest = $derived(events.slice(-160).reverse());
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
      <strong>{lines.length}</strong>
      <span>raw lines</span>
    </div>
    <div>
      <strong>{snapshotBytes.toLocaleString()}</strong>
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
      <article class="event {eventTone(event)}">
        <div class="meta">
          <div class="title">
            <span class="kind">{eventGroup(event)}</span>
            <b>{eventTitle(event)}</b>
          </div>
          <div class="when">
            {#if eventSubject(event)}
              <span>{eventSubject(event)}</span>
            {/if}
            <time datetime={new Date(event.ts_ms).toISOString()}>{formatTime(event.ts_ms)}</time>
          </div>
        </div>

        {#if detailPairs(event).length > 0}
          <div class="details">
            {#each detailPairs(event) as [label, value]}
              <span><b>{value}</b>{label}</span>
            {/each}
          </div>
        {/if}

        {#if event.kind === 'server' && event.url}
          <a class="server-link" href={event.url}>{event.url}</a>
        {:else if event.kind === 'process-start'}
          <pre class="command">{commandLine(event)}</pre>
        {:else if event.kind === 'process-finish'}
          <p class="result">
            {event.exit_code === 0 ? 'completed cleanly' : 'failed with a non-zero exit'}
          </p>
        {:else if event.kind === 'line'}
          <pre class="log {event.stream === 'stderr' ? 'stderr' : 'stdout'}">{event.text ?? ''}</pre>
        {:else if event.kind.startsWith('codex-')}
          <div class="codex">
            <div class="codex-meta">
              <span>{codexItemLabel(event)}</span>
              <span>{codexStatus(event)}</span>
            </div>
            {#if event.text}
              <pre class={looksCommandLike(event) ? 'command' : 'message'}>{event.text}</pre>
            {/if}
            {#if event.event}
              <details>
                <summary>json</summary>
                <pre class="json">{formatJson(event.event)}</pre>
              </details>
            {/if}
          </div>
        {:else if event.text}
          <pre class="message">{event.text}</pre>
        {:else}
          <pre class="json">{formatJson(event)}</pre>
        {/if}
      </article>
    {/each}
  </section>
</main>
