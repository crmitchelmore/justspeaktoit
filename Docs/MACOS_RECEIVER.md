# macOS transport receiver

> **Status (2026-09-09): the iOS "Send to Mac" client has been removed.**
> An audit found that no code on the phone ever called
> `MacConnection.sendTranscript`, so a user could discover the Bonjour service,
> enter the pairing code, connect, dictate — and receive nothing on the Mac,
> with no error. The pairing UI (`MacDiscovery`, `SendToMacView`, `PairingSheet`)
> and its Settings entry are gone.
>
> What remains and still ships:
> - the **Mac-side `TransportServer`** described below, which backs the `speak`
>   automation CLI (#655) and the MCP server (#656);
> - **`MacConnection`** in `SpeakCore`, now purely the client that
>   `TransportLoopbackTests` drives against that server to keep the wire protocol
>   covered.
>
> The sections below describe the wire protocol and the Mac server, which are
> accurate. Sections describing the iOS client, its Settings screen and the
> end-to-end "dictate on the phone, text appears on the Mac" flow describe
> behaviour that no longer exists. Cross-device delivery today is CloudKit
> history sync.

## Wire Protocol

Both ends build their `NWParameters` from `SpeakTransportWire`
(`Sources/SpeakCore/TransportChannel.swift`), so the client and the server cannot
frame messages differently.

| Item | Value |
|------|-------|
| Transport | WebSocket (RFC 6455) over TCP, via `NWProtocolWebSocket` |
| Discovery | Bonjour, `_speaktransport._tcp` |
| Client endpoint | The Bonjour service endpoint, or `ws://<host>:<port>/speak` |
| Frame | One binary WebSocket message per `TransportMessage`, JSON, ISO 8601 dates |
| Frame ceiling before authentication | 4 KiB |
| Frame ceiling after authentication | 1 MiB |

Notes:

- A WebSocket client must address the Mac either by Bonjour service endpoint or
  by URL. A bare host-and-port endpoint cannot complete the handshake, because
  the handshake needs an HTTP request line.
- The server accepts any request path.
- `NWProtocolWebSocket.Options.maximumMessageSize` applies the 1 MiB ceiling
  inside the framing layer, so an oversized frame is refused before its bytes are
  buffered.
- A device must send `hello`, then `authenticate` with the pairing code, before
  the server accepts any message that carries text. Until then it is held to the
  4 KiB ceiling. Anything else closes the connection.
- A `hello` whose `protocolVersion` differs from the server's receives
  `ErrorMessage.protocolMismatch`, which names both versions, and the server then
  closes the connection.
- `TransportLoopbackTests` connects the shipping `MacConnection` to the shipping
  `TransportServer` over a loopback socket and covers each of these rules.
  Codable-only tests cannot: before issue #688 both ends agreed on every message
  shape and still could not exchange one byte, because the phone spoke WebSocket
  while the Mac read a hand-rolled four-byte length prefix.

## What Was Added

### TransportServer (`Sources/SpeakApp/Transport/TransportServer.swift`)
- **Bonjour Advertiser**: Advertises `_speaktransport._tcp` service on local network
- **Connection Handler**: Accepts WebSocket connections from iOS devices  
- **Authentication**: Validates 6-digit pairing codes
- **Message Protocol**: Receives transcript chunks via TransportMessage protocol
- **Text Forwarding**: Automatically inserts received text via `LiveTextInserter`

### AppEnvironment Integration (`Sources/SpeakApp/WireUp.swift`)
- Added `transportServer: TransportServer` to environment
- Configured callback: `onTranscriptReceived` → `environment.liveTextInserter.insertText(text)`
- Auto-start server if `settings.enableSendToMac` is true

### Settings UI (`Sources/SpeakApp/SettingsView.swift`)
- New "Send to Mac" card in General settings
- Toggle to enable/disable server
- Displays pairing code (with copy button)
- Shows connected iOS devices with disconnect option
- Server status indicator (running/stopped)
- List of currently connected devices with connection time

### App Settings (`Sources/SpeakApp/AppSettings.swift`)
- Added `enableSendToMac: Bool` property
- Added `DefaultsKey.enableSendToMac` case
- Persists across app launches

## How It Works

### On macOS:

1. User enables "Send to Mac" in Settings → General
2. `TransportServer` starts and advertises Bonjour service
3. Pairing code is displayed (e.g., "123456")
4. Server listens for connections on local network
5. When iOS connects and authenticates:
   - Connection appears in "Connected Devices" list
   - Transcript chunks are received
   - Text is automatically inserted into active macOS app using existing `LiveTextInserter`

### On iOS: removed

The phone half described here (Settings → Send to Mac → Configure, pair, then
have `TranscriberCoordinator` send final chunks) never existed in the form
written. The pairing screen was real; the sending was not — no code path ever
called `MacConnection.sendTranscript`, and `TranscriberCoordinator` has no
such code. The screen has been removed rather than left as a dead end.

## User Experience

### Pairing Flow:
```
iOS:  Discovers "MacBook Pro" on network
iOS:  User taps to pair
iOS:  Shows: "Enter pairing code from MacBook Pro"
User: Looks at Mac Settings → sees "123456"
User: Enters on iPhone
iOS:  ✅ Connected
Mac:  Shows "iPhone" in Connected Devices list
```

### Transcription Flow:
```
User: Opens email on Mac, places cursor
User: Picks up iPhone, opens Speak
User: Taps microphone, speaks "Let's meet at 3pm"
iOS:  Transcribes speech
iOS:  Sends text to Mac
Mac:  Receives text
Mac:  Inserts "Let's meet at 3pm" at cursor position
User: Text appears in email instantly
```

## Security

- **Pairing Code**: 6-digit numeric code, regeneratable
- **Local Network Only**: No internet required, Bonjour discovery
- **Session Tokens**: Authenticated connections get unique tokens
- **Device Tracking**: Paired devices remembered in UserDefaults
- **Manual Disconnect**: User can remove paired devices anytime

## Build Status

✅ **swift build** - Compiles successfully  
✅ **All targets** - SpeakCore, SpeakiOSLib, SpeakApp  
✅ **Zero errors** - Clean build  

## Testing the Mac server

The end-to-end checklist that used to live here ("Settings → Send to Mac →
Configure", then dictate on the phone and watch text appear on the Mac)
described the removed iOS client and is not runnable. It has been deleted
rather than left as a procedure nobody can follow.

What can be tested today:

- `TransportLoopbackTests` drives the shipping `MacConnection` against the
  shipping `TransportServer` over a loopback socket and covers the handshake,
  the pairing-code authentication, the frame ceilings and the protocol-version
  mismatch. That is the wire protocol's real coverage.
- On the Mac, Settings → General → Enable "Send to Mac" starts the server and
  shows the pairing code. The `speak` automation CLI (#655) is the client that
  exercises it in practice.

## What's next

The Mac transport server is in use by the automation CLI. The iOS client is
removed; see the status note at the top of this file.

If phone-to-Mac delivery is revisited, the open questions the audit recorded are:

- a connection has to outlive the Settings screen (the old one was a
  `@StateObject` on the view, so it was torn down on navigation);
- a sleeping Mac needs Wake on Demand and a sleep proxy, and mDNS is blocked on
  many networks, so a local-network lane needs a fallback;
- CloudKit history sync already reaches the Mac and works when the Mac is
  asleep, so it is the cheaper lane to make live.
