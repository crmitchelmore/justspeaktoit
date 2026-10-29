// Alpha is discoverable from the README only. Existing Stable static routes
// continue to resolve GitHub Latest. A single pointer prevents mixed feed/CLI releases.
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
    if (!Object.hasOwn(assets, path)) return env.ASSETS.fetch(request);
    const response = await fetch('https://github.com/crmitchelmore/justspeaktoit/releases/download/alpha-latest/alpha-pointer.json', {
      cf: {cacheTtl: 30}, headers: {'Accept': 'application/json'},
    });
    if (!response.ok) return new Response('Alpha build not yet available', {status: 503});
    let pointer;
    try { pointer = await response.json(); } catch {
      return new Response('Invalid Alpha pointer', {status: 503});
    }
    if (!pointer || typeof pointer !== 'object' || !/^alpha-build-[1-9][0-9]*$/.test(pointer.tag)) return new Response('Invalid Alpha pointer', {status: 503});
    const location = `https://github.com/crmitchelmore/justspeaktoit/releases/download/${pointer.tag}/${assets[path]}`;
    // Windows and Linux downloads exist only on Alphas whose desktop qualification
    // published them; never redirect to a missing asset.
    if (/^\/alpha\/download\/(windows|linux)-/.test(path)) {
      try {
        const probe = await fetch(location, {method: 'HEAD', redirect: 'manual', cf: {cacheTtl: 30}});
        if (probe.status !== 302) return new Response('Desktop Alpha build not yet available', {status: 503});
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
