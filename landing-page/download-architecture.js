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

if (typeof document !== "undefined" && typeof navigator !== "undefined") {
  enhanceMacDownloads(document, navigator);
}
