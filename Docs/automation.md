# Automation

Just Speak To It exposes three automation surfaces. All of them talk to the
**running app**, so provider credentials, dictation profiles and model choices
stay in one place — no automation surface ever sees an API key.

| Surface | Use it for | Status |
| --- | --- | --- |
| Shortcuts / App Intents | Mac and iOS Shortcuts, Spotlight | Planned — tracked in issue #637 |
| `speak` CLI | Terminal, scripts, CI-style batch work | This document |
| MCP server | Claude Code and other MCP agents | This document (`speak mcp`) |

## The `speak` CLI

`speak` is a thin client. It opens a UNIX domain socket owned by the app
(`~/Library/Application Support/SpeakApp/Automation/automation.sock`, mode
`0600`), sends one length-prefixed JSON request and prints the reply.

### Install

The CLI ships inside the app bundle and is symlinked by the Homebrew cask:

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
  echo "Start Just Speak To It first" >&2
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
  "error": { "code": "app_unavailable", "message": "Just Speak To It isn't running …" }
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

## App Intents / Shortcuts

Not shipped yet. Shortcuts actions (Start Dictation, Stop & Get Text, Transcribe
Audio File, Get Last Transcription, Polish Text) are tracked separately in issue
#637 and will reuse the managers the CLI and MCP paths already drive, so
behaviour will be identical whichever surface starts a session.

## Troubleshooting

**`app_unavailable` while the app is open.** The socket is created at launch. Quit
and relaunch the app, then check the path:

```bash
ls -l ~/Library/Application\ Support/SpeakApp/Automation/automation.sock
```

**Running a second app instance.** Point both the app and the CLI at a different
socket with `SPEAK_AUTOMATION_SOCKET=/path/to/automation.sock`.

**`timed_out` on `transcribe`.** Long recordings on a cloud provider can exceed
the default; raise it with `--timeout 900`.

**`schema_mismatch`.** The CLI and the app were built from different releases.
Update whichever is older.
