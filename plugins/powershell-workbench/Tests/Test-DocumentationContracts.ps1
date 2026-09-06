[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$pluginRoot=Split-Path -Parent $PSScriptRoot
$qualityGate=Get-Content -LiteralPath (Join-Path $pluginRoot 'skills\powershell-quality-gate\SKILL.md') -Raw
$profiles=Get-Content -LiteralPath (Join-Path $pluginRoot 'skills\powershell-scaffold\references\project-profiles.md') -Raw
$portability=Get-Content -LiteralPath (Join-Path $pluginRoot 'skills\powershell-workbench-portability\SKILL.md') -Raw
if($qualityGate -notmatch 'Test-PowerShellWorkbenchAutomaticVariables\.ps1 -Path <target\.ps1> -NoThrow'){throw 'Quality-gate documentation does not bind the mandatory Path parameter explicitly.'}
if($profiles -match 'Test_<Name>\.<Type>\.ps1' -or $profiles -notmatch 'Test-<Name>\.<Type>\.ps1'){throw 'Project-profile guidance does not use discoverable Test- names.'}
if($portability -match 'A future portal' -or $portability -notmatch 'Show-PowerShellWorkbenchProjectPortal\.ps1'){throw 'Portability guidance does not describe the existing project-profile portal.'}
'PowerShell Workbench documentation contracts passed.'
