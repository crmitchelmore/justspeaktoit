#!/usr/bin/env python3
"""Verify identity, submission metadata, privacy and notes in shipped bundles."""
import hashlib
import importlib.util
import json
import plistlib
import subprocess
import sys
from pathlib import Path
from xml.parsers.expat import ExpatError


def _intent_terms():
    path = Path(__file__).resolve().parent / "ios/check-app-intents-terms.py"
    spec = importlib.util.spec_from_file_location("check_app_intents_terms", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


INTENT_TERMS = _intent_terms()


def bundle_info(bundle):
    root = bundle / "Contents" if (bundle / "Contents").is_dir() else bundle
    return plistlib.loads((root / "Info.plist").read_bytes())


def verify_intent_metadata(resources, *, main, require_shortcuts=False):
    path = resources / "Metadata.appintents/extract.actionsdata"
    if not path.is_file():
        if main:
            raise SystemExit(f"Missing App Intents metadata: {path}")
        return  # Extensions without App Intents do not emit this resource.
    try:
        metadata = json.loads(path.read_text())
    except (ValueError, UnicodeError) as error:
        raise SystemExit(f"Invalid App Intents metadata: {path}: {error}") from error
    if not isinstance(metadata, dict) or not isinstance(metadata.get("actions"), dict):
        raise SystemExit(f"Unsupported App Intents metadata schema: {path}")
    for identifier, action in metadata["actions"].items():
        if not isinstance(action, dict):
            raise SystemExit(f"Invalid App Intent action: {identifier}: {path}")
        description = action.get("descriptionMetadata", {})
        if not isinstance(description, dict):
            raise SystemExit(f"Invalid App Intent description: {identifier}: {path}")
        if "descriptionText" not in description:
            continue  # AppIntent.description is optional.
        resource = description["descriptionText"]
        if (not isinstance(resource, dict) or not isinstance(resource.get("key"), str)
                or resource.get("alternatives") != []):
            raise SystemExit(f"Unsupported localized App Intent description: {identifier}: {path}")
        text = resource["key"].strip()
        if not text.endswith("."):
            raise SystemExit(f"App Intent description must end with a period: {identifier}: {path}")
    # Titles, parameters, entities and phrases are validated as well as descriptions.
    findings = INTENT_TERMS.metadata_findings(metadata)
    if findings:
        raise SystemExit(f"ITMS-90626: prohibited App Intents metadata term: {path}: {'; '.join(findings)}")
    shortcuts = metadata.get("autoShortcuts")
    if not isinstance(shortcuts, list) or len(shortcuts) > 10:
        raise SystemExit(f"Invalid App Shortcuts list (maximum ten): {path}")
    if require_shortcuts and not shortcuts:
        # A provider compiled into a static library builds but registers no phrases.
        raise SystemExit(f"App registers no App Shortcuts: {path}")
    for shortcut in shortcuts:
        if not isinstance(shortcut, dict):
            raise SystemExit(f"Invalid App Shortcut: {path}")
        phrases = shortcut.get("phraseTemplates")
        if (not isinstance(phrases, list) or not phrases
                or any(not isinstance(phrase, dict) or not isinstance(phrase.get("key"), str)
                       or "${applicationName}" not in phrase["key"] for phrase in phrases)):
            raise SystemExit(f"App Shortcut phrases must include the application name: {path}")


def verify_submission_metadata(bundle, info, *, surface, main=False, watch=False):
    resources = bundle / "Contents/Resources" if (bundle / "Contents").is_dir() else bundle
    path = resources / "PrivacyInfo.xcprivacy"
    if not path.is_file():
        raise SystemExit(f"Missing own-bundle privacy manifest: {path}")
    try:
        privacy = plistlib.loads(path.read_bytes())
    except (plistlib.InvalidFileException, ValueError, ExpatError) as error:
        raise SystemExit(f"Invalid privacy manifest: {path}: {error}") from error
    if not isinstance(privacy, dict):
        raise SystemExit(f"Privacy manifest must be a dictionary: {path}")
    if privacy.get("NSPrivacyTracking") is not False or privacy.get("NSPrivacyTrackingDomains") != []:
        raise SystemExit(f"Unexpected tracking declaration: {path}")
    # These are the project's audited uses, not Apple's complete reason list.
    approved_reasons = {
        "NSPrivacyAccessedAPICategoryUserDefaults": {"CA92.1", "1C8F.1"},
        "NSPrivacyAccessedAPICategoryFileTimestamp": {"C617.1", "3B52.1"},
        "NSPrivacyAccessedAPICategoryDiskSpace": {"E174.1"},
        "NSPrivacyAccessedAPICategorySystemBootTime": {"35F9.1"},
        "NSPrivacyAccessedAPICategoryActiveKeyboards": {"54BD.1"},
    }
    # UITextInputMode.activeInputModes is UIKit-only: the iOS app and keyboard read it.
    ios_only = {"NSPrivacyAccessedAPICategoryActiveKeyboards"}
    categories = set()
    apis = privacy.get("NSPrivacyAccessedAPITypes")
    if not isinstance(apis, list):
        raise SystemExit(f"Missing required-reason API array: {path}")
    for api in apis:
        if not isinstance(api, dict):
            raise SystemExit(f"Invalid required-reason API entry: {path}")
        category, reasons = api.get("NSPrivacyAccessedAPIType"), api.get("NSPrivacyAccessedAPITypeReasons")
        if (not isinstance(category, str) or category in categories
                or not isinstance(reasons, list) or not reasons
                or any(not isinstance(reason, str) or reason not in approved_reasons.get(category, set())
                       for reason in reasons)):
            raise SystemExit(f"Unaudited or invalid required-reason API declaration: {path}")
        categories.add(category)
    required_main = approved_reasons.keys() - (set() if surface == "ios" else ios_only)
    if main and not required_main <= categories:
        raise SystemExit(f"Missing app required-reason API categories: {path}")
    extension_point = info.get("NSExtension", {}).get("NSExtensionPointIdentifier")
    if extension_point == "com.apple.keyboard-service" and not ios_only <= categories:
        raise SystemExit(f"Missing keyboard active-keyboards API declaration: {path}")
    if extension_point in ["com.apple.keyboard-service", "com.apple.share-services"] or (
            extension_point == "com.apple.widgetkit-extension" and not watch):
        if "NSPrivacyAccessedAPICategoryUserDefaults" not in categories:
            raise SystemExit(f"Missing extension defaults API declaration: {path}")
    collected = privacy.get("NSPrivacyCollectedDataTypes")
    if not isinstance(collected, list):
        raise SystemExit(f"Missing collected-data array: {path}")
    required_data = {"NSPrivacyCollectedDataType" + name for name in [
        "AudioData", "OtherUserContent", "CrashData", "PerformanceData", "OtherDiagnosticData", "DeviceID"
    ]}
    audited_data = required_data | {"NSPrivacyCollectedDataTypeProductInteraction"}
    linked_diagnostics = required_data - {"NSPrivacyCollectedDataTypeAudioData", "NSPrivacyCollectedDataTypeOtherUserContent"}
    data_types = set()
    for entry in collected:
        if not isinstance(entry, dict):
            raise SystemExit(f"Invalid collected-data entry: {path}")
        data_type, purposes = entry.get("NSPrivacyCollectedDataType"), entry.get("NSPrivacyCollectedDataTypePurposes")
        if (not isinstance(data_type, str) or data_type not in audited_data
                or data_type in data_types or type(entry.get("NSPrivacyCollectedDataTypeLinked")) is not bool
                or entry.get("NSPrivacyCollectedDataTypeTracking") is not False
                or not isinstance(purposes, list) or not purposes
                or any(purpose not in ["NSPrivacyCollectedDataTypePurposeAppFunctionality",
                                       "NSPrivacyCollectedDataTypePurposeAnalytics"] for purpose in purposes)):
            raise SystemExit(f"Invalid collected-data declaration: {path}")
        if data_type in linked_diagnostics and entry["NSPrivacyCollectedDataTypeLinked"] is not True:
            raise SystemExit(f"Sentry diagnostics must disclose installation linkage: {path}")
        data_types.add(data_type)
    if main:
        if not required_data <= data_types:
            raise SystemExit(f"Missing app collected-data declarations: {path}")
    if main and surface == "mac-store":
        if any("NSPrivacyCollectedDataTypePurposeAnalytics" in entry["NSPrivacyCollectedDataTypePurposes"]
               for entry in collected):
            raise SystemExit("App Store manifest declares excluded product analytics")
    purpose_keys = []
    if main or info.get("WKApplication") is True or extension_point == "com.apple.keyboard-service":
        purpose_keys.append("NSMicrophoneUsageDescription")
    if main or extension_point == "com.apple.keyboard-service":
        purpose_keys.append("NSSpeechRecognitionUsageDescription")
    for key in purpose_keys:
        if not isinstance(info.get(key), str) or not info[key].strip() or "$(" in info[key]:
            raise SystemExit(f"Missing or unresolved {key}: {bundle}")
    verify_intent_metadata(resources, main=main, require_shortcuts=main and surface == "ios")


def signed_entitlements(bundle):
    result = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(bundle)],
                            check=True, capture_output=True)
    return plistlib.loads(result.stdout)


def main():
    if len(sys.argv) != 4 or sys.argv[3] not in ["ios", "mac-direct", "mac-store"]:
        raise SystemExit("Usage: verify-release-train-archive.py app manifest.json ios|mac-direct|mac-store")
    app, manifest_path, surface = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
    manifest = json.loads(manifest_path.read_text())
    train = manifest['train']
    config = json.loads(Path('Sources/SpeakCore/Resources/ReleaseTrains.json').read_text())[train]
    item = manifest['surfaces'][surface]
    info = bundle_info(app)
    expected_id = config['iosBundleIdentifier' if surface == 'ios' else
                         'storeMacBundleIdentifier' if surface == 'mac-store' else 'directMacBundleIdentifier']
    expected = {'CFBundleIdentifier': expected_id, 'SpeakReleaseTrain': train,
                'CFBundleShortVersionString': item['version'], 'CFBundleVersion': item['build'],
                'GitCommitSHA': manifest['source']}
    for key, value in expected.items():
        if info.get(key) != value:
            raise SystemExit(f'{key}: expected {value}, observed {info.get(key)}')
    if surface == 'mac-direct' and info.get('SUFeedURL') != config['feedURL']:
        raise SystemExit('Wrong Sparkle release train')
    if surface == 'mac-store' and any(key.startswith('SU') for key in info):
        raise SystemExit('App Store archive contains Sparkle configuration')
    if surface == 'ios' and any(key in info for key in ['NSLocalNetworkUsageDescription', 'NSBonjourServices']):
        raise SystemExit('Public iOS archive declares an unavailable local-network feature')
    verify_submission_metadata(app, info, surface=surface, main=True)
    if surface != 'mac-direct':
        entitlements = signed_entitlements(app)
        # #1119: every surface uses the train's shared container; the iPhone
        # also keeps its legacy container so the one-time migration can read it.
        cloud = {config['cloudContainer']} | ({config['iosCloudContainer']} if surface == 'ios' else set())
        signed_cloud = entitlements.get('com.apple.developer.icloud-container-identifiers')
        if not isinstance(signed_cloud, list) or len(signed_cloud) != len(cloud) or set(signed_cloud) != cloud:
            raise SystemExit('Signed archive has the wrong CloudKit containers')
        kv = config['iosKVStoreIdentifier' if surface == 'ios' else 'macKVStoreIdentifier']
        if entitlements.get('com.apple.developer.ubiquity-kvstore-identifier', '').split('.', 1)[-1] != kv:
            raise SystemExit('Signed archive has the wrong iCloud key-value store')
        if surface == 'ios' and entitlements.get('com.apple.security.application-groups') != [config['iosAppGroup']]:
            raise SystemExit('Signed archive has the wrong App Groups')
        if surface == 'mac-store' and entitlements.get('com.apple.security.app-sandbox') is not True:
            raise SystemExit('App Store archive is not sandboxed')
        if surface == 'mac-store' and 'com.apple.security.network.server' in entitlements:
            raise SystemExit('App Store archive has network.server without a listener')  # App Review rejects it unused
        if surface == 'mac-store' and any(key in info for key in ['NSLocalNetworkUsageDescription', 'NSBonjourServices']):
            raise SystemExit('App Store archive declares an unavailable local-network feature')
    bundles = list(app.rglob('*.appex'))
    if surface == 'ios':
        bundles.extend((app / 'Watch').glob('*.app'))
    for extension in bundles:
        ext = bundle_info(extension)
        is_watch = extension.relative_to(app).parts[0] == 'Watch'
        verify_submission_metadata(extension, ext, surface=surface, watch=is_watch)
        app_group = config['watchAppGroup' if is_watch else 'iosAppGroup']
        if surface == 'ios' and signed_entitlements(extension).get('com.apple.security.application-groups') != [app_group]:
            raise SystemExit('Signed extension has the wrong App Groups')
        if is_watch and extension.suffix == '.app' and ext.get('WKCompanionAppBundleIdentifier') != expected_id:
            raise SystemExit('Watch app has the wrong companion identity')
        if not ext['CFBundleIdentifier'].startswith(expected_id + '.'):
            raise SystemExit('Extension belongs to another app identity')
        for key in ['SpeakReleaseTrain', 'CFBundleShortVersionString', 'CFBundleVersion', 'GitCommitSHA']:
            if ext.get(key) != expected[key]:
                raise SystemExit(f'Extension {key} mismatch')
    catalogues = list(app.rglob('ReleaseNotes.json'))
    if not catalogues:
        raise SystemExit('Missing bundled notes catalogue')
    for catalogue in catalogues:
        entries = json.loads(catalogue.read_text())['entries']
        entry = next((e for e in entries if e.get('train', 'stable') == train and e.get('build') == item['build']
                      and e['platform'] == ('ios' if surface == 'ios' else 'mac')), None)
        if not entry or hashlib.sha256(entry['markdown'].encode()).hexdigest() != item['notesHash']:
            raise SystemExit(f'Bundled notes do not match approved manifest: {catalogue}')
    print(f'Verified {surface} {train}: {expected_id}, {item["version"]} ({item["build"]}), {manifest["source"]}')


if __name__ == "__main__":
    main()
