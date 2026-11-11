import { chromium, firefox } from 'playwright';
import AxeBuilder from '@axe-core/playwright';
import fs from 'node:fs';

const BASE = process.env.BASE || 'https://justspeaktoit.com';
const OUT = process.env.OUT || '/tmp/a11yqa/out';
const PAGES = (process.env.PAGES || '/,/privacy,/support,/qa').split(',');
const BROWSERS = (process.env.BROWSERS || 'chromium,firefox').split(',');
const SCHEMES = (process.env.SCHEMES || 'light,dark').split(',');
fs.mkdirSync(`${OUT}/screenshots`, { recursive: true });

const slug = p => (p === '/' ? 'home' : p.replace(/\W+/g, ''));
const report = [];

// Marks every element that should be in the Tab order and returns its summary.
const ENUMERATE = () => {
  const sel = 'a[href], button, input, select, textarea, summary, iframe, [tabindex], [contenteditable="true"], audio[controls], video[controls]';
  const nameOf = el => {
    const lb = el.getAttribute('aria-labelledby');
    if (lb) return lb.split(/\s+/).map(id => document.getElementById(id)?.textContent || '').join(' ').trim();
    if (el.getAttribute('aria-label')) return el.getAttribute('aria-label').trim();
    if (el.labels && el.labels.length) return [...el.labels].map(l => l.textContent).join(' ').trim();
    const alt = [...el.querySelectorAll('img[alt], svg[aria-label]')].map(i => i.getAttribute('alt') || i.getAttribute('aria-label')).join(' ');
    const text = (el.innerText || el.textContent || '').trim();
    return (text || alt || el.getAttribute('title') || el.value || '').replace(/\s+/g, ' ').trim();
  };
  const visible = el => {
    if (el.closest('[inert]')) return false;
    if (el.checkVisibility && !el.checkVisibility({ visibilityProperty: true })) {
      // visually-hidden inputs styled through a sibling still count
      if (!(el.matches('input') && el.closest('label'))) return false;
    }
    if (el.closest('details:not([open])') && !el.matches('summary') && !el.closest('details:not([open]) > summary')) return false;
    return el.getClientRects().length > 0 || el.matches('input');
  };
  const radiosSeen = new Set();
  const out = [];
  let i = 0;
  for (const el of document.querySelectorAll('*')) el.removeAttribute('data-qa-idx');
  for (const el of document.querySelectorAll(sel)) {
    i += 1;
    el.setAttribute('data-qa-dom', String(i));
    const ti = el.getAttribute('tabindex');
    if (ti !== null && Number(ti) < 0) continue;
    if (el.disabled) continue;
    if (el.matches('a:not([href])')) continue;
    if (el.matches('input[type=hidden]')) continue;
    if (!visible(el)) continue;
    let group = null;
    if (el.matches('input[type=radio]')) {
      group = `radio:${el.name}`;
      if (radiosSeen.has(group)) continue; // only one radio per group is tabbable
      radiosSeen.add(group);
    }
    el.setAttribute('data-qa-idx', String(out.length));
    out.push({ idx: out.length, dom: i, tag: el.tagName.toLowerCase(), group, tabindex: ti, name: nameOf(el), id: el.id || null,
      text: (el.outerHTML || '').slice(0, 140) });
  }
  return out;
};

const ACTIVE = () => {
  const el = document.activeElement;
  if (!el || el === document.body || el === document.documentElement) return { body: true };
  const rect = el.getBoundingClientRect();
  const cs = getComputedStyle(el);
  const sib = el.matches('input') ? el.nextElementSibling : null;
  const scs = sib ? getComputedStyle(sib) : null;
  const ind = s => s && ((s.outlineStyle !== 'none' && parseFloat(s.outlineWidth) >= 1) || (s.boxShadow && s.boxShadow !== 'none'));
  const group = el.matches('input[type=radio]') ? `radio:${el.name}` : null;
  let idx = el.getAttribute('data-qa-idx');
  if (idx === null && group) {
    const first = document.querySelector(`input[type=radio][name="${CSS.escape(el.name)}"][data-qa-idx]`);
    idx = first ? first.getAttribute('data-qa-idx') : null;
  }
  return {
    body: false, idx: idx === null ? null : Number(idx), dom: Number(el.getAttribute('data-qa-dom') || -1),
    tag: el.tagName.toLowerCase(), id: el.id || null, group,
    text: (el.innerText || el.getAttribute('aria-label') || el.value || '').replace(/\s+/g, ' ').trim().slice(0, 60),
    rect: { x: rect.x, y: rect.y, w: rect.width, h: rect.height },
    inViewport: rect.bottom > 0 && rect.top < innerHeight && rect.right > 0 && rect.left < innerWidth && rect.width > 0,
    focusIndicator: Boolean(ind(cs) || ind(scs)),
    outline: `${cs.outlineStyle} ${cs.outlineWidth} ${cs.outlineColor}`, boxShadow: cs.boxShadow,
    focusVisible: el.matches(':focus-visible'),
  };
};

async function shot(page, file, rect) {
  const pad = 40;
  const vp = page.viewportSize();
  let clip;
  if (rect && rect.w > 0) {
    const x = Math.max(0, rect.x - pad), y = Math.max(0, rect.y - pad);
    clip = { x, y, width: Math.min(vp.width - x, rect.w + pad * 2), height: Math.min(vp.height - y, rect.h + pad * 2) };
    if (clip.width < 10 || clip.height < 10) clip = undefined;
  }
  await page.screenshot({ path: `${OUT}/screenshots/${file}`, clip });
  return `screenshots/${file}`;
}

async function auditPage(browserName, browser, path, scheme) {
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 }, colorScheme: scheme, reducedMotion: 'reduce' });
  const page = await ctx.newPage();
  const consoleErrors = [];
  page.on('pageerror', e => consoleErrors.push(String(e)));
  page.on('console', m => { if (m.type() === 'error') consoleErrors.push(m.text()); });
  const tag = `${browserName}-${slug(path)}-${scheme}`;
  const r = { browser: browserName, page: path, scheme, issues: [], screenshots: [] };
  await page.goto(BASE + path, { waitUntil: 'networkidle' });

  // axe
  const axe = await new AxeBuilder({ page })
    .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa', 'wcag22aa', 'best-practice']).analyze();
  r.axe = {
    violations: axe.violations.map(v => ({ id: v.id, impact: v.impact, help: v.help, nodes: v.nodes.map(n => n.target.join(' ')).slice(0, 8), count: v.nodes.length })),
    incomplete: axe.incomplete.map(v => ({ id: v.id, impact: v.impact, count: v.nodes.length })),
    passes: axe.passes.length,
  };
  r.axe.seriousOrCritical = r.axe.violations.filter(v => ['serious', 'critical'].includes(v.impact)).length;

  // keyboard checks only in one scheme per browser (focus colour screenshots in both)
  const candidates = await page.evaluate(ENUMERATE);
  r.candidates = candidates.length;
  r.unnamed = candidates.filter(c => !c.name).map(c => c.text);
  r.positiveTabindex = candidates.filter(c => c.tabindex && Number(c.tabindex) > 0).map(c => c.text);

  // Skip link: first Tab
  await page.keyboard.press('Tab');
  const first = await page.evaluate(ACTIVE);
  r.skipLink = { firstFocus: first.text, visible: first.inViewport, indicator: first.focusIndicator };
  r.screenshots.push(await shot(page, `${tag}-01-skiplink.png`, null));
  if (!/skip/i.test(first.text || '')) r.issues.push(`First Tab stop is not a skip link (${first.text})`);
  if (!first.inViewport) r.issues.push('Skip link not visible when focused');
  await page.keyboard.press('Enter');
  await page.waitForTimeout(300);
  r.skipLink.hashAfterEnter = new URL(page.url()).hash;
  await page.keyboard.press('Tab');
  const afterSkip = await page.evaluate(() => {
    const el = document.activeElement;
    return { inMain: Boolean(el && el.closest('main, #main')), text: (el?.innerText || el?.getAttribute('aria-label') || '').trim().slice(0, 60) };
  });
  r.skipLink.nextFocusAfterSkip = afterSkip;
  if (!afterSkip.inMain) r.issues.push(`After activating skip link, next Tab lands outside main (${afterSkip.text})`);

  // Full forward traversal from top
  await page.goto(BASE + path, { waitUntil: 'networkidle' });
  await page.evaluate(ENUMERATE);
  const seq = [];
  const limit = candidates.length * 2 + 25;
  let trap = null;
  for (let n = 0; n < limit; n += 1) {
    await page.keyboard.press('Tab');
    const a = await page.evaluate(ACTIVE);
    if (a.body) { if (seq.length) break; else continue; }
    if (seq.length && a.idx !== null && seq.some(s => s.idx === a.idx) && seq[0].idx === a.idx) break; // wrapped
    // <video controls> exposes several native control stops inside its shadow root;
    // collapse them into one stop and only call it a trap if focus never leaves.
    if (seq.length && seq[seq.length - 1].dom === a.dom && a.tag === 'video') {
      seq[seq.length - 1].nativeStops = (seq[seq.length - 1].nativeStops || 1) + 1;
      if (seq[seq.length - 1].nativeStops > 15) { trap = a; break; }
      continue;
    }
    seq.push(a);
  }
  if (seq.length >= limit) trap = trap || { text: 'traversal never ended' };
  r.forward = seq.map(s => ({ idx: s.idx, tag: s.tag, text: s.text, indicator: s.focusIndicator, inViewport: s.inViewport, nativeStops: s.nativeStops }));
  if (trap) r.issues.push(`Possible keyboard trap at ${trap.text}`);
  const reached = new Set(seq.map(s => s.idx).filter(x => x !== null));
  r.unreached = candidates.filter(c => !reached.has(c.idx)).map(c => `${c.tag} "${c.name}" ${c.text}`);
  if (r.unreached.length) r.issues.push(`${r.unreached.length} focusable elements not reached by Tab`);
  r.extraStops = seq.filter(s => s.idx === null).map(s => `${s.tag} ${s.text}`);
  const noIndicator = seq.filter(s => !s.focusIndicator);
  r.nativeVideoStops = seq.filter(s => s.nativeStops).map(s => `${s.text}: ${s.nativeStops} stops`);
  if (noIndicator.length) r.issues.push(`No visible focus indicator on: ${noIndicator.map(s => s.text || s.tag).join(' | ')}`);
  const offscreen = seq.filter(s => !s.inViewport);
  if (offscreen.length) r.issues.push(`Focused but not scrolled into view: ${offscreen.map(s => s.text || s.tag).join(' | ')}`);
  // Logical order: DOM order should be monotonic
  const doms = seq.map(s => s.dom);
  const backwards = doms.filter((d, i) => i && d < doms[i - 1]).length;
  r.orderMonotonic = backwards === 0;
  if (backwards) r.issues.push(`Tab order goes backwards in DOM ${backwards} times`);

  // Shift+Tab: from last element, reverse back
  const rev = [];
  for (let n = 0; n < seq.length * 12 + 5; n += 1) {
    await page.keyboard.press('Shift+Tab');
    const a = await page.evaluate(ACTIVE);
    if (a.body) break;
    if (rev.length && rev[rev.length - 1] === a.dom && a.tag === 'video') continue;
    rev.push(a.dom);
    if (rev.length >= seq.length) break;
  }
  const expected = doms.slice(0, -1).reverse();
  // after loop end focus is on body/browser chrome; first Shift+Tab lands on the last element
  const revCmp = rev[0] === doms[doms.length - 1] ? rev.slice(1) : rev;
  r.reverseMatches = JSON.stringify(revCmp.slice(0, expected.length)) === JSON.stringify(expected.slice(0, revCmp.length)) && revCmp.length >= expected.length - 1;
  if (!r.reverseMatches) r.issues.push('Shift+Tab order does not mirror Tab order');

  // Focus screenshots (first ~8 stops after skip link, plus failures)
  await page.goto(BASE + path, { waitUntil: 'networkidle' });
  await page.evaluate(ENUMERATE);
  const shotIdx = new Set([1, 2, 3, 5, 8, Math.floor(seq.length / 2), seq.length - 1].filter(i => i > 0 && i < seq.length));
  noIndicator.forEach(s => shotIdx.add(seq.indexOf(s)));
  let prevDom = null, n = -1;
  for (let k = 0; k < seq.length * 12 && n < seq.length - 1; k += 1) {
    await page.keyboard.press('Tab');
    const a = await page.evaluate(ACTIVE);
    if (a.body) break;
    if (a.dom === prevDom && a.tag === 'video') continue;
    prevDom = a.dom; n += 1;
    if (shotIdx.has(n)) r.screenshots.push(await shot(page, `${tag}-focus-${String(n).padStart(3, '0')}.png`, a.rect));
  }

  // Enter on an in-page link, Escape handling, details/summary
  r.enter = [];
  await page.goto(BASE + path, { waitUntil: 'networkidle' });
  const anchor = await page.$('main a[href^="#"]:not(.skip-link), nav a[href^="#"]');
  if (anchor) {
    const href = await anchor.getAttribute('href');
    await anchor.focus();
    await page.keyboard.press('Enter');
    await page.waitForTimeout(300);
    r.enter.push({ action: `Enter on in-page link ${href}`, hash: new URL(page.url()).hash, ok: new URL(page.url()).hash === href });
  }
  const summary = await page.$('summary');
  if (summary) {
    await summary.focus();
    await page.keyboard.press('Enter');
    const open = await summary.evaluate(s => s.parentElement.open);
    r.enter.push({ action: 'Enter on <summary>', ok: open });
    await page.keyboard.press('Escape');
    const stillFocused = await summary.evaluate(s => document.activeElement === s);
    r.enter.push({ action: 'Escape while <summary> focused keeps focus', ok: stillFocused });
    await page.keyboard.press('Enter');
  }
  const expanders = await page.$$('[aria-expanded]');
  for (const ex of expanders.slice(0, 5)) {
    if (!(await ex.isVisible())) continue;
    await ex.focus();
    const before = await ex.getAttribute('aria-expanded');
    await page.keyboard.press('Enter');
    const after = await ex.getAttribute('aria-expanded');
    await page.keyboard.press('Escape');
    const esc = await ex.getAttribute('aria-expanded');
    r.enter.push({ action: `Enter/Escape on [aria-expanded] ${await ex.evaluate(e => e.textContent.trim().slice(0, 40))}`, before, after, afterEscape: esc, ok: before !== after });
  }
  if (path === '/qa') {
    // Mark one check Pass using only the keyboard
    const radio = page.locator('input[type=radio][value="pass"]').first();
    await radio.focus();
    await page.keyboard.press('Space');
    const checked = await radio.isChecked();
    r.enter.push({ action: 'Space on first Pass radio marks the check Pass', ok: checked });
    await page.keyboard.press('ArrowRight');
    const moved = await page.evaluate(() => document.activeElement?.value);
    r.enter.push({ action: 'ArrowRight from Pass selects Fail and keeps focus in the group', value: moved, ok: moved === 'fail' });
    await page.keyboard.press('ArrowRight');
    const moved2 = await page.evaluate(() => document.activeElement?.value);
    r.enter.push({ action: 'ArrowRight again reaches Skip', value: moved2, ok: moved2 === 'skip' });
    await page.keyboard.press('ArrowLeft');
    await page.keyboard.press('Tab');
    const note = await page.evaluate(() => document.activeElement?.id || document.activeElement?.tagName);
    r.enter.push({ action: 'With Fail selected, the next Tab reaches the note field', value: note, ok: /^note-/.test(note) });
    const a = await page.evaluate(ACTIVE);
    r.screenshots.push(await shot(page, `${tag}-qa-radio-keyboard.png`, a.rect));
  }
  // Escape at an arbitrary point must not throw focus away or break the page
  await page.keyboard.press('Tab');
  const beforeEsc = await page.evaluate(ACTIVE);
  await page.keyboard.press('Escape');
  const afterEsc = await page.evaluate(ACTIVE);
  r.enter.push({ action: 'Escape on a focused control keeps focus', ok: beforeEsc.dom === afterEsc.dom });
  for (const e of r.enter) if (!e.ok) r.issues.push(`Keyboard action failed: ${e.action}`);

  r.consoleErrors = consoleErrors;
  if (r.axe.seriousOrCritical) {
    r.issues.push(`axe: ${r.axe.violations.filter(v => ['serious', 'critical'].includes(v.impact)).map(v => `${v.id}(${v.impact})`).join(', ')}`);
    r.screenshots.push(await shot(page, `${tag}-axe-fail.png`, null));
  }
  await ctx.close();
  return r;
}

for (const bn of BROWSERS) {
  const browser = await (bn === 'firefox' ? firefox : chromium).launch();
  for (const p of PAGES) for (const s of SCHEMES) {
    try {
      const r = await auditPage(bn, browser, p, s);
      report.push(r);
      console.log(`${bn} ${p} ${s}: axe ${r.axe.violations.map(v => `${v.id}:${v.impact}:${v.count}`).join(',') || 'clean'} | stops ${r.forward.length}/${r.candidates} | issues: ${r.issues.join(' ; ') || 'none'}`);
    } catch (e) {
      console.log(`${bn} ${p} ${s}: ERROR ${e.stack}`);
      report.push({ browser: bn, page: p, scheme: s, error: String(e) });
    }
  }
  await browser.close();
}
fs.writeFileSync(`${OUT}/report.json`, JSON.stringify(report, null, 2));
