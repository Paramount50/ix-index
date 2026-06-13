import { IX_LLM_MIME, type Job, type LlmView, type RichOutput } from './types';

// Format a duration as a compact, minimal string. Sub-second runs read as no
// time at all (the dominant case, and noise on a finished card); otherwise a
// single whole unit, no decimals.
export function duration(seconds: number): string {
  if (seconds < 1) return '';
  if (seconds < 60) return `${Math.round(seconds)}s`;
  const m = Math.floor(seconds / 60);
  const s = Math.floor(seconds % 60);
  if (m < 60) return `${m}m ${s}s`;
  const h = Math.floor(m / 60);
  return `${h}h ${m % 60}m`;
}

// A card title for a run: only a caller-supplied `name`. With the source shown
// highlighted on the card, echoing its first line as a title read as noise, so
// an unnamed run stays untitled.
export function jobTitle(name: string, id: string): string {
  return name && name !== id ? name : '';
}

// A rough token count for a string. We have no model tokenizer in the browser
// (and the exact Anthropic vocabulary is not public), so estimate at the usual
// ~4 chars/token rule of thumb. It is an indicator, not a billing figure: good
// enough to compare calls and spot a result that blew up the context.
export function estimateTokens(text: string): number {
  return text ? Math.ceil(text.length / 4) : 0;
}

// A token count as a compact label: bare under 1k, one-decimal "k" up to 10k,
// rounded "k"/"M" above. Mirrors the terse, tabular feel of the duration chip.
export function tokens(n: number): string {
  if (n < 1000) return String(n);
  if (n < 10_000) return `${(n / 1000).toFixed(1).replace(/\.0$/, '')}k`;
  if (n < 1_000_000) return `${Math.round(n / 1000)}k`;
  return `${(n / 1_000_000).toFixed(1).replace(/\.0$/, '')}M`;
}

// The exact text one rich output handed the MODEL, mirroring server-side
// outputs.to_mcp: a Result's IX_LLM view text, else the bundle's text/plain,
// else the placeholder the model gets for an HTML-only table. Empty for a pure
// image. Kept in sync with RichOutput.svelte's `llm` derivation.
function outputModelText(output: RichOutput): string {
  const data = output.data ?? {};
  const encoded = data[IX_LLM_MIME];
  if (encoded) {
    try {
      const parsed = JSON.parse(encoded) as LlmView;
      if (typeof parsed.text === 'string') return parsed.text;
    } catch {
      // Malformed view: fall through to the plain-text representation below.
    }
  }
  if (data['text/plain']) return data['text/plain'];
  if (data['text/html'] && !data['image/png']) return '[HTML output; see the dashboard]';
  return '';
}

// Estimated input/output token counts for one tool call, with the underlying
// char counts for the hover detail. Input is the `code` argument. Output is what
// the model actually read back: the rich outputs' model text, falling back to
// the result/stdout copy when a run produced no rich block, plus any error. The
// `output`/`result` columns duplicate the rich text/plain, so we pick one
// representation rather than summing the three.
export function jobTokens(job: Job): {
  inTok: number;
  outTok: number;
  inChars: number;
  outChars: number;
} {
  let out = job.outputs.map(outputModelText).filter(Boolean).join('\n');
  if (!out) out = job.result ?? job.output ?? '';
  if (job.error) out += (out ? '\n' : '') + job.error;
  return {
    inTok: estimateTokens(job.code),
    outTok: estimateTokens(out),
    inChars: job.code.length,
    outChars: out.length,
  };
}
