<script lang="ts">
  import { onMount } from 'svelte';
  import { LoroDoc } from 'loro-crdt';

  import { reduceEvents } from './lib/reduce';
  import { parseApiState, parseSnapshot } from './lib/schema';
  import { tokenize } from './lib/highlight';
  import type { Command } from './lib/types';

  let rawEvents = $state<unknown[]>([]);
  let now = $state(Date.now());
  let listEl: HTMLElement | undefined = $state();
  let stickToBottom = $state(true);

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
    const tick = window.setInterval(() => (now = Date.now()), 250);
    return () => {
      source.close();
      window.clearInterval(tick);
    };
  });

  const view = $derived(reduceEvents(rawEvents));
  const rows = $derived<Command[]>([
    ...view.history,
    ...(view.current ? [view.current] : [])
  ]);

  $effect(() => {
    void rows.length;
    if (!stickToBottom || !listEl) return;
    requestAnimationFrame(() => {
      if (listEl) listEl.scrollTop = listEl.scrollHeight;
    });
  });

  const onScroll = () => {
    if (!listEl) return;
    const distance = listEl.scrollHeight - listEl.scrollTop - listEl.clientHeight;
    stickToBottom = distance < 24;
  };

  const jumpToBottom = () => {
    if (!listEl) return;
    stickToBottom = true;
    listEl.scrollTop = listEl.scrollHeight;
  };

  const fmtDuration = (ms: number): string => {
    if (ms < 0) ms = 0;
    if (ms < 1000) return `${ms}ms`;
    if (ms < 10_000) return `${(ms / 1000).toFixed(1)}s`;
    if (ms < 60_000) return `${Math.round(ms / 1000)}s`;
    const totalSec = Math.floor(ms / 1000);
    const m = Math.floor(totalSec / 60);
    const s = totalSec % 60;
    if (m < 60) return `${m}m ${s.toString().padStart(2, '0')}s`;
    const h = Math.floor(m / 60);
    return `${h}h ${(m % 60).toString().padStart(2, '0')}m`;
  };

  const fmtClock = (ts: number): string => {
    const d = new Date(ts);
    return d.toLocaleTimeString([], {
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
      hour12: false
    });
  };

  const durationOf = (cmd: Command, ref: number): number =>
    (cmd.finishedAt ?? ref) - cmd.startedAt;

  const outcomeLabel = (outcome: string | undefined): string => {
    if (outcome === 'pushed') return 'pushed';
    if (outcome === 'clean') return 'clean';
    if (outcome === 'running') return 'running';
    return 'idle';
  };

  const iterationDuration = $derived.by(() => {
    if (view.iterationStartedAt === undefined) return undefined;
    const end = view.iterationFinishedAt ?? now;
    return end - view.iterationStartedAt;
  });
</script>

<div class="app">
  <header class="bar">
    <div class="bar-left">
      <span class="brand">loop</span>
      {#if view.iteration !== undefined}
        <span class="chip">iter {view.iteration}</span>
      {/if}
      <span class="chip outcome {view.outcome ?? 'idle'}">
        <span class="chip-dot"></span>
        {outcomeLabel(view.outcome)}
      </span>
      {#if view.pathCount !== undefined && view.outcome === 'pushed'}
        <span class="chip muted">{view.pathCount} file{view.pathCount === 1 ? '' : 's'}</span>
      {/if}
    </div>
    <div class="bar-right">
      {#if iterationDuration !== undefined}
        <span class="meta-label">elapsed</span>
        <span class="meta-value">{fmtDuration(iterationDuration)}</span>
      {/if}
      <span class="count">{rows.length} step{rows.length === 1 ? '' : 's'}</span>
    </div>
  </header>

  <main class="list" bind:this={listEl} onscroll={onScroll}>
    {#if rows.length === 0}
      <div class="empty">waiting for the first command…</div>
    {:else}
      {#each rows as cmd, i (i)}
        {@const isLast = i === rows.length - 1}
        {@const dur = durationOf(cmd, now)}
        <article
          class="row"
          data-status={cmd.status}
          data-category={cmd.category}
          class:last={isLast}
        >
          <div class="gutter">
            <span class="indicator" aria-hidden="true"></span>
            <span class="seq">{i + 1}</span>
          </div>
          <div class="body">
            <div class="tag">{cmd.category}</div>
            {#if cmd.category === 'shell'}
              <div class="cmd">
                {#each tokenize(cmd.text) as t}<span class={t.kind}>{t.text}</span>{/each}
              </div>
            {:else}
              <div class="prose" class:reasoning={cmd.category === 'reasoning'} class:patch={cmd.category === 'patch'}>{cmd.text}</div>
            {/if}
            {#if cmd.status === 'running' && cmd.tail}
              <div class="tail">{cmd.tail}</div>
            {/if}
            {#if cmd.status === 'failed' && cmd.exitCode !== undefined}
              <div class="error">exit {cmd.exitCode}</div>
            {/if}
          </div>
          <div class="meta">
            <span class="dur">{fmtDuration(dur)}</span>
            <span class="time">{fmtClock(cmd.startedAt)}</span>
          </div>
        </article>
      {/each}
    {/if}
  </main>

  {#if !stickToBottom && rows.length > 0}
    <button class="jump" onclick={jumpToBottom} aria-label="scroll to bottom">
      jump to latest ↓
    </button>
  {/if}
</div>

<style>
  .app {
    display: flex;
    flex-direction: column;
    height: 100vh;
    max-width: 1100px;
    margin: 0 auto;
    position: relative;
  }

  .bar {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 16px;
    padding: 14px 28px;
    border-bottom: 1px solid #18181b;
    background: #0a0a0b;
    position: sticky;
    top: 0;
    z-index: 2;
  }

  .bar-left,
  .bar-right {
    display: flex;
    align-items: center;
    gap: 10px;
    font-size: 12px;
    font-family: ui-sans-serif, system-ui, -apple-system, 'Segoe UI', sans-serif;
  }

  .brand {
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    font-size: 13px;
    font-weight: 600;
    color: #e4e4e7;
    letter-spacing: -0.01em;
  }

  .chip {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 3px 9px;
    border-radius: 999px;
    background: #18181b;
    color: #d4d4d8;
    font-size: 11.5px;
    font-variant-numeric: tabular-nums;
    border: 1px solid #27272a;
  }

  .chip.muted {
    color: #71717a;
  }

  .chip-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: #52525b;
  }

  .outcome.running {
    color: #fbbf24;
    border-color: #422006;
    background: #1c1206;
  }
  .outcome.running .chip-dot {
    background: #fbbf24;
    box-shadow: 0 0 0 0 rgba(251, 191, 36, 0.6);
    animation: pulse 1.6s ease-in-out infinite;
  }

  .outcome.pushed {
    color: #86efac;
    border-color: #052e16;
    background: #051f0f;
  }
  .outcome.pushed .chip-dot {
    background: #86efac;
  }

  .outcome.clean {
    color: #93c5fd;
    border-color: #0c2236;
    background: #060f1a;
  }
  .outcome.clean .chip-dot {
    background: #93c5fd;
  }

  .outcome.idle {
    color: #71717a;
  }

  .meta-label {
    color: #52525b;
    font-size: 11px;
  }

  .meta-value {
    color: #d4d4d8;
    font-variant-numeric: tabular-nums;
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    font-size: 12px;
  }

  .count {
    color: #52525b;
    font-variant-numeric: tabular-nums;
  }

  .list {
    flex: 1;
    overflow-y: auto;
    padding: 8px 0 96px;
    scroll-behavior: smooth;
  }

  .empty {
    padding: 80px 32px;
    text-align: center;
    color: #52525b;
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    font-size: 13px;
  }

  .row {
    display: grid;
    grid-template-columns: 56px 1fr auto;
    gap: 14px;
    padding: 10px 28px 10px 0;
    align-items: flex-start;
    position: relative;
    transition: background 120ms ease;
  }

  .row:hover {
    background: #0e0e10;
  }

  .row[data-status='done'] {
    opacity: 0.7;
  }

  .row[data-status='running'] {
    background: #0d0e08;
  }
  .row[data-status='running']:hover {
    background: #11120a;
  }

  .row[data-status='failed'] {
    background: #150909;
  }

  .gutter {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 4px 0 0 18px;
    color: #3f3f46;
    font-variant-numeric: tabular-nums;
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    font-size: 11px;
  }

  .indicator {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: #3f3f46;
    flex-shrink: 0;
  }

  .row[data-status='done'] .indicator {
    background: #3f3f46;
  }

  .row[data-status='running'] .indicator {
    background: #fbbf24;
    box-shadow: 0 0 0 0 rgba(251, 191, 36, 0.55);
    animation: pulse 1.6s ease-in-out infinite;
  }

  .row[data-status='failed'] .indicator {
    background: #f87171;
  }

  .body {
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  .cmd {
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    font-size: 13.5px;
    line-height: 1.55;
    color: #a1a1aa;
    white-space: pre-wrap;
    overflow-wrap: anywhere;
  }

  .tag {
    display: inline-block;
    align-self: flex-start;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    font-size: 9.5px;
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    color: #52525b;
    padding: 1px 5px;
    border-radius: 3px;
    background: #131316;
    border: 1px solid #1f1f23;
  }

  .row[data-category='message'] .tag { color: #a5b4fc; border-color: #1e1b4b; background: #0c0a1f; }
  .row[data-category='reasoning'] .tag { color: #c4b5fd; border-color: #2e1065; background: #110926; }
  .row[data-category='patch'] .tag { color: #fcd34d; border-color: #3f2e07; background: #1c1407; }
  .row[data-category='tool'] .tag { color: #67e8f9; border-color: #0c2a36; background: #07151b; }

  .prose {
    font-family: ui-sans-serif, system-ui, -apple-system, 'Segoe UI', sans-serif;
    font-size: 13.5px;
    line-height: 1.55;
    color: #d4d4d8;
    white-space: pre-wrap;
    overflow-wrap: anywhere;
  }

  .prose.reasoning {
    color: #a78bfa;
    font-style: italic;
    border-left: 2px solid #2e1065;
    padding-left: 10px;
  }

  .prose.patch {
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    font-size: 12.5px;
    color: #fde68a;
    background: #0e0a05;
    border-left: 2px solid #3f2e07;
    padding: 6px 10px;
    border-radius: 3px;
  }

  .tail {
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    font-size: 12px;
    color: #52525b;
    white-space: pre-wrap;
    overflow-wrap: anywhere;
    padding-left: 14px;
    border-left: 2px solid #1c1c1f;
  }

  .error {
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    font-size: 11.5px;
    color: #f87171;
  }

  .meta {
    display: flex;
    flex-direction: column;
    align-items: flex-end;
    gap: 2px;
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    font-variant-numeric: tabular-nums;
    padding-top: 2px;
  }

  .dur {
    font-size: 12px;
    color: #71717a;
  }

  .row[data-status='running'] .dur {
    color: #fbbf24;
  }

  .row[data-status='failed'] .dur {
    color: #f87171;
  }

  .time {
    font-size: 10.5px;
    color: #3f3f46;
  }

  .cmd .cmd { color: #86efac; }
  .cmd .path { color: #cbd5e1; }
  .cmd .flag { color: #93c5fd; }
  .cmd .string { color: #fde68a; }
  .cmd .var { color: #c4b5fd; }
  .cmd .op { color: #f472b6; }
  .cmd .comment { color: #52525b; font-style: italic; }
  .cmd .arg { color: #a1a1aa; }

  .row[data-status='failed'] .cmd :is(.cmd, .path, .flag, .string, .var, .op, .arg) {
    color: #fca5a5;
  }

  .jump {
    position: absolute;
    bottom: 20px;
    left: 50%;
    transform: translateX(-50%);
    padding: 8px 14px;
    border-radius: 999px;
    border: 1px solid #27272a;
    background: #18181b;
    color: #d4d4d8;
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    font-size: 12px;
    cursor: pointer;
    box-shadow: 0 8px 24px rgba(0, 0, 0, 0.4);
    z-index: 3;
  }

  .jump:hover {
    background: #27272a;
    border-color: #3f3f46;
  }

  @keyframes pulse {
    0%, 100% {
      box-shadow: 0 0 0 0 rgba(251, 191, 36, 0.45);
    }
    50% {
      box-shadow: 0 0 0 6px rgba(251, 191, 36, 0);
    }
  }
</style>
