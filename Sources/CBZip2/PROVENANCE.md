# Vendored libbz2 1.0.8

Windows-only target used to expand the digest-pinned local runtime and model
archives in process. Only the streaming decompression API is called.

- Upstream: https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz
- Tarball: 810,029 bytes, SHA-256
  `ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269`
  (the same URL and digest are pinned independently by Homebrew's `bzip2`
  formula; upstream's detached signature `bzip2-1.0.8.tar.gz.sig` was
  retained with the research receipts).
- Licence: `LICENSE` (the bzip2/libbzip2 licence, copied unmodified). Binary
  distributions must reproduce it; it is listed for the Windows notices.

Files copied byte-for-byte from `bzip2-1.0.8/` (SHA-256):

| File | SHA-256 |
| --- | --- |
| `blocksort.c` | `4e48cd2ccff44699e67a7c949b0e9576c05b8dcbe20f863475c4fcc8db11a409` |
| `bzlib.c` | `d06cf1bd991df1f2dc8ef4f7713d186eb636767111cbd4807ef5fc4a54ca6838` |
| `compress.c` | `75995bd6e8c5f1e1dad05178f3cf53137df99ce860a1984324f78591f28deed3` |
| `crctable.c` | `2fb7a564629386456e731f431a5cf4f5026747bace4cd10be8f5ecf082066a92` |
| `decompress.c` | `31a89f8bf408ef0e4acae83e8be60a8eb4edece6c866d6e32b8f7e557ca54bc6` |
| `huffman.c` | `bdeb45f3f535546a672811b68aa87cc58fd395b28ecebc34fa3566a656a4d1d1` |
| `randtable.c` | `407054ca6f54cd737dbc26ceb6b7874b55a0fcff86c2eb23cbec2fbdbb884815` |
| `bzlib_private.h` | `c0cda4f35ee1f2d54c9beacd524f8d28e0dbf8494aca30d854af3f143af4341b` |
| `include/bzlib.h` | `6ac62e811669598ee30c9e1c379b9e627f6ff17a5a3dc1e0b4fa8b8ea75e580d` |
| `LICENSE` | `c6dbbf828498be844a89eaa3b84adbab3199e342eb5cb2ed2f0d4ba7ec0f38a3` |

Local additions (this project): `include/CBZip2.h` defines `BZ_NO_STDIO`
before including `bzlib.h`, and `JSTIBZip2Support.c` supplies the required
`bz_internal_error`, recording the code per thread instead of exiting.
