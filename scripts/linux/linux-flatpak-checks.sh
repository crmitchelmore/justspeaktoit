#!/usr/bin/env bash
# Install the actual bundle and exercise only the installed app in its normal
# sandbox. No SDK substitution, filesystem grants or runtime-directory override.
set -euo pipefail
bundle="${1:?usage: $0 <bundle.flatpak> <verified-jfk.wav>}"
fixture="${2:?usage: $0 <bundle.flatpak> <verified-jfk.wav>}"
app=com.justspeaktoit.JustSpeakToIt
# Inspect all persisted scopes without changing a real user's installation or
# exposing override values. Recheck inside the private session before install.
python3 "$(dirname "$0")/linux-flatpak-qualification.py" check-overrides "$app"

# GNOME 50's Glycin loader uses the Flatpak Spawn portal for its tighter image
# sandbox. A desktop session supplies this bus; a headless runner must do so too.
if [ "${JSTI_FLATPAK_CHECK_SESSION:-}" != 1 ]; then
  session_dir=$(mktemp -d)
  trap 'rm -rf "$session_dir"' EXIT
  mkdir -m 700 "$session_dir/runtime"
  XDG_RUNTIME_DIR="$session_dir/runtime" JSTI_FLATPAK_CHECK_SESSION=1 \
    GDK_BACKEND=x11 GSK_RENDERER=cairo GTK_A11Y=none NO_AT_BRIDGE=1 \
    env -u WAYLAND_DISPLAY xvfb-run -a -s '-screen 0 1280x1024x24 -nolisten tcp' \
    dbus-run-session -- "$0" "$@"
  exit
fi

# The builder image strips D-Bus activation files to stay small. Start the real
# host Flatpak portal explicitly, just as a desktop session would activate it.
portal_pid=
portal_log=$(mktemp)
cleanup_portal() {
  if [ -n "$portal_pid" ]; then kill "$portal_pid" 2>/dev/null || true; wait "$portal_pid" 2>/dev/null || true; fi
  cat "$portal_log"
  rm -f "$portal_log"
}
trap cleanup_portal EXIT
for portal in /app/libexec/flatpak-portal /usr/libexec/flatpak-portal /usr/lib/flatpak-portal /usr/lib/flatpak/flatpak-portal; do
  if [ -x "$portal" ]; then
    "$portal" --no-idle-exit >"$portal_log" 2>&1 &
    portal_pid=$!
    break
  fi
done
[ -n "$portal_pid" ] || { echo 'The host flatpak-portal executable is required.' >&2; exit 1; }
gdbus wait --session --timeout 15 org.freedesktop.portal.Flatpak

command -v xvfb-run >/dev/null
command -v readelf >/dev/null || { echo 'readelf from binutils is required.' >&2; exit 1; }
flatpak install --user -y --noninteractive --reinstall --bundle "$bundle"

# Size baseline (#1295): the bundle file, then the installed app deployment
# without the shared runtime, which the user may already have.
# Assignments, not echo arguments, so a failed measurement stops the checks.
bundle_bytes=$(stat -c %s "$bundle")
installed_location=$(flatpak info --user --show-location "$app")
installed_bytes=$(du -sb "$installed_location" | cut -f1)
for value in "$bundle_bytes" "$installed_bytes"; do
  [[ "$value" =~ ^[0-9]+$ ]] || { echo "Invalid package size measurement: '$value'" >&2; exit 1; }
done
echo '== package size (bytes)'
echo "bundle $bundle_bytes"
echo "installed-app $installed_bytes"

echo '== Flatpak Spawn portal (required by the sandboxed PNG loader)'
timeout 60 flatpak run --command=flatpak-spawn "$app" --sandbox --watch-bus /usr/bin/true

echo '== installed app version (normal packaged environment)'
timeout 15 flatpak run "$app" --version

echo '== installed app self-test: resources, recording codecs and adapters'
timeout 180 flatpak run "$app" --self-test

echo '== sandbox PID namespace hides host processes (app profiles are default-only in the Flatpak)'
# A host X11 window's _NET_WM_PID cannot be resolved through /proc inside the
# sandbox, so the app must not attempt automatic profile matching here.
flatpak run --command=sh "$app" -ec '
  test -f /.flatpak-info
  test ! -e "/proc/$1/exe"
' sandbox-pid-check "$portal_pid"

echo '== installed automation CLI'
flatpak run --command=speak "$app" --help

echo '== pinned runtime and license in the installed package'
flatpak run --command=sh "$app" -ec '
  test "$JSTI_WHISPER_RUNTIME_DIRECTORY" = /app/lib/justspeaktoit
  for name in libggml-base.so.0 libggml.so.0 libwhisper.so.1; do
    test -f "/app/lib/justspeaktoit/$name"
    test ! -L "/app/lib/justspeaktoit/$name"
  done
  test -f /app/share/licenses/com.justspeaktoit.JustSpeakToIt/whisper.cpp/LICENSE
  ls /app/lib/justspeaktoit/libggml-cpu-*.so
'

# Inspect installed ELF files from the build host, using its existing readelf.
# Nothing is added to the runtime and the normal sandbox receives no override.
installed_root=$(flatpak info --user --show-location "$app")
python3 "$(dirname "$0")/../../packaging/linux/verify-flatpak-manifest.py" \
  --runtime-directory "$installed_root/files/lib/justspeaktoit"

echo '== real on-device transcription, live folding, silence and cancellation'
# Transfer this public-domain fixture over stdin; no access to host files is
# added to the app. The app downloads and verifies its canonical tiny model.
timeout 480 flatpak run --env=JSTI_WHISPER_CPU_ONLY=1 --command=sh "$app" -ec '
  sample=$(mktemp /tmp/jsti-jfk.XXXXXX.wav)
  trap '\''rm -f "$sample"'\'' EXIT
  cat > "$sample"
  justspeaktoit --local-transcription-self-test "$sample" --expect "ask not what your country can do for you"
' < "$fixture"

echo '== GTK window and canonical icon smoke test in the installed sandbox (Xvfb, private bus)'
timeout 600 flatpak run \
  --env=GDK_BACKEND=x11 --env=GSK_RENDERER=cairo --env=GTK_A11Y=none \
  --env=NO_AT_BRIDGE=1 "$app" --ui-smoke-test

echo 'Installed Flatpak checks passed.'
