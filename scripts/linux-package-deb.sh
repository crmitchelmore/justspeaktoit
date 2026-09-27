#!/usr/bin/env bash
# Builds a .deb of the Linux app from a release build.
#
#   scripts/linux-package-deb.sh [options]
#     --bin-dir DIR      SwiftPM release bin dir holding SpeakLinux and
#                        SpeakApp_SpeakCore.resources (default: swift build
#                        --configuration release --show-bin-path)
#     --whisper-dir DIR  optional whisper.cpp runtime (scripts/linux-build-whisper.sh)
#     --version X.Y.Z    package version (default: newest release in the metainfo)
#     --output DIR       where to write the .deb (default: current directory)
#
# Layout: /usr/lib/justspeaktoit is a self-contained prefix, like /app in the
# Flatpak. The executable and its SwiftPM resource bundle sit together in
# bin/ (Bundle.module looks beside the executable, which Foundation resolves
# through /proc/self/exe, so the /usr/bin symlink works), and the whisper.cpp
# runtime is in lib/justspeaktoit/, which is <executable dir>/../lib/justspeaktoit.
# Runtime Depends come from dpkg-shlibdeps. Needs dpkg-dev.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
app_id=com.justspeaktoit.JustSpeakToIt
bin_dir=""
whisper_dir=""
version=""
output="$PWD"
while [ $# -gt 0 ]; do
    case "$1" in
        --bin-dir) bin_dir="$2"; shift 2 ;;
        --whisper-dir) whisper_dir="$2"; shift 2 ;;
        --version) version="$2"; shift 2 ;;
        --output) output="$2"; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done
if [ -z "$bin_dir" ]; then
    bin_dir="$(SPEAK_LINUX_TARGET=1 swift build --package-path "$repo" --configuration release --show-bin-path)"
fi
if [ -z "$version" ]; then
    version="$(sed -n 's/.*<release version="\([^"]*\)".*/\1/p' "$repo/packaging/linux/$app_id.metainfo.xml" | head -n1)"
fi
[ -x "$bin_dir/SpeakLinux" ] || { echo "no SpeakLinux in $bin_dir" >&2; exit 1; }
[ -d "$bin_dir/SpeakApp_SpeakCore.resources" ] || { echo "no resource bundle in $bin_dir" >&2; exit 1; }
arch="$(dpkg --print-architecture)"
mkdir -p "$output"
output="$(cd "$output" && pwd)"

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/jsti-deb.XXXXXX")"
trap 'rm -rf "$work"' EXIT
# dpkg-shlibdeps expects a source-package layout: debian/control and the
# staged package in debian/<package>.
root="$work/debian/justspeaktoit"
prefix="$root/usr/lib/justspeaktoit"

install -Dm755 "$bin_dir/SpeakLinux" "$prefix/bin/justspeaktoit"
cp -r "$bin_dir/SpeakApp_SpeakCore.resources" "$prefix/bin/"
mkdir -p "$root/usr/bin"
ln -s ../lib/justspeaktoit/bin/justspeaktoit "$root/usr/bin/justspeaktoit"
install -Dm644 "$repo/packaging/linux/$app_id.desktop" "$root/usr/share/applications/$app_id.desktop"
install -Dm644 "$repo/packaging/linux/$app_id.metainfo.xml" "$root/usr/share/metainfo/$app_id.metainfo.xml"
install -Dm644 "$repo/Resources/Brand/AppIcon.svg" "$root/usr/share/icons/hicolor/scalable/apps/$app_id.svg"

copyright="$root/usr/share/doc/justspeaktoit/copyright"
mkdir -p "$(dirname "$copyright")"
{
    echo "Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/"
    echo "Upstream-Name: JustSpeakToIt"
    echo "Source: https://github.com/crmitchelmore/justspeaktoit"
    echo
    echo "Files: *"
    echo "License: MIT"
    sed 's/^$/./; s/^/ /' "$repo/LICENSE"
} >"$copyright"

private_libs=()
if [ -n "$whisper_dir" ]; then
    lib_dir="$prefix/lib/justspeaktoit"
    mkdir -p "$lib_dir"
    cp -a "$whisper_dir"/lib*.so* "$lib_dir/"
    [ -e "$lib_dir/libwhisper.so.1" ] || { echo "no libwhisper.so.1 in $whisper_dir" >&2; exit 1; }
    {
        echo
        echo "Files: usr/lib/justspeaktoit/lib/justspeaktoit/*"
        echo "Copyright: The ggml authors"
        echo "License: MIT"
        sed 's/^$/./; s/^/ /' "$whisper_dir/LICENSE.whisper.cpp"
    } >>"$copyright"
    private_libs=(-l"usr/lib/justspeaktoit/lib/justspeaktoit")
fi
chmod 644 "$copyright"

mkdir -p "$work/debian" "$root/DEBIAN"
cat >"$work/debian/control" <<EOF
Source: justspeaktoit
Maintainer: JustSpeakToIt <hello@justspeaktoit.com>

Package: justspeaktoit
Architecture: $arch
EOF

# Every ELF file in the package: the app and, when bundled, whisper.cpp.
mapfile -t elves < <(find "$root/usr/lib" -type f \( -name '*.so*' -o -perm -u+x \) \
    -exec sh -c 'file -b "$1" | grep -q ELF' _ {} \; -print | sort)
# Release packages ship without debug sections, as dh_strip would.
strip --strip-unneeded --remove-section=.comment --remove-section=.note "${elves[@]}"
depends="$(cd "$work" && dpkg-shlibdeps -O "${private_libs[@]}" -e"${elves[@]}" 2>"$work/shlibdeps.log" \
    | sed -n 's/^shlibs:Depends=//p')" || { cat "$work/shlibdeps.log" >&2; exit 1; }
grep -v -e "^$" -e "useless dependency" "$work/shlibdeps.log" >&2 || true
[ -n "$depends" ] || { echo "dpkg-shlibdeps found no dependencies" >&2; exit 1; }

installed_size="$(du -sk --exclude=DEBIAN "$root" | cut -f1)"
cat >"$root/DEBIAN/control" <<EOF
Package: justspeaktoit
Version: $version
Architecture: $arch
Maintainer: JustSpeakToIt <hello@justspeaktoit.com>
Installed-Size: $installed_size
Depends: $depends, gstreamer1.0-plugins-base
Recommends: gstreamer1.0-plugins-good, gnome-keyring | kwalletmanager | keepassxc, xdg-desktop-portal
Section: utils
Priority: optional
Homepage: https://justspeaktoit.com
Description: Dictate into any app with cloud speech-to-text
 A developer preview of JustSpeakToIt for Linux. Press a shortcut, speak, and
 the transcript is pasted into the app you were using. Recordings and
 transcripts stay in a local History; audio goes only to the transcription
 provider you choose, with your own API key kept in the desktop keyring.
EOF

deb="$output/justspeaktoit_${version}_${arch}.deb"
dpkg-deb --root-owner-group --build "$root" "$deb" >/dev/null
echo "Built $deb"
dpkg-deb --info "$deb" | sed -n '/Package:/,$p'
