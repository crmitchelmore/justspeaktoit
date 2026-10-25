#!/usr/bin/env bash
# Install the actual bundle and exercise only the installed app in its normal
# sandbox. No SDK substitution, filesystem grants or runtime-directory override.
set -euo pipefail
bundle="${1:?usage: $0 <bundle.flatpak> <verified-jfk.wav>}"
fixture="${2:?usage: $0 <bundle.flatpak> <verified-jfk.wav>}"
app=com.justspeaktoit.JustSpeakToIt
command -v xvfb-run >/dev/null
flatpak install --user -y --noninteractive --reinstall --bundle "$bundle"

echo '== installed app self-test: resources, icons, recording codecs and adapters'
timeout 180 flatpak run "$app" --self-test

echo '== installed automation CLI'
flatpak run --command=speak "$app" --help

echo '== pinned runtime and license in the installed package'
flatpak run --command=sh "$app" -ec '
  test "$JSTI_WHISPER_RUNTIME_DIRECTORY" = /app/lib/justspeaktoit
  test -f /app/lib/justspeaktoit/libwhisper.so.1
  test -f /app/lib/justspeaktoit/libggml-base.so.0
  test -f /app/lib/justspeaktoit/libggml.so.0
  test -f /app/share/licenses/com.justspeaktoit.JustSpeakToIt/whisper.cpp/LICENSE
  ls /app/lib/justspeaktoit/libggml-cpu-*.so
'

echo '== real on-device transcription, live folding, silence and cancellation'
# Transfer this public-domain fixture over stdin; no access to host files is
# added to the app. The app downloads and verifies its canonical tiny model.
timeout 480 flatpak run --env=JSTI_WHISPER_CPU_ONLY=1 --command=sh "$app" -ec '
  sample=$(mktemp /tmp/jsti-jfk.XXXXXX.wav)
  trap '\''rm -f "$sample"'\'' EXIT
  cat > "$sample"
  justspeaktoit --local-transcription-self-test "$sample" --expect "ask not what your country can do for you"
' < "$fixture"

echo '== GTK window smoke test in the installed sandbox (Xvfb, private bus)'
env -u WAYLAND_DISPLAY xvfb-run -a -s '-screen 0 1280x1024x24 -nolisten tcp' \
  dbus-run-session -- timeout 600 flatpak run \
  --env=GDK_BACKEND=x11 --env=GSK_RENDERER=cairo --env=GTK_A11Y=none \
  --env=NO_AT_BRIDGE=1 "$app" --ui-smoke-test

echo 'Installed Flatpak checks passed.'
