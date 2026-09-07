[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$pluginRoot=Split-Path -Parent $PSScriptRoot;$newProfile=Join-Path $pluginRoot 'scripts\New-PowerShellWorkbenchProjectProfile.ps1';$resolveProfile=Join-Path $pluginRoot 'scripts\Resolve-PowerShellWorkbenchProjectProfile.ps1';$tempRoot=Join-Path ([IO.Path]::GetTempPath()) ('powershell-workbench-profile-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path (Join-Path $tempRoot 'src') -Force|Out-Null
try{
    $created=& $newProfile -ProjectRoot $tempRoot -Name 'FixtureProject' -Confirm:$false
    $createdBytes=[IO.File]::ReadAllBytes($created.ProfilePath)
    if($createdBytes.Length -ge 3 -and $createdBytes[0] -eq 0xEF -and $createdBytes[1] -eq 0xBB -and $createdBytes[2] -eq 0xBF){throw 'Generated profile was not deterministic UTF-8 without BOM.'}
    $resolved=& $resolveProfile -ProfilePath $created.ProfilePath
    if($resolved.ProjectName -ne 'FixtureProject' -or -not $resolved.ProjectRootExists -or $resolved.Components[0].ResolvedRoot -ne $tempRoot -or $resolved.PathDetails.reports.Exists -or -not $resolved.PathDetails.reports.WithinProject -or $resolved.PathDetails.reports.ConfiguredPath -ne 'Reports' -or $resolved.Quality.BlockingRules -notcontains 'PSReviewUnusedParameter'){throw 'Portable project profile did not resolve its relative root, quality plan, and path evidence.'}
    $profileDocument=Get-Content -LiteralPath $created.ProfilePath -Raw|ConvertFrom-Json
    $profileDocument.components+=([pscustomobject]@{id='outside';root='..\..\outside';role='shared'})
    $profileDocument|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $created.ProfilePath -Encoding UTF8
    $rejected=$false;try{& $resolveProfile -ProfilePath $created.ProfilePath|Out-Null}catch{$rejected=$true}
    if(-not $rejected){throw 'External component root was accepted without explicit authorization.'}
    $profileDocument.components=@([pscustomobject]@{id='main';root='..';role='primary'})
    $profileDocument.paths | Add-Member -MemberType NoteProperty -Name escaped -Value '..\Log'
    $profileDocument|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $created.ProfilePath -Encoding UTF8
    $escapedPathRejected=$false;try{& $resolveProfile -ProfilePath $created.ProfilePath|Out-Null}catch{$escapedPathRejected=$true}
    if(-not $escapedPathRejected){throw 'A working path outside the project root was accepted without explicit authorization.'}
    $externalPath=& $resolveProfile -ProfilePath $created.ProfilePath -AllowExternalPaths
    if($externalPath.PathDetails.escaped.WithinProject -or $externalPath.PathDetails.escaped.ResolvedPath -ne (Join-Path (Split-Path -Parent $tempRoot) 'Log')){throw 'Explicit external working path authorization did not preserve deterministic evidence.'}
    $previewProfilePath=Join-Path $tempRoot '.powershell-workbench\preview-project-profile.json'
    $preview=& $newProfile -ProjectRoot $tempRoot -Name 'FixtureProject' -Destination $previewProfilePath -NoWrite
    if(-not $preview.ProfilePath -or -not $preview.ProfileDocument -or $preview.ProfileDocument.project.name -ne 'FixtureProject' -or $preview.WasCreated -or -not $preview.WasPreview -or (Test-Path -LiteralPath $previewProfilePath -PathType Leaf)){throw 'NoWrite profile creation did not return a preview document only.'}
    'PowerShell Workbench project profile contracts passed.'
}finally{Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue}
