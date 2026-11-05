import test from 'node:test';
import assert from 'node:assert/strict';
import worker from './_worker.js';

const release = 'https://github.com/crmitchelmore/justspeaktoit/releases/download';
const serve = async (path, published) => {
  globalThis.fetch = async (url, init = {}) => {
    if (url.endsWith('/alpha-latest/alpha-pointer.json')) return Response.json({tag: 'alpha-build-7'});
    assert.equal(init.method, 'HEAD');
    return new Response(null, {status: published.some(name => url.endsWith(`/${name}`)) ? 302 : 404});
  };
  return worker.fetch(new Request(`https://justspeaktoit.com${path}`), {ASSETS: {fetch: () => new Response('static')}});
};

test('desktop Alpha routes redirect to the pointed Alpha only when the asset was published', async () => {
  const routes = {
    '/alpha/download/windows-x64': 'JustSpeakToIt-windows-x64-developer.zip',
    '/alpha/download/windows-arm64': 'JustSpeakToIt-windows-arm64-developer.zip',
    '/alpha/download/linux-x86_64': 'JustSpeakToIt-linux-x86_64.flatpak',
  };
  for (const [path, asset] of Object.entries(routes)) {
    const found = await serve(path, [asset]);
    assert.equal(found.status, 302);
    assert.equal(found.headers.get('Location'), `${release}/alpha-build-7/${asset}`);
    assert.equal((await serve(path, [])).status, 503);
  }
});

test('Mac Alpha routes do not probe and unknown paths fall through to static assets', async () => {
  const mac = await serve('/alpha/download/arm64', []);
  assert.equal(mac.headers.get('Location'), `${release}/alpha-build-7/JustSpeakToItAlpha-arm64.dmg`);
  assert.equal(await (await serve('/alpha/other', [])).text(), 'static');
});


test('desktop Alpha routes return unavailable when the asset HEAD request rejects', async () => {
  const originalFetch = globalThis.fetch;
  try {
    globalThis.fetch = async (url, init = {}) => {
      if (url.endsWith('/alpha-latest/alpha-pointer.json')) return Response.json({tag: 'alpha-build-7'});
      assert.equal(init.method, 'HEAD');
      throw new TypeError('Network unavailable');
    };
    for (const platform of ['windows-x64', 'windows-arm64', 'linux-x86_64']) {
      const response = await worker.fetch(new Request(`https://justspeaktoit.com/alpha/download/${platform}`), {});
      assert.equal(response.status, 503);
      assert.equal(response.headers.get('Location'), null);
      assert.equal(await response.text(), 'Desktop Alpha build not yet available');
    }
  } finally {
    globalThis.fetch = originalFetch;
  }
});

const installerPointer = {schemaVersion: 1, tag: 'alpha-build-9', build: '202610301641', version: '2026.1030.1641.0',
  publisher: 'CN=Example Ltd, O=Example Ltd, C=GB'};
const appInstaller = `<?xml version="1.0" encoding="utf-8"?>
<AppInstaller Uri="https://justspeaktoit.com/alpha/windows/JustSpeakToIt.appinstaller" Version="2026.1030.1641.0"/>`;
const serveInstaller = async (path, {pointer = installerPointer, file = appInstaller} = {}) => {
  const originalFetch = globalThis.fetch;
  const requested = [];
  globalThis.fetch = async url => {
    requested.push(url);
    if (url.endsWith('/alpha-latest/windows-installer-pointer.json')) {
      return pointer ? Response.json(pointer) : new Response('Not Found', {status: 404});
    }
    if (url === `${release}/alpha-build-9/JustSpeakToIt.appinstaller`) {
      return file === null ? new Response('Not Found', {status: 404}) : new Response(file);
    }
    throw Error(`unexpected fetch ${url}`);
  };
  try {
    const response = await worker.fetch(new Request(`https://justspeaktoit.com${path}`), {});
    return {response, requested};
  } finally {
    globalThis.fetch = originalFetch;
  }
};

test('the Windows CTA opens the qualified App Installer file and falls back to the ZIP by architecture', async () => {
  const {response} = await serveInstaller('/alpha/download/windows?arch=arm64');
  assert.equal(response.status, 302);
  assert.equal(response.headers.get('Location'), '/alpha/windows/JustSpeakToIt.appinstaller');
  for (const [query, platform] of [['', 'windows-x64'], ['?arch=arm64', 'windows-arm64'], ['?arch=other', 'windows-x64']]) {
    const fallback = (await serveInstaller(`/alpha/download/windows${query}`, {pointer: null})).response;
    assert.equal(fallback.headers.get('Location'), `/alpha/download/${platform}`);
  }
});

test('the App Installer file is served as a download from the pointed release only', async () => {
  const {response, requested} = await serveInstaller('/alpha/windows/JustSpeakToIt.appinstaller');
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('Content-Type'), 'application/appinstaller');
  assert.match(response.headers.get('Content-Disposition'), /^attachment; filename="JustSpeakToIt\.appinstaller"$/);
  assert.equal(await response.text(), appInstaller);
  assert.ok(!requested.some(url => url.includes('alpha-pointer.json')));
  for (const options of [{pointer: null}, {file: null}, {file: appInstaller.replace('justspeaktoit.com', 'example.com')},
    {pointer: {...installerPointer, tag: 'alpha-latest'}}, {pointer: {...installerPointer, schemaVersion: 2}},
    {pointer: {...installerPointer, version: '1.2.3'}}]) {
    assert.equal((await serveInstaller('/alpha/windows/JustSpeakToIt.appinstaller', options)).response.status, 503);
  }
});

test('the installer status reports availability without promising more than the pointer', async () => {
  const available = await (await serveInstaller('/alpha/windows/installer.json')).response.json();
  assert.deepEqual(available, {available: true, channel: 'beta', tag: 'alpha-build-9', build: '202610301641',
    version: '2026.1030.1641.0', publisher: installerPointer.publisher,
    appInstaller: 'https://justspeaktoit.com/alpha/windows/JustSpeakToIt.appinstaller'});
  const missing = await (await serveInstaller('/alpha/windows/installer.json', {pointer: null})).response.json();
  assert.deepEqual(missing, {available: false, channel: 'beta'});
});
