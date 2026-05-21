import { z } from 'zod';

const base = z.object({
  ts_ms: z.number(),
  kind: z.string()
});

const serverEvent = base.extend({
  kind: z.literal('server'),
  url: z.string().optional(),
  mode: z.string().optional()
});

const iterationStart = base.extend({
  kind: z.literal('iteration-start'),
  iteration: z.number().optional()
});

const iterationClean = base.extend({
  kind: z.literal('iteration-clean'),
  iteration: z.number().optional()
});

const pushed = base.extend({
  kind: z.literal('pushed'),
  iteration: z.number().optional(),
  path_count: z.number().optional()
});

const processStart = base.extend({
  kind: z.literal('process-start'),
  name: z.string().optional(),
  program: z.string().optional(),
  args: z.array(z.string()).optional()
});

const processFinish = base.extend({
  kind: z.literal('process-finish'),
  name: z.string().optional(),
  exit_code: z.number().optional()
});

const nodeStart = base.extend({
  kind: z.literal('node-start'),
  node: z.string().optional()
});

const nodeFinish = base.extend({
  kind: z.literal('node-finish'),
  node: z.string().optional(),
  exit_code: z.number().optional()
});

const line = base.extend({
  kind: z.literal('line'),
  name: z.string().optional(),
  stream: z.enum(['stdout', 'stderr']).default('stdout'),
  text: z.string().optional()
});

const healthChecksComplete = base.extend({
  kind: z.literal('health-checks-complete'),
  exit_code: z.number().optional()
});

const codexNested: z.ZodType<CodexPayload> = z.lazy(() =>
  z
    .object({
      id: z.string().optional(),
      type: z.string().optional(),
      kind: z.string().optional(),
      text: z.string().optional(),
      message: z.string().optional(),
      content: z.string().optional(),
      item: codexNested.optional(),
      payload: codexNested.optional(),
      data: codexNested.optional()
    })
    .passthrough()
);

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

const codex = base.extend({
  kind: z.string().regex(/^codex-/),
  name: z.string().optional(),
  stream: z.string().optional(),
  text: z.string().optional(),
  event: codexNested.optional()
});

const fallback = base.passthrough();

export const eventSchema = z.union([
  serverEvent,
  iterationStart,
  iterationClean,
  pushed,
  processStart,
  processFinish,
  nodeStart,
  nodeFinish,
  line,
  healthChecksComplete,
  codex,
  fallback
]);

export type LoopEvent = z.infer<typeof eventSchema>;

export type ServerEvent = z.infer<typeof serverEvent>;
export type IterationStart = z.infer<typeof iterationStart>;
export type IterationClean = z.infer<typeof iterationClean>;
export type Pushed = z.infer<typeof pushed>;
export type ProcessStart = z.infer<typeof processStart>;
export type ProcessFinish = z.infer<typeof processFinish>;
export type NodeStart = z.infer<typeof nodeStart>;
export type NodeFinish = z.infer<typeof nodeFinish>;
export type LineEvent = z.infer<typeof line>;
export type CodexEvent = z.infer<typeof codex>;

/** Parse a raw event payload, falling back to a tolerant pass-through. */
export const parseEvent = (input: unknown): LoopEvent | null => {
  const result = eventSchema.safeParse(input);
  return result.success ? result.data : null;
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
