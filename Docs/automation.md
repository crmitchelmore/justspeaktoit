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
- **Transcribe Audio File** accepts common audio containers (m4a, mp3, wav,
  aac, flac, ogg, opus, aiff, caf, mp4, webm). On macOS it uses your configured
  file-transcription provider; on iOS it uses your batch model. On both
  platforms the result is saved to history, so **Get Last Transcription** and
  the app's History screen show it. The audio itself is not kept: Shortcuts
  hands over a temporary copy that is deleted once the action returns.
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

**Summarise a recording with your own prompt**

1. **Transcribe Audio File**
2. **Polish Text** with Custom Prompt:
   `Summarise this transcript as five terse bullet points for a standup update.`
3. **Send Message** / **Copy to Clipboard**

**Action Button dictation that lands in a draft (iOS)**

1. Assign the Action Button to a shortcut containing **Start Recording**
2. A second shortcut runs **Stop Dictation and Get Text** → **New Draft**
   (Drafts, Notes, Mail — anything that accepts text input)

**"What did I just say?"**

1. **Get Last Transcription**
2. **Show Result** (or **Speak Text**, or pipe it into any other action)

Works even when the recording happened via the Action Button, Live Activity,
or the app itself — it reads the same history the app shows.

### Siri

All actions with App Shortcut phrases can be invoked by voice, e.g. "Start
dictation with Just Speak to It" or "Get my last transcription from Just Speak
to It".

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

The CLI also ships inside the app bundle and is symlinked by the Homebrew cask:

```bash
brew install --cask crmitchelmore/tap/justspeaktoit
speak --version
```

Running from a source checkout:

```bash
swift build --product speak
.build/debug/speak status
```

To use a binary directly from the app bundle:

```bash
/Applications/JustSpeakToIt.app/Contents/MacOS/speak status
```

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

```bash
claude mcp add justspeaktoit -- /Applications/JustSpeakToIt.app/Contents/MacOS/speak mcp
```

Or in an MCP client config file:

```json
{
  "mcpServers": {
    "justspeaktoit": {
      "command": "/Applications/JustSpeakToIt.app/Contents/MacOS/speak",
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

- **Idempotent calls.** The JSON-RPC call id becomes the automation request id
  (`mcp-<id>`). The app replays the stored reply for an id it has already run, so
  an agent retrying a timed-out `start_dictation` cannot open a second session.
- **Tool failures are results, not protocol errors.** "App not running" comes back
  as `isError: true` content the agent can act on, leaving the session usable.
- **Bounded inputs.** Paths, identifiers, history limits and message sizes are
  validated on both sides; oversized or wrongly typed arguments are rejected
  before anything reaches the app.
- **No credentials.** The protocol has no field for a key or token, and the app
  never puts provider configuration into a reply.

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
