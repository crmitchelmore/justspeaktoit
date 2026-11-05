import test from "node:test";
import assert from "node:assert/strict";
import {
  classifyArchitecture,
  detectMacArchitecture,
  downloadForArchitecture,
  detectWindowsArchitecture,
  enhanceWindowsDownloads,
} from "./download-architecture.js";

test("classifies browser architecture hints", () => {
  assert.equal(classifyArchitecture("arm"), "arm64");
  assert.equal(classifyArchitecture("aarch64"), "arm64");
  assert.equal(classifyArchitecture("x86"), "intel");
  assert.equal(classifyArchitecture("x86_64"), "intel");
  assert.equal(classifyArchitecture(""), "unknown");
});

test("uses high-entropy hints on a Mac", async () => {
  const navigatorObject = {
    userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
    userAgentData: {
      getHighEntropyValues: async () => ({ architecture: "arm", bitness: "64" }),
    },
  };
  assert.equal(await detectMacArchitecture(navigatorObject), "arm64");
});

test("does not infer architecture from Safari's ambiguous MacIntel platform", async () => {
  assert.equal(await detectMacArchitecture({ platform: "MacIntel" }), "unknown");
});

test("falls back to the compatible universal download", () => {
  assert.equal(downloadForArchitecture("arm64"), "/download/mac");
  assert.equal(downloadForArchitecture("intel"), "/download/mac-intel");
  assert.equal(downloadForArchitecture("unknown"), "/download/mac-intel");
});

const windowsNavigator = (architecture) => ({
  userAgentData: {
    platform: "Windows",
    getHighEntropyValues: async () => ({ architecture, bitness: "64" }),
  },
});

function windowsDocument() {
  const link = { href: "/alpha/download/windows-x64", dataset: {}, textContent: "" };
  const note = { textContent: "" };
  return {
    link, note,
    querySelectorAll: (selector) => selector === "[data-auto-windows-download]" ? [link] : [note],
  };
}

test("Windows uses native ARM64 hints without guessing from a legacy UA", async () => {
  assert.equal(await detectWindowsArchitecture(windowsNavigator("arm")), "arm64");
  assert.equal(await detectWindowsArchitecture(windowsNavigator("x86")), "intel");
  assert.equal(await detectWindowsArchitecture({ platform: "Win32" }), "unknown");
  assert.equal(await detectWindowsArchitecture({ platform: "MacIntel" }), "unknown");
  assert.equal(await detectWindowsArchitecture({
    userAgentData: { platform: "Windows", getHighEntropyValues: async () => { throw Error("denied"); } },
  }), "unknown");
});

test("unavailable installer selects the native ZIP and explains extraction", async () => {
  for (const [architecture, suffix] of [["arm", "arm64"], ["x86", "x64"]]) {
    const document = windowsDocument();
    const result = await enhanceWindowsDownloads(document, windowsNavigator(architecture), async (url) => {
      assert.equal(url, "/alpha/windows/installer.json");
      return { ok: true, json: async () => ({ available: false }) };
    });
    assert.equal(result.download, `/alpha/download/windows-${suffix}`);
    assert.equal(document.link.href, result.download);
    assert.match(document.note.textContent, /Unsigned developer preview.*Extract all files/);
  }
});

test("unknown Windows architecture keeps an explicitly labelled x64 fallback", async () => {
  const document = windowsDocument();
  await enhanceWindowsDownloads(document, {}, async () => ({ ok: true, json: async () => ({ available: false }) }));
  assert.equal(document.link.href, "/alpha/download/windows-x64");
  assert.match(document.link.textContent, /choose ARM64 below/);
});

test("only qualified canonical installer metadata changes the installation action", async () => {
  const document = windowsDocument();
  await enhanceWindowsDownloads(document, windowsNavigator("arm"), async () => ({
    ok: true,
    json: async () => ({
      available: true, publisher: "CN=Example", version: "2026.1105.1200.0",
      appInstaller: "https://justspeaktoit.com/alpha/windows/JustSpeakToIt.appinstaller",
    }),
  }));
  assert.equal(document.link.href, "/alpha/windows/JustSpeakToIt.appinstaller");
  assert.equal(document.link.textContent, "Install Windows beta");
  assert.match(document.note.textContent, /Publisher: CN=Example.*Windows chooses your architecture/);
});

test("network, HTTP and malformed metadata failures retain ZIP recovery with an explicit notice", async () => {
  for (const fetch of [
    async () => { throw Error("offline"); },
    async () => ({ ok: false }),
    async () => ({ ok: true, json: async () => { throw Error("invalid JSON"); } }),
    async () => ({ ok: true, json: async () => ({}) }),
    async () => ({ ok: true, json: async () => ({ available: true, appInstaller: "https://example.com/untrusted" }) }),
  ]) {
    const document = windowsDocument();
    await enhanceWindowsDownloads(document, windowsNavigator("arm"), fetch);
    assert.equal(document.link.href, "/alpha/download/windows-arm64");
    assert.match(document.note.textContent, /Installer status could not be checked/);
  }
});

test("installer discovery is bounded and leaves a working download when aborted", async () => {
  const document = windowsDocument();
  await enhanceWindowsDownloads(document, windowsNavigator("x86"), async (_url, { signal }) => {
    return new Promise((_resolve, reject) => signal.addEventListener("abort", () => reject(Error("timeout")), { once: true }));
  });
  assert.equal(document.link.href, "/alpha/download/windows-x64");
  assert.match(document.note.textContent, /could not be checked/);
});

test("pages without Windows controls do not make installer requests", async () => {
  await enhanceWindowsDownloads({ querySelectorAll: () => [] }, {}, () => assert.fail("Unexpected fetch"));
});
