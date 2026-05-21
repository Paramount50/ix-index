import {
  parseEvent,
  type CodexEvent,
  type CodexPayload,
  type KnownEvent
} from './schema';
import type { Iteration, LogLine, Run, Timeline } from './types';

const quotePart = (part: string) => (/[\s"'\\]/.test(part) ? JSON.stringify(part) : part);

const argvLine = (program?: string, args?: string[]): string | undefined => {
  if (!program && (!args || args.length === 0)) return undefined;
  return [program ?? '', ...(args ?? [])].filter(Boolean).map(quotePart).join(' ');
};

const friendlyName = (raw: string): string => raw.replace(/[_.-]+/g, ' ').trim();

const codexBase = (kind: string): string =>
  kind.replace(/^codex-/, '').replace(/\.(started|completed|failed)$/, '');

const codexLifecycle = (kind: string): 'started' | 'completed' | 'failed' | null => {
  if (kind.endsWith('.started')) return 'started';
  if (kind.endsWith('.completed')) return 'completed';
  if (kind.endsWith('.failed')) return 'failed';
  return null;
};

const codexId = (payload: CodexPayload | undefined): string | undefined => {
  if (!payload) return undefined;
  const seen = new Set<CodexPayload>();
  const visit = (node: CodexPayload | undefined): string | undefined => {
    if (!node || seen.has(node)) return undefined;
    seen.add(node);
    if (node.id) return node.id;
    return visit(node.item) ?? visit(node.payload) ?? visit(node.data);
  };
  return visit(payload);
};

const looksLikeShell = (text: string): boolean =>
  /^(\/|\.{1,2}\/)|[ "']-lc[ "']|\s-{1,2}\w/.test(text) || text.startsWith('cd ');

const codexLabel = (event: CodexEvent): { label: string; detail?: string } => {
  const base = codexBase(event.kind);
  const text = event.text;
  if (text && looksLikeShell(text)) return { label: 'exec', detail: text };
  if (text) return { label: friendlyName(base) || 'event', detail: text };
  return { label: friendlyName(base) || 'event' };
};

const newRun = (id: string, label: string, startedAt: number, detail?: string): Run => ({
  id,
  label,
  detail,
  startedAt,
  status: 'running',
  logs: [],
  children: []
});

const closeRun = (
  run: Run,
  ts: number,
  status: 'done' | 'failed',
  exitCode?: number
): void => {
  run.finishedAt = ts;
  run.status = status;
  if (exitCode !== undefined) run.exitCode = exitCode;
};

type Frame = {
  iteration?: Iteration;
  byProcess: Map<string, Run>;
  byCodex: Map<string, Run>;
  codexStack: Run[];
  orphans: Run[];
};

const containerFor = (frame: Frame): Run[] => {
  const top = frame.codexStack.at(-1);
  if (top) return top.children;
  if (frame.iteration) return frame.iteration.runs;
  return frame.orphans;
};

const applyKnown = (timeline: Timeline, frame: Frame, event: KnownEvent): void => {
  const ts = event.ts_ms;
  switch (event.kind) {
    case 'server':
      if (event.url) timeline.serverUrl = event.url;
      return;

    case 'iteration-start': {
      if (frame.iteration && frame.iteration.status === 'running') {
        frame.iteration.status = 'done';
        frame.iteration.finishedAt = ts;
      }
      const n = event.iteration ?? timeline.iterations.length + 1;
      const iteration: Iteration = { n, startedAt: ts, status: 'running', runs: [] };
      timeline.iterations.push(iteration);
      frame.iteration = iteration;
      frame.byProcess.clear();
      frame.byCodex.clear();
      frame.codexStack.length = 0;
      return;
    }

    case 'iteration-clean':
    case 'pushed':
      if (!frame.iteration) return;
      frame.iteration.status = 'done';
      frame.iteration.finishedAt = ts;
      frame.iteration.outcome = event.kind === 'pushed' ? 'pushed' : 'clean';
      if (event.kind === 'pushed' && event.path_count !== undefined) {
        frame.iteration.pathCount = event.path_count;
      }
      return;

    case 'process-start': {
      const name = event.name ?? 'process';
      const run = newRun(
        `process:${name}:${ts}`,
        name,
        ts,
        argvLine(event.program, event.args)
      );
      frame.byProcess.set(name, run);
      containerFor(frame).push(run);
      return;
    }

    case 'process-finish': {
      const name = event.name ?? 'process';
      const run = frame.byProcess.get(name);
      const exitCode = event.exit_code ?? 0;
      if (run) {
        closeRun(run, ts, exitCode === 0 ? 'done' : 'failed', exitCode);
        frame.byProcess.delete(name);
      }
      while (frame.codexStack.length > 0) {
        const open = frame.codexStack.pop()!;
        if (open.status === 'running') closeRun(open, ts, 'done');
      }
      frame.byCodex.clear();
      return;
    }

    case 'node-start': {
      const name = event.node ?? 'node';
      const run = newRun(`node:${name}:${ts}`, name, ts);
      frame.byProcess.set(`node:${name}`, run);
      containerFor(frame).push(run);
      return;
    }

    case 'node-finish': {
      const name = event.node ?? 'node';
      const run = frame.byProcess.get(`node:${name}`);
      const exitCode = event.exit_code ?? 0;
      if (run) {
        closeRun(run, ts, exitCode === 0 ? 'done' : 'failed', exitCode);
        frame.byProcess.delete(`node:${name}`);
      }
      return;
    }

    case 'line': {
      const owner =
        frame.codexStack.at(-1) ?? frame.byProcess.get(event.name ?? 'process');
      if (!owner) return;
      const log: LogLine = { ts, stream: event.stream, text: event.text ?? '' };
      owner.logs.push(log);
      return;
    }

    case 'health-checks-complete': {
      const status = (event.exit_code ?? 0) === 0 ? 'done' : 'failed';
      const run = newRun(`health:${ts}`, 'health checks', ts);
      closeRun(run, ts, status, event.exit_code);
      containerFor(frame).push(run);
      return;
    }
  }
};

const applyCodex = (frame: Frame, event: CodexEvent): void => {
  const ts = event.ts_ms;
  const lifecycle = codexLifecycle(event.kind);
  const id = codexId(event.event) ?? `${codexBase(event.kind)}:${event.text ?? ''}`;
  const key = `${codexBase(event.kind)}#${id}`;

  if (lifecycle === 'started') {
    const { label, detail } = codexLabel(event);
    const run = newRun(`codex:${key}:${ts}`, label, ts, detail);
    frame.byCodex.set(key, run);
    containerFor(frame).push(run);
    frame.codexStack.push(run);
    return;
  }

  if (lifecycle === 'completed' || lifecycle === 'failed') {
    const run = frame.byCodex.get(key);
    const finalStatus = lifecycle === 'failed' ? 'failed' : 'done';
    if (run) {
      closeRun(run, ts, finalStatus);
      frame.byCodex.delete(key);
      const idx = frame.codexStack.lastIndexOf(run);
      if (idx >= 0) frame.codexStack.splice(idx, 1);
    } else {
      const { label, detail } = codexLabel(event);
      const oneShot = newRun(`codex:${key}:${ts}`, label, ts, detail);
      closeRun(oneShot, ts, finalStatus);
      containerFor(frame).push(oneShot);
    }
    return;
  }

  const owner = frame.codexStack.at(-1);
  if (owner && event.text) {
    owner.logs.push({ ts, stream: 'stdout', text: event.text });
  }
};

export const reduceEvents = (raws: unknown[]): Timeline => {
  const timeline: Timeline = { iterations: [], orphans: [] };
  const frame: Frame = {
    byProcess: new Map(),
    byCodex: new Map(),
    codexStack: [],
    orphans: timeline.orphans
  };

  for (const raw of raws) {
    const parsed = parseEvent(raw);
    if (!parsed) continue;
    if (parsed.tag === 'known') {
      applyKnown(timeline, frame, parsed.event);
    } else if (parsed.tag === 'codex') {
      applyCodex(frame, parsed.event);
    } else {
      const ts = parsed.event.ts_ms;
      const kind = parsed.event.kind;
      const run = newRun(`event:${kind}:${ts}`, kind, ts);
      closeRun(run, ts, 'done');
      containerFor(frame).push(run);
    }
  }

  return timeline;
};
