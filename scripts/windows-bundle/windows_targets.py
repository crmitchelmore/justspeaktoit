"""The Windows architectures the developer build targets, defined once.

The bundle, local runtime, package and execution checks read these facts from
here so an architecture cannot be described differently by two scripts.
``peImages`` are the image architectures (see ``windows_pe``) a native process
of the target loads; ``processMachine`` is the IMAGE_FILE_MACHINE value
Windows reports for such a process.
"""
import json
import pathlib

import windows_pe

HERE = pathlib.Path(__file__).resolve().parent
CROSS_PINS = HERE.parent / "windows-cross" / "dependencies.json"
BUNDLE_PINS = HERE / "dependencies.json"

TARGETS = {
    "x64": {
        "displayName": "x64",
        "swiftTriple": "x86_64-unknown-windows-msvc",
        "bundleArchitecture": "x86_64",
        "processMachine": windows_pe.IMAGE_FILE_MACHINE_AMD64,
        "msixArchitecture": "x64",
        # Key of microsoftRuntime.packages in windows-bundle/dependencies.json.
        "visualCppPackage": "minimum",
        "swiftRuntimeLock": "swift-runtime-lock.json",
    },
    "arm64": {
        "displayName": "ARM64",
        "swiftTriple": "aarch64-unknown-windows-msvc",
        "bundleArchitecture": "aarch64",
        "processMachine": windows_pe.IMAGE_FILE_MACHINE_ARM64,
        "msixArchitecture": "arm64",
        "visualCppPackage": "arm64",
        "swiftRuntimeLock": "swift-runtime-lock-arm64.json",
    },
}
for _name, _target in TARGETS.items():
    _target["name"] = _name
    _target["peImages"] = sorted(windows_pe.NATIVE_IMAGES[_name])


def target(name):
    if name not in TARGETS:
        raise ValueError("unsupported Windows architecture %r; expected one of %s" % (name, ", ".join(sorted(TARGETS))))
    return TARGETS[name]


def for_bundle_architecture(value):
    """The target a bundle manifest's ``bundle.architecture`` names."""
    for entry in TARGETS.values():
        if entry["bundleArchitecture"] == value:
            return entry
    raise ValueError("unsupported bundle architecture %r" % (value,))


def swift_runtime_installer(architecture, cross=CROSS_PINS, bundle=BUNDLE_PINS):
    """``(Swift version, pin, pin file)`` of the official installer holding the architecture's runtime.

    x64 uses the cross compiler's installer. Other architectures pin a
    runtime-only installer in windows-bundle/dependencies.json.
    """
    target(architecture)
    lock = json.loads(pathlib.Path(cross).read_text(encoding="utf-8"))
    if architecture == "x64":
        pin = next(item for item in lock["downloads"] if item["name"].endswith("-windows10.exe"))
        return lock["swiftVersion"], pin, pathlib.Path(cross)
    pins = json.loads(pathlib.Path(bundle).read_text(encoding="utf-8")).get("swiftRuntimeInstallers", {})
    if architecture not in pins:
        raise ValueError("no Swift runtime installer is pinned for " + architecture)
    return lock["swiftVersion"], pins[architecture], pathlib.Path(bundle)


def installer_size_matches(pin, size):
    """Every installer pin records the exact byte count of the SHA-256-pinned download."""
    if not isinstance(pin.get("bytes"), int):
        raise ValueError("the installer pin for %s lacks its exact byte count" % pin.get("name"))
    return isinstance(size, int) and size == pin["bytes"]
