import base64
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "linux-flatpak-repo.py"
spec = importlib.util.spec_from_file_location("linux_flatpak_repo", SCRIPT)
repo = importlib.util.module_from_spec(spec)
spec.loader.exec_module(repo)

KEY = b"\x99\x01\x0dpublic-key-bytes"
URL = "https://justspeaktoit-flatpak.pages.dev/repo"


def fields(text: str) -> dict:
    lines = text.strip().splitlines()
    return dict(line.split("=", 1) for line in lines[1:])


class DescriptorTests(unittest.TestCase):
    def test_flatpakref_installs_the_app_with_the_flathub_runtime_and_pinned_key(self):
        text = repo.flatpakref(URL, KEY)
        self.assertTrue(text.startswith("[Flatpak Ref]\n"))
        values = fields(text)
        self.assertEqual(values["Name"], "com.justspeaktoit.JustSpeakToIt")
        self.assertEqual(values["Branch"], "master")
        self.assertEqual(values["Url"], URL + "/")
        self.assertEqual(values["RuntimeRepo"], "https://dl.flathub.org/repo/flathub.flatpakrepo")
        self.assertEqual(values["IsRuntime"], "false")
        self.assertEqual(base64.b64decode(values["GPGKey"]), KEY)

    def test_flatpakrepo_adds_a_signed_remote(self):
        values = fields(repo.flatpakrepo(URL + "/", KEY))
        self.assertEqual(values["Url"], URL + "/")
        self.assertEqual(base64.b64decode(values["GPGKey"]), KEY)
        self.assertEqual(values["DefaultBranch"], "master")

    def test_plain_http_repository_is_refused(self):
        with self.assertRaises(ValueError):
            repo.flatpakref("http://example.com/repo", KEY)

    def test_write_descriptors_includes_a_404_page_and_channel(self):
        with tempfile.TemporaryDirectory() as directory:
            site = Path(directory)
            repo.write_descriptors(site, URL, KEY, "alpha-build-12")
            self.assertTrue((site / "404.html").is_file())
            self.assertEqual(json.loads((site / "channel.json").read_text())["tag"], "alpha-build-12")
            self.assertIn("application/vnd.flatpak.ref", (site / "_headers").read_text())
            with self.assertRaises(ValueError):
                repo.write_descriptors(site, URL, b"", "alpha-build-12")


class PublicationTests(unittest.TestCase):
    def test_only_a_strictly_newer_alpha_replaces_the_published_one(self):
        self.assertTrue(repo.should_publish("alpha-build-9", None))
        self.assertTrue(repo.should_publish("alpha-build-10", "alpha-build-9"))
        self.assertFalse(repo.should_publish("alpha-build-9", "alpha-build-9"))
        self.assertFalse(repo.should_publish("alpha-build-8", "alpha-build-9"))
        self.assertTrue(repo.should_publish("alpha-build-8", "garbage"))
        with self.assertRaises(ValueError):
            repo.should_publish("mac-v1.0.0", None)

    def test_check_site_reports_files_over_the_pages_limit(self):
        with tempfile.TemporaryDirectory() as directory:
            site = Path(directory)
            (site / "small").write_bytes(b"x")
            self.assertEqual(repo.check_site(site), [])
            with open(site / "large", "wb") as handle:
                handle.truncate(repo.MAX_FILE_BYTES + 1)
            self.assertEqual(len(repo.check_site(site)), 1)


if __name__ == "__main__":
    unittest.main()
