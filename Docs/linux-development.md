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
| `SpeakDesktopHost` | Recording, transcription, History, output, post-processing, profiles and model catalogue orchestration, generic over `DesktopHostPlatform`. Shared with Windows (moved out of `SpeakWindows`). |
| `CLinuxSystem/*` | pkg-config system libraries: `libadwaita-1`, `gio-unix-2.0`, `libpulse`, `libsecret-1`, `xtst`. |
| `CLinuxSupport` | The `jsti_*` C ABI (`include/CLinuxSupport.h`): window, clipboard, credentials, capture, private files, X11, portals, self-tests. |
| `SpeakLinuxPlatform` | Testable Swift over the C ABI: keyring, capture, session detection, text-output options, output planning and the output job. |
| `SpeakLinux` | The executable: `LinuxHostPlatform`, events, shortcuts, `--self-test`, `--ui-smoke-test`, `--integration-test`. |

The Linux targets are opt-in with `SPEAK_LINUX_TARGET=1`, like
`SPEAK_WINDOWS_TARGET=1`, so the `portable-linux` job (which has no GTK
packages) is unchanged.

## Build and run

Ubuntu 24.04 (or any distribution with GTK 4.14+, libadwaita 1.5+) and Swift 6.2.3:

```sh
sudo apt install libgtk-4-dev libadwaita-1-dev libpulse-dev libsecret-1-dev \
  libx11-dev libxtst-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
  gstreamer1.0-plugins-good pkg-config
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
under the same canonical identifiers as Windows Credential Manager.

### Flatpak

`packaging/linux/com.justspeaktoit.JustSpeakToIt.yml` builds with the GNOME 48
runtime and the Flathub `org.freedesktop.Sdk.Extension.swift6` extension, with
`--static-swift-stdlib` (checked locally: the release binary links no Swift
libraries and passes `--self-test`; static FoundationNetworking needs libcurl
headers, which the GNOME SDK has). The desktop file and metainfo pass
`desktop-file-validate` and `appstreamcli validate`.

```sh
flatpak-builder --user --install --force-clean build-dir \
  packaging/linux/com.justspeaktoit.JustSpeakToIt.yml
flatpak run com.justspeaktoit.JustSpeakToIt
flatpak run com.justspeaktoit.JustSpeakToIt --toggle
```

The Flatpak build itself has **not been run** yet: the swift6 extension must
ship Swift 6.2 or newer for this package.

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
in History; output never runs during shutdown. On Wayland the focused app is
not visible to clients, so the paste goes to whatever is focused at delivery,
never to JustSpeakToIt's own window; focus re-verification and per-app
profiles are X11-only.

## Parity matrix

"Verified" means exercised by an automated check listed here on Linux, not
proven on a physical desktop.

| Feature | State | Evidence |
|---|---|---|
| Shared host controller (record, stop, transcribe, cancel, close, output slot, History) | Verified | `SpeakDesktopHostTests` with a fake platform; Windows Swift type-checks against it (`scripts/typecheck-windows-swift.sh`) |
| All 31 batch models, OpenRouter discovery, post-processing | Shared code, verified by the portable tests | `swift test` (portable suite) |
| GTK window, events, record-bound History presentation | Verified headless | `--ui-smoke-test` under Xvfb, window self-test, snapshot |
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
| Live transcription in the app | Wired to the shared live clients (OpenAI, Deepgram, AssemblyAI, Speechmatics, Soniox, ElevenLabs, xAI, Mistral) | No provider receipt yet: **unverified** with real keys |
| Shortcut styles (press, hold, double-tap, both) | Session rules verified in the shared host | `SpeakDesktopHostTests`; the X11 grab reports press and release (integration check); portal Deactivated on real desktops **unverified** |
| History playback in the app | Verified player (a tone plays to the end through PipeWire) | App WAV recordings only; other imports use Open audio; audible hardware output **unverified** |
| App profiles | Controller support shared; **no Linux editor** | The X11 target's `/proc/<pid>/exe` path reaches the shared resolver, whose matcher is written for Windows paths: **unverified** |
| Read aloud, local models, IBus insertion, tray, autostart | **Not implemented** | Later phases |
| Flatpak | Manifest, desktop file, metainfo | `flatpak-builder` **not run**; Swift version of the extension unverified |

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

## CI

`.github/workflows/linux.yml` (ubuntu-24.04, `swift:6.2.3-noble`, pinned by
digest) installs the packages above, then runs the boundary check, the
release build, `swift test` with `SPEAK_LINUX_TARGET=1`,
`scripts/linux-desktop-checks.sh` (uploading the window snapshot),
`scripts/linux-integration-checks.sh`, and the Windows Swift type-check. It
also runs on pushes to `claude/linux-port`, which should be dropped when the
branch merges.
