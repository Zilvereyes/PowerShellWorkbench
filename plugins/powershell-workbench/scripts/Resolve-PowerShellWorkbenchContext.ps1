[CmdletBinding()]
param(
    [Alias('Path')]
    [string]$StartPath = (Get-Location).Path,

    [ValidateSet('Auto', 'Generic', 'RecoveryToolkit', 'WingetDownloader', 'WindowsServicingToolkit')]
    [string]$RequestedProfile = 'Auto',

    [string]$RegistryPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-ProfileAtPath {
    param([string]$Path)

    if (Test-Path -LiteralPath (Join-Path $Path 'RecoveryToolkit.psd1')) { return 'RecoveryToolkit' }
    if (Test-Path -LiteralPath (Join-Path $Path 'WingetDownloader.psd1')) { return 'WingetDownloader' }
    if ((Get-ServicingInventory -Path $Path).Detected) { return 'WindowsServicingToolkit' }
    if (Test-Path -LiteralPath (Join-Path $Path '.git')) { return 'Generic' }
    if (@(Get-ChildItem -LiteralPath $Path -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.psd1', '.psm1') }).Count -gt 0) { return 'Generic' }
    return $null
}

function Get-TechnologiesAtPath {
    param([string]$Path)

    $technologies = New-Object System.Collections.Generic.List[string]
    $excludedSegments = @('.git', '.svn', 'node_modules', 'packages', 'bin', 'obj', 'TestResults', 'Reports', 'outputs', 'artifacts')
    $files = @(Get-ChildItem -LiteralPath $Path -File -Recurse -Depth 3 -ErrorAction SilentlyContinue | Where-Object {
        $relative = $_.FullName.Substring($Path.Length).TrimStart([char[]]'\\/')
        -not @($excludedSegments | Where-Object { $relative -match ('(^|[\\/])' + [regex]::Escape($_) + '([\\/]|$)') }).Count
    })
    if (@($files | Where-Object { $_.Extension -in @('.ps1', '.psm1', '.psd1') }).Count -gt 0) { $technologies.Add('PowerShell') }
    if (@($files | Where-Object { $_.Name -in @('pyproject.toml', 'requirements.txt') -or $_.Extension -eq '.py' }).Count -gt 0) { $technologies.Add('Python') }
    if (@($files | Where-Object Name -eq 'package.json').Count -gt 0) { $technologies.Add('Node') }
    if (@($files | Where-Object { $_.Extension -in @('.sln', '.csproj', '.fsproj') }).Count -gt 0) { $technologies.Add('.NET') }
    if (@($files | Where-Object { $_.Name -eq 'CMakeLists.txt' -or $_.Extension -in @('.c', '.cpp', '.h', '.hpp') }).Count -gt 0) { $technologies.Add('Native') }
    if (@($files | Where-Object { $_.Extension -in @('.html', '.css', '.js', '.ts') }).Count -gt 0) { $technologies.Add('Web') }
    if (@($files | Where-Object { $_.Extension -in @('.json', '.yaml', '.yml', '.toml', '.xml') }).Count -gt 0) { $technologies.Add('DataFormats') }
    if (@($files | Where-Object Extension -eq '.md').Count -gt 0) { $technologies.Add('Documentation') }
    return @($technologies | Select-Object -Unique)
}

function Get-ServicingInventory {
    param([string]$Path)

    $excludedSegments = @('.git', '.svn', 'node_modules', 'packages', 'bin', 'obj', 'TestResults', 'Reports', 'outputs', 'artifacts')
    $files = @(Get-ChildItem -LiteralPath $Path -File -Recurse -Depth 3 -ErrorAction SilentlyContinue | Where-Object {
        $relative = $_.FullName.Substring($Path.Length).TrimStart([char[]]'\\/')
        -not @($excludedSegments | Where-Object { $relative -match ('(^|[\\/])' + [regex]::Escape($_) + '([\\/]|$)') }).Count
    })
    $contentFiles = @($files | Where-Object { $_.Extension -in @('.ps1', '.psm1', '.psd1', '.json', '.yaml', '.yml', '.xml', '.txt') })
    $hasPattern = {
        param([string]$Pattern)
        if (-not $contentFiles) { return $false }
        [bool](Select-String -LiteralPath @($contentFiles.FullName) -Pattern $Pattern -Quiet -ErrorAction SilentlyContinue)
    }
    $dism = & $hasPattern '(?i)(dism(?:\.exe)?|/(Mount|Unmount|Add-Package|Add-Driver|Export)-Image|/Commit|/Discard)'
    $oscdimg = & $hasPattern '(?i)oscdimg'
    $registry = & $hasPattern '(?i)\breg(?:\.exe)?\b|reg load|reg unload'
    $robocopy = & $hasPattern '(?i)\brobocopy(?:\.exe)?\b'
    $bootMedia = @($files | Where-Object { $_.Name -match '^(boot|install)\.(wim|esd)$|^boot\.stl$' }).Count -gt 0 -or (& $hasPattern '(?i)(boot\.wim|install\.(wim|esd)|\befi\b|\biso\b)')
    $nativeTools = New-Object System.Collections.Generic.List[string]
    if ($dism) { $nativeTools.Add('DISM') }
    if ($oscdimg) { $nativeTools.Add('Oscdimg') }
    if ($registry) { $nativeTools.Add('reg.exe') }
    if ($robocopy) { $nativeTools.Add('Robocopy') }
    $artifactTypes = New-Object System.Collections.Generic.List[string]
    foreach ($extension in @('.wim', '.esd', '.iso', '.msu', '.cab', '.inf')) {
        if (@($files | Where-Object Extension -eq $extension).Count -gt 0 -or (& $hasPattern ([regex]::Escape($extension)))) { $artifactTypes.Add($extension.TrimStart('.').ToUpperInvariant()) }
    }
    $riskSurfaces = New-Object System.Collections.Generic.List[string]
    if ($dism) { $riskSurfaces.Add('Mount'); $riskSurfaces.Add('Commit') }
    if ($bootMedia) { $riskSurfaces.Add('BootMedia') }
    if ($registry) { $riskSurfaces.Add('RegistryHive') }
    if (& $hasPattern '(?i)(physicaldrive|diskpart|format-volume|write.*usb)') { $riskSurfaces.Add('DiskWrite') }
    if (& $hasPattern '(?i)(icacls|set-acl|takeown)') { $riskSurfaces.Add('ACL') }
    [pscustomobject]@{ Detected = ($dism -or $oscdimg -or $bootMedia); NativeTools = @($nativeTools); ArtifactTypes = @($artifactTypes); RiskSurfaces = @($riskSurfaces) }
}

function Get-PowerShellRuntimeInventory {

    $seen = @{}
    $runtimes = New-Object System.Collections.Generic.List[object]
    $addRuntime = {
        param([string]$RuntimePath, [string]$Source, [bool]$Pinned)
        if (-not $RuntimePath -or -not (Test-Path -LiteralPath $RuntimePath -PathType Leaf)) { return }
        $resolved = (Resolve-Path -LiteralPath $RuntimePath).Path
        if ($seen.ContainsKey($resolved)) { return }
        $seen[$resolved] = $true
        $probe = '$PSVersionTable.PSEdition; $PSVersionTable.PSVersion.ToString()'
        $encodedProbe = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe))
        $versionLines = @(& $resolved -NoProfile -EncodedCommand $encodedProbe 2>$null)
        if ($LASTEXITCODE -ne 0 -or $versionLines.Count -lt 2) { $versionLines = @('Unknown', 'Unknown') }
        $architecture = if ($resolved -match '(?i)(x64|amd64)') { 'x64' } elseif ($resolved -match '(?i)x86') { 'x86' } else { 'Unknown' }
        $runtimes.Add([pscustomobject]@{ Path=$resolved; Edition=[string]$versionLines[0]; Version=[string]$versionLines[1]; Architecture=$architecture; Source=$Source; Pinned=$Pinned })
    }
    foreach ($name in @('powershell.exe', 'pwsh.exe')) { foreach ($command in @(Get-Command $name -All -ErrorAction SilentlyContinue)) { & $addRuntime $command.Source 'PATH' $false } }
    $windowsApps = Join-Path $env:ProgramFiles 'WindowsApps'
    if (Test-Path -LiteralPath $windowsApps) { foreach ($candidate in @(Get-ChildItem -Path (Join-Path $windowsApps 'Microsoft.PowerShell_*\pwsh.exe') -File -ErrorAction SilentlyContinue)) { & $addRuntime $candidate.FullName 'WindowsApps' $true } }
    @($runtimes.ToArray())
}

function Get-ContextResult {
    param([string]$ProfileName, [string]$ProjectRoot, [string]$Source)
    $servicing = Get-ServicingInventory -Path $ProjectRoot
    [pscustomobject]@{ Profile=$ProfileName; ProjectRoot=$ProjectRoot; Source=$Source; Technologies=@(Get-TechnologiesAtPath -Path $ProjectRoot); NativeTools=$servicing.NativeTools; ArtifactTypes=$servicing.ArtifactTypes; RiskSurfaces=$servicing.RiskSurfaces; DetectedPowerShellRuntimes=@(Get-PowerShellRuntimeInventory) }
}

$candidate = [System.IO.Path]::GetFullPath($StartPath)
if (Test-Path -LiteralPath $candidate -PathType Leaf) { $candidate = Split-Path -Parent $candidate }
$fallbackRoot = $candidate
while (-not (Test-Path -LiteralPath $fallbackRoot -PathType Container)) {
    $fallbackParent = Split-Path -Parent $fallbackRoot
    if ([string]::IsNullOrWhiteSpace($fallbackParent) -or $fallbackParent -eq $fallbackRoot) { $fallbackRoot = ''; break }
    $fallbackRoot = $fallbackParent
}
while (-not [string]::IsNullOrWhiteSpace($candidate)) {
    if (Test-Path -LiteralPath $candidate -PathType Container) {
        $detectedProfile = Get-ProfileAtPath -Path $candidate
        if ($detectedProfile -and ($RequestedProfile -in @('Auto', $detectedProfile) -or ($RequestedProfile -eq 'Generic' -and $detectedProfile -eq 'Generic'))) {
            Get-ContextResult -ProfileName $detectedProfile -ProjectRoot $candidate -Source 'Ancestor'
            return
        }
    }
    $parent = Split-Path -Parent $candidate
    if ($parent -eq $candidate) { break }
    $candidate = $parent
}

if ([string]::IsNullOrWhiteSpace($RegistryPath)) {
    if (-not [string]::IsNullOrWhiteSpace($env:POWERSHELL_WORKBENCH_PROJECTS)) {
        $RegistryPath = $env:POWERSHELL_WORKBENCH_PROJECTS
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $RegistryPath = Join-Path $env:USERPROFILE '.config\powershell-workbench\projects.json'
    }
}

if ($RegistryPath -and (Test-Path -LiteralPath $RegistryPath -PathType Leaf)) {
    $registry = Get-Content -LiteralPath $RegistryPath -Raw | ConvertFrom-Json
    foreach ($project in @($registry.projects)) {
        if ($project.path -and (Test-Path -LiteralPath $project.path -PathType Container) -and ($RequestedProfile -eq 'Auto' -or $project.profile -eq $RequestedProfile)) {
            $registeredRoot = [System.IO.Path]::GetFullPath([string]$project.path)
            Get-ContextResult -ProfileName ([string]$project.profile) -ProjectRoot $registeredRoot -Source 'Registry'
            return
        }
    }
}

if ($RequestedProfile -in @('Auto', 'Generic') -and $fallbackRoot) {
    Get-ContextResult -ProfileName 'Generic' -ProjectRoot $fallbackRoot -Source 'StartPath'
    return
}

[pscustomobject]@{ Profile = $(if ($RequestedProfile -eq 'Auto') { 'Generic' } else { $RequestedProfile }); ProjectRoot = ''; Source = 'Unresolved'; Technologies = @(); NativeTools = @(); ArtifactTypes = @(); RiskSurfaces = @(); DetectedPowerShellRuntimes = @() }
