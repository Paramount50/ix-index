import vmConfig from './vm-config.json';

export type Status = 'connecting' | 'live' | 'waiting';

export type UsageStats = {
  generatedAt: string | null;
  cpu: { usedCores: number; totalCores: number; percent: number };
  memory: { usedBytes: number; totalBytes: number; percent: number };
  disk: { usedBytes: number; totalBytes: number; percent: number };
  costPerSecondUsd: number;
};

// vm-config.json is the single source of truth shared with default.nix's
// Nushell stats writer. Edit values there; never inline a constant here.
export const SERVER = vmConfig.server;
export const BILLING = vmConfig.billing;

export const FALLBACK_STATS: UsageStats = {
  generatedAt: null,
  cpu: { usedCores: 0, totalCores: SERVER.vcpu, percent: 0 },
  memory: { usedBytes: 0, totalBytes: SERVER.memoryGiB * 1024 ** 3, percent: 0 },
  disk: { usedBytes: 0, totalBytes: SERVER.storageTiB * 1024 ** 4, percent: 0 },
  costPerSecondUsd: 0
};

export function parseUsageStats(value: unknown): UsageStats | null {
  if (!isRecord(value)) return null;
  if (!(typeof value.generatedAt === 'string' || value.generatedAt === null)) return null;
  if (!isNumber(value.costPerSecondUsd)) return null;

  const cpu = parseCpuStats(value.cpu);
  const memory = parseByteStats(value.memory);
  const disk = parseByteStats(value.disk);
  if (cpu === null || memory === null || disk === null) return null;

  return {
    generatedAt: value.generatedAt,
    cpu,
    memory,
    disk,
    costPerSecondUsd: value.costPerSecondUsd
  };
}

function parseCpuStats(value: unknown): UsageStats['cpu'] | null {
  if (!isRecord(value)) return null;
  if (!isNumber(value.usedCores) || !isNumber(value.totalCores) || !isNumber(value.percent)) {
    return null;
  }
  return {
    usedCores: value.usedCores,
    totalCores: value.totalCores,
    percent: value.percent
  };
}

function parseByteStats(value: unknown): UsageStats['memory'] | null {
  if (!isRecord(value)) return null;
  if (!isNumber(value.usedBytes) || !isNumber(value.totalBytes) || !isNumber(value.percent)) {
    return null;
  }
  return {
    usedBytes: value.usedBytes,
    totalBytes: value.totalBytes,
    percent: value.percent
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

function isNumber(value: unknown): value is number {
  return typeof value === 'number' && Number.isFinite(value);
}
