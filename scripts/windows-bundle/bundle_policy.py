"""Packaging policy for the Windows runtime bundle: module categories, the
import closure from the production roots, executable admission, bundle path
safety and the deterministic archive. Nothing here reads build inputs."""
import fnmatch
import hashlib
import json
import pathlib
import re
import zipfile

import windows_pe
import windows_targets

HERE = pathlib.Path(__file__).resolve().parent
APPLICATION = "SpeakWindows.exe"
CLI = "speak.exe"
EXECUTABLES = (APPLICATION, CLI)
ZIP_TIMESTAMP = (1980, 1, 1, 0, 0, 0)
RESERVED_NAMES = {"con", "prn", "aux", "nul"} | {"com%d" % n for n in range(1, 10)} | {"lpt%d" % n for n in range(1, 10)}
SYSTEM_MODULE, SWIFT_RUNTIME, MICROSOFT_RUNTIME, TEST_MODULE, UNKNOWN_MODULE = (
    "system", "swift-runtime", "microsoft-runtime", "test", "unknown")
# In-process transcription/cleanup DLLs admitted as runtime-loaded sources.
LOCAL_RUNTIME = "local-inference-runtime"


class BundleError(Exception):
    """A bundle input violates the packaging policy; nothing is written."""


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def digest_file(path):
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            hasher.update(chunk)
    return hasher.hexdigest()


class Log:
    def __init__(self, path=None):
        self.path = path
        if path is not None:
            path.write_text("", encoding="utf-8")

    def __call__(self, message):
        print(message, flush=True)
        if self.path is not None:
            with self.path.open("a", encoding="utf-8") as stream:
                stream.write(message + "\n")


# --- policy ---------------------------------------------------------------------
class Policy:
    def __init__(self, data, local_runtime=()):
        self.data = data
        self.local = {name.lower(): name for name in local_runtime}
        self.system = {name.lower() for name in data["windowsSystemModules"]}
        self.api_sets = [re.compile(pattern) for pattern in data["windowsApiSetPatterns"]]
        self.swift = {name.lower(): name for name in data["swiftRuntimeModules"]}
        self.microsoft = {name.lower(): name for name in data["microsoftRuntimeModules"]}
        self.tests = {name.lower() for name in data["testModules"]}
        self.additional = [name for name in data["additionalRuntimeModules"]]
        self.forbidden = [pattern.lower() for pattern in data["forbiddenBundlePatterns"]]
        overlap = (self.system & set(self.swift)) | (self.system & set(self.microsoft)) | (set(self.swift) & set(self.microsoft))
        overlap |= self.tests & (self.system | set(self.swift) | set(self.microsoft))
        overlap |= set(self.local) & (self.system | set(self.swift) | set(self.microsoft) | self.tests)
        if overlap:
            raise BundleError("runtime policy lists a module in more than one category: " + ", ".join(sorted(overlap)))
        for name in self.additional:
            if self.classify(name) not in (SWIFT_RUNTIME, MICROSOFT_RUNTIME):
                raise BundleError("additionalRuntimeModules must name a pinned runtime module: " + name)

    @classmethod
    def load(cls, path=HERE / "runtime-policy.json", local_runtime=()):
        return cls(json.loads(path.read_text(encoding="utf-8")), local_runtime)

    def classify(self, module):
        lower = module.lower()
        if lower in self.tests:
            return TEST_MODULE
        if lower in self.system or any(pattern.match(lower) for pattern in self.api_sets):
            return SYSTEM_MODULE
        if lower in self.swift:
            return SWIFT_RUNTIME
        if lower in self.microsoft:
            return MICROSOFT_RUNTIME
        if lower in self.local:
            return LOCAL_RUNTIME
        return UNKNOWN_MODULE

    def canonical(self, module):
        lower = module.lower()
        return self.swift.get(lower) or self.microsoft.get(lower) or self.local.get(lower) or module

    def forbids(self, path):
        lower = path.lower()
        name = lower.rsplit("/", 1)[-1]
        return any(fnmatch.fnmatchcase(lower, pattern) or fnmatch.fnmatchcase(name, pattern) for pattern in self.forbidden)


# --- dependency closure -----------------------------------------------------------
def resolve_closure(roots, read_imports, policy, loaded_at_run_time=()):
    """Walk static and delay-load imports from production roots until only system modules remain.

    ``read_imports(name, category)`` returns ``(static, delayed)`` module name lists
    for the application (category ``"application"``) or a runtime module. The
    result records each bundled runtime module with its importers, each system
    module with its importers, and raises ``BundleError`` for test libraries or
    modules that no pinned runtime source provides.

    ``loaded_at_run_time`` names modules the application loads with
    LoadLibrary (the whisper.cpp runtime). They are walked after the static
    closure, and imports reached only through them are recorded as
    ``runtime-static``/``runtime-delay`` so a run that never loads them is not
    expected to show them.
    """
    roots = (roots,) if isinstance(roots, str) else tuple(roots)
    if not roots or len({name.lower() for name in roots}) != len(roots):
        raise BundleError("dependency roots must be non-empty and distinct")
    bundled, system, queue = {}, {}, [(root, "application", False) for root in roots]
    seen = {root.lower() for root in roots}
    for name in policy.additional:
        lower = name.lower()
        bundled[lower] = {"name": policy.canonical(name), "source": policy.classify(name),
                          "importedBy": [{"importer": "runtime-policy", "kind": "runtime-loaded"}]}
        seen.add(lower)
        queue.append((policy.canonical(name), policy.classify(name), False))
    deferred = []
    for name in loaded_at_run_time:
        if policy.classify(name) != LOCAL_RUNTIME:
            raise BundleError("run-time loaded module is not part of the local runtime: " + name)
        deferred.append((policy.canonical(name), LOCAL_RUNTIME, True))
    while queue or deferred:
        if not queue:
            importer, category, late = deferred.pop(0)
            lower = importer.lower()
            entry = bundled.setdefault(lower, {"name": importer, "source": LOCAL_RUNTIME, "importedBy": []})
            entry["importedBy"].append({"importer": APPLICATION, "kind": "runtime-loaded"})
            if lower in seen:
                continue
            seen.add(lower)
            queue.append((importer, category, late))
        importer, category, late = queue.pop(0)
        static, delayed = read_imports(importer, category)
        for base_kind, names in (("static", static), ("delay", delayed)):
            kind = ("runtime-" + base_kind) if late else base_kind
            for module in names:
                lower = module.lower()
                found = policy.classify(module)
                if found == TEST_MODULE:
                    raise BundleError(importer + " imports the test library " + module +
                                      "; only the production executable may be bundled")
                if found == UNKNOWN_MODULE:
                    raise BundleError(importer + " imports " + module + ", which is neither a Windows system "
                                      "module nor a module of the pinned Swift, Microsoft or local inference runtimes")
                reference = {"importer": importer, "kind": kind}
                if found == SYSTEM_MODULE:
                    system.setdefault(lower, {"name": module, "importedBy": []})["importedBy"].append(reference)
                    continue
                entry = bundled.setdefault(lower, {"name": policy.canonical(module), "source": found, "importedBy": []})
                entry["importedBy"].append(reference)
                if lower not in seen:
                    seen.add(lower)
                    queue.append((entry["name"], found, late))
    closure = {"bundled": dict(sorted(bundled.items())), "system": dict(sorted(system.items()))}
    closure["roots"] = {root: {"staticModules": static_modules(closure, root)} for root in roots}
    return closure


def static_modules(closure, root):
    """Bundled modules reached only through static edges from this executable.

    Delay-load and LoadLibrary edges do not make a DLL mandatory in a sampled
    process. A shared DLL keeps every immediate importer in the union graph.
    """
    reached = {root.lower()}
    required = {}
    changed = True
    while changed:
        changed = False
        for lower, entry in closure["bundled"].items():
            if lower in reached:
                continue
            if any(ref["kind"] == "static" and ref["importer"].lower() in reached for ref in entry["importedBy"]):
                reached.add(lower)
                required[lower] = entry["name"]
                changed = True
    return [required[name] for name in sorted(required)]


def validate_executable(data, name, architecture, policy):
    image = windows_pe.PEImage(data, name)
    if not image.runs_natively_on(architecture) or image.is_dll:
        raise BundleError("%s is not a Windows %s executable (it is %s)" % (
            name, windows_targets.target(architecture)["displayName"], image.architecture))
    if name == CLI and image.subsystem != windows_pe.IMAGE_SUBSYSTEM_WINDOWS_CUI:
        raise BundleError("speak.exe must use the console subsystem")
    for module in image.imports() + image.delay_imports():
        if policy.classify(module) == TEST_MODULE:
            raise BundleError(name + " imports the test library " + module + "; refusing a test-enabled build")
    return image


# --- bundle path safety -------------------------------------------------------------
def check_bundle_path(path):
    if not path or path.startswith("/") or any(character in path for character in '\\:<>"|?*'):
        raise BundleError("unsafe bundle path: " + repr(path))
    for part in path.split("/"):
        if part in ("", ".", "..") or part != part.strip() or part.endswith(".") or any(ord(c) < 32 for c in part):
            raise BundleError("unsafe bundle path component: " + repr(path))
        if part.split(".")[0].lower() in RESERVED_NAMES:
            raise BundleError("reserved Windows device name in bundle path: " + repr(path))
    return path


def check_bundle_layout(paths, policy):
    lowered = {}
    for path in paths:
        check_bundle_path(path)
        if policy.forbids(path):
            raise BundleError("policy forbids shipping " + path)
        key = path.lower()
        if key in lowered:
            raise BundleError("case-insensitive path collision: " + lowered[key] + " and " + path)
        lowered[key] = path
    directories = {"/".join(path.lower().split("/")[:depth]) for path in paths
                   for depth in range(1, len(path.split("/")))}
    clash = directories & set(lowered)
    if clash:
        raise BundleError("a file and a directory share a name: " + ", ".join(sorted(clash)))


# --- deterministic archive -----------------------------------------------------------
def write_deterministic_zip(path, entries):
    """Write ``{path: bytes}`` as a ZIP whose bytes depend only on its contents."""
    names = sorted(entries)
    with zipfile.ZipFile(path, "w") as archive:
        for name in names:
            info = zipfile.ZipInfo(name, date_time=ZIP_TIMESTAMP)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            archive.writestr(info, entries[name], compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
    return names
