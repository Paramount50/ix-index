<script lang="ts">
  import type { Status } from '../lib/types';

  let { status }: { status: Status } = $props();
</script>

<span class="dot {status}" aria-label={status}></span>

<style>
  .dot {
    --c: #6c6c70;
    display: inline-block;
    width: 7px;
    height: 7px;
    border-radius: 999px;
    background: var(--c);
    box-shadow: 0 0 0 0 var(--c);
    flex: none;
  }

  .dot.done {
    --c: #4ade80;
  }

  .dot.failed {
    --c: #f87171;
  }

  .dot.running {
    --c: #fbbf24;
    animation: pulse 1.6s ease-in-out infinite;
  }

  @keyframes pulse {
    0%,
    100% {
      box-shadow: 0 0 0 0 color-mix(in srgb, var(--c) 60%, transparent);
    }
    50% {
      box-shadow: 0 0 0 6px color-mix(in srgb, var(--c) 0%, transparent);
    }
  }
</style>
