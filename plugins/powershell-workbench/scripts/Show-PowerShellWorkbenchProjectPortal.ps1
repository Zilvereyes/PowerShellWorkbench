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

function Ensure-Property {
    param([object]$Object, [string]$Name, [object]$Value)
    if ($null -eq $Object.PSObject.Properties[$Name]) {
        $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
    }
}

if (-not (Test-Path -LiteralPath $ProfilePath -PathType Leaf)) {
    throw "Project profile was not found: $ProfilePath. Create it first with New-PowerShellWorkbenchProjectProfile.ps1."
}

$config = Get-Content -LiteralPath $ProfilePath -Raw | ConvertFrom-Json
Ensure-Property $config 'project' ([pscustomobject]@{ root = '.' })
Ensure-Property $config 'components' @()
Ensure-Property $config 'paths' ([pscustomobject]@{})
Ensure-Property $config 'targets' ([pscustomobject]@{ windows = @() })
Ensure-Property $config.targets 'windows' @()

$changed = $false
if ($PSBoundParameters.ContainsKey('ProjectRoot')) { $config.project.root = $ProjectRoot; $changed = $true }
foreach ($entry in @($(if ($ComponentRoot) { $ComponentRoot.GetEnumerator() }))) {
    $component=@($config.components|Where-Object {$_.id -eq $entry.Key})|Select-Object -First 1
    if($component){$component.root=$entry.Value}
    else{$config.components=@($config.components)+[pscustomobject]@{id=$entry.Key;root=$entry.Value;role='configured'}}
    $changed = $true
}
foreach ($entry in @($(if ($WorkingPath) { $WorkingPath.GetEnumerator() }))) {
    if ($null -eq $config.paths.PSObject.Properties[$entry.Key]) { $config.paths | Add-Member NoteProperty $entry.Key $entry.Value }
    else { $config.paths.$($entry.Key) = $entry.Value }
    $changed = $true
}
if ($PSBoundParameters.ContainsKey('WindowsTarget')) { $config.targets.windows = @($WindowsTarget); $changed = $true }

if ($changed -and -not $NoWrite) {
    $config | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ProfilePath -Encoding UTF8
    Write-PortalBlock 'PROFILE GEMT' @($ProfilePath, 'Kun den angivne projektkonfiguration blev opdateret.') Green
}
elseif ($changed) { Write-PortalBlock 'FORHANDSVISNING' @('NoWrite er aktiv: ingen fil blev aendret.') Yellow }

$componentLines = @($config.components | ForEach-Object { "{0}: {1}" -f $_.id, $_.root })
$pathLines = @($config.paths.PSObject.Properties | ForEach-Object { "{0}: {1}" -f $_.Name, $_.Value })
$targetLines = @($config.targets.windows | ForEach-Object { "Windows: $_" })
Write-PortalBlock 'PROJECT PORTAL' @("Profile: $ProfilePath", "Project root: $($config.project.root)", "Mode: $(if ($changed) { if ($NoWrite) { 'preview' } else { 'updated' } } else { 'read-only overview' })") Cyan
Write-PortalBlock 'COMPONENT ROOTS' $(if ($componentLines.Count) { $componentLines } else { 'No component roots configured.' }) Magenta
Write-PortalBlock 'WINDOWS TARGETS' $(if ($targetLines.Count) { $targetLines } else { 'No Windows targets configured.' }) Yellow
Write-PortalBlock 'WORKING PATHS' $(if ($pathLines.Count) { $pathLines } else { 'No working paths configured.' }) DarkCyan

[pscustomobject]@{ ProfilePath = (Resolve-Path -LiteralPath $ProfilePath).Path; ProjectRoot = $config.project.root; Components = $config.components; WindowsTargets = @($config.targets.windows); Paths = $config.paths; WasUpdated = ($changed -and -not $NoWrite) }
