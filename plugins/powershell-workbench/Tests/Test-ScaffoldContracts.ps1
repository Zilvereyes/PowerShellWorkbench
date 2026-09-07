[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$pluginRoot=Split-Path -Parent $PSScriptRoot
$generator=Join-Path $pluginRoot 'scripts\New-PowerShellArtifact.ps1'
$tempRoot=Join-Path ([IO.Path]::GetTempPath()) ('powershell-workbench-scaffold-'+[guid]::NewGuid().ToString('N'))
try{
    New-Item -ItemType Directory -Path $tempRoot|Out-Null
    foreach($projectProfile in @('RecoveryToolkit','WingetDownloader')){
        $item=& $generator -Kind PesterContract -Name 'Fixture' -Destination $tempRoot -Profile $projectProfile -ProjectRoot $tempRoot -Confirm:$false
        if($item.Name -ne 'Test-Fixture.Contract.ps1'){throw "Profile $projectProfile generated a non-discoverable test name: $($item.Name)"}
        Remove-Item -LiteralPath $item.FullName -Force
    }
    $sourcePath=Join-Path $tempRoot 'Source.ps1'
    $templatePath=Join-Path $tempRoot 'fragments.json'
    $outputPath=Join-Path $tempRoot 'Composed.ps1'
    @'
function Get-Alpha {
    'alpha'
}

#region SharedBeta
function Get-Beta {
    'beta'
}
#endregion
'@ | Set-Content -LiteralPath $sourcePath -Encoding UTF8
    $fragmentGenerator=Join-Path $pluginRoot 'scripts\New-PowerShellWorkbenchFragmentTemplate.ps1'
    $composer=Join-Path $pluginRoot 'scripts\Join-PowerShellWorkbenchFragmentTemplate.ps1'
    $preview=& $fragmentGenerator -SourcePath $sourcePath -OutputPath $templatePath -ProjectRoot $tempRoot -FunctionName Get-Alpha -RegionName SharedBeta
    $previewItems=@($preview)
    if($previewItems.Count -ne 1 -or $preview.state -ne 'PREVIEW' -or $preview.writePerformed){throw "Fragment generator did not default to no-write preview. Count=$($previewItems.Count); State=$($preview.state -join ','); WritePerformed=$($preview.writePerformed -join ','); FailedGates=$($preview.failedGates -join ',')"}
    if(Test-Path -LiteralPath $templatePath){throw 'Fragment generator preview wrote a file.'}
    $written=& $fragmentGenerator -SourcePath $sourcePath -OutputPath $templatePath -ProjectRoot $tempRoot -FunctionName Get-Alpha -RegionName SharedBeta -Write
    if($written.state -ne 'SUCCEEDED' -or -not(Test-Path -LiteralPath $templatePath)){throw 'Fragment generator did not write the validated template.'}
    $composePreview=& $composer -TemplatePath $templatePath -OutputPath $outputPath -ProjectRoot $tempRoot
    $composePreviewItems=@($composePreview)
    if($composePreviewItems.Count -ne 1 -or $composePreview.state -ne 'PREVIEW' -or $composePreview.writePerformed){throw "Fragment composer did not default to no-write preview. Count=$($composePreviewItems.Count); State=$($composePreview.state -join ','); WritePerformed=$($composePreview.writePerformed -join ',')"}
    if(Test-Path -LiteralPath $outputPath){throw 'Fragment composer preview wrote a file.'}
    $composed=& $composer -TemplatePath $templatePath -OutputPath $outputPath -ProjectRoot $tempRoot -Write
    if($composed.state -ne 'SUCCEEDED' -or -not(Test-Path -LiteralPath $outputPath)){throw 'Fragment composer did not write the composed script.'}
    if($composed.executionPerformed -or $composed.transportPerformed){throw 'Fragment composer reported execution or transport.'}
    $tokens=$null;$errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($outputPath,[ref]$tokens,[ref]$errors)
    if(@($errors).Count -ne 0){throw 'Composed fragment script does not parse.'}
    $conflictSourcePath=Join-Path $tempRoot 'ConflictSource.ps1'
    $conflictTemplatePath=Join-Path $tempRoot 'conflict-fragments.json'
    @'
function Get-Alpha {
    'different'
}
'@ | Set-Content -LiteralPath $conflictSourcePath -Encoding UTF8
    $conflictTemplate=& $fragmentGenerator -SourcePath $conflictSourcePath -OutputPath $conflictTemplatePath -ProjectRoot $tempRoot -FunctionName Get-Alpha -Write
    if($conflictTemplate.state -ne 'SUCCEEDED'){throw 'Conflict fixture template was not written.'}
    $conflicted=& $composer -TemplatePath $templatePath,$conflictTemplatePath -OutputPath (Join-Path $tempRoot 'Conflicted.ps1') -ProjectRoot $tempRoot
    if($conflicted.state -ne 'BLOCKED' -or @($conflicted.failedGates) -notcontains 'DuplicateFragmentConflict'){throw 'Fragment composer did not fail closed on conflicting duplicate fragments.'}
    Add-Content -LiteralPath $sourcePath -Value '# drift'
    $drifted=& $composer -TemplatePath $templatePath -OutputPath (Join-Path $tempRoot 'Drifted.ps1') -ProjectRoot $tempRoot
    if($drifted.state -ne 'BLOCKED' -or @($drifted.failedGates) -notcontains 'SourceSha256'){throw 'Fragment composer did not fail closed on source drift.'}
    'PowerShell Workbench scaffold contracts passed.'
}finally{if(Test-Path -LiteralPath $tempRoot){Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue}}
