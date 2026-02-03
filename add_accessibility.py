#!/usr/bin/env python3
"""
Script to add accessibility labels to macOS SwiftUI views
"""

import re

def add_accessibility_to_hudview():
    """Add accessibility labels to HUDView.swift"""
    
    with open('/Users/cm/work/justspeaktoit/Sources/SpeakApp/HUDView.swift', 'r') as f:
        content = f.read()
    
    # Pattern 1: Add accessibility label to headline text
    content = re.sub(
        r'(Text\(manager\.snapshot\.headline\)\s+\.font\(\.headline\)\s+\.foregroundStyle\(headlineColor\))',
        r'\1\n          .accessibilityLabel("Status: \\(manager.snapshot.headline)")',
        content
    )
    
    # Pattern 2: Add accessibility label to subheadline
    content = re.sub(
        r'(Text\(sub\)\s+\.font\(\.subheadline\)\s+\.foregroundStyle\(\.secondary\))',
        r'\1\n            .accessibilityLabel(sub)',
        content
    )
    
    # Pattern 3: Add accessibility hint to retry text
    content = re.sub(
        r'(Text\("Press ⌘R to retry"\)\s+\.font\(\.caption\)\s+\.foregroundStyle\(\.secondary\)\s+\.padding\(\.top, 4\))',
        r'\1\n            .accessibilityHint("Press Command-R to retry the operation")',
        content
    )
    
    # Pattern 4: Add accessibility to audio level meter
    content = re.sub(
        r'(AudioLevelMeterView\(level: manager\.audioLevel, width: 100, height: 4\)\s+\.padding\(\.top, 2\))',
        r'\1\n          .accessibilityLabel("Audio level meter")\n          .accessibilityValue("\\(Int(manager.audioLevel * 100)) percent")',
        content
    )
    
    # Pattern 5: Add accessibility to elapsed time
    content = re.sub(
        r'(Text\(elapsedText\)\s+\.font\(\.caption\.monospacedDigit\(\)\)\s+\.foregroundStyle\(\.secondary\))',
        r'\1\n          .accessibilityLabel("Elapsed time: \\(elapsedText)")',
        content
    )
    
    # Pattern 6: Add accessibility to live transcript text
    content = re.sub(
        r'(\.animation\(\.easeInOut\(duration: 0\.2\), value: isFinal\))',
        r'\1\n        .accessibilityLabel(isFinal ? "Transcript: \\(text)" : "Partial transcript: \\(text)")',
        content,
        count=1
    )
    
    # Pattern 7: Add accessibility to confidence badge  
    content = re.sub(
        r'(Capsule\(\)\s+\.fill\(\.quaternary\)\s+\))',
        r'\1\n          .accessibilityLabel("Confidence: \\(Int(confidence * 100)) percent")',
        content,
        count=1
    )
    
    # Pattern 8: Add accessibility to error indicator
    content = re.sub(
        r'(Image\(systemName: "exclamationmark\.triangle\.fill"\)\s+\.font\(\.system\(size: 32, weight: \.bold\)\)\s+\.foregroundStyle\(phaseColor\.gradient\)\s+\.scaleEffect\(scale\)\s+\.shadow\(color: phaseColor\.opacity\(0\.45\), radius: 10, x: 0, y: 6\))',
        r'\1\n          .accessibilityLabel("Error indicator")',
        content
    )
    
    # Pattern 9: Add accessibility to success indicator
    content = re.sub(
        r'(Image\(systemName: "checkmark\.circle\.fill"\)\s+\.font\(\.system\(size: 28, weight: \.semibold\)\)\s+\.foregroundStyle\(phaseColor\)\s+\.shadow\(color: phaseColor\.opacity\(0\.3\), radius: 6, x: 0, y: 4\))',
        r'\1\n        .accessibilityLabel("Success indicator")',
        content
    )
    
    # Pattern 10: Add accessibility to recording status indicator
    content = re.sub(
        r'(Circle\(\)\s+\.fill\(phaseColor\.gradient\)\s+\.frame\(width: 18, height: 18\)\s+\.scaleEffect\(scale\)\s+\.shadow\(color: phaseColor\.opacity\(0\.4\), radius: 6, x: 0, y: 4\))',
        r'\1\n          .accessibilityLabel("Recording status indicator")',
        content
    )
    
    with open('/Users/cm/work/justspeaktoit/Sources/SpeakApp/HUDView.swift', 'w') as f:
        f.write(content)
    
    print("✅ Added accessibility labels to HUDView.swift")


def add_accessibility_to_mainview():
    """Add accessibility labels to MainView.swift"""
    
    with open('/Users/cm/work/justspeaktoit/Sources/SpeakApp/MainView.swift', 'r') as f:
        content = f.read()
    
    # Add accessibility label to record button
    content = re.sub(
        r'(\.speakTooltip\("Start or stop a recording from anywhere in Speak\. We\'ll let you know when we\'re listening\."\))',
        r'\1\n      .accessibilityLabel(accessibilityLabelForRecordButton)',
        content
    )
    
    # Add accessibility label to status item
    content = re.sub(
        r'(Capsule\(\)\s+\.strokeBorder\(\.secondary\.opacity\(0\.3\), lineWidth: 0\.5\)\s+\))',
        r'\1\n      .accessibilityLabel("Current mode: \\(environment.settings.transcriptionMode.displayName)")',
        content
    )
    
    # Add helper function before closing brace
    helper_func = '''
  
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

// @Implement This is the main app container and handles all top-level system events'''
    
    content = re.sub(
        r'\}\s*\n\s*// @Implement This is the main app container and handles all top-level system events',
        helper_func,
        content
    )
    
    with open('/Users/cm/work/justspeaktoit/Sources/SpeakApp/MainView.swift', 'w') as f:
        f.write(content)
    
    print("✅ Added accessibility labels to MainView.swift")


def add_accessibility_to_settingsview():
    """Add key accessibility labels to SettingsView.swift"""
    
    with open('/Users/cm/work/justspeaktoit/Sources/SpeakApp/SettingsView.swift', 'r') as f:
        lines = f.readlines()
    
    # Add accessibility labels at specific line numbers (based on earlier inspection)
    # This is a simplified version focusing on key interactive elements
    
    modifications = [
        (254, '          .accessibilityLabel("Appearance theme picker")'),
        (273, '          .accessibilityLabel("Text output method picker")'),
        (311, '            .accessibilityLabel("App visibility picker")'),
        (353, '          .accessibilityLabel("Audio input device picker")'),
        (375, '            .accessibilityLabel("Refresh audio devices")'),
        (405, '            .accessibilityLabel("Recording sound profile picker")'),
        (426, '              .accessibilityLabel("Recording sound volume")'),
        (427, '              .accessibilityValue("\\(Int(settings.recordingSoundVolume * 100)) percent")'),
        (438, '            .accessibilityLabel("Preview start recording sound")'),
        (442, '            .accessibilityLabel("Preview stop recording sound")'),
        (491, '                .accessibilityLabel("Copy pairing code")'),
        (502, '              .accessibilityLabel("Regenerate pairing code")'),
        (503, '              .accessibilityHint("Generates a new code and disconnects all paired devices")'),
        (655, '          .accessibilityLabel("Transcription mode picker")'),
        (670, '          .accessibilityLabel("Preferred locale picker")'),
        (959, '            .accessibilityLabel("Post-processing output language picker")'),
        (1142, '            .accessibilityLabel("Default TTS voice picker")'),
        (1160, '            .accessibilityLabel("TTS quality picker")'),
        (1178, '              .accessibilityLabel("TTS playback speed")'),
        (1179, '              .accessibilityValue(String(format: "%.2fx", settings.ttsSpeed))'),
        (1190, '              .accessibilityLabel("TTS voice pitch")'),
        (1191, '              .accessibilityValue("\\(settings.ttsPitch > 0 ? "plus " : "")\\(Int(settings.ttsPitch)) semitones")'),
        (1209, '            .accessibilityLabel("TTS output file format picker")'),
        (1919, '          .accessibilityLabel("Hotkey activation style picker")'),
        (1937, '            .accessibilityLabel("Hold threshold")'),
        (1938, '            .accessibilityValue(String(format: "%.2f seconds", settings.holdThreshold))'),
        (1954, '            .accessibilityLabel("Double tap window")'),
        (1955, '            .accessibilityValue(String(format: "%.2f seconds", settings.doubleTapWindow))'),
        (1967, '              .accessibilityLabel("Request \\(permission.displayName) permission")'),
        (1975, '          .accessibilityLabel("Refresh permission statuses")'),
    ]
    
    # Sort in reverse order to avoid index shifting issues
    for line_num, label in sorted(modifications, reverse=True):
        if line_num <= len(lines):
            lines.insert(line_num, label + '\n')
    
    with open('/Users/cm/work/justspeaktoit/Sources/SpeakApp/SettingsView.swift', 'w') as f:
        f.writelines(lines)
    
    print("✅ Added accessibility labels to SettingsView.swift")


if __name__ == '__main__':
    print("Adding accessibility labels to macOS views...\n")
    add_accessibility_to_hudview()
    add_accessibility_to_mainview()
    add_accessibility_to_settingsview()
    print("\n✅ All accessibility labels added successfully!")
