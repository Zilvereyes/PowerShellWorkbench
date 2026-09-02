[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$ProjectRoot,
    [string]$Name,
    [string]$Destination,
    [switch]$Force,
    [switch]$NoWrite
)

Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$ProjectRoot=(Resolve-Path -LiteralPath $ProjectRoot -ErrorAction Stop).Path
if(-not $Name){$Name=Split-Path -Leaf $ProjectRoot}
if(-not $Destination){$Destination=Join-Path $ProjectRoot '.powershell-workbench\project-profile.json'}
$Destination=[IO.Path]::GetFullPath($Destination)
if(-not $NoWrite -and (Test-Path -LiteralPath $Destination) -and -not $Force){throw "Project profile already exists: $Destination. Use -Force to replace it."}
$profileDocument=[ordered]@{
    schemaVersion='1.0'
    project=[ordered]@{name=$Name;root='..'}
    components=@([ordered]@{id='main';root='..';role='primary'})
    targets=[ordered]@{windows=@()}
    paths=[ordered]@{reports='Reports';artifacts='artifacts';cache='cache'}
    notes='Keep roots relative to this profile. External component roots require explicit resolver authorization.'
}
if($NoWrite){
    [pscustomobject]@{
        ProfilePath=$Destination
        ProjectRoot=$ProjectRoot
        Name=$Name
        ProfileDocument=$profileDocument
        WasCreated=$false
        WasPreview=$true
    }
    return
}
if($PSCmdlet.ShouldProcess($Destination,'Create portable PowerShell Workbench project profile')){
    $directory=Split-Path -Parent $Destination
    if(-not(Test-Path -LiteralPath $directory -PathType Container)){New-Item -ItemType Directory -Path $directory -Force|Out-Null}
    $profileDocument|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $Destination -Encoding UTF8
    [pscustomobject]@{ProfilePath=$Destination;ProjectRoot=$ProjectRoot;Name=$Name}
}
