#!/usr/bin/env python3
"""Fail before archiving if any profile belongs to the other train."""
import json
import os
import plistlib
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[2]) if len(sys.argv) > 2 else Path.home() / 'Library/MobileDevice/Provisioning Profiles'
surface = sys.argv[1]
parent = os.environ['BUNDLE_ID']
profiles = [('mac-app-store', parent)] if surface == 'mac-store' else [
    ('ios-appstore', parent), ('ios-widget-appstore', parent + '.JustSpeakToItWidgetExtension'),
    ('ios-keyboard-appstore', parent + '.keyboard')]
groups = {}
if surface == 'ios':
    # Alpha-only targets are checked only when the release kept them enabled.
    train = os.environ.get('RELEASE_TRAIN', 'stable')
    config = json.loads(Path('Sources/SpeakCore/Resources/ReleaseTrains.json').read_text())[train]
    if os.environ.get('TUIST_IOS_SHARE_EXTENSION') == '1':
        profiles.append(('ios-share-appstore', parent + '.share'))
    if os.environ.get('TUIST_WATCH_APP') == '1':
        profiles += [('watch-appstore', parent + '.watchkitapp'),
                     ('watch-widget-appstore', parent + '.watchkitapp.widget')]
        groups = {'watch-appstore': config['watchAppGroup'], 'watch-widget-appstore': config['watchAppGroup']}
for name, identifier in profiles:
    path = root / (name + '.provisionprofile')
    profile = plistlib.loads(subprocess.check_output(['security', 'cms', '-D', '-i', str(path)]))
    entitlements = profile['Entitlements']
    app_id = entitlements.get('application-identifier', entitlements.get('com.apple.application-identifier', ''))
    if app_id.split('.', 1)[-1] != identifier:
        raise SystemExit(f'Profile {name} does not authorise {identifier}')
    expected_group = groups.get(name, os.environ.get('IOS_APP_GROUP'))
    if surface == 'ios' and entitlements.get('com.apple.security.application-groups', []) != [expected_group]:
        raise SystemExit(f'Profile {name} has the wrong App Group')
    if name in ['ios-appstore', 'mac-app-store']:
        containers = set(entitlements.get('com.apple.developer.icloud-container-identifiers', []))
        if surface == 'ios':
            # #1119: the shared container plus the legacy one the migration reads.
            allowed = [{os.environ['IOS_CLOUD_CONTAINER'], os.environ['MAC_CLOUD_CONTAINER']}]
        else:
            allowed = [{os.environ['MAC_CLOUD_CONTAINER']}]
        if containers not in allowed:
            raise SystemExit(f'Profile {name} has the wrong CloudKit container')
    print(f'Validated {identifier}')
