#!/usr/bin/env bash
# Checks a flatpak-builder build directory of the Linux app: the native
# self-test, the bundled whisper.cpp runtime (loads by path, ggml finds a CPU
# backend) and, when Xvfb is available, the GTK window smoke test.
#
#   scripts/linux-flatpak-checks.sh <build-dir> [manifest]
#
# Used by .github/workflows/linux-flatpak.yml; run it after flatpak-builder.
set -euo pipefail

build_dir="${1:?usage: $0 <build-dir> [manifest]}"
manifest="${2:-packaging/linux/com.justspeaktoit.JustSpeakToIt.yml}"
run() { flatpak-builder --run "$build_dir" "$manifest" "$@"; }

echo "== native self-test (inside the Flatpak)"
run justspeaktoit --self-test

echo "== whisper.cpp runtime in /app/lib/justspeaktoit"
run sh -c 'ls -l /app/lib/justspeaktoit && ls /app/share/licenses/com.justspeaktoit.JustSpeakToIt/whisper.cpp/LICENSE'
run python3 - <<'PY'
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
    echo "== window smoke test (Xvfb, private session bus, inside the Flatpak)"
    # Unset Wayland so the fallback-x11 socket is shared with the sandbox.
    env -u WAYLAND_DISPLAY xvfb-run -a -s "-screen 0 1280x1024x24 -nolisten tcp" \
        flatpak-builder --run "$build_dir" "$manifest" \
        env GDK_BACKEND=x11 GSK_RENDERER=cairo GTK_A11Y=none NO_AT_BRIDGE=1 \
        timeout 120 dbus-run-session -- justspeaktoit --ui-smoke-test
else
    echo "== xvfb-run not found; skipping the window smoke test"
fi
echo "Flatpak checks passed."
