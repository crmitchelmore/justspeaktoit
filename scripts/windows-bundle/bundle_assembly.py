"""Assemble the Windows runtime bundle's entries and manifest from
authenticated inputs, optionally cross-checking every import table with
llvm-readobj."""
import pathlib
import subprocess
import sys
import tempfile

import windows_pe
import windows_targets
from bundle_notices import SUPPORTED_WINDOWS, microsoft_notice_text, notices_text, readme_text
from bundle_policy import (
    APPLICATION,
    EXECUTABLES,
    LOCAL_RUNTIME,
    MICROSOFT_RUNTIME,
    SWIFT_RUNTIME,
    BundleError,
    check_bundle_layout,
    resolve_closure,
    sha256,
    validate_executable,
)
from bundle_sources import read_swift_module

HERE = pathlib.Path(__file__).resolve().parent
if str(HERE.parent / "local-llm-runtime") not in sys.path:
    sys.path.insert(0, str(HERE.parent / "local-llm-runtime"))
import local_llm_package


# --- llvm-readobj cross-check ---------------------------------------------------------------
def parse_llvm_readobj_imports(text):
    """Static and delay-load imports of the native view in ``llvm-readobj --coff-imports`` output.

    For an ARM64X image llvm-readobj then prints its ARM64EC view under
    ``HybridObject``. A native ARM64 process loads only the native view, which
    is also the view windows_pe.py reads, so the hybrid section is not read.
    """
    static, delayed, section = [], [], None
    for line in text.splitlines():
        stripped = line.strip()
        if stripped == "HybridObject {":
            break
        if stripped == "Import {":
            section = static
        elif stripped == "DelayImport {":
            section = delayed
        elif stripped == "}":
            section = None
        elif section is not None and stripped.startswith("Name: "):
            section.append(stripped[len("Name: "):])
    return static, delayed


def cross_check_with_llvm(tool, name, data, image, log):
    with tempfile.TemporaryDirectory(prefix="jsti-bundle-readobj-") as scratch:
        path = pathlib.Path(scratch) / name
        path.write_bytes(data)
        text = subprocess.run([str(tool), "--coff-imports", str(path)], check=True, capture_output=True,
                              text=True).stdout
    static, delayed = parse_llvm_readobj_imports(text)
    expected = ([m.lower() for m in image.imports()], [m.lower() for m in image.delay_imports()])
    observed = ([m.lower() for m in static], [m.lower() for m in delayed])
    if expected != observed:
        raise BundleError("llvm-readobj import tables differ from the Python reader for " + name)
    log("llvm-readobj confirmed %d static and %d delay-load imports for %s" % (len(static), len(delayed), name))


def local_llm_source(runtime):
    return dict(runtime["manifest"], manifestSHA256=runtime["manifestSHA256"],
                libraryPath="LocalLLMRuntime/llama.dll", dependencies=runtime["dependencies"])


def local_llm_library_path(name, runtime):
    return "LocalLLMRuntime/llama.dll" if runtime and name.lower() == "llama.dll" else name


def verify_local_llm_payload(entries, source, architecture):
    prefix = "LocalLLMRuntime/"
    nested = {name[len(prefix):]: data for name, data in entries.items() if name.startswith(prefix)}
    if any(name.lower().startswith(prefix.lower()) and not name.startswith(prefix) for name in entries):
        raise BundleError("native local LLM folder casing differs from the canonical path")
    if source is None and not nested:
        return None
    try:
        runtime = local_llm_package.validate_entries(
            nested, "windows", "x86_64" if architecture == "x64" else architecture)
    except (OSError, ValueError) as error:
        raise BundleError("invalid nested native local LLM payload: " + str(error)) from error
    if source != local_llm_source(runtime):
        raise BundleError("native local LLM source record differs from its authenticated nested payload")
    return runtime


def assemble(application, swift, microsoft, licenses, app_license, policy, lock, cross_check, log, local_runtime=None,
             architecture="x64", local_llm=None):
    """Return ``(entries, manifest)``: bundle bytes keyed by path, and the manifest document."""
    target = windows_targets.target(architecture)
    executables = application.get("executables") or {}
    if set(executables) != set(EXECUTABLES):
        raise BundleError("bundle requires exactly the production SpeakWindows.exe and speak.exe roots")
    images = {name: validate_executable(executables[name], name, architecture, policy) for name in EXECUTABLES}
    for name in EXECUTABLES:
        if application["metadata"].get("executables", {}).get(name) != sha256(executables[name]):
            raise BundleError(name + " does not match the hash recorded by the build")
    executable = executables[APPLICATION]
    application_image = images[APPLICATION]
    local_modules = dict(local_runtime["modules"]) if local_runtime else {}
    if local_llm:
        try:
            local_llm = local_llm_package.validate_entries(
                local_llm["entries"], "windows", "x86_64" if architecture == "x64" else architecture)
        except (OSError, ValueError) as error:
            raise BundleError("cannot authenticate the native local LLM runtime: " + str(error)) from error
        if "llama.dll" in local_modules:
            raise BundleError("the transcription runtime collides with the native cleanup runtime")
        local_modules["llama.dll"] = {
            "name": "llama.dll", "bytes": local_llm["entries"]["llama.dll"],
            "provenance": local_llm_source(local_llm),
        }
    if local_modules and set(policy.local) != set(local_modules):
        raise BundleError("the runtime policy was not loaded with the local runtime modules")

    def read_imports(name, category):
        if category == "application":
            image = images[name]
        elif category == SWIFT_RUNTIME:
            image = windows_pe.PEImage(read_swift_module(swift, name)[0], name)
        elif category == MICROSOFT_RUNTIME:
            module = microsoft["modules"].get(name.lower())
            if module is None:
                raise BundleError("the pinned Visual C++ redistributable does not provide " + name)
            image = windows_pe.PEImage(module["bytes"], name)
        elif category == LOCAL_RUNTIME:
            image = windows_pe.PEImage(local_modules[name.lower()]["bytes"], name)
        else:
            raise BundleError("cannot read imports for " + name)
        images[name] = image
        return image.imports(), image.delay_imports()

    closure = resolve_closure(EXECUTABLES, read_imports, policy,
                              sorted(module["name"] for module in local_modules.values()))
    entries = dict(executables)
    files = [{"path": name, "bytes": len(executables[name]), "sha256": sha256(executables[name]),
              "source": "application", "imageArchitecture": images[name].architecture} for name in EXECUTABLES]
    for relative, data in sorted(application["resources"].items()):
        entries[relative] = data
        files.append({"path": relative, "bytes": len(data), "sha256": sha256(data), "source": "application-resources"})
    swift_files, microsoft_files, local_files = [], [], []
    for lower, entry in closure["bundled"].items():
        name = entry["name"]
        if entry["source"] == SWIFT_RUNTIME:
            data, provenance = read_swift_module(swift, name)
            swift_files.append(name)
        elif entry["source"] == LOCAL_RUNTIME:
            data, provenance = local_modules[lower]["bytes"], local_modules[lower]["provenance"]
            local_files.append(name)
        else:
            module = microsoft["modules"][lower]
            data, provenance = module["bytes"], module["provenance"]
            microsoft_files.append(name)
        image = images.get(name) or windows_pe.PEImage(data, name)
        if not image.runs_natively_on(architecture) or not image.is_dll:
            raise BundleError("%s is not a native %s DLL (it is %s)" % (name, architecture, image.architecture))
        version = image.version_info() or {}
        path = local_llm_library_path(name, local_llm)
        entries[path] = data
        files.append({"path": path, "bytes": len(data), "sha256": sha256(data), "source": entry["source"],
                      "fileVersion": version.get("fileVersion"), "imageArchitecture": image.architecture,
                      "provenance": provenance})
    if cross_check is not None:
        for name in list(EXECUTABLES) + swift_files + microsoft_files + local_files:
            data = entries[local_llm_library_path(name, local_llm)]
            cross_check_with_llvm(cross_check, name, data, images.get(name) or windows_pe.PEImage(data, name), log)
    if local_llm:
        for name in ("provisioning.json", "LICENSE.llama-cpp"):
            path, data = "LocalLLMRuntime/" + name, local_llm["entries"][name]
            entries[path] = data
            files.append({"path": path, "bytes": len(data), "sha256": sha256(data),
                          "source": "license" if name == "LICENSE.llama-cpp" else "native-local-llm-provenance",
                          "provenance": {"commit": local_llm_package.COMMIT, "license": "MIT"}})
    license_names = []
    for entry in licenses:
        path = "licenses/" + entry["name"]
        entries[path] = entry["data"]
        files.append({"path": path, "bytes": len(entry["data"]), "sha256": sha256(entry["data"]), "source": "license",
                      "provenance": {"url": entry["url"], "license": entry["license"], "covers": entry["covers"]}})
        license_names.append(entry["name"])
    if local_runtime:
        entries["licenses/LICENSE-whisper.cpp.txt"] = local_runtime["license"]
        files.append({"path": "licenses/LICENSE-whisper.cpp.txt", "bytes": len(local_runtime["license"]),
                      "sha256": sha256(local_runtime["license"]), "source": "license",
                      "provenance": {"url": local_runtime["manifest"]["repository"], "license": "MIT",
                                     "covers": "whisper.cpp and ggml runtime DLLs"}})
    app_license_name = "LICENSE-JustSpeakToIt.txt"
    generated = {
        "licenses/" + app_license_name: app_license,
        "licenses/NOTICE-microsoft-visual-cpp-runtime.txt": microsoft_notice_text(
            microsoft, lock, [(name, microsoft["modules"][name.lower()]) for name in microsoft_files]).encode(),
        "THIRD-PARTY-NOTICES.txt": notices_text(app_license_name, swift_files, microsoft_files, microsoft, lock, licenses,
                                                local_runtime, architecture, swift["pinFile"]).encode(),
        "README.txt": readme_text(application["metadata"], swift_files + microsoft_files, microsoft, local_runtime,
                                  architecture).encode(),
    }
    if local_llm:
        generated["README.txt"] += (
            b"\nNative on-device cleanup: CPU llama.cpp b6500 in LocalLLMRuntime/llama.dll. "
            b"Models are separate, explicit downloads. provisioning.json records built bytes, not model-quality "
            b"acceptance. No subprocess or remote fallback is used.\n")
        generated["THIRD-PARTY-NOTICES.txt"] += (
            "\nllama.cpp b6500 (commit " + local_llm_package.COMMIT + "), including ggml: "
            "LocalLLMRuntime/llama.dll\nMIT license: LocalLLMRuntime/LICENSE.llama-cpp\n").encode()
    for path, data in generated.items():
        entries[path] = data
        files.append({"path": path, "bytes": len(data), "sha256": sha256(data),
                      "source": "application-license" if path.endswith(app_license_name) else "generated"})
    files.sort(key=lambda item: item["path"])
    metadata = application["metadata"]
    manifest = {
        "schemaVersion": 1,
        "bundle": {"kind": "unsigned Windows %s developer runtime bundle" % target["displayName"],
                   "architecture": target["bundleArchitecture"],
                   "requires": SUPPORTED_WINDOWS[architecture][1] + "; the Universal CRT and other Windows modules come from the operating system",
                   "notInstaller": True, "codeSigned": False},
        "application": {"sourceCommit": metadata.get("sourceCommit"), "configuration": metadata.get("configuration"),
                        "target": metadata.get("target"), "appBuiltForTesting": metadata.get("appBuiltForTesting"),
                        "executableSHA256": sha256(executable), "swiftCompiler": metadata.get("swiftCompiler"),
                        "executables": {name: sha256(executables[name]) for name in EXECUTABLES},
                        "nativeCompiler": metadata.get("nativeCompiler"), "buildHost": metadata.get("host"),
                        "imageArchitecture": application_image.architecture},
        "files": files,
        "dependencies": {"bundled": closure["bundled"], "system": closure["system"],
                         "roots": closure["roots"],
                         "additionalRuntimeModules": policy.additional},
        "sources": {
            "swiftRuntime": {"installer": swift["installer"], "payloads": swift["payloads"],
                             "swiftVersion": swift["swiftVersion"], "fileLockSHA256": swift["lockSHA256"],
                             "bootstrapManifestSHA256": swift["bootstrapManifestSHA256"],
                             "installerPin": swift["pinFile"], "fileLock": swift.get("lockOrigin")},
            "microsoftRuntime": {"download": {key: lock[key] for key in ("name", "url", "sha256", "bytes", "permalink", "version")},
                                 "package": lock["packages"][target["visualCppPackage"]],
                                 "displayName": microsoft["displayName"], "productName": microsoft["productName"],
                                 "nonNativeFilesNotBundled": microsoft.get("skipped", [])},
            "licenses": [{key: entry[key] for key in ("name", "url", "sha256", "bytes", "license", "covers")} for entry in licenses],
            "localInferenceRuntime": None if not local_runtime else {
                key: local_runtime["manifest"].get(key)
                for key in ("runtime", "architecture", "version", "commit", "repository", "cmakeArguments", "compiler",
                            "vulkanSdk")
            } | {"manifestSHA256": local_runtime["manifestSHA256"],
                 "modules": sorted(name for name in local_files if name.lower() in local_runtime["modules"])},
        },
        "policy": policy.data,
        "verification": {"importReader": "windows_pe.py static and delay-load import directories",
                         "imageArchitecture": "every executable and DLL is an image a native %s process loads (%s); "
                                              "windows_pe.py reads the machine and the load configuration's hybrid "
                                              "metadata" % (target["displayName"], ", ".join(target["peImages"])),
                         "llvmReadobjCrossCheck": cross_check is not None,
                         "windowsEvidence": "scripts/windows-bundle/verify-windows-bundle.ps1 runs the bundle with an isolated PATH and records sampled loaded modules"},
    }
    if local_llm:
        manifest["sources"]["localLLMRuntime"] = local_llm_source(local_llm)
    check_bundle_layout(sorted(entries) + ["bundle-manifest.json"], policy)
    return entries, manifest
