"""Execute the production Swift policy/manifest expressions without app dependencies.

The harness substitutes only settings, entitlement and Tuist containers. The
conditions under test come from the source, so restoring the old conditions
fails these cases. Full app/StoreKit/UI qualification remains a separate gate.
"""
import json
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def block(source, marker):
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("xcrun"), "Apple Swift required")
class PaidAccessRecoveryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        manifest = (ROOT / "Project.swift").read_text()
        manager = (ROOT / "Sources/SpeakApp/PaidAccess/PaidAccessManager.swift").read_text()
        store = (ROOT / "Sources/SpeakiOS/Services/PaidAccessStore.swift").read_text()
        routing = (ROOT / "Sources/SpeakCore/PaidAccess/PaidAccessRouting.swift").read_text()
        view = (ROOT / "Sources/SpeakApp/Views/Settings/SettingsView+Transcription.swift").read_text()
        app_store_flags = manifest.split("let appStoreFlag =", 1)[1].split("let macEntitlementsPath", 1)[0]
        paid_flags = manifest.split("let paidAccessFlag =", 1)[1].split("var iosWidgetSettings", 1)[0]
        channel_flags = manifest.split("if isAppStoreBuild {", 1)[1].split("// The `.remote`", 1)[0]
        # The environment is the sole injected input to the real manifest logic.
        flags = ("let appStoreFlag =" + app_store_flags + "let paidAccessFlag =" + paid_flags
                 + "if isAppStoreBuild {" + channel_flags)
        flags = flags.replace("ProcessInfo.processInfo.environment", "environment")
        stream_condition = re.search(r"if ([^\n{]+) \{\s*remoteStreamingModelCard", view).group(1)
        batch_condition = re.search(r"if ([^\n{]+) \{\s*remoteBatchModelCard", view).group(1)
        notice_condition = re.search(r"if ([^\n{]+) \{\s*simpleModelChoicesNotice", view).group(1)
        swift = '''import Foundation
extension String { static func string(_ value: String) -> String { value } }
func configureManualSigning(for settings: inout [String: String], profileName: String) {}
func flags(_ environment: [String: String]) -> [String] {
    var macAppSettings: [String: String] = [:]
    let macAppStoreProfileName: String? = nil
''' + flags + '''
    return macAppSettings["SWIFT_ACTIVE_COMPILATION_CONDITIONS", default: "$(inherited)"]
        .split(separator: " ").map(String.init)
}
struct Entitlement { let active: Bool; func allowsPaidRouting() -> Bool { active } }
struct Settings { let simpleModelChoices: Bool; let paidAccessRoutingEnabled: Bool }
enum PaidAccessFeature { static var isEnabled = false; static var isAvailableOnIOS = false }
''' + block(routing, "public struct SimpleModelChoicesPolicy") + '''
struct MacPolicy {
    let settings: Settings; let entitlement: Entitlement
''' + block(manager, "var simpleModelChoicesPolicy:") + "\n" + block(manager, "var isPaidRoutingActive:") + '''
}
struct IOSPolicy {
    let simpleModelChoices: Bool; let paidRoutingEnabled: Bool; let entitlement: Entitlement
''' + block(store, "public var simpleModelChoicesPolicy:") + "\n" + block(store, "public var isPaidRoutingActive:") + '''
}
enum Mode { case streaming, batchRemote, localModel }
struct ViewSettings { let transcriptionMode: Mode }
var policies: [[String: Any]] = []
for build in [false, true] { for preferred in [false, true] {
    for entitled in [false, true] { for simple in [false, true] {
        PaidAccessFeature.isEnabled = build
        PaidAccessFeature.isAvailableOnIOS = build
        let entitlement = Entitlement(active: entitled)
        let mac = MacPolicy(settings: Settings(simpleModelChoices: simple,
            paidAccessRoutingEnabled: preferred), entitlement: entitlement)
        let ios = IOSPolicy(simpleModelChoices: simple, paidRoutingEnabled: preferred,
            entitlement: entitlement)
        policies.append(["expected": build && preferred && entitled && simple,
            "mac": mac.simpleModelChoicesPolicy.hidesModelSelection,
            "ios": ios.simpleModelChoicesPolicy.hidesModelSelection])
    }}
}}
var views: [[String: Any]] = []
for mode in [Mode.streaming, .batchRemote, .localModel] {
    for hidesModelSelection in [false, true] {
        let settings = ViewSettings(transcriptionMode: mode)
        let isRemoteStreamingTranscriptionSelected = mode == .streaming
        views.append(["streaming": (''' + stream_condition + '''),
            "expectedStreaming": mode == .streaming,
            "batch": (''' + batch_condition + '''),
            "expectedBatch": mode == .batchRemote && !hidesModelSelection,
            "notice": (''' + notice_condition + '''),
            "expectedNotice": mode == .batchRemote && hidesModelSelection])
    }
}
let inputs = [["", ""], ["0", "0"], ["1", "0"], ["0", "1"], ["1", "1"],
    ["true", "yes"], ["false", "false"], ["YES", "TRUE"]]
let manifestCases = inputs.map { pair in ["inputs": pair,
    "flags": flags(["TUIST_APP_STORE": pair[0], "TUIST_PAID_ACCESS": pair[1]])] }
let data = try JSONSerialization.data(withJSONObject: ["policies": policies,
    "views": views, "manifest": manifestCases], options: [.sortedKeys])
print(String(data: data, encoding: .utf8)!)
'''
        with tempfile.TemporaryDirectory(prefix="paid-source-contract-") as temp:
            source = Path(temp) / "main.swift"
            source.write_text(swift)
            result = subprocess.run(
                ["xcrun", "swift", "-module-cache-path", str(Path(temp) / "cache"), str(source)],
                check=True, text=True, capture_output=True, timeout=60,
            )
            cls.result = json.loads(result.stdout)

    def test_entitlement_alone_never_hides_manual_model_choices(self):
        for case in self.result["policies"]:
            with self.subTest(case=case):
                self.assertEqual(case["mac"], case["expected"])
                self.assertEqual(case["ios"], case["expected"])

    def test_unwired_streaming_and_local_selection_stay_available(self):
        for case in self.result["views"]:
            with self.subTest(case=case):
                self.assertEqual(case["streaming"], case["expectedStreaming"])
                self.assertEqual(case["batch"], case["expectedBatch"])
                self.assertEqual(case["notice"], case["expectedNotice"])

    def test_paid_and_app_store_flags_compose_without_enabling_default_builds(self):
        for case in self.result["manifest"]:
            with self.subTest(case=case):
                app_store, paid = [x.lower() in ("1", "true", "yes") for x in case["inputs"]]
                expected = ["$(inherited)"]
                if paid:
                    expected.append("PAID_ACCESS")
                if app_store:
                    expected.append("APP_STORE")
                self.assertEqual(case["flags"], expected)


if __name__ == "__main__":
    unittest.main()
