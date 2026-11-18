// Alpha is discoverable from the README only. Existing Stable static routes
// continue to resolve GitHub Latest. A single pointer prevents mixed feed/CLI releases.
const release = 'https://github.com/crmitchelmore/justspeaktoit/releases/download';
const appInstallerPath = '/alpha/windows/JustSpeakToIt.appinstaller';
const appInstallerAsset = 'JustSpeakToIt.appinstaller';
const alphaTag = /^alpha-build-[1-9][0-9]*$/;
// Every upstream fetch and its body read share one deadline, so a stalled
// GitHub or Pages response becomes a controlled answer instead of holding the
// request open until the platform's own limit.
const upstreamTimeoutMs = 5000;
// Byte caps for upstream bodies, enforced while streaming so an oversized or
// endless body is cancelled at the cap instead of being buffered first.
const pointerMaxBytes = 4096;
const appInstallerMaxBytes = 65536;
const flatpakDescriptorMaxBytes = 16384;
/** What `readText` returns when a body exceeds its cap. */
const tooLarge = Symbol('tooLarge');

/**
 * Fetches `url` and reads the response with `read` within the upstream deadline.
 * On timeout the request is aborted and this rejects, like a network failure.
 */
async function fetchWithin(url, init, read) {
  const controller = new AbortController();
  let timer;
  const deadline = new Promise((_, reject) => {
    timer = setTimeout(() => {
      controller.abort();
      reject(new Error('Upstream deadline reached'));
    }, upstreamTimeoutMs);
  });
  try {
    return await Promise.race([fetch(url, {...init, signal: controller.signal}).then(read), deadline]);
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Reads a response body as UTF-8 text, counting bytes as they arrive. Returns
 * `tooLarge` and cancels the body as soon as it passes `maxBytes`, so the
 * Worker never holds more than the cap. A declared oversized length is
 * refused before reading.
 */
async function readText(response, maxBytes) {
  if (Number(response.headers.get('Content-Length')) > maxBytes) {
    response.body?.cancel().catch(() => {});
    return tooLarge;
  }
  if (response.body === null) return '';
  const reader = response.body.getReader();
  const chunks = [];
  let total = 0;
  for (;;) {
    const {done, value} = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maxBytes) {
      reader.cancel().catch(() => {});
      return tooLarge;
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  // Decoding once keeps a multibyte character split across chunks intact.
  return new TextDecoder().decode(bytes);
}

/**
 * Reads a small JSON pointer from the alpha-latest release. Returns
 * {unavailable} when it cannot be fetched (missing, network failure or
 * deadline), {invalid} when it is too large or not JSON, otherwise {value}.
 */
async function fetchPointer(name) {
  let text;
  try {
    text = await fetchWithin(`${release}/alpha-latest/${name}`,
      {cf: {cacheTtl: 30}, headers: {'Accept': 'application/json'}},
      response => response.ok ? readText(response, pointerMaxBytes) : null);
  } catch {
    return {unavailable: true};
  }
  if (text === null) return {unavailable: true};
  if (text === tooLarge) return {invalid: true};
  try {
    return {value: JSON.parse(text)};
  } catch {
    return {invalid: true};
  }
}

// The Alpha pointer keeps its original format ({tag, build, source}); only
// the tag routes downloads, so only the tag is required.
function isAlphaPointer(pointer) {
  return pointer !== null && typeof pointer === 'object' && alphaTag.test(pointer.tag);
}

// The Windows installer pointer is versioned, and installer.json echoes its
// fields, so every field it publishes must be present and well formed.
function isInstallerPointer(pointer) {
  return pointer !== null && typeof pointer === 'object' && pointer.schemaVersion === 1
    && alphaTag.test(pointer.tag) && /^[0-9]{1,5}(\.[0-9]{1,5}){3}$/.test(pointer.version)
    && typeof pointer.build === 'string' && /^[0-9A-Za-z._-]{1,64}$/.test(pointer.build)
    && typeof pointer.publisher === 'string' && pointer.publisher.length > 0;
}

// The signed Windows beta installer advances its own pointer only after the
// published App Installer file installed on clean x64 and ARM64 runners, so it
// can lag the Alpha pointer and is absent until a publisher is configured.
async function windowsInstaller() {
  const {value} = await fetchPointer('windows-installer-pointer.json');
  return isInstallerPointer(value ?? null) ? value : null;
}

const windowsInstallerRoutes = {
  // App Installer reads this file, installs the bundle for the PC's architecture
  // and checks this same URL for updates. The ms-appinstaller: protocol is
  // disabled by default, so the file is a download rather than a protocol link.
  [appInstallerPath]: async installer => {
    if (!installer) return new Response('Windows installer not yet available', {status: 503});
    let body;
    try {
      body = await fetchWithin(`${release}/${installer.tag}/${appInstallerAsset}`, {cf: {cacheTtl: 30}},
        response => {
          if (!response.ok) throw Error('missing');
          return readText(response, appInstallerMaxBytes);
        });
    } catch {
      return new Response('Windows installer not yet available', {status: 503});
    }
    if (body === tooLarge || !body.includes(`Uri="https://justspeaktoit.com${appInstallerPath}"`)) {
      return new Response('Invalid Windows installer', {status: 503});
    }
    return new Response(body, {headers: {
      'Content-Type': 'application/appinstaller',
      'Content-Disposition': `attachment; filename="${appInstallerAsset}"`,
      'Cache-Control': 'public, max-age=60',
      'X-Content-Type-Options': 'nosniff',
    }});
  },
  // One architecture-neutral CTA: the installer when qualified, otherwise the
  // developer ZIP for the requested architecture.
  '/alpha/download/windows': async (installer, url) => {
    const location = installer ? appInstallerPath
      : `/alpha/download/windows-${url.searchParams.get('arch') === 'arm64' ? 'arm64' : 'x64'}`;
    return new Response(null, {status: 302, headers: {Location: location, 'Cache-Control': 'public, max-age=30'}});
  },
  '/alpha/windows/installer.json': async installer => Response.json(installer ? {
    available: true, channel: 'beta', tag: installer.tag, build: installer.build, version: installer.version,
    publisher: installer.publisher, appInstaller: `https://justspeaktoit.com${appInstallerPath}`,
  } : {available: false, channel: 'beta'}, {headers: {'Cache-Control': 'public, max-age=30'}}),
};

// The Android beta APK pointer is advanced by alpha-release.yml only after the
// signed APK is attached to a public Alpha, so it can lag the Alpha pointer.
const androidApk = 'JustSpeakToIt-android.apk';

async function androidDownload() {
  const {value} = await fetchPointer('android-pointer.json');
  if (value === undefined || value === null || typeof value !== 'object' || value.schemaVersion !== 1
    || !alphaTag.test(value.tag) || value.asset !== androidApk) {
    return new Response('Android beta not yet available', {status: 503});
  }
  return new Response(null, {status: 302, headers: {
    Location: `${release}/${value.tag}/${androidApk}`,
    'Cache-Control': 'public, max-age=30',
  }});
}

// The signed Linux Flatpak repository lives on its own static Pages project,
// published by linux-flatpak-repo.yml. These stable URLs serve its install
// descriptors; until a repository is published they fall back to the
// single-file Alpha bundle so the Linux CTA never breaks.
const flatpakSite = 'https://justspeaktoit-flatpak.pages.dev';
const flatpakRoutes = {
  '/linux/flatpak': {file: 'com.justspeaktoit.JustSpeakToIt.flatpakref', header: '[Flatpak Ref]',
    type: 'application/vnd.flatpak.ref'},
  '/linux/justspeaktoit.flatpakrepo': {file: 'justspeaktoit.flatpakrepo', header: '[Flatpak Repo]',
    type: 'application/vnd.flatpak.repo'},
};

async function flatpakDescriptor({file, header, type}) {
  try {
    const body = await fetchWithin(`${flatpakSite}/${file}`, {cf: {cacheTtl: 60}},
      response => response.ok ? readText(response, flatpakDescriptorMaxBytes) : null);
    if (typeof body === 'string' && body.startsWith(`${header}\n`) && body.includes('\nGPGKey=')) {
      return new Response(body, {headers: {
        'Content-Type': type,
        'Content-Disposition': `attachment; filename="${file}"`,
        'Cache-Control': 'public, max-age=60',
        'X-Content-Type-Options': 'nosniff',
      }});
    }
  } catch {
    // Fall through to the bundle.
  }
  return new Response(null, {status: 302, headers: {
    Location: '/alpha/download/linux-x86_64', 'Cache-Control': 'public, max-age=30',
  }});
}

// The Alpha every Mac, CLI and desktop download resolves through. Returns the
// pointer, or the controlled 503 to serve: unavailable when the pointer cannot
// be fetched in time (including a network failure), invalid when it does not
// parse or match the Alpha pointer format.
async function alphaPointer() {
  const pointer = await fetchPointer('alpha-pointer.json');
  if (pointer.unavailable) return new Response('Alpha build not yet available', {status: 503});
  if (pointer.invalid || !isAlphaPointer(pointer.value)) return new Response('Invalid Alpha pointer', {status: 503});
  return pointer.value;
}

// CloudKit Console accepts only https:// (or a custom scheme) as an API
// token's sign-in callback, so the token's registered callback is this page,
// and it forwards Apple's redirect to the loopback listener the Windows, Linux
// and Android apps open only while sign-in runs. Only the single
// ckWebAuthToken goes on; nothing else from the query is kept, logged or echoed.
const cloudKitSignInPath = '/cloudkit-sign-in';
const cloudKitLoopbackCallback = 'http://127.0.0.1:47823/cloudkit-sign-in';
const cloudKitTokenPattern = /^[A-Za-z0-9+/=_.~:|-]{1,4096}$/;
const cloudKitHeaders = {
  'Cache-Control': 'no-store',
  'Referrer-Policy': 'no-referrer',
  'X-Robots-Tag': 'noindex',
};

/**
 * The one `ckWebAuthToken` in a raw query string, percent-decoded with `+`
 * kept as `+` (as the apps read it), or null when it is missing, empty,
 * repeated, malformed or not a plausible token.
 */
function cloudKitWebAuthToken(search) {
  const tokens = [];
  for (const item of search.replace(/^\?/, '').split('&')) {
    const separator = item.indexOf('=');
    const rawName = separator === -1 ? item : item.slice(0, separator);
    let name;
    try {
      name = decodeURIComponent(rawName);
    } catch {
      continue;
    }
    if (name !== 'ckWebAuthToken') continue;
    if (separator === -1) return null;
    try {
      tokens.push(decodeURIComponent(item.slice(separator + 1)));
    } catch {
      return null;
    }
  }
  return tokens.length === 1 && cloudKitTokenPattern.test(tokens[0]) ? tokens[0] : null;
}

function cloudKitSignIn(request, url) {
  if (request.method !== 'GET' && request.method !== 'HEAD') {
    return new Response(null, {status: 405, headers: {...cloudKitHeaders, Allow: 'GET, HEAD'}});
  }
  const token = cloudKitWebAuthToken(url.search);
  if (token === null) {
    const body = request.method === 'HEAD' ? null : '<!doctype html><meta charset="utf-8">'
      + '<meta name="viewport" content="width=device-width, initial-scale=1">'
      + '<title>iCloud sign-in did not finish</title>'
      + '<p>This iCloud sign-in link is incomplete or has expired. '
      + 'Start iCloud sign-in again from Just Speak to It.</p>';
    return new Response(body, {status: 400, headers: {
      ...cloudKitHeaders, 'Content-Type': 'text/html; charset=utf-8', 'X-Content-Type-Options': 'nosniff',
    }});
  }
  return new Response(null, {status: 302, headers: {
    ...cloudKitHeaders,
    Location: `${cloudKitLoopbackCallback}?ckWebAuthToken=${encodeURIComponent(token)}`,
  }});
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname;
    if (path === cloudKitSignInPath) return cloudKitSignIn(request, url);
    const assets = {
      '/alpha/appcast.xml': 'appcast.xml',
      '/alpha/appcast-arm64.xml': 'appcast-arm64.xml',
      '/alpha/download/arm64': 'JustSpeakToItAlpha-arm64.dmg',
      '/alpha/download/universal': 'JustSpeakToItAlpha-universal.dmg',
      '/alpha/cli/speak-cli-manifest.json': 'speak-cli-manifest.json',
      '/alpha/cli/speak-cli-manifest.json.sig': 'speak-cli-manifest.json.sig',
      '/alpha/download/windows-x64': 'JustSpeakToIt-windows-x64-developer.zip',
      '/alpha/download/windows-arm64': 'JustSpeakToIt-windows-arm64-developer.zip',
      '/alpha/download/linux-x86_64': 'JustSpeakToIt-linux-x86_64.flatpak',
    };
    if (Object.hasOwn(flatpakRoutes, path)) return flatpakDescriptor(flatpakRoutes[path]);
    if (path === '/alpha/download/android') return androidDownload();
    if (Object.hasOwn(windowsInstallerRoutes, path)) {
      const installer = await windowsInstaller();
      return windowsInstallerRoutes[path](installer, new URL(request.url));
    }
    if (!Object.hasOwn(assets, path)) return env.ASSETS.fetch(request);
    const pointer = await alphaPointer();
    if (pointer instanceof Response) return pointer;
    const location = `${release}/${pointer.tag}/${assets[path]}`;
    // Windows and Linux downloads exist only on Alphas whose desktop qualification
    // published them; never redirect to a missing asset.
    if (/^\/alpha\/download\/(windows|linux)-/.test(path)) {
      try {
        const status = await fetchWithin(location, {method: 'HEAD', redirect: 'manual', cf: {cacheTtl: 30}},
          probe => probe.status);
        if (status !== 302) return new Response('Desktop Alpha build not yet available', {status: 503});
      } catch {
        return new Response('Desktop Alpha build not yet available', {status: 503});
      }
    }
    return new Response(null, {status: 302, headers: {
      Location: location,
      'Cache-Control': 'public, max-age=30',
    }});
  },
};
