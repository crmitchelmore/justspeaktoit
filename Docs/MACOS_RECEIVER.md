# macOS local transport receiver

The iPhone app has no Bonjour transcript sender or pairing screen. Discovering a
service, enabling the Mac receiver or having protocol support does not send an
iPhone transcription to a Mac. Platform History sync can use iCloud when enabled
and CloudKit is available; it is separate from live insertion at a Mac's cursor.
Mac/iPhone History sync remains unqualified because their configured iCloud
containers differ; see [#1119](https://github.com/crmitchelmore/justspeaktoit/issues/1119).
Physical iPhone Settings/Privacy and ordinary capture-to-History smoke for #952
remain open.

The retained components are:

- [`TransportServer`](../Sources/SpeakApp/Transport/TransportServer.swift): the
  user-enabled Mac WebSocket receiver and Bonjour advertiser.
- [`MacConnection`](../Sources/SpeakCore/MacConnection.swift): the shared protocol
  client used by `TransportLoopbackTests`. No shipping transcription flow calls
  its `sendSessionStart`, `sendTranscript` or `sendSessionEnd` methods.
- [`AutomationServer`](../Sources/SpeakApp/Transport/AutomationServer.swift): a
  **separate**, user-enabled Unix-domain socket for the `speak` CLI and MCP. Those
  clients use `UnixSocketAutomationClient`, not `MacConnection` or Bonjour. See
  [automation](automation.md) for setup and access controls.

## Receiver and protocol

Mac Settings → General → **Send to Mac** controls the existing receiver through
`enableSendToMac`. Its pairing code, listener status and connected-device controls
remain available to protocol clients. They do not provide an iPhone sender.
`WireUp.swift` wires received transcript chunks to `liveTextInserter.update` and
starts the listener only when its preference is enabled. Listener failure turns
that preference off. Automation has its own preference and listener lifecycle.

Both receiver and client use `SpeakTransportWire` in
[`TransportChannel.swift`](../Sources/SpeakCore/TransportChannel.swift):

| Item | Current contract |
| --- | --- |
| Transport | WebSocket over TCP via `NWProtocolWebSocket` |
| Discovery | Train-specific `SpeakTransportServiceType` Bonjour service |
| Endpoint | Bonjour service endpoint, or `ws://<host>:<port>/speak` |
| Frame | One binary WebSocket message per JSON `TransportMessage`, ISO8601 dates |
| Unauthenticated ceiling | 4 KiB |
| Authenticated ceiling | 1 MiB |

A bare host-and-port endpoint lacks the HTTP request line required for the
WebSocket handshake. The receiver accepts any request path. A client sends
`hello` and authenticates with the pairing code before sending text. Wrong codes,
protocol-version mismatch and transcript frames before authentication are
rejected; framing limits also apply inside `NWProtocolWebSocket`.

## Existing coverage and remaining qualification

`TransportLoopbackTests` connects the actual `MacConnection` and `TransportServer`
on loopback. Its cases cover authenticated transcript delivery, wrong pairing
code, protocol mismatch, oversized/pre-authentication frames, disconnect,
reconnection identity and listener restart. These are protocol fixtures, not
phone-to-Mac delivery or physical microphone/cursor-insertion evidence. No fresh
build or test execution is claimed by this documentation correction.

For a manual receiver check, enable **Send to Mac** on the Mac and inspect its
listener status and pairing code. An iPhone cannot complete a pairing/transcript
walkthrough because its sender and pairing UI were removed. Use the independent
Automation settings for CLI/MCP checks; enabling the Bonjour receiver does not
enable automation.

Any future phone sender needs an explicitly reviewed delivery design and actual
iPhone/Mac acceptance, including connection ownership, unavailable/sleeping Mac,
network interruption and truthful recovery. This document does not add a sender,
new permissions, a namespace migration or a cross-device delivery guarantee.
