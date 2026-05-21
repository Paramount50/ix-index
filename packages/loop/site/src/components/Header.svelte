<script lang="ts">
  let {
    connected,
    serverUrl,
    currentIteration
  }: {
    connected: boolean;
    serverUrl?: string;
    currentIteration?: number;
  } = $props();
</script>

<header>
  <div class="brand">
    <span class="dot" class:online={connected}></span>
    <h1>loop</h1>
    {#if currentIteration !== undefined}
      <span class="iter">#{currentIteration}</span>
    {/if}
  </div>
  {#if serverUrl}
    <a class="url" href={serverUrl}>{serverUrl.replace(/^https?:\/\//, '')}</a>
  {/if}
</header>

<style>
  header {
    display: flex;
    align-items: baseline;
    justify-content: space-between;
    gap: 16px;
    padding: 20px 0 12px;
  }

  .brand {
    display: flex;
    align-items: baseline;
    gap: 10px;
  }

  h1 {
    margin: 0;
    font-size: 18px;
    font-weight: 600;
    letter-spacing: 0.02em;
    color: #f4f4f5;
  }

  .iter {
    color: #71717a;
    font-variant-numeric: tabular-nums;
    font-size: 13px;
    letter-spacing: 0.04em;
  }

  .dot {
    width: 6px;
    height: 6px;
    border-radius: 999px;
    background: #52525b;
    align-self: center;
  }

  .dot.online {
    background: #4ade80;
    box-shadow: 0 0 8px rgba(74, 222, 128, 0.6);
  }

  .url {
    color: #52525b;
    font-size: 11.5px;
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    text-decoration: none;
    letter-spacing: 0.02em;
  }

  .url:hover {
    color: #a1a1aa;
  }
</style>
