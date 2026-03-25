# Repository Context

## Durable facts for this role
- The hot path is audio capture, live transcription, and HUD updates during an active session.
- Cloud transcription, post-processing, and text-to-speech introduce network latency that should be separated from local/offline behaviour.
- History, settings, and dashboard surfaces are colder paths but some files are already large and need disciplined changes.
- Resource usage matters on laptops and mobile devices, especially CPU, battery, and retained recording files.
- Performance discussions should use realistic session lengths or payload sizes rather than generic claims.
- The repo already has strong manager and service boundaries, so performance fixes should prefer measured changes in existing hot paths.
