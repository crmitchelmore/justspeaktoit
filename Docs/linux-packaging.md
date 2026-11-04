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
checks. The bundle, SHA-256, checked-out revision, resolved manifest and installed-test log are retained
as `justspeaktoit-flatpak-x86_64`.

Trusted retests download that fixed-name artifact from an authenticated, successful
same-repository source run. New builds also retain a versioned `build-provenance.json`
with run/attempt, repository and workflow identity, trigger source SHA, actual checkout
and ordered commit parents, same-repository PR identities, and the bundle SHA-256.
The consumer compares it with the live run identity/attempt, the actual fetched git
commit and bundle bytes before checking unchanged package inputs. Current PR head/base
metadata and an association disappearing after merge cannot rewrite the build-time
record. The record has authority only inside that authenticated artifact; copying or
inventing one alone does not establish qualification. Missing legacy records require
a fresh build. Override and sandbox checks are unchanged. This provenance path has
Python regression coverage and passed its [fresh hosted build/install](https://github.com/crmitchelmore/justspeaktoit/actions/runs/40227762194/job/121272697098)
and [trusted installed retest](https://github.com/crmitchelmore/justspeaktoit/actions/runs/40229920326/job/121279237420)
at code revision [`da07071f`](https://github.com/crmitchelmore/justspeaktoit/commit/da07071f5ffd96caa4a7ea3a0b0919a128851479).
Normal PR/merge, public-distribution and physical acceptance gates remain open.

Qualification requires a successful [Linux Flatpak workflow receipt](https://github.com/crmitchelmore/justspeaktoit/actions/workflows/linux-flatpak.yml)
for the chosen revision, with its installed-test log and bundle hash. Historical
packaging-branch success is not evidence for current main. The
[Linux parity matrix](linux-development.md#parity-matrix) continues to distinguish
native synthetic checks from physical desktop acceptance. Interactive GNOME/KDE
portal consent, physical microphone/output, Wayland shortcuts/insertion, login
monitoring, Vulkan execution and ARM64 remain unqualified by this hosted check.

### Sandbox limits on app awareness

Flatpak gives the app its own PID namespace, so another X11 window's
`_NET_WM_PID` cannot be resolved through `/proc`. In the installed Flatpak,
automatic app profiles therefore never match, as on Wayland: the app reports
that normal settings apply and the profile editor says so. Choose a profile
manually. The installed check asserts that host processes stay hidden. The same
missing identity means the X11 front-window guard can refuse automatic paste and
leave the text on the clipboard; that guard is deliberately not loosened, and
no host-process broker (`flatpak-spawn --host`) is added.

## Installing, updating and removing

Each Alpha whose desktop qualification passed publishes the CI bundle as
`JustSpeakToIt-linux-x86_64.flatpak`, served at
<https://justspeaktoit.com/alpha/download/linux-x86_64>. The bundle is built with
`--runtime-repo` pointing at Flathub, so on any distribution with Flatpak
installed:

```sh
flatpak install --user ./JustSpeakToIt-linux-x86_64.flatpak
```

or opening the file in GNOME Software or KDE Discover installs the app and
pulls the GNOME 50 runtime from Flathub (adding the Flathub remote if needed).
The menu entry, icon and the "Start or Stop Dictation" action come from the
package's desktop file and AppStream metadata. `flatpak run
com.justspeaktoit.JustSpeakToIt` starts it; `flatpak uninstall
com.justspeaktoit.JustSpeakToIt` removes it (add `--delete-data` to remove its
data too).

**Updates are manual for now.** A single-file bundle has no update source, so
`flatpak update` and the software centres do not see new builds; installing a
newer bundle over the old one keeps the app's data. The bundle carries no
signature of its own beyond the HTTPS download from GitHub Releases.

**Recommended next step: Flathub.** Flathub is the established route for
signed, automatically updated Flatpaks, and the software centres on most
distributions already list it, so it gives the "open, install, update" path
without a bespoke repository or signing key. The project already uses the
Flathub runtime, SDK extension and `flatpak-builder-lint manifest`. Submission
is free but needs the owner, because it creates a public listing and a
maintainer account ([requirements](https://docs.flathub.org/docs/for-app-authors/requirements),
[submission](https://docs.flathub.org/docs/for-app-authors/submission),
[verification](https://docs.flathub.org/docs/for-app-authors/verification)):

1. Write, by hand, a submission manifest that builds from a tagged `git`
   source of this repository instead of the local `type: dir` source, with
   the same pinned SwiftPM sources. Flathub's
   [generative AI policy](https://docs.flathub.org/docs/for-app-authors/requirements#generative-ai-policy)
   bars AI-generated or AI-assisted content in Flathub manifests, and bars
   AI agents from opening or writing the submission pull request, its
   description or replies. The manifest in this repository was produced with
   agent help, so it is a technical reference only, not the submission.
2. Add Linux screenshots (hosted at stable URLs) and a release entry per
   version to the metainfo; run `flatpak-builder-lint appstream` and
   `flatpak-builder-lint repo` on a built repo.
3. Sign in to GitHub as the owner (2FA required) and open the submission
   pull request to `flathub/flathub` against the `new-pr` branch, titled
   "Add com.justspeaktoit.JustSpeakToIt" (this accepts Flathub's terms).
   Disclose which parts of the app were AI-generated and roughly how much,
   justify each `finish-args` permission, and answer reviewers personally.
   Accept the maintainer invitation within a week of approval.
4. After acceptance, verify the app id's domain by publishing the token
   Flathub gives at `https://justspeaktoit.com/.well-known/org.flathub.VerifiedApps.txt`.
5. Point the website CTA at `https://flathub.org/apps/com.justspeaktoit.JustSpeakToIt`.

Eligibility does not depend on the owner's country and submission is free.
The app id's domain (`justspeaktoit.com`) is owner-controlled and the
project is MIT-licensed and upstream, so it meets the id, licence and
conflicting-submission rules. Acceptance is at the volunteer reviewers'
discretion, with no fixed timescale; they also weigh development history and
the extent of AI-generated code.

Flathub then builds, signs and serves updates. Network, audio, display and
portal permissions in `finish-args` will be reviewed; `--talk-name` for the
status notifier and `--device=dri` are common and documented above.

A self-hosted OSTree repository with a `.flatpakref` would also give updates,
but needs a GPG signing key, hosting and repository maintenance owned by the
project, so it is not used.
