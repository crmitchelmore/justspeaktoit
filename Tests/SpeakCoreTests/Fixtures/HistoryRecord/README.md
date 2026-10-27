Synthetic fixtures generated from the unchanged legacy `ApplicationHistoryItem` and
`iOSHistoryItem` JSONEncoders at base `4aa25b67`, with ISO8601 dates and sorted keys.
No user exports, credentials or private diagnostic content were used.

`HistoryRecordFixtures.swift` supplies deterministic Mac inputs; the tests compare
both legacy Mac encoder outputs to these fixtures byte for byte. The iOS current
input uses the same fixed UUID/date, an empty processed value, a local error, and
`macos` origin to verify decoding is based on keys. The old iOS fixture removes
only fields its existing backwards-compatible decoder permits to be absent.
The native iOS tests also compare the actual iOS encoder/decoder and shared value.
