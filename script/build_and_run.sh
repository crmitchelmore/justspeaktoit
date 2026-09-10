#!/usr/bin/env bash
# Local Alpha defaults keep development alongside the installed Stable app.
set -euo pipefail
cd "$(dirname "$0")/.."
export TUIST_RELEASE_TRAIN="${TUIST_RELEASE_TRAIN:-alpha}"
case "$TUIST_RELEASE_TRAIN" in alpha|stable) ;; *) echo 'Unknown release train' >&2; exit 1 ;; esac
PRODUCT=$(python3 -c 'import json,os; print(json.load(open("Sources/SpeakCore/Resources/ReleaseTrains.json"))[os.environ["TUIST_RELEASE_TRAIN"]]["directMacProductName"])')
pkill -x "$PRODUCT" || true
xcrun swift build --cache-path "$PWD/.build/local-run-cache" --product SpeakApp
BIN=$(xcrun swift build --cache-path "$PWD/.build/local-run-cache" --show-bin-path)
APP="$PWD/dist/$PRODUCT.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/SpeakApp" "$APP/Contents/MacOS/$PRODUCT"
# SwiftPM's generated resource accessors retain their local .build fallback.
# Keep the development app a valid macOS bundle; release archives use Tuist.
for stale in "$APP"/*.bundle; do [ ! -e "$stale" ] || rm -rf "$stale"; done
for bundle in "$BIN"/*.bundle; do ditto "$bundle" "$APP/Contents/Resources/$(basename "$bundle")"; done
# Embed dynamic dependencies only; static binary targets are linked into SpeakApp.
rm -rf "$APP/Contents/Frameworks"
mkdir -p "$APP/Contents/Frameworks"
while IFS= read -r framework; do
    ditto "$BIN/$framework" "$APP/Contents/Frameworks/$framework"
done < <(otool -L "$BIN/SpeakApp" | sed -n 's|.*@rpath/\([^/]*\.framework\)/.*|\1|p' | sort -u)
python3 - "$APP" <<'PY'
import json,os,plistlib,sys,subprocess
from pathlib import Path
app=Path(sys.argv[1]);train=os.environ['TUIST_RELEASE_TRAIN']
c=json.loads(Path('Sources/SpeakCore/Resources/ReleaseTrains.json').read_text())[train]
info=plistlib.loads(Path('Config/AppInfo.plist').read_bytes())
info.update(CFBundleExecutable=c['directMacProductName'],CFBundleIdentifier=c['directMacBundleIdentifier'],
            CFBundleName=c['displayName'],CFBundleDisplayName=c['displayName'],SpeakReleaseTrain=train,
            CFBundleShortVersionString=Path('VERSION').read_text().strip(),CFBundleVersion='1',
            GitCommitSHA=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
            NSBonjourServices=[c['transportServiceType']],SUFeedURL=c['feedURL'])
info['CFBundleIconFile']='AppIconAlpha' if train=='alpha' else 'AppIcon'
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
ICON=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP/Contents/Info.plist")
cp "Resources/$ICON.icns" "$APP/Contents/Resources/$ICON.icns"
install_name_tool -add_rpath '@executable_path/../Frameworks' "$APP/Contents/MacOS/$PRODUCT" 2>/dev/null || true
codesign --force --deep --sign - "$APP"
case "${1:-}" in
  --debug) exec lldb "$APP/Contents/MacOS/$PRODUCT" ;;
  --logs|--telemetry)
    open -n "$APP"
    exec /usr/bin/log stream --level info --predicate "process == '$PRODUCT'" ;;
  ''|--verify)
    open -n "$APP"
    for _ in {1..20}; do
      if pgrep -x "$PRODUCT" >/dev/null; then echo "Running $APP"; exit 0; fi
      sleep 0.5
    done
    echo 'App did not remain running' >&2; exit 1 ;;
  *) echo 'Use --verify, --debug, --logs or --telemetry' >&2; exit 1 ;;
esac
