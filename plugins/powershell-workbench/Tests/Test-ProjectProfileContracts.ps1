[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$pluginRoot=Split-Path -Parent $PSScriptRoot;$newProfile=Join-Path $pluginRoot 'scripts\New-PowerShellWorkbenchProjectProfile.ps1';$resolveProfile=Join-Path $pluginRoot 'scripts\Resolve-PowerShellWorkbenchProjectProfile.ps1';$tempRoot=Join-Path ([IO.Path]::GetTempPath()) ('powershell-workbench-profile-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path (Join-Path $tempRoot 'src') -Force|Out-Null
try{
    $created=& $newProfile -ProjectRoot $tempRoot -Name 'FixtureProject' -Confirm:$false
    $resolved=& $resolveProfile -ProfilePath $created.ProfilePath
    if($resolved.ProjectName -ne 'FixtureProject' -or -not $resolved.ProjectRootExists -or $resolved.Components[0].ResolvedRoot -ne $tempRoot){throw 'Portable project profile did not resolve its relative root.'}
    $profileDocument=Get-Content -LiteralPath $created.ProfilePath -Raw|ConvertFrom-Json
    $profileDocument.components+=([pscustomobject]@{id='outside';root='..\..\outside';role='shared'})
    $profileDocument|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $created.ProfilePath -Encoding UTF8
    $rejected=$false;try{& $resolveProfile -ProfilePath $created.ProfilePath|Out-Null}catch{$rejected=$true}
    if(-not $rejected){throw 'External component root was accepted without explicit authorization.'}
    $previewProfilePath=Join-Path $tempRoot '.powershell-workbench\preview-project-profile.json'
    $preview=& $newProfile -ProjectRoot $tempRoot -Name 'FixtureProject' -Destination $previewProfilePath -NoWrite
    if(-not $preview.ProfilePath -or -not $preview.ProfileDocument -or $preview.ProfileDocument.project.name -ne 'FixtureProject' -or $preview.WasCreated -or -not $preview.WasPreview -or (Test-Path -LiteralPath $previewProfilePath -PathType Leaf)){throw 'NoWrite profile creation did not return a preview document only.'}
    'PowerShell Workbench project profile contracts passed.'
}finally{Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue}
