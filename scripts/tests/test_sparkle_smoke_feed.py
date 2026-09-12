import importlib.util
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location(
    "smoke_feed", Path(__file__).resolve().parents[1] / "prepare-sparkle-smoke-feed.py"
)
feed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(feed)
NS = "{" + feed.SPARKLE + "}"
XML = f'''<rss xmlns:sparkle="{feed.SPARKLE}"><channel><item>
<sparkle:version>202609051234</sparkle:version>
<sparkle:shortVersionString>2.30.1</sparkle:shortVersionString>
<description><![CDATA[<p>Release notes</p>]]></description>
<enclosure url="https://example.test/release.dmg" sparkle:edSignature="signed-bytes=="
length="123456" type="application/octet-stream" sparkle:phasedRolloutInterval="86400"/>
</item></channel></rss>'''


class SmokeFeedTests(unittest.TestCase):
    def test_local_enclosure_keeps_signature_size_and_marketing_version(self):
        root = ET.fromstring(feed.prepare_feed(XML, "202609051235", "http://127.0.0.1:8000/enclosure.dmg"))
        item = root.find("./channel/item")
        enclosure = item.find("enclosure")
        self.assertEqual(enclosure.get("url"), "http://127.0.0.1:8000/enclosure.dmg")
        self.assertEqual(enclosure.get(NS + "edSignature"), "signed-bytes==")
        self.assertEqual(enclosure.get("length"), "123456")
        self.assertEqual(item.find(NS + "version").text, "202609051235")
        self.assertEqual(item.find(NS + "shortVersionString").text, "2.30.1")
        self.assertEqual(item.find("description").text, "<p>Release notes</p>")
        self.assertNotIn(NS + "phasedRolloutInterval", enclosure.attrib)

    def test_published_mode_keeps_original_download_url(self):
        root = ET.fromstring(feed.prepare_feed(XML, "202609051235"))
        self.assertEqual(root.find("./channel/item/enclosure").get("url"), "https://example.test/release.dmg")

    def test_legacy_version_attribute(self):
        xml = XML.replace("<sparkle:version>202609051234</sparkle:version>", "").replace(
            '<enclosure url=', '<enclosure sparkle:version="202609051234" url='
        )
        root = ET.fromstring(feed.prepare_feed(xml, "202609051235"))
        self.assertEqual(root.find("./channel/item/enclosure").get(NS + "version"), "202609051235")

    def test_rejects_ambiguous_or_unsigned_or_versionless_feed(self):
        for xml in [
            XML.replace('sparkle:edSignature="signed-bytes=="', ''),
            XML.replace("<sparkle:version>202609051234</sparkle:version>", ""),
            XML.replace("</channel>", "<item/></channel>"),
            XML.replace("</item>", "<enclosure/></item>"),
            '<rss><channel/></rss>',
        ]:
            with self.subTest(xml=xml), self.assertRaises(ValueError):
                feed.prepare_feed(xml, "202609051235")

    def test_rejects_non_numeric_version(self):
        with self.assertRaises(ValueError):
            feed.prepare_feed(XML, "broken")


if __name__ == "__main__":
    unittest.main()
