#!/usr/bin/env python3
"""Verify archive identity and frozen notes from the actual shipped bundle."""
import hashlib
import json
import plistlib
import subprocess
import sys
from pathlib import Path
app, manifest_path, surface = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
manifest = json.loads(manifest_path.read_text())
train = manifest['train']
config = json.loads(Path('Sources/SpeakCore/Resources/ReleaseTrains.json').read_text())[train]
item = manifest['surfaces'][surface]
info_path = app / ('Contents/Info.plist' if surface.startswith('mac') else 'Info.plist')
info = plistlib.loads(info_path.read_bytes())
expected_id = config['iosBundleIdentifier' if surface == 'ios' else 'storeMacBundleIdentifier' if surface == 'mac-store' else 'directMacBundleIdentifier']
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
for extension in app.rglob('*.appex'):
    ext = plistlib.loads((extension / 'Info.plist').read_bytes())
    if not ext['CFBundleIdentifier'].startswith(expected_id + '.'):
        raise SystemExit('Extension belongs to another app identity')
    for key in ['SpeakReleaseTrain', 'CFBundleShortVersionString', 'CFBundleVersion']:
        if ext.get(key) != expected[key]: raise SystemExit(f'Extension {key} mismatch')
catalogues = list(app.rglob('ReleaseNotes.json'))
if not catalogues: raise SystemExit('Missing bundled notes catalogue')
for catalogue in catalogues:
    entries = json.loads(catalogue.read_text())['entries']
    entry = next((e for e in entries if e.get('train', 'stable') == train and e.get('build') == item['build']
                  and e['platform'] == ('ios' if surface == 'ios' else 'mac')), None)
    if not entry or hashlib.sha256(entry['markdown'].encode()).hexdigest() != item['notesHash']:
        raise SystemExit(f'Bundled notes do not match approved manifest: {catalogue}')
print(f'Verified {surface} {train}: {expected_id}, {item["version"]} ({item["build"]}), {manifest["source"]}')
