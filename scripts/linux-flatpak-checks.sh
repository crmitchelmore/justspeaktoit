#!/usr/bin/env bash
# Installs the Linux app from a flatpak-builder repository (flatpak-builder
# --repo) into the user installation and checks it with `flatpak run`: the
# native self-test, the bundled whisper.cpp runtime (loads by path, ggml finds
# a CPU backend) and, when xvfb-run is available, the GTK window smoke test.
#
#   scripts/linux-flatpak-checks.sh <repo-dir>
#
# The GNOME 50 runtime must already be installed. Used by
# .github/workflows/linux-flatpak.yml.
set -euo pipefail

repo_dir="${1:?usage: $0 <repo-dir>}"
app=com.justspeaktoit.JustSpeakToIt

flatpak remote-add --user --if-not-exists --no-gpg-verify jsti-local "$repo_dir"
flatpak install --user -y --noninteractive --reinstall jsti-local "$app"

echo "== native self-test (flatpak run)"
flatpak run "$app" --self-test

echo "== whisper.cpp runtime in /app/lib/justspeaktoit"
flatpak run --command=sh "$app" -c \
    'ls -l /app/lib/justspeaktoit && ls /app/share/licenses/com.justspeaktoit.JustSpeakToIt/whisper.cpp/LICENSE'
flatpak run --command=python3 "$app" - <<'PY'
import ctypes, os
d = "/app/lib/justspeaktoit/"
ctypes.CDLL(d + "libwhisper.so.1")          # resolves libggml*.so.0 through $ORIGIN
ggml = ctypes.CDLL(d + "libggml.so.0")
ggml.ggml_backend_load_all_from_path(d.encode())
ggml.ggml_backend_dev_count.restype = ctypes.c_size_t
count = ggml.ggml_backend_dev_count()
print("ggml devices:", count)
assert count >= 1, "no ggml backend loaded"
assert any(n.startswith("libggml-cpu-") for n in os.listdir(d)), "no CPU backend variants"
PY

if command -v xvfb-run >/dev/null; then
    echo "== window smoke test (Xvfb, private session bus, flatpak run)"
    # Without WAYLAND_DISPLAY the fallback-x11 socket is shared with the sandbox.
    env -u WAYLAND_DISPLAY xvfb-run -a -s "-screen 0 1280x1024x24 -nolisten tcp" \
        dbus-run-session -- \
        flatpak run --env=GDK_BACKEND=x11 --env=GSK_RENDERER=cairo --env=GTK_A11Y=none \
        --env=NO_AT_BRIDGE=1 --command=timeout "$app" 120 justspeaktoit --ui-smoke-test
else
    echo "== xvfb-run not found; skipping the window smoke test"
fi
echo "Flatpak checks passed."
