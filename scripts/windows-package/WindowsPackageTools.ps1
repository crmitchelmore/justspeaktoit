# Shared helpers for the Windows developer MSIX scripts. Dot-source this file.
# Compatible with Windows PowerShell 5.1 (the Appx and WinRT deployment APIs
# used by the lifecycle test) and PowerShell 7. Keep this file ASCII-only.

function Get-JstiSha256([string] $Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Read-JstiJson([string] $Path) {
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
}

function Write-JstiJson([string] $Path, $Value) {
    $json = $Value | ConvertTo-Json -Depth 16
    [System.IO.File]::WriteAllText($Path, $json + "`n", (New-Object System.Text.UTF8Encoding $false))
}

function ConvertTo-JstiArgument([string] $Value) {
    # Quote one argument for the Windows C runtime command-line parser.
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $builder = New-Object System.Text.StringBuilder
    [void] $builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $backslashes++; continue }
        if ($character -eq '"') {
            [void] $builder.Append('\' * ($backslashes * 2 + 1))
            [void] $builder.Append('"')
        } else {
            [void] $builder.Append('\' * $backslashes)
            [void] $builder.Append($character)
        }
        $backslashes = 0
    }
    [void] $builder.Append('\' * ($backslashes * 2))
    [void] $builder.Append('"')
    return $builder.ToString()
}

function Invoke-JstiTool {
    # Runs a native tool without PowerShell's stderr-to-error conversion, which
    # would turn ordinary diagnostics into terminating errors in Windows
    # PowerShell 5.1. The caller decides what a non-zero exit code means.
    param(
        [Parameter(Mandatory = $true)] [string] $FilePath,
        [string[]] $Arguments = @(),
        [string] $LogPath,
        [int] $TimeoutSeconds = 900
    )
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = (($Arguments | ForEach-Object { ConvertTo-JstiArgument $_ }) -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $process = [System.Diagnostics.Process]::Start($startInfo)
    $standardOutput = $process.StandardOutput.ReadToEndAsync()
    $standardError = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        $process.Kill()
        throw "$([System.IO.Path]::GetFileName($FilePath)) exceeded $TimeoutSeconds seconds."
    }
    $process.WaitForExit()
    $result = [pscustomobject]@{
        ExitCode = $process.ExitCode
        StandardOutput = $standardOutput.Result
        StandardError = $standardError.Result
    }
    if ($LogPath) {
        $text = "> $FilePath $($startInfo.Arguments)`r`n$($result.StandardOutput)$($result.StandardError)exit $($result.ExitCode)`r`n"
        [System.IO.File]::AppendAllText($LogPath, $text, (New-Object System.Text.UTF8Encoding $false))
    }
    return $result
}

function Invoke-JstiPython {
    param([Parameter(Mandatory = $true)] [string] $Python, [string[]] $Arguments, [string] $LogPath)
    $command = Get-Command $Python -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $result = Invoke-JstiTool -FilePath $command.Source -Arguments (@('-B') + $Arguments) -LogPath $LogPath
    if ($result.ExitCode -ne 0) {
        throw "Python $($Arguments[0]) failed with exit code $($result.ExitCode): $($result.StandardError.Trim())"
    }
    return $result.StandardOutput
}

function Get-JstiPackagingTools {
    # Downloads the pinned Microsoft.Windows.SDK.BuildTools package once,
    # authenticates it by SHA-512 and size, extracts only its x64 tool directory
    # and requires valid Microsoft signatures on MakeAppx and SignTool.
    param([Parameter(Mandatory = $true)] [string] $CacheDirectory)
    $pins = (Read-JstiJson (Join-Path $PSScriptRoot 'dependencies.json')).packagingTools
    $cache = (New-Item -ItemType Directory -Force -Path $CacheDirectory).FullName
    $archive = Join-Path $cache $pins.name
    if (-not (Test-Path -LiteralPath $archive)) {
        $partial = "$archive.partial"
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $previousProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try { Invoke-WebRequest -Uri $pins.url -OutFile $partial -UseBasicParsing }
        finally { $ProgressPreference = $previousProgress }
        Move-Item -LiteralPath $partial -Destination $archive
    }
    $bytes = (Get-Item -LiteralPath $archive).Length
    $digest = (Get-FileHash -LiteralPath $archive -Algorithm SHA512).Hash.ToLowerInvariant()
    if ($bytes -ne $pins.bytes -or $digest -ne $pins.sha512) {
        Remove-Item -LiteralPath $archive -Force
        throw "Packaging tools download does not match its pin ($bytes bytes, SHA-512 $digest)."
    }
    $tools = Join-Path $cache 'tools'
    $marker = Join-Path $tools '.jsti-extracted'
    # Reuse an extraction from this verified archive; the tool hashes and
    # signatures are checked again below either way.
    if (-not ((Test-Path -LiteralPath $marker) -and
              ([System.IO.File]::ReadAllText($marker).Trim() -eq $digest))) {
        if (Test-Path -LiteralPath $tools) { Remove-Item -LiteralPath $tools -Recurse -Force }
        New-Item -ItemType Directory -Path $tools | Out-Null
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($archive)
        try {
            foreach ($entry in $zip.Entries) {
                $name = [System.Uri]::UnescapeDataString($entry.FullName)
                if (-not $name.StartsWith($pins.toolDirectory, [System.StringComparison]::OrdinalIgnoreCase) -or
                    $name.EndsWith('/')) { continue }
                $relative = $name.Substring($pins.toolDirectory.Length)
                if ($relative -match '(^|/)\.\.(/|$)' -or $relative -match '^[/\\]' -or $relative -match ':') {
                    throw "Unsafe path in packaging tools archive: $name"
                }
                $destination = Join-Path $tools ($relative.Replace('/', '\'))
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destination, $false)
            }
        } finally { $zip.Dispose() }
        [System.IO.File]::WriteAllText($marker, $digest)
    }
    $evidence = [ordered]@{ package = $pins.name; sha512 = $digest; bytes = $bytes; tools = [ordered]@{} }
    $paths = @{}
    foreach ($tool in $pins.tools) {
        $path = Join-Path $tools $tool
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Pinned packaging tools lack $tool." }
        $signature = Get-AuthenticodeSignature -LiteralPath $path
        $signer = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { '' }
        if ($signature.Status -ne 'Valid' -or $signer -notmatch 'O=Microsoft Corporation') {
            throw "$tool is not validly signed by Microsoft: $($signature.Status) $signer"
        }
        $evidence.tools[$tool] = [ordered]@{
            sha256 = Get-JstiSha256 $path
            fileVersion = (Get-Item -LiteralPath $path).VersionInfo.FileVersion
            authenticode = [string] $signature.Status
            signer = $signer
        }
        $paths[$tool] = $path
    }
    return [pscustomobject]@{ MakeAppx = $paths['makeappx.exe']; SignTool = $paths['signtool.exe']; Evidence = $evidence }
}

function Read-JstiPackageIdentity([string] $Package) {
    # Reads the Identity element of the manifest inside an .msix without
    # installing or unpacking it.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Package)
    try {
        $entry = $zip.GetEntry('AppxManifest.xml')
        if (-not $entry) { throw "$Package has no AppxManifest.xml." }
        $reader = New-Object System.IO.StreamReader($entry.Open(), [System.Text.Encoding]::UTF8)
        try { [xml] $manifest = $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $zip.Dispose() }
    # GetAttribute avoids the XmlElement.Name property shadowing the attribute.
    $identity = $manifest.DocumentElement.GetElementsByTagName('Identity') | Select-Object -First 1
    if (-not $identity) { throw "$Package has no package identity." }
    return [pscustomobject]@{
        Name = $identity.GetAttribute('Name'); Publisher = $identity.GetAttribute('Publisher')
        Version = $identity.GetAttribute('Version'); Architecture = $identity.GetAttribute('ProcessorArchitecture')
    }
}
