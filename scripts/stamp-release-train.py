#!/usr/bin/env python3
"""Stamp before Tuist copies Alpha plists; never change Stable identity defaults."""
import json
import os
import plistlib
import sys
from pathlib import Path
surface = sys.argv[1]
train = os.environ['RELEASE_TRAIN']
config = json.loads(Path('Sources/SpeakCore/Resources/ReleaseTrains.json').read_text())[train]
if surface != 'ios':
    path = Path('Config/AppInfo.AppStore.plist' if surface == 'mac-store' else 'Config/AppInfo.plist')
    info = plistlib.loads(path.read_bytes())
    info.update(CFBundleShortVersionString=os.environ['RELEASE_VERSION'], CFBundleVersion=os.environ['BUILD_NUMBER'],
                GitCommitSHA=os.environ['RELEASE_SOURCE'], SpeakReleaseTrain=train)
    path.write_bytes(plistlib.dumps(info))
with open(os.environ['GITHUB_ENV'], 'a') as output:
    entitlements = 'Config/SpeakMacOS.entitlements'
    if train == 'alpha': entitlements = '.build/release-train/alpha/' + entitlements
    output.write(f'TRAIN_ENTITLEMENTS={entitlements}\n')
