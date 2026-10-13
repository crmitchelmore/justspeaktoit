# Configuration transfer and QR capacity

macOS and iOS share `ConfigTransferManager`. A transfer contains every stored
credential in the canonical transfer policy, including provider configurations
that bind an API key to its region and workspace. No credential is silently
dropped to make the QR code fit.

## Compatibility

Small transfers retain the existing version-1 AES-GCM envelope and base64
wrapper. Larger version-1 transfers use the existing raw-envelope JSON shape
when that still fits the 2,953-byte, correction-level-L QR limit.

If the version-1 envelope exceeds that physical limit, the exporter compresses
the plaintext with zlib, then encrypts it in a version-2 AES-GCM envelope.
Compression is never applied to the ciphertext. Version, creation time and salt
remain authenticated, and each encryption uses a fresh nonce. The one-time code
is still absent from the QR and appears only after the source hides the QR.
The ten-minute expiry and key-derivation cost are unchanged.

Version-2 transfers require updated software on both devices. Older importers
reject the new version with their existing update-required error rather than
applying a partial configuration. New importers continue accepting encrypted
version-1 and legacy import-only codes.

## Bounds and errors

The exporter admits at most 64 KiB of plaintext configuration. The version-2
importer uses a fixed 64 KiB output budget, rejects decompression beyond that
budget, and requires a complete compressed stream with no trailing bytes before
decoding the configuration.

Even compression cannot fit an arbitrarily large collection of independent
API keys into one QR code. A transfer that still exceeds 2,953 bytes fails with
an explicit message directing the user to iCloud key sync or manual key entry.
It does not truncate keys, render a misleading partial QR, or change stored
credentials.

`ConfigTransferQRCapacityTests` exercises a high-entropy expanded provider set
with a region-bound Alibaba credential, the exact decompression limit,
overflow, malformed/truncated/trailing compressed input, and authenticated
version changes. The existing transfer tests cover version-1 compatibility,
expiry, wrong codes, catalogue parity and transactional import.
