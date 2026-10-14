# Synthetic native-tool results only; no SDK download, signing or installation.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'WindowsPackageTools.ps1')

$script:failed = 0
function Assert-That([bool] $Condition, [string] $Message) {
    if ($Condition) { Write-Host "PASS  $Message" } else { $script:failed++; Write-Host "FAIL  $Message" }
}

$directory = Join-Path ([IO.Path]::GetTempPath()) ("jsti-pack-diagnostics-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $directory | Out-Null
try {
    $log = Join-Path $directory 'synthetic.pack.log'
    $hostExecutable = (Get-Process -Id $PID).Path
    $command = "[Console]::Out.Write(('A' * 5000) + 'END-STDOUT'); " +
        "[Console]::Error.Write(('B' * 5000) + 'END-STDERR'); exit 1"
    $result = Invoke-JstiTool -FilePath $hostExecutable -Arguments @('-NoProfile', '-Command', $command) -LogPath $log
    $script:failure = ''
    $messages = @(& {
        try { Assert-JstiMakeAppxPackSucceeded -Result $result -LogPath $log }
        catch { $script:failure = $_.Exception.Message }
    } 6>&1)
    $shown = ($messages | ForEach-Object { $_.ToString() }) -join "`n"
    Assert-That ($result.ExitCode -eq 1 -and $script:failure -match 'exit code 1') 'Exit 1 remains a pack failure'
    Assert-That ($shown.Contains('END-STDOUT') -and $shown.Contains('END-STDERR')) 'Both diagnostic stream tails are emitted'
    Assert-That ($shown.Length -lt 9000 -and -not $shown.Contains('A' * 5000)) 'Console diagnostics are bounded'
    Assert-That ($script:failure.Contains($log) -and $shown.Contains($log)) 'Failure and excerpt identify the full log'
    $saved = [IO.File]::ReadAllText($log)
    Assert-That ($saved.Contains('A' * 5000) -and $saved.Contains('B' * 5000) -and $saved.Contains('exit 1')) `
        'The complete tool log survives failure'

    $helper = (Join-Path $PSScriptRoot 'WindowsPackageTools.ps1').Replace("'", "''")
    $command = ". '$helper'; Assert-JstiMakeAppxPackSucceeded -Result " +
        "([pscustomobject]@{ ExitCode = 1; StandardOutput = 'SCHEMA FAILURE'; StandardError = 'PACK ERROR' }) " +
        "-LogPath 'synthetic.pack.log'"
    $unhandled = Invoke-JstiTool -FilePath $hostExecutable -Arguments @('-NoProfile', '-Command', $command)
    Assert-That ($unhandled.ExitCode -eq 1 -and $unhandled.StandardOutput.Contains('SCHEMA FAILURE') -and
        $unhandled.StandardOutput.Contains('PACK ERROR')) 'Unhandled pack failure exits 1 and emits both diagnostics'

    $success = [pscustomobject]@{ ExitCode = 0; StandardOutput = 'success'; StandardError = '' }
    $messages = @(Assert-JstiMakeAppxPackSucceeded -Result $success -LogPath $log 6>&1)
    Assert-That ($messages.Count -eq 0) 'Successful packing emits no additional diagnostics'

    $empty = [pscustomobject]@{ ExitCode = 1; StandardOutput = ''; StandardError = '' }
    $script:failure = ''
    $messages = @(& {
        try { Assert-JstiMakeAppxPackSucceeded -Result $empty -LogPath $log }
        catch { $script:failure = $_.Exception.Message }
    } 6>&1)
    Assert-That ($script:failure -match 'exit code 1' -and (Test-Path -LiteralPath $log)) `
        'Empty tool output still fails and retains the log'
} finally {
    Remove-Item -LiteralPath $directory -Recurse
}
if ($script:failed) { throw "$script:failed packaging diagnostic fixtures failed." }
Write-Host 'Packaging failure diagnostic fixtures passed.'
