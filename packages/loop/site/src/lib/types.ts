export type Status = 'running' | 'done' | 'failed';

export type LogLine = {
  ts: number;
  stream: 'stdout' | 'stderr';
  text: string;
};

export type Run = {
  id: string;
  label: string;
  detail?: string;
  startedAt: number;
  finishedAt?: number;
  status: Status;
  exitCode?: number;
  logs: LogLine[];
  children: Run[];
};

export type Iteration = {
  n: number;
  startedAt: number;
  finishedAt?: number;
  status: Status;
  outcome?: 'pushed' | 'clean';
  pathCount?: number;
  runs: Run[];
};

export type Timeline = {
  serverUrl?: string;
  iterations: Iteration[];
  /** Runs that arrived outside any iteration. */
  orphans: Run[];
};
