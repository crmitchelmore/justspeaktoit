"""The README and licence notices the Windows runtime bundle ships, generated
from its manifest inputs so every bundled file has stated licence terms."""
import windows_targets
from bundle_policy import sha256

# Where each architecture's bundle runs, as the README and manifest state it.
SUPPORTED_WINDOWS = {
    "x64": (["automatic-update channel. It runs from this folder on 64-bit Windows 10 or",
             "later without installing the Swift toolchain or Visual C++ redistributable:"],
            "64-bit Windows 10 or later"),
    "arm64": (["automatic-update channel. It runs from this folder on Windows 10 or later on",
               "an ARM64 PC without installing the Swift toolchain or Visual C++ redistributable:"],
              "Windows 10 or later on ARM64"),
}


def microsoft_runtime_name(microsoft, architecture):
    # The x64 package is the redistributable's own; ARM64 names the package inside it.
    return microsoft["displayName"] if architecture == "x64" else microsoft["productName"]


def readme_text(metadata, closure_names, microsoft, local_runtime=None, architecture="x64"):
    commit = metadata.get("sourceCommit") or "main"
    return "\n".join([
        "Just Speak to It - Windows " + windows_targets.target(architecture)["displayName"] + " developer runtime bundle",
        "",
        "This is an unsigned developer build, not an installer, signed release or",
    ] + SUPPORTED_WINDOWS[architecture][0] + [
        "the runtime DLLs the application imports sit beside SpeakWindows.exe.",
        "",
        "Run SpeakWindows.exe, or pass --bundle-self-test / --self-test / --ui-smoke-test. The smoke tests",
        "use no microphone and no real provider API key. Settings and recordings are",
        "stored under %LOCALAPPDATA%\\JustSpeakToIt. Because the executable is not",
        "code-signed, Windows SmartScreen may ask for confirmation before it runs.",
        "",
        "The real automation CLI is .\\speak.exe (not the GUI executable).",
        "Run .\\speak.exe --help or .\\speak.exe --version without starting the app.",
        "Other CLI commands use the running app's same-user automation pipe.",
        "This portable bundle does not add anything to PATH.",
        "",
        "The canonical app icon is embedded in SpeakWindows.exe. To create a",
        "per-user Start menu shortcut after extracting to a permanent folder, run:",
        "$shell = New-Object -ComObject WScript.Shell",
        "$link = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Programs')) 'Just Speak to It Developer.lnk'))",
        "$link.TargetPath = (Resolve-Path .\\SpeakWindows.exe).Path",
        "$link.WorkingDirectory = Split-Path $link.TargetPath",
        "$link.IconLocation = $link.TargetPath + ',0'",
        "$link.Save()",
        "Run those commands in PowerShell from the extracted bundle folder.",
        "This shortcut is optional; the bundle does not install or enable autostart.",
        "",
        "Bundled runtime: Swift 6.2.3 (" + ", ".join(name for name in closure_names if not name.lower().startswith(("msvcp", "vcruntime", "concrt", "vccorlib", "vcamp", "vcomp"))) + ")",
        "and " + microsoft_runtime_name(microsoft, architecture) + ".",
        "",
    ] + ([
        "On-device transcription: whisper.cpp " + local_runtime["manifest"]["version"] + " (whisper.dll and the",
        "ggml DLLs). It uses a Vulkan GPU when the graphics driver provides vulkan-1.dll",
        "and the CPU otherwise. Models are downloaded in the app (Settings > Local models).",
        "",
    ] if local_runtime and local_runtime["manifest"]["vulkanSdk"] else [
        "On-device transcription: whisper.cpp " + local_runtime["manifest"]["version"] + " (whisper.dll and the",
        "ggml DLLs). It runs on the CPU; this build has no GPU backend. Models are",
        "downloaded in the app (Settings > Local models).",
        "",
    ] if local_runtime else []) + [
        "bundle-manifest.json lists every file with its SHA-256 and origin;",
        "THIRD-PARTY-NOTICES.txt and the licenses folder hold the licence terms.",
        "",
        "Current parity limits and verification evidence:",
        "https://github.com/crmitchelmore/justspeaktoit/blob/" + commit + "/Docs/windows-runtime-bundle.md",
        "",
    ])


def notices_text(app_license_name, swift_files, microsoft_files, microsoft, lock, licenses, local_runtime=None,
                 architecture="x64", swift_pin_file="scripts/windows-cross/dependencies.json"):
    lines = ["THIRD-PARTY NOTICES", "", "Just Speak to It is distributed under the MIT License (licenses/" + app_license_name + ").", ""]
    swift_license = next(entry for entry in licenses if entry["name"] == "LICENSE-swift.txt")
    installer = "Windows" if architecture == "x64" else "Windows " + windows_targets.target(architecture)["displayName"]
    lines += ["Swift 6.2.3 runtime (swift.org): " + ", ".join(swift_files),
              "  Licence: " + swift_license["license"] + " (licenses/LICENSE-swift.txt)",
              "  Source: official swift-6.2.3-RELEASE " + installer + " installer runtime package (rtl.msi), pinned in "
              + swift_pin_file, ""]
    icu = next((entry for entry in licenses if entry["name"] == "LICENSE-icu.txt"), None)
    if icu is not None:
        lines += ["_FoundationICU.dll additionally contains " + icu["covers"].split(" compiled")[0] + ":",
                  "  Licence: " + icu["license"] + " (licenses/LICENSE-icu.txt)", ""]
    for entry in licenses:
        if entry["name"] in ("LICENSE-curl.txt", "LICENSE-zlib.txt", "LICENSE-miniz.txt"):
            lines += [entry["covers"], "  Licence: " + entry["license"] + " (licenses/" + entry["name"] + ")", ""]
    lines += [microsoft["displayName"] + ": " + ", ".join(microsoft_files),
              "  Files are unmodified copies from Microsoft's official " + lock["name"] + " (" + microsoft["productName"] + ").",
              "  Redistributed under the Visual Studio 2022 Community licence's Distributable Code terms for this open-source application:",
              "  https://learn.microsoft.com/en-us/visualstudio/releases/2022/redistribution",
              "  https://visualstudio.microsoft.com/license-terms/vs2022-ga-community/",
              "  Runtime licence terms: https://aka.ms/VCRedistLicense (licenses/NOTICE-microsoft-visual-cpp-runtime.txt)", ""]
    if local_runtime:
        manifest = local_runtime["manifest"]
        built = "  Built from source by scripts/windows-local-runtime/build-whisper-runtime.py with " + str(
            manifest.get("compiler"))
        lines += ["whisper.cpp " + manifest["version"] + " (commit " + manifest["commit"] + "), including ggml: "
                  + ", ".join(sorted(module["name"] for module in local_runtime["modules"].values())),
                  "  Licence: MIT (licenses/LICENSE-whisper.cpp.txt)"]
        if manifest["vulkanSdk"]:
            lines += [built + "; the Vulkan SDK " + manifest["vulkanSdk"]["version"] + " was used at build time only.",
                      "  vulkan-1.dll is not redistributed: it comes from the graphics driver when present.", ""]
        else:
            lines += [built + "; CPU backend only, no GPU backend.", ""]
    lines += ["Windows operating-system modules (kernel32, user32, the Universal CRT and other API sets) are not redistributed.", ""]
    return "\n".join(lines)


def microsoft_notice_text(microsoft, lock, files):
    lines = ["Microsoft Visual C++ Runtime files included in this bundle", "",
             "Package: " + microsoft["displayName"], "Product: " + microsoft["productName"],
             "Official download: " + lock["url"], "Permalink: " + lock["permalink"],
             "SHA-256: " + lock["sha256"], "Size: %d bytes" % lock["bytes"], "", "Files:"]
    for name, module in files:
        provenance = module["provenance"]
        lines.append("  %s  version %s  SHA-256 %s" % (name, provenance["fileVersion"], sha256(module["bytes"])))
    lines += ["", "These files are unmodified. Microsoft permits licensed Visual Studio users to copy and distribute",
              "the Visual C++ Runtime files with their programs; see",
              "https://learn.microsoft.com/en-us/visualstudio/releases/2022/redistribution and",
              "https://visualstudio.microsoft.com/license-terms/vs2022-ga-community/. The runtime's licence terms",
              "are published at https://aka.ms/VCRedistLicense. The download was read as data only: no installer,",
              "MSI package or custom action was executed while extracting these files.", ""]
    return "\n".join(lines)
