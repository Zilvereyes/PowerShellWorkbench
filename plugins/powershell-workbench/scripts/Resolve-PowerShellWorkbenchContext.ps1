[CmdletBinding()]
param(
    [string]$StartPath = (Get-Location).Path,

    [ValidateSet('Auto', 'Generic', 'RecoveryToolkit', 'WingetDownloader')]
    [string]$RequestedProfile = 'Auto',

    [string]$RegistryPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-ProfileAtPath {
    param([string]$Path)

    if (Test-Path -LiteralPath (Join-Path $Path 'RecoveryToolkit.psd1')) { return 'RecoveryToolkit' }
    if (Test-Path -LiteralPath (Join-Path $Path 'WingetDownloader.psd1')) { return 'WingetDownloader' }
    if (Test-Path -LiteralPath (Join-Path $Path '.git')) { return 'Generic' }
    if (@(Get-ChildItem -LiteralPath $Path -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.psd1', '.psm1') }).Count -gt 0) { return 'Generic' }
    return $null
}

function Get-TechnologiesAtPath {
    param([string]$Path)

    $technologies = New-Object System.Collections.Generic.List[string]
    $files = @(Get-ChildItem -LiteralPath $Path -File -ErrorAction SilentlyContinue)
    if (@($files | Where-Object { $_.Extension -in @('.ps1', '.psm1', '.psd1') }).Count -gt 0) { $technologies.Add('PowerShell') }
    if ((Test-Path -LiteralPath (Join-Path $Path 'pyproject.toml')) -or (Test-Path -LiteralPath (Join-Path $Path 'requirements.txt')) -or @($files | Where-Object Extension -eq '.py').Count -gt 0) { $technologies.Add('Python') }
    if (Test-Path -LiteralPath (Join-Path $Path 'package.json')) { $technologies.Add('Node') }
    if (@($files | Where-Object { $_.Extension -in @('.sln', '.csproj', '.fsproj') }).Count -gt 0) { $technologies.Add('.NET') }
    if ((Test-Path -LiteralPath (Join-Path $Path 'CMakeLists.txt')) -or @($files | Where-Object { $_.Extension -in @('.c', '.cpp', '.h', '.hpp') }).Count -gt 0) { $technologies.Add('Native') }
    if (@($files | Where-Object { $_.Extension -in @('.html', '.css', '.js', '.ts') }).Count -gt 0) { $technologies.Add('Web') }
    if (@($files | Where-Object { $_.Extension -in @('.json', '.yaml', '.yml') }).Count -gt 0) { $technologies.Add('DataFormats') }
    if (@($files | Where-Object Extension -eq '.md').Count -gt 0) { $technologies.Add('Documentation') }
    return @($technologies | Select-Object -Unique)
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
            [pscustomobject]@{ Profile = $detectedProfile; ProjectRoot = $candidate; Source = 'Ancestor'; Technologies = @(Get-TechnologiesAtPath -Path $candidate) }
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
            [pscustomobject]@{ Profile = [string]$project.profile; ProjectRoot = $registeredRoot; Source = 'Registry'; Technologies = @(Get-TechnologiesAtPath -Path $registeredRoot) }
            return
        }
    }
}

if ($RequestedProfile -in @('Auto', 'Generic') -and $fallbackRoot) {
    [pscustomobject]@{ Profile = 'Generic'; ProjectRoot = $fallbackRoot; Source = 'StartPath'; Technologies = @(Get-TechnologiesAtPath -Path $fallbackRoot) }
    return
}

[pscustomobject]@{ Profile = $(if ($RequestedProfile -eq 'Auto') { 'Generic' } else { $RequestedProfile }); ProjectRoot = ''; Source = 'Unresolved'; Technologies = @() }
