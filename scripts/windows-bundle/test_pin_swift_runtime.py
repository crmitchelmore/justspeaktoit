"""7-Zip selection for pin-swift-runtime.py, so ARM64 bundles can assemble on Linux; no downloads."""
import importlib.util
import io
import json
import pathlib
import tarfile
import tempfile
import unittest
from unittest import mock

HERE = pathlib.Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("pin_swift_runtime", HERE / "pin-swift-runtime.py")
PIN = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(PIN)


class SevenZipPinTests(unittest.TestCase):
    def test_each_supported_host_has_a_pinned_console(self):
        self.assertTrue(PIN.seven_pin("darwin", "arm64")["name"].endswith("-mac.tar.xz"))
        self.assertEqual(PIN.seven_pin("linux", "x86_64")["name"], "7z2603-linux-x64.tar.xz")
        self.assertEqual(PIN.seven_pin("linux", "AMD64")["name"], "7z2603-linux-x64.tar.xz")
        self.assertEqual(PIN.seven_pin("linux", "aarch64")["name"], "7z2603-linux-arm64.tar.xz")
        with self.assertRaises(PIN.PinError):
            PIN.seven_pin("win32", "x86_64")

    def test_linux_pins_are_complete_and_match_the_macos_release(self):
        lock = json.loads((HERE / "dependencies.json").read_text(encoding="utf-8"))
        mac = PIN.seven_pin("darwin", "arm64")
        release = mac["url"].rsplit("/", 1)[0]
        for pin in lock["sevenZipLinux"]:
            self.assertEqual(pin["url"], release + "/" + pin["name"])
            self.assertRegex(pin["sha256"], r"^[0-9a-f]{64}$")
            self.assertGreater(pin["bytes"], 0)

    def test_only_the_console_is_extracted(self):
        with tempfile.TemporaryDirectory() as scratch:
            downloads = pathlib.Path(scratch)
            archive = downloads / "7z-test.tar.xz"
            with tarfile.open(archive, "w:xz") as bundle:
                for name, data in (("7zz", b"binary"), ("readme.txt", b"x")):
                    info = tarfile.TarInfo(name)
                    info.size = len(data)
                    bundle.addfile(info, io.BytesIO(data))
            with mock.patch.object(PIN, "download", lambda pin, directory: archive):
                console = PIN.pinned_seven(downloads, {"name": "7z-test.tar.xz"})
            self.assertEqual(console.read_bytes(), b"binary")
            self.assertTrue(console.stat().st_mode & 0o100)
            self.assertEqual(sorted(p.name for p in console.parent.iterdir()), ["7zz"])


if __name__ == "__main__":
    unittest.main()
