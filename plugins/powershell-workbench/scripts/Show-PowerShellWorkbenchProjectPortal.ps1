[CmdletBinding()]
param(
    [string]$ProfilePath = (Join-Path (Get-Location) '.powershell-workbench\project-profile.json'),
    [string]$ProjectRoot,
    [hashtable]$ComponentRoot,
    [hashtable]$WorkingPath,
    [string[]]$WindowsTarget,
    [switch]$NoWrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-PortalBlock {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Operator-visible, color-coded configuration blocks are an explicit workbench feature.')]
    param([string]$Title, [string[]]$Lines, [ConsoleColor]$Color = [ConsoleColor]::Cyan)
    $originalColor=[Console]::ForegroundColor
    try{
        [Console]::ForegroundColor=$Color
        [Console]::WriteLine()
        [Console]::WriteLine("========== $Title ==========")
        $Lines | ForEach-Object { [Console]::WriteLine($_) }
        [Console]::WriteLine(('=' * (12 + $Title.Length)))
    }finally{[Console]::ForegroundColor=$originalColor}
}

function Initialize-Property {
    param([object]$Object, [string]$Name, [object]$Value)
    if ($null -eq $Object.PSObject.Properties[$Name]) {
        $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
    }
}

$newProfileScript = Join-Path $PSScriptRoot 'New-PowerShellWorkbenchProjectProfile.ps1'
$resolvedProfilePath = [IO.Path]::GetFullPath($ProfilePath)

if (-not (Test-Path -LiteralPath $resolvedProfilePath -PathType Leaf)) {
    if (-not $NoWrite) { throw "Project profile was not found: $resolvedProfilePath. Create it first with New-PowerShellWorkbenchProjectProfile.ps1." }
    $profileRoot = if ($PSBoundParameters.ContainsKey('ProjectRoot')) { $ProjectRoot } else { (Get-Location).Path }
    $profileName = Split-Path -Leaf (Split-Path -Parent $resolvedProfilePath)
    if (-not $profileName) { $profileName = Split-Path -Leaf (Get-Location) }
    $created = & $newProfileScript -ProjectRoot $profileRoot -Name $profileName -Destination $resolvedProfilePath -NoWrite
    $config = $created.ProfileDocument
    if (-not $config) { throw "Unable to preview missing profile as JSON for $resolvedProfilePath." }
} else {
    $config = Get-Content -LiteralPath $resolvedProfilePath -Raw | ConvertFrom-Json
}

Initialize-Property -Object $config -Name 'project' -Value ([pscustomobject]@{ root = '.' })
Initialize-Property -Object $config -Name 'components' -Value @()
Initialize-Property -Object $config -Name 'paths' -Value ([pscustomobject]@{})
Initialize-Property -Object $config -Name 'targets' -Value ([pscustomobject]@{ windows = @() })
Initialize-Property -Object $config.targets -Name 'windows' -Value @()

$changed = $false
$hasProjectRootOverride = $PSBoundParameters.ContainsKey('ProjectRoot')
if ($hasProjectRootOverride) { $config.project.root = $ProjectRoot; $changed = $true }
foreach ($entry in @($(if ($ComponentRoot) { $ComponentRoot.GetEnumerator() }))) {
    $component = @($config.components | Where-Object { $_.id -eq $entry.Key }) | Select-Object -First 1
    if ($component) { $component.root = $entry.Value }
    else { $config.components = @($config.components) + [pscustomobject]@{id=$entry.Key;root=$entry.Value;role='configured'} }
    $changed = $true
}
foreach ($entry in @($(if ($WorkingPath) { $WorkingPath.GetEnumerator() }))) {
    if ($null -eq $config.paths.PSObject.Properties[$entry.Key]) { $config.paths | Add-Member NoteProperty $entry.Key $entry.Value }
    else { $config.paths.$($entry.Key) = $entry.Value }
    $changed = $true
}
if ($PSBoundParameters.ContainsKey('WindowsTarget')) { $config.targets.windows = @($WindowsTarget); $changed = $true }

if ($changed -and -not $NoWrite) {
    $config | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resolvedProfilePath -Encoding UTF8
    Write-PortalBlock -Title 'PROFILE GEMT' -Lines @($resolvedProfilePath, 'Kun den angivne projektkonfiguration blev opdateret.') -Color Green
}
elseif ($changed) { Write-PortalBlock -Title 'FORHANDSVISNING' -Lines @('NoWrite er aktiv: ingen fil blev aendret.') -Color Yellow }

$componentLines = @($config.components | ForEach-Object { "{0}: {1}" -f $_.id, $_.root })
$pathLines = @($config.paths.PSObject.Properties | ForEach-Object { "{0}: {1}" -f $_.Name, $_.Value })
$targetLines = @($config.targets.windows | ForEach-Object { "Windows: $_" })
Write-PortalBlock -Title 'PROJECT PORTAL' -Lines @("Profile: $resolvedProfilePath", "Project root: $($config.project.root)", "Mode: $(if ($changed) { if ($NoWrite) { 'preview' } else { 'updated' } } else { 'read-only overview' })") -Color Cyan
Write-PortalBlock -Title 'COMPONENT ROOTS' -Lines $(if ($componentLines.Count) { $componentLines } else { 'No component roots configured.' }) -Color Magenta
Write-PortalBlock -Title 'WINDOWS TARGETS' -Lines $(if ($targetLines.Count) { $targetLines } else { 'No Windows targets configured.' }) -Color Yellow
Write-PortalBlock -Title 'WORKING PATHS' -Lines $(if ($pathLines.Count) { $pathLines } else { 'No working paths configured.' }) -Color DarkCyan

[pscustomobject]@{
    ProfilePath = $resolvedProfilePath
    ProjectRoot = $config.project.root
    Components = $config.components
    WindowsTargets = @($config.targets.windows)
    Paths = $config.paths
    WasUpdated = ($changed -and -not $NoWrite)
}
