# Android Google Play submission readiness

What Google Play checks, what the repo already satisfies, and the answers to
every Play Console form. Play Console has no API for the listing questionnaires,
so the owner enters them by hand. The answers below are derived from the code;
re-check them whenever the Android app gains a network call, SDK or permission.

## What the repo provides

| Requirement | Where it lives |
| --- | --- |
| Target API level 36 (required for new apps and updates from 31 August 2026) | `android/app/build.gradle.kts` (`targetSdk = 36`) |
| Release build with R8 and resource shrinking | `bundleRelease`, run on every Android PR by `scripts/ci-android.sh` |
| Signed release AAB in CI | `release` job in `.github/workflows/android.yml` (main pushes and manual dispatch, after the build job passes) |
| Monotonic version code | `JSTI_ANDROID_VERSION_CODE` = seconds since 2026-01-01 UTC at build time, set by the release job |
| Upload to the internal testing track | Same job, through `r0adkll/upload-google-play`, when the Play service account is configured |
| Privacy policy inside the app | Settings › Privacy policy opens `https://justspeaktoit.com/privacy` |
| Privacy policy covering Android | The Android section of `landing-page/privacy.html` |
| No backup or device transfer of keys and history | `res/xml/data_extraction_rules.xml`, `allowBackup=false` |
| HTTPS only | No cleartext traffic is permitted (target SDK ≥ 28 default, no network security override) |

### How the release job behaves

The job runs only on `main`, after the `Build & Test (Android)` job (unit tests,
lint, debug build and R8 release build) has passed, in the `android-release`
environment. Secrets are read only by that job.

| Configured in `android-release` | Result |
| --- | --- |
| Nothing | Unsigned rehearsal AAB uploaded as the `justspeaktoit-android-release` artefact |
| Upload keystore secrets | Upload-key-signed AAB artefact, signature verified (refuses a debug certificate) |
| Keystore and `PLAY_SERVICE_ACCOUNT_JSON` | The signed AAB is also published to the **internal** track |

The same upload key signs the sideloadable `JustSpeakToIt-android.apk` that
every green Alpha attaches and `justspeaktoit.com/alpha/download/android`
serves (see [the release train doc](alpha-stable-release-trains.md#android-alpha-apk)).
Play re-signs its builds with the Play App Signing key, so a sideloaded APK and
a Play install cannot update each other; uninstall one before installing the other.

The track release is created as a `draft` until the repository variable
`JSTI_PLAY_RELEASE_STATUS` is set to `completed`. Google rejects non-draft
releases while the app itself is still a draft, so flip the variable only after
the first manual release has gone through.

Each upload needs a higher version code. Deriving it from build time keeps a
re-run of an older workflow run above every earlier upload; main runs are
serialised, so two builds never share a code.

## Store listing

**App name** (30 max): Just Speak to It

**Short description** (80 max):

> Private dictation on your phone, or with your own OpenAI, Groq or OpenRouter key

**Full description** (4,000 max):

> Just Speak to It turns your voice into text, without an account and without a
> server in the middle.
>
> Tap the big button and talk. Words appear as you speak, and the finished
> transcript is ready to copy or share. On Android 12 and newer, recognition can
> run entirely on your phone, so audio never leaves it. Or use your phone's
> speech service, clearly labelled because it may send audio to its provider.
>
> Want a specific model? Add your own API key for OpenAI, Groq or OpenRouter and
> the app sends audio straight to that provider. Optional clean-up tidies
> spelling, grammar and punctuation with a model you choose. Keys are encrypted with
> the Android Keystore and never leave the phone except to authenticate with the
> provider you picked.
>
> Dictate anywhere:
> • A dictation keyboard types into any app (never in password fields)
> • A Quick Settings tile and launcher shortcut start dictation in one tap
> • Share a voice note or audio file from another app to transcribe it
> • History keeps recent transcripts on your phone to copy, share or retry
>
> No account, no subscription, no ads, no analytics. History stays on the
> phone and is excluded from backups. The code is open source under the MIT
> licence: https://github.com/crmitchelmore/justspeaktoit

**Category:** Productivity. **Tags:** Productivity, Tools.
**Contact email:** hello@justspeaktoit.com. **Website:** https://justspeaktoit.com.
**Privacy policy:** https://justspeaktoit.com/privacy.

**Graphics** (owner supplies; none of these are generated in CI):

- App icon 512 × 512 PNG: `landing-page/icon-512.png` (opaque, as Play requires).
- Feature graphic 1024 × 500 PNG or JPEG, no alpha.
- At least 2 phone screenshots (2–8; 16:9 or 9:16, each side 320–3,840 px). Use
  a debug build on a device or emulator with fictional text: the recorder, a
  transcript, History and the keyboard. Tablet screenshots are optional.

## Data safety form

Answers for the current code. "Collected" in Play's sense means the app sends
data off the device; the developer receives nothing.

**Does your app collect or share any of the required user data types?** Yes.
**Is all of the user data collected by your app encrypted in transit?** Yes.
**Do you provide a way for users to request that their data is deleted?** The
app has no account and the developer stores nothing; choose the option stating
that data is not retained, and point to Settings › History › Clear and app
uninstall for on-device data.

| Data type | Collected | Shared | Ephemeral | Required | Purpose | Why |
| --- | --- | --- | --- | --- | --- | --- |
| Audio › Voice or sound recordings | Yes | No | No | Optional | App functionality | Cloud mode uploads the recording to the user's chosen provider with the user's key |
| Audio › Other audio files | Yes | No | No | Optional | App functionality | Audio shared into the app is transcribed with the chosen cloud model |
| App activity › Other user-generated content | Yes | No | No | Optional | App functionality | Clean-up sends transcript text to OpenRouter |

Answer **No** to every other type, including Personal info, Financial info,
Location, Contacts, Messages, Photos and videos, Files and docs, Calendar, Web
browsing, App info and performance (no crash or diagnostics SDK), and Device or
other IDs.

Reasoning to keep on record:

- **Not shared.** Each transfer is user-initiated, to a provider the user
  selected and authenticated with their own key, which is Play's user-initiated
  transfer exception.
- **Not ephemeral.** The app does not retain the data, but the provider's own
  retention is outside the app's control, so do not claim ephemeral processing.
- **Speech service mode.** Audio is handled by the system `RecognitionService`,
  not transmitted by the app. On-device mode keeps audio on the phone.
- **API keys** never leave the phone except as the provider's own
  authentication header.

## Content rating (IARC questionnaire)

Category: **Utility, Productivity, Communication or Other**. Expected result:
Everyone / PEGI 3.

- Violence, fear, sexuality, language, controlled substances, gambling: **No**.
- Users interact or exchange content with each other: **No**. Transcripts never
  travel between users.
- Shares the user's current physical location with other users: **No**.
- Allows users to purchase digital goods: **No**.
- Unrestricted internet access (web browser or search engine): **No**.
- Generative AI: if asked, the optional clean-up sends the user's own transcript
  to a language model to tidy punctuation; it does not generate new content.

## App content declarations

- **Ads:** No ads.
- **Target audience:** 18 and over (do not select children's age groups; the
  app is a general productivity tool not directed at children).
- **News app:** No. **Government app:** No. **Financial features:** None.
- **Health apps:** No. **COVID-19 tracing:** No.
- **App access:** All functionality is available without special access. Note
  for reviewers that on-device and speech-service modes need no key, and cloud
  mode needs the reviewer's own provider key (supply a limited review key in the
  private App access instructions if Play asks).
- **Permissions:** `RECORD_AUDIO` and `INTERNET` only. No foreground service,
  accessibility service, SMS, call log or location permissions.

## Testing track and production access

1. Internal testing (up to 100 testers, no review) receives every green main
   build once the release job is configured.
2. Personal developer accounts created after 13 November 2023 must run a
   **closed test with at least 12 opted-in testers for 14 continuous days**
   before applying for production access. Organisation accounts are exempt.
3. Production is an owner decision; the release job never targets it.

## Owner setup

Exact steps, in order. Never commit the keystore, its passwords or the service
account JSON, and never paste them into an issue.

1. **Create the app.** Play Console › Create app: name "Just Speak to It",
   default language English (United Kingdom), App, Free. Accept the
   declarations. The package name is fixed by the first upload:
   `com.justspeaktoit.android`.
Steps 2 and 3 are done: a keytool RSA 4096 PKCS12 upload key (alias `upload`,
SHA-256 certificate fingerprint
`BF:2D:AC:AF:10:23:36:23:F2:D8:8A:AA:79:02:83:8E:2B:FA:4B:F2:AC:33:28:FF:19:6B:35:E7:C8:DC:82:49`)
is in the `android-release` secrets, with a copy in the owner Mac's login
Keychain under service `justspeaktoit-android-upload` (accounts
`upload-keystore-base64` and `upload-keystore-password`; the key password is
the same). Copy both into 1Password. Repeat them only to rotate the key.

2. **Create the upload key** on a trusted machine (Play App Signing keeps the
   real app signing key):
   ```bash
   keytool -genkeypair -v -keystore jsti-upload.jks -alias upload \
     -keyalg RSA -keysize 4096 -validity 10000 \
     -dname "CN=Just Speak to It, O=Just Speak to It"
   ```
   Store the file and both passwords in 1Password before continuing.
3. **Create the `android-release` environment** in GitHub › Settings ›
   Environments. Deployment branches: *Selected branches*, add `main` only.
   Add these environment secrets:
   ```bash
   base64 -i jsti-upload.jks | gh secret set ANDROID_UPLOAD_KEYSTORE_BASE64 --env android-release
   gh secret set ANDROID_UPLOAD_KEYSTORE_PASSWORD --env android-release
   gh secret set ANDROID_UPLOAD_KEY_ALIAS --env android-release --body upload
   gh secret set ANDROID_UPLOAD_KEY_PASSWORD --env android-release
   ```
4. **Build the first signed AAB:** `gh workflow run android.yml --ref main`,
   then download the `justspeaktoit-android-release` artefact from the run.
5. **First upload by hand** (the Play API cannot create the first release):
   Testing › Internal testing › Create new release › upload `app-release.aab`.
   Accept Play App Signing (Google-generated key). Add yourself to a tester
   list and save the release.
6. **Service account for CI uploads.** In Google Cloud, create a project (or
   reuse one), enable the *Google Play Android Developer API*, create a service
   account and a JSON key. In Play Console › Users and permissions › Invite new
   user, add the service account email with app access to Just Speak to It and
   the permissions *Release apps to testing tracks* and *View app information*.
   Then:
   ```bash
   gh secret set PLAY_SERVICE_ACCOUNT_JSON --env android-release < service-account.json
   ```
   Delete the local JSON file afterwards.
7. **Fill in the forms** under Policy › App content using the answers above:
   Privacy policy, App access, Ads, Content rating, Target audience, Data
   safety, News, Government and Financial features.
8. **Store listing:** Grow › Store presence › Main store listing, with the text
   and graphics above.
9. **After the first release is reviewed**, set
   `gh variable set JSTI_PLAY_RELEASE_STATUS --body completed` so each green
   main build reaches internal testers without a manual rollout.
10. **Closed testing** (personal accounts): create a closed track, add at least
    12 testers by email list or Google Group, and keep it running 14 days
    before applying for production access under Dashboard.
