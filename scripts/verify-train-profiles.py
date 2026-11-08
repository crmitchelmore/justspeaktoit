#!/usr/bin/env python3
"""Fail before archiving if any profile belongs to the other train."""
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
for name, identifier in profiles:
    path = root / (name + '.provisionprofile')
    profile = plistlib.loads(subprocess.check_output(['security', 'cms', '-D', '-i', str(path)]))
    entitlements = profile['Entitlements']
    app_id = entitlements.get('application-identifier', entitlements.get('com.apple.application-identifier', ''))
    if app_id.split('.', 1)[-1] != identifier:
        raise SystemExit(f'Profile {name} does not authorise {identifier}')
    if surface == 'ios' and entitlements.get('com.apple.security.application-groups', []) != [os.environ['IOS_APP_GROUP']]:
        raise SystemExit(f'Profile {name} has the wrong App Group')
    if name in ['ios-appstore', 'mac-app-store']:
        containers = set(entitlements.get('com.apple.developer.icloud-container-identifiers', []))
        if surface == 'ios':
            # #1119: a profile may also authorise this train's shared Mac container;
            # builds that use it must have it.
            legacy, shared = os.environ['IOS_CLOUD_CONTAINER'], os.environ['MAC_CLOUD_CONTAINER']
            needs_shared = os.environ.get('TUIST_IOS_SHARED_CLOUD_CONTAINER') == '1'
            allowed = [{legacy, shared}] if needs_shared else [{legacy}, {legacy, shared}]
        else:
            allowed = [{os.environ['MAC_CLOUD_CONTAINER']}]
        if containers not in allowed:
            raise SystemExit(f'Profile {name} has the wrong CloudKit container')
    print(f'Validated {identifier}')
