const timeFormatter = new Intl.DateTimeFormat(undefined, {
  hour: '2-digit',
  minute: '2-digit',
  second: '2-digit'
});

export const formatClock = (ts: number) => timeFormatter.format(new Date(ts));

export const formatDuration = (ms: number): string => {
  if (ms < 0) return '0ms';
  if (ms < 1000) return `${Math.round(ms)}ms`;
  const seconds = ms / 1000;
  if (seconds < 60) return `${seconds < 10 ? seconds.toFixed(1) : Math.round(seconds)}s`;
  const minutes = Math.floor(seconds / 60);
  const rem = Math.round(seconds - minutes * 60);
  if (minutes < 60) return rem === 0 ? `${minutes}m` : `${minutes}m ${rem}s`;
  const hours = Math.floor(minutes / 60);
  const minRem = minutes - hours * 60;
  return minRem === 0 ? `${hours}h` : `${hours}h ${minRem}m`;
};
