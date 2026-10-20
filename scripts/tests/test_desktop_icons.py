"""Native icon/resource/packaging invariants, with no platform SDK or image library."""
import importlib.util
import pathlib
import struct
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ICONS = load("desktop_icons", "scripts/generate-desktop-icons.py")
STAGE = load("stage_linux", "scripts/stage-linux-desktop.py")


def ico_frames(data):
    reserved, kind, count = struct.unpack_from("<HHH", data)
    assert (reserved, kind) == (0, 1)
    frames = {}
    end = 6 + count * 16
    for index in range(count):
        width, height, colours, reserved, planes, depth, length, offset = struct.unpack_from(
            "<BBBBHHII", data, 6 + index * 16)
        assert width == height and (colours, reserved, planes, depth) == (0, 0, 1, 32)
        assert offset == end
        end += length
        assert end <= len(data)
        frames[width or 256] = data[offset:end]
    assert end == len(data)
    return frames


def res_entries(data):
    entries, cursor = {}, 0
    while cursor < len(data):
        size, header, ordinal_type, kind, ordinal_name, name, version, flags, language, data_version, characteristics = (
            struct.unpack_from("<IIHHHHIHHII", data, cursor))
        assert header == 32 and ordinal_type == ordinal_name == 0xffff
        assert version == language == data_version == characteristics == 0
        assert flags == (0x1030 if kind else 0)
        end = cursor + header + size
        assert end <= len(data)
        assert (kind, name) not in entries
        entries[kind, name] = data[cursor + header:end]
        aligned = (end + 3) & ~3
        assert not any(data[end:aligned])
        cursor = aligned
    assert cursor == len(data)
    return entries


class DesktopIconTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.exports = ICONS.exports()

    def test_checked_in_exports_are_exact_and_complete(self):
        for path, expected in self.exports.items():
            self.assertEqual((ROOT / path).read_bytes(), expected, path)
        theme = ROOT / "Sources/SpeakLinux/Resources/hicolor"
        actual = {str(path.relative_to(ROOT)).replace("\\", "/") for path in theme.rglob("*") if path.is_file()}
        self.assertEqual(actual, {path for path in self.exports if "/hicolor/" in path})

    def test_ico_contains_all_native_dpi_sizes_and_canonical_pixels(self):
        frames = ico_frames(self.exports["Resources/Desktop/AppIcon.ico"])
        self.assertEqual(tuple(frames), ICONS.SIZES)
        for size, png in frames.items():
            self.assertEqual(png, ICONS.canonical_png(size))
            width, height, rgba = ICONS.IMAGES.decode_png(png)
            self.assertEqual((width, height), (size, size))
            self.assertEqual(rgba[3], 0)
            self.assertEqual(rgba[((size // 2) * size + size // 2) * 4 + 3], 255)

    def test_architecture_neutral_resource_groups_reference_exact_icon_payloads(self):
        entries = res_entries(self.exports["Resources/Desktop/AppIcon.res"])
        self.assertEqual(entries.pop((0, 0)), b"")
        self.assertEqual(len(entries), 2 + 2 * len(ICONS.SIZES))
        referenced = set()
        for group_id in (ICONS.IDLE_ID, ICONS.RECORDING_ID):
            group = entries[14, group_id]
            self.assertEqual(struct.unpack_from("<HHH", group), (0, 1, len(ICONS.SIZES)))
            self.assertEqual(len(group), 6 + 14 * len(ICONS.SIZES))
            for index, size in enumerate(ICONS.SIZES):
                width, height, colours, reserved, planes, depth, length, identifier = struct.unpack_from(
                    "<BBBBHHIH", group, 6 + index * 14)
                self.assertEqual((width or 256, height or 256), (size, size))
                self.assertEqual((colours, reserved, planes, depth), (0, 0, 1, 32))
                referenced.add(identifier)
                png = entries[3, identifier]
                self.assertEqual(len(png), length)
                expected = ICONS.canonical_png(size)
                if group_id == ICONS.RECORDING_ID:
                    expected = ICONS.recording_png(expected)
                self.assertEqual(png, expected)
        self.assertEqual(referenced, {name for kind, name in entries if kind == 3})

    def test_recording_indicator_preserves_artwork_outside_overlay(self):
        for size in ICONS.SIZES:
            idle = ICONS.canonical_png(size)
            _, _, before = ICONS.IMAGES.decode_png(idle)
            _, _, after = ICONS.IMAGES.decode_png(ICONS.recording_png(idle))
            dot = max(6, size * 7 // 16)
            for y in range(size):
                for x in range(size):
                    if x < size - dot or y < size - dot:
                        offset = (y * size + x) * 4
                        self.assertEqual(before[offset:offset + 4], after[offset:offset + 4])
            self.assertNotEqual(before, after)

    def test_linux_theme_sizes_match_exact_mac_artwork_and_desktop_identity(self):
        theme = ROOT / "Sources/SpeakLinux/Resources/hicolor"
        for size in (16, 24, 32, 48, 64, 128, 256, 512):
            png = theme / f"{size}x{size}/apps/{ICONS.APP_ID}.png"
            self.assertEqual(png.read_bytes(), ICONS.canonical_png(size))
            self.assertIn(f"[{size}x{size}/apps]\nSize={size}", (theme / "index.theme").read_text())
        desktop = (ROOT / f"packaging/linux/{ICONS.APP_ID}.desktop").read_text()
        self.assertIn("Icon=" + ICONS.APP_ID, desktop)
        self.assertIn('let linuxApplicationID = "' + ICONS.APP_ID + '"', (ROOT / "Sources/SpeakLinux/main.swift").read_text())

    def test_native_and_flatpak_resource_wiring(self):
        package = (ROOT / "Package.swift").read_text()
        self.assertIn('.appendingPathComponent("Resources/Desktop/AppIcon.res").path', package)
        self.assertIn('resources: [.copy("Resources/hicolor")]', package)
        native = (ROOT / "Sources/CWindowsSupport/WindowsAppIcon.cpp").read_text()
        self.assertIn("idleResource = 101, recordingResource = 102", native)
        self.assertIn("GetSystemMetricsForDpi", native)
        window = (ROOT / "Sources/CWindowsSupport/WindowsWindow.cpp").read_text()
        self.assertIn("jsti::appIcon::selfTest(window, failure)", window)
        self.assertIn("jsti::appIcon::refresh(window, HIWORD(wparam)", window)
        self.assertNotIn("IDI_APPLICATION", window)
        flatpak = (ROOT / f"packaging/linux/{ICONS.APP_ID}.yml").read_text()
        self.assertIn("python3 scripts/stage-linux-desktop.py --binary .build/release/SpeakLinux", flatpak)
        self.assertIn("--output .build/linux-desktop-layout --prefix /app", flatpak)
        self.assertIn("cp -r .build/linux-desktop-layout/. /app/", flatpak)
        linux = (ROOT / "Sources/CLinuxSupport/LinuxAppIcon.c").read_text()
        self.assertIn("gtk_icon_theme_add_search_path", linux)
        self.assertIn("gdk_cairo_set_source_pixbuf", linux)

    def test_windows_accessors_do_not_collide_with_rpc_small_macro(self):
        header = (ROOT / "Sources/CWindowsSupport/WindowsAppIcon.hpp").read_text()
        source = (ROOT / "Sources/CWindowsSupport/WindowsAppIcon.cpp").read_text()
        window = (ROOT / "Sources/CWindowsSupport/WindowsWindow.cpp").read_text()
        self.assertNotRegex(header + source + window, r"\bsmall\s*\(")
        self.assertIn("HICON smallHandle();", header)
        self.assertIn("HICON smallHandle()", source)
        self.assertIn("jsti::appIcon::smallHandle()", window)

    def test_asset_attributes_trigger_resource_and_native_workflows(self):
        for workflow in ("desktop-icons.yml", "windows.yml", "windows-arm64.yml",
                         "windows-cross-proof.yml", "linux.yml"):
            lines = (ROOT / ".github/workflows" / workflow).read_text().splitlines()
            for event in ("push", "pull_request"):
                with self.subTest(workflow=workflow, event=event):
                    start = lines.index(f"  {event}:") + 1
                    end = next((index for index in range(start, len(lines))
                                if lines[index].strip() and not lines[index].startswith("    ")
                                and not lines[index].lstrip().startswith("#")), len(lines))
                    self.assertIn("      - .gitattributes", lines[start:end])

    def test_resource_workflow_pins_reviewed_remote_actions(self):
        workflow = (ROOT / ".github/workflows/desktop-icons.yml").read_text()
        self.assertIn("actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1", workflow)
        for line in workflow.splitlines():
            if "uses:" in line:
                action = line.split("uses:", 1)[1].strip().split()[0]
                self.assertRegex(action, r"^[^@]+@[0-9a-f]{40}$")

    def test_linux_integration_assertion_includes_high_dpi_tray_pixmaps(self):
        integration = (ROOT / "scripts/linux-integration-checks.sh").read_text()
        self.assertIn("[22, 22], [32, 32], [48, 48], [64, 64], [96, 96]", integration)

    def test_msix_includes_high_dpi_and_light_dark_unplated_start_menu_icons(self):
        identity = ICONS.IMAGES.load_identity()
        sizes = identity["assets"]["images"]
        self.assertEqual(sizes["Assets/Square150x150Logo.scale-400.png"], 600)
        self.assertEqual(sizes["Assets/Square44x44Logo.scale-400.png"], 176)
        for size in (16, 24, 32, 48, 256):
            for appearance in ("unplated", "lightunplated"):
                self.assertEqual(sizes[f"Assets/Square44x44Logo.targetsize-{size}_altform-{appearance}.png"], size)
        manifest = ICONS.IMAGES.render_manifest(identity, "0.0.1.0", identity["identity"]["developerPublisher"])
        self.assertIn(b'Square44x44Logo="Assets\\Square44x44Logo.png"', manifest)

    def test_portable_shortcut_guidance_uses_embedded_executable_icon(self):
        readme = ICONS.IMAGES.BUNDLE.readme_text({}, [], {"displayName": "test runtime"})
        self.assertIn("$link.IconLocation = $link.TargetPath + ',0'", readme)
        self.assertIn("[Environment]::GetFolderPath('Programs')", readme)
        self.assertIn("$link.Save()", readme)

    def test_linux_staging_ships_identical_runtime_and_installed_icons(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = pathlib.Path(scratch)
            build = root / "build"
            build.mkdir()
            binary = build / "SpeakLinux"
            binary.write_bytes(b"synthetic executable")
            core = build / "SpeakApp_SpeakCore.resources"
            core.mkdir()
            (core / "fixture.json").write_bytes(b"{}")
            import shutil
            shutil.copytree(ROOT / "Sources/SpeakLinux/Resources/hicolor",
                            build / "SpeakApp_SpeakLinux.resources/hicolor")
            future = build / "SpeakApp_FutureFeature.resources/nested"
            future.mkdir(parents=True)
            (future / "fixture.bin").write_bytes(b"future production resource")
            tests = build / "SpeakApp_FutureFeatureTests.resources"
            tests.mkdir()
            (tests / "fixture.bin").write_bytes(b"test-only resource")
            (build / "unrelated").mkdir()
            output = root / "layout"
            STAGE.stage(binary, output, "/opt/Just Speak to It")
            self.assertEqual((output / "bin/justspeaktoit").read_bytes(), binary.read_bytes())
            self.assertEqual((output / "bin/SpeakApp_SpeakCore.resources/fixture.json").read_bytes(), b"{}")
            self.assertEqual((output / "bin/SpeakApp_FutureFeature.resources/nested/fixture.bin").read_bytes(),
                             b"future production resource")
            self.assertFalse((output / "bin/SpeakApp_FutureFeatureTests.resources").exists())
            self.assertFalse((output / "bin/unrelated").exists())
            self.assertFalse((output / "share/icons/hicolor/index.theme").exists())
            for png in (output / "share/icons/hicolor").rglob("*.png"):
                relative = png.relative_to(output / "share/icons")
                self.assertEqual(png.read_bytes(), (output / "bin/SpeakApp_SpeakLinux.resources" / relative).read_bytes())
            desktop = (output / f"share/applications/{ICONS.APP_ID}.desktop").read_text()
            self.assertIn('Exec="/opt/Just Speak to It/bin/justspeaktoit"', desktop)
            self.assertIn("Icon=" + ICONS.APP_ID, desktop)
            with self.assertRaisesRegex(ValueError, "new directory"):
                STAGE.stage(binary, output)

    def test_linux_staging_refuses_missing_resources_before_writing(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = pathlib.Path(scratch)
            binary = root / "SpeakLinux"
            binary.write_bytes(b"synthetic executable")
            output = root / "layout"
            with self.assertRaisesRegex(ValueError, "resource bundles"):
                STAGE.stage(binary, output)
            self.assertFalse(output.exists())

    def test_linux_staging_refuses_nonportable_exec_prefixes_before_writing(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = pathlib.Path(scratch)
            binary = root / "SpeakLinux"
            binary.write_bytes(b"synthetic executable")
            output = root / "layout"
            for prefix in ("/opt/100%ready", "/opt/equal=name"):
                with self.subTest(prefix=prefix), self.assertRaisesRegex(ValueError, "percent or equal signs"):
                    STAGE.stage(binary, output, prefix)
                self.assertFalse(output.exists())

    @unittest.skipUnless(sys.platform.startswith("linux"), "GLib launcher acceptance requires Linux")
    def test_linux_staged_exec_round_trips_accepted_prefixes_through_glib_launch(self):
        import ctypes
        import ctypes.util
        import json
        import shutil
        import time
        library = ctypes.util.find_library("gio-2.0")
        if library is None:
            self.skipTest("GLib is unavailable")
        gio = ctypes.CDLL(library)
        gio.g_desktop_app_info_new_from_filename.argtypes = [ctypes.c_char_p]
        gio.g_desktop_app_info_new_from_filename.restype = ctypes.c_void_p
        gio.g_app_info_launch.argtypes = [
            ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]
        gio.g_app_info_launch.restype = ctypes.c_int
        gobject = ctypes.CDLL("libgobject-2.0.so.0")
        gobject.g_object_unref.argtypes = [ctypes.c_void_p]
        gobject.g_object_unref.restype = None
        with tempfile.TemporaryDirectory() as scratch:
            root = pathlib.Path(scratch)
            build = root / "build"
            build.mkdir()
            binary = build / "SpeakLinux"
            (build / "SpeakApp_SpeakCore.resources").mkdir()
            shutil.copytree(ROOT / "Sources/SpeakLinux/Resources/hicolor",
                            build / "SpeakApp_SpeakLinux.resources/hicolor")
            for number, name in enumerate(("plain", "space path", "backslash\\path", 'quote"path',
                                           "dollar$path", "tick`path", "single'path")):
                with self.subTest(prefix=name):
                    output = root / name
                    receipt = root / f"receipt-{number}.json"
                    pending = receipt.with_suffix(".tmp")
                    binary.write_text(
                        "#!/usr/bin/env python3\nimport json,sys\nfrom pathlib import Path\n"
                        f"pending=Path({str(pending)!r})\npending.write_text(json.dumps(sys.argv))\n"
                        f"pending.replace({str(receipt)!r})\n", encoding="utf-8")
                    STAGE.stage(binary, output, str(output))
                    desktop = output / f"share/applications/{ICONS.APP_ID}.desktop"
                    info = gio.g_desktop_app_info_new_from_filename(str(desktop).encode())
                    self.assertTrue(info, "GLib rejected the staged desktop entry")
                    try:
                        error = ctypes.c_void_p()
                        self.assertTrue(gio.g_app_info_launch(info, None, None, ctypes.byref(error)),
                                        "GLib could not launch the synthetic executable")
                        deadline = time.monotonic() + 5
                        while not receipt.exists() and time.monotonic() < deadline:
                            time.sleep(.01)
                        self.assertTrue(receipt.exists(), "Synthetic launcher did not write its receipt")
                        self.assertEqual(json.loads(receipt.read_text()), [str(output / "bin/justspeaktoit")])
                    finally:
                        gobject.g_object_unref(info)

    def test_linux_staging_still_requires_core_and_icon_bundles_with_future_resources(self):
        for missing in ("core", "icons"):
            with self.subTest(missing=missing), tempfile.TemporaryDirectory() as scratch:
                root = pathlib.Path(scratch)
                binary = root / "SpeakLinux"
                binary.write_bytes(b"synthetic executable")
                (root / "SpeakApp_FutureFeature.resources").mkdir()
                if missing != "core":
                    (root / "SpeakApp_SpeakCore.resources").mkdir()
                if missing != "icons":
                    (root / "SpeakApp_SpeakLinux.resources/hicolor").mkdir(parents=True)
                output = root / "layout"
                with self.assertRaisesRegex(ValueError, "resource bundles"):
                    STAGE.stage(binary, output)
                self.assertFalse(output.exists())

    def test_linux_staging_refuses_non_directory_resource_bundles_before_writing(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = pathlib.Path(scratch)
            binary = root / "SpeakLinux"
            binary.write_bytes(b"synthetic executable")
            (root / "SpeakApp_Invalid.resources").write_bytes(b"not a directory")
            output = root / "layout"
            with self.assertRaisesRegex(ValueError, "resource bundle must be a regular directory"):
                STAGE.stage(binary, output)
            self.assertFalse(output.exists())

    def test_linux_staging_refuses_linked_resource_bundles_and_entries_before_writing(self):
        from unittest import mock
        with tempfile.TemporaryDirectory() as scratch:
            root = pathlib.Path(scratch)
            binary = root / "SpeakLinux"
            binary.write_bytes(b"synthetic executable")
            bundle = root / "SpeakApp_FutureFeature.resources"
            bundle.mkdir()
            entry = bundle / "fixture.bin"
            entry.write_bytes(b"fixture")
            output = root / "layout"
            for linked in (bundle, entry):
                with self.subTest(linked=linked), mock.patch.object(
                        pathlib.Path, "is_symlink", lambda path: path == linked):
                    with self.assertRaisesRegex(ValueError, "resource"):
                        STAGE.stage(binary, output)
                self.assertFalse(output.exists())

    def test_check_mode_refuses_a_stale_export(self):
        expected = self.exports["Resources/Desktop/AppIcon.ico"]
        with tempfile.TemporaryDirectory() as scratch:
            root = pathlib.Path(scratch)
            (root / "Resources/Desktop").mkdir(parents=True)
            (root / "Resources/Desktop/AppIcon.ico").write_bytes(expected[:-1])
            from unittest import mock
            import contextlib
            import io
            with mock.patch.object(ICONS, "ROOT", root), mock.patch.object(ICONS, "exports",
                    return_value={"Resources/Desktop/AppIcon.ico": expected}), mock.patch.object(
                    sys, "argv", ["icons", "--check"]), contextlib.redirect_stderr(io.StringIO()) as failure:
                self.assertEqual(ICONS.main(), 1)
                self.assertIn("Stale desktop icons", failure.getvalue())


if __name__ == "__main__":
    unittest.main()
