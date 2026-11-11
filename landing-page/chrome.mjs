// Shared page chrome and the small data projections the static pages are
// rendered from. Pages stay plain HTML: each marker comment below is replaced
// at build time (build.mjs) and by the preview server (serve.ts), so every
// page's header, footer, clip markup and Stable display version come from here.
//
//   <!-- partial:NAME -->   a block from `partials`, at the marker's indentation
//   <!-- clip:NAME -->      the <video> for one entry in `clips`
//   <!-- stable:mac-version -->  the Stable Mac version shown beside its download
import { readFile } from 'node:fs/promises';

/**
 * Stable display identity. The Mac download buttons resolve GitHub Latest
 * through `_redirects`, which is always the newest published `mac-v*` tag, so
 * this must name that tag's version. Alpha builds never change it: publishing
 * Stable is the only step that does.
 */
export const stable = { mac: { version: '3.2.0', tag: 'mac-v3.2.0' } };

/** Narrated clips. Each ships light/dark WebM and MP4 variants and English captions. */
export const clips = {
  hero: {
    width: 1280, height: 720,
    label: 'Dictating into a text field on a Mac, then finding the text in History',
    fallback: 'Download the Mac demo clip (MP4)',
  },
  iphone: {
    width: 640, height: 1280,
    label: 'The iPhone app: tap record, see the words, copy them, then on-device and Action Button settings',
    fallback: 'Download the iPhone clip (MP4)',
  },
};

const webm = 'video/webm; codecs=&quot;av01.0.05M.08, opus&quot;';
const dark = ' media="(prefers-color-scheme: dark)"';
const icon = '/favicon.svg?v=20260909';
const copyright = '© 2026 Chris Mitchelmore · MIT licensed';

function brand(href, { label, size = 34 } = {}) {
  const name = label === undefined ? '' : ` aria-label="${label}"`;
  return `<a class="brand" href="${href}"${name}><img src="${icon}" width="${size}" height="${size}" alt="">`
    + '<span class="brand-wordmark">Just Speak to It</span></a>';
}

export function clipVideo(name) {
  const clip = clips[name];
  if (clip === undefined) throw new Error(`Unknown clip: ${name}`);
  const base = `/images/clips/${name}`;
  return [
    `<video class="clip-video" controls playsinline preload="none" width="${clip.width}" height="${clip.height}"`
      + ` data-clip="${name}" aria-label="${clip.label}" aria-describedby="clip-${name}-caption">`,
    `  <source src="${base}-dark.webm" type="${webm}"${dark}>`,
    `  <source src="${base}-light.webm" type="${webm}">`,
    `  <source src="${base}-dark.mp4" type="video/mp4"${dark}>`,
    `  <source src="${base}-light.mp4" type="video/mp4">`,
    `  <track kind="captions" src="${base}.en.vtt" srclang="en" label="English" default>`,
    `  <a href="${base}-light.mp4" data-clip-download="${name}">${clip.fallback}</a>`,
    '</video>',
  ].join('\n');
}

export const partials = {
  // The landing page header: in-page section links and the download CTA.
  'site-header': () => [
    '<header class="site-header wrap" id="top">',
    `  ${brand('#top', { label: 'Just Speak to It home' })}`,
    '  <nav class="site-nav" aria-label="Primary">',
    '    <a href="#how">How it works</a>',
    '    <a href="#own">Privacy</a>',
    '    <a href="#models">Models</a>',
    '    <a href="#mobile">iPhone &amp; iPad</a>',
    '    <a href="#automate">Automation</a>',
    '  </nav>',
    '  <a class="button button-small" href="#get">Download</a>',
    '</header>',
  ].join('\n'),
  'site-footer': () => [
    '<footer class="site-footer wrap">',
    '  <div class="footer-top">',
    '    <div>',
    `      ${brand('#top')}`,
    '      <p>Made by <a href="https://mitchelmore.uk">Chris Mitchelmore</a>, who also makes <a href="https://pasta-app.com">Pasta</a>.</p>',
    '    </div>',
    '    <nav class="footer-nav" aria-label="Footer">',
    '      <a href="https://github.com/crmitchelmore/justspeaktoit">GitHub</a>',
    '      <a href="https://github.com/crmitchelmore/justspeaktoit/releases">Releases</a>',
    '      <a href="/privacy">Privacy</a>',
    '      <a href="/support">Support</a>',
    '      <a href="https://mitchelmore.uk">Blog</a>',
    '      <a href="https://pasta-app.com">Pasta</a>',
    '    </nav>',
    '  </div>',
    '  <div class="footer-bottom">',
    `    <span>${copyright}</span>`,
    '    <a href="#top">Back to top ↑</a>',
    '  </div>',
    '</footer>',
  ].join('\n'),
  // Privacy and support: one reading column with a way back to the site.
  'document-style': async () => readFile(new URL('partials/document.css', import.meta.url), 'utf8'),
  'document-header': () => [
    '<a class="skip-link" href="#main">Skip to content</a>',
    '<nav class="nav" aria-label="Primary navigation">',
    '  <div class="nav__inner">',
    `    ${brand('/', { size: 32 })}`,
    '    <a class="back" href="/">Back to the app</a>',
    '  </div>',
    '</nav>',
  ].join('\n'),
  'document-footer': () =>
    `<footer><p>${copyright} · <a href="/">Home</a> · <a href="/privacy">Privacy policy</a> · <a href="/support">Support</a></p></footer>`,
};

function indent(block, prefix) {
  return block.split('\n').map(line => (line === '' ? line : prefix + line)).join('\n');
}

/** Replaces every marker in `html`. Unknown markers throw rather than ship. */
export async function renderMarkup(html) {
  let output = html;
  for (const [line, prefix, kind, name] of html.matchAll(/^([ \t]*)<!-- (partial|clip):([a-z-]+) -->$/gm)) {
    let block;
    if (kind === 'clip') {
      block = clipVideo(name);
    } else {
      if (!Object.hasOwn(partials, name)) throw new Error(`Unknown partial: ${name}`);
      block = await partials[name]();
    }
    output = output.replace(line, () => indent(block.replace(/\n$/, ''), prefix));
  }
  output = output.replaceAll('<!-- stable:mac-version -->', stable.mac.version);
  const leftover = output.match(/<!-- (partial|clip|stable):[^>]* -->/);
  if (leftover) throw new Error(`Unrendered marker: ${leftover[0]}`);
  return output;
}

/** The published pages that are rendered from markers. */
export const pages = ['index.html', 'privacy.html', 'support.html'];

/** Reads one source page from this directory and renders it. */
export async function renderPage(name) {
  return renderMarkup(await readFile(new URL(name, import.meta.url), 'utf8'));
}
