#!/usr/bin/env python3
"""Generate the App Installer file and winget manifest template for a Windows build.

The input is a built ``.msixbundle`` (or a single ``.msix``) and the channel it
belongs to in ``update-channels.json``. The output is:

* ``<channel>.appinstaller``: an App Installer file whose ``Uri`` is the
  channel's stable feed location and whose main bundle points at the immutable
  versioned release asset, with update checks on launch and in the background;
* ``winget/`` (for channels with a winget identity): the version, installer and
  default-locale manifests for ``winget-pkgs``, as a template. It is never
  submitted; unsigned builds carry no ``SignatureSha256`` and cannot be
  submitted at all.

URLs come from ``--feed-base`` (default ``WINDOWS_UPDATE_FEED_BASE`` or the
channel file's GitHub Releases base) and ``--tag``. Nothing is uploaded.
"""
import argparse
import hashlib
import json
import os
import pathlib
import re
import sys
import urllib.parse
import xml.etree.ElementTree as ET
import zipfile
from xml.sax.saxutils import escape

HERE = pathlib.Path(__file__).resolve().parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(HERE))
import windows_msix  # noqa: E402

CHANNELS_PATH = HERE / "update-channels.json"
APPINSTALLER_NAMESPACE = "http://schemas.microsoft.com/appx/appinstaller/2021"
FEED_VARIABLE = "WINDOWS_UPDATE_FEED_BASE"
TAG_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}")


class UpdateChannelError(Exception):
    pass


def load_channels(path=CHANNELS_PATH, trains_path=windows_msix.REPOSITORY / "Sources/SpeakCore/Resources/ReleaseTrains.json"):
    data = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
    if data.get("schemaVersion") != 1 or set(data.get("channels", {})) != {"developer", "alpha", "stable"}:
        raise UpdateChannelError("update-channels.json must define exactly developer, alpha and stable")
    trains = json.loads(pathlib.Path(trains_path).read_text(encoding="utf-8"))
    names = set()
    for name, channel in data["channels"].items():
        windows_msix.validate_name(channel["packageName"])
        if channel["packageName"] in names:
            raise UpdateChannelError("each channel needs its own package name")
        names.add(channel["packageName"])
        if channel["releaseTrain"] not in (None, "alpha", "stable") or (
                (channel["releaseTrain"] is None) != (name == "developer")):
            raise UpdateChannelError("only the developer channel is outside the release trains")
        if channel["releaseTrain"] and channel["releaseTrain"] not in trains:
            raise UpdateChannelError("unknown release train " + channel["releaseTrain"])
        if not channel["appInstaller"].endswith(".appinstaller") or "/" in channel["appInstaller"]:
            raise UpdateChannelError("appInstaller must be a file name ending .appinstaller")
    if data["channels"]["developer"]["packageName"] != windows_msix.load_identity()["identity"]["name"]:
        raise UpdateChannelError("the developer channel must be package-identity.json's package")
    if data["channels"]["alpha"]["appInstallerLocation"] == "github-latest":
        raise UpdateChannelError("Alpha is never GitHub Latest, so its App Installer file cannot live there")
    return data


def feed_base(channels, override=None, environment=os.environ):
    base = (override or environment.get(FEED_VARIABLE) or channels["feedBase"]).rstrip("/")
    parts = urllib.parse.urlsplit(base)
    if parts.scheme != "https" or not parts.netloc or parts.query or parts.fragment:
        raise UpdateChannelError("the feed base must be an https URL without a query")
    return base


def locations(channels, channel_name, tag, package_file, base, appinstaller_override=None):
    """``(appinstaller_uri, package_uri)`` for a channel's files."""
    channel = channels["channels"][channel_name]
    if not TAG_PATTERN.fullmatch(tag or ""):
        raise UpdateChannelError("the release tag must be 1-128 letters, digits, '.', '_' or '-'")
    quoted = urllib.parse.quote(package_file)
    package_uri = "%s/download/%s/%s" % (base, urllib.parse.quote(tag), quoted)
    location = channel["appInstallerLocation"]
    if appinstaller_override:
        appinstaller_uri = appinstaller_override
    elif location == "github-latest":
        appinstaller_uri = "%s/latest/download/%s" % (base, urllib.parse.quote(channel["appInstaller"]))
    elif location == "release-asset":
        appinstaller_uri = "%s/download/%s/%s" % (base, urllib.parse.quote(tag), urllib.parse.quote(channel["appInstaller"]))
    elif location.startswith("variable:"):
        raise UpdateChannelError("the %s channel's App Installer URL comes from %s; pass --appinstaller-uri"
                                 % (channel_name, location.split(":", 1)[1]))
    else:
        raise UpdateChannelError("unknown App Installer location " + location)
    if urllib.parse.urlsplit(appinstaller_uri).scheme != "https":
        raise UpdateChannelError("App Installer files must be served over https")
    return appinstaller_uri, package_uri


def package_facts(path):
    """Identity, architectures and hashes of a built .msixbundle or .msix."""
    path = pathlib.Path(path)
    data = path.read_bytes()
    facts = {"file": path.name, "sha256": hashlib.sha256(data).hexdigest().upper(), "signatureSha256": None}
    try:
        with zipfile.ZipFile(path) as archive:
            names = set(archive.namelist())
            if windows_msix.SIGNATURE_PART in names:
                facts["signatureSha256"] = hashlib.sha256(archive.read(windows_msix.SIGNATURE_PART)).hexdigest().upper()
            if windows_msix.BUNDLE_MANIFEST_PART in names:
                root = ET.fromstring(archive.read(windows_msix.BUNDLE_MANIFEST_PART))
                ns = {"b": windows_msix.BUNDLE_NAMESPACE}
                identity = root.find("b:Identity", ns)
                facts.update(kind="bundle", name=identity.get("Name"), publisher=identity.get("Publisher"),
                             version=identity.get("Version"),
                             architectures=sorted(element.get("Architecture")
                                                  for element in root.findall("b:Packages/b:Package", ns)))
            else:
                identity = windows_msix.read_package_identity(path)
                facts.update(kind="package", name=identity["Name"], publisher=identity["Publisher"],
                             version=identity["Version"], architectures=[identity["ProcessorArchitecture"]])
    except (zipfile.BadZipFile, ET.ParseError, AttributeError) as error:
        raise UpdateChannelError("%s is not a readable MSIX package or bundle: %s" % (path.name, error))
    windows_msix.validate_publisher(facts["publisher"])
    windows_msix.validate_version(facts["version"])
    facts["packageFamilyName"] = facts["name"] + "_" + windows_msix.publisher_id(facts["publisher"])
    return facts


def appinstaller_xml(facts, appinstaller_uri, package_uri, hours=12):
    """The App Installer file: check for updates at launch (without blocking it)
    and in the background, and allow a same-family update to any higher version."""
    element = "MainBundle" if facts["kind"] == "bundle" else "MainPackage"
    attributes = {"Name": facts["name"], "Publisher": facts["publisher"], "Version": facts["version"],
                  "Uri": package_uri}
    if facts["kind"] == "package":
        attributes["ProcessorArchitecture"] = facts["architectures"][0]

    def render(values):
        return " ".join('%s="%s"' % (key, escape(value, {'"': "&quot;"})) for key, value in values.items())

    text = (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<!-- Generated by scripts/windows-package/update_channel.py. Windows reads Uri for updates. -->\n'
        '<AppInstaller xmlns="%s" %s>\n'
        '  <%s %s/>\n'
        '  <UpdateSettings>\n'
        '    <OnLaunch HoursBetweenUpdateChecks="%d" ShowPrompt="true" UpdateBlocksActivation="false"/>\n'
        '    <AutomaticBackgroundTask/>\n'
        '    <ForceUpdateFromAnyVersion>false</ForceUpdateFromAnyVersion>\n'
        '  </UpdateSettings>\n'
        '</AppInstaller>\n'
    ) % (APPINSTALLER_NAMESPACE, render({"Version": facts["version"], "Uri": appinstaller_uri}), element,
         render(attributes), hours)
    data = text.encode("utf-8")
    check_appinstaller(data, facts, appinstaller_uri, package_uri)
    return data


def check_appinstaller(data, facts, appinstaller_uri, package_uri):
    root = ET.fromstring(data)
    ns = {"a": APPINSTALLER_NAMESPACE}
    main = root.find("a:MainBundle" if facts["kind"] == "bundle" else "a:MainPackage", ns)
    if (root.get("Uri"), root.get("Version")) != (appinstaller_uri, facts["version"]) or main is None:
        raise UpdateChannelError("App Installer file does not describe the requested feed")
    if (main.get("Name"), main.get("Publisher"), main.get("Version"), main.get("Uri")) != (
            facts["name"], facts["publisher"], facts["version"], package_uri):
        raise UpdateChannelError("App Installer main package differs from the build")
    return root


def _yaml_scalar(value):
    if value is None:
        return "null"
    text = str(value)
    if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9 ._/:+-]*", text) and not re.fullmatch(r"(?i)(true|false|null|yes|no)", text) \
            and ": " not in text and not text.endswith(":"):
        return text
    return "'" + text.replace("'", "''") + "'"


def _yaml(document, header):
    lines = ["# " + line for line in header] + []
    for key, value in document.items():
        if isinstance(value, list):
            lines.append("%s:" % key)
            for item in value:
                first = True
                for item_key, item_value in item.items():
                    if isinstance(item_value, list):
                        lines.append(("- " if first else "  ") + "%s:" % item_key)
                        lines.extend("  - %s" % _yaml_scalar(entry) for entry in item_value)
                    else:
                        lines.append(("- " if first else "  ") + "%s: %s" % (item_key, _yaml_scalar(item_value)))
                    first = False
        else:
            lines.append("%s: %s" % (key, _yaml_scalar(value)))
    return "\n".join(lines) + "\n"


def winget_manifests(channels, facts, package_uri, release_notes_url=None):
    """``{relative path: text}`` for the winget-pkgs multi-file manifest (a template, never submitted)."""
    winget = channels["winget"]
    identifier = winget["packageIdentifier"]
    version = facts["version"]
    schema = "https://aka.ms/winget-manifest.%s.%s.schema.json"
    header = ["Generated by scripts/windows-package/update_channel.py as a template; not submitted.",
              "yaml-language-server: $schema=" + schema]
    common = {"PackageIdentifier": identifier, "PackageVersion": version}
    installer = dict(common)
    installer.update({
        "MinimumOSVersion": windows_msix.load_identity()["targetDeviceFamily"]["minVersion"],
        "InstallerType": "msix",
        "PackageFamilyName": facts["packageFamilyName"],
        "Installers": [dict({"Architecture": architecture, "InstallerUrl": package_uri,
                             "InstallerSha256": facts["sha256"]},
                            **({"SignatureSha256": facts["signatureSha256"]} if facts["signatureSha256"] else {}))
                       for architecture in facts["architectures"]],
        "ManifestType": "installer", "ManifestVersion": winget["manifestVersion"],
    })
    locale = dict(common)
    locale.update({
        "PackageLocale": winget["defaultLocale"], "Publisher": winget["publisher"], "PublisherUrl": winget["publisherUrl"],
        "PackageName": winget["packageName"], "PackageUrl": winget["packageUrl"], "License": winget["license"],
        "LicenseUrl": winget["licenseUrl"], "ShortDescription": winget["shortDescription"],
        "ManifestType": "defaultLocale", "ManifestVersion": winget["manifestVersion"],
    })
    if release_notes_url:
        locale["ReleaseNotesUrl"] = release_notes_url
    version_manifest = dict(common)
    version_manifest.update({"DefaultLocale": winget["defaultLocale"], "ManifestType": "version",
                             "ManifestVersion": winget["manifestVersion"]})
    owner, name = identifier.split(".", 1)
    folder = "manifests/%s/%s/%s/%s/" % (owner[0].lower(), owner, name, version)
    return {
        folder + identifier + ".yaml": _yaml(version_manifest, [header[0], header[1] % ("version", winget["manifestVersion"])]),
        folder + identifier + ".installer.yaml": _yaml(installer, [header[0], header[1] % ("installer", winget["manifestVersion"])]),
        folder + identifier + ".locale.%s.yaml" % winget["defaultLocale"]: _yaml(
            locale, [header[0], header[1] % ("defaultLocale", winget["manifestVersion"])]),
    }


def generate(package, channel_name, tag, output, feed=None, appinstaller_uri=None, channels=None,
             environment=os.environ, published_name=None):
    """Write the channel's files for ``package``. ``published_name`` is the file name
    the package will have as a release asset (for a preview made from an unsigned
    build that will be renamed once signed)."""
    channels = channels or load_channels()
    if channel_name not in channels["channels"]:
        raise UpdateChannelError("unknown channel " + channel_name)
    channel = channels["channels"][channel_name]
    facts = package_facts(package)
    if facts["name"] != channel["packageName"]:
        raise UpdateChannelError("%s is package %s, not the %s channel's %s"
                                 % (facts["file"], facts["name"], channel_name, channel["packageName"]))
    base = feed_base(channels, feed, environment)
    if published_name is not None and (not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*\.(msix|msixbundle)", published_name)):
        raise UpdateChannelError("the published name must be an .msix or .msixbundle file name")
    appinstaller, package_uri = locations(channels, channel_name, tag, published_name or facts["file"], base,
                                          appinstaller_uri)
    output = pathlib.Path(output)
    if output.exists() and any(output.iterdir()):
        raise UpdateChannelError("the output directory must be new or empty")
    output.mkdir(parents=True, exist_ok=True)
    (output / channel["appInstaller"]).write_bytes(
        appinstaller_xml(facts, appinstaller, package_uri, channels["hoursBetweenUpdateChecks"]))
    written = [channel["appInstaller"]]
    if channel["winget"]:
        for relative, text in winget_manifests(channels, facts, package_uri).items():
            destination = output / "winget" / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(text, encoding="utf-8")
            written.append("winget/" + relative)
    record = {"schemaVersion": 1, "channel": channel_name, "commissioned": channel["commissioned"],
              "published": False, "appInstallerUri": appinstaller, "packageUri": package_uri, "package": facts,
              "files": written,
              "status": "Generated only. Nothing was uploaded, tagged or submitted."}
    (output / "update-channel.json").write_text(json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return record


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--package", required=True, type=pathlib.Path, help=".msixbundle (or .msix) to describe")
    parser.add_argument("--channel", required=True, choices=["developer", "alpha", "stable"])
    parser.add_argument("--tag", required=True, help="release tag whose assets hold the package")
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--feed-base", help="GitHub Releases base (default %s or update-channels.json)" % FEED_VARIABLE)
    parser.add_argument("--appinstaller-uri", help="where the App Installer file itself will be served")
    parser.add_argument("--published-name", help="the package's release asset name, when it differs from --package")
    args = parser.parse_args(argv)
    record = generate(args.package, args.channel, args.tag, args.output, args.feed_base, args.appinstaller_uri,
                      published_name=args.published_name)
    print(json.dumps({key: record[key] for key in ("channel", "appInstallerUri", "packageUri", "files")}, indent=2))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (UpdateChannelError, windows_msix.PackageError) as error:
        raise SystemExit("update channel: " + str(error))
