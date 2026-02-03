#!/usr/bin/env python3
import re

# HUDView.swift
with open('Sources/SpeakApp/HUDView.swift', 'r') as f:
    content = f.read()

replacements = [
    (r'(\.foregroundStyle\(headlineColor\))', r'\1\n          .accessibilityLabel("Status: \\(manager.snapshot.headline)")'),
    (r'(Text\(sub\)\s+\.font\(\.subheadline\)\s+\.foregroundStyle\(\.secondary\))', r'\1\n            .accessibilityLabel(sub)'),
    (r'(\.padding\(\.top, 4\))(\s+\})', r'\1\n            .accessibilityHint("Press Command-R to retry the operation")\2'),
    (r'(AudioLevelMeterView\(level: manager\.audioLevel, width: 100, height: 4\)\s+\.padding\(\.top, 2\))', r'\1\n          .accessibilityLabel("Audio level meter")\n          .accessibilityValue("\\(Int(manager.audioLevel * 100)) percent")'),
    (r'(Text\(elapsedText\)\s+\.font\(\.caption\.monospacedDigit\(\)\)\s+\.foregroundStyle\(\.secondary\))', r'\1\n          .accessibilityLabel("Elapsed time: \\(elapsedText)")'),
    (r'(\.animation\(\.easeInOut\(duration: 0\.2\), value: isFinal\))', r'\1\n        .accessibilityLabel(isFinal ? "Transcript: \\(text)" : "Partial transcript: \\(text)")'),
    (r'(Capsule\(\)\s+\.fill\(\.quaternary\)\s+\))', r'\1\n          .accessibilityLabel("Confidence: \\(Int(confidence * 100)) percent")'),
    (r'(Image\(systemName: "exclamationmark\.triangle\.fill"\)\s+\.font\(\.system\(size: 32, weight: \.bold\)\)\s+\.foregroundStyle\(phaseColor\.gradient\)\s+\.scaleEffect\(scale\)\s+\.shadow\(color: phaseColor\.opacity\(0\.45\), radius: 10, x: 0, y: 6\))', r'\1\n          .accessibilityLabel("Error indicator")'),
    (r'(Image\(systemName: "checkmark\.circle\.fill"\)\s+\.font\(\.system\(size: 28, weight: \.semibold\)\)\s+\.foregroundStyle\(phaseColor\)\s+\.shadow\(color: phaseColor\.opacity\(0\.3\), radius: 6, x: 0, y: 4\))', r'\1\n        .accessibilityLabel("Success indicator")'),
    (r'(Circle\(\)\s+\.fill\(phaseColor\.gradient\)\s+\.frame\(width: 18, height: 18\)\s+\.scaleEffect\(scale\)\s+\.shadow\(color: phaseColor\.opacity\(0\.4\), radius: 6, x: 0, y: 4\))', r'\1\n          .accessibilityLabel("Recording status indicator")'),
]

for pattern, replacement in replacements:
    content = re.sub(pattern, replacement, content)

with open('Sources/SpeakApp/HUDView.swift', 'w') as f:
    f.write(content)

print("✅ HUDView.swift updated")

# MainView.swift
with open('Sources/SpeakApp/MainView.swift', 'r') as f:
    content = f.read()

content = re.sub(
    r'(\.speakTooltip\("Start or stop a recording from anywhere in Speak\. We\'ll let you know when we\'re listening\."\))',
    r'\1\n      .accessibilityLabel(accessibilityLabelForRecordButton)',
    content
)

content = re.sub(
    r'(\.strokeBorder\(\.secondary\.opacity\(0\.3\), lineWidth: 0\.5\)\s+\))',
    r'\1\n      .accessibilityLabel("Current mode: \\(environment.settings.transcriptionMode.displayName)")',
    content
)

helper = '''
  
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
}

// @Implement This is the main app container'''

content = re.sub(r'\}\s*\n\s*// @Implement This is the main app container', helper, content)

with open('Sources/SpeakApp/MainView.swift', 'w') as f:
    f.write(content)

print("✅ MainView.swift updated")

# SettingsView.swift
with open('Sources/SpeakApp/SettingsView.swift', 'r') as f:
    lines = f.readlines()

# Add accessibility labels at key locations
inserts = [
    (254, '          .accessibilityLabel("Appearance theme picker")\n'),
    (274, '          .accessibilityLabel("Text output method picker")\n'),
    (353, '          .accessibilityLabel("Audio input device picker")\n'),
    (655, '          .accessibilityLabel("Transcription mode picker")\n'),
    (670, '          .accessibilityLabel("Preferred locale picker")\n'),
]

for line_no, text in sorted(inserts, reverse=True):
    if line_no < len(lines):
        lines.insert(line_no, text)

with open('Sources/SpeakApp/SettingsView.swift', 'w') as f:
    f.writelines(lines)

print("✅ SettingsView.swift updated")
print("\n✅ All files updated with accessibility labels!")
