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
const pointerMaxBytes = 4096;

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
 * Reads a small JSON pointer from the alpha-latest release. Returns
 * {unavailable} when it cannot be fetched (missing, network failure or
 * deadline), {invalid} when it is too large or not JSON, otherwise {value}.
 */
async function fetchPointer(name) {
  let text;
  try {
    text = await fetchWithin(`${release}/alpha-latest/${name}`,
      {cf: {cacheTtl: 30}, headers: {'Accept': 'application/json'}},
      response => response.ok ? response.text() : null);
  } catch {
    return {unavailable: true};
  }
  if (text === null) return {unavailable: true};
  if (text.length > pointerMaxBytes) return {invalid: true};
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
          return response.text();
        });
    } catch {
      return new Response('Windows installer not yet available', {status: 503});
    }
    if (body.length > 65536 || !body.includes(`Uri="https://justspeaktoit.com${appInstallerPath}"`)) {
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
      response => response.ok ? response.text() : null);
    if (body !== null) {
      if (body.length <= 16384 && body.startsWith(`${header}\n`) && body.includes('\nGPGKey=')) {
        return new Response(body, {headers: {
          'Content-Type': type,
          'Content-Disposition': `attachment; filename="${file}"`,
          'Cache-Control': 'public, max-age=60',
          'X-Content-Type-Options': 'nosniff',
        }});
      }
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

export default {
  async fetch(request, env) {
    const path = new URL(request.url).pathname;
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
