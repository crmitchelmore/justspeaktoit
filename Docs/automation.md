# Automation

Just Speak to It exposes its dictation pipeline to automation. This page covers
the **Shortcuts (App Intents)** surface, available on both macOS and iOS. A CLI
(`speak`) and an MCP server are planned follow-ups on the same roadmap
(issue #613, tracked as #655 and #656); they are not shipped yet.

## Shortcuts actions

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
  file-transcription provider; on iOS it uses your batch model. On iOS the
  result is also saved to history.
- **Polish Text** sends the text through the LLM post-processing path
  (OpenRouter, or the on-device Apple model when selected on iOS). Without a
  custom prompt it applies the standard transcript-cleanup contract; with a
  custom prompt, your prompt replaces the cleanup instructions and the text is
  passed to the model verbatim.

## Recipes

### Dictate straight into any app's clipboard workflow (macOS)

1. **Start Dictation**
2. **Wait** (or trigger the second shortcut manually / with a hotkey)
3. **Stop Dictation** → **Copy to Clipboard**

Bind the two shortcuts to keyboard shortcuts in Shortcuts settings for a
system-wide push-to-talk that ends with the transcript on your clipboard.

### Voice memo file → polished note

1. **Select File** (or receive audio from the share sheet)
2. **Transcribe Audio File**
3. **Polish Text** (leave the custom prompt empty)
4. **Create Note** / **Append to Note**

### Summarise a recording with your own prompt

1. **Transcribe Audio File**
2. **Polish Text** with Custom Prompt:
   `Summarise this transcript as five terse bullet points for a standup update.`
3. **Send Message** / **Copy to Clipboard**

### Action Button dictation that lands in a draft (iOS)

1. Assign the Action Button to a shortcut containing **Start Recording**
2. A second shortcut runs **Stop Dictation and Get Text** → **New Draft**
   (Drafts, Notes, Mail — anything that accepts text input)

### "What did I just say?"

1. **Get Last Transcription**
2. **Show Result** (or **Speak Text**, or pipe it into any other action)

Works even when the recording happened via the Action Button, Live Activity,
or the app itself — it reads the same history the app shows.

## Siri

All actions with App Shortcut phrases can be invoked by voice, e.g. "Start
dictation with Just Speak to It" or "Get my last transcription from Just Speak
to It".

## Planned follow-ups

- **CLI (`speak`)** — `speak transcribe file.m4a`, `speak listen`,
  `speak history --last 5 --json`, talking to the running app over the local
  transport so keys and configuration stay in one place. Tracked in #655.
- **MCP server** — `transcribe_file`, `get_history`, `start/stop_dictation`
  exposed as MCP tools for Claude and other agents. Tracked in #656.

Both roll up to issue #613, which stays open until all three surfaces ship.
