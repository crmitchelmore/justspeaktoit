#!/bin/bash
set -e

cd /Users/cm/work/justspeaktoit

echo "Adding accessibility labels to macOS views..."

# HUDView.swift - Add labels to interactive elements

# 1. Subheadline
sed -i '' '/if let sub = manager.snapshot.subheadline/,/\.foregroundStyle(\.secondary)/{
  /\.foregroundStyle(\.secondary)/a\
            .accessibilityLabel(sub)
}' Sources/SpeakApp/HUDView.swift

# 2. Retry hint
sed -i '' '/Press ⌘R to retry/,/padding(.top, 4)/{
  /padding(.top, 4)/a\
            .accessibilityHint("Press Command-R to retry the operation")
}' Sources/SpeakApp/HUDView.swift

# 3. Audio level meter
sed -i '' '/AudioLevelMeterView(level: manager.audioLevel/,/padding(.top, 2)/{
  /padding(.top, 2)/a\
          .accessibilityLabel("Audio level meter")\
          .accessibilityValue("\\(Int(manager.audioLevel * 100)) percent")
}' Sources/SpeakApp/HUDView.swift

# 4. Elapsed time
sed -i '' '/Text(elapsedText)/,/foregroundStyle(.secondary)/{
  /foregroundStyle(.secondary)/a\
          .accessibilityLabel("Elapsed time: \\(elapsedText)")
}' Sources/SpeakApp/HUDView.swift

# 5. Live transcript text
sed -i '' '/\.animation(.easeInOut(duration: 0.2), value: isFinal)/a\
        .accessibilityLabel(isFinal ? "Transcript: \\(text)" : "Partial transcript: \\(text)")
' Sources/SpeakApp/HUDView.swift

# 6. Confidence badge
sed -i '' '/Capsule()/,/\.fill(.quaternary)/{
  /\.fill(.quaternary)/a\
          )\
          .accessibilityLabel("Confidence: \\(Int(confidence * 100)) percent")
}' Sources/SpeakApp/HUDView.swift

# 7. Error indicator
sed -i '' '/exclamationmark.triangle.fill/,/shadow(color: phaseColor.opacity(0.45)/{
  /shadow(color: phaseColor.opacity(0.45)/a\
          .accessibilityLabel("Error indicator")
}' Sources/SpeakApp/HUDView.swift

# 8. Success indicator
sed -i '' '/checkmark.circle.fill/,/shadow(color: phaseColor.opacity(0.3)/{
  /shadow(color: phaseColor.opacity(0.3)/a\
        .accessibilityLabel("Success indicator")
}' Sources/SpeakApp/HUDView.swift

# 9. Recording indicator
sed -i '' '/Circle()/,/shadow(color: phaseColor.opacity(0.4)/{
  /shadow(color: phaseColor.opacity(0.4)/a\
          .accessibilityLabel("Recording status indicator")
}' Sources/SpeakApp/HUDView.swift

# MainView.swift - Add helper function and accessibility labels

# 1. Record button label
sed -i '' '/\.speakTooltip("Start or stop a recording/a\
      .accessibilityLabel(accessibilityLabelForRecordButton)
' Sources/SpeakApp/MainView.swift

# 2. Status item label
sed -i '' '/strokeBorder(.secondary.opacity(0.3)/a\
      )\
      .accessibilityLabel("Current mode: \\(environment.settings.transcriptionMode.displayName)")
' Sources/SpeakApp/MainView.swift

# 3. Add helper function
cat > /tmp/main_helper.txt << 'HELPER'
  
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
HELPER

sed -i '' '/^}$/,${
  /^}$/i\
'"$(cat /tmp/main_helper.txt)"'
  /^}/q
}' Sources/SpeakApp/MainView.swift

rm /tmp/main_helper.txt

# SettingsView.swift - Add labels to key pickers

# Theme picker
sed -i '' '/Picker("Theme", selection: settingsBinding/,/speakTooltip("Choose whether Speak follows macOS/{
  /speakTooltip("Choose whether Speak follows macOS/a\
          .accessibilityLabel("Appearance theme picker")
}' Sources/SpeakApp/SettingsView.swift

# Text output picker
sed -i '' '/Picker("Text Output", selection: settingsBinding/,/speakTooltip("Decide how Speak returns/{
  /speakTooltip("Decide how Speak returns/a\
          .accessibilityLabel("Text output method picker")
}' Sources/SpeakApp/SettingsView.swift

# Audio input picker
sed -i '' '/Picker("Input Device", selection: audioInputSelectionBinding/,/speakTooltip("Choose which microphone/{
  /speakTooltip("Choose which microphone/a\
          .accessibilityLabel("Audio input device picker")
}' Sources/SpeakApp/SettingsView.swift

# Transcription mode picker
sed -i '' '/Picker("Transcription Mode", selection: settingsBinding/,/speakTooltip("Pick the recording flow/{
  /speakTooltip("Pick the recording flow/a\
          .accessibilityLabel("Transcription mode picker")
}' Sources/SpeakApp/SettingsView.swift

# Locale picker
sed -i '' '/Picker("Preferred Locale", selection: settingsBinding/,/speakTooltip("Choose from supported locales/{
  /speakTooltip("Choose from supported locales/a\
          .accessibilityLabel("Preferred locale picker")
}' Sources/SpeakApp/SettingsView.swift

echo "✅ Accessibility labels added successfully!"
git --no-pager diff --stat
