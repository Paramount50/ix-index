import { parseEvent, type CodexEvent, type KnownEvent } from './schema';
import type { Command, CommandCategory, State } from './types';

const looksLikeShell = (text: string): boolean =>
  /^(\/|\.{1,2}\/)|[ "']-lc[ "']|\s-{1,2}\w/.test(text) || text.startsWith('cd ');

const codexBase = (kind: string): string =>
  kind.replace(/^codex-/, '').replace(/\.(started|completed|failed)$/, '');

const codexLifecycle = (kind: string): 'started' | 'completed' | 'failed' | null => {
  if (kind.endsWith('.started')) return 'started';
  if (kind.endsWith('.completed')) return 'completed';
  if (kind.endsWith('.failed')) return 'failed';
  return null;
};

const inferCategory = (event: CodexEvent): CommandCategory => {
  if (event.category) return event.category;
  if (event.text && looksLikeShell(event.text)) return 'shell';
  return 'event';
};

const finish = (cmd: Command, ts: number, status: 'done' | 'failed', exitCode?: number): Command => ({
  ...cmd,
  finishedAt: ts,
  status,
  exitCode
});

const applyKnown = (state: State, event: KnownEvent): void => {
  const ts = event.ts_ms;
  switch (event.kind) {
    case 'server':
      if (event.url) state.serverUrl = event.url;
      return;

    case 'iteration-start':
      if (state.current) {
        state.history.push(finish(state.current, ts, 'done'));
        state.current = undefined;
      }
      state.iteration = event.iteration ?? (state.iteration ?? 0) + 1;
      state.iterationStartedAt = ts;
      state.iterationFinishedAt = undefined;
      state.outcome = 'running';
      state.pathCount = undefined;
      state.history = [];
      return;

    case 'iteration-clean':
    case 'pushed':
      state.iterationFinishedAt = ts;
      state.outcome = event.kind === 'pushed' ? 'pushed' : 'clean';
      if (event.kind === 'pushed' && event.path_count !== undefined) {
        state.pathCount = event.path_count;
      }
      if (state.current) {
        state.history.push(finish(state.current, ts, 'done'));
        state.current = undefined;
      }
      return;

    case 'line':
      if (state.current && event.text) {
        state.current.tail = event.text;
      }
      return;

    case 'process-finish':
      if (state.current && (event.exit_code ?? 0) !== 0) {
        state.history.push(finish(state.current, ts, 'failed', event.exit_code));
        state.current = undefined;
      }
      return;
  }
};

const applyCodex = (state: State, event: CodexEvent): void => {
  if (!event.text) return;
  const ts = event.ts_ms;
  const lifecycle = codexLifecycle(event.kind);
  const base = codexBase(event.kind);
  if (base !== 'item' && base !== 'exec') return;

  const category = inferCategory(event);

  if (lifecycle === 'started') {
    if (state.current) {
      state.history.push(finish(state.current, ts, 'done'));
    }
    state.current = {
      text: event.text,
      startedAt: ts,
      status: 'running',
      category
    };
    return;
  }

  if (lifecycle === 'completed' || lifecycle === 'failed') {
    const status = lifecycle === 'failed' ? 'failed' : 'done';
    if (state.current && state.current.text === event.text) {
      state.history.push(finish(state.current, ts, status));
      state.current = undefined;
    } else {
      state.history.push({
        text: event.text,
        startedAt: ts,
        finishedAt: ts,
        status,
        category
      });
    }
  }
};

export const reduceEvents = (raws: unknown[]): Omit<State, 'connected'> => {
  const state: State = { connected: false, history: [] };
  for (const raw of raws) {
    const parsed = parseEvent(raw);
    if (!parsed) continue;
    if (parsed.tag === 'known') applyKnown(state, parsed.event);
    else if (parsed.tag === 'codex') applyCodex(state, parsed.event);
  }
  const { connected: _connected, ...rest } = state;
  return rest;
};
