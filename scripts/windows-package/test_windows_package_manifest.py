#!/usr/bin/env python3
"""Package identity, the AppxManifest and its visual assets; no downloads, caches or Windows APIs."""
import copy
import json
import pathlib
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

HERE = pathlib.Path(__file__).resolve().parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(HERE))
import windows_msix  # noqa: E402
from package_test_fixtures import sha256  # noqa: E402


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
        shared = (windows_msix.REPOSITORY / "Sources/SpeakDesktop/Shell/DesktopLoginItem.swift").read_text(encoding="utf-8")
        self.assertIn('constexpr wchar_t identifier[] = L"%s";' % startup["id"], native)
        self.assertIn('constexpr wchar_t launchArgument[] = L"%s";' % startup["parameters"], native)
        self.assertIn('public static let launchArgument = "%s"' % startup["parameters"], shared)

    def test_cli_alias_matches_the_automation_setup_dialog(self):
        # General › CLI and MCP setup locates the packaged speak command by
        # this alias; a rename on one side must fail here.
        alias = windows_msix.load_identity()["cli"]["executionAlias"]
        native = (windows_msix.REPOSITORY / "Sources/CWindowsSupport/WindowsAutomationSettings.cpp").read_text(
            encoding="utf-8")
        self.assertIn('L"%s"' % alias, native)
        self.assertIn('L"\\\\Microsoft\\\\WindowsApps\\\\"', native)

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


if __name__ == "__main__":
    unittest.main()
