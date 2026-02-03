#!/bin/bash

# Script to add accessibility labels to macOS views

set -e

cd /Users/cm/work/justspeaktoit

echo "Adding accessibility labels to HUDView.swift..."

# HUDView.swift changes
sed -i.tmp '/foregroundStyle(headlineColor)/a\
          .accessibilityLabel("Status: \\(manager.snapshot.headline)")' Sources/SpeakApp/HUDView.swift

sed -i.tmp '/\.foregroundStyle(\.secondary)$/,/^[[:space:]]*}/{
  /^[[:space:]]*}$/i\
            .accessibilityLabel(sub)
}' Sources/SpeakApp/HUDView.swift

sed -i.tmp '/Press ⌘R to retry/,/padding(.top, 4)/a\
            .accessibilityHint("Press Command-R to retry the operation")' Sources/SpeakApp/HUDView.swift

sed -i.tmp '/AudioLevelMeterView(level: manager.audioLevel/a\
          .accessibilityLabel("Audio level meter")\
          .accessibilityValue("\\(Int(manager.audioLevel * 100)) percent")' Sources/SpeakApp/HUDView.swift

sed -i.tmp '/Text(elapsedText)/,/.foregroundStyle(.secondary)/a\
          .accessibilityLabel("Elapsed time: \\(elapsedText)")' Sources/SpeakApp/HUDView.swift

sed -i.tmp '/\.animation(.easeInOut(duration: 0.2), value: isFinal)/a\
        .accessibilityLabel(isFinal ? "Transcript: \\(text)" : "Partial transcript: \\(text)")' Sources/SpeakApp/HUDView.swift

sed -i.tmp '/Capsule()/,/\.fill(.quaternary)/a\
          )\
          .accessibilityLabel("Confidence: \\(Int(confidence * 100)) percent")' Sources/SpeakApp/HUDView.swift

sed -i.tmp '/exclamationmark.triangle.fill/,/shadow(color: phaseColor/a\
          .accessibilityLabel("Error indicator")' Sources/SpeakApp/HUDView.swift

sed -i.tmp '/checkmark.circle.fill/,/shadow(color: phaseColor/a\
        .accessibilityLabel("Success indicator")' Sources/SpeakApp/HUDView.swift

sed -i.tmp '/\.shadow(color: phaseColor\.opacity\(0\.4\)/a\
          .accessibilityLabel("Recording status indicator")' Sources/SpeakApp/HUDView.swift

# Clean up temp files
rm -f Sources/SpeakApp/HUDView.swift.tmp

echo "Adding accessibility labels to MainView.swift..."

# Main View.swift changes - add helper function and accessibility labels
cat > /tmp/main_view_additions.txt << 'EOF'
  
  private var accessibilityLabelForRecordButton: String {
    switch environment.main.state {
    case .idle, .completed(_), .failed(_):
      return "Start recording"
    case .recording:
      return "Stop recording"
    case .processing:
      return "Processing recording"
    case .delivering:
      return "Delivering transcription"
    }
  }
EOF

# Add the helper function before the closing brace
sed -i.tmp '/^}$/,${
  /^}$/i\
'"$(cat /tmp/main_view_additions.txt)"'
  /^}/q
}' Sources/SpeakApp/MainView.swift

# Add accessibility label to button
sed -i.tmp '/\.speakTooltip("Start or stop a recording/a\
      .accessibilityLabel(accessibilityLabelForRecordButton)' Sources/SpeakApp/MainView.swift

# Add accessibility label to status item
sed -i.tmp '/strokeBorder(.secondary.opacity(0.3)/a\
      )\
      .accessibilityLabel("Current mode: \\(environment.settings.transcriptionMode.displayName)")' Sources/SpeakApp/MainView.swift

rm -f Sources/SpeakApp/MainView.swift.tmp
rm -f /tmp/main_view_additions.txt

echo "Adding accessibility labels to SettingsView.swift..."

# Settings View.swift - add accessibility labels to key pickers and buttons
sed -i.tmp '/Picker("Theme", selection: settingsBinding/,/speakTooltip("Choose whether Speak follows macOS/a\
          .accessibilityLabel("Appearance theme picker")' Sources/SpeakApp/SettingsView.swift

sed -i.tmp '/Picker("Text Output", selection: settingsBinding/,/speakTooltip("Decide how Speak returns/a\
          .accessibilityLabel("Text output method picker")' Sources/SpeakApp/SettingsView.swift

sed -i.tmp '/Picker("Show App In", selection: settingsBinding/,/pickerStyle(.segmented)/a\
            .accessibilityLabel("App visibility picker")' Sources/SpeakApp/SettingsView.swift

sed -i.tmp '/Picker("Input Device", selection: audioInputSelectionBinding/,/speakTooltip("Choose which microphone/a\
          .accessibilityLabel("Audio input device picker")' Sources/SpeakApp/SettingsView.swift

sed -i.tmp '/Label("Refresh", systemImage: "arrow.clockwise")/,/speakTooltip("Reload the list/a\
            .accessibilityLabel("Refresh audio devices")' Sources/SpeakApp/SettingsView.swift

sed -i.tmp '/Picker("Sound profile", selection: settingsBinding/,/\.fill(Color(nsColor: \.controlBackgroundColor))/a\
            )\
            .accessibilityLabel("Recording sound profile picker")' Sources/SpeakApp/SettingsView.swift

sed -i.tmp '/Slider(/,/step: 0.1$/a\
              )\
              .accessibilityLabel("Recording sound volume")\
              .accessibilityValue("\\(Int(settings.recordingSoundVolume * 100)) percent")' Sources/SpeakApp/SettingsView.swift

sed -i.tmp 's/Button("Preview Start") {/Button("Preview Start") {\
              previewRecordingSound(.start)\
            }\
            .buttonStyle(.bordered)\
            .accessibilityLabel("Preview start recording sound")\
\
            Button("Preview Stop") {/g' Sources/SpeakApp/SettingsView.swift

sed -i.tmp '/Picker("Transcription Mode", selection: settingsBinding/,/speakTooltip("Pick the recording flow/a\
          .accessibilityLabel("Transcription mode picker")' Sources/SpeakApp/SettingsView.swift

sed -i.tmp '/Picker("Preferred Locale", selection: settingsBinding/,/speakTooltip("Choose from supported locales/a\
          .accessibilityLabel("Preferred locale picker")' Sources/SpeakApp/SettingsView.swift

rm -f Sources/SpeakApp/SettingsView.swift.tmp

echo "Accessibility labels added successfully!"
echo "Running git diff to show changes..."
git --no-pager diff --stat

