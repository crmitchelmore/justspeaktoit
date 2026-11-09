# Linux Flatpak qualification

The Flatpak is a developer preview, not a Flathub or Stable release; it is
distributed from the project's own signed repository (see below). The
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

The single-file bundle has no update source, so `flatpak update` and the
software centres do not see new builds from it; installing a newer bundle over
the old one keeps the app's data. It remains the fallback download.

### Signed Flatpak repository (automatic updates)

The recommended install is the project's own GPG-signed Flatpak repository:

```sh
flatpak install --user https://justspeaktoit.com/linux/flatpak
```

(or open that `.flatpakref` in GNOME Software or KDE Discover). This adds the
`justspeaktoit` remote with its signing key pinned, pulls the GNOME 50 runtime
from Flathub, and from then on `flatpak update` and the software centres pick
up each new qualified Alpha. Someone who installed the single-file bundle runs
the same command once to switch to the updating remote; their data is kept.
`https://justspeaktoit.com/linux/justspeaktoit.flatpakrepo` adds just the
remote. Both URLs fall back to the single-file bundle until a repository has
been published.

[`linux-flatpak-repo.yml`](../.github/workflows/linux-flatpak-repo.yml) runs
after desktop qualification in every Alpha. It imports that Alpha's qualified
bundle (the same bytes the installed checks passed) into a fresh
`archive-z2` OSTree repository, signs the commit and summary, writes the
descriptors, checks the Cloudflare Pages limits (20,000 files, 25 MiB each),
and verifies that the signed remote lists the app and that an unrelated key is
refused. It then deploys the static site to the Cloudflare Pages project
`justspeaktoit-flatpak` (`https://justspeaktoit-flatpak.pages.dev/repo/`),
reusing the site's existing `CLOUDFLARE_API_TOKEN`. It never replaces a newer
published Alpha with an older one. Clients need only the newest commit, so
each publication is a fresh single-commit repository. Without the signing key,
and on pull requests, it rehearses the whole route with a throwaway key and
publishes nothing.

**Why not Flathub, Snap or AppImage (#1219).** Flathub's
[generative AI policy](https://docs.flathub.org/docs/for-app-authors/requirements#generative-ai-policy)
bars agent-written manifests and submissions, so it cannot be automated. The
Snap Store would need a second packaging of the Swift/GTK app, store
registration and review of the interfaces a dictation app needs. An AppImage
would have to bundle GTK 4 and a separate updater. The self-hosted repository
reuses the qualified Flatpak unchanged, keeps sandboxing and gives native
updates; its costs are a signing key and a static site.

#### Owner setup (once)

1. On a trusted machine, create the signing key and keep an offline backup of
   it: rotating it later forces every user to reinstall.

   ```sh
   export GNUPGHOME="$(mktemp -d)"
   gpg --batch --passphrase '' --quick-gen-key \
     "Just Speak to It Flatpak <flatpak@justspeaktoit.com>" ed25519 sign never
   gpg --armor --export-secret-keys > justspeaktoit-flatpak-signing.asc
   ```

2. Create the `flatpak-repo` environment limited to `main` and store the key
   in it (never as a repository secret):

   ```sh
   gh api -X PUT repos/crmitchelmore/justspeaktoit/environments/flatpak-repo \
     -F 'deployment_branch_policy[protected_branches]=false' \
     -F 'deployment_branch_policy[custom_branch_policies]=true'
   gh api -X POST repos/crmitchelmore/justspeaktoit/environments/flatpak-repo/deployment-branch-policies \
     -f name=main -f type=branch
   gh secret set FLATPAK_GPG_PRIVATE_KEY --env flatpak-repo < justspeaktoit-flatpak-signing.asc
   ```

   Then move `justspeaktoit-flatpak-signing.asc` to the offline backup and
   delete the working copy.

3. Run the **Linux Flatpak repository** workflow on `main` with the newest
   `alpha-build-N` tag that has a Linux bundle (or wait for the next Alpha).
   The first run creates the Pages project. If the `justspeaktoit-flatpak`
   Pages name is unavailable, set the repository variables
   `FLATPAK_PAGES_PROJECT`, `FLATPAK_REPO_URL` and `FLATPAK_CHANNEL_URL`, and
   update `flatpakSite` in `landing-page/_worker.js`.

## Shared Swift runtime staging

The application and `speak` CLI can share one SDK runtime rather than embedding
Swift/Foundation in both executables. The stager's `--swift-runtime` accepts the
building compiler's `paths.runtimeLibraryPaths[0]` from `swift -print-target-info`.
It follows ELF `DT_NEEDED` entries recursively, copies only dependencies present
in that SDK directory, refuses escaping SDK symlinks and missing Swift libraries,
and sets executable-relative search paths with `patchelf`. System libraries
remain supplied by GNOME/the distribution. The Swift runtime license accompanies
the libraries. No models or extra sandbox permissions are added.

Both SwiftPM `.resources` and Swift 6.4 `.bundle` resource layouts are supported;
mixed duplicate resource sets are refused. `--strip-symbols` strips only staged
copies for native packaging. Flatpak continues to use its normal separate-debug
processing, preserving debug evidence outside the downloaded application.

A native release payload comparison on Swift 6.4.2 (same resources and whisper
runtime, normalized `tar`, `xz -6`) measured 223,545,421 → 165,200,564 bytes
uncompressed, and 46,056,484 → 31,330,096 bytes compressed. These are native
payload measurements, not a shared GNOME runtime saving. The final
[Flatpak build/install run](https://github.com/crmitchelmore/justspeaktoit/actions/runs/42138678379)
for `63b42e0e` produced a 33,194,016-byte bundle and a 167,433,463-byte installed
application, excluding shared GNOME and optional models. Its authenticated
artifact also passed the full local sandbox checks and compact/wide Wayland
tours on Omarchy. See [the quality rubric](linux-quality-rubric.md) for exact
provenance, measurements and limitations.

PR builds explicitly check out the immutable PR head rather than a synthetic
merge, whose base may differ from the event payload. Provenance accepts that
exact authenticated event head while retaining repository, workflow, run,
attempt, commit-parent and bundle-hash verification. The manifest builds pinned
patchelf 0.18.0 only for staging and removes it during cleanup.
