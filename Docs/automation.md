# Automation

Just Speak to It exposes three automation surfaces. All of them talk to the
**running app**, so provider credentials, dictation profiles and model choices
stay in one place — no automation surface ever sees an API key.

| Surface | Use it for |
| --- | --- |
| Shortcuts / App Intents | Mac and iOS Shortcuts, Siri, the Action Button |
| `speak` CLI | Terminal, scripts, CI-style batch work |
| MCP server | Claude Code and other MCP agents (`speak mcp`) |

Every surface speaks the same verb vocabulary, so a workflow translates
directly between them:

| Verb | Shortcuts action | CLI | MCP tool |
| --- | --- | --- | --- |
| listen | Start Dictation | `speak listen` | `start_dictation` |
| stop | Stop Dictation | `speak stop` | `stop_dictation` |
| transcribe | Transcribe Audio File | `speak transcribe <file>` | `transcribe_file` |
| history | Get Last Transcription | `speak history` | `get_history` |
| polish | Polish Text | — | — |

## Shortcuts / App Intents

Open the Shortcuts app and search for "Just Speak to It". Actions run inside
the app process, so they use the same providers, API keys, and settings you
configured in the app — nothing is duplicated.

| Action | macOS | iOS | Returns |
| --- | --- | --- | --- |
| Start Dictation | Yes | Yes (as "Start Recording" / "Toggle Recording", iOS 18+) | — |
| Stop Dictation ("Stop Dictation and Get Text" on iOS, iOS 18+) | Yes | Yes | Final transcript text |
| Dictate (iOS 18+) | — | Yes | Final transcript text |
| Transcribe Audio File | Yes | Yes | Transcript text |
| Get Last Transcription | Yes | Yes | Most recent history entry (polished text preferred) |
| Polish Text | Yes | Yes | Cleaned-up (or custom-prompt-processed) text |

Notes:

- **Start / Stop Dictation (macOS)** drive the exact same session pipeline as
  the hotkey: live transcription, personal lexicon, post-processing, and text
  delivery all behave as configured. Stop additionally returns the final text
  to the shortcut. The app must be running (it launches on demand, but needs a
  moment to finish starting up on a cold launch).
- **Start / Stop on iOS** requires iOS 18 (system policy for background audio
  recording). The existing "Start Recording" / "Toggle Recording" /
  "Stop Recording" actions remain; "Stop Dictation and Get Text" is the
  variant that hands the transcript to the next action in your shortcut.
- **Dictate (iOS)** is the one-shot version: it records, finishes on its own
  once you stop speaking, and returns the transcript — one trigger instead of
  the Start / "Stop Dictation and Get Text" pair. *Pause Length* is how long
  silence must hold before it finishes (2–8 seconds, 3 by default; shorter
  finishes sooner but is likelier to cut you off mid-thought). *Maximum Length*
  is the hard stop whatever happens (5–60 seconds, 25 by default). Values above
  25 may not return before the system ends the action, because below iOS 27
  there is no long-running-intent API to host the recording in. Destination,
  language, model and source work as they do on the other recording actions.
  A Dictate that arrives while something is already recording is refused rather
  than opening a second microphone.
- **Wait For Polish (iOS 18+)**, on both *Dictate* and *Stop Dictation and Get
  Text*, decides which version of the transcript your shortcut receives. It is
  **off by default**, which is what these actions always did: they return the
  raw transcript the moment recording stops. Turn it on when your destination
  is *Clipboard and Polish* and you want the chain and the clipboard to agree —
  otherwise the shortcut gets the raw text while the clipboard is quietly
  replaced with the polished one a few seconds later. The wait is bounded; if
  the polish fails, returns nothing, or has not landed in time, the raw
  transcript is returned rather than nothing at all.
- **Transcribe Audio File** accepts common audio containers (m4a, mp3, wav,
  aac, flac, ogg, opus, aiff, caf, mp4, webm). On macOS it uses your configured
  file-transcription provider; on iOS it uses your batch model. On both
  platforms the result is saved to history, so **Get Last Transcription** and
  the app's History screen show it. The audio itself is not kept: Shortcuts
  hands over a temporary copy that is deleted once the action returns, and
  **the file you shared is only ever read — never moved, renamed, changed or
  deleted.** On iOS the action also takes optional *Language* and *Model*
  overrides for that recipe only; leave them unset to use Settings. A file it
  cannot use is refused with the reason — an unsupported format, a file over
  the size cap, an iCloud file that is not downloaded to this device yet, an
  empty file, or one it could not open — rather than failing silently.
- **Polish Text** sends the text through the same post-processing path a
  dictation session uses, so your configured model applies — including the
  on-device Apple Foundation model and downloaded local models, which need no
  API key — along with your post-processing temperature. Without a custom
  prompt it applies your effective cleanup prompt (custom base prompt, output
  language, and active dictation profile included); with a custom prompt, your
  prompt replaces the cleanup instructions and the text is passed to the model
  verbatim.

### Recipes

**Dictate straight into any app's clipboard workflow (macOS)**

1. **Start Dictation**
2. **Wait** (or trigger the second shortcut manually / with a hotkey)
3. **Stop Dictation** → **Copy to Clipboard**

Bind the two shortcuts to keyboard shortcuts in Shortcuts settings for a
system-wide push-to-talk that ends with the transcript on your clipboard.

**Voice memo file → polished note**

1. **Select File** (or receive audio from the share sheet)
2. **Transcribe Audio File**
3. **Polish Text** (leave the custom prompt empty)
4. **Create Note** / **Append to Note**

To reach it from anywhere on iOS, open the shortcut's settings and turn on
**Show in Share Sheet** with the accepted input set to Files (or Media). It
then appears when you share a Voice Memo, an Apple Watch memo synced to the
phone, or any audio file in Files.

**Summarise a recording with your own prompt**

1. **Transcribe Audio File**
2. **Polish Text** with Custom Prompt:
   `Summarise this transcript as five terse bullet points for a standup update.`
3. **Send Message** / **Copy to Clipboard**

**Action Button dictation that lands in a draft (iOS)**

1. Assign the Action Button to a shortcut containing **Dictate**
2. Follow it with **New Draft** (Drafts, Notes, Mail — anything that accepts
   text input)

One press, and the shortcut finishes on its own once you stop talking. The
older two-shortcut form still works: **Start Recording**, then a second
shortcut running **Stop Dictation and Get Text**.

**Finish headless recordings without a second press**

Settings → Action Button & Shortcuts → **Stop On Silence**. Recordings started
from a Control, the Action Button, Siri or a Shortcut then finish on their own
after the pause length you choose. It is off by default: it saves a press for
people who dictate in bursts and gets in the way of people who think in long
pauses. Recordings you start in the app or from the keyboard are unaffected,
and a recording that never goes quiet still stops after 15 minutes.

**"What did I just say?"**

1. **Get Last Transcription**
2. **Show Result** (or **Speak Text**, or pipe it into any other action)

Works even when the recording happened via the Action Button, Live Activity,
or the app itself — it reads the same history the app shows.

### The gallery in the app (iOS)

**Settings → Action Button & Shortcuts → Shortcuts Gallery** lists the same
recipes with the exact action names to search for, marks which steps are Just
Speak to It's and which are Apple's, and opens the Shortcuts app. Deliberately
recipes rather than one-tap `.shortcut` downloads: a hosted shortcut has to be
re-signed for every iOS release and fails to install silently when it is not,
which is worse than no gallery entry at all. Every Just Speak to It action a
recipe names is checked against the shipped App Intent by a test, so a renamed
action breaks the build rather than the recipe.

### Share Sheet (iOS)

There is also an optional Share extension that skips Shortcuts entirely: share
an audio file to **Just Speak to It** and it copies the recording into the
app's own storage, then the app transcribes it the next time you open it and
saves the result to History.

It is built only when the project is generated with
`TUIST_IOS_SHARE_EXTENSION=1` — like the custom keyboard and the watch app, it
needs its own App ID, App Group registration and provisioning profile before it
can ship, so it is off by default and release signing is unaffected until those
exist.

What it does and does not do:

- **Your recording is only ever read.** The extension opens it for reading,
  copies it in fixed 64 KiB chunks (so a long recording is never held in
  memory, which is what gets a Share extension killed), and never moves,
  renames, changes or deletes the original.
- Every refusal says which one it was and that nothing was changed: an
  unsupported format, a file over the size cap, an iCloud file that is not
  downloaded yet (open it once in Files first), an empty file, one it could not
  open, or an import you cancelled — in which case the partial copy is deleted.
- The sheet does not close itself on a failure. A share sheet that dismisses
  itself is indistinguishable from one that worked.
- If the transcription itself fails later, the app says so, names the file, and
  says your recording was not changed.

### Siri

All actions with App Shortcut phrases can be invoked by voice, e.g. "Start
dictation with Just Speak to It", "Dictate with Just Speak to It" or "Get my
last transcription from Just Speak to It".

## Turn automation on first (CLI and MCP)

Shortcuts actions run inside the app and work out of the box. The CLI and MCP
surfaces instead talk to the app over a local socket, and that socket is **off
by default**. While it is on, anything running under your macOS account can
start the microphone and read your transcription history, so the socket only
opens once you ask for it: **Settings → General → Automation → Enable
automation (speak CLI and MCP)**. Until then every client gets
`app_unavailable`, exactly as it would if the app were closed.

## The `speak` CLI

`speak` is a thin client. It opens a UNIX domain socket owned by the app
(`~/Library/Application Support/SpeakApp/Automation/automation.sock`, mode
`0600`), sends one length-prefixed JSON request and prints the reply.

### Install

**From the app (recommended):** Settings → General → **Automation CLI** → *Install CLI*.
The app downloads the release's standalone `speak` build for your Mac's
architecture, verifies the signed release manifest, the archive's size and
SHA-256, the executable's architecture and its Developer ID signature, then
installs it atomically at:

```text
~/Library/Application Support/SpeakApp/bin/speak
```

No administrator rights are needed and your shell profile is never edited.
The card offers *Copy PATH command* — paste that line into `~/.zshrc` (or
symlink the binary, e.g. `ln -s "$HOME/Library/Application Support/SpeakApp/bin/speak" ~/.local/bin/speak`).
*Check for update* fetches the latest manifest; *Uninstall* removes only the
files the installer wrote. A failed download or verification never replaces a
working CLI.

**Homebrew:** the cask installs the app and depends on the `speak` formula, so
`speak` lands on your PATH; the formula alone installs just the CLI:

```bash
brew install --cask crmitchelmore/justspeaktoit/justspeaktoit   # app + CLI
brew install crmitchelmore/justspeaktoit/speak                  # CLI only
speak --version
```

Older casks linked the copy inside the app bundle; upgrading removes that
link and the formula provides the standalone binary instead. Both install
paths deliver the same signed, notarised build for your Mac's architecture,
published as `speak-<version>-<arch>.zip` alongside each release together with
`speak-cli-manifest.json` and its signature.

Running from a source checkout:

```bash
swift build --product speak
.build/debug/speak status
```

The Apple Silicon download no longer carries a `speak` binary inside the app
bundle; the universal (Intel-compatible) legacy download still does, at
`/Applications/JustSpeakToIt.app/Contents/MacOS/speak`.

### Commands

```text
speak transcribe <file> [--json] [--timeout <seconds>]
speak listen [--json]
speak stop [--json]
speak history [--last <n>] [--json]
speak status [--json]
speak mcp
speak --help | --version
```

### Recipes

Transcribe a voice memo and copy it to the clipboard:

```bash
speak transcribe ~/Downloads/memo.m4a | pbcopy
```

Dictate a commit message:

```bash
speak listen
# ... talk ...
git commit -m "$(speak stop)"
```

Pull the last five transcriptions as JSON:

```bash
speak history --last 5 --json | jq -r '.data.entries[].text'
```

Fail a script cleanly when the app is closed:

```bash
if ! speak status >/dev/null; then
  echo "Start Just Speak to It first" >&2
  exit 1
fi
```

### JSON output

`--json` prints one versioned envelope on stdout, for success **and** failure, so
a consumer only ever parses one stream:

```json
{
  "schemaVersion": 1,
  "ok": true,
  "command": "transcribe_file",
  "data": { "text": "hello world", "model": "nova-3", "durationSeconds": 4.2 }
}
```

```json
{
  "schemaVersion": 1,
  "ok": false,
  "command": "status",
  "error": { "code": "app_unavailable", "message": "Just Speak to It isn't running …" }
}
```

`schemaVersion` only changes when an existing field changes meaning; new fields
are added without a bump, so pin on the version and ignore unknown keys.

### Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success |
| `1` | The command ran but failed (e.g. `not_recording`, `transcription_failed`) |
| `2` | Usage error — bad flags or arguments; nothing was sent to the app |
| `3` | The app is not running / the automation socket is unreachable |

### Error codes

`app_unavailable`, `schema_mismatch`, `invalid_argument`, `unsupported_command`,
`file_not_found`, `file_too_large`, `not_recording`, `already_recording`,
`transcription_failed`, `timed_out`, `internal_error`.

Branch on `error.code`, not on the message text.

## MCP server

`speak mcp` runs a stdio MCP server that exposes the same operations as tools.
Messages are newline-delimited JSON-RPC 2.0, per the MCP stdio transport.

### Claude Code

With `speak` on your PATH (Homebrew, or the PATH command from the Automation
CLI card):

```bash
claude mcp add justspeaktoit -- speak mcp
```

Or in an MCP client config file, using the full path so it works regardless
of the client's PATH (replace `<you>` with your user name, or use
`$(brew --prefix)/bin/speak` for a Homebrew install):

```json
{
  "mcpServers": {
    "justspeaktoit": {
      "command": "/Users/<you>/Library/Application Support/SpeakApp/bin/speak",
      "args": ["mcp"]
    }
  }
}
```

### Tools

| Tool | Arguments | Returns |
| --- | --- | --- |
| `transcribe_file` | `path` (required), `timeout_seconds` | Transcript text |
| `get_history` | `limit` (1–200, default 10) | Recent transcriptions, newest first |
| `start_dictation` | — | Confirmation once the session is live |
| `stop_dictation` | — | Transcript of the finished session |

Every tool also returns `structuredContent` with the same fields as the CLI's
`--json` `data` object.

### Behaviour worth knowing

- **Process-scoped idempotent calls.** The JSON-RPC call id becomes an automation
  request id shaped like `mcp-<process-scope>-<call-id>`, where the process scope
  is an eight-character UUID prefix. The final identifier is truncated to
  `AutomationLimits.maxIdentifierLength`. Reusing a call id within the same MCP
  server process lets the app replay its cached reply, so an agent retrying a
  timed-out `start_dictation` does not open a second session. A new server process
  receives a new scope: this does not promise exactly-once execution across
  processes or unlimited cache retention.
- **Tool failures are results, not protocol errors.** "App not running" comes back
  as `isError: true` content the agent can act on, leaving the session usable.
- **Bounded inputs.** Paths, identifiers, history limits and message sizes are
  validated on both sides; oversized or wrongly typed arguments are rejected
  before anything reaches the app.
- **No credentials.** The protocol has no field for a key or token, and the app
  never puts provider configuration into a reply.

### Claude Code qualification record

The released-app protocol check from 26 August 2026 used app/CLI version 2.62.0
and a hand-driven stdio client. It successfully called `get_history` with
`limit: 1`, observed both `content` and `structuredContent`, confirmed owner-only
socket permissions, and restored Automation to off. Preserve that as protocol
evidence; it is not the outstanding real-Claude-Code client result.

Use this compact record for the named-client gate. Do not include transcript
text, request headers, tokens, account identifiers, or full client logs. Mark
each result PASS, FAIL, or NOT RUN.

| Evidence | Result |
| --- | --- |
| Date; macOS/architecture | NOT RUN — `<date>; <macOS>; <architecture>` |
| App version/build; standalone `speak` path and version; `claude --version` | NOT RUN — `<versions and resolved absolute path>` |
| Original Automation state; local registration name/scope; restoration | NOT RUN — `<state; name; local scope; restored yes/no>` |
| Real client connection and discovered tools | NOT RUN — expect exactly `transcribe_file`, `get_history`, `start_dictation`, `stop_dictation` |
| Invoked argument and response shape/count | NOT RUN — `get_history({"limit":1})`; record `content`, `structuredContent`, and item count without text |
| Failure classification | NOT RUN — `<none, PATH, opt-in/socket, account/client permission, or protocol mismatch; redacted code>` |
| Disabled-access check and final state | NOT RUN — `<fresh call blocked; socket absent where applicable; original state restored>` |

Run this gate only on an authorised Mac with an existing usable Claude Code
client/account, running app, installed standalone CLI, and explicitly
non-sensitive History entry. Use a local registration and preserve any existing
target-server configuration. Do not install software, change account/provider
state, or enable Automation without authorisation. Configuration output alone is
not a pass: the real client must discover exactly the four tools and complete
`get_history({"limit":1})`. Disabling Automation prevents new access but does not
erase content already returned to a client.

The documentation change may merge while every row remains NOT RUN. Keep issue
#656 open until the real-client registration and call pass; file transcription,
microphone, and paid-provider qualification belong to their separate gates.

## Troubleshooting (CLI and MCP)

**`app_unavailable` while the app is open.** Check that automation is enabled in
Settings → General → Automation; the socket only exists while that toggle is on.
It is created when the app launches with the setting already on, so if you have
just enabled it and still see this, check the path:

```bash
ls -l ~/Library/Application\ Support/SpeakApp/Automation/automation.sock
```

**Running a second app instance.** Point both the app and the CLI at a socket in
an owner-only directory. The app rejects a shared parent rather than changing
its permissions:

```bash
install -d -m 700 "$HOME/.speak-automation"
export SPEAK_AUTOMATION_SOCKET="$HOME/.speak-automation/automation.sock"
```

**`timed_out` on `transcribe`.** Long recordings on a cloud provider can exceed
the default; raise it with `--timeout 900`.

**`schema_mismatch`.** The CLI and the app were built from different releases.
Update whichever is older.
