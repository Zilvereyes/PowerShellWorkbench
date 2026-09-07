[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProfilePath,
    [string]$AssessmentPath,
    [switch]$AsJson
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-Sha256File { param([string]$LiteralPath) (Get-FileHash -LiteralPath $LiteralPath -Algorithm SHA256).Hash.ToLowerInvariant() }
function Add-Gate { param([Collections.Generic.List[string]]$List,[string]$Gate) if (-not $List.Contains($Gate)) { [void]$List.Add($Gate) } }
function Test-WithinRoot { param([string]$Candidate,[string]$Root) $prefix = $Root.TrimEnd([char[]]'\\/') + [IO.Path]::DirectorySeparatorChar; $Candidate.Equals($Root,[StringComparison]::OrdinalIgnoreCase) -or $Candidate.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) }
function Get-AssessmentResult {
    param([bool]$IsConfigured,[string[]]$FailedGates,[object[]]$Targets,[object]$Source,[string]$HostBinding,[string]$SanitizationStatus,[string]$NextAllowedAction,[string]$ProfileSha256)
    $readinessStatus = 'PASS'
    if ($FailedGates.Count -gt 0) { $readinessStatus = 'BLOCKED' }
    elseif (@($Targets | Where-Object { $_.Status -eq 'BLOCKED' }).Count) { $readinessStatus = 'BLOCKED' }
    elseif (@($Targets | Where-Object { $_.Status -eq 'WAITING' }).Count) { $readinessStatus = 'WAITING' }
    elseif (@($Targets | Where-Object { $_.Status -eq 'NOT_RUN' }).Count) { $readinessStatus = 'NOT_RUN' }
    [pscustomobject][ordered]@{ SchemaVersion='1.1'; IsConfigured=$IsConfigured; IsValid=($FailedGates.Count -eq 0); FailedGates=@($FailedGates); ReadinessStatus=$readinessStatus; Source=$Source; SourceCommit=if ($Source) { [string]$Source.Commit } else { '' }; ProfileSha256=$ProfileSha256; HostBinding=$HostBinding; SanitizationStatus=$SanitizationStatus; NextAllowedAction=$NextAllowedAction; Targets=@($Targets); WritePerformed=$false; NetworkPerformed=$false; ProcessPerformed=$false; TransportPerformed=$false }
}

$profileResolved = if (Test-Path -LiteralPath $ProfilePath -PathType Leaf) { (Resolve-Path -LiteralPath $ProfilePath -ErrorAction Stop).Path } else { [IO.Path]::GetFullPath($ProfilePath) }
$profileDirectory = Split-Path -Parent $profileResolved
if ([string]::IsNullOrWhiteSpace($AssessmentPath)) { $AssessmentPath = Join-Path $profileDirectory 'project-assessment.json' }
$assessmentResolved = [IO.Path]::GetFullPath($AssessmentPath)
if (-not (Test-Path -LiteralPath $assessmentResolved -PathType Leaf)) {
    $result = Get-AssessmentResult -IsConfigured $false -FailedGates @('AssessmentProfilePresent') -Targets @() -Source $null -HostBinding '' -SanitizationStatus 'UNKNOWN' -NextAllowedAction 'Preview a project-assessment.json sidecar before declaring any target ready.' -ProfileSha256 ''
    if ($AsJson) { $result | ConvertTo-Json -Depth 12 } else { $result }
    return
}
try { $profileDocument = Get-Content -LiteralPath $profileResolved -Raw | ConvertFrom-Json; $document = Get-Content -LiteralPath $assessmentResolved -Raw | ConvertFrom-Json }
catch { throw "Project assessment or profile is invalid JSON: $($_.Exception.Message)" }
$failed = New-Object 'System.Collections.Generic.List[string]'
$schema = [string]$document.schemaVersion
if (@('1.0','1.1') -notcontains $schema) { Add-Gate $failed 'AssessmentSchemaVersion' }
$projectRoot = [IO.Path]::GetFullPath((Join-Path $profileDirectory ([string]$profileDocument.project.root)))
if (-not (Test-Path -LiteralPath $projectRoot -PathType Container)) { Add-Gate $failed 'ProjectRoot' }
$evidenceRoot = if ($schema -eq '1.0') { $profileDirectory } else { $projectRoot }
$source = $null
if ($schema -eq '1.0') {
    $commit = [string]$document.source.commit
    if ($commit -notmatch '^[0-9a-fA-F]{7,64}$') { Add-Gate $failed 'SourceCommit' }
    $source = [pscustomobject][ordered]@{ Kind='git'; Commit=$commit; Identity=$null }
} elseif ($schema -eq '1.1') {
    $kind = [string]$document.source.kind; $algorithm = [string]$document.source.identity.algorithm; $value = [string]$document.source.identity.value
    if (@('git','tree','ledger','manifest') -notcontains $kind) { Add-Gate $failed 'SourceIdentityKind' }
    if ($algorithm -cne 'SHA256' -or $value -notmatch '^[0-9a-fA-F]{64}$') { Add-Gate $failed 'SourceIdentity' }
    $expectedProfileHash = [string]$document.profileSha256; $actualProfileHash = Get-Sha256File $profileResolved
    if ($expectedProfileHash -notmatch '^[0-9a-fA-F]{64}$') { Add-Gate $failed 'ProfileSha256' } elseif ($expectedProfileHash -ine $actualProfileHash) { Add-Gate $failed 'ProfileHash' }
    $source = [pscustomobject][ordered]@{ Kind=$kind; Commit=''; Identity=[pscustomobject][ordered]@{ Algorithm=$algorithm; Value=$value.ToLowerInvariant() } }
}
$hostBinding = [string]$document.host.binding; if ([string]::IsNullOrWhiteSpace($hostBinding)) { Add-Gate $failed 'HostBinding' }
$sanitizationStatus = [string]$document.host.sanitizationStatus; if (@('SANITIZED','UNSANITIZED','UNKNOWN') -notcontains $sanitizationStatus) { Add-Gate $failed 'SanitizationStatus' }
$nextAllowedAction = [string]$document.nextAllowedAction; if ([string]::IsNullOrWhiteSpace($nextAllowedAction)) { Add-Gate $failed 'NextAllowedAction' }
$allowedStatus = @('PASS','WAITING','BLOCKED','NOT_RUN'); $targets = @()
foreach ($target in @($document.targets)) {
    $targetFailed = New-Object 'System.Collections.Generic.List[string]'; $targetName = [string]$target.name; $targetStatus = [string]$target.status
    if ([string]::IsNullOrWhiteSpace($targetName)) { Add-Gate $targetFailed 'TargetName' }
    if ($allowedStatus -notcontains $targetStatus) { Add-Gate $targetFailed 'TargetStatus' }
    $evidence = @()
    foreach ($item in @($target.evidence)) {
        $evidencePath = [string]$item.path; $expectedHash = [string]$item.sha256
        if ([string]::IsNullOrWhiteSpace($evidencePath) -or [IO.Path]::IsPathRooted($evidencePath) -or $evidencePath -match '(^|[\\/])\.\.([\\/]|$)') { Add-Gate $targetFailed 'EvidencePath'; continue }
        if ($expectedHash -notmatch '^[0-9a-fA-F]{64}$') { Add-Gate $targetFailed 'EvidenceSha256'; continue }
        $fullEvidencePath = [IO.Path]::GetFullPath((Join-Path $evidenceRoot $evidencePath))
        if (-not (Test-WithinRoot $fullEvidencePath $evidenceRoot)) { Add-Gate $targetFailed 'EvidencePath'; continue }
        $actualHash=''; $state='MISSING'
        if (Test-Path -LiteralPath $fullEvidencePath -PathType Leaf) { $actualHash=Get-Sha256File $fullEvidencePath; $state=if ($actualHash -ieq $expectedHash) { 'VERIFIED' } else { 'DRIFTED' } }
        if ($state -ne 'VERIFIED') { Add-Gate $targetFailed 'EvidenceHash' }
        $evidence += [pscustomobject][ordered]@{ Path=$evidencePath.Replace('\\','/'); ExpectedSha256=$expectedHash.ToLowerInvariant(); ActualSha256=$actualHash; State=$state }
    }
    $applicability='UNKNOWN'; $proofs=$null; $freshness='UNKNOWN'
    if ($schema -eq '1.1') {
        $applicability=[string]$target.applicability; if (@('APPLICABLE','NOT_APPLICABLE','UNKNOWN') -notcontains $applicability) { Add-Gate $targetFailed 'TargetApplicability' }
        $freshness=[string]$target.freshness; if (@('FRESH','STALE','UNKNOWN') -notcontains $freshness) { Add-Gate $targetFailed 'Freshness' }
        $proofs=[pscustomobject][ordered]@{ SafeOffline=[string]$target.proofs.safeOffline; Live=[string]$target.proofs.live; Postcondition=[string]$target.proofs.postcondition }
        foreach ($proofName in @('SafeOffline','Live','Postcondition')) { if (@('VERIFIED','MISSING','NOT_APPLICABLE','UNKNOWN') -notcontains [string]$proofs.$proofName) { Add-Gate $targetFailed ($proofName+'Proof') } }
        if ($targetStatus -eq 'PASS') {
            if ($applicability -ne 'APPLICABLE') { Add-Gate $targetFailed 'TargetApplicability' }
            if ($freshness -ne 'FRESH') { Add-Gate $targetFailed 'Freshness' }
            foreach ($proofName in @('SafeOffline','Live','Postcondition')) { if (@('VERIFIED','NOT_APPLICABLE') -notcontains [string]$proofs.$proofName) { Add-Gate $targetFailed ($proofName+'Proof') } }
        }
    }
    if ($targetStatus -eq 'PASS' -and ($evidence.Count -eq 0 -or $targetFailed.Count -gt 0)) { Add-Gate $targetFailed 'PassRequiresVerifiedEvidence' }
    $targetResult=[pscustomobject][ordered]@{ Name=$targetName; Status=$targetStatus; Applicability=$applicability; Freshness=$freshness; Proofs=$proofs; FailedGates=@($targetFailed); Evidence=@($evidence) }
    $targets += $targetResult; foreach ($gate in $targetResult.FailedGates) { Add-Gate $failed ($targetName+'/'+$gate) }
}
if ($targets.Count -eq 0) { Add-Gate $failed 'TargetsPresent' }
$profileHash = if ($schema -eq '1.1') { Get-Sha256File $profileResolved } else { '' }
$result = Get-AssessmentResult -IsConfigured $true -FailedGates @($failed) -Targets $targets -Source $source -HostBinding $hostBinding -SanitizationStatus $sanitizationStatus -NextAllowedAction $nextAllowedAction -ProfileSha256 $profileHash
if ($AsJson) { $result | ConvertTo-Json -Depth 12 } else { $result }
