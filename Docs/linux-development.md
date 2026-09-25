# Linux development

The Linux target is a **developer preview, not a Linux release**. It reuses the
portable Swift core (`SpeakCore`, `SpeakDesktop`) and the desktop host shared
with Windows (`SpeakDesktopHost`), and reaches the desktop through a narrow C
adapter (`CLinuxSupport`) over GTK 4/libadwaita, libpulse, libsecret, X11/XTest
and the XDG desktop portals. Feature parity with macOS remains the acceptance
criterion; this document says exactly what is verified and what is not.

## Layout

| Target | Role |
|---|---|
| `SpeakDesktopHost` | Recording, transcription, History, output, post-processing, profiles, model catalogue, Read aloud, on-device model and iCloud sync orchestration, generic over `DesktopHostPlatform`. Shared with Windows (moved out of `SpeakWindows`). |
| `CLinuxSystem/*` | pkg-config system libraries: `libadwaita-1`, `gio-unix-2.0`, `libpulse`, `libsecret-1`, `xtst`, `libcrypto` (OpenSSL). |
| `CLinuxSupport` | The `jsti_*` C ABI (`include/CLinuxSupport.h`): window, clipboard, credentials, capture, private files, X11, portals, the whisper.cpp loader and GChecksum SHA-256, iCloud sync (group, loopback listener, sign-in page, envelope crypto), self-tests. |
| `SpeakLinuxPlatform` | Testable Swift over the C ABI: keyring, capture, session detection, text-output options, output planning, the output job, History playback and speech, voice output staging, and the iCloud sync adapters. |
| `SpeakLinux` | The executable: `LinuxHostPlatform`, events, shortcuts, `--self-test`, `--ui-smoke-test`, `--integration-test`. |

The Linux targets are opt-in with `SPEAK_LINUX_TARGET=1`, like
`SPEAK_WINDOWS_TARGET=1`, so the `portable-linux` job (which has no GTK
packages) is unchanged.

## Build and run

Ubuntu 24.04 (or any distribution with GTK 4.14+, libadwaita 1.5+) and Swift 6.2.3:

```sh
sudo apt install libgtk-4-dev libadwaita-1-dev libpulse-dev libsecret-1-dev \
  libx11-dev libxtst-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
  gstreamer1.0-plugins-good libssl-dev pkg-config
export SPEAK_LINUX_TARGET=1
swift build --product SpeakLinux
swift test                                  # portable, host and Linux tests
.build/debug/SpeakLinux --self-test
scripts/linux-desktop-checks.sh             # self-test + Xvfb window smoke test
scripts/linux-integration-checks.sh         # keyring, PipeWire, portals, X11 paste
.build/debug/SpeakLinux                     # the app
```

The smoke test needs `xvfb` and `dbus`; the integration checks also need
`gnome-keyring pipewire pipewire-pulse wireplumber pulseaudio-utils openbox
zenity xdotool python3-gi`. Set `JSTI_UI_SNAPSHOT_PATH=/tmp/window.png` to save
a picture of the smoke-test window.

A second invocation with `--toggle` starts or stops dictation in the running
app without raising its window (GApplication forwards the command line), so it
can be bound to a key in any desktop. The `app.toggle-recording` action does
the same over D-Bus.

Data lives in `$XDG_DATA_HOME/JustSpeakToIt` (`~/.local/share/JustSpeakToIt`;
Flatpak: `~/.var/app/com.justspeaktoit.JustSpeakToIt/data/JustSpeakToIt`):
`settings.json`, `History/`, profiles and the OpenRouter catalogue cache, all
private to the user (0700/0600). API keys are in the Secret Service keyring
under the same canonical identifiers as Windows Credential Manager. iCloud
sync keeps its state in `CloudSync/state.json` there (see below).

### Flatpak

`packaging/linux/com.justspeaktoit.JustSpeakToIt.yml` builds with the GNOME 50
runtime (GNOME 48 reached end of life in March 2026) and the Flathub
`org.freedesktop.Sdk.Extension.swift6` extension, currently Swift 6.3.3 on the
25.08 branch, with `--static-swift-stdlib` (checked locally: the release binary links no Swift
libraries and passes `--self-test`; static FoundationNetworking needs libcurl
headers, which the GNOME SDK has). The desktop file and metainfo pass
`desktop-file-validate` and `appstreamcli validate`.

```sh
flatpak-builder --user --install --force-clean build-dir \
  packaging/linux/com.justspeaktoit.JustSpeakToIt.yml
flatpak run com.justspeaktoit.JustSpeakToIt
flatpak run com.justspeaktoit.JustSpeakToIt --toggle
```

`flatpak-builder` has built this manifest on GNOME 48 (Swift 6.2) and GNOME 50
(Swift 6.3.3); inside the resulting build environment `--self-test` and the
Xvfb `--ui-smoke-test` passed. iCloud sync has since added a link to
`libcrypto` (OpenSSL), which the freedesktop SDK under the GNOME SDK ships;
no Flatpak has been built with it yet. Not yet done: an installed `flatpak run` on a
desktop, a `.flatpak` bundle in CI, and Flathub readiness.

The root `Package.resolved` pins the Apple graph, which the Linux graph does not
match. `packaging/linux/Package.resolved` pins the Linux graph (SwiftNIO,
NIOSSL, swift-atomics, swift-collections, swift-system). CI and the Flatpak
manifest copy it into place and build with `--force-resolved-versions`, so a
pin that no longer satisfies `Package.swift` fails the build instead of
floating, and CI also fails if the build rewrites the pins. After changing the
Linux dependencies, regenerate it with
`SPEAK_LINUX_TARGET=1 swift package resolve`, copy `Package.resolved` to
`packaging/linux/`, and restore the root file. The Flatpak build still fetches
those pins with network access (`build-args: --share=network`); Flathub builds
offline, so a submission must also list them as git sources.

## Desktop support

| Desktop (2026) | Shortcut | Paste into the focused app | Fallback |
|---|---|---|---|
| GNOME 48+ Wayland | GlobalShortcuts portal (asks once) | RemoteDesktop portal, keyboard only, persist mode 2, restore token in the keyring; transcript offered through the Clipboard portal; Ctrl+V as keysyms | Copied + notification "press Ctrl+V" |
| KDE Plasma 6 Wayland | GlobalShortcuts portal | Same portal path | Same |
| Hyprland | Portal (xdg-desktop-portal-hyprland) | Portal path if its RemoteDesktop is available | Copy |
| Sway, niri, other wlroots | No portal: bind `justspeaktoit --toggle` | No RemoteDesktop portal: copy | Copy |
| COSMIC | Portal or `--toggle` binding | Portal path (restore tokens reported not to persist) | Copy |
| X11 (any) | Ctrl+Alt+Space by XGrabKey | Clipboard + XTest Ctrl+V into the window focused at the shortcut, re-verified before the keystroke; Ctrl+Shift+V for terminals by WM_CLASS; previous clipboard text restored after 750 ms unless the user copied something else | Copy + notification |

Policy carried over from Windows: the target and text-output choice are fixed
when dictation starts; Record in the app's own window never pastes (the app
has focus) and offers Copy; failures leave the transcript on the clipboard and
in History; output never runs during shutdown. Closing cancels every request
and waits at most `DesktopHostShutdown.grace` (5 s); a request that ignores
cancellation cannot reach the window, and its record is recovered with its
audio at the next launch. On Wayland the focused app is
not visible to clients, so the paste goes to whatever is focused at delivery,
never to JustSpeakToIt's own window; focus re-verification and per-app
profiles are X11-only.

## iCloud sync

Linux joins the **Mac** CloudKit container through CloudKit Web Services
exactly as Windows does, and runs the same flow: `DesktopHostCloudSync` in
`SpeakDesktopHost`, with Linux adapters for the transport, keyring,
cryptography, loopback listener and browser. Formats, protocol evidence and
limits are in [Windows CloudKit sync](windows-cloudkit-sync.md); the one-time
CloudKit Console setup is in
[Windows development: iCloud sync](windows-development.md#icloud-sync). One
API token serves both apps: they share the callback URL.

- The **iCloud sync** group, below History, shows the status beside
  **Sign in…** and **Sign out**. Sign in asks CloudKit for Apple's sign-in
  page, opens it in the default browser (only `https` pages on `apple.com` or
  `icloud.com`; through the OpenURI portal inside Flatpak) and listens on
  `http://127.0.0.1:47823/cloudkit-sign-in` for the redirect carrying
  `ckWebAuthToken`, only during sign-in and for at most ten minutes. A
  connection that sends no complete request within five seconds is dropped,
  so an idle browser preconnection cannot hold the callback. The redirect is
  taken only from a process of this user (read from `/proc/net/tcp`) and only
  as a top-level browser navigation; see
  [Sign-in callback](windows-cloudkit-sync.md#sign-in-callback). The rotating
  token is kept in the keyring as `cloudkit.webAuthToken`.
- **Sync History with my Mac** and **Import API keys from my Mac** (off by
  default; needs the key-sync passphrase set on the Mac) take effect with
  **Apply**. Sync runs at launch, every five minutes, after each saved
  transcript and on **Sync now**. Transcripts from the Mac show "from your
  Mac" and refuse playback, opening audio and retry. Recordings made here
  upload with `originPlatform` `linux`, which the Mac shows as their origin.
  Only the key derived from the passphrase is stored (keyring,
  `cloudkit.apiKeySyncKey`); keys are imported from the canonical list only
  and never uploaded. A key typed here is never removed by a later deletion
  on the Mac.
- Sync state (cursor, bound iCloud user, acknowledgements, imported-key
  bookkeeping) is in `CloudSync/state.json` in the data folder, created
  private to the user. Signing out keeps it, History and saved keys; another
  Apple ID resets it and deletes nothing, as on Windows.
- Closing the window stops sync, lets running work end within three seconds
  and only then closes the controller.

The CloudKit API token is a build setting:
`scripts/windows-cloudkit/configure-cloudkit-web.py` writes the
`CLOUDKIT_WEB_API_TOKEN` secret into both `Sources/SpeakWindows` and
`Sources/SpeakLinux/CloudKitWebBuildConfiguration.swift`, which are committed
without one. No Linux workflow injects it yet, so every Linux build says
"iCloud sync is not available in this build" and otherwise works. For local
development set `JSTI_CLOUDKIT_WEB_API_TOKEN` (and
`JSTI_CLOUDKIT_WEB_ENVIRONMENT=development`) before starting the app.

## Parity matrix

"Verified" means exercised by an automated check listed here on Linux, not
proven on a physical desktop.

| Feature | State | Evidence |
|---|---|---|
| Shared host controller (record, stop, transcribe, cancel, close, output slot, History) | Verified | `SpeakDesktopHostTests` with a fake platform; Windows Swift type-checks against it (`scripts/typecheck-windows-swift.sh`) |
| All 31 batch models, OpenRouter discovery, post-processing | Shared code, verified by the portable tests | `swift test` (portable suite) |
| GTK window, events, record-bound History presentation | Verified headless on X11 and Wayland | `--ui-smoke-test` under Xvfb and headless Weston (`scripts/linux-wayland-smoke.sh`), window self-test, snapshot |
| Microphone capture (libpulse via PipeWire) | Verified with a virtual source | integration check: exact 100 ms frames, non-silent test tone; physical USB/Bluetooth microphones **unverified** |
| Microphone list and hotplug | Verified (monitors excluded; a new source triggers a refresh) | integration check; the saved choice keeps an "unavailable" row; physical hotplug **unverified** |
| Secret Service keys | Verified with GNOME Keyring | integration check; KWallet and the Flatpak Secret portal **unverified** |
| X11 paste, focus re-verification, clipboard restore | Verified under Xvfb + Openbox into a GTK (Zenity) field | integration check; real X11 desktops, terminals, Electron, LibreOffice **unverified** |
| X11 Ctrl+Alt+Space grab | Built; grab errors handled | **Unverified** by an automated key press |
| GlobalShortcuts portal | Protocol verified against a fake portal | GNOME 48 / KDE dialogs and real key presses **unverified** |
| Wayland paste (RemoteDesktop + Clipboard portals) | Protocol verified against a fake portal (sessions, persist mode, restore token reuse, SelectionWrite, keysyms) | **Unverified on a real compositor** (see risks below) |
| `--toggle` / app action | Built on GApplication | Forwarding **unverified** by an automated check |
| Import and conversion | Verified for WAV (44.1 kHz stereo to 16 kHz mono) | `LinuxAudioConversionTests` through GStreamer; MP3, M4A and Opus depend on installed plugins and are **unverified**; conversion runs only for 16 kHz-WAV-only models (Meta, Azure) |
| Live transcription transport (SwiftNIO, `SpeakLinuxWebSocket`) | Verified against the loopback probe | `SpeakLinuxWebSocketTests`: echo, PCM frames, ping/pong payload, peer close code and reason with acknowledgement, 2 × 2 MiB through a slow peer, fragmented Unicode and binary, cancellation of pending receive and pre-handshake send, abrupt disconnect, oversize, refused upgrade, and the shared Mistral client's four Voxtral scenarios. TLS (`wss`) to real providers, and live providers other than Mistral's protocol peer, **unverified**; HTTP(S) proxies are **not** honoured by this transport |
| Live transcription in the app | Wired to the same shared live clients as Windows (OpenAI, Deepgram, AssemblyAI, Speechmatics, Soniox, ElevenLabs, xAI, Mistral, Gladia, Cartesia, Rev.ai and Azure Voice Live) | No provider receipt yet: **unverified** with real keys |
| Azure Speech resource endpoint | Settings shows an entry row while an Azure model is selected; entries are checked with the shared `DesktopHostAzureResource` rules before saving, and live Azure refuses to start without one | `DesktopHostAzureResourceTests`; the window self-test checks the row follows the picker |
| iCloud sync: History with the Mac, API-key import | Same shared flow as Windows (`DesktopHostCloudSync`); the flow, the adapters and the group verified against the fake CloudKit server | `DesktopHostCloudSyncTests` (sign-in, History both ways, deletion, sign-out, timeout, shutdown); `LinuxCloudKitTransportTests` and `LinuxLoopbackListenerTests` (fake server over a real loopback socket through URLSession and OpenSSL, callback, idle connections, cancellation); `LinuxEnvelopeCryptographyTests` (the CryptoKit/CNG vectors); window self-test; keyring integration check. A live CloudKit receipt, the Console setup (API token, callback URL, Production schema), a real Apple ID sign-in in a browser and the OpenURI portal inside Flatpak are **unverified** |
| Shortcut styles (press, hold, double-tap, both) | Session rules verified in the shared host | `SpeakDesktopHostTests`; the X11 grab reports press and release (integration check); portal Deactivated on real desktops **unverified** |
| History playback in the app | Verified player (a tone plays to the end through PipeWire) | App WAV recordings only; other imports use Open audio; audible hardware output **unverified** |
| App profiles | Controller support shared; **no Linux editor** | The X11 target's `/proc/<pid>/exe` path reaches the shared resolver, whose matcher is written for Windows paths: **unverified** |
| Read aloud | Verified with a stubbed Deepgram response, a device-free player and a virtual sink. Read aloud in History speaks the displayed transcript (the version shown) with a canonical Deepgram Aura or Flux voice chosen in the Read aloud group, in sentence-bounded segments within Deepgram's 2,000-character limit, through the History player: Play/Pause and Stop act on it, and recording, import, another row, History playback and close end it. The controller is shared with Windows (`DesktopHostReadAloud`). Synthesized WAVs are staged in `VoiceOutput/` (0700, files 0600) only while they play; leftovers from an earlier run are removed | `DesktopHostReadAloudTests` (segments, voice, missing key, Stop, supersession, persistence); `LinuxAudioPlaybackSpeechTests` (speech state, pause between segments, refused segments after Stop); `LinuxVoiceOutputTests` (private staging, a stubbed Deepgram WAV through the engine and speech mode); the window self-test (the button follows the presented record and reports its id, the picker reports the voice); the integration check (a 24 kHz segment plays to the end through PipeWire). A real Deepgram receipt (including Flux linear16/WAV), audible output on a physical desktop, speed control and other providers **unverified** |
| On-device transcription (whisper.cpp 1.9.4, the four pinned Whisper models) | Verified in a container with the CPU runtime built from the pin | `--local-transcription-self-test` downloaded the pinned tiny model through the app's installer and transcribed the JFK sample; `LinuxLocalTranscriptionTests` (GChecksum vectors; with the runtime: JFK, silence, cancellation before and during recognition, cache release by path, held removal); `DesktopHostLocalModelsTests` (download, pause and resume, readiness, removal ownership, a keyless local recording); `DesktopHostLocalModelVerificationTests` (a same-size tampered model is deleted before recognition, rehash only when the runtime may load); `--self-test` (installer cycle, loader refusals); window self-test (Local models rows, events, no key row). Linux CI receipt for this revision, Vulkan (not built), aarch64 (not pinned), large models' speed and memory, and the group on real desktops **unverified**; no Flatpak runtime module |
| IBus insertion, tray, autostart | **Not implemented** | Later phases |
| Flatpak | Built with `flatpak-builder` (GNOME 50, Swift 6.3.3); self-test and window smoke test pass in its environment | Installed `flatpak run`, portals from inside the sandbox and Flathub offline build **unverified** |

### Needs a physical desktop

1. **RemoteDesktop consent on GNOME**: whether a keyboard-only session is
   allowed without a screencast, what the dialog says, whether GNOME shows a
   screen-sharing indicator while the session is open, and whether the restore
   token avoids the dialog after a restart (and after a reboot on KDE, see KDE
   bug 480235). This decides whether the portal paste is acceptable; the copy
   fallback always works.
2. The Clipboard portal: GNOME and KDE must report `clipboard_enabled` and send
   `SelectionTransfer` when the target pastes.
3. GlobalShortcuts on GNOME 48: the first-run dialog, and that the binding is
   keyed by the app ID (needs the Flatpak or an installed `.desktop` file).
4. Insertion into Firefox, Chromium/Electron, LibreOffice, GNOME Terminal and
   Konsole (Ctrl+Shift+V), GTK and Qt fields, with a non-US layout.
5. USB and Bluetooth microphones through PipeWire.
6. iCloud sync, once the container owner has created the API token: that
   CloudKit Console accepts the plain `http://127.0.0.1` callback, a real
   Apple ID sign-in in Firefox and Chromium (and through the OpenURI portal
   from the Flatpak), a Mac transcript arriving and a Linux one reaching the
   Mac, and key import with a real passphrase.

## On-device transcription

Linux transcribes recordings and imported files on this computer with the same
whisper.cpp 1.9.4 runtime and pinned GGML models as Windows
([windows-development.md](windows-development.md#on-device-transcription)).

- **Catalogue.** `LocalModelHostSupport.linux` runs whisper.cpp's GGML backend,
  so Linux projects exactly the shared catalogue entries Windows does (Whisper
  Tiny, Base, Small and Large v3 Turbo, under their canonical
  `local/whisperkit/...` identifiers). `LocalModelHostSupportTests` and
  `DesktopLocalTranscriptionTests` fail if the two hosts ever differ.
- **Shared workflow.** Downloads, verification, readiness, recognition and
  removal ownership moved from the Windows host into `SpeakDesktopHost`
  (`DesktopHostLocalModelManagement.swift`, `DesktopHostLocalModelRemoval.swift`)
  behind `DesktopHostLocalModelPlatform`; a host supplies only its SHA-256, its
  runtime loader and its presenter. Windows type-checks against it.
- **Download.** Models live in `$XDG_DATA_HOME/JustSpeakToIt/LocalModels`, one
  0700 folder per model. `LocalModelInstaller` downloads with HTTP Range into a
  `.partial` file, resumes after a pause or dropped connection, hashes the whole
  file with GLib's `GChecksum` SHA-256, then renames it atomically and writes a
  receipt. A tampered or truncated file is deleted and never loaded: the shared
  host hashes the whole file again, off the controller, before the runtime can
  load it (first use in a process, after another model, or once its size,
  modification time or inode changed), and a transcript is discarded if the
  file changed while in use.
- **Runtime.** `LinuxWhisper.c` opens `libggml-base.so.0`, `libggml.so.0` and
  `libwhisper.so.1` by absolute path, in dependency order, from the executable's
  directory or `JSTI_WHISPER_RUNTIME_DIRECTORY`, so their sonames resolve to
  those copies and neither `LD_LIBRARY_PATH` nor the system is searched (the
  libraries carry no RPATH or RUNPATH). The directory and libraries must not be
  links or writable by other users. It refuses any `whisper_version()` other
  than 1.9.4 (the headers vendored for Windows are shared, not copied), then
  registers the best-scoring `libggml-cpu-*.so` variant and, with the GPU choice
  on and `libggml-vulkan.so` present, Vulkan. It picks those files itself:
  ggml's own loader would also load whatever `GGML_BACKEND_PATH` names. At
  startup `GGML_NO_BACKTRACE` is set (unless already set), so a ggml abort or an
  escaped C++ exception never runs `gdb` from `PATH` against the app. Models
  stay loaded between recordings; cancelling aborts recognition.
- **Controls.** The model picker lists each model with its friendly name and
  state, for example "Whisper Tiny (on-device) — download in Local models", and
  hides the API key row for it. The Local models group lists each model with
  its size and state (Not downloaded, Downloading 42% of 74 MB, 10% downloaded,
  paused, Downloaded and verified, Removing…) and Download or Resume download,
  Cancel and Remove, with licence and provenance as the row's tooltip. The GPU
  switch appears only when the runtime has a Vulkan backend. Local recordings
  need no API key and skip the upload cap; silent recordings stay empty;
  History shows the friendly name. A model that a recording, import or
  transcription uses cannot be removed.
- **Checks.** `--self-test` checks the GChecksum vectors, a download, resume,
  tamper and removal cycle in private folders, and the loader's refusals
  (relative, missing, shared-writable, incomplete and damaged runtimes).
  `--local-transcription-self-test <wav> --expect <phrase> [--model <id>]`
  downloads the pinned model into `JSTI_LOCAL_MODEL_DIRECTORY` and transcribes
  the WAV (`JSTI_WHISPER_CPU_ONLY=1` keeps a Vulkan runtime on the CPU).

### Building the runtime

`scripts/linux-local-runtime/build-whisper-runtime.py` reads the whisper.cpp
pin (tag, commit, licence and JFK fixture digests) from
`scripts/windows-local-runtime/dependencies.json`, so both desktops build one
pin, and takes the Linux CMake switches from
`scripts/linux-local-runtime/dependencies.json`: shared libraries,
`GGML_BACKEND_DL` with every x86-64 CPU variant, OpenMP and native tuning off,
no RPATH. It refuses any library that is not an x86-64 shared object, carries
a search path or needs anything but the C and C++ runtimes and its own
libraries, and writes `runtime/`, `fixtures/jfk.wav` and `runtime-manifest.json`
(sizes, SHA-256, sonames, needed libraries, compiler).

```sh
sudo apt install cmake ninja-build g++ git python3
python3 scripts/linux-local-runtime/build-whisper-runtime.py \
  --output /tmp/whisper-runtime --work /tmp/whisper-work
export JSTI_WHISPER_RUNTIME_DIRECTORY=/tmp/whisper-runtime/runtime
.build/debug/SpeakLinux --local-transcription-self-test \
  /tmp/whisper-runtime/fixtures/jfk.wav --expect 'ask not what your country can do for you'
```

In a 4-vCPU container shared with other builds, the tiny model transcribed the
11-second sample in about 7.5 seconds on the CPU; that is a smoke check, not a
benchmark. `--vulkan` adds `libggml-vulkan.so` (it needs `libvulkan-dev` and
`glslc`, and uses the system's `libvulkan.so.1`); it has not been built or run.
Only x86-64 is pinned.

A Flatpak does not include the runtime yet. It would need a whisper.cpp module
built from the pinned commit (a pinned source, since Flathub builds offline)
with the same switches, installing the libraries beside
`/app/bin/justspeaktoit` and the licence under `/app/share/licenses`. Models
would download into
`~/.var/app/com.justspeaktoit.JustSpeakToIt/data/JustSpeakToIt/LocalModels`
over the existing network permission. None of this is built or tested.

## CI

`.github/workflows/linux.yml` (ubuntu-24.04, `swift:6.2.3-noble`, pinned by
digest) installs the packages above, then runs the boundary check, the
release build, `swift test` with `SPEAK_LINUX_TARGET=1`,
`scripts/linux-desktop-checks.sh` (uploading the window snapshot),
`scripts/linux-integration-checks.sh`, `--local-transcription-self-test` on
the JFK sample, and the Windows Swift type-check. The reusable
`linux-local-runtime.yml` first builds the pinned whisper.cpp runtime in the
same image (cached by its pins); the desktop job downloads it and a cached
tiny model, so the Linux platform tests run against the real runtime. Like
the Windows workflows it is advisory: it runs on pull requests and on `main`
but is not a required check, and nothing else waits for it.

## App ID

The app ID is `com.justspeaktoit.JustSpeakToIt`, under the same
`com.justspeaktoit` domain as the iOS bundle identifiers. It names the Flatpak,
the desktop file, the metainfo, the D-Bus name, the GlobalShortcuts binding and
the Flatpak data path. Treat it as fixed: changing it moves user data and
shortcut bindings.
