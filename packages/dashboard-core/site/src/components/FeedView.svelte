<script lang="ts">
  import { stripAnsi } from '$lib/ansi';
  import { store, timeline, SCOPE_SEP } from '$lib/stream.svelte';
  import { ui, focusPane, humanAge, humanDuration } from '$lib/ui.svelte';
  import { rendererFor } from '$lib/renderers';
  import CodeBlock from './CodeBlock.svelte';
  import ExecBody from './ExecBody.svelte';
  import InlineTrace from './InlineTrace.svelte';
  import type { Pane } from '$lib/types';

  // The feed: a chronological timeline of panes, newest first. Each block puts the
  // input on the left and its execution/output on the right — for an exec that is
  // source | output. The output is the larger, fuller column; the code is the
  // supporting one. Each block leads with the pane title, which for an exec is the
  // caller's `intent` (a plain-language statement of what the run is for), so the
  // feed reads as a list of intents rather than code; the lang/op/session sit
  // beside it as quiet meta. Non-exec panes have no input column, so their output
  // spans the block. Click a block to open it fullscreen.

  function ledLive(p: Pane): boolean {
    const kind = p.kind ?? 'data';
    if (kind === 'exec') return p.ok === true;
    if (kind === 'terminal') return p.alive !== false;
    return true;
  }
  function ledRun(p: Pane): boolean {
    return (p.kind ?? 'data') === 'exec' && p.running === true;
  }
  function ledErr(p: Pane): boolean {
    const kind = p.kind ?? 'data';
    return (kind === 'exec' && p.ok === false) || (kind === 'terminal' && p.alive === false);
  }
  // The thin meta tag: an exec's language, else its kind.
  function tag(p: Pane): string {
    const kind = p.kind ?? 'data';
    return kind === 'exec' ? p.lang || 'exec' : kind;
  }

  // The hub stores an exec's inline-trace as JSON text; parse it back to the
  // `{line, text}[]` the trace view consumes. Malformed/absent → no trace.
  function parseTrace(raw: string | undefined): { line: number; text: string }[] {
    if (!raw) return [];
    try {
      const value = JSON.parse(raw);
      return Array.isArray(value) ? value : [];
    } catch {
      return [];
    }
  }

  // Pull the essentials out of a Python traceback so a failed run shows *where* it
  // broke, not a wall of text: the final `Type: message` line, plus each frame in
  // the user's own exec source (filename `<ix-mcp exec>`) mapped to that source
  // line. A transport error (no traceback) yields just its message, no frames.
  type ErrInfo = { message: string; frames: { line: number; text: string }[] };
  function parseError(stderr: string | undefined, source: string | undefined): ErrInfo | null {
    const text = stripAnsi(stderr ?? '').trimEnd();
    if (!text) return null;
    const lines = text.split('\n');
    const message = lines.filter((l) => l.trim()).at(-1)?.trim() ?? text;
    const src = (source ?? '').split('\n');
    const frames: { line: number; text: string }[] = [];
    for (const m of text.matchAll(/File "([^"]*)", line (\d+)/g)) {
      const file = m[1];
      const line = Number(m[2]);
      // Only frames inside the run's own source have a line we can point at; the
      // exec wrapper names them `<ix-mcp exec>` (or another synthetic `<...>`).
      if (file.includes('ix-mcp') || file.startsWith('<')) {
        frames.push({ line, text: (src[line - 1] ?? '').trim() });
      }
    }
    return { message, frames };
  }

  // Ages read against wall-clock while following live, else the scrubbed-to moment.
  const refMs = $derived(
    timeline.source === 'live' && timeline.following ? ui.clock : timeline.position || timeline.maxTs,
  );

  // The feed is a quiet list of intents by default: one line per run, just what
  // it is doing. Clicking a row expands it to show the printed output; a further
  // `code` toggle inside reveals the source. Both states are keyed by pane key so
  // each entry remembers itself across re-renders.
  let expanded: Record<string, boolean> = $state({});
  let showCode: Record<string, boolean> = $state({});
  function toggleCode(e: MouseEvent, key: string): void {
    e.stopPropagation();
    showCode[key] = !showCode[key];
  }

  // Panes newest-first. created_at is the stamp; ties break by key for stability.
  const items = $derived(
    Object.keys(store.panes)
      .map((key) => {
        const sep = key.indexOf(SCOPE_SEP);
        const scope = sep === -1 ? '' : key.slice(0, sep);
        return { key, pane: { ...store.panes[key], key, scope } as Pane };
      })
      .sort(
        (a, b) =>
          (b.pane.created_at ?? 0) - (a.pane.created_at ?? 0) || (a.key < b.key ? -1 : 1),
      ),
  );

  // Vim navigation: `j`/`k` move the selection down/up, `o` (or Enter) toggles the
  // selected row open. Selection follows clicks too, so mouse and keyboard agree.
  let selectedKey: string | null = $state(null);
  $effect(() => {
    // Keep the selection valid as panes come and go; default to the first row.
    if (items.length === 0) selectedKey = null;
    else if (!items.some((it) => it.key === selectedKey)) selectedKey = items[0].key;
  });
  function move(delta: number): void {
    if (!items.length) return;
    const i = items.findIndex((it) => it.key === selectedKey);
    const next = Math.max(0, Math.min(items.length - 1, (i < 0 ? 0 : i) + delta));
    selectedKey = items[next].key;
    // Defer until the class lands so the freshly-selected row is the scroll target.
    queueMicrotask(() => {
      if (selectedKey == null) return;
      document
        .querySelector(`li.entry[data-key="${CSS.escape(selectedKey)}"]`)
        ?.scrollIntoView({ block: 'nearest' });
    });
  }
  function onKeydown(e: KeyboardEvent): void {
    const t = e.target as HTMLElement | null;
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    if (t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.isContentEditable)) return;
    if (e.key === 'j') {
      e.preventDefault();
      move(1);
    } else if (e.key === 'k') {
      e.preventDefault();
      move(-1);
    } else if (e.key === 'o' || e.key === 'Enter') {
      if (!selectedKey) return;
      e.preventDefault();
      expanded[selectedKey] = !(expanded[selectedKey] === true);
    }
  }
</script>

<svelte:window onkeydown={onKeydown} />

<div class="feed">
  {#if items.length === 0}
    <div class="feed-empty">{store.live ? 'no panes yet' : 'connecting…'}</div>
  {:else}
    <ol class="feed-rail">
      {#each items as it (it.key)}
        {@const p = it.pane}
        {@const k = p.kind ?? 'data'}
        {@const traceArr = k === 'exec' ? parseTrace(p.trace) : []}
        {@const traced = k === 'exec' && !!p.source && traceArr.length > 0}
        {@const hasSource = k === 'exec' && !!p.source}
        {@const running = ledRun(p)}
        {@const isErr = ledErr(p)}
        {@const isOpen = expanded[it.key] === true}
        {@const codeOpen = showCode[it.key] === true}
        <!-- A failed run shows a compact, parsed error by default (the message and
             where it broke) so the failure is visible without a click; expanding
             the row then reveals the full output. A success stays one quiet line. -->
        {@const errInfo = isErr && !isOpen ? parseError(p.stderr, p.source) : null}
        <li class="entry" class:open={isOpen} class:err={isErr} class:selected={selectedKey === it.key} data-key={it.key}>
          <!-- The whole row is the toggle: by default it shows just the intent
               (what the run is doing). Click to expand into the printed output. -->
          <button class="entry-row" onclick={() => { selectedKey = it.key; expanded[it.key] = !isOpen; }} title={`${tag(p)}${p.subtitle ? ' · ' + p.subtitle : ''}`}>
            <span class="entry-dot" class:live={ledLive(p)} class:run={running} class:err={isErr}></span>
            <span class="entry-title" title={p.title}>{p.title || '(pane)'}</span>
            <span class="entry-meta">
              {#if running}
                <span class="entry-now">running</span>
              {:else if p.duration_ms != null}
                <span class="entry-age" title="execution time">{humanDuration(p.duration_ms)}</span>
              {:else}
                <span class="entry-age">{humanAge(p.created_at, refMs)}</span>
              {/if}
              <span class="entry-chev">{isOpen ? '▾' : '▸'}</span>
            </span>
          </button>

          {#if isOpen}
            <div class="entry-detail">
              {#if k === 'exec'}
                <!-- Output is the point: lead with it. The source stays hidden until
                     the `code` toggle is on, then revealed below as the inline-trace
                     (each printed line beside its source line) when the producer
                     attributed output to lines, else a plain highlighted block. -->
                <div class="entry-box cell cell-out"><ExecBody pane={p} chrome={false} expanded /></div>
                {#if hasSource}
                  <button
                    class="entry-code-toggle"
                    class:on={codeOpen}
                    onclick={(e) => toggleCode(e, it.key)}
                    title={codeOpen ? 'hide code' : 'show code'}
                  >{codeOpen ? '▾' : '▸'} code</button>
                  {#if codeOpen}
                    {#if traced}
                      <div class="entry-box entry-trace-box entry-code-reveal">
                        <InlineTrace source={p.source ?? ''} lang={p.lang ?? 'text'} trace={traceArr} />
                        {#if p.stderr}<pre class="exec-out err trace-stderr">{stripAnsi(p.stderr)}</pre>{/if}
                      </div>
                    {:else}
                      <div class="entry-box entry-code entry-code-reveal"><CodeBlock code={p.source ?? ''} lang={p.lang ?? 'text'} /></div>
                    {/if}
                  {/if}
                {/if}
              {:else}
                {@const Body = rendererFor(k)}
                <div class="entry-box pane entry-body" class:term={k === 'terminal'} style={k === 'terminal' ? 'font-size: 13px;' : ''}>
                  <div class="body" class:term-body={k === 'terminal'} class:html-body={k === 'html'}>
                    <Body pane={p} />
                  </div>
                </div>
              {/if}
            </div>
          {:else if errInfo}
            <!-- Compact, parsed failure: the error message, then the source line(s)
                 it came from. Expand the row for the full output. -->
            <div class="entry-detail entry-fail">
              <div class="fail-msg">{errInfo.message}</div>
              {#each errInfo.frames as fr}
                <div class="fail-frame">
                  <span class="fail-line">{fr.line}</span>
                  <code class="fail-src">{fr.text}</code>
                </div>
              {/each}
            </div>
          {/if}
        </li>
      {/each}
    </ol>
  {/if}
</div>
