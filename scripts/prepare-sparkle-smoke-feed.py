#!/usr/bin/env python3
"""Prepare only a synthetic smoke feed; never modify the publication appcast."""
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)
ET.register_namespace("dc", "http://purl.org/dc/elements/1.1/")


def prepare_feed(xml, bumped_version, local_enclosure_url=None):
    if not bumped_version.isdigit():
        raise ValueError("synthetic version must be numeric")
    root = ET.fromstring(xml)
    items = root.findall("./channel/item")
    if len(items) != 1:
        raise ValueError("expected exactly one release item")
    item = items[0]
    enclosures = item.findall("enclosure")
    if len(enclosures) != 1:
        raise ValueError("expected exactly one signed enclosure")
    enclosure = enclosures[0]
    if not enclosure.get(f"{{{SPARKLE}}}edSignature"):
        raise ValueError("enclosure has no EdDSA signature")
    version = item.find(f"{{{SPARKLE}}}version")
    if version is not None:
        version.text = bumped_version
    elif f"{{{SPARKLE}}}version" in enclosure.attrib:
        enclosure.set(f"{{{SPARKLE}}}version", bumped_version)
    else:
        raise ValueError("feed has no sparkle:version")
    if local_enclosure_url:
        # The URL is not covered by the DMG signature. The exact signed bytes
        # are served from loopback for the pre-publication installation gate.
        enclosure.set("url", local_enclosure_url)
    for element in item.iter():
        element.attrib.pop(f"{{{SPARKLE}}}phasedRolloutInterval", None)
    return ET.tostring(root, encoding="unicode", xml_declaration=True)


if __name__ == "__main__":
    source, destination, version, local_url = sys.argv[1:]
    Path(destination).write_text(prepare_feed(Path(source).read_text(), version, local_url), encoding="utf-8")
