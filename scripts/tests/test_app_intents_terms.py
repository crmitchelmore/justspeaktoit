import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "ios/check-app-intents-terms.py"
spec = importlib.util.spec_from_file_location("check_app_intents_terms", SCRIPT)
terms = importlib.util.module_from_spec(spec)
spec.loader.exec_module(terms)


class SourceScanTests(unittest.TestCase):
    def test_multilineDescriptionNamingDevice_isFound(self):
        source = '''
        public static var description = IntentDescription(
            """
            Stops the current recording. Works on a locked \\
            iPhone but returns no text.
            """,
            categoryName: "Recording"
        )
        '''
        self.assertIn("Stops the current recording. Works on a locked iPhone but returns no text.",
                      [" ".join(text.split()) for text in terms.metadata_strings(source)])

    def test_concatenatedParameterDescription_isJoined(self):
        source = '@Parameter(title: "Model", description: "Runs on " + "Siri.")\nvar model: String?'
        self.assertIn("Runs on Siri.", terms.metadata_strings(source))

    def test_metadataContexts_areAllRead(self):
        source = '''
        static let title: LocalizedStringResource = "Title iPad"
        static var typeDisplayRepresentation: TypeDisplayRepresentation { "Entity iPod" }
        static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [.a: "Case CarPlay"]
        AppShortcut(intent: A(), phrases: ["Ask Siri with \\(.applicationName)"], shortTitle: "Short")
        static var parameterSummary: some ParameterSummary { Summary("Send to \\(\\.$target) HomePod") }
        '''
        found = " ".join(terms.metadata_strings(source))
        for text in ("Title iPad", "Entity iPod", "Case CarPlay", "Ask Siri with", "HomePod"):
            self.assertIn(text, found)

    def test_runtimeStringsCommentsAndSymbols_areIgnored(self):
        source = '''
        // Works from Siri and the Action Button.
        static var title: LocalizedStringResource = "Stop Recording"
        func perform() { throw Failure("Unlock this iPhone and try again.") }
        let image = Image(systemName: "lock.iphone")
        AppShortcut(intent: A(), phrases: ["Stop with \\(.applicationName)"], systemImageName: "iphone")
        var description: String { "iPhone" }
        '''
        found = terms.metadata_strings(source)
        self.assertEqual([text for text in found if terms.banned_terms_in(text)], [])

    def test_bannedTerms_matchCaseInsensitivelyAcrossWhitespace(self):
        self.assertEqual(terms.banned_terms_in("Use SIRI on an Apple\n   Watch"), ["siri", "apple watch"])
        self.assertEqual(terms.banned_terms_in("Works on a locked device or the watch."), [])


class CommandTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def run_check(self, *args):
        return subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True, check=False)

    def write_source(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        subprocess.run(["git", "init", "-q"], cwd=self.root, check=True)
        subprocess.run(["git", "add", name], cwd=self.root, check=True)

    def test_sourceScan_failsOnlyForAppIntentsTargets(self):
        intent = 'import AppIntents\nstruct A: AppIntent { static var title: LocalizedStringResource = "Ask Siri" }\n'
        self.write_source("Sources/A.swift", intent)
        self.write_source("Sources/B.swift", 'import SwiftUI\nstatic var title = "iPhone"\n')
        self.write_source("Tests/C.swift", intent)
        result = self.run_check("--root", str(self.root))
        self.assertEqual(result.returncode, 1)
        self.assertIn('Sources/A.swift: "siri"', result.stderr)
        self.assertNotIn("B.swift", result.stderr)
        self.assertNotIn("Tests/C.swift", result.stderr)

    def test_compiledMetadata_flagsEveryLocalizedString(self):
        app = self.root / "JustSpeakToIt.app/Metadata.appintents"
        app.mkdir(parents=True)
        metadata = {
            "actions": {"Stop": {
                "title": {"key": "Stop Recording", "alternatives": []},
                "descriptionMetadata": {"descriptionText": {"key": "Needs an unlocked iPhone.", "alternatives": []}},
                "parameters": [{"title": {"key": "Destination", "alternatives": ["Siri destination"]}}],
            }},
            "autoShortcuts": [{"phraseTemplates": [{"key": "Stop with ${applicationName}", "alternatives": []}]}],
        }
        (app / "extract.actionsdata").write_text(json.dumps(metadata))
        result = self.run_check("--metadata", str(self.root))
        self.assertEqual(result.returncode, 1)
        self.assertIn('descriptionText: "iphone"', result.stderr)
        self.assertIn('alternatives[0]: "siri"', result.stderr)
        self.assertNotIn("Stop Recording", result.stderr)

    def test_compiledMetadata_missing_fails(self):
        result = self.run_check("--metadata", str(self.root))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No Metadata.appintents", result.stderr)


class RepositoryTests(unittest.TestCase):
    def test_repositoryAppIntentsMetadata_namesNoSiriOrDevice(self):
        self.assertEqual(terms.scan_sources(terms.ROOT), [])


if __name__ == "__main__":
    unittest.main()
