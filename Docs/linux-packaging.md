# Linux Flatpak qualification

The Flatpak is a developer preview, not a Flathub or Stable release. The
`Linux Flatpak` workflow builds repository-owned pull requests and main when
package inputs change, and supports manual dispatch. It targets x86-64 with
the GNOME 50 SDK/runtime and the freedesktop 25.08 Swift 6 extension. Its pinned
container previously provided Swift 6.3.3; the build log records the actual
compiler used. No signing or publication is performed.

The manifest includes whisper.cpp 1.9.4 at the same commit as the native desktop
runtime pin, with baseline CPU dispatch and a separately loaded Vulkan backend.
The runtime lives under `/app/lib/justspeaktoit`, configured through the manifest's
`JSTI_WHISPER_RUNTIME_DIRECTORY`, and its MIT license is installed. Existing
network, graphics, audio, X11/Wayland and panel permissions are unchanged.

`GGML_NO_BACKTRACE=1` is a package environment default, matching the native
runtime's existing default. It must exist before static Swift captures argv:
the native constructor's early `setenv` can otherwise move `environ` and lose
all command arguments. The same installed binary accepted `--version` only
when the value was preseeded in [the causal probe](https://github.com/crmitchelmore/justspeaktoit/actions/runs/40202256191).
Normal Flatpak user environment overrides retain priority, including `0`.
The final qualification uses ordinary installed commands without test overrides.

SwiftPM dependencies are git sources pinned from `packaging/linux/Package.resolved`.
After changing that resolved file, run:

```sh
python3 packaging/linux/generate-swiftpm-sources.py
python3 packaging/linux/generate-swiftpm-sources.py --check
```

`swiftpm-offline-setup.sh` points SwiftPM mirrors at those local repositories;
`--force-resolved-versions` prevents resolution drift. The build fetches sources
first and then uses `flatpak-builder --disable-download`, without build network
permission. The current production resource/icon stager also stages the `speak`
CLI. The native app self-test decodes all eight bundled recording cues through
the installed runtime's GStreamer codecs.

To reproduce on a Linux machine with Flatpak, flatpak-builder, the GNOME 50
SDK/platform and the Swift 6 SDK extension installed:

```sh
flatpak-builder --download-only --force-clean --state-dir ../flatpak-state \
  ../flatpak-build packaging/linux/com.justspeaktoit.JustSpeakToIt.yml
flatpak-builder --disable-download --force-clean --disable-rofiles-fuse \
  --state-dir ../flatpak-state --repo ../flatpak-repo ../flatpak-build \
  packaging/linux/com.justspeaktoit.JustSpeakToIt.yml
flatpak build-bundle --runtime-repo=https://dl.flathub.org/repo/flathub.flatpakrepo \
  ../flatpak-repo ../JustSpeakToIt-x86_64.flatpak com.justspeaktoit.JustSpeakToIt
flatpak install --user --bundle ../JustSpeakToIt-x86_64.flatpak
flatpak run com.justspeaktoit.JustSpeakToIt --self-test
```

CI installs the actual generated bundle and runs the installed app's resource,
codec and adapter self-test, CLI help, real CPU transcription of the pinned
public-domain JFK sample with the app-downloaded/verified tiny model (including
live folding, silence and cancellation), and the GTK window smoke test under
Xvfb. No SDK substitution or extra filesystem permissions are used for these
checks. The bundle, SHA-256, resolved manifest and installed-test log are retained
as `justspeaktoit-flatpak-x86_64`.

Qualification requires a successful [Linux Flatpak workflow receipt](https://github.com/crmitchelmore/justspeaktoit/actions/workflows/linux-flatpak.yml)
for the chosen revision, with its installed-test log and bundle hash. Historical
packaging-branch success is not evidence for current main. The
[Linux parity matrix](linux-development.md#parity-matrix) continues to distinguish
native synthetic checks from physical desktop acceptance. Interactive GNOME/KDE
portal consent, physical microphone/output, Wayland shortcuts/insertion, login
monitoring, Vulkan execution and ARM64 remain unqualified by this hosted check.
