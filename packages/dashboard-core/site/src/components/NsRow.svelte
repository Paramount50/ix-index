<script lang="ts">
  // One namespace row, rendered recursively: a container (dict/list/object) shows a
  // caret and expands its `children` inline, each child the same row one level
  // deeper. Leaves have no caret. Open state is local, so expanding one branch
  // never disturbs another.
  import { fmtSize, detail, type NsRow as Row } from '$lib/namespace';
  import { focusPane } from '$lib/ui.svelte';
  import { SCOPE_SEP } from '$lib/stream.svelte';
  import KindIcon from './KindIcon.svelte';
  // Svelte 5 expresses recursion by importing the component itself rather than the
  // old <svelte:self>.
  import Self from './NsRow.svelte';

  // `scope` is the namespace pane's producer scope, threaded down so a reference
  // chip can build the target exec pane's key (`scope<0x1f>runId`) and focus it.
  let { row, depth = 0, scope = '' }: { row: Row; depth?: number; scope?: string } = $props();

  const hasChildren = $derived(!!row.children && row.children.length > 0);
  // References live only on top-level rows; show them when present.
  const assignedIn = $derived(row.assigned_in ?? []);
  const usedIn = $derived(row.used_in ?? []);
  const hasRefs = $derived(assignedIn.length > 0 || usedIn.length > 0);
  let open = $state(false);

  function toggle(): void {
    if (hasChildren) open = !open;
  }

  // Jump to the run behind a reference: focus its exec pane. The exec pane's id is
  // the run id, sharing this producer's scope, so the key is `scope<0x1f>runId`.
  function goToRun(runId: string): void {
    focusPane(scope + SCOPE_SEP + runId);
  }
</script>

<div class="nsrow">
  <button
    class="nsrow-line"
    class:has-children={hasChildren}
    style="padding-left: {12 + depth * 15}px"
    onclick={toggle}
    aria-expanded={hasChildren ? open : undefined}
  >
    <span class="nsrow-caret" class:open class:hidden={!hasChildren}>›</span>
    <KindIcon kind={row.kind} />
    <span class="nsrow-name" title={row.type}>{row.name}</span>
    <span class="nsrow-detail" title={detail(row)}>{detail(row)}</span>
    <span class="nsrow-size">{fmtSize(row.size)}</span>
  </button>

  {#if hasRefs}
    <!-- Provenance: the runs that set or used this variable, each a chip that
         focuses the run's pane. Indented to sit under the name column. -->
    <div class="nsrow-refs" style="padding-left: {62 + depth * 15}px">
      {#if assignedIn.length > 0}
        <span class="nsrow-reflabel">set</span>
        {#each assignedIn as id (id)}
          <button class="nsrow-ref" title={`assigned in run ${id}`} onclick={() => goToRun(id)}
            >{id}</button
          >
        {/each}
      {/if}
      {#if usedIn.length > 0}
        <span class="nsrow-reflabel">used</span>
        {#each usedIn as id (id)}
          <button class="nsrow-ref" title={`used in run ${id}`} onclick={() => goToRun(id)}
            >{id}</button
          >
        {/each}
      {/if}
    </div>
  {/if}

  {#if open && row.children}
    {#each row.children as child, i (child.name + ':' + i)}
      <Self row={child} depth={depth + 1} {scope} />
    {/each}
  {/if}
</div>

<style>
  .nsrow-line {
    display: grid;
    grid-template-columns: 14px 16px minmax(0, auto) minmax(0, 1fr) auto;
    align-items: center;
    column-gap: 10px;
    width: 100%;
    padding: 5px 12px;
    font: inherit;
    font-family: var(--mono);
    font-size: 12px;
    text-align: left;
    color: var(--ink);
    background: none;
    border: 0;
    border-radius: 7px;
    cursor: default;
    transition: background 0.12s ease;
  }
  .nsrow-line.has-children {
    cursor: pointer;
  }
  .nsrow-line.has-children:hover {
    background: var(--panel);
  }
  /* The caret: a quiet chevron that rotates open. Hidden (but space-preserving) on
     leaves so every row's chip/name column stays aligned. */
  .nsrow-caret {
    justify-self: center;
    color: var(--ink-faint);
    transition: transform 0.12s ease;
    transform: rotate(0deg);
    user-select: none;
  }
  .nsrow-caret.open {
    transform: rotate(90deg);
  }
  .nsrow-caret.hidden {
    visibility: hidden;
  }
  .nsrow-name {
    min-width: 0;
    color: var(--ink);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .nsrow-detail {
    min-width: 0;
    color: var(--ink-faint);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .nsrow-size {
    text-align: right;
    color: var(--ink-dim);
    font-variant-numeric: tabular-nums;
    white-space: nowrap;
  }
  /* The references line under a variable: small chips for the runs that set/used it,
     wrapping rather than overflowing. */
  .nsrow-refs {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 4px;
    padding-right: 12px;
    padding-bottom: 4px;
    font-family: var(--mono);
    font-size: 10px;
  }
  .nsrow-reflabel {
    color: var(--ink-faint);
    text-transform: uppercase;
    letter-spacing: 0.08em;
    margin-right: 1px;
  }
  /* A run id chip: a quiet monospace pill that brightens on hover, clicked to focus
     the run's pane. */
  .nsrow-ref {
    font: inherit;
    color: var(--ink-dim);
    background: var(--panel);
    border: 0;
    border-radius: 5px;
    padding: 1px 5px;
    cursor: pointer;
    transition:
      background 0.12s ease,
      color 0.12s ease;
  }
  .nsrow-ref:hover {
    color: var(--ink);
    background: var(--panel-strong, var(--panel));
  }
</style>
