import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import test from 'node:test';

const root = fileURLToPath(new URL('../../', import.meta.url));
const read = name => readFileSync(path.join(root, name));
function png(name) {
  const data = read(name);
  assert.equal(data.subarray(1, 4).toString(), 'PNG', name);
  return { width: data.readUInt32BE(16), height: data.readUInt32BE(20), depth: data[24], colourType: data[25] };
}
test('Mac iconset pixels match point sizes and Retina scale', () => {
  for (const name of readdirSync(path.join(root, 'Resources/AppIcon.iconset'))) {
    const [, points, scale] = name.match(/^icon_(\d+)x\d+(@2x)?\.png$/);
    const expected = Number(points) * (scale ? 2 : 1);
    const asset = png('Resources/AppIcon.iconset/' + name);
    assert.equal(asset.width, expected, name);
    assert.equal(asset.height, expected, name);
    assert.equal(asset.depth, 8, name);
    assert.equal(asset.colourType, 6, 'Mac icon needs transparent outer corners');
  }
  const icns = read('Resources/AppIcon.icns');
  assert.deepEqual(read('Sources/SpeakApp/Resources/AppIcon.icns'), icns, 'SwiftPM and Xcode must bundle the same icon');
  assert.equal(icns.subarray(0, 4).toString(), 'icns');
  assert.equal(icns.readUInt32BE(4), icns.length);
  const chunks = new Set();
  for (let offset = 8; offset < icns.length;) {
    chunks.add(icns.subarray(offset, offset + 4).toString());
    const size = icns.readUInt32BE(offset + 4);
    assert.ok(size >= 8 && offset + size <= icns.length);
    offset += size;
  }
  // iconutil may choose ARGB or PNG chunks for small sizes, depending on Xcode/macOS.
  for (const alternatives of [['ic04', 'icp4', 'is32'], ['ic05', 'icp5', 'il32'], ['ic07'], ['ic08'], ['ic09'], ['ic10']]) {
    assert.ok(alternatives.some(type => chunks.has(type)), 'Missing ICNS size: ' + alternatives.join('/'));
  }
});
test('iOS appearances and Watch marketing icon are opaque 1024px artwork', () => {
  const ios = 'SpeakiOSApp/Assets.xcassets/AppIcon.appiconset';
  const entries = JSON.parse(read(ios + '/Contents.json')).images;
  assert.deepEqual(entries.map(x => x.appearances?.[0].value ?? 'any').sort(), ['any', 'dark', 'tinted']);
  for (const entry of entries) {
    assert.deepEqual(png(ios + '/' + entry.filename),
      { width: 1024, height: 1024, depth: 8, colourType: 2 });
  }
  assert.deepEqual(png('JustSpeakWatch/Assets.xcassets/AppIcon.appiconset/AppIcon.png'),
    { width: 1024, height: 1024, depth: 8, colourType: 2 });
});
test('web and touch icon sizes match their declarations', () => {
  for (const [name, size] of [['favicon-32.png', 32], ['apple-touch-icon.png', 180], ['icon-192.png', 192], ['icon-512.png', 512]]) {
    assert.equal(png('landing-page/' + name).width, size);
    assert.equal(png('landing-page/' + name).height, size);
  }
  for (const icon of JSON.parse(read('landing-page/site.webmanifest')).icons) {
    const asset = png('landing-page' + icon.src);
    assert.equal(icon.sizes, asset.width + 'x' + asset.height);
  }
});
