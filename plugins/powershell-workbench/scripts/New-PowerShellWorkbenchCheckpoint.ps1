[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$CheckpointPath,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')][string]$StepId,
    [ValidateSet('Prepared','Mounted','Committed','Discarded','Verified','Failed')][string]$Status='Prepared',
    [ValidateSet('None','MountedByCurrentRun','Committed','Discardable')][string]$MountState='None',
    [string[]]$ArtifactPath=@(),
    [string]$ToolPath,
    [string[]]$Precondition=@(),
    [string[]]$Postcondition=@(),
    [switch]$Force,
    [switch]$NoWrite
)

Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

function Get-CheckpointSha256 { param([Parameter(Mandatory)][string]$Path) (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function Get-CheckpointResumeToken {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Identity)
    $sha256=[Security.Cryptography.SHA256]::Create()
    try{$bytes=[Text.Encoding]::UTF8.GetBytes(($Identity|ConvertTo-Json -Depth 8 -Compress));([BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-','')}
    finally{$sha256.Dispose()}
}

$resolvedCheckpointPath=[IO.Path]::GetFullPath($CheckpointPath)
if((Test-Path -LiteralPath $resolvedCheckpointPath -PathType Leaf) -and -not $Force){throw "Checkpoint already exists: $resolvedCheckpointPath. Use -Force to replace it."}
$artifacts=@()
foreach($path in $ArtifactPath){
    $resolvedPath=[IO.Path]::GetFullPath($path)
    if(-not(Test-Path -LiteralPath $resolvedPath -PathType Leaf)){throw "Checkpoint artifact was not found: $resolvedPath"}
    $artifacts+=[ordered]@{Path=$resolvedPath;Sha256=Get-CheckpointSha256 -Path $resolvedPath}
}
$tool=$null
if(-not [string]::IsNullOrWhiteSpace($ToolPath)){
    $resolvedToolPath=[IO.Path]::GetFullPath($ToolPath)
    if(-not(Test-Path -LiteralPath $resolvedToolPath -PathType Leaf)){throw "Checkpoint tool was not found: $resolvedToolPath"}
    $tool=[ordered]@{Path=$resolvedToolPath;FileVersion=(Get-Item -LiteralPath $resolvedToolPath).VersionInfo.FileVersion;Sha256=Get-CheckpointSha256 -Path $resolvedToolPath}
}
$identity=[ordered]@{SchemaVersion='1.0';StepId=$StepId;Status=$Status;MountState=$MountState;Tool=$tool;Artifacts=$artifacts;Preconditions=@($Precondition);Postconditions=@($Postcondition)}
$checkpoint=[ordered]@{SchemaVersion='1.0';StepId=$StepId;Status=$Status;MountState=$MountState;CreatedAtUtc=[DateTime]::UtcNow.ToString('o');Tool=$tool;Artifacts=$artifacts;Preconditions=@($Precondition);Postconditions=@($Postcondition);ResumeToken=Get-CheckpointResumeToken -Identity $identity}
$wasWritten=$false
if(-not $NoWrite -and $PSCmdlet.ShouldProcess($resolvedCheckpointPath,'Write checkpoint contract')){
    $parent=Split-Path -Parent $resolvedCheckpointPath
    if(-not(Test-Path -LiteralPath $parent -PathType Container)){New-Item -ItemType Directory -Path $parent -Force|Out-Null}
    $checkpoint|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $resolvedCheckpointPath -Encoding UTF8
    $wasWritten=$true
}
[pscustomobject]@{CheckpointPath=$resolvedCheckpointPath;Checkpoint=[pscustomobject]$checkpoint;ResumeToken=$checkpoint.ResumeToken;WasWritten=$wasWritten;WasPreview=[bool]$NoWrite}
