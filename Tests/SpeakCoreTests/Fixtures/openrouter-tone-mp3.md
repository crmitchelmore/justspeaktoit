`openrouter-tone-mp3.mp3` is a byte-identical copy of
`Tests/SpeakWindowsPlatformTests/Fixtures/tone-mp3.mp3`: a generated 440 Hz tone,
250 ms, 48 kHz stereo, encoded at 96 kbps with libmp3lame. The original fixture
README records the generation command. No speech, private recording or
third-party media is present. No encoder was run for this change.

The incremental decoder tests exercise the actual Apple MP3 parser/converter,
arbitrary fragment boundaries, bounded PCM output and known final-frame
truncation. Native execution and audible-before-EOF acceptance are separate
qualification requirements; adding this fixture does not establish either.
