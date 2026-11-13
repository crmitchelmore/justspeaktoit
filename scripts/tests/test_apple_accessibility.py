import importlib.util
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "apple_accessibility", ROOT / "scripts/accessibility/check-apple-accessibility.py"
)
CHECK = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = CHECK
SPEC.loader.exec_module(CHECK)


def rules(body: str) -> list[str]:
    source = "import SwiftUI\nstruct V: View { var body: some View {\n" + body + "\n}}\n"
    return [finding.rule for finding in CHECK.scan_source("V.swift", source)]


class AppleAccessibilityCheckTests(unittest.TestCase):
    def test_repository_has_no_findings(self):
        findings = CHECK.scan()
        self.assertEqual([], [str(f) for f in findings])

    def test_icon_only_button_needs_label(self):
        self.assertEqual(["icon-only-control"], rules('Button { go() } label: { Image(systemName: "xmark") }'))
        self.assertEqual(["icon-only-control"], rules('Button(action: go) {\n  Image(systemName: "gear")\n}\n.buttonStyle(.plain)'))
        self.assertEqual(["icon-only-control"], rules('Menu { Button("a") {} } label: { Image(systemName: "ellipsis") }'))
        self.assertEqual(["icon-only-control"], rules('Link(destination: url) { Image(systemName: "safari") }'))

    def test_labelled_icon_only_button_needs_identifier(self):
        self.assertEqual(
            ["icon-only-missing-id"],
            rules('Button { go() } label: { Image(systemName: "xmark") }\n.accessibilityLabel("Close")'),
        )
        self.assertEqual(
            [],
            rules(
                'Button { go() } label: { Image(systemName: "xmark") }\n'
                '.accessibilityLabel("Close")\n.accessibilityIdentifier("close")'
            ),
        )

    def test_textual_controls_pass(self):
        self.assertEqual([], rules('Button("Save") { go() }'))
        self.assertEqual([], rules('Button(action: go) { Label("Gear", systemImage: "gear") }'))
        self.assertEqual([], rules('Button { go() } label: { HStack { Image(systemName: "a"); Text("Add") } }'))
        self.assertEqual([], rules('Button("Refresh", systemImage: "arrow.clockwise") { go() }'))

    def test_empty_titled_controls_need_label(self):
        self.assertEqual(["empty-control-label"], rules('Toggle("", isOn: $on)\n.labelsHidden()'))
        self.assertEqual([], rules('Toggle("", isOn: $on)\n.labelsHidden()\n.accessibilityLabel("Enabled")'))

    def test_untitled_slider_and_text_editor_need_label(self):
        self.assertEqual(["untitled-control"], rules('Slider(value: $speed, in: 0...2, step: 0.1)\n.help("Speed")'))
        self.assertEqual(["untitled-control"], rules('TextEditor(text: $draft)\n.font(.body)'))
        self.assertEqual([], rules('Slider(value: $speed, in: 0...2)\n.accessibilityLabel("Speed")'))
        self.assertEqual([], rules('TextEditor(text: $draft)\n.accessibilityLabel("Draft")\n.font(.body)'))
        self.assertEqual([], rules('Slider(value: $speed, in: 0...2) {\n  Text("Speed")\n}'))

    def test_ios_segmented_picker_needs_label_and_identifier(self):
        def ios_rules(body, path="Sources/SpeakiOS/V.swift"):
            source = "import SwiftUI\nstruct V: View { var body: some View {\n" + body + "\n}}\n"
            return [finding.rule for finding in CHECK.scan_source(path, source)]

        picker = 'Picker("Mode", selection: $mode) {\n  Text("A").tag(0)\n}\n.pickerStyle(.segmented)'
        self.assertEqual(["unlabelled-segmented-picker"], ios_rules(picker))
        self.assertEqual(["unlabelled-segmented-picker"], ios_rules(picker + '\n.accessibilityIdentifier("mode")'))
        self.assertEqual([], ios_rules(picker + '\n.accessibilityLabel("Mode")\n.accessibilityIdentifier("mode")'))
        self.assertEqual([], ios_rules(picker.replace("segmented", "navigationLink")))
        self.assertEqual([], ios_rules(picker, path="Sources/SpeakApp/V.swift"))

    def test_tap_gesture_needs_trait_or_action(self):
        self.assertEqual(["tap-without-trait"], rules('Text("x")\n.onTapGesture { go() }'))
        self.assertEqual([], rules('Text("x")\n.onTapGesture { go() }\n.accessibilityAddTraits(.isButton)'))

    def test_ignore_comment_suppresses(self):
        self.assertEqual([], rules('Text("x")\n// a11y-ignore: duplicate of a labelled button\n.onTapGesture { go() }'))

    def test_comments_and_strings_do_not_trigger(self):
        self.assertEqual([], rules('// Button { } label: { Image(systemName: "x") }\nText("Button { Image(systemName: x) }")'))


if __name__ == "__main__":
    unittest.main()
