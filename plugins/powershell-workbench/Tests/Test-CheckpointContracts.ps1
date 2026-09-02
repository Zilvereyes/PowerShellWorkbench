[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
function Assert-True { param([Parameter(Mandatory)][bool]$Condition,[Parameter(Mandatory)][string]$Message) if(-not $Condition){throw $Message} }

$pluginRoot=Split-Path -Parent $PSScriptRoot;$newCheckpoint=Join-Path $pluginRoot 'scripts\New-PowerShellWorkbenchCheckpoint.ps1';$testCheckpoint=Join-Path $pluginRoot 'scripts\Test-PowerShellWorkbenchCheckpoint.ps1';$tempRoot=Join-Path ([IO.Path]::GetTempPath()) ('powershell-workbench-checkpoint-'+[guid]::NewGuid().ToString('N'))
try{
    New-Item -ItemType Directory -Path $tempRoot -Force|Out-Null
    $artifactPath=Join-Path $tempRoot 'artifact.txt';$checkpointPath=Join-Path $tempRoot 'checkpoint.json';$previewPath=Join-Path $tempRoot 'preview.json';Set-Content -LiteralPath $artifactPath -Value 'initial artifact' -Encoding UTF8
    $preview=& $newCheckpoint -CheckpointPath $previewPath -StepId 'servicing.stage' -ArtifactPath $artifactPath -NoWrite
    Assert-True -Condition (-not $preview.WasWritten) -Message 'NoWrite checkpoint preview reported a write.'
    Assert-True -Condition $preview.WasPreview -Message 'NoWrite checkpoint preview did not report preview mode.'
    Assert-True -Condition (-not(Test-Path -LiteralPath $previewPath -PathType Leaf)) -Message 'NoWrite checkpoint preview created a file.'
    $created=& $newCheckpoint -CheckpointPath $checkpointPath -StepId 'servicing.stage' -Status Prepared -MountState None -ArtifactPath $artifactPath -ToolPath $env:ComSpec -Precondition 'Path is local.' -Postcondition 'Artifact hash is unchanged.'
    Assert-True -Condition $created.WasWritten -Message 'Checkpoint contract was not written.'
    Assert-True -Condition ($created.Checkpoint.ResumeToken -match '^[A-F0-9]{64}$') -Message 'Checkpoint resume token is not a SHA256 value.'
    $valid=& $testCheckpoint -CheckpointPath $checkpointPath
    Assert-True -Condition $valid.Passed -Message 'Fresh checkpoint contract did not validate.'
    Set-Content -LiteralPath $artifactPath -Value 'drifted artifact' -Encoding UTF8
    $drifted=& $testCheckpoint -CheckpointPath $checkpointPath -NoThrow
    Assert-True -Condition (-not $drifted.Passed) -Message 'Checkpoint validator accepted an artifact with drift.'
    Assert-True -Condition (($drifted.Diagnostics -match 'Artifact hash drift detected').Count -gt 0) -Message 'Checkpoint validator did not explain artifact drift.'
    'Checkpoint contract tests passed.'
}finally{Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue}
