import test, {mock} from 'node:test';
import assert from 'node:assert/strict';
import worker from './_worker.js';
import {desktopDownloads} from '../scripts/desktop-release-lib.mjs';

const release = 'https://github.com/crmitchelmore/justspeaktoit/releases/download';
const serve = async (path, published) => {
  globalThis.fetch = async (url, init = {}) => {
    if (url.endsWith('/alpha-latest/alpha-pointer.json')) return Response.json({tag: 'alpha-build-7'});
    assert.equal(init.method, 'HEAD');
    return new Response(null, {status: published.some(name => url.endsWith(`/${name}`)) ? 302 : 404});
  };
  return worker.fetch(new Request(`https://justspeaktoit.com${path}`), {ASSETS: {fetch: () => new Response('static')}});
};

// The desktop download goldens come from the assets the release train
// publishes, so a renamed or added asset fails here instead of on the site.
const desktopRoutes = Object.fromEntries(desktopDownloads.map(({kind, architecture, asset}) =>
  [`/alpha/download/${kind === 'flatpak' ? 'linux' : 'windows'}-${architecture}`, asset]));

test('desktop Alpha routes redirect to the pointed Alpha only when the asset was published', async () => {
  assert.deepEqual(Object.keys(desktopRoutes).sort(),
    ['/alpha/download/linux-x86_64', '/alpha/download/windows-arm64', '/alpha/download/windows-x64']);
  for (const [path, asset] of Object.entries(desktopRoutes)) {
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
    for (const path of Object.keys(desktopRoutes)) {
      const response = await worker.fetch(new Request(`https://justspeaktoit.com${path}`), {});
      assert.equal(response.status, 503);
      assert.equal(response.headers.get('Location'), null);
      assert.equal(await response.text(), 'Desktop Alpha build not yet available');
    }
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test('Alpha routes return unavailable when the Alpha pointer fetch rejects', async () => {
  const originalFetch = globalThis.fetch;
  try {
    globalThis.fetch = async () => { throw new TypeError('synthetic pointer network failure'); };
    for (const path of ['/alpha/download/arm64', '/alpha/appcast.xml', '/alpha/download/windows-x64']) {
      const response = await worker.fetch(new Request(`https://justspeaktoit.com${path}`), {});
      assert.equal(response.status, 503);
      assert.equal(response.headers.get('Location'), null);
      assert.equal(await response.text(), 'Alpha build not yet available');
    }
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test('Alpha routes distinguish a missing pointer from an invalid one', async () => {
  const originalFetch = globalThis.fetch;
  const cases = [
    [new Response('nope', {status: 404}), 'Alpha build not yet available'],
    [new Response('not json'), 'Invalid Alpha pointer'],
    [Response.json({tag: 'alpha-build-0'}), 'Invalid Alpha pointer'],
  ];
  try {
    for (const [pointer, message] of cases) {
      globalThis.fetch = async () => pointer;
      const response = await worker.fetch(new Request('https://justspeaktoit.com/alpha/download/arm64'), {});
      assert.equal(response.status, 503);
      assert.equal(await response.text(), message);
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

test('Linux Flatpak descriptors are served from the signed repository site', async () => {
  const originalFetch = globalThis.fetch;
  const ref = '[Flatpak Ref]\nName=com.justspeaktoit.JustSpeakToIt\nGPGKey=AAAA\n';
  try {
    globalThis.fetch = async url => {
      assert.equal(url, 'https://justspeaktoit-flatpak.pages.dev/com.justspeaktoit.JustSpeakToIt.flatpakref');
      return new Response(ref);
    };
    const response = await worker.fetch(new Request('https://justspeaktoit.com/linux/flatpak'), {});
    assert.equal(response.status, 200);
    assert.equal(response.headers.get('Content-Type'), 'application/vnd.flatpak.ref');
    assert.equal(await response.text(), ref);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test('Linux Flatpak descriptors fall back to the Alpha bundle until a repository is published', async () => {
  const originalFetch = globalThis.fetch;
  const cases = [
    async () => new Response('Not found', {status: 404}),
    async () => new Response('<html>index</html>'),
    async () => new Response('[Flatpak Repo]\nUrl=https://example.com/\n'),
    async () => { throw new TypeError('Network unavailable'); },
  ];
  try {
    for (const fake of cases) {
      globalThis.fetch = fake;
      for (const path of ['/linux/flatpak', '/linux/justspeaktoit.flatpakrepo']) {
        const response = await worker.fetch(new Request(`https://justspeaktoit.com${path}`), {});
        assert.equal(response.status, 302);
        assert.equal(response.headers.get('Location'), '/alpha/download/linux-x86_64');
      }
    }
  } finally {
    globalThis.fetch = originalFetch;
  }
});

// A fetch that never answers on its own; it rejects only when its signal aborts.
const stalledFetch = aborted => (url, init = {}) => new Promise((_, reject) => {
  init.signal?.addEventListener('abort', () => {
    aborted.push(url);
    reject(new DOMException('aborted', 'AbortError'));
  });
});

// Runs one request against stalled upstreams, advancing past the deadline.
const serveStalled = async (path, fetchImpl) => {
  const originalFetch = globalThis.fetch;
  mock.timers.enable({apis: ['setTimeout']});
  try {
    globalThis.fetch = fetchImpl;
    const pending = worker.fetch(new Request(`https://justspeaktoit.com${path}`), {});
    for (let step = 0; step < 4; step += 1) {
      await new Promise(resolve => setImmediate(resolve));
      mock.timers.tick(5000);
    }
    return await pending;
  } finally {
    mock.timers.reset();
    globalThis.fetch = originalFetch;
  }
};

test('a stalled Alpha pointer is aborted at the deadline and answers unavailable', async () => {
  const aborted = [];
  const response = await serveStalled('/alpha/download/arm64', stalledFetch(aborted));
  assert.equal(response.status, 503);
  assert.equal(await response.text(), 'Alpha build not yet available');
  assert.deepEqual(aborted, [`${release}/alpha-latest/alpha-pointer.json`]);
});

test('stalled installer, probe and Flatpak fetches end in their controlled fallbacks', async () => {
  const installer = await serveStalled('/alpha/windows/installer.json', stalledFetch([]));
  assert.deepEqual(await installer.json(), {available: false, channel: 'beta'});

  const probe = await serveStalled('/alpha/download/windows-x64', (url, init) =>
    url.endsWith('/alpha-pointer.json') ? Promise.resolve(Response.json({tag: 'alpha-build-7'}))
      : stalledFetch([])(url, init));
  assert.equal(probe.status, 503);
  assert.equal(await probe.text(), 'Desktop Alpha build not yet available');

  const file = await serveStalled('/alpha/windows/JustSpeakToIt.appinstaller', (url, init) =>
    url.endsWith('/windows-installer-pointer.json') ? Promise.resolve(Response.json(installerPointer))
      : stalledFetch([])(url, init));
  assert.equal(file.status, 503);
  assert.equal(await file.text(), 'Windows installer not yet available');

  const flatpak = await serveStalled('/linux/flatpak', stalledFetch([]));
  assert.equal(flatpak.status, 302);
  assert.equal(flatpak.headers.get('Location'), '/alpha/download/linux-x86_64');
});

test('pointer schemas are checked separately for the Alpha and installer pointers', async () => {
  const originalFetch = globalThis.fetch;
  try {
    // The Alpha pointer needs only its tag; installer fields are never imposed on it.
    globalThis.fetch = async () => Response.json({tag: 'alpha-build-7'});
    assert.equal((await worker.fetch(new Request('https://justspeaktoit.com/alpha/download/arm64'), {})).status, 302);
    for (const pointer of [JSON.stringify({tag: 'alpha-build-7', padding: 'x'.repeat(5000)}), 'null', '"alpha-build-7"']) {
      globalThis.fetch = async () => new Response(pointer);
      const response = await worker.fetch(new Request('https://justspeaktoit.com/alpha/download/arm64'), {});
      assert.equal(response.status, 503);
      assert.equal(await response.text(), 'Invalid Alpha pointer');
    }
  } finally {
    globalThis.fetch = originalFetch;
  }
  const {build: _build, ...withoutBuild} = installerPointer;
  for (const pointer of [withoutBuild, {...installerPointer, build: 7}, {...installerPointer, publisher: ''}]) {
    const status = await (await serveInstaller('/alpha/windows/installer.json', {pointer})).response.json();
    assert.deepEqual(status, {available: false, channel: 'beta'});
  }
});

// An upstream body served in chunks on demand, recording how much was read and
// whether the reader cancelled it. `endless` keeps producing chunks forever.
const streamedBody = ({chunks, endless = false}) => {
  const state = {pulledBytes: 0, cancelled: false};
  let index = 0;
  const stream = new ReadableStream({
    pull(controller) {
      const chunk = endless ? new Uint8Array(1024).fill(0x20) : chunks[index++];
      if (chunk === undefined) return controller.close();
      state.pulledBytes += chunk.byteLength;
      controller.enqueue(chunk);
    },
    cancel() { state.cancelled = true; },
  }, {highWaterMark: 0});
  return {stream, state};
};

test('oversized upstream bodies are cancelled at their byte cap instead of buffered', async () => {
  const originalFetch = globalThis.fetch;
  const bodies = [];
  const respond = () => {
    const body = streamedBody({endless: true});
    bodies.push(body.state);
    return new Response(body.stream);
  };
  try {
    globalThis.fetch = async () => respond();
    const pointer = await worker.fetch(new Request('https://justspeaktoit.com/alpha/download/arm64'), {});
    assert.equal(pointer.status, 503);
    assert.equal(await pointer.text(), 'Invalid Alpha pointer');

    const flatpak = await worker.fetch(new Request('https://justspeaktoit.com/linux/flatpak'), {});
    assert.equal(flatpak.headers.get('Location'), '/alpha/download/linux-x86_64');

    globalThis.fetch = async url => url.endsWith('/windows-installer-pointer.json')
      ? Response.json(installerPointer) : respond();
    const installer = await worker.fetch(
      new Request('https://justspeaktoit.com/alpha/windows/JustSpeakToIt.appinstaller'), {});
    assert.equal(installer.status, 503);
    assert.equal(await installer.text(), 'Invalid Windows installer');
  } finally {
    globalThis.fetch = originalFetch;
  }
  const caps = [4096, 16384, 65536];
  assert.equal(bodies.length, caps.length);
  bodies.forEach((body, index) => {
    assert.ok(body.cancelled, `body ${index} was not cancelled`);
    assert.ok(body.pulledBytes <= caps[index] + 1024, `body ${index} read ${body.pulledBytes} bytes`);
  });
});

test('a declared oversized length is refused before the body is read', async () => {
  const originalFetch = globalThis.fetch;
  const body = streamedBody({endless: true});
  try {
    globalThis.fetch = async () => new Response(body.stream, {headers: {'Content-Length': '5000'}});
    const response = await worker.fetch(new Request('https://justspeaktoit.com/alpha/download/arm64'), {});
    assert.equal(await response.text(), 'Invalid Alpha pointer');
  } finally {
    globalThis.fetch = originalFetch;
  }
  assert.ok(body.state.cancelled);
  assert.equal(body.state.pulledBytes, 0);
});

test('a body at its cap is accepted and multibyte text split across chunks survives', async () => {
  const encoded = new TextEncoder().encode(appInstaller.replace('<AppInstaller', '<!-- café --><AppInstaller'));
  const split = encoded.indexOf(0xc3) + 1;
  const originalFetch = globalThis.fetch;
  try {
    globalThis.fetch = async url => url.endsWith('/windows-installer-pointer.json')
      ? Response.json(installerPointer)
      : new Response(streamedBody({chunks: [encoded.slice(0, split), encoded.slice(split)]}).stream);
    const response = await worker.fetch(
      new Request('https://justspeaktoit.com/alpha/windows/JustSpeakToIt.appinstaller'), {});
    assert.equal(response.status, 200);
    assert.equal(await response.text(), new TextDecoder().decode(encoded));

    const pointer = new TextEncoder().encode(JSON.stringify({tag: 'alpha-build-7'}).padEnd(4096, ' '));
    globalThis.fetch = async () => new Response(streamedBody({chunks: [pointer]}).stream);
    const download = await worker.fetch(new Request('https://justspeaktoit.com/alpha/download/arm64'), {});
    assert.equal(download.status, 302);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test('a body that stalls after its headers ends at the deadline as unavailable', async () => {
  const response = await serveStalled('/alpha/download/arm64', async () =>
    new Response(new ReadableStream({pull() { return new Promise(() => {}); }})));
  assert.equal(response.status, 503);
  assert.equal(await response.text(), 'Alpha build not yet available');
});
