// Static accessibility guards for every published page. Conventions: Docs/accessibility.md.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { renderPage } from './chrome.mjs';
import { loadCatalogue } from './qa/manual-checks.mjs';
import { renderQaPage } from './qa/render.mjs';
import { renderStylesheet } from './stylesheet.mjs';

const read = file => readFile(new URL(file, import.meta.url), 'utf8');
const pages = {
  'index.html': await renderPage('index.html'),
  'privacy.html': await renderPage('privacy.html'),
  'support.html': await renderPage('support.html'),
  'qa/index.html': renderQaPage(loadCatalogue(await read('../Docs/manual-checks.yml'))),
};
const stylesheets = {
  'site.css': await renderStylesheet(),
  'qa/qa.css': await read('qa/qa.css'),
  'privacy.html': pages['privacy.html'],
  'support.html': pages['support.html'],
};

const attribute = (tag, name) => tag.match(new RegExp(`\\s${name}\\s*=\\s*(?:"([^"]*)"|'([^']*)')`, 'i'))
  ?.slice(1).find(value => value !== undefined);
const hasAttribute = (tag, name) => new RegExp(`\\s${name}(\\s|=|>|/)`, 'i').test(tag);
const visibleText = html => html
  .replace(/<(script|style)\b[\s\S]*?<\/\1>/gi, '')
  .replace(/<[^>]*aria-hidden="true"[^>]*>[\s\S]*?<\/(span|svg|i)>/gi, '')
  .replace(/<img\b[^>]*>/gi, tag => ` ${attribute(tag, 'alt') ?? ''} `)
  .replace(/<[^>]+>/g, ' ')
  .replace(/&[a-z#0-9]+;/gi, 'x')
  .trim();
const elements = (html, name) => [...html.matchAll(new RegExp(`(<${name}\\b[^>]*>)([\\s\\S]*?)</${name}>`, 'gi'))]
  .map(([, open, body]) => ({ open, body }));
const ids = html => [...html.matchAll(/\sid="([^"]+)"/g)].map(match => match[1]);
const accessibleName = (open, body, html) => {
  if (attribute(open, 'aria-label')?.trim()) return true;
  const labelledBy = attribute(open, 'aria-labelledby');
  if (labelledBy) return labelledBy.split(/\s+/).every(id => ids(html).includes(id));
  return visibleText(body).length > 0;
};

test('every page declares a language, title and zoomable viewport', () => {
  for (const [name, html] of Object.entries(pages)) {
    assert.match(html, /<html[^>]*\slang="[a-z]{2}/i, `${name} declares lang`);
    assert.match(html, /<title>[^<]+<\/title>/, `${name} has a title`);
    assert.doesNotMatch(html, /user-scalable\s*=\s*no|maximum-scale\s*=\s*1(\.0)?\b/i, `${name} allows zoom`);
  }
});

test('every page has one main landmark and a single h1', () => {
  for (const [name, html] of Object.entries(pages)) {
    assert.equal((html.match(/<main\b/g) || []).length, 1, `${name} has one <main>`);
    assert.equal((html.match(/<h1\b/g) || []).length, 1, `${name} has one <h1>`);
  }
});

test('element ids are unique so labels and automation selectors resolve', () => {
  for (const [name, html] of Object.entries(pages)) {
    const seen = new Set();
    for (const id of ids(html)) {
      assert.ok(!seen.has(id), `${name} repeats id="${id}"`);
      seen.add(id);
    }
  }
});

test('images and inline SVGs are labelled or hidden from assistive technology', () => {
  for (const [name, html] of Object.entries(pages)) {
    for (const [tag] of html.matchAll(/<img\b[^>]*>/gi)) {
      assert.ok(attribute(tag, 'alt') !== undefined, `${name}: image without alt: ${tag}`);
    }
    for (const { open, body } of elements(html, 'svg')) {
      const hidden = attribute(open, 'aria-hidden') === 'true';
      const named = attribute(open, 'role') === 'img' && (attribute(open, 'aria-label') || /<title>/.test(body));
      assert.ok(hidden || named, `${name}: inline SVG must be aria-hidden or role="img" with a name: ${open}`);
    }
  }
});

test('links and buttons have accessible names', () => {
  for (const [name, html] of Object.entries(pages)) {
    for (const kind of ['a', 'button']) {
      for (const { open, body } of elements(html, kind)) {
        assert.ok(accessibleName(open, body, html), `${name}: unnamed <${kind}>: ${open}`);
      }
    }
  }
});

test('form controls have a programmatic label', () => {
  for (const [name, html] of Object.entries(pages)) {
    const labelled = new Set([...html.matchAll(/<label\b[^>]*\sfor="([^"]+)"/g)].map(match => match[1]));
    const wrapped = elements(html, 'label').map(({ body }) => body).join('\n');
    for (const [tag] of html.matchAll(/<(input|select|textarea)\b[^>]*>/gi)) {
      if (/type="(hidden|submit|button|reset)"/i.test(tag)) continue;
      const id = attribute(tag, 'id');
      const ok = attribute(tag, 'aria-label') || attribute(tag, 'aria-labelledby') ||
        (id && labelled.has(id)) || wrapped.includes(tag);
      assert.ok(ok, `${name}: unlabelled form control: ${tag}`);
    }
  }
});

test('positive tabindex never overrides the reading order', () => {
  for (const [name, html] of Object.entries(pages)) {
    assert.doesNotMatch(html, /tabindex="[1-9]/, `${name} uses a positive tabindex`);
  }
});

test('pages with navigation offer a skip link to main content', () => {
  for (const [name, html] of Object.entries(pages)) {
    if (!/<nav\b/.test(html)) continue;
    const target = html.match(/<a\b[^>]*href="#([^"]+)"[^>]*>\s*Skip to /)?.[1];
    assert.ok(target, `${name} has a skip link`);
    assert.ok(ids(html).includes(target), `${name} skip link target #${target} exists`);
  }
});

test('the QA checklist announces save and submission state', () => {
  const html = pages['qa/index.html'];
  assert.match(html, /aria-live="(polite|assertive)"|role="(status|alert)"/, 'QA page exposes a live region');
});

test('stylesheets keep visible focus and honour reduced motion', () => {
  for (const name of Object.keys(stylesheets)) {
    const css = stylesheets[name];
    assert.match(css, /:focus-visible\s*\{[^}]*outline:\s*\d/, `${name} draws a focus outline`);
    assert.doesNotMatch(css, /outline:\s*(none|0)\s*;?\s*\}/, `${name} never removes focus outlines`);
    assert.match(css, /prefers-reduced-motion/, `${name} honours reduced motion`);
  }
});

// WCAG 2.2 AA contrast for body-text tokens on every page background, in both schemes.
const luminance = hex => {
  const value = hex.replace('#', '');
  const full = value.length === 3 ? [...value].map(c => c + c).join('') : value;
  const channel = index => {
    const c = parseInt(full.slice(index, index + 2), 16) / 255;
    return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
  };
  return 0.2126 * channel(0) + 0.7152 * channel(2) + 0.0722 * channel(4);
};
const contrast = (a, b) => {
  const [light, dark] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (light + 0.05) / (dark + 0.05);
};
const tokens = block => Object.fromEntries([...block.matchAll(/(--[a-z-]+):\s*(#[0-9a-f]{3,6})\b/gi)]
  .map(([, name, value]) => [name, value]));
const schemes = css => {
  const dark = tokens(css.match(/:root\s*\{([\s\S]*?)\}/)[1]);
  const light = { ...dark, ...tokens(css.match(/prefers-color-scheme:\s*light\)\s*\{\s*:root\s*\{([\s\S]*?)\}/)[1]) };
  return { dark, light };
};
const foregrounds = ['--text', '--text-dim', '--text-faint', '--muted', '--accent-link', '--pass', '--fail', '--skip'];
const backgrounds = ['--ground', '--surface', '--bg'];

test('text tokens meet WCAG AA contrast in light and dark', () => {
  for (const [name, css] of Object.entries(stylesheets)) {
    for (const [scheme, palette] of Object.entries(schemes(css))) {
      for (const fg of foregrounds.filter(token => palette[token])) {
        for (const bg of backgrounds.filter(token => palette[token])) {
          const ratio = contrast(palette[fg], palette[bg]);
          assert.ok(ratio >= 4.5, `${name} ${scheme}: ${fg} on ${bg} is ${ratio.toFixed(2)}:1`);
        }
      }
    }
  }
});
