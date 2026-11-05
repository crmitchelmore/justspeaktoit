const ARM64_DOWNLOAD = "/download/mac";
const UNIVERSAL_DOWNLOAD = "/download/mac-intel";

export function classifyArchitecture(value) {
  const architecture = String(value || "").toLowerCase();
  if (/arm|aarch64/.test(architecture)) return "arm64";
  if (/x86|x64|amd64|ia32/.test(architecture)) return "intel";
  return "unknown";
}

export async function detectMacArchitecture(navigatorObject) {
  const userAgent = `${navigatorObject?.userAgent || ""} ${navigatorObject?.platform || ""}`;
  if (!/Macintosh|MacIntel|MacPPC|Mac68K/i.test(userAgent)) return "unknown";

  const userAgentData = navigatorObject?.userAgentData;
  if (!userAgentData?.getHighEntropyValues) return "unknown";

  try {
    const hints = await userAgentData.getHighEntropyValues(["architecture", "bitness"]);
    return classifyArchitecture(hints.architecture);
  } catch {
    return "unknown";
  }
}

export function downloadForArchitecture(architecture) {
  // Universal is the safe fallback: it contains both x86_64 and arm64. Safari
  // deliberately does not expose reliable CPU architecture information.
  return architecture === "arm64" ? ARM64_DOWNLOAD : UNIVERSAL_DOWNLOAD;
}

export async function enhanceMacDownloads(documentObject, navigatorObject) {
  const architecture = await detectMacArchitecture(navigatorObject);
  const download = downloadForArchitecture(architecture);
  const label = architecture === "arm64"
    ? "Apple Silicon"
    : architecture === "intel"
      ? "Intel"
      : "Universal compatible";

  documentObject.querySelectorAll("[data-auto-mac-download]").forEach((link) => {
    link.href = download;
    link.dataset.detectedArchitecture = architecture;
    link.setAttribute("aria-label", `Download Just Speak to It for ${label}`);
  });
  documentObject.querySelectorAll("[data-download-architecture]").forEach((element) => {
    element.textContent = label;
  });
  return { architecture, download };
}

export async function detectWindowsArchitecture(navigatorObject) {
  const platform = `${navigatorObject?.userAgentData?.platform || ""} ${navigatorObject?.userAgent || ""} ${navigatorObject?.platform || ""}`;
  if (!/Windows|Win32|Win64/i.test(platform)) return "unknown";
  if (!navigatorObject?.userAgentData?.getHighEntropyValues) return "unknown";
  try {
    const hints = await navigatorObject.userAgentData.getHighEntropyValues(["architecture", "bitness"]);
    return classifyArchitecture(hints.architecture);
  } catch {
    return "unknown";
  }
}

export async function enhanceWindowsDownloads(documentObject, navigatorObject, fetchObject = globalThis.fetch) {
  const links = documentObject.querySelectorAll("[data-auto-windows-download]");
  if (!links.length) return;
  const architecture = await detectWindowsArchitecture(navigatorObject);
  const arch = architecture === "arm64" ? "arm64" : "x64";
  const label = architecture === "unknown" ? "x64 ZIP (or choose ARM64 below)" : `${arch === "arm64" ? "ARM64" : "x64"} ZIP`;
  let download = `/alpha/download/windows-${arch}`;
  let action = `Download Windows ${label}`;
  let note = "Unsigned developer preview. Extract all files before opening SpeakWindows.exe. No Swift installation or automatic updates.";
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 3000);
  try {
    const response = await fetchObject("/alpha/windows/installer.json", { signal: controller.signal });
    if (!response.ok) throw new Error("Installer availability request failed");
    const installer = await response.json();
    if (installer?.available === true) {
      if (installer.appInstaller !== "https://justspeaktoit.com/alpha/windows/JustSpeakToIt.appinstaller"
        || typeof installer.publisher !== "string" || !installer.publisher
        || typeof installer.version !== "string" || !installer.version) {
        throw new Error("Invalid installer metadata");
      }
      download = "/alpha/windows/JustSpeakToIt.appinstaller";
      action = "Install Windows beta";
      note = `Version ${installer.version}. Publisher: ${installer.publisher}. Open the downloaded App Installer file; Windows chooses your architecture and checks for updates.`;
    } else if (installer?.available !== false) {
      throw new Error("Invalid installer availability");
    }
  } catch {
    note = "Installer status could not be checked. The unsigned ZIP links remain available; extract all files before opening SpeakWindows.exe. ZIP builds have no automatic updates.";
  } finally {
    clearTimeout(timeout);
  }
  links.forEach((link) => {
    link.href = download;
    link.textContent = action;
    link.dataset.detectedArchitecture = architecture;
  });
  documentObject.querySelectorAll("[data-windows-download-note]").forEach((element) => {
    element.textContent = note;
  });
  return { architecture, download };
}

if (typeof document !== "undefined" && typeof navigator !== "undefined") {
  enhanceMacDownloads(document, navigator);
  enhanceWindowsDownloads(document, navigator);
}
