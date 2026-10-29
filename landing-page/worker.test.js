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
