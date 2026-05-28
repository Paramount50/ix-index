/// WebTransport client for the live delta stream.
///
/// The server pushes a `reset` seed then incremental `Delta`s as msgpack frames
/// (a `u32` big-endian length prefix per frame) on one unidirectional stream. We
/// reframe, decode, validate, and fold them into a working model, projecting a
/// fresh `MonitorSnapshot` to the caller. There is deliberately no SSE or
/// WebSocket fallback: a browser without WebTransport reports an error.

import { decode } from '@msgpack/msgpack';
import * as v from 'valibot';
import {
  deltaSchema,
  EMPTY_SNAPSHOT,
  type ActivityNode,
  type BuildNode,
  type ConnectionStatus,
  type Delta,
  type DerivationEdge,
  type LogEntry,
  type MonitorSnapshot
} from '$lib/types';

type SnapshotHandler = (snapshot: MonitorSnapshot) => void;
type StatusHandler = (status: ConnectionStatus) => void;

const transportInfoSchema = v.object({
  port: v.number(),
  certHash: v.array(v.number())
});

/// Mirror the server's retention caps so a long run cannot grow these without
/// bound. The UI only renders the tail anyway; older entries fall off the head.
const LOG_RETAIN = 5_000;
const ERROR_RETAIN = 2_000;

/// Mutable accumulation of the snapshot, keyed for O(1) upserts. Kept private to
/// this module; callers only ever see the immutable projection.
type Working = {
  activities: Map<number, ActivityNode>;
  builds: Map<string, BuildNode>;
  logs: LogEntry[];
  errors: string[];
  progress: MonitorSnapshot['progress'];
  expected: Record<string, number>;
  dependencies: DerivationEdge[];
  exitCode: number | null;
  finished: boolean;
};

function createWorking(): Working {
  return {
    activities: new Map(),
    builds: new Map(),
    logs: [],
    errors: [],
    progress: null,
    expected: {},
    dependencies: [],
    exitCode: null,
    finished: false
  };
}

/// Fold one delta into the working model. A `reset` replaces everything; the
/// rest patch in place. `logsAppend` mirrors the server's per-build `logCount`
/// so the hot log path needs no `buildUpsert`.
export function applyDelta(working: Working, delta: Delta): Working {
  switch (delta.type) {
    case 'reset':
      return fromSnapshot(delta.snapshot);
    case 'buildUpsert':
      working.builds.set(delta.build.derivation, delta.build);
      return working;
    case 'activityUpsert':
      working.activities.set(delta.activity.id, delta.activity);
      return working;
    case 'logsAppend':
      for (const entry of delta.entries) {
        working.logs.push(entry);
        bumpLogCount(working, entry);
      }
      capHead(working.logs, LOG_RETAIN);
      return working;
    case 'progressSet':
      working.progress = delta.progress;
      return working;
    case 'expectedSet':
      working.expected = { ...working.expected, [delta.name]: delta.value };
      return working;
    case 'errorAppend':
      working.errors.push(delta.message);
      capHead(working.errors, ERROR_RETAIN);
      return working;
    case 'dependenciesSet':
      working.dependencies = delta.edges;
      return working;
    case 'finished':
      working.exitCode = delta.exitCode;
      working.finished = true;
      return working;
  }
}

function fromSnapshot(snapshot: MonitorSnapshot): Working {
  return {
    activities: new Map(snapshot.activities.map((activity) => [activity.id, activity])),
    builds: new Map(snapshot.builds.map((build) => [build.derivation, build])),
    logs: [...snapshot.logs],
    errors: [...snapshot.errors],
    progress: snapshot.progress,
    expected: { ...snapshot.expected },
    dependencies: snapshot.dependencies,
    exitCode: snapshot.exitCode,
    finished: snapshot.finished
  };
}

/// Match the server's `push_log`: a log line on a build's activity bumps that
/// build's `logCount`, independent of log retention so the count never regresses.
function bumpLogCount(working: Working, entry: LogEntry): void {
  if (entry.activityId === null) return;
  const activity = working.activities.get(entry.activityId);
  if (activity?.build == null) return;
  const build = working.builds.get(activity.build);
  if (build === undefined) return;
  working.builds.set(activity.build, { ...build, logCount: build.logCount + 1 });
}

function capHead(items: unknown[], max: number): void {
  if (items.length > max) items.splice(0, items.length - max);
}

/// Project the working model into a fresh immutable snapshot. Builds sort by
/// derivation and activities by id for a stable order; the UI applies its own
/// display ordering on top.
export function projectSnapshot(working: Working): MonitorSnapshot {
  return {
    activities: [...working.activities.values()].toSorted((a, b) => a.id - b.id),
    builds: [...working.builds.values()].toSorted((a, b) =>
      a.derivation.localeCompare(b.derivation)
    ),
    logs: [...working.logs],
    errors: [...working.errors],
    progress: working.progress,
    expected: { ...working.expected },
    dependencies: working.dependencies,
    exitCode: working.exitCode,
    finished: working.finished
  };
}

function decodeDelta(payload: Uint8Array): Delta | null {
  try {
    const result = v.safeParse(deltaSchema, decode(payload));
    return result.success ? result.output : null;
  } catch {
    return null;
  }
}

/// How long a session may be down before the indicator leaves `live`. A drop
/// the client reconnects through within this window never flickers the status,
/// which is what kept the old single-shot driver oscillating live/error on a
/// lossy link.
const GRACE_MS = 1_200;
/// Reconnect backoff bounds. The floor keeps a flapping session from busy-
/// looping; the ceiling keeps a hard-down endpoint from being hammered while
/// still recovering within a few seconds once it returns.
const BACKOFF_MIN_MS = 250;
const BACKOFF_MAX_MS = 5_000;

/// Open the WebTransport session and drive the snapshot/status callbacks until
/// the returned disposer is called or the monitored run finishes. A dropped
/// session reconnects with backoff; there is still no cross-protocol fallback.
export function openMonitorEvents(onSnapshot: SnapshotHandler, onStatus: StatusHandler): () => void {
  onStatus('connecting');

  if (typeof WebTransport === 'undefined') {
    onSnapshot(EMPTY_SNAPSHOT);
    onStatus('error');
    return () => {};
  }

  // Cancellation flips with the disposer from outside the async flow. Read
  // through `isAborted()` so the type-aware lint re-evaluates it at each
  // await-point instead of narrowing it to a constant after the first guard.
  const aborted = new AbortController();
  const isAborted = (): boolean => aborted.signal.aborted;
  let transport: WebTransport | null = null;
  // `live` once a session has ever come up: it picks the degraded label
  // (`reconnecting` vs the initial `error`) and is the signal that a drop is
  // transient rather than a cold start against a server that is not up yet.
  let everLive = false;
  let degradeTimer: ReturnType<typeof setTimeout> | null = null;

  // Hold the visible status on its pre-drop value until the link has been down
  // for `GRACE_MS`; only then surface the degraded label. A reconnect inside
  // the window cancels the timer, so brief blips stay invisible.
  const armDegrade = (): void => {
    if (degradeTimer !== null) return;
    degradeTimer = setTimeout(() => {
      degradeTimer = null;
      if (!isAborted()) onStatus(everLive ? 'reconnecting' : 'error');
    }, GRACE_MS);
  };
  const clearDegrade = (): void => {
    if (degradeTimer === null) return;
    clearTimeout(degradeTimer);
    degradeTimer = null;
  };

  void loop();

  async function loop(): Promise<void> {
    let attempt = 0;
    while (!isAborted()) {
      let finished = false;
      try {
        const info = await fetchTransportInfo();
        if (isAborted()) return;
        transport = new WebTransport(`https://${location.hostname}:${String(info.port)}/`, {
          serverCertificateHashes: [{ algorithm: 'sha-256', value: new Uint8Array(info.certHash) }]
        });
        await transport.ready;
        if (isAborted()) return;
        attempt = 0;
        everLive = true;
        clearDegrade();
        onStatus('live');
        finished = await consume(transport);
      } catch {
        // Fall through to the reconnect/degrade handling below.
      }
      if (isAborted()) return;
      transport?.close();
      transport = null;
      // A clean end carrying the `finished` delta means the run is over; stop.
      // Any other end (thrown, or stream closed mid-run) is treated as a drop.
      if (finished) {
        onStatus('closed');
        return;
      }
      armDegrade();
      attempt += 1;
      await delay(Math.min(BACKOFF_MAX_MS, BACKOFF_MIN_MS * 2 ** (attempt - 1)));
    }
  }

  /// Drain one session's delta stream into snapshots. Returns `true` when the
  /// stream ended on a `finished` delta (run complete) and `false` when it ended
  /// otherwise, which the caller treats as a drop to reconnect through.
  async function consume(wt: WebTransport): Promise<boolean> {
    // The DOM lib types incoming streams loosely; narrow to the byte stream we
    // know the server opens.
    const streams = wt.incomingUnidirectionalStreams.getReader();
    const result = await streams.read();
    if (result.done) return false;
    const stream = result.value as ReadableStream<Uint8Array>;

    const working = createWorking();
    let frameDue = false;
    // Coalesce bursts of deltas into one snapshot per frame. The terminal
    // snapshot is delivered either by the `finished` branch's explicit flush or
    // by the last scheduled frame, so no trailing flush is needed after the loop.
    const flush = (): void => {
      frameDue = false;
      if (!isAborted()) onSnapshot(projectSnapshot(working));
    };
    const schedule = (): void => {
      if (frameDue) return;
      frameDue = true;
      requestAnimationFrame(flush);
    };

    for await (const delta of frames(stream)) {
      if (isAborted()) break;
      applyDelta(working, delta);
      if (delta.type === 'finished') {
        flush();
        return true;
      }
      schedule();
    }
    return false;
  }

  /// Backoff sleep that resolves early when the disposer aborts, so teardown
  /// does not wait out a pending reconnect delay.
  function delay(ms: number): Promise<void> {
    return new Promise((resolve) => {
      const timer = setTimeout(resolve, ms);
      aborted.signal.addEventListener(
        'abort',
        () => {
          clearTimeout(timer);
          resolve();
        },
        { once: true }
      );
    });
  }

  /// Reassemble length-prefixed msgpack frames from the raw byte stream and
  /// yield each decoded, validated delta.
  async function* frames(stream: ReadableStream<Uint8Array>): AsyncGenerator<Delta> {
    const reader = stream.getReader();
    let buffer: Uint8Array = new Uint8Array(0);
    for (;;) {
      const { value, done } = await reader.read();
      if (done) return;
      buffer = concat(buffer, value);

      for (;;) {
        if (buffer.length < 4) break;
        const length = new DataView(buffer.buffer, buffer.byteOffset, 4).getUint32(0, false);
        if (buffer.length < 4 + length) break;
        const delta = decodeDelta(buffer.subarray(4, 4 + length));
        buffer = buffer.slice(4 + length);
        if (delta !== null) yield delta;
      }
    }
  }

  return () => {
    aborted.abort();
    clearDegrade();
    transport?.close();
  };
}

async function fetchTransportInfo(): Promise<v.InferOutput<typeof transportInfoSchema>> {
  const response = await fetch('/api/transport');
  if (!response.ok) throw new Error(`transport handshake failed: ${String(response.status)}`);
  return v.parse(transportInfoSchema, await response.json());
}

function concat(left: Uint8Array, right: Uint8Array): Uint8Array {
  if (left.length === 0) return right;
  const merged = new Uint8Array(left.length + right.length);
  merged.set(left);
  merged.set(right, left.length);
  return merged;
}
