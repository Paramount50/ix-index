export type SiteUpdateLink = {
  label: string;
  href: string;
};

export type SiteUpdate = {
  id: string;
  date: string;
  title: string;
  summary: string;
  paragraphs: string[];
  links: SiteUpdateLink[];
};

export const siteUpdates: SiteUpdate[] = [
  {
    id: 'site-audio-briefs',
    date: '2026-05-23',
    title: 'Audio briefs land on the site',
    summary:
      'The ix images site now has bite-size update entries and a browser-read audio brief.',
    paragraphs: [
      'Public project notes now live as compact updates with exact repo links close to the text they explain.',
      'The audio controls use browser speech synthesis, so GitHub Pages can keep serving static files while each reader picks an available voice from their device.',
      'The full brief button queues the update feed as one listenable pass for anyone checking the project between tasks.'
    ],
    links: [
      {
        label: 'site source',
        href: 'https://github.com/indexable-inc/index/tree/main/site'
      },
      {
        label: 'contributor note',
        href: 'https://github.com/indexable-inc/index/blob/main/AGENTS.md#site-updates'
      }
    ]
  }
];

export const siteIntro =
  'ix images publishes pre-built OCI images and composable NixOS modules for ix VMs.';

export function updateScript(update: SiteUpdate): string {
  return [update.title, update.summary, ...update.paragraphs].join(' ');
}

export function feedScript(updates: SiteUpdate[]): string {
  const entries = updates.map((update, index) =>
    [
      `Update ${String(index + 1)}. ${update.date}.`,
      updateScript(update)
    ].join(' ')
  );

  return ['ix images update brief.', siteIntro, ...entries].join(' ');
}
