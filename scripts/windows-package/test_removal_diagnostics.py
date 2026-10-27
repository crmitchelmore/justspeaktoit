"""Exercise bounded read-only failure diagnostics; never touch an installed package."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'scripts/windows-package/test-windows-package-lifecycle.ps1'
POWERSHELL = shutil.which('powershell') or shutil.which('pwsh')


class RemovalDiagnosticTests(unittest.TestCase):
    def test_strict_deadline_and_failed_assertion_are_preserved(self):
        source = SOURCE.read_text(encoding='utf-8')
        removal = source.split('function Assert-Removed(', 1)[1].split('# --- user data', 1)[0]
        self.assertIn('$filesRemoved = $installLocation -and (Wait-PathState $installLocation $false 120)', removal)
        self.assertIn('if (-not $filesRemoved) {', removal)
        self.assertIn('Get-PreviousPackageDiagnostics $name $Package.PackageFullName $installLocation', removal)
        self.assertNotIn('-RemovalOnly', removal)
        self.assertIn('Add-Check "$Label removes its installed files" $filesRemoved $removalDetails', removal)
        self.assertNotIn('Remove-Item', removal)

    @unittest.skipUnless(POWERSHELL, 'PowerShell runtime unavailable; actual mocked helper runs in Windows packaging CI')
    def test_actual_helper_bounds_relative_inventory_and_registration_metadata_without_mutation(self):
        source = SOURCE.read_text(encoding='utf-8')
        helper = 'function Get-PreviousPackageDiagnostics(' + source.split(
            'function Get-PreviousPackageDiagnostics(', 1)[1].split('# --- certificates', 1)[0]
        with tempfile.TemporaryDirectory(prefix='jsti-removal-diagnostics-') as folder:
            root = Path(folder)
            payload = root / 'retained package'
            payload.mkdir()
            for index in range(270):
                (payload / f'file-{index:03}.txt').write_text('CONTENTS_MUST_NOT_BE_COLLECTED', encoding='utf-8')
            (payload / 'directory').mkdir()
            before = sorted(path.name for path in payload.iterdir())
            fixture = root / 'fixture.ps1'
            fixture.write_text(r'''
param([string] $Location)
$ErrorActionPreference = 'Stop'
$script:removedJob = $false
$script:waitSeconds = 0
function Start-Job {
    param($ArgumentList, $ScriptBlock)
    # Execute the actual child block with synthetic AppX reads, without a job.
    [pscustomobject]@{ State = 'Completed'; Rows = @(& $ScriptBlock @ArgumentList) }
}
function Wait-Job { param($Job, $Timeout) $script:waitSeconds = $Timeout }
function Receive-Job { param($Job) $Job.Rows }
function Stop-Job { param($Job) throw 'A completed diagnostic must not be stopped' }
function Remove-Job { param($Job, [switch] $Force) $script:removedJob = $true }
function Get-AppxPackage {
    param([switch] $AllUsers, [string] $Name)
    1..40 | ForEach-Object {
        [pscustomobject]@{ PackageFullName = "owned_$($_)"; InstallLocation = $Location
            Status = 'Ok'; IsPartiallyStaged = $true; PackageUserInformation = @() }
    }
}
function Get-AppxProvisionedPackage { throw 'Removal diagnostics must not collect provisioning' }
function Get-Process { throw 'Removal diagnostics must not sample processes' }
''' + helper + r'''
$first = Get-PreviousPackageDiagnostics 'owned' 'owned_1' $Location -RemovalOnly
function Get-AppxPackage { throw ('synthetic-read-error-' + ('x' * 1000)) }
$second = Get-PreviousPackageDiagnostics 'owned' 'owned_1' $Location -RemovalOnly
[ordered]@{ first = $first; second = $second; removedJob = $script:removedJob
    waitSeconds = $script:waitSeconds } | ConvertTo-Json -Depth 12 -Compress
''', encoding='utf-8')
            completed = subprocess.run([POWERSHELL, '-NoProfile', '-NonInteractive', '-File', str(fixture),
                                        '-Location', str(payload)], capture_output=True, text=True,
                                       encoding='utf-8', timeout=30, check=True)
            result = json.loads(completed.stdout)
            self.assertTrue(result['removedJob'])
            self.assertEqual(result['waitSeconds'], 30)
            self.assertEqual(result['first']['state'], 'Completed')
            sections = result['first']['observations']
            self.assertEqual([row['kind'] for row in sections], ['registrations', 'directory'])
            registrations, directory = sections
            self.assertTrue(registrations['truncated'])
            self.assertEqual(len(registrations['rows']), 32)
            self.assertTrue(directory['truncated'])
            self.assertEqual(len(directory['rows']), 256)
            self.assertEqual(directory['observedEntryCount'], 256)
            self.assertEqual(directory['observedFileCount'] + directory['observedDirectoryCount'], 256)
            self.assertTrue(all('/' not in row['name'] and '\\' not in row['name'] for row in directory['rows']))
            self.assertNotIn('CONTENTS_MUST_NOT_BE_COLLECTED', completed.stdout)
            self.assertEqual(len(result['second']['observations'][0]['error']), 512)
            self.assertEqual(sorted(path.name for path in payload.iterdir()), before)
            self.assertEqual((payload / 'file-000.txt').read_text(encoding='utf-8'), 'CONTENTS_MUST_NOT_BE_COLLECTED')


if __name__ == '__main__':
    unittest.main()
