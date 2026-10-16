$ErrorActionPreference = 'Stop'
$source = Get-Content -Raw (Join-Path $PSScriptRoot 'test-windows-package-lifecycle.ps1')
$assignment = [regex]::Match($source, '(?m)^\$readyPattern = ''([^'']+)''\r?$')
if (-not $assignment.Success) { throw 'The production lifecycle readiness pattern was not found.' }
$pattern = $assignment.Groups[1].Value
$warning = 'Recording sounds unavailable. Check audio output; dictation still works.'
$cases = @(
    @{ status = 'Enter and save the selected provider''s API key'; expected = $true },
    @{ status = 'Ready. Ctrl+Alt+Space starts dictation.'; expected = $true },
    @{ status = $warning; expected = $true },
    @{ status = "Unexpected error: $warning"; expected = $false },
    @{ status = "$warning Additional failure."; expected = $false },
    @{ status = $warning.Replace('unavailable.', 'unavailable!'); expected = $false },
    @{ status = 'Recording sound preparation failed: no audio device.'; expected = $false },
    @{ status = 'Recording sounds unavailable. Dictation failed.'; expected = $false },
    @{ status = 'Failed to load recordings.'; expected = $false }
)
foreach ($case in $cases) {
    if (($case.status -match $pattern) -ne $case.expected) {
        throw "Incorrect production lifecycle readiness decision: $($case.status)"
    }
}
Write-Host 'Recording feedback readiness passed: only the exact nonfatal warning is admitted.'
