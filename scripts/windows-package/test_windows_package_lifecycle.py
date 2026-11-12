#!/usr/bin/env python3
"""Start entry projection, app-data ownership and the package lifecycle support helpers."""
import json
import pathlib
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile

HERE = pathlib.Path(__file__).resolve().parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(HERE))
import lifecycle_support  # noqa: E402


class StartEntryMockTests(unittest.TestCase):
    def test_native_family_entry_projection_with_mock_startapps(self):
        pwsh = shutil.which("pwsh")
        if pwsh is None:
            self.skipTest("PowerShell 7 is unavailable; no tools are downloaded")
        script = r"""
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($args[0], [ref] $tokens, [ref] $errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($name in @('Get-StartMenuEntry', 'Wait-StartMenuEntry')) {
    $function = @($ast.FindAll({ param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true))
    if ($function.Count -ne 1) { throw "Expected one $name function" }
    . ([scriptblock]::Create($function[0].Extent.Text))
}
$base = @{ packageFamilyName = 'developer_family'; displayName = 'Developer GUI' }
$aumid = 'developer_family!JustSpeakToIt'
$script:waiting = $false
function Get-FakeStartItems {
    if ($script:waiting) {
        $index = [Math]::Min($script:polls, $script:frames.Count - 1)
        $script:items = $script:frames[$index].items
        $script:polls++
    }
    $script:items
}
function Get-StartApps { Get-FakeStartItems }
function Get-Command {
    param($Name, $ErrorAction)
    if (-not $script:useShell) { [pscustomobject]@{ Name = 'Get-StartApps' } }
}
function New-Object {
    param($ComObject)
    if ($ComObject -ne 'Shell.Application') { throw 'Unexpected COM request' }
    $script:folder = [pscustomobject]@{}
    $script:folder | Add-Member ScriptMethod Items {
        Get-FakeStartItems | ForEach-Object { [pscustomobject]@{ Path = $_.AppID; Name = $_.Name } }
    }
    $shell = [pscustomobject]@{}
    $shell | Add-Member ScriptMethod NameSpace {
        param($Path)
        if ($Path -ne 'shell:AppsFolder') { throw 'Unexpected shell namespace' }
        $script:folder
    }
    $shell
}
$gui = [pscustomobject]@{ AppID = $aumid; Name = 'Developer GUI' }
$cli = [pscustomobject]@{ AppID = 'developer_family!JustSpeakToItCLI'; Name = 'Unexpected CLI' }
$other = [pscustomobject]@{ AppID = 'other_family!Other'; Name = 'Other app' }
$near = [pscustomobject]@{ AppID = 'developer_family_extra!Other'; Name = 'Similar family' }
foreach ($script:useShell in @($false, $true)) {
foreach ($case in @(
    @{ items = @(); count = 0; present = $false },
    @{ items = @($other); count = 0; present = $false },
    @{ items = @($gui, $other); count = 1; present = $true },
    @{ items = @($gui, $cli); count = 2; present = $true },
    @{ items = @($cli); count = 1; present = $false },
    @{ items = @($gui, $gui); count = 2; present = $true },
    @{ items = @($near); count = 0; present = $false }
)) {
    $script:items = $case.items
    $entry = Get-StartMenuEntry
    if ($entry.entries.Count -ne $case.count -or $entry.present -ne $case.present) {
        throw 'Incorrect family entry projection'
    }
}
}
Write-Output 'PASS fourteen mock-only Start entry projections (StartApps and shell fallback)'
function Get-Date { ([datetime]'2026-01-01T00:00:00').AddSeconds($script:elapsed) }
function Start-Sleep {
    param([int] $Seconds)
    if ($Seconds -ne 1) { throw 'The existing polling interval must remain one second' }
    $script:elapsed += $Seconds
}
$wrongName = [pscustomobject]@{ AppID = $aumid; Name = 'Unreviewed name' }
$cases = @(
    @{ present = $true; frames = @(@{ items = @($gui, $cli) }, @{ items = @($gui) })
       count = 1; gui = $true; polls = 2; elapsed = 1; ids = $aumid },
    @{ present = $false; frames = @(@{ items = @($cli) }, @{ items = @() })
       count = 0; gui = $false; polls = 2; elapsed = 1; ids = '' },
    @{ present = $true; frames = @(@{ items = @($wrongName) }, @{ items = @($gui) })
       count = 1; gui = $true; polls = 2; elapsed = 1; ids = $aumid },
    @{ present = $true; frames = @(@{ items = @($cli) }, @{ items = @($gui) })
       count = 1; gui = $true; polls = 2; elapsed = 1; ids = $aumid },
    @{ present = $true; frames = @(@{ items = @($gui, $cli) })
       count = 2; gui = $true; polls = 3; elapsed = 3; ids = "$aumid,developer_family!JustSpeakToItCLI" },
    @{ present = $true; frames = @(@{ items = @($cli) })
       count = 1; gui = $false; polls = 3; elapsed = 3; ids = 'developer_family!JustSpeakToItCLI' },
    @{ present = $false; frames = @(@{ items = @($gui, $cli) })
       count = 2; gui = $true; polls = 3; elapsed = 3; ids = "$aumid,developer_family!JustSpeakToItCLI" },
    @{ present = $false; frames = @(@{ items = @($cli) })
       count = 1; gui = $false; polls = 3; elapsed = 3; ids = 'developer_family!JustSpeakToItCLI' }
)
$script:waiting = $true
foreach ($script:useShell in @($false, $true)) {
    foreach ($case in $cases) {
        $script:frames = $case.frames; $script:polls = 0; $script:elapsed = 0
        $entry = Wait-StartMenuEntry -Present $case.present -Seconds 3
        $ids = ($entry.entries | ForEach-Object { $_.id }) -join ','
        if ($entry.entries.Count -ne $case.count -or $entry.present -ne $case.gui -or
            $script:polls -ne $case.polls -or $script:elapsed -ne $case.elapsed -or $ids -cne $case.ids) {
            throw "Incorrect bounded family convergence or final evidence: $($case.ids)"
        }
    }
}
Write-Output 'PASS sixteen deterministic mock-only family waits (no real sleeps or native queries)'
"""
        with tempfile.TemporaryDirectory() as scratch:
            fixture = pathlib.Path(scratch) / "start-entry-mock.ps1"
            fixture.write_text(script, encoding="utf-8")
            result = subprocess.run([pwsh, "-NoProfile", "-NonInteractive", "-File", str(fixture),
                                     str(HERE / "LifecycleInstallation.ps1")],
                                    capture_output=True, text=True, encoding="utf-8", timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS fourteen mock-only", result.stdout)
        self.assertIn("PASS sixteen deterministic mock-only", result.stdout)


class AppDataOwnershipTests(unittest.TestCase):
    def test_normal_startup_prepares_private_root_before_any_controller_io(self):
        source = (HERE.parents[1] / "Sources/SpeakWindows/SpeakWindowsMain.swift").read_text(encoding="utf-8")
        main = source[source.index("@main"):]
        prepare = main.index("try WindowsHostPlatform.preparePrivateDirectory(directory)")
        self.assertLess(main.index('appendingPathComponent("JustSpeakToIt")'), prepare)
        self.assertLess(prepare, main.index("DesktopHostOnboarding.adoptExistingInstall"))
        self.assertLess(prepare, main.index("WindowsAppController(directory: directory)"))

    def test_newly_copied_fixtures_use_current_user_not_elevated_default_group_owner(self):
        for name in ("test-windows-package-lifecycle.ps1", "test-windows-package-admission.ps1"):
            with self.subTest(script=name):
                source = (HERE / name).read_text(encoding="utf-8")
                copied = source.index("Copy-Item -LiteralPath $staging -Destination $dataDirectory -Recurse")
                fixture = source[copied:source.index("$expectations = Read-JstiJson", copied)]
                self.assertIn("$fixtureAccess = Get-Acl -LiteralPath $dataDirectory", fixture)
                self.assertIn("$fixtureAccess.SetOwner([Security.Principal.WindowsIdentity]::GetCurrent().User)", fixture)
                self.assertIn("Set-Acl -LiteralPath $dataDirectory -AclObject $fixtureAccess", fixture)


class LifecycleSupportTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.scratch.name)
        self.data = self.root / "JustSpeakToIt"
        self.expectations = lifecycle_support.write_fixture(self.data, self.root / "expectations.json")

    def tearDown(self):
        self.scratch.cleanup()

    def recover_like_the_app(self):
        # DesktopRecordingStore.recoverInterruptedRecordings and
        # PCMRecordingFile.recoverInterruptedFile, reproduced for the test.
        recovery = self.expectations["recovery"]
        record_path = self.data / recovery["record"]
        record = json.loads(record_path.read_text(encoding="utf-8"))
        record["failure"] = recovery["failure"]
        record["createdAt"] = int(record["createdAt"])
        record_path.write_text(json.dumps(record, indent=2, sort_keys=True), encoding="utf-8")
        audio_path = self.data / recovery["audio"]
        audio = bytearray(audio_path.read_bytes())
        payload = len(audio) - 44
        struct.pack_into("<I", audio, 4, payload + 36)
        struct.pack_into("<I", audio, 40, payload)
        audio_path.write_bytes(bytes(audio))
        (self.data / "onboarding.json").write_text('{"hasCompletedOnboarding":true}', encoding="utf-8")

    def test_fixture_uses_the_apps_formats(self):
        completed = json.loads((self.data / ("History/%s.json" % lifecycle_support.COMPLETED_ID)).read_text(encoding="utf-8"))
        self.assertEqual(completed["result"]["text"], lifecycle_support.TRANSCRIPT)
        self.assertEqual(completed["id"], lifecycle_support.COMPLETED_ID)
        self.assertEqual(set(completed["result"]), {"duration", "modelIdentifier", "segments", "text"})
        interrupted = json.loads((self.data / ("History/%s.json" % lifecycle_support.INTERRUPTED_ID)).read_text(encoding="utf-8"))
        self.assertNotIn("result", interrupted)
        self.assertNotIn("failure", interrupted)
        self.assertGreater(completed["createdAt"], interrupted["createdAt"], "completed record is listed first")
        header = (self.data / ("History/%s.wav" % lifecycle_support.INTERRUPTED_ID)).read_bytes()[:44]
        expected = (b"RIFF" + struct.pack("<I", 36) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, 16000, 32000, 2, 16)
                    + b"data" + struct.pack("<I", 0))
        self.assertEqual(header, expected)
        audio = (self.data / ("History/%s.wav" % lifecycle_support.COMPLETED_ID)).read_bytes()
        self.assertEqual(audio[:44], lifecycle_support.wav_header(len(audio) - 44))
        self.assertTrue(any(audio[44:]), "fixture audio is not silent")
        self.assertEqual(json.loads((self.data / "settings.json").read_text(encoding="utf-8")), {"model": lifecycle_support.MODEL})
        with self.assertRaises(SystemExit):
            lifecycle_support.write_fixture(self.data, self.root / "again.json")

    def test_seeded_and_recovered_states_are_checked(self):
        self.assertEqual(lifecycle_support.check_data(self.data, self.expectations, "seeded")["failures"], [])
        self.assertTrue(lifecycle_support.check_data(self.data, self.expectations, "recovered")["failures"])
        self.recover_like_the_app()
        (self.data / "OpenRouterAudioCatalog.json").write_text("{}", encoding="utf-8")
        report = lifecycle_support.check_data(self.data, self.expectations, "recovered")
        self.assertEqual(report["failures"], [])
        self.assertEqual(report["appCreatedFiles"], ["OpenRouterAudioCatalog.json", "onboarding.json"])
        self.assertTrue(lifecycle_support.check_data(self.data, self.expectations, "seeded")["failures"])

    def test_legacy_onboarding_completion_is_required_and_validated(self):
        self.recover_like_the_app()
        state = self.data / "onboarding.json"
        for invalid in (None, "not json", "[]", '{"hasCompletedOnboarding":false}',
                        '{"hasCompletedOnboarding":1}', '{"hasCompletedOnboarding":true,"unknown":true}'):
            with self.subTest(state=invalid):
                if invalid is None:
                    state.unlink()
                else:
                    state.write_text(invalid, encoding="utf-8")
                report = lifecycle_support.check_data(self.data, self.expectations, "recovered")
                self.assertTrue(any("legacy onboarding" in failure for failure in report["failures"]), report)

    def test_unrecognized_app_metadata_remains_a_preservation_failure(self):
        self.recover_like_the_app()
        (self.data / "other-state.json").write_text("{}", encoding="utf-8")
        report = lifecycle_support.check_data(self.data, self.expectations, "recovered")
        self.assertIn("unexpected files: other-state.json", report["failures"])

    def test_lost_or_changed_user_data_is_reported(self):
        self.recover_like_the_app()
        cases = {
            "completed audio": lambda: (self.data / ("History/%s.wav" % lifecycle_support.COMPLETED_ID)).write_bytes(b"x"),
            "user note": lambda: (self.data / "keep-user-notes.txt").unlink(),
            "settings": lambda: (self.data / "settings.json").write_text('{"model": "other"}', encoding="utf-8"),
            "unexpected": lambda: (self.data / "History/stray.json").write_text("{}", encoding="utf-8"),
        }
        for label, change in cases.items():
            with self.subTest(label):
                snapshot = {path: path.read_bytes() for path in self.data.rglob("*") if path.is_file()}
                change()
                self.assertTrue(lifecycle_support.check_data(self.data, self.expectations, "recovered")["failures"])
                for path in list(self.data.rglob("*")):
                    if path.is_file() and path not in snapshot:
                        path.unlink()
                for path, data in snapshot.items():
                    path.write_bytes(data)
        audio_path = self.data / self.expectations["recovery"]["audio"]
        audio = bytearray(audio_path.read_bytes())
        audio[-1] ^= 1
        audio_path.write_bytes(bytes(audio))
        self.assertIn("recovered audio samples changed",
                      lifecycle_support.check_data(self.data, self.expectations, "recovered")["failures"])

    def test_tampering_changes_exactly_one_payload_byte(self):
        source = self.root / "package.msix"
        with zipfile.ZipFile(source, "w") as archive:
            archive.writestr("AppxManifest.xml", b"<Package/>")
            archive.writestr(zipfile.ZipInfo("Stored.bin"), bytes(range(256)) * 4)
            archive.writestr("Deflated.txt", b"deflated " * 100, compress_type=zipfile.ZIP_DEFLATED)
        output = self.root / "tampered.msix"
        result = lifecycle_support.tamper(source, output)
        self.assertEqual(result["entry"], "Stored.bin")
        self.assertTrue(result["stored"])
        original, changed = source.read_bytes(), output.read_bytes()
        self.assertEqual(len(original), len(changed))
        self.assertEqual(sum(1 for a, b in zip(original, changed) if a != b), 1)
        with zipfile.ZipFile(output) as archive:
            self.assertEqual(archive.read("Deflated.txt"), b"deflated " * 100)
            with self.assertRaises(zipfile.BadZipFile):
                archive.read("Stored.bin")

    def test_tampering_against_a_reference_changes_only_an_updated_entry(self):
        base = self.root / "base.msix"
        upgrade = self.root / "upgrade.msix"
        for path, version in ((base, b"1"), (upgrade, b"2")):
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("AppxManifest.xml", b"<Package/>")
                archive.writestr(zipfile.ZipInfo("Unchanged.bin"), bytes(range(256)) * 8)
                archive.writestr(zipfile.ZipInfo("package-manifest.json"), (b'{"version": "' + version + b'"}') * 8)
        output = self.root / "tampered.msix"
        result = lifecycle_support.tamper(upgrade, output, base)
        self.assertEqual(result["entry"], "package-manifest.json")
        with zipfile.ZipFile(output) as archive:
            self.assertEqual(archive.read("Unchanged.bin"), bytes(range(256)) * 8)
        with self.assertRaises(SystemExit):
            lifecycle_support.tamper(base, self.root / "same.msix", base)


if __name__ == "__main__":
    unittest.main()
