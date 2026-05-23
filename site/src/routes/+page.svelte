<script lang="ts">
  import { resolve } from '$app/paths';
  import { onMount } from 'svelte';
  import { feedScript, siteFeedUrl, siteIntro, siteUpdates, updateScript } from '$lib/updates';

  type SpeechState = 'loading' | 'idle' | 'speaking' | 'paused' | 'unsupported' | 'error';

  const dateFormatter = new Intl.DateTimeFormat('en', {
    month: 'short',
    day: 'numeric',
    year: 'numeric',
    timeZone: 'UTC'
  });

  const feedHref = resolve('/feed.xml');
  const latestUpdate = siteUpdates[0];

  let selectedId = $state(latestUpdate.id);
  let voices = $state<SpeechSynthesisVoice[]>([]);
  let selectedVoiceUri = $state('');
  let speechState = $state<SpeechState>('loading');
  let activeTitle = $state('');
  let statusText = $state('Audio controls load after the page opens.');
  let speechRun = 0;

  const selectedUpdate = $derived(
    siteUpdates.find((update) => update.id === selectedId) ?? latestUpdate
  );
  const selectedVoice = $derived(
    voices.find((voice) => voice.voiceURI === selectedVoiceUri) ?? null
  );
  const canSpeak = $derived(speechState !== 'loading' && speechState !== 'unsupported');
  const canPause = $derived(speechState === 'speaking');
  const canResume = $derived(speechState === 'paused');

  function formatDate(date: string): string {
    return dateFormatter.format(new Date(`${date}T00:00:00Z`));
  }

  function syncVoices(): void {
    const nextVoices = window.speechSynthesis.getVoices();
    voices = nextVoices;

    if (selectedVoiceUri !== '' || nextVoices.length === 0) {
      return;
    }

    const preferredVoice =
      nextVoices.find((voice) => voice.lang.toLowerCase().startsWith('en-us')) ??
      nextVoices.find((voice) => voice.lang.toLowerCase().startsWith('en')) ??
      nextVoices[0];

    selectedVoiceUri = preferredVoice.voiceURI;
  }

  function speak(title: string, text: string): void {
    if (!canSpeak) {
      statusText = 'This browser does not expose speech synthesis here.';
      return;
    }

    const run = speechRun + 1;
    speechRun = run;

    window.speechSynthesis.cancel();
    window.speechSynthesis.resume();

    const utterance = new SpeechSynthesisUtterance(text);
    utterance.rate = 0.96;
    utterance.pitch = 1;

    if (selectedVoice !== null) {
      utterance.voice = selectedVoice;
    }

    utterance.onstart = () => {
      if (speechRun !== run) {
        return;
      }

      activeTitle = title;
      speechState = 'speaking';
      statusText = `Reading ${title}.`;
    };

    utterance.onend = () => {
      if (speechRun !== run) {
        return;
      }

      activeTitle = '';
      speechState = 'idle';
      statusText = 'Finished reading.';
    };

    utterance.onerror = () => {
      if (speechRun !== run) {
        return;
      }

      activeTitle = '';
      speechState = 'error';
      statusText = 'The browser stopped audio playback. Try the brief again.';
    };

    window.speechSynthesis.speak(utterance);
  }

  function readSelected(): void {
    speak(selectedUpdate.title, updateScript(selectedUpdate));
  }

  function readFeed(): void {
    speak('latest ix images updates', feedScript(siteUpdates));
  }

  function pauseSpeech(): void {
    if (!canPause) {
      return;
    }

    window.speechSynthesis.pause();
    speechState = 'paused';
    statusText = `Paused ${activeTitle}.`;
  }

  function resumeSpeech(): void {
    if (!canResume) {
      return;
    }

    window.speechSynthesis.resume();
    speechState = 'speaking';
    statusText = `Reading ${activeTitle}.`;
  }

  function stopSpeech(): void {
    if (!canSpeak) {
      return;
    }

    speechRun += 1;
    window.speechSynthesis.cancel();
    activeTitle = '';
    speechState = 'idle';
    statusText = 'Stopped.';
  }

  onMount(() => {
    if (!('speechSynthesis' in window) || !('SpeechSynthesisUtterance' in window)) {
      speechState = 'unsupported';
      statusText = 'This browser does not expose speech synthesis here.';
      return;
    }

    speechState = 'idle';
    statusText = 'Ready to read.';
    syncVoices();
    window.speechSynthesis.addEventListener('voiceschanged', syncVoices);

    return () => {
      window.speechSynthesis.removeEventListener('voiceschanged', syncVoices);
      window.speechSynthesis.cancel();
    };
  });
</script>

<svelte:head>
  <title>ix images</title>
  <meta
    name="description"
    content="Pre-built OCI images and composable NixOS modules for ix VMs, with browser-read project updates."
  />
  <link rel="alternate" type="application/rss+xml" title="ix images updates" href={siteFeedUrl} />
</svelte:head>

<main>
  <section class="hero" aria-labelledby="hero-title">
    <p class="eyebrow">ix images</p>
    <h1 id="hero-title">ix images</h1>
    <p class="lede">
      {siteIntro} The update feed below keeps public changes short enough to scan
      and hear between tasks.
    </p>
    <div class="hero-links" aria-label="Primary links">
      <a href="https://github.com/indexable-inc/index">Repository</a>
      <a href="https://ix.dev">ix VMs</a>
      <a href={feedHref}>RSS feed</a>
    </div>
  </section>

  <section class="audio-panel" aria-labelledby="audio-title">
    <div class="panel-heading">
      <div>
        <p class="eyebrow">Audio brief</p>
        <h2 id="audio-title">Listen to the feed</h2>
      </div>
      <div class="signal" aria-hidden="true">
        <span></span>
        <span></span>
        <span></span>
        <span></span>
      </div>
    </div>

    <p class="status" aria-live="polite">{statusText}</p>

    <div class="controls" aria-label="Audio controls">
      <button type="button" onclick={readSelected} disabled={!canSpeak}>Read selected</button>
      <button type="button" onclick={readFeed} disabled={!canSpeak}>Play full brief</button>
      <button type="button" onclick={pauseSpeech} disabled={!canPause}>Pause</button>
      <button type="button" onclick={resumeSpeech} disabled={!canResume}>Resume</button>
      <button type="button" onclick={stopSpeech} disabled={!canSpeak}>Stop</button>
    </div>

    <label for="voice">Voice</label>
    <select id="voice" bind:value={selectedVoiceUri} disabled={voices.length === 0}>
      {#if voices.length === 0}
        <option value="">Browser default</option>
      {:else}
        {#each voices as voice (voice.voiceURI)}
          <option value={voice.voiceURI}>
            {voice.name} ({voice.lang}{voice.localService ? ', local' : ', network'})
          </option>
        {/each}
      {/if}
    </select>

    <p class="note">
      GitHub Pages ships the text. Your browser renders the voice through the
      <a href="https://developer.mozilla.org/docs/Web/API/SpeechSynthesis">Web Speech API</a>.
    </p>
  </section>

  <section id={selectedUpdate.id} class="updates" aria-labelledby="updates-title">
    <div class="section-heading">
      <p class="eyebrow">News</p>
      <h2 id="updates-title">Small update entries</h2>
    </div>

    <div class="update-grid">
      <div class="update-picker" aria-label="Update list">
        {#each siteUpdates as update (update.id)}
          <button
            type="button"
            class:selected={update.id === selectedId}
            aria-pressed={update.id === selectedId}
            onclick={() => {
              selectedId = update.id;
            }}
          >
            <time datetime={update.date}>{formatDate(update.date)}</time>
            <span>{update.title}</span>
            <small>{update.summary}</small>
          </button>
        {/each}
      </div>

      <article class="update-copy" aria-labelledby="selected-update-title">
        <time datetime={selectedUpdate.date}>{formatDate(selectedUpdate.date)}</time>
        <h3 id="selected-update-title">{selectedUpdate.title}</h3>
        <p>{selectedUpdate.summary}</p>
        {#each selectedUpdate.paragraphs as paragraph (paragraph)}
          <p>{paragraph}</p>
        {/each}
        <div class="link-row" aria-label="Update links">
          {#each selectedUpdate.links as link (link.href)}
            <a href={link.href} rel="external">{link.label}</a>
          {/each}
        </div>
      </article>
    </div>
  </section>

  <section class="repository" aria-labelledby="repository-title">
    <h2 id="repository-title">Repository</h2>
    <p>
      Source lives at
      <a href="https://github.com/indexable-inc/index">github.com/indexable-inc/index</a>.
      Images are auto-discovered from <code>images/</code>; modules live under
      <code>modules/services/</code>.
    </p>
  </section>
</main>
