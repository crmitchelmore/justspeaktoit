#!/usr/bin/env bash
# Builds the whisper.cpp runtime for the Linux packages (the .deb; the Flatpak
# builds the same pin with the same options as a manifest module).
#
#   scripts/linux-build-whisper.sh <install-dir> [work-dir]
#
# Installs libwhisper.so*, libggml*.so* and the ggml backend modules into
# <install-dir> (the app loads libwhisper.so.1 from
# <executable dir>/../lib/justspeaktoit) and the licence as
# <install-dir>/LICENSE.whisper.cpp. Pin: whisper.cpp v1.9.4 at
# 927cfce34f31707e17f2bff35c349632fb9e2c3a, as in
# scripts/windows-local-runtime/dependencies.json.
set -euo pipefail

tag=v1.9.4
commit=927cfce34f31707e17f2bff35c349632fb9e2c3a
repository=https://github.com/ggml-org/whisper.cpp

install_dir="${1:?usage: $0 <install-dir> [work-dir]}"
work="${2:-$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/jsti-whisper.XXXXXX")}"
mkdir -p "$install_dir" "$work"
install_dir="$(cd "$install_dir" && pwd)"
src="$work/whisper.cpp"

if [ ! -d "$src/.git" ]; then
    git init -q "$src"
    git -C "$src" fetch -q --depth 1 "$repository" "refs/tags/$tag"
fi
git -C "$src" checkout -q FETCH_HEAD
actual="$(git -C "$src" rev-parse HEAD)"
[ "$actual" = "$commit" ] || { echo "whisper.cpp $tag is $actual, expected $commit" >&2; exit 1; }

# The arm64 CPU variants include armv9.2+SME, which GCC 13 (Ubuntu 24.04)
# rejects; the Swift toolchain's clang accepts it. Override with CC/CXX.
if [ -z "${CC:-}" ] && command -v clang >/dev/null && command -v clang++ >/dev/null; then
    export CC=clang CXX=clang++
fi

cmake -S "$src" -B "$work/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$work/prefix" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_INSTALL_RPATH='$ORIGIN' \
    -DWHISPER_BUILD_IS_DEV=OFF \
    -DBUILD_SHARED_LIBS=ON \
    -DGGML_NATIVE=OFF \
    -DGGML_BACKEND_DL=ON \
    -DGGML_CPU_ALL_VARIANTS=ON \
    -DGGML_OPENMP=OFF \
    -DGGML_CCACHE=OFF \
    -DWHISPER_BUILD_EXAMPLES=OFF \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_SERVER=OFF \
    -DWHISPER_SDL2=OFF \
    -DWHISPER_CURL=OFF
cmake --build "$work/build" --parallel
cmake --install "$work/build"
# Versioned libraries and their SONAME links; no unversioned development links.
cp -a "$work/prefix/lib/"lib*.so.* "$install_dir/"
# GGML_BACKEND_DL installs the backend modules (libggml-cpu-*.so) into bin/.
cp -a "$work/prefix/bin/"libggml-*.so "$install_dir/"
install -m644 "$src/LICENSE" "$install_dir/LICENSE.whisper.cpp"
ls -l "$install_dir"
