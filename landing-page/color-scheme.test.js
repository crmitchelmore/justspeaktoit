import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { renderPage } from './chrome.mjs';
import { loadCatalogue } from './qa/manual-checks.mjs';
import { renderQaPage } from './qa/render.mjs';
import { renderStylesheet } from './stylesheet.mjs';

const read = file => readFile(new URL(file, import.meta.url), 'utf8');
const catalogue = loadCatalogue(await read('../Docs/manual-checks.yml'));
const pages = {
  'index.html': await renderPage('index.html'),
  'privacy.html': await renderPage('privacy.html'),
  'support.html': await renderPage('support.html'),
  'qa/index.html': renderQaPage(catalogue),
};
const stylesheets = {
  'site.css': await renderStylesheet(),
  'qa/qa.css': await read('qa/qa.css'),
  'privacy.html': pages['privacy.html'],
  'support.html': pages['support.html'],
};

test('every page opts into both light and dark colour schemes', () => {
  for (const [name, html] of Object.entries(pages)) {
    assert.match(html, /<meta name="color-scheme" content="light dark">/, name);
  }
});

test('every stylesheet follows the system appearance', () => {
  for (const [name, css] of Object.entries(stylesheets)) {
    assert.match(css, /color-scheme:\s*light dark;/, `${name} declares color-scheme`);
    assert.doesNotMatch(css, /color-scheme:\s*dark;/, `${name} is not forced dark`);
    assert.match(css, /@media \(prefers-color-scheme: light\)\s*\{\s*:root\s*\{[^}]*--text:/, `${name} has a light palette`);
  }
});

test('page chrome uses theme tokens instead of fixed dark fills', () => {
  for (const [name, css] of Object.entries(stylesheets)) {
    assert.doesNotMatch(css, /background:\s*rgba\(18, 20, 23/, `${name} bars use a theme token`);
  }
});

test('primary nav labels wrap instead of being clipped', () => {
  const nav = stylesheets['site.css'].match(/\.site-nav \{[^}]*\}/)[0];
  assert.match(nav, /flex-wrap:\s*wrap/);
  assert.match(nav, /min-width:\s*0/);
  assert.doesNotMatch(stylesheets['site.css'], /\.site-nav[^{]*\{[^}]*text-overflow/);
});
