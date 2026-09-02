[CmdletBinding()]
param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$CheckpointPath,[switch]$NoThrow)

Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

function Get-CheckpointSha256 { param([Parameter(Mandatory)][string]$Path) (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function Get-CheckpointResumeToken {
    param([Parameter(Mandatory)][hashtable]$Identity)
    $sha256=[Security.Cryptography.SHA256]::Create()
    try{$bytes=[Text.Encoding]::UTF8.GetBytes(($Identity|ConvertTo-Json -Depth 8 -Compress));([BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-','')}
    finally{$sha256.Dispose()}
}

$diagnostics=@();$resolvedCheckpointPath=[IO.Path]::GetFullPath($CheckpointPath);$checkpoint=$null
try{
    if(-not(Test-Path -LiteralPath $resolvedCheckpointPath -PathType Leaf)){throw "Checkpoint was not found: $resolvedCheckpointPath"}
    $checkpoint=Get-Content -LiteralPath $resolvedCheckpointPath -Raw|ConvertFrom-Json
    if($checkpoint.SchemaVersion -ne '1.0'){throw "Unsupported checkpoint schema version: $($checkpoint.SchemaVersion)"}
    foreach($artifact in @($checkpoint.Artifacts)){
        if(-not(Test-Path -LiteralPath $artifact.Path -PathType Leaf)){$diagnostics+="Artifact is missing: $($artifact.Path)";continue}
        if((Get-CheckpointSha256 -Path $artifact.Path) -ne $artifact.Sha256){$diagnostics+="Artifact hash drift detected: $($artifact.Path)"}
    }
    if($null -ne $checkpoint.Tool){
        if(-not(Test-Path -LiteralPath $checkpoint.Tool.Path -PathType Leaf)){$diagnostics+="Tool is missing: $($checkpoint.Tool.Path)"}
        elseif((Get-CheckpointSha256 -Path $checkpoint.Tool.Path) -ne $checkpoint.Tool.Sha256){$diagnostics+="Tool hash drift detected: $($checkpoint.Tool.Path)"}
    }
    $identity=[ordered]@{SchemaVersion=$checkpoint.SchemaVersion;StepId=$checkpoint.StepId;Status=$checkpoint.Status;MountState=$checkpoint.MountState;Tool=$checkpoint.Tool;Artifacts=@($checkpoint.Artifacts);Preconditions=@($checkpoint.Preconditions);Postconditions=@($checkpoint.Postconditions)}
    if((Get-CheckpointResumeToken -Identity $identity) -ne $checkpoint.ResumeToken){$diagnostics+='Resume token does not match the checkpoint identity.'}
}catch{$diagnostics+=$_.Exception.Message}
$result=[pscustomobject]@{Passed=($diagnostics.Count -eq 0);CheckpointPath=$resolvedCheckpointPath;ResumeToken=if($null -ne $checkpoint){$checkpoint.ResumeToken}else{$null};Diagnostics=@($diagnostics);Checkpoint=$checkpoint}
if(-not $result.Passed -and -not $NoThrow){throw ($result.Diagnostics -join [Environment]::NewLine)}
$result
