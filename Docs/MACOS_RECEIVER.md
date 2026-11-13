# macOS local transport receiver

The iPhone app has no Bonjour transcript sender or pairing screen. Discovering a
service, enabling the Mac receiver or having protocol support does not send an
iPhone transcription to a Mac. Platform History sync can use iCloud when enabled
and CloudKit is available; it is separate from live insertion at a Mac's cursor.
Mac and iPhone now share one iCloud container; Mac/iPhone History sync stays
unqualified until the device checks for
[#1119](https://github.com/crmitchelmore/justspeaktoit/issues/1119) pass.
Physical iPhone Settings/Privacy and ordinary capture-to-History smoke for #952
remain open.

The retained components are:

- [`TransportServer`](../Sources/SpeakApp/Transport/TransportServer.swift): the
  user-enabled Mac WebSocket receiver and Bonjour advertiser.
- [`MacConnection`](../Sources/SpeakCore/Sync/Apple/MacConnection.swift): the shared protocol
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
[`TransportChannel.swift`](../Sources/SpeakCore/Sync/Apple/TransportChannel.swift):

| Item | Current contract |
| --- | --- |
| Transport | WebSocket over TCP via `NWProtocolWebSocket` |
| Protocol version | 2 (`SpeakTransportProtocolVersion`); v1 plaintext peers are refused |
| Discovery | Train-specific `SpeakTransportServiceType` Bonjour service |
| Endpoint | Bonjour service endpoint, or `ws://<host>:<port>/speak` |
| Encryption | X25519 key share each way, then ChaCha20-Poly1305 with HKDF-SHA256 keys from the X25519 secret and the pairing code (first pairing) or a per-device credential (later sessions) |
| Frame | One binary WebSocket message per sealed JSON `TransportMessage`, ISO8601 dates |
| Unauthenticated ceiling | 4 KiB |
| Authenticated ceiling | 1 MiB |

A bare host-and-port endpoint lacks the HTTP request line required for the
WebSocket handshake. The receiver accepts any request path.

### Encryption

[`TransportSecureSession.swift`](../Sources/SpeakCore/Sync/Apple/TransportSecureSession.swift)
defines the handshake, which `TransportChannel` runs before any message:

1. The client sends its protocol version and an ephemeral X25519 public key. This
   and the Mac's reply are the only plaintext frames. When pairing with the code
   it also sets `requestsCredential`; once paired it sends `credentialID` instead.
2. The Mac replies with its own ephemeral key. Both sides derive one key per
   direction with HKDF-SHA256 from the X25519 secret, a key HKDF-derived from the
   pairing code or the device credential, and a hash of both key-share frames.
3. The client sends a sealed "client finished" frame. The Mac checks it through
   `PairingManager.authorize(_:)`. A code-keyed frame is the pairing check and
   counts towards the lockout below; a credential-keyed frame is checked against
   that stored credential only.
4. The Mac answers with a sealed "server finished" frame, or, for a wrong code,
   an unknown credential or a lockout, a plaintext failure `authResult` that the
   client only ever reads as a refusal. After a code pairing that asked for one,
   "server finished" also carries a new device credential: a 16-byte id and a
   random 32-byte secret.

After that `send` and `receive` accept only sealed frames, and refuse to run
before the handshake. Nonces are per-direction frame counters, so a tampered,
replayed or reordered frame fails to open and closes the connection. Ephemeral
keys make every session's keys unique. The pairing code never crosses the wire.

A plaintext `hello` gets a plaintext error (a protocol-version mismatch for v1,
"requires an encrypted connection" for v2) and the connection closes. There is
no plaintext fallback: no shipping iPhone sender exists, so no v1 peer needs one.

Device credentials (#1643): the code has six digits, and a device that
impersonates the Mac to the phone (for example by spoofing Bonjour) could test
every code offline against the phone's "client finished" frame. So the code is
used only once. After it, sessions are keyed with the credential the Mac issued,
which leaves an impostor nothing it can guess. `MacConnection` stores the
credential per Mac in a `TransportCredentialStore` (a shipping sender must back
it with the Keychain) and never falls back to the code on its own: when the Mac
refuses a revoked credential, the user must forget the Mac and pair again.

The Mac keeps up to 32 credentials beside the pairing code. Regenerating the code
revokes all of them, and removing a paired device revokes the ones bound to it.
An unknown credential is refused without counting towards the lockout.

What is left: the first pairing is still exposed to an impostor present at that
moment, and to one that gets the user to pair again. A PAKE would close that, but
CryptoKit has none.

### Authentication

Inside the encrypted session the client sends `hello` and `authenticate` before
sending text. Protocol-version mismatch and transcript frames before
authentication are rejected; framing limits also apply inside
`NWProtocolWebSocket`. Codes are compared in constant time, and after five
consecutive wrong codes (counted across all connections) every attempt is refused
for a lockout that starts at 30 seconds and doubles per further failure up to an
hour. A correct code or regenerating the code clears it.

## Existing coverage and remaining qualification

`TransportLoopbackTests` connects the actual `MacConnection` and `TransportServer`
on loopback. Its cases cover authenticated transcript delivery, wrong pairing
code, protocol mismatch, plaintext peers, peers without the pairing key, the
lockout through the encrypted handshake, oversized/pre-authentication frames,
disconnect, reconnection identity and listener restart.
`TransportSecureSessionTests` checks the handshake and framing byte by byte:
round trips, an eavesdropper who knows the code, injection without the key, and
tampered, replayed, reordered and cross-session frames. These are protocol fixtures, not
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
