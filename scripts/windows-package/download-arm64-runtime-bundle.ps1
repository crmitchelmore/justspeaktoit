<#
.SYNOPSIS
Waits for the Windows ARM64 workflow run of the same commit and downloads its runtime bundle.

.DESCRIPTION
The x64 runtime bundle comes from the Mac cross-build in this workflow; the
ARM64 one from windows-arm64.yml, which builds natively on windows-11-arm. Both
workflows run for the same pushes and pull requests (their path filters name
each other), so the ARM64 run for -HeadSha must appear. This script polls the
Actions API until that run has uploaded windows-runtime-bundle-arm64, downloads
it to -Destination and writes run-id to $GITHUB_OUTPUT. It fails, never skips,
when no such run appears or the run ends without the artifact. Requires the gh
CLI with GH_TOKEN (actions: read). Keep this file ASCII-only.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $HeadSha,
    [Parameter(Mandatory = $true)] [string] $Destination,
    [string] $Event = $env:GITHUB_EVENT_NAME,
    [string] $Repository = $env:GITHUB_REPOSITORY,
    [string] $Workflow = 'windows-arm64.yml',
    [string] $Artifact = 'windows-runtime-bundle-arm64',
    [int] $TimeoutMinutes = 80,
    [int] $AppearMinutes = 10,
    [string] $GitHubOutput = $env:GITHUB_OUTPUT
)

$ErrorActionPreference = 'Stop'
if ($HeadSha -notmatch '^[0-9a-f]{40}$') { throw 'HeadSha must be a full commit SHA.' }
$started = Get-Date
$runId = $null
while ($true) {
    $elapsed = (Get-Date) - $started
    if ($elapsed.TotalMinutes -gt $TimeoutMinutes) {
        throw "The $Workflow run for $HeadSha did not upload $Artifact within $TimeoutMinutes minutes."
    }
    $filter = @('run', 'list', '--repo', $Repository, '--workflow', $Workflow, '--commit', $HeadSha, '--limit', '10',
                '--json', 'databaseId,status,conclusion,event,createdAt')
    $runs = @(& gh @filter | ConvertFrom-Json)
    if ($LASTEXITCODE -ne 0) { throw 'gh run list failed.' }
    # workflow_dispatch of this workflow does not dispatch the ARM64 one; any event of the commit will do.
    if ($Event -and $Event -ne 'workflow_dispatch') { $runs = @($runs | Where-Object { $_.event -eq $Event }) }
    $run = $runs | Sort-Object createdAt -Descending | Select-Object -First 1
    if (-not $run) {
        if ($elapsed.TotalMinutes -gt $AppearMinutes) {
            throw "No $Workflow run exists for $HeadSha ($Event) after $AppearMinutes minutes; both workflows must run together."
        }
        Write-Host "Waiting for the $Workflow run of $HeadSha to start."
        Start-Sleep -Seconds 30
        continue
    }
    $runId = $run.databaseId
    $artifacts = & gh api "repos/$Repository/actions/runs/$runId/artifacts?per_page=100" | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'Could not list the ARM64 run artifacts.' }
    if (@($artifacts.artifacts | Where-Object { $_.name -eq $Artifact -and -not $_.expired }).Count) { break }
    $status = & gh run view $runId --repo $Repository --json status,conclusion | ConvertFrom-Json
    if ($status.status -eq 'completed') {
        throw "ARM64 run $runId finished ($($status.conclusion)) without uploading $Artifact."
    }
    Write-Host "ARM64 run $runId is $($status.status); waiting for $Artifact."
    Start-Sleep -Seconds 30
}
& gh run download $runId --repo $Repository --name $Artifact --dir $Destination
if ($LASTEXITCODE -ne 0) { throw "Could not download $Artifact from run $runId." }
Write-Host "Downloaded $Artifact from ARM64 run $runId."
if ($GitHubOutput) { Add-Content -LiteralPath $GitHubOutput -Value "run-id=$runId" }
