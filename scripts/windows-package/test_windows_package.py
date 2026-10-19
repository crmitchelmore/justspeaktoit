#!/usr/bin/env python3
"""Unit tests for the Windows developer MSIX tooling; no downloads, caches or Windows APIs."""
import copy
import hashlib
import importlib.util
import json
import pathlib
import struct
import shutil
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
import urllib.parse
import xml.etree.ElementTree as ET
import zipfile

HERE = pathlib.Path(__file__).resolve().parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(HERE))
import lifecycle_support  # noqa: E402
import signing_configuration  # noqa: E402
import windows_msix  # noqa: E402


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# The bundle tests already build minimal PE32+ images; reuse them.
BUNDLE_TESTS = load("windows_bundle_tests", HERE.parent / "windows-bundle" / "test_windows_bundle.py")
BUILD = windows_msix.BUNDLE
COMMIT = "0123456789abcdef0123456789abcdef01234567"


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def make_bundle(directory, commit=COMMIT, mutate=None, exe_imports=("swiftCore.dll", "KERNEL32.dll"),
                architecture="x64"):
    """Write a bundle directory shaped exactly like build-windows-bundle.py output."""
    directory = pathlib.Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    target = windows_msix.windows_targets.target(architecture)
    machine = target["processMachine"]
    executable = BUNDLE_TESTS.build_pe(imports=exe_imports, machine=machine, subsystem=2)
    cli = BUNDLE_TESTS.build_pe(imports=["swiftCore.dll", "KERNEL32.dll"], machine=machine)
    entries = {
        "SpeakWindows.exe": executable,
        "speak.exe": cli,
        "swiftCore.dll": BUNDLE_TESTS.build_pe(imports=["KERNEL32.dll"], dll=True, machine=machine),
        "SpeakApp_SpeakCore.resources/ReleaseNotes.json": b'{"entries": [{"version": "1"}]}',
        # Larger than one 64 KiB block, so block maps have several blocks.
        "SpeakApp_SpeakCore.resources/Large.bin": bytes(range(256)) * 700,
        "licenses/LICENSE-JustSpeakToIt.txt": b"MIT License\n",
        "README.txt": b"Developer bundle\n",
    }
    sources = {"SpeakWindows.exe": "application", "speak.exe": "application",
               "swiftCore.dll": "swift-runtime", "README.txt": "generated",
               "licenses/LICENSE-JustSpeakToIt.txt": "application-license"}
    # Invalid executable-import fixtures still need a producer-shaped graph;
    # the consumer must re-read their PEs rather than trust this graph.
    graph_images = dict(entries, **{"SpeakWindows.exe": BUNDLE_TESTS.build_pe(
        imports=["swiftCore.dll", "KERNEL32.dll"], machine=machine)})
    def read_imports(name, category):
        image = windows_msix.windows_pe.PEImage(graph_images[name], name)
        return image.imports(), image.delay_imports()
    closure = BUILD.resolve_closure(BUILD.EXECUTABLES, read_imports, BUILD.Policy.load())
    manifest = {
        "schemaVersion": 1,
        "bundle": {"kind": "unsigned Windows %s developer runtime bundle" % target["displayName"],
                   "architecture": target["bundleArchitecture"], "notInstaller": True, "codeSigned": False},
        "application": {"sourceCommit": commit, "configuration": "release", "appBuiltForTesting": False,
                        "executableSHA256": sha256(executable),
                        "executables": {"SpeakWindows.exe": sha256(executable), "speak.exe": sha256(cli)},
                        "target": target["swiftTriple"], "buildHost": BUILD.APPLICATION_HOSTS[architecture]},
        "dependencies": dict(closure, additionalRuntimeModules=BUILD.Policy.load().additional),
        "policy": BUILD.Policy.load().data,
    }
    if mutate is not None:
        mutate(entries, manifest)
    manifest["files"] = [{"path": path, "bytes": len(data), "sha256": sha256(data),
                          "source": sources.get(path, "application-resources")}
                         for path, data in sorted(entries.items()) if path != "bundle-manifest.json"]
    return write_bundle(directory, entries, manifest, architecture)


def write_bundle(directory, entries, manifest, architecture):
    directory.mkdir(parents=True, exist_ok=True)
    commit = manifest["application"]["sourceCommit"]
    manifest_bytes = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()
    entries["bundle-manifest.json"] = manifest_bytes
    archive = directory / ("justspeaktoit-windows-%s-developer-%s.zip" % (architecture, commit[:7]))
    BUILD.write_deterministic_zip(archive, entries)
    data = archive.read_bytes()
    evidence = {"schemaVersion": 1,
                "zip": {"name": archive.name, "sha256": sha256(data), "bytes": len(data), "entries": len(entries)},
                "manifest": {"name": "bundle-manifest.json", "sha256": sha256(manifest_bytes)},
                "application": {"sourceCommit": commit,
                                "executableSHA256": manifest["application"]["executableSHA256"],
                                "executables": manifest["application"]["executables"]}}
    (directory / "bundle-evidence.json").write_text(json.dumps(evidence, indent=2), encoding="utf-8")
    return directory


def build_blockmap(files):
    namespace = windows_msix.BLOCKMAP_NAMESPACE
    root = ET.Element("{%s}BlockMap" % namespace, HashMethod=windows_msix.SHA256_METHOD)
    for name, data in sorted(files.items()):
        element = ET.SubElement(root, "{%s}File" % namespace, Name=name.replace("/", "\\"), Size=str(len(data)),
                                LfhSize="30")
        for value in windows_msix.block_hashes(data):
            ET.SubElement(element, "{%s}Block" % namespace, Hash=value)
    return ET.tostring(root, xml_declaration=True, encoding="utf-8")


def make_package(layout, path, signed=False, extra=None, drop=None, blockmap=None, replace=None, listed_extra=None):
    """Write an .msix-shaped archive as MakeAppx (and SignTool) would, from a layout directory.

    ``listed_extra`` adds parts that the block map also lists, as SignTool does
    for its code integrity catalogue.
    """
    files = {item.relative_to(layout).as_posix(): item.read_bytes() for item in layout.rglob("*") if item.is_file()}
    for name in drop or ():
        files.pop(name)
    listed = dict(files)
    listed.update(listed_extra or {})
    files.update(replace or {})
    files.update(listed_extra or {})
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, data in sorted(files.items()):
            archive.writestr(urllib.parse.quote(name), data)
        for name, data in (extra or {}).items():
            archive.writestr(name, data)
        archive.writestr("AppxBlockMap.xml", blockmap if blockmap is not None else build_blockmap(listed))
        archive.writestr("[Content_Types].xml",
                         b'<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>')
        if signed:
            archive.writestr("AppxSignature.p7x", b"PKCX synthetic signature")
    return path


class IdentityTests(unittest.TestCase):
    def test_developer_identity_is_separate_from_every_release_train(self):
        identity = windows_msix.load_identity()
        self.assertEqual(identity["channel"], "developer")
        self.assertIsNone(identity["releaseTrain"])
        trains = json.loads((windows_msix.REPOSITORY / "Sources/SpeakCore/Resources/ReleaseTrains.json").read_text(encoding="utf-8"))
        claimed = {value for train in trains.values() for value in train.values()}
        for value in (identity["identity"]["name"], identity["presentation"]["displayName"],
                      identity["application"]["executionAlias"][:-4]):
            self.assertNotIn(value, claimed)
        self.assertIn("Not an Alpha or Stable release", identity["presentation"]["description"])

    def test_startup_task_matches_the_native_login_item(self):
        # The C++ adapter asks for this task id, and the shared host starts
        # minimised on this argument; a rename on one side must fail here.
        startup = windows_msix.load_identity()["application"]["startupTask"]
        native = (windows_msix.REPOSITORY / "Sources/CWindowsSupport/WindowsLoginItem.hpp").read_text(encoding="utf-8")
        shared = (windows_msix.REPOSITORY / "Sources/SpeakDesktop/DesktopLoginItem.swift").read_text(encoding="utf-8")
        self.assertIn('constexpr wchar_t identifier[] = L"%s";' % startup["id"], native)
        self.assertIn('constexpr wchar_t launchArgument[] = L"%s";' % startup["parameters"], native)
        self.assertIn('public static let launchArgument = "%s"' % startup["parameters"], shared)

    def test_cli_alias_matches_the_automation_setup_dialog(self):
        # General › CLI and MCP setup locates the packaged speak command by
        # this alias; a rename on one side must fail here.
        alias = windows_msix.load_identity()["cli"]["executionAlias"]
        native = (windows_msix.REPOSITORY / "Sources/CWindowsSupport/WindowsAutomationSettings.cpp").read_text(
            encoding="utf-8")
        self.assertIn('L"\\\\Microsoft\\\\WindowsApps\\\\%s"' % alias, native)

    def test_publisher_id_matches_windows_for_known_publishers(self):
        self.assertEqual(windows_msix.publisher_id(
            "CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US"), "8wekyb3d8bbwe")
        self.assertEqual(windows_msix.publisher_id(
            "CN=Microsoft Windows, O=Microsoft Corporation, L=Redmond, S=Washington, C=US"), "cw5n1h2txyewy")

    def test_versions_follow_the_manifest_schema(self):
        for version in ("0.0.1.0", "1.2.3.4", "65535.65535.65535.65535", "0.0.42.1"):
            self.assertEqual(windows_msix.validate_version(version), version)
        for version in ("1.2.3", "1.2.3.4.5", "65536.0.0.0", "01.0.0.0", "-1.0.0.0", " 1.0.0.0", "1.0.0.0 ", "", None):
            with self.assertRaises(windows_msix.PackageError):
                windows_msix.validate_version(version)

    def test_publishers_and_names_follow_the_manifest_schema(self):
        for publisher in ("CN=Just Speak to It Developer", "CN=Contoso Software, O=Contoso Corporation, C=US",
                          'CN="Quoted, Name", C=GB', "CN=Example, OID.2.25.311729368913984317654407730594956997722=1"):
            self.assertEqual(windows_msix.validate_publisher(publisher), publisher)
        for publisher in ("Just Speak", "CN=", "CN=a,O=b", "XX=Example", " CN=Example", "CN=Line\nBreak"):
            with self.assertRaises(windows_msix.PackageError):
                windows_msix.validate_publisher(publisher)
        for name in ("ab", "a" * 51, "bad name", "com.example.", "con.example", "under_score"):
            with self.assertRaises(windows_msix.PackageError):
                windows_msix.validate_name(name)
        self.assertEqual(windows_msix.validate_name("com.justspeaktoit.windows.developer"),
                         "com.justspeaktoit.windows.developer")

    def test_policy_changes_to_identity_are_refused(self):
        original = json.loads(windows_msix.IDENTITY_PATH.read_text(encoding="utf-8"))
        changes = [
            lambda data: data["fileSystem"].update(writeVirtualization="enabled"),
            lambda data: data["targetDeviceFamily"].update(minVersion="10.0.18362.0"),
            lambda data: data["presentation"].update(displayName="Just | Speak"),
            lambda data: data["capabilities"]["device"].append("webcam"),
            lambda data: data.update(releaseTrain="stable"),
            lambda data: data["identity"].update(processorArchitectures=["x86"]),
            lambda data: data["identity"].update(processorArchitectures=[]),
            lambda data: data["identity"].update(processorArchitectures=["x64", "x64"]),
            lambda data: data["identity"].update(processorArchitectures="x64"),
            lambda data: data["application"].update(executionAlias="nested\\alias.exe"),
            lambda data: data["application"].update(executable="speak.exe"),
            lambda data: data["application"].update(id="ChangedGUI"),
            lambda data: data["application"].update(executionAlias="JustSpeakToItDeveloperCLI.exe"),
            lambda data: data["cli"].update(executable="SpeakWindows.exe"),
            lambda data: data["cli"].update(id="ChangedCLI"),
            lambda data: data["cli"].update(id="JustSpeakToIt"),
            lambda data: data["cli"].pop("id"),
            lambda data: data["cli"].update(startupTask={"id": "Extra", "parameters": "--background"}),
            lambda data: data["cli"].update(executionAlias="speak.exe"),
            lambda data: data["cli"].update(executionAlias="nested\\alias.exe"),
            lambda data: data["cli"].update(executable="..\\speak.exe"),
            lambda data: data.pop("cli"),
            lambda data: data["application"]["startupTask"].update(parameters="--minimised"),
            lambda data: data["application"]["startupTask"].update(id="bad id"),
            lambda data: data["application"].pop("startupTask"),
        ]
        with tempfile.TemporaryDirectory() as scratch:
            for change in changes:
                data = copy.deepcopy(original)
                change(data)
                path = pathlib.Path(scratch) / "identity.json"
                path.write_text(json.dumps(data), encoding="utf-8")
                with self.assertRaises(windows_msix.PackageError):
                    windows_msix.load_identity(path)


class ManifestTests(unittest.TestCase):
    def setUp(self):
        self.identity = windows_msix.load_identity()

    def test_manifest_declares_the_reviewed_identity_capabilities_and_unvirtualised_data(self):
        data = windows_msix.render_manifest(self.identity, "0.0.7.1", "CN=Just Speak to It Developer")
        root = ET.fromstring(data)
        ns = windows_msix.NAMESPACES
        self.assertEqual(root.find("f:Identity", ns).attrib, {
            "Name": "com.justspeaktoit.windows.developer", "Publisher": "CN=Just Speak to It Developer",
            "Version": "0.0.7.1", "ProcessorArchitecture": "x64"})
        self.assertEqual(root.findtext("f:Properties/desktop6:FileSystemWriteVirtualization", namespaces=ns),
                         "disabled")
        self.assertNotIn("desktop6", root.get("IgnorableNamespaces").split())
        application = root.find("f:Applications/f:Application", ns)
        self.assertEqual(application.get("Executable"), "SpeakWindows.exe")
        self.assertEqual(application.get("{%s}TrustLevel" % ns["uap10"]), "mediumIL")
        alias = application.find(".//desktop:ExecutionAlias", ns)
        self.assertEqual(alias.get("Alias"), "JustSpeakToItDeveloper.exe")
        applications = root.findall("f:Applications/f:Application", ns)
        self.assertEqual([app.get("Id") for app in applications], ["JustSpeakToIt", "JustSpeakToItCLI"])
        cli_application = applications[1]
        self.assertEqual(cli_application.get("Executable"), "speak.exe")
        self.assertEqual(cli_application.find("uap:VisualElements", ns).get("AppListEntry"), "none")
        self.assertIsNone(application.find("uap:VisualElements", ns).get("AppListEntry"))
        self.assertEqual(cli_application.get("{%s}SupportsMultipleInstances" % ns["uap10"]), "true")
        self.assertIsNone(application.get("{%s}SupportsMultipleInstances" % ns["uap10"]))
        cli_extension = cli_application.find("f:Extensions/uap5:Extension", ns)
        self.assertEqual(cli_extension.get("Executable"), "speak.exe")
        cli_alias = cli_extension.find("uap5:AppExecutionAlias", ns)
        self.assertEqual(cli_alias.get("{%s}Subsystem" % ns["uap10"]), "console")
        self.assertEqual(cli_alias.find("uap5:ExecutionAlias", ns).get("Alias"), "JustSpeakToItDeveloperCLI.exe")
        self.assertEqual(len(cli_application.find("f:Extensions", ns)), 1)
        self.assertIsNone(cli_application.find(".//desktop:StartupTask", ns))
        startup = application.find("f:Extensions/desktop:Extension[@Category='windows.startupTask']", ns)
        self.assertEqual((startup.get("Executable"), startup.get("{%s}Parameters" % ns["uap10"])),
                         ("SpeakWindows.exe", "--background"))
        self.assertEqual(startup.find("desktop:StartupTask", ns).attrib,
                         {"TaskId": "JustSpeakToIt", "Enabled": "false", "DisplayName": "Just Speak to It Developer"})
        names = [element.get("Name") for element in root.find("f:Capabilities", ns)]
        self.assertEqual(names, ["runFullTrust", "unvirtualizedResources", "microphone"])
        family = root.find("f:Dependencies/f:TargetDeviceFamily", ns)
        self.assertEqual((family.get("MinVersion"), family.get("MaxVersionTested")), ("10.0.19041.0", "10.0.20348.0"))

    def test_arm64_manifest_declares_the_same_identity_for_arm64(self):
        data = windows_msix.render_manifest(self.identity, "0.0.7.1", "CN=Just Speak to It Developer",
                                            architecture="arm64")
        identity = ET.fromstring(data).find("f:Identity", windows_msix.NAMESPACES)
        self.assertEqual(identity.get("ProcessorArchitecture"), "arm64")
        self.assertEqual(identity.get("Name"), "com.justspeaktoit.windows.developer")
        with self.assertRaises(windows_msix.PackageError):
            windows_msix.check_manifest(data, self.identity, "0.0.7.1", "CN=Just Speak to It Developer")
        record = windows_msix.package_identity(self.identity, "0.0.7.1", "CN=Just Speak to It Developer", "arm64")
        self.assertEqual(record["packageFullName"], "com.justspeaktoit.windows.developer_0.0.7.1_arm64__"
                         + windows_msix.publisher_id("CN=Just Speak to It Developer"))
        x64_only = copy.deepcopy(self.identity)
        x64_only["identity"]["processorArchitectures"] = ["x64"]
        with self.assertRaisesRegex(windows_msix.PackageError, "does not allow the arm64"):
            windows_msix.render_manifest(x64_only, "0.0.7.1", "CN=Just Speak to It Developer", architecture="arm64")

    def test_qualified_logo_families_require_generated_unqualified_assets(self):
        for root in ("Assets/StoreLogo.png", "Assets/Square44x44Logo.png", "Assets/Square150x150Logo.png"):
            with self.subTest(root=root):
                identity = copy.deepcopy(self.identity)
                del identity["assets"]["images"][root]
                self.assertTrue(any(path.startswith(root[:-4] + ".") for path in identity["assets"]["images"]))
                with self.assertRaisesRegex(windows_msix.PackageError, "generated unqualified assets"):
                    windows_msix.render_manifest(identity, "0.0.7.1", "CN=Just Speak to It Developer")

    def test_text_values_are_escaped(self):
        identity = copy.deepcopy(self.identity)
        identity["presentation"]["displayName"] = 'Speak <It> & "Quote"'
        data = windows_msix.render_manifest(identity, "1.0.0.0", "CN=Just Speak to It Developer")
        root = ET.fromstring(data)
        self.assertEqual(root.findtext("f:Properties/f:DisplayName", namespaces=windows_msix.NAMESPACES),
                         'Speak <It> & "Quote"')

    def test_manifest_that_differs_from_the_request_is_refused(self):
        data = windows_msix.render_manifest(self.identity, "0.0.7.1", "CN=Just Speak to It Developer")
        with self.assertRaises(windows_msix.PackageError):
            windows_msix.check_manifest(data, self.identity, "0.0.7.2", "CN=Just Speak to It Developer")
        weakened = data.replace(b">disabled</desktop6", b">enabled</desktop6")
        with self.assertRaises(windows_msix.PackageError):
            windows_msix.check_manifest(weakened, self.identity, "0.0.7.1", "CN=Just Speak to It Developer")
        ignorable = data.replace(b'IgnorableNamespaces="uap', b'IgnorableNamespaces="desktop6 uap')
        with self.assertRaises(windows_msix.PackageError):
            windows_msix.check_manifest(ignorable, self.identity, "0.0.7.1", "CN=Just Speak to It Developer")
        # Launch at login stays off until the user turns it on, and starts minimised.
        for original, changed in ((b'Enabled="false"', b'Enabled="true"'),
                                  (b'uap10:Parameters="--background"', b'uap10:Parameters=""'),
                                  (b'TaskId="JustSpeakToIt"', b'TaskId="Other"')):
            self.assertIn(original, data)
            with self.assertRaises(windows_msix.PackageError):
                windows_msix.check_manifest(data.replace(original, changed), self.identity, "0.0.7.1",
                                            "CN=Just Speak to It Developer")

    def test_cli_alias_retarget_duplicates_path_injection_and_subsystem_changes_are_refused(self):
        data = windows_msix.render_manifest(self.identity, "0.0.7.1", "CN=Just Speak to It Developer")
        for original, changed in (
            (b'Executable="speak.exe"', b'Executable="SpeakWindows.exe"'),
            (b'Executable="speak.exe"', b'Executable="nested\\speak.exe"'),
            (b'Alias="JustSpeakToItDeveloperCLI.exe"', b'Alias="JustSpeakToItDeveloper.exe"'),
            (b'Alias="JustSpeakToItDeveloperCLI.exe"', b'Alias="speak.exe"'),
            (b'Alias="JustSpeakToItDeveloperCLI.exe"', b'Alias="..\\CLI.exe"'),
            (b'uap10:Subsystem="console"', b'uap10:Subsystem="windows"'),
            (b'uap10:Subsystem="console"', b''),
            (b'<uap5:ExecutionAlias Alias="JustSpeakToItDeveloperCLI.exe"/>',
             b'<uap5:ExecutionAlias Alias="JustSpeakToItDeveloperCLI.exe"/>'
             b'<uap5:ExecutionAlias Alias="extra.exe"/>'),
        ):
            with self.subTest(changed=changed), self.assertRaises(windows_msix.PackageError):
                windows_msix.check_manifest(data.replace(original, changed), self.identity, "0.0.7.1",
                                            "CN=Just Speak to It Developer")
        root = ET.fromstring(data)
        ns = windows_msix.NAMESPACES
        extensions = root.findall("f:Applications/f:Application", ns)[1].find("f:Extensions", ns)
        extensions.append(copy.deepcopy(extensions.find("uap5:Extension", ns)))
        with self.assertRaisesRegex(windows_msix.PackageError, "exactly"):
            windows_msix.check_manifest(ET.tostring(root), self.identity, "0.0.7.1", "CN=Just Speak to It Developer")

    def test_application_topology_visuals_and_extension_ownership_are_exact_on_both_architectures(self):
        ns = windows_msix.NAMESPACES
        for architecture in ("x64", "arm64"):
            original = windows_msix.render_manifest(self.identity, "0.0.7.1", "CN=Just Speak to It Developer",
                                                    architecture=architecture)
            for mutation in ("old-topology", "extra-hidden-app", "duplicate-app-id", "wrong-cli-id",
                             "cli-visible", "gui-hidden", "cli-missing-visual", "cli-foreign-logo",
                             "gui-foreign-logo", "cli-startup", "extra-extension", "swapped-aliases",
                             "cli-extra-visual", "cli-wrong-trust", "gui-extra-activation",
                             "duplicate-category", "cli-wrong-executable", "cli-wrong-alias",
                             "cli-wrong-subsystem", "cli-missing-subsystem", "cli-extra-alias",
                             "cli-missing-supports-multiple-instances",
                             "cli-false-supports-multiple-instances",
                             "cli-unqualified-supports-multiple-instances",
                             "cli-supports-multiple-instances-wrong-location",
                             "gui-extra-supports-multiple-instances"):
                with self.subTest(architecture=architecture, mutation=mutation):
                    root = ET.fromstring(original)
                    apps = root.find("f:Applications", ns)
                    gui, cli = list(apps)
                    gui_extensions = gui.find("f:Extensions", ns)
                    cli_extensions = cli.find("f:Extensions", ns)
                    visual = cli.find("uap:VisualElements", ns)
                    if mutation == "old-topology":
                        gui_extensions.append(cli_extensions[0])
                        apps.remove(cli)
                    elif mutation == "extra-hidden-app":
                        apps.append(copy.deepcopy(cli))
                    elif mutation == "duplicate-app-id":
                        cli.set("Id", gui.get("Id"))
                    elif mutation == "wrong-cli-id":
                        cli.set("Id", "UnreviewedCLI")
                    elif mutation == "cli-visible":
                        visual.attrib.pop("AppListEntry")
                    elif mutation == "gui-hidden":
                        gui.find("uap:VisualElements", ns).set("AppListEntry", "none")
                    elif mutation == "cli-missing-visual":
                        cli.remove(visual)
                    elif mutation == "cli-foreign-logo":
                        visual.set("Square44x44Logo", "Assets\\StoreLogo.png")
                    elif mutation == "gui-foreign-logo":
                        gui.find("uap:VisualElements", ns).set("Square150x150Logo", "Assets\\StoreLogo.png")
                    elif mutation == "cli-startup":
                        cli_extensions.append(copy.deepcopy(gui_extensions[1]))
                    elif mutation == "extra-extension":
                        ET.SubElement(cli_extensions, "{%s}Extension" % ns["uap5"], Category="windows.userActivity")
                    elif mutation == "swapped-aliases":
                        gui_alias, cli_alias = gui_extensions[0], cli_extensions[0]
                        gui_extensions.remove(gui_alias)
                        cli_extensions.remove(cli_alias)
                        gui_extensions.insert(0, cli_alias)
                        cli_extensions.append(gui_alias)
                    elif mutation == "cli-extra-visual":
                        ET.SubElement(visual, "{%s}DefaultTile" % ns["uap"])
                    elif mutation == "cli-wrong-trust":
                        cli.set("{%s}TrustLevel" % ns["uap10"], "appContainer")
                    elif mutation == "duplicate-category":
                        gui_extensions.append(copy.deepcopy(cli_extensions[0]))
                    elif mutation == "cli-wrong-executable":
                        cli.set("Executable", "SpeakWindows.exe")
                    elif mutation == "cli-wrong-alias":
                        cli_extensions[0][0][0].set("Alias", "JustSpeakToItDeveloper.exe")
                    elif mutation == "cli-wrong-subsystem":
                        cli_extensions[0][0].set("{%s}Subsystem" % ns["uap10"], "windows")
                    elif mutation == "cli-missing-subsystem":
                        cli_extensions[0][0].attrib.pop("{%s}Subsystem" % ns["uap10"])
                    elif mutation == "cli-extra-alias":
                        cli_extensions[0][0].append(copy.deepcopy(cli_extensions[0][0][0]))
                    elif mutation == "cli-missing-supports-multiple-instances":
                        cli.attrib.pop("{%s}SupportsMultipleInstances" % ns["uap10"])
                    elif mutation == "cli-false-supports-multiple-instances":
                        cli.set("{%s}SupportsMultipleInstances" % ns["uap10"], "false")
                    elif mutation == "cli-unqualified-supports-multiple-instances":
                        cli.attrib.pop("{%s}SupportsMultipleInstances" % ns["uap10"])
                        cli.set("SupportsMultipleInstances", "true")
                    elif mutation == "cli-supports-multiple-instances-wrong-location":
                        cli.attrib.pop("{%s}SupportsMultipleInstances" % ns["uap10"])
                        cli_extensions.set("{%s}SupportsMultipleInstances" % ns["uap10"], "true")
                    elif mutation == "gui-extra-supports-multiple-instances":
                        gui.set("{%s}SupportsMultipleInstances" % ns["uap10"], "true")
                    else:
                        gui.set("EntryPoint", "Unreviewed.Activation")
                    with self.assertRaises(windows_msix.PackageError):
                        windows_msix.check_manifest(ET.tostring(root), self.identity, "0.0.7.1",
                                                    "CN=Just Speak to It Developer", architecture=architecture)


class StartEntryMockTests(unittest.TestCase):
    def test_native_family_entry_projection_with_mock_startapps(self):
        pwsh = shutil.which("pwsh")
        if pwsh is None:
            self.skipTest("PowerShell 7 is unavailable; no tools are downloaded")
        script = r"""
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($args[0], [ref] $tokens, [ref] $errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($name in @('Get-StartMenuEntry', 'Wait-StartMenuEntry')) {
    $function = @($ast.FindAll({ param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true))
    if ($function.Count -ne 1) { throw "Expected one $name function" }
    . ([scriptblock]::Create($function[0].Extent.Text))
}
$base = @{ packageFamilyName = 'developer_family'; displayName = 'Developer GUI' }
$aumid = 'developer_family!JustSpeakToIt'
$script:waiting = $false
function Get-FakeStartItems {
    if ($script:waiting) {
        $index = [Math]::Min($script:polls, $script:frames.Count - 1)
        $script:items = $script:frames[$index].items
        $script:polls++
    }
    $script:items
}
function Get-StartApps { Get-FakeStartItems }
function Get-Command {
    param($Name, $ErrorAction)
    if (-not $script:useShell) { [pscustomobject]@{ Name = 'Get-StartApps' } }
}
function New-Object {
    param($ComObject)
    if ($ComObject -ne 'Shell.Application') { throw 'Unexpected COM request' }
    $script:folder = [pscustomobject]@{}
    $script:folder | Add-Member ScriptMethod Items {
        Get-FakeStartItems | ForEach-Object { [pscustomobject]@{ Path = $_.AppID; Name = $_.Name } }
    }
    $shell = [pscustomobject]@{}
    $shell | Add-Member ScriptMethod NameSpace {
        param($Path)
        if ($Path -ne 'shell:AppsFolder') { throw 'Unexpected shell namespace' }
        $script:folder
    }
    $shell
}
$gui = [pscustomobject]@{ AppID = $aumid; Name = 'Developer GUI' }
$cli = [pscustomobject]@{ AppID = 'developer_family!JustSpeakToItCLI'; Name = 'Unexpected CLI' }
$other = [pscustomobject]@{ AppID = 'other_family!Other'; Name = 'Other app' }
$near = [pscustomobject]@{ AppID = 'developer_family_extra!Other'; Name = 'Similar family' }
foreach ($script:useShell in @($false, $true)) {
foreach ($case in @(
    @{ items = @(); count = 0; present = $false },
    @{ items = @($other); count = 0; present = $false },
    @{ items = @($gui, $other); count = 1; present = $true },
    @{ items = @($gui, $cli); count = 2; present = $true },
    @{ items = @($cli); count = 1; present = $false },
    @{ items = @($gui, $gui); count = 2; present = $true },
    @{ items = @($near); count = 0; present = $false }
)) {
    $script:items = $case.items
    $entry = Get-StartMenuEntry
    if ($entry.entries.Count -ne $case.count -or $entry.present -ne $case.present) {
        throw 'Incorrect family entry projection'
    }
}
}
Write-Output 'PASS fourteen mock-only Start entry projections (StartApps and shell fallback)'
function Get-Date { ([datetime]'2026-01-01T00:00:00').AddSeconds($script:elapsed) }
function Start-Sleep {
    param([int] $Seconds)
    if ($Seconds -ne 1) { throw 'The existing polling interval must remain one second' }
    $script:elapsed += $Seconds
}
$wrongName = [pscustomobject]@{ AppID = $aumid; Name = 'Unreviewed name' }
$cases = @(
    @{ present = $true; frames = @(@{ items = @($gui, $cli) }, @{ items = @($gui) })
       count = 1; gui = $true; polls = 2; elapsed = 1; ids = $aumid },
    @{ present = $false; frames = @(@{ items = @($cli) }, @{ items = @() })
       count = 0; gui = $false; polls = 2; elapsed = 1; ids = '' },
    @{ present = $true; frames = @(@{ items = @($wrongName) }, @{ items = @($gui) })
       count = 1; gui = $true; polls = 2; elapsed = 1; ids = $aumid },
    @{ present = $true; frames = @(@{ items = @($cli) }, @{ items = @($gui) })
       count = 1; gui = $true; polls = 2; elapsed = 1; ids = $aumid },
    @{ present = $true; frames = @(@{ items = @($gui, $cli) })
       count = 2; gui = $true; polls = 3; elapsed = 3; ids = "$aumid,developer_family!JustSpeakToItCLI" },
    @{ present = $true; frames = @(@{ items = @($cli) })
       count = 1; gui = $false; polls = 3; elapsed = 3; ids = 'developer_family!JustSpeakToItCLI' },
    @{ present = $false; frames = @(@{ items = @($gui, $cli) })
       count = 2; gui = $true; polls = 3; elapsed = 3; ids = "$aumid,developer_family!JustSpeakToItCLI" },
    @{ present = $false; frames = @(@{ items = @($cli) })
       count = 1; gui = $false; polls = 3; elapsed = 3; ids = 'developer_family!JustSpeakToItCLI' }
)
$script:waiting = $true
foreach ($script:useShell in @($false, $true)) {
    foreach ($case in $cases) {
        $script:frames = $case.frames; $script:polls = 0; $script:elapsed = 0
        $entry = Wait-StartMenuEntry -Present $case.present -Seconds 3
        $ids = ($entry.entries | ForEach-Object { $_.id }) -join ','
        if ($entry.entries.Count -ne $case.count -or $entry.present -ne $case.gui -or
            $script:polls -ne $case.polls -or $script:elapsed -ne $case.elapsed -or $ids -cne $case.ids) {
            throw "Incorrect bounded family convergence or final evidence: $($case.ids)"
        }
    }
}
Write-Output 'PASS sixteen deterministic mock-only family waits (no real sleeps or native queries)'
"""
        with tempfile.TemporaryDirectory() as scratch:
            fixture = pathlib.Path(scratch) / "start-entry-mock.ps1"
            fixture.write_text(script, encoding="utf-8")
            result = subprocess.run([pwsh, "-NoProfile", "-NonInteractive", "-File", str(fixture),
                                     str(HERE / "test-windows-package-lifecycle.ps1")],
                                    capture_output=True, text=True, encoding="utf-8", timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS fourteen mock-only", result.stdout)
        self.assertIn("PASS sixteen deterministic mock-only", result.stdout)


class AssetTests(unittest.TestCase):
    def test_png_round_trip(self):
        pixels = bytes((x * 7 + y * 13 + channel * 31) & 255 for y in range(5) for x in range(9) for channel in range(4))
        self.assertEqual(windows_msix.decode_png(windows_msix.encode_png(9, 5, pixels)), (9, 5, pixels))

    def test_corrupt_png_is_refused(self):
        data = bytearray(windows_msix.encode_png(2, 2, bytes(16)))
        data[-20] ^= 1
        with self.assertRaises(windows_msix.PackageError):
            windows_msix.decode_png(bytes(data))

    def test_area_weights_cover_each_source_exactly_once(self):
        for source, target in ((256, 150), (256, 44), (256, 50), (7, 3), (3, 7)):
            weights = windows_msix._area_weights(source, target)
            self.assertTrue(all(sum(weight for _, weight in row) == source for row in weights))
            coverage = [0] * source
            for row in weights:
                for pixel, weight in row:
                    coverage[pixel] += weight
            self.assertEqual(coverage, [target] * source)

    def test_transparent_pixels_do_not_darken_edges(self):
        width = 8
        pixels = b"".join(bytes((0, 0, 0, 0)) if x < 4 else bytes((255, 107, 61, 255))
                          for y in range(width) for x in range(width))
        output = windows_msix.resample_rgba(width, width, pixels, 3, 3)
        for offset in range(0, len(output), 4):
            if output[offset + 3]:
                self.assertEqual(tuple(output[offset:offset + 3]), (255, 107, 61))
        solid = bytes((12, 34, 56, 255)) * 49
        self.assertEqual(windows_msix.resample_rgba(7, 7, solid, 3, 3), bytes((12, 34, 56, 255)) * 9)

    def test_logos_are_derived_from_the_canonical_icon_at_declared_sizes(self):
        identity = windows_msix.load_identity()
        assets, record = windows_msix.render_assets(identity)
        self.assertEqual(sorted(assets), sorted(identity["assets"]["images"]))
        source = (windows_msix.REPOSITORY / identity["assets"]["source"]).read_bytes()
        self.assertEqual(record["sourceSHA256"], sha256(source))
        for path, data in assets.items():
            size = identity["assets"]["images"][path]
            width, height, rgba = windows_msix.decode_png(data)
            self.assertEqual((width, height), (size, size))
            self.assertEqual(rgba[3], 0, "corners stay transparent")
            centre = ((size // 2) * size + size // 2) * 4
            self.assertEqual(rgba[centre + 3], 255, "artwork is opaque")
        again, _ = windows_msix.render_assets(identity)
        self.assertEqual(assets, again)


class LayoutTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.scratch.name)

    def tearDown(self):
        self.scratch.cleanup()

    def build(self, bundle=None, output="out", **options):
        bundle = bundle or make_bundle(self.root / "bundle")
        options.setdefault("version", "0.0.9.1")
        return windows_msix.build_layout(bundle, self.root / output, **options)

    def test_layout_is_the_verified_bundle_plus_generated_package_files(self):
        bundle = make_bundle(self.root / "bundle")
        evidence = self.build(bundle, expected_commit=COMMIT)
        layout = self.root / "out/layout"
        package_manifest, hashes = windows_msix.verify_layout(layout)
        with zipfile.ZipFile(next(bundle.glob("*.zip"))) as archive:
            for name in archive.namelist():
                self.assertEqual((layout / name).read_bytes(), archive.read(name), name)
                self.assertEqual(hashes[name], sha256(archive.read(name)))
        generated = {row["path"]: row["origin"] for row in package_manifest["files"] if row["origin"] != "bundle"}
        expected = {path: "generated-asset" for path in windows_msix.load_identity()["assets"]["images"]}
        expected["AppxManifest.xml"] = "generated-manifest"
        self.assertEqual(generated, expected)
        self.assertEqual(package_manifest["package"]["packageFamilyName"],
                         "com.justspeaktoit.windows.developer_" + windows_msix.publisher_id(
                             "CN=Just Speak to It Developer"))
        self.assertFalse(package_manifest["package"]["signed"])
        self.assertEqual(package_manifest["bundle"]["sourceCommit"], COMMIT)
        self.assertEqual(package_manifest["bundle"]["runtimeModules"], ["swiftCore.dll"])
        self.assertEqual(package_manifest["executable"]["subsystem"], "windows")
        self.assertEqual(set(package_manifest["executables"]), set(BUILD.EXECUTABLES))
        self.assertEqual(package_manifest["executables"]["speak.exe"]["subsystem"], "console")
        self.assertEqual(package_manifest["package"]["cliExecutionAlias"], "JustSpeakToItDeveloperCLI.exe")
        self.assertEqual(package_manifest["package"]["cliApplicationId"], "JustSpeakToItCLI")
        self.assertEqual(package_manifest["package"]["cliAppUserModelId"],
                         package_manifest["package"]["packageFamilyName"] + "!JustSpeakToItCLI")
        self.assertEqual(evidence["layout"]["files"], len(hashes))

    def test_arm64_bundle_becomes_an_arm64_package_of_the_same_identity(self):
        bundle = make_bundle(self.root / "bundle", architecture="arm64")
        evidence = self.build(bundle, expected_commit=COMMIT)
        self.assertEqual(evidence["package"]["architecture"], "arm64")
        self.assertIn("_0.0.9.1_arm64__", evidence["package"]["packageFullName"])
        package_manifest, _ = windows_msix.verify_layout(self.root / "out/layout")
        self.assertEqual(package_manifest["package"]["kind"], "unsigned Windows ARM64 developer MSIX payload")
        manifest = ET.fromstring((self.root / "out/layout/AppxManifest.xml").read_bytes())
        self.assertEqual(manifest.find("f:Identity", windows_msix.NAMESPACES).get("ProcessorArchitecture"), "arm64")
        self.assertEqual(package_manifest["package"]["cliApplicationId"], "JustSpeakToItCLI")
        self.assertEqual(package_manifest["package"]["cliAppUserModelId"],
                         package_manifest["package"]["packageFamilyName"] + "!JustSpeakToItCLI")
        x64 = self.build(make_bundle(self.root / "x64-bundle"), output="x64")
        self.assertEqual(x64["package"]["packageFamilyName"], evidence["package"]["packageFamilyName"])
        self.assertEqual(x64["package"]["architecture"], "x64")

    def test_images_foreign_to_the_bundle_architecture_are_refused(self):
        arm64 = windows_msix.windows_pe.IMAGE_FILE_MACHINE_ARM64
        cases = [
            ("x64-dll", "arm64", lambda entries, manifest: entries.update(
                {"swiftCore.dll": BUNDLE_TESTS.build_pe(imports=["KERNEL32.dll"], dll=True)}),
             "swiftCore.dll is not a native arm64 DLL"),
            ("arm64ec-dll", "arm64", lambda entries, manifest: entries.update(
                {"swiftCore.dll": BUNDLE_TESTS.build_pe(imports=["KERNEL32.dll"], dll=True, hybrid_metadata=0x18000A2E8)}),
             "not a native arm64 DLL \\(it is arm64ec\\)"),
            ("arm64-exe-in-x64", "x64", lambda entries, manifest: entries.update(
                {"SpeakWindows.exe": BUNDLE_TESTS.build_pe(imports=["KERNEL32.dll"], machine=arm64)}) or
             manifest["application"].update(executableSHA256=sha256(entries["SpeakWindows.exe"])) or
             manifest["application"]["executables"].update({"SpeakWindows.exe": sha256(entries["SpeakWindows.exe"])}),
             "not a Windows x64 executable \\(it is arm64\\)"),
            ("no-architecture", "x64", lambda entries, manifest: manifest["bundle"].pop("architecture"),
             "unsupported bundle architecture"),
        ]
        for name, architecture, mutate, message in cases:
            bundle = make_bundle(self.root / name, mutate=mutate, architecture=architecture)
            if name == "arm64-exe-in-x64":
                # The evidence names the recorded executable; keep it consistent with the mutation.
                evidence = json.loads((bundle / "bundle-evidence.json").read_text(encoding="utf-8"))
                with zipfile.ZipFile(next(bundle.glob("*.zip"))) as archive:
                    evidence["application"]["executableSHA256"] = sha256(archive.read("SpeakWindows.exe"))
                (bundle / "bundle-evidence.json").write_text(json.dumps(evidence), encoding="utf-8")
            with self.assertRaisesRegex(windows_msix.PackageError, message, msg=name):
                self.build(bundle, output="out-" + name)

    def test_layout_is_deterministic(self):
        bundle = make_bundle(self.root / "bundle")
        self.build(bundle, output="first")
        self.build(bundle, output="second")
        first = {path.relative_to(self.root / "first").as_posix(): path.read_bytes()
                 for path in (self.root / "first").rglob("*") if path.is_file()}
        second = {path.relative_to(self.root / "second").as_posix(): path.read_bytes()
                  for path in (self.root / "second").rglob("*") if path.is_file()}
        self.assertEqual(first, second)

    def test_missing_tampered_retargeted_cli_and_false_root_attribution_are_refused(self):
        def replace_cli(entries, manifest, data):
            entries["speak.exe"] = data
            manifest["application"]["executables"]["speak.exe"] = sha256(data)

        cases = [
            ("missing", lambda entries, manifest: entries.pop("speak.exe"), "production executable"),
            ("tampered", lambda entries, manifest: entries.update({"speak.exe": entries["speak.exe"] + b"tamper"}),
             "production executable"),
            ("no-cli-receipt", lambda entries, manifest: manifest["application"]["executables"].pop("speak.exe"),
             "production executable"),
            ("foreign-cli", lambda entries, manifest: replace_cli(entries, manifest, BUNDLE_TESTS.build_pe(
                machine=windows_msix.windows_pe.IMAGE_FILE_MACHINE_ARM64)), "speak.exe is not a Windows x64"),
            ("cli-test", lambda entries, manifest: replace_cli(entries, manifest, BUNDLE_TESTS.build_pe(
                delay_imports=["Testing.dll"])), "speak.exe imports the test library Testing.dll"),
            ("gui-as-cli", lambda entries, manifest: replace_cli(entries, manifest, entries["SpeakWindows.exe"]),
             "console subsystem"),
            ("cli-unknown", lambda entries, manifest: replace_cli(entries, manifest, BUNDLE_TESTS.build_pe(
                imports=["unreviewed.dll"])), "speak.exe imports unreviewed.dll"),
            ("false-importer", lambda entries, manifest: manifest["dependencies"]["bundled"]["swiftcore.dll"]
             ["importedBy"].pop(), "importer attribution"),
            ("false-root", lambda entries, manifest: manifest["dependencies"]["roots"]["speak.exe"].update(
                staticModules=[]), "multi-root dependency closure"),
            ("cli-source", lambda entries, manifest: manifest["application"].update(buildHost="unreviewed"),
             "source provenance"),
            ("cli-target", lambda entries, manifest: manifest["application"].update(target="x86_64-unknown-linux-gnu"),
             "source provenance"),
            ("extra-executable", lambda entries, manifest: entries.update({"other.exe": entries["speak.exe"]}),
             "exact production multi-root closure"),
        ]
        for name, mutate, reason in cases:
            with self.subTest(name=name):
                bundle = make_bundle(self.root / name, mutate=mutate)
                with self.assertRaisesRegex(windows_msix.PackageError, reason):
                    self.build(bundle, output="out-" + name)
                self.assertFalse((self.root / ("out-" + name)).exists())

    def test_producer_multi_root_graph_round_trips_with_resources_and_miniz_licence(self):
        for architecture in ("x64", "arm64"):
            with self.subTest(architecture=architecture):
                fixture = BUNDLE_TESTS.AssemblyTests()
                fixture.setUp(architecture)
                try:
                    cli = BUNDLE_TESTS.build_pe(imports=["swiftWinSDK.dll"], delay_imports=["Foundation.dll"],
                                               machine=windows_msix.windows_targets.target(architecture)["processMachine"])
                    fixture.application["executables"]["speak.exe"] = cli
                    fixture.application["metadata"]["executables"]["speak.exe"] = sha256(cli)
                    fixture.application["resources"]["SpeakApp_Future.resources/nested/payload.json"] = b"{}"
                    licence = BUNDLE_TESTS.MIGRATION.license_entry(windows_msix.REPOSITORY)
                    entries, manifest = fixture.assemble(architecture=architecture, licenses=fixture.licenses + [licence])
                    bundle = write_bundle(self.root / ("producer-" + architecture), entries, manifest, architecture)
                    result = windows_msix.verify_bundle(bundle, fixture.application["metadata"]["sourceCommit"])
                    self.assertEqual(result["manifest"]["dependencies"], manifest["dependencies"])
                    self.assertNotIn("swiftWinSDK.dll", manifest["dependencies"]["roots"]["SpeakWindows.exe"]["staticModules"])
                    self.build(bundle, output="producer-out-" + architecture)
                    layout = self.root / ("producer-out-" + architecture) / "layout"
                    self.assertEqual((layout / "speak.exe").read_bytes(), cli)
                    self.assertEqual((layout / "SpeakApp_Future.resources/nested/payload.json").read_bytes(), b"{}")
                    self.assertEqual((layout / "licenses/LICENSE-miniz.txt").read_bytes(), licence["data"])
                finally:
                    fixture.doCleanups()

    def test_external_publisher_changes_the_package_family(self):
        publisher = "CN=Contoso Software, O=Contoso Corporation, C=US"
        evidence = self.build(publisher=publisher)
        self.assertEqual(evidence["package"]["publisher"], publisher)
        self.assertEqual(evidence["package"]["packageFamilyName"],
                         "com.justspeaktoit.windows.developer_" + windows_msix.publisher_id(publisher))
        manifest = ET.fromstring((self.root / "out/layout/AppxManifest.xml").read_bytes())
        self.assertEqual(manifest.find("f:Identity", windows_msix.NAMESPACES).get("Publisher"), publisher)

    def test_changed_or_foreign_bundles_are_refused(self):
        def tamper_archive(bundle):
            archive = next(bundle.glob("*.zip"))
            data = bytearray(archive.read_bytes())
            data[len(data) // 2] ^= 1
            archive.write_bytes(bytes(data))

        def rewrite_evidence(bundle, change):
            path = bundle / "bundle-evidence.json"
            evidence = json.loads(path.read_text(encoding="utf-8"))
            change(evidence)
            path.write_text(json.dumps(evidence), encoding="utf-8")

        cases = {
            "archive changed": ("does not match bundle-evidence", tamper_archive),
            "manifest hash": ("bundle-manifest.json does not match",
                              lambda bundle: rewrite_evidence(bundle, lambda e: e["manifest"].update(sha256="0" * 64))),
            "archive path": ("unexpected archive",
                             lambda bundle: rewrite_evidence(bundle, lambda e: e["zip"].update(name="../other.zip"))),
        }
        for label, (reason, change) in cases.items():
            with self.subTest(label):
                bundle = make_bundle(self.root / ("bundle-" + label.replace(" ", "-")))
                change(bundle)
                with self.assertRaisesRegex(windows_msix.PackageError, reason):
                    self.build(bundle, output="out-" + label.replace(" ", "-"))
        with self.assertRaisesRegex(windows_msix.PackageError, "source commit"):
            self.build(make_bundle(self.root / "other-commit"), output="wrong-commit", expected_commit="f" * 40)

    def test_bundle_contents_that_violate_policy_are_refused(self):
        def same_size_tamper(entries, manifest):
            # Recorded hashes come from the untampered bytes.
            manifest["application"]["executableSHA256"] = sha256(entries["SpeakWindows.exe"])

        production = "optimised production executable"
        mutations = {
            "test build": (production, lambda entries, manifest: manifest["application"].update(appBuiltForTesting=True)),
            "debug build": (production, lambda entries, manifest: manifest["application"].update(configuration="debug")),
            "other policy": ("different runtime policy",
                             lambda entries, manifest: manifest.update(policy=dict(manifest["policy"], testModules=[]))),
            "reserved manifest": ("reserved package paths",
                                  lambda entries, manifest: entries.update({"AppxManifest.xml": b"<Package/>"})),
            "reserved metadata": ("reserved package paths",
                                  lambda entries, manifest: entries.update({"AppxMetadata/CodeIntegrity.cat": b"x"})),
            "forbidden symbols": ("policy forbids", lambda entries, manifest: entries.update({"SpeakWindows.pdb": b"x"})),
            "percent name": ("cannot contain", lambda entries, manifest: entries.update({"licenses/100%.txt": b"x"})),
            "missing runtime": ("runtime module is missing", lambda entries, manifest: entries.pop("swiftCore.dll")),
        }
        for label, (reason, mutate) in mutations.items():
            with self.subTest(label):
                bundle = make_bundle(self.root / ("bundle-" + label.replace(" ", "-")), mutate=mutate)
                with self.assertRaisesRegex(windows_msix.PackageError, reason):
                    self.build(bundle, output="out-" + label.replace(" ", "-"))
        with self.assertRaisesRegex(windows_msix.PackageError, "test library XCTest.dll"):
            self.build(make_bundle(self.root / "xctest", exe_imports=("XCTest.dll",)), output="out-xctest")
        bundle = make_bundle(self.root / "bundle-extra")
        archive = next(bundle.glob("*.zip"))
        with zipfile.ZipFile(archive, "a") as handle:
            handle.writestr("extra.txt", b"not in the manifest")
        data = archive.read_bytes()
        evidence = json.loads((bundle / "bundle-evidence.json").read_text(encoding="utf-8"))
        evidence["zip"].update(sha256=sha256(data), bytes=len(data))
        (bundle / "bundle-evidence.json").write_text(json.dumps(evidence), encoding="utf-8")
        with self.assertRaisesRegex(windows_msix.PackageError, "does not list: extra.txt"):
            self.build(bundle, output="out-extra")

    def test_same_size_file_tamper_is_refused(self):
        bundle = make_bundle(self.root / "bundle")
        archive = next(bundle.glob("*.zip"))
        with zipfile.ZipFile(archive) as handle:
            entries = {name: handle.read(name) for name in handle.namelist()}
        notes = bytearray(entries["README.txt"])
        notes[0] ^= 1
        entries["README.txt"] = bytes(notes)
        BUILD.write_deterministic_zip(archive, entries)
        data = archive.read_bytes()
        evidence = json.loads((bundle / "bundle-evidence.json").read_text(encoding="utf-8"))
        evidence["zip"].update(sha256=sha256(data), bytes=len(data))
        (bundle / "bundle-evidence.json").write_text(json.dumps(evidence), encoding="utf-8")
        with self.assertRaisesRegex(windows_msix.PackageError, "README.txt"):
            self.build(bundle)

    def test_invalid_requests_and_unsafe_outputs_are_refused(self):
        bundle = make_bundle(self.root / "bundle")
        for options in ({"version": "1.2.3"}, {"publisher": "Contoso"}):
            with self.assertRaises(windows_msix.PackageError):
                self.build(bundle, output="bad", **options)
        with self.assertRaises(windows_msix.PackageError):
            windows_msix.build_layout(bundle, bundle / "inside", "0.0.1.0")
        (self.root / "occupied").mkdir()
        (self.root / "occupied/file").write_text("x", encoding="utf-8")
        with self.assertRaises(windows_msix.PackageError):
            self.build(bundle, output="occupied")

    def test_layout_changed_after_build_is_refused(self):
        self.build()
        layout = self.root / "out/layout"
        (layout / "README.txt").write_bytes(b"changed")
        with self.assertRaises(windows_msix.PackageError):
            windows_msix.verify_layout(layout)
        (layout / "README.txt").unlink()
        with self.assertRaises(windows_msix.PackageError):
            windows_msix.verify_layout(layout)


class PackageVerificationTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.scratch.name)
        windows_msix.build_layout(make_bundle(self.root / "bundle"), self.root / "out", "0.0.9.1")
        self.layout = self.root / "out/layout"

    def tearDown(self):
        self.scratch.cleanup()

    def test_unsigned_and_signed_packages_must_equal_the_layout(self):
        unsigned = make_package(self.layout, self.root / "unsigned.msix")
        result = windows_msix.verify_package(unsigned, self.layout, signed=False)
        self.assertEqual(result["payloadFiles"], len(windows_msix.verify_layout(self.layout)[1]))
        self.assertEqual(result["identity"]["version"], "0.0.9.1")
        signed = make_package(self.layout, self.root / "signed.msix", signed=True)
        windows_msix.verify_package(signed, self.layout, signed=True, unsigned_reference=unsigned)
        with self.assertRaises(windows_msix.PackageError):
            windows_msix.verify_package(unsigned, self.layout, signed=True)
        with self.assertRaises(windows_msix.PackageError):
            windows_msix.verify_package(signed, self.layout, signed=False)

    def test_payload_block_map_and_signing_differences_are_refused(self):
        unsigned = make_package(self.layout, self.root / "unsigned.msix")
        blockmap = build_blockmap({"README.txt": b"other"})
        cases = {
            "extra": ("unexpected \\['Injected.dll'\\]",
                      make_package(self.layout, self.root / "extra.msix", extra={"Injected.dll": b"MZ"})),
            "missing": ("missing \\['swiftCore.dll'\\]",
                        make_package(self.layout, self.root / "missing.msix", drop=["swiftCore.dll"])),
            "content": ("differs from the layout: README.txt", make_package(
                self.layout, self.root / "content.msix", replace={"README.txt": b"Developer bundlf\n"})),
            "blockmap": ("does not list exactly",
                         make_package(self.layout, self.root / "blockmap.msix", blockmap=blockmap)),
            "metadata": ("unexpected \\['AppxMetadata/CodeIntegrity.cat'\\]", make_package(
                self.layout, self.root / "metadata.msix", extra={"AppxMetadata/CodeIntegrity.cat": b"x"})),
        }
        for label, (reason, package) in cases.items():
            with self.subTest(label), self.assertRaisesRegex(windows_msix.PackageError, reason):
                windows_msix.verify_package(package, self.layout, signed=False)
        stale = build_blockmap({path.relative_to(self.layout).as_posix(): b"stale"
                                for path in self.layout.rglob("*") if path.is_file()})
        with self.assertRaisesRegex(windows_msix.PackageError, "block map hashes do not match"):
            windows_msix.verify_package(make_package(self.layout, self.root / "stale.msix", blockmap=stale),
                                        self.layout, signed=False)
        signed = make_package(self.layout, self.root / "signed.msix", signed=True)
        other = make_package(self.layout, self.root / "other-unsigned.msix",
                             blockmap=build_blockmap({"AppxManifest.xml": b"x"}))
        with self.assertRaisesRegex(windows_msix.PackageError, "signing changed the block map"):
            windows_msix.verify_package(signed, self.layout, signed=True, unsigned_reference=other)
        windows_msix.verify_package(signed, self.layout, signed=True, unsigned_reference=unsigned)

    def test_signing_may_add_only_its_code_integrity_catalogue(self):
        catalogue = {windows_msix.CODE_INTEGRITY_PART: b"0\x82catalogue"}
        unsigned = make_package(self.layout, self.root / "unsigned.msix")
        listed = make_package(self.layout, self.root / "listed.msix", signed=True, listed_extra=catalogue)
        result = windows_msix.verify_package(listed, self.layout, signed=True, unsigned_reference=unsigned)
        self.assertEqual(result["payloadFiles"], len(windows_msix.verify_layout(self.layout)[1]))
        unlisted = make_package(self.layout, self.root / "unlisted.msix", signed=True, extra=catalogue)
        windows_msix.verify_package(unlisted, self.layout, signed=True, unsigned_reference=unsigned)
        with self.assertRaisesRegex(windows_msix.PackageError, "unexpected \\['AppxMetadata/CodeIntegrity.cat'\\]"):
            windows_msix.verify_package(make_package(self.layout, self.root / "unsigned-catalogue.msix",
                                                     listed_extra=catalogue), self.layout, signed=False)
        files = {path.relative_to(self.layout).as_posix(): path.read_bytes()
                 for path in self.layout.rglob("*") if path.is_file()}
        stale = build_blockmap(dict(files, **{windows_msix.CODE_INTEGRITY_PART: b"other"}))
        tampered = make_package(self.layout, self.root / "stale-catalogue.msix", signed=True, extra=catalogue,
                                blockmap=stale)
        with self.assertRaisesRegex(windows_msix.PackageError, "block map hashes do not match AppxMetadata"):
            windows_msix.verify_package(tampered, self.layout, signed=True)
        changed = dict(files, **catalogue)
        changed["README.txt"] = b"changed while signing"
        rewritten = make_package(self.layout, self.root / "rewritten.msix", signed=True, extra=catalogue,
                                 blockmap=build_blockmap(changed))
        with self.assertRaises(windows_msix.PackageError):
            windows_msix.verify_package(rewritten, self.layout, signed=True, unsigned_reference=unsigned)
        other = make_package(self.layout, self.root / "other.msix", blockmap=build_blockmap({"AppxManifest.xml": b"x"}))
        with self.assertRaisesRegex(windows_msix.PackageError, "signing changed the block map"):
            windows_msix.verify_package(listed, self.layout, signed=True, unsigned_reference=other)

    def test_percent_encoded_part_names_are_decoded(self):
        package_manifest = json.loads((self.layout / windows_msix.PACKAGE_MANIFEST).read_text(encoding="utf-8"))
        data = b"spaced"
        (self.layout / "licenses/With Space.txt").write_bytes(data)
        package_manifest["files"].append({"path": "licenses/With Space.txt", "bytes": len(data),
                                          "sha256": sha256(data), "origin": "bundle"})
        (self.layout / windows_msix.PACKAGE_MANIFEST).write_text(json.dumps(package_manifest), encoding="utf-8")
        package = make_package(self.layout, self.root / "spaced.msix")
        with zipfile.ZipFile(package) as archive:
            self.assertIn("licenses/With%20Space.txt", archive.namelist())
        windows_msix.verify_package(package, self.layout, signed=False)


class LifecycleSupportTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.scratch.name)
        self.data = self.root / "JustSpeakToIt"
        self.expectations = lifecycle_support.write_fixture(self.data, self.root / "expectations.json")

    def tearDown(self):
        self.scratch.cleanup()

    def recover_like_the_app(self):
        # DesktopRecordingStore.recoverInterruptedRecordings and
        # PCMRecordingFile.recoverInterruptedFile, reproduced for the test.
        recovery = self.expectations["recovery"]
        record_path = self.data / recovery["record"]
        record = json.loads(record_path.read_text(encoding="utf-8"))
        record["failure"] = recovery["failure"]
        record["createdAt"] = int(record["createdAt"])
        record_path.write_text(json.dumps(record, indent=2, sort_keys=True), encoding="utf-8")
        audio_path = self.data / recovery["audio"]
        audio = bytearray(audio_path.read_bytes())
        payload = len(audio) - 44
        struct.pack_into("<I", audio, 4, payload + 36)
        struct.pack_into("<I", audio, 40, payload)
        audio_path.write_bytes(bytes(audio))

    def test_fixture_uses_the_apps_formats(self):
        completed = json.loads((self.data / ("History/%s.json" % lifecycle_support.COMPLETED_ID)).read_text(encoding="utf-8"))
        self.assertEqual(completed["result"]["text"], lifecycle_support.TRANSCRIPT)
        self.assertEqual(completed["id"], lifecycle_support.COMPLETED_ID)
        self.assertEqual(set(completed["result"]), {"duration", "modelIdentifier", "segments", "text"})
        interrupted = json.loads((self.data / ("History/%s.json" % lifecycle_support.INTERRUPTED_ID)).read_text(encoding="utf-8"))
        self.assertNotIn("result", interrupted)
        self.assertNotIn("failure", interrupted)
        self.assertGreater(completed["createdAt"], interrupted["createdAt"], "completed record is listed first")
        header = (self.data / ("History/%s.wav" % lifecycle_support.INTERRUPTED_ID)).read_bytes()[:44]
        expected = (b"RIFF" + struct.pack("<I", 36) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, 16000, 32000, 2, 16)
                    + b"data" + struct.pack("<I", 0))
        self.assertEqual(header, expected)
        audio = (self.data / ("History/%s.wav" % lifecycle_support.COMPLETED_ID)).read_bytes()
        self.assertEqual(audio[:44], lifecycle_support.wav_header(len(audio) - 44))
        self.assertTrue(any(audio[44:]), "fixture audio is not silent")
        self.assertEqual(json.loads((self.data / "settings.json").read_text(encoding="utf-8")), {"model": lifecycle_support.MODEL})
        with self.assertRaises(SystemExit):
            lifecycle_support.write_fixture(self.data, self.root / "again.json")

    def test_seeded_and_recovered_states_are_checked(self):
        self.assertEqual(lifecycle_support.check_data(self.data, self.expectations, "seeded")["failures"], [])
        self.assertTrue(lifecycle_support.check_data(self.data, self.expectations, "recovered")["failures"])
        self.recover_like_the_app()
        (self.data / "OpenRouterAudioCatalog.json").write_text("{}", encoding="utf-8")
        report = lifecycle_support.check_data(self.data, self.expectations, "recovered")
        self.assertEqual(report["failures"], [])
        self.assertEqual(report["appCreatedFiles"], ["OpenRouterAudioCatalog.json"])
        self.assertTrue(lifecycle_support.check_data(self.data, self.expectations, "seeded")["failures"])

    def test_lost_or_changed_user_data_is_reported(self):
        self.recover_like_the_app()
        cases = {
            "completed audio": lambda: (self.data / ("History/%s.wav" % lifecycle_support.COMPLETED_ID)).write_bytes(b"x"),
            "user note": lambda: (self.data / "keep-user-notes.txt").unlink(),
            "settings": lambda: (self.data / "settings.json").write_text('{"model": "other"}', encoding="utf-8"),
            "unexpected": lambda: (self.data / "History/stray.json").write_text("{}", encoding="utf-8"),
        }
        for label, change in cases.items():
            with self.subTest(label):
                snapshot = {path: path.read_bytes() for path in self.data.rglob("*") if path.is_file()}
                change()
                self.assertTrue(lifecycle_support.check_data(self.data, self.expectations, "recovered")["failures"])
                for path in list(self.data.rglob("*")):
                    if path.is_file() and path not in snapshot:
                        path.unlink()
                for path, data in snapshot.items():
                    path.write_bytes(data)
        audio_path = self.data / self.expectations["recovery"]["audio"]
        audio = bytearray(audio_path.read_bytes())
        audio[-1] ^= 1
        audio_path.write_bytes(bytes(audio))
        self.assertIn("recovered audio samples changed",
                      lifecycle_support.check_data(self.data, self.expectations, "recovered")["failures"])

    def test_tampering_changes_exactly_one_payload_byte(self):
        source = self.root / "package.msix"
        with zipfile.ZipFile(source, "w") as archive:
            archive.writestr("AppxManifest.xml", b"<Package/>")
            archive.writestr(zipfile.ZipInfo("Stored.bin"), bytes(range(256)) * 4)
            archive.writestr("Deflated.txt", b"deflated " * 100, compress_type=zipfile.ZIP_DEFLATED)
        output = self.root / "tampered.msix"
        result = lifecycle_support.tamper(source, output)
        self.assertEqual(result["entry"], "Stored.bin")
        self.assertTrue(result["stored"])
        original, changed = source.read_bytes(), output.read_bytes()
        self.assertEqual(len(original), len(changed))
        self.assertEqual(sum(1 for a, b in zip(original, changed) if a != b), 1)
        with zipfile.ZipFile(output) as archive:
            self.assertEqual(archive.read("Deflated.txt"), b"deflated " * 100)
            with self.assertRaises(zipfile.BadZipFile):
                archive.read("Stored.bin")

    def test_tampering_against_a_reference_changes_only_an_updated_entry(self):
        base = self.root / "base.msix"
        upgrade = self.root / "upgrade.msix"
        for path, version in ((base, b"1"), (upgrade, b"2")):
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("AppxManifest.xml", b"<Package/>")
                archive.writestr(zipfile.ZipInfo("Unchanged.bin"), bytes(range(256)) * 8)
                archive.writestr(zipfile.ZipInfo("package-manifest.json"), (b'{"version": "' + version + b'"}') * 8)
        output = self.root / "tampered.msix"
        result = lifecycle_support.tamper(upgrade, output, base)
        self.assertEqual(result["entry"], "package-manifest.json")
        with zipfile.ZipFile(output) as archive:
            self.assertEqual(archive.read("Unchanged.bin"), bytes(range(256)) * 8)
        with self.assertRaises(SystemExit):
            lifecycle_support.tamper(base, self.root / "same.msix", base)



SIGNING = {
    "AZURE_ARTIFACT_SIGNING_CLIENT_ID": "00000000-0000-4000-8000-000000000001",
    "AZURE_ARTIFACT_SIGNING_TENANT_ID": "00000000-0000-4000-8000-000000000002",
    "AZURE_ARTIFACT_SIGNING_SUBSCRIPTION_ID": "00000000-0000-4000-8000-000000000003",
    "AZURE_ARTIFACT_SIGNING_ENDPOINT": "https://weu.codesigning.azure.net/",
    "AZURE_ARTIFACT_SIGNING_ACCOUNT": "examplesigning",
    "AZURE_ARTIFACT_SIGNING_CERTIFICATE_PROFILE": "example-public",
    "WINDOWS_MSIX_PUBLISHER": "CN=Example Developer, O=Example Developer, L=Leeds, C=GB",
}


class SigningConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = pathlib.Path(self.scratch.name)

    def test_no_settings_keeps_the_unsigned_developer_package(self):
        decision = signing_configuration.plan({"UNRELATED": "1", "AZURE_ARTIFACT_SIGNING_ACCOUNT": "  "})
        self.assertFalse(decision["enabled"])
        self.assertIn("keeping the unsigned developer MSIX", decision["message"])
        output = self.root / "output"
        with unittest.mock.patch.dict("os.environ", {}, clear=True):
            self.assertEqual(signing_configuration.main(["--github-output", str(output),
                                                         "--metadata", str(self.root / "metadata.json")]), 0)
        self.assertEqual(output.read_text(encoding="utf-8"), "enabled=false\n")
        self.assertFalse((self.root / "metadata.json").exists())

    def test_complete_settings_sign_as_the_configured_publisher(self):
        decision = signing_configuration.plan(SIGNING)
        self.assertTrue(decision["enabled"])
        self.assertEqual(decision["publisher"], SIGNING["WINDOWS_MSIX_PUBLISHER"])
        self.assertEqual(decision["timestampUrl"], "http://timestamp.acs.microsoft.com")
        self.assertEqual(decision["metadata"]["Endpoint"], "https://weu.codesigning.azure.net")
        self.assertEqual(decision["metadata"]["CodeSigningAccountName"], "examplesigning")
        self.assertEqual(decision["metadata"]["CertificateProfileName"], "example-public")
        self.assertNotIn("AzureCliCredential", decision["metadata"]["ExcludeCredentials"])
        output, metadata = self.root / "output", self.root / "metadata.json"
        with unittest.mock.patch.dict("os.environ", SIGNING, clear=True):
            self.assertEqual(signing_configuration.main(["--github-output", str(output),
                                                         "--metadata", str(metadata)]), 0)
        self.assertEqual(output.read_text(encoding="utf-8"),
                         "enabled=true\npublisher=" + SIGNING["WINDOWS_MSIX_PUBLISHER"] + "\n")
        self.assertEqual(json.loads(metadata.read_text(encoding="utf-8")), decision["metadata"])
        for secret in signing_configuration.SECRETS:
            self.assertNotIn(SIGNING[secret], metadata.read_text(encoding="utf-8") + output.read_text(encoding="utf-8"))

    def test_partial_settings_fail_naming_only_the_missing_settings(self):
        partial = dict(SIGNING)
        del partial["WINDOWS_MSIX_PUBLISHER"], partial["AZURE_ARTIFACT_SIGNING_TENANT_ID"]
        with self.assertRaises(signing_configuration.SigningConfigurationError) as caught:
            signing_configuration.plan(partial)
        message = str(caught.exception)
        self.assertIn("AZURE_ARTIFACT_SIGNING_TENANT_ID, WINDOWS_MSIX_PUBLISHER", message)
        self.assertNotIn(SIGNING["AZURE_ARTIFACT_SIGNING_CLIENT_ID"], message)
        with unittest.mock.patch.dict("os.environ", partial, clear=True):
            self.assertEqual(signing_configuration.main([]), 1)

    def test_malformed_settings_are_refused(self):
        for name, value in [("AZURE_ARTIFACT_SIGNING_CLIENT_ID", "not-a-guid"),
                            ("AZURE_ARTIFACT_SIGNING_ENDPOINT", "https://example.com"),
                            ("AZURE_ARTIFACT_SIGNING_ENDPOINT", "http://weu.codesigning.azure.net"),
                            ("AZURE_ARTIFACT_SIGNING_ACCOUNT", "ab"),
                            ("AZURE_ARTIFACT_SIGNING_ACCOUNT", "bad--name"),
                            ("AZURE_ARTIFACT_SIGNING_CERTIFICATE_PROFILE", "1profile"),
                            ("WINDOWS_MSIX_PUBLISHER", "Example Developer"),
                            ("WINDOWS_MSIX_PUBLISHER", "CN=Just Speak to It Developer")]:
            with self.subTest(name=name, value=value):
                with self.assertRaisesRegex(signing_configuration.SigningConfigurationError, name):
                    signing_configuration.plan(dict(SIGNING, **{name: value}))

    def test_signed_and_unsigned_layouts_follow_the_plan(self):
        bundle = make_bundle(self.root / "bundle")
        unsigned = windows_msix.build_layout(bundle, self.root / "unsigned", "0.0.9.1")
        self.assertEqual(unsigned["package"]["publisher"], "CN=Just Speak to It Developer")
        decision = signing_configuration.plan(SIGNING)
        signed = windows_msix.build_layout(bundle, self.root / "signed", "0.0.9.1", publisher=decision["publisher"])
        self.assertEqual(signed["package"]["publisher"], SIGNING["WINDOWS_MSIX_PUBLISHER"])
        self.assertNotEqual(signed["package"]["packageFamilyName"], unsigned["package"]["packageFamilyName"])
        layout = self.root / "signed" / "layout"
        reference = make_package(layout, self.root / "reference.msix")
        windows_msix.verify_package(reference, layout, signed=False)
        package = make_package(layout, self.root / "signed.msix", signed=True)
        windows_msix.verify_package(package, layout, signed=True, unsigned_reference=reference)
        with self.assertRaises(windows_msix.PackageError):
            windows_msix.verify_package(package, self.root / "unsigned" / "layout", signed=True)


if __name__ == "__main__":
    unittest.main()
