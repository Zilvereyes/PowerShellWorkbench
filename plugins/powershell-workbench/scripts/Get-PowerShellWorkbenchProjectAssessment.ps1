[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProfilePath,
    [string]$AssessmentPath,
    [switch]$AsJson
)

Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

function Get-AssessmentResult {
    param([bool]$IsConfigured,[string[]]$FailedGates,[object[]]$Targets,[string]$SourceCommit,[string]$HostBinding,[string]$SanitizationStatus,[string]$NextAllowedAction)
    $readinessStatus='PASS'
    if($FailedGates.Count -gt 0){$readinessStatus='BLOCKED'}
    elseif(@($Targets|Where-Object{$_.Status -eq 'BLOCKED'}).Count){$readinessStatus='BLOCKED'}
    elseif(@($Targets|Where-Object{$_.Status -eq 'WAITING'}).Count){$readinessStatus='WAITING'}
    elseif(@($Targets|Where-Object{$_.Status -eq 'NOT_RUN'}).Count){$readinessStatus='NOT_RUN'}
    [pscustomobject][ordered]@{
        SchemaVersion='1.0'; IsConfigured=$IsConfigured; IsValid=($FailedGates.Count -eq 0); FailedGates=@($FailedGates)
        ReadinessStatus=$readinessStatus
        SourceCommit=$SourceCommit; HostBinding=$HostBinding; SanitizationStatus=$SanitizationStatus; NextAllowedAction=$NextAllowedAction
        Targets=@($Targets); WritePerformed=$false; NetworkPerformed=$false; ProcessPerformed=$false; TransportPerformed=$false
    }
}

$profileResolved=if(Test-Path -LiteralPath $ProfilePath -PathType Leaf){(Resolve-Path -LiteralPath $ProfilePath -ErrorAction Stop).Path}else{[IO.Path]::GetFullPath($ProfilePath)}
$profileDirectory=Split-Path -Parent $profileResolved
$profilePrefix=$profileDirectory.TrimEnd([char[]]'\\/')+[IO.Path]::DirectorySeparatorChar
if([string]::IsNullOrWhiteSpace($AssessmentPath)){$AssessmentPath=Join-Path $profileDirectory 'project-assessment.json'}
$assessmentResolved=[IO.Path]::GetFullPath($AssessmentPath)
if(-not(Test-Path -LiteralPath $assessmentResolved -PathType Leaf)){
    $result=Get-AssessmentResult -IsConfigured $false -FailedGates @('AssessmentProfilePresent') -Targets @() -SourceCommit '' -HostBinding '' -SanitizationStatus 'UNKNOWN' -NextAllowedAction 'Create and review a project-assessment.json sidecar before declaring any target ready.'
    if($AsJson){$result|ConvertTo-Json -Depth 12}else{$result}; return
}
try{$document=Get-Content -LiteralPath $assessmentResolved -Raw|ConvertFrom-Json}catch{throw "Project assessment is invalid JSON: $($_.Exception.Message)"}
$failed=@()
if([string]$document.schemaVersion -ne '1.0'){$failed+='AssessmentSchemaVersion'}
$sourceCommit=[string]$document.source.commit
if($sourceCommit -notmatch '^[0-9a-fA-F]{7,64}$'){$failed+='SourceCommit'}
$hostBinding=[string]$document.host.binding
if([string]::IsNullOrWhiteSpace($hostBinding)){$failed+='HostBinding'}
$sanitizationStatus=[string]$document.host.sanitizationStatus
if(@('SANITIZED','UNSANITIZED','UNKNOWN') -notcontains $sanitizationStatus){$failed+='SanitizationStatus'}
$nextAllowedAction=[string]$document.nextAllowedAction
if([string]::IsNullOrWhiteSpace($nextAllowedAction)){$failed+='NextAllowedAction'}
$allowedStatus=@('PASS','WAITING','BLOCKED','NOT_RUN')
$targets=@()
foreach($target in @($document.targets)){
    $targetFailed=@(); $targetName=[string]$target.name; $targetStatus=[string]$target.status
    if([string]::IsNullOrWhiteSpace($targetName)){$targetFailed+='TargetName'}
    if($allowedStatus -notcontains $targetStatus){$targetFailed+='TargetStatus'}
    $evidence=@()
    foreach($item in @($target.evidence)){
        $evidencePath=[string]$item.path; $expectedHash=[string]$item.sha256
        if([string]::IsNullOrWhiteSpace($evidencePath) -or [IO.Path]::IsPathRooted($evidencePath)){$targetFailed+='EvidencePath'; continue}
        if($expectedHash -notmatch '^[0-9a-fA-F]{64}$'){$targetFailed+='EvidenceSha256'; continue}
        $fullEvidencePath=[IO.Path]::GetFullPath((Join-Path $profileDirectory $evidencePath))
        if(-not($fullEvidencePath.StartsWith($profilePrefix,[StringComparison]::OrdinalIgnoreCase))){$targetFailed+='EvidencePath'; continue}
        $actualHash=''; $state='MISSING'
        if(Test-Path -LiteralPath $fullEvidencePath -PathType Leaf){$actualHash=(Get-FileHash -LiteralPath $fullEvidencePath -Algorithm SHA256).Hash.ToLowerInvariant(); $state=$(if($actualHash -eq $expectedHash.ToLowerInvariant()){'VERIFIED'}else{'DRIFTED'})}
        if($state -ne 'VERIFIED'){$targetFailed+='EvidenceHash'}
        $evidence+=[pscustomobject][ordered]@{Path=$evidencePath;ExpectedSha256=$expectedHash.ToLowerInvariant();ActualSha256=$actualHash;State=$state}
    }
    if($targetStatus -eq 'PASS' -and ($evidence.Count -eq 0 -or $targetFailed.Count -gt 0)){$targetFailed+='PassRequiresVerifiedEvidence'}
    $targets+=[pscustomobject][ordered]@{Name=$targetName;Status=$targetStatus;FailedGates=@($targetFailed|Select-Object -Unique);Evidence=@($evidence)}
    $failed+=@($targetFailed|ForEach-Object{"$targetName/$($_)"})
}
if($targets.Count -eq 0){$failed+='TargetsPresent'}
$result=Get-AssessmentResult -IsConfigured $true -FailedGates @($failed|Select-Object -Unique) -Targets $targets -SourceCommit $sourceCommit -HostBinding $hostBinding -SanitizationStatus $sanitizationStatus -NextAllowedAction $nextAllowedAction
if($AsJson){$result|ConvertTo-Json -Depth 12}else{$result}
