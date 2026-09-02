[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$pluginRoot=Split-Path -Parent $PSScriptRoot
$portal=Join-Path $pluginRoot 'scripts\Show-PowerShellWorkbenchProjectPortal.ps1'
$tempRoot=Join-Path ([IO.Path]::GetTempPath()) ('powershell-workbench-portal-'+[guid]::NewGuid().ToString('N'))
$profileDirectory=Join-Path $tempRoot '.powershell-workbench'
$profilePath=Join-Path $profileDirectory 'project-profile.json'
try{
    New-Item -ItemType Directory -Path $profileDirectory -Force|Out-Null
    @{schemaVersion='1.0';project=@{name='Fixture';root='..'};components=@();targets=@{windows=@()};paths=@{reports='Reports'}}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $profilePath -Encoding UTF8
    $readOnly=& $portal -ProfilePath $profilePath
    if($readOnly.WasUpdated){throw 'Read-only portal view reported an update.'}
    $before=Get-Content -LiteralPath $profilePath -Raw
    $preview=& $portal -ProfilePath $profilePath -ProjectRoot '.' -ComponentRoot @{main='src'} -WorkingPath @{cache='.cache'} -WindowsTarget @('Windows 11') -NoWrite
    $after=Get-Content -LiteralPath $profilePath -Raw
    if($preview.WasUpdated -or $before -ne $after -or $preview.Components.Count -ne 1){throw 'NoWrite portal preview modified or failed to map the profile.'}
    $missingPath=Join-Path $tempRoot '.powershell-workbench\missing-project-profile.json'
    $missingPreview=& $portal -ProfilePath $missingPath -NoWrite
    if($missingPreview.WasUpdated -or $missingPreview.ProfilePath -ne $missingPath -or (Test-Path -LiteralPath $missingPath -PathType Leaf)){throw 'Missing-profile NoWrite preview behaved unexpectedly.'}
}finally{Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue}
