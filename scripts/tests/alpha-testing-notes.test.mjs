import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { newAlphaChecks, pleaseTestMarkdown, previousDeliveredSource, catalogueIds, MAX_LISTED_CHECKS } from '../alpha-testing-notes-lib.mjs';
import { notesFor } from '../release-train-lib.mjs';

const check = (id, title) => [
    `      - id: "${id}"`,
    '        issues:',
    '          - 1',
    `        title: "${title}"`,
    '        minutes: 3',
    '        core: true',
    '        build: "Alpha"',
    '        steps:',
    '          - "One"',
    '          - "Two"',
    '          - "Three"',
    '        expected: "Works"',
    '        final_gate: true',
].join('\n');
const catalogue = (sessions) => ['version: 1', 'updated: "2026-11-12"', 'sessions:', ...sessions.map(([id, device, items]) => [
    `  - id: "${id}"`, `    device: "${device}"`, `    title: "${device}"`, '    items:', ...items.map(([itemId, title]) => check(itemId, title)),
].join('\n'))].join('\n') + '\n';

const previous = catalogue([['mac', 'Mac', [['mac-old', 'Old Mac check']]], ['iphone', 'iPhone', [['iphone-old', 'Old iPhone check']]]]);
const current = catalogue([
    ['mac', 'Mac', [['mac-old', 'Old Mac check'], ['mac-new', 'New Mac check'], ['owner-setup', 'Owner setup']]],
    ['iphone', 'iPhone', [['iphone-old', 'Old iPhone check'], ['iphone-new', 'New iPhone check']]],
    ['watch', 'Watch', [['watch-new', 'New Watch check']]],
]);

test('lists only checks added since the previous Alpha, per platform, without owner tasks', () => {
    assert.deepEqual(newAlphaChecks({ previous, current, platform: 'mac' }).map((item) => item.id), ['mac-new']);
    assert.deepEqual(newAlphaChecks({ previous, current, platform: 'ios' }).map((item) => item.id), ['iphone-new', 'watch-new']);
    assert.deepEqual(newAlphaChecks({ previous: current, current, platform: 'ios' }), []);
});

test('an invalid current catalogue never blocks a release; a missing previous one lists everything', () => {
    assert.deepEqual(newAlphaChecks({ previous, current: 'version: 2', platform: 'mac' }), []);
    assert.deepEqual(newAlphaChecks({ previous: '', current, platform: 'mac' }).map((item) => item.id), ['mac-old', 'mac-new']);
});

test('Please test section links each check and caps the list', () => {
    assert.equal(pleaseTestMarkdown([]), '');
    const checks = Array.from({ length: MAX_LISTED_CHECKS + 2 }, (_, i) => ({ id: `mac-${i}`, title: `Check ${i}`, minutes: 2 }));
    const markdown = pleaseTestMarkdown(checks);
    assert.match(markdown, /^## Please test\n/);
    assert.match(markdown, /- \*\*Check 0\*\* \(about 2 min\): https:\/\/justspeaktoit\.com\/qa#mac-0/);
    assert.doesNotMatch(markdown, /mac-6/);
    assert.match(markdown, /- 2 more: https:\/\/justspeaktoit\.com\/qa$/);
});

test('Alpha notes place Please test after the changes and before the changelog', () => {
    const testing = pleaseTestMarkdown(newAlphaChecks({ previous, current, platform: 'mac' }));
    const notes = notesFor([{ sha: 'a'.repeat(40), subject: 'feat(mac): thing', body: '' }], 'mac', 'https://example.test/compare', testing);
    assert.ok(notes.indexOf('### New and improved') < notes.indexOf('## Please test'));
    assert.ok(notes.indexOf('## Please test') < notes.indexOf('**Full changelog:**'));
    assert.doesNotMatch(notesFor([], 'mac', 'https://example.test/compare'), /Please test/);
});

test('the previous Alpha is the newest delivered ancestor on that surface', () => {
    const manifests = [1, 2, 3, 4].map((ordinal) => ({ train: 'alpha', tag: `alpha-build-${ordinal}`, ordinal, source: `s${ordinal}` }));
    const releases = [
        { tag_name: 'alpha-build-1', assets: [{ name: 'ios-receipt.json' }, { name: 'mac-direct-receipt.json' }] },
        { tag_name: 'alpha-build-2', assets: [{ name: 'mac-direct-receipt.json' }] },
        { tag_name: 'alpha-build-3', assets: [{ name: 'mac-direct-receipt.json' }] },
        { tag_name: 'alpha-build-4', assets: [{ name: 'ios-receipt.json' }, { name: 'mac-direct-receipt.json' }] },
    ];
    const isAncestor = (ancestor) => ancestor !== 's3';
    const find = (surface) => previousDeliveredSource({ manifests, releases, surface, source: 's4', isAncestor });
    assert.equal(find('mac-direct'), 's2');
    assert.equal(find('ios'), 's1');
    assert.equal(previousDeliveredSource({ manifests, releases: [], surface: 'ios', source: 's4', isAncestor }), null);
});

test('the committed catalogue parses for Alpha notes', () => {
    const source = readFileSync(new URL('../../Docs/manual-checks.yml', import.meta.url), 'utf8');
    assert.ok(catalogueIds(source).has('iphone-keyboard-other-apps'));
    assert.ok(newAlphaChecks({ previous: '', current: source, platform: 'ios' }).length > 0);
});
