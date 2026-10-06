# Phonon-2 local transcription

Phonon-2 is the first recommended **Local → Batch** model in direct-download macOS
builds on Apple silicon. Existing saved selections remain unchanged. Configure and
Download installs the runtime and model, verifies an offline decode, then selects
Phonon-2. WhisperKit remains the multilingual option and the App Store/Intel choice.
This integration does not add Phonon streaming or iOS support.

macOS onboarding's transcription setup offers **Local** and **Remote** directly.
Local uses the same starter presets as Settings: Phonon-2 (~164 MB of weights,
English only, additional runtime), WhisperKit Large v3 Turbo (~632 MB,
multilingual accuracy), and a compact WhisperKit model (currently Base, ~145 MB,
less storage/memory but lower accuracy on difficult speech). Phonon is omitted
where its runtime is unsupported. Model names and sizes come from the canonical
catalogue; the compact preset chooses an available WhisperKit model under 200 MB
without duplicating the primary recommendation.

Onboarding enables the chosen batch model only after installation succeeds.
Failures are shown with a retry action and leave the previous configuration
usable. Cloud post-processing is disabled for this local-only setup even when a
cloud key already exists; local cleanup remains available. Downloads need an
internet connection, but subsequent transcription does not. Settings also offers
the compact choice for local streaming.

## Runtime and storage

The canonical entry is `PhononLocalModels.phonon2` in SpeakCore, with ID
`local/phonon/phonon-2`. Platform pickers use `ModelCatalog.availableLocalTranscription`.
History resolves the friendly name through the canonical catalogue.

`PhononRuntime` uses `fermion-research==0.2.4` and the exact dependency versions in
`Sources/SpeakApp/Resources/phonon-requirements.txt`. That file is the full transitive
lock for CPython 3.11–3.13 on macOS 14+ arm64, including `setuptools`, which torch
declares but `pip freeze` omits. Every entry carries the PyPI SHA-256 of each matching
wheel. pip runs with `--require-hashes --no-deps --only-binary=:all:`, an explicit PyPI
`--index-url`, `--isolated` and `PIP_CONFIG_FILE=/dev/null`, so user, global and
environment pip configuration cannot redirect or loosen the install. pip does not re-check
packages that are already installed, so the venv records the lock's digest and is rebuilt
whenever that digest is missing or differs. Python 3.11–3.13 must already be
installed. All packages install into a private virtual environment; no global
Python installation is modified. The advertised 164 MB covers the compressed
weights only; the runtime and its dependencies require additional disk space.

Runtime, weights and Hugging Face cache live under the release train's Application
Support `LocalModels/Phonon` directory. Upstream's pinned archive and per-file
checksums verify downloads. A readiness receipt is written only after offline
decoder verification. Model deletion removes only the owned model/cache/receipt;
the installed runtime remains for reuse. Failed installs can be retried. Active
downloads and inference hold deletion guards.

Recordings are converted locally through Core Audio to mono 16 kHz PCM WAV, then
passed to the pinned CLI as a file path. Transcription uses a local model path,
`HF_HUB_OFFLINE=1` and `TRANSFORMERS_OFFLINE=1`. The existing bounded process runner
handles cancellation, timeouts and process-group cleanup. Empty transcripts stay
empty; malformed or explicitly truncated responses fail. English, English locale
and automatic language hints are accepted; other languages produce an actionable
error directing the user to WhisperKit.

The CLI currently loads the model for each recording. Its cold process/model load
adds seconds, so upstream's warm throughput figures are not app latency promises.

## Sources and attribution

Verified 30 September 2026:

- [Official weights and model card](https://huggingface.co/FermionResearch/Phonon-2/tree/9c7fef3584499a88fe8d394427f45851bbb8b446).
- [Official CLI contract](https://github.com/fermionresearch/phonon/blob/bc7c1cae7baeab43e4f15c281305e33c8ea9f46e/docs/cli.md).
- [Pinned Python runtime](https://pypi.org/project/fermion-research/0.2.4/).
- [Upstream NOTICE](https://huggingface.co/FermionResearch/Phonon-2/blob/9c7fef3584499a88fe8d394427f45851bbb8b446/NOTICE).

Phonon-2 © 2026 Fermion Research derives from NVIDIA's
[Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3), © NVIDIA.
Weights are [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/).
Fermion retrained/quantised encoder weights to five values and quantised remaining
parameters to six-bit tables. This app uses the published weights without further
modification. The upstream CLI is Apache-2.0; dependencies retain their own licences.
Settings links to the model attribution and weights licence.

## Reproducible runtime check

`PhononRuntimeTests.testRealOfflineRuntime` is opt-in: set `PHONON_TEST_ROOT` to an
isolated writable directory and `PHONON_TEST_AUDIO` to a synthetic recording saying
“three apples and a cup of tea”. Put a silent PCM file at `<root>/silence.wav`.
Run `xcrun swift test --filter PhononRuntimeTests`. The check installs the exact
runtime, downloads/validates the model, exercises the Swift conversion/inference
path, checks silence, and verifies a missing audio file fails. It never records
the microphone or reads personal recordings. Normal CI skips this download test.
