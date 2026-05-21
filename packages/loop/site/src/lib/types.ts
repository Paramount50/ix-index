export type CommandStatus = 'running' | 'done' | 'failed';

export type CommandCategory = 'shell' | 'message' | 'reasoning' | 'patch' | 'tool' | 'event';

export type Command = {
  text: string;
  startedAt: number;
  finishedAt?: number;
  status: CommandStatus;
  exitCode?: number;
  tail?: string;
  category: CommandCategory;
};

export type State = {
  connected: boolean;
  serverUrl?: string;
  iteration?: number;
  iterationStartedAt?: number;
  iterationFinishedAt?: number;
  outcome?: 'pushed' | 'clean' | 'running';
  pathCount?: number;
  current?: Command;
  history: Command[];
};
