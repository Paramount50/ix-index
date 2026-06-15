// Shared helpers for the namespace browser: the row shape the kernel publishes
// (`introspect.namespace_rows`), and the formatting both the inline body and the
// full rail view use, so there is one implementation of "how a variable reads".

// One variable (or, recursively, one member of a container). `children` is present
// only for expandable containers (dict/list/object), depth- and breadth-bounded by
// the producer; a single trailing `+N more` elision row may appear among them.
export interface NsRow {
  name: string;
  type: string;
  kind: string;
  repr: string;
  size: number;
  shape: string;
  children?: NsRow[];
  // Run ids that bound (`assigned_in`) or referenced (`used_in`) this variable,
  // most-recent-last, present only on top-level rows (provenance is a property of a
  // variable, not of a container's members). Each id is an exec pane's id, so the
  // view can link a name back to the runs behind it.
  assigned_in?: string[];
  used_in?: string[];
}

// Human byte size; empty for the sizeless (modules, functions report 0).
export function fmtSize(n: number): string {
  if (!n) return '';
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(n < 10 * 1024 ? 1 : 0)} KB`;
  if (n < 1024 * 1024 * 1024) return `${(n / (1024 * 1024)).toFixed(1)} MB`;
  return `${(n / (1024 * 1024 * 1024)).toFixed(1)} GB`;
}

// The middle column: a frame/array describes itself by shape; everything else
// shows its repr, falling back to a shape (a container's length).
export function detail(row: NsRow): string {
  if (row.shape && (row.kind === 'frame' || row.kind === 'array')) return row.shape;
  return row.repr || row.shape;
}

// The three top-level groups the view buckets names into, in display order.
export type NsGroup = 'Data' | 'Modules' | 'Functions';
export const NS_GROUPS: readonly NsGroup[] = ['Data', 'Modules', 'Functions'];

// Which group a row belongs to: modules and functions/classes are shared machinery,
// everything else is the data the session holds.
export function groupOf(row: NsRow): NsGroup {
  if (row.kind === 'module') return 'Modules';
  if (row.kind === 'function' || row.kind === 'class') return 'Functions';
  return 'Data';
}

// Parse a namespace pane's JSON body into rows; malformed/absent → none.
export function parseRows(body: string | undefined): NsRow[] {
  try {
    const parsed = JSON.parse(body ?? '[]');
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}
