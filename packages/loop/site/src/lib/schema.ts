import { z } from 'zod';

const base = z.object({
  ts_ms: z.number(),
  kind: z.string()
});

const serverEvent = z.object({
  ts_ms: z.number(),
  kind: z.literal('server'),
  url: z.string().optional(),
  mode: z.string().optional()
});

const iterationStart = z.object({
  ts_ms: z.number(),
  kind: z.literal('iteration-start'),
  iteration: z.number().optional()
});

const iterationClean = z.object({
  ts_ms: z.number(),
  kind: z.literal('iteration-clean'),
  iteration: z.number().optional()
});

const pushed = z.object({
  ts_ms: z.number(),
  kind: z.literal('pushed'),
  iteration: z.number().optional(),
  path_count: z.number().optional()
});

const processStart = z.object({
  ts_ms: z.number(),
  kind: z.literal('process-start'),
  name: z.string().optional(),
  program: z.string().optional(),
  args: z.array(z.string()).optional()
});

const processFinish = z.object({
  ts_ms: z.number(),
  kind: z.literal('process-finish'),
  name: z.string().optional(),
  exit_code: z.number().optional()
});

const nodeStart = z.object({
  ts_ms: z.number(),
  kind: z.literal('node-start'),
  node: z.string().optional()
});

const nodeFinish = z.object({
  ts_ms: z.number(),
  kind: z.literal('node-finish'),
  node: z.string().optional(),
  exit_code: z.number().optional()
});

const line = z.object({
  ts_ms: z.number(),
  kind: z.literal('line'),
  name: z.string().optional(),
  stream: z.enum(['stdout', 'stderr']).default('stdout'),
  text: z.string().optional()
});

const healthChecksComplete = z.object({
  ts_ms: z.number(),
  kind: z.literal('health-checks-complete'),
  exit_code: z.number().optional()
});

const knownEvent = z.discriminatedUnion('kind', [
  serverEvent,
  iterationStart,
  iterationClean,
  pushed,
  processStart,
  processFinish,
  nodeStart,
  nodeFinish,
  line,
  healthChecksComplete
]);

export type CodexPayload = {
  id?: string;
  type?: string;
  kind?: string;
  text?: string;
  message?: string;
  content?: string;
  item?: CodexPayload;
  payload?: CodexPayload;
  data?: CodexPayload;
  [key: string]: unknown;
};

const codexPayload: z.ZodType<CodexPayload> = z.lazy(() =>
  z
    .object({
      id: z.string().optional(),
      type: z.string().optional(),
      kind: z.string().optional(),
      text: z.string().optional(),
      message: z.string().optional(),
      content: z.string().optional(),
      item: codexPayload.optional(),
      payload: codexPayload.optional(),
      data: codexPayload.optional()
    })
    .passthrough()
);

const codexCategory = z.enum(['shell', 'message', 'reasoning', 'patch', 'tool', 'event']);

const codexEvent = z.object({
  ts_ms: z.number(),
  kind: z.string(),
  name: z.string().optional(),
  stream: z.string().optional(),
  category: codexCategory.optional(),
  text: z.string().optional(),
  event: codexPayload.optional()
});

const fallbackEvent = base.passthrough();

export type KnownEvent = z.infer<typeof knownEvent>;
export type CodexEvent = z.infer<typeof codexEvent>;
export type FallbackEvent = z.infer<typeof fallbackEvent>;

export type ParsedEvent =
  | { tag: 'known'; event: KnownEvent }
  | { tag: 'codex'; event: CodexEvent }
  | { tag: 'fallback'; event: FallbackEvent };

export const parseEvent = (input: unknown): ParsedEvent | null => {
  const head = base.safeParse(input);
  if (!head.success) return null;
  if (head.data.kind.startsWith('codex-')) {
    const parsed = codexEvent.safeParse(input);
    return parsed.success ? { tag: 'codex', event: parsed.data } : null;
  }
  const known = knownEvent.safeParse(input);
  if (known.success) return { tag: 'known', event: known.data };
  const fallback = fallbackEvent.safeParse(input);
  return fallback.success ? { tag: 'fallback', event: fallback.data } : null;
};

const stateSchema = z.object({
  snapshot: z.string(),
  lines: z.array(z.string()).default([])
});

export type ApiState = z.infer<typeof stateSchema>;

export const parseApiState = (input: unknown): ApiState => stateSchema.parse(input);

const snapshotSchema = z.object({
  events: z.array(z.unknown()).default([])
});

export const parseSnapshot = (input: unknown): unknown[] =>
  snapshotSchema.parse(input).events;
