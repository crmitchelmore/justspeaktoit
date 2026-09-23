# Synthetic compressed audio fixtures

These files contain only a generated 440 Hz tone: 250 ms, 48 kHz stereo. They
contain no speech, recordings, credentials or third-party media. Windows tests
use them to exercise the actual Media Foundation AAC and MP3 decoder paths,
canonical resampling, signal preservation and original-file ownership.

Generated with FFmpeg's `sine` source:

```sh
ffmpeg -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=0.25' -ac 2 -c:a aac -b:a 96k -map_metadata -1 tone-aac.m4a
ffmpeg -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=0.25' -ac 2 -c:a libmp3lame -b:a 96k -map_metadata -1 tone-mp3.mp3
```

Codec delay/padding may extend the decoded duration beyond exactly 250 ms.
Tests allow this while requiring a non-silent, non-clipped signal and a valid
16 kHz mono PCM16 WAV. The decoder tests require these codecs on the pinned
Windows CI image; an unavailable decoder is a failure, not a skipped pass.
