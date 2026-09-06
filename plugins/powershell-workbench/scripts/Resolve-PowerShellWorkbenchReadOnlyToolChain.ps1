[CmdletBinding()]
param(
    [string]$ProposalPath,
    [ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedProposalSha256,
    [string]$ApprovalPath,
    [ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedApprovalSha256,
    [string]$ObservationPath,
    [ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedObservationSha256,
    [Parameter(Mandatory)][string]$AllowedRoot,
    [string]$AllowedEvidenceRoot,
    [Parameter(Mandatory)][datetimeoffset]$ReferenceTimeUtc,
    [ValidateRange(1,1440)][int]$MaximumProposalAgeMinutes = 30,
    [ValidateRange(1,1048576)][int]$MaximumSliceBytes = 65536,
    [ValidateRange(1024,10485760)][long]$MaximumEvidenceBytes = 1048576,
    [ValidateRange(1024,1073741824)][long]$MaximumTargetBytes = 67108864,
    [switch]$RequireObservation,
    [switch]$NoThrow,
    [switch]$AsJson
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$unknownGates = New-Object Collections.Generic.List[string]
$conflictGates = New-Object Collections.Generic.List[string]
function Add-UnknownGate { param([string]$Gate) if(-not $unknownGates.Contains($Gate)){$unknownGates.Add($Gate)} }
function Add-ConflictGate { param([string]$Gate) if(-not $conflictGates.Contains($Gate)){$conflictGates.Add($Gate)} }
function Get-Value { param($Object,[string]$Name,$Default=$null) if($null -eq $Object){return $Default};$property=$Object.PSObject.Properties[$Name];if($null -eq $property){return $Default};$property.Value }
function Test-Integer { param($Value) $Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64] }
function Test-ExactBoolean { param($Value,[bool]$Expected) $Value -is [bool] -and $Value -eq $Expected }
function Convert-EvidenceTime { param($Value) if($Value -is [datetimeoffset]){return $Value};if($Value -is [datetime]){return [datetimeoffset]::new([datetime]$Value)};[datetimeoffset]::Parse([string]$Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind) }
function Test-Shape { param($Object,[string[]]$Expected) if($null -eq $Object){return $false};$names=@($Object.PSObject.Properties.Name);@($names|Where-Object{$Expected -cnotcontains $_}).Count -eq 0 -and @($Expected|Where-Object{$names -cnotcontains $_}).Count -eq 0 }
function Test-FullyQualifiedPath { param([string]$Path) if([string]::IsNullOrWhiteSpace($Path)-or -not[IO.Path]::IsPathRooted($Path)){return $false};if($Path -match '^[A-Za-z]:(?:$|[^\\/])' -or $Path -match '^[\\/](?![\\/])'){return $false};$true }
function Get-NormalizedPath { param([string]$Path) if(-not(Test-FullyQualifiedPath -Path $Path)){return $null};try{[IO.Path]::GetFullPath($Path).TrimEnd('\','/')}catch{return $null} }
function Test-PathWithinRoot { param([string]$Path,[string]$Root) $rootPath=[IO.Path]::GetFullPath($Root).TrimEnd('\','/');$candidate=[IO.Path]::GetFullPath($Path);$candidate.StartsWith($rootPath+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) }
function Test-PathChain { param([string]$Path,[string]$Root) $rootPath=[IO.Path]::GetFullPath($Root).TrimEnd('\','/');$current=[IO.Path]::GetFullPath($Path);while($current){if(Test-Path -LiteralPath $current){if((Get-Item -LiteralPath $current).Attributes -band [IO.FileAttributes]::ReparsePoint){return $false}};if($current -ieq $rootPath){return $true};$parent=Split-Path -Parent $current;if(-not $parent -or $parent -ieq $current){break};$current=$parent.TrimEnd('\','/')};$false }
function Read-Snapshot {
    param([string]$LiteralPath,[long]$MaximumBytes)
    $resolved=(Resolve-Path -LiteralPath $LiteralPath).Path
    $stream=[IO.File]::Open($resolved,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{$memory=[IO.MemoryStream]::new();try{$buffer=New-Object byte[] 8192;while(($count=$stream.Read($buffer,0,$buffer.Length))-gt 0){if($memory.Length -gt ($MaximumBytes-$count)){throw 'Snapshot exceeds its byte limit.'};$memory.Write($buffer,0,$count)};$bytes=$memory.ToArray()}finally{$memory.Dispose()}}finally{$stream.Dispose()}
    $algorithm=[Security.Cryptography.SHA256]::Create();try{$hash=([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()}finally{$algorithm.Dispose()}
    $decoder=New-Object Text.UTF8Encoding($false,$true)
    [pscustomobject]@{Path=$resolved;Bytes=$bytes;Length=$bytes.Length;Sha256=$hash;Text=$decoder.GetString($bytes)}
}
function Read-JsonEvidence {
    param([string]$Path,[string]$ExpectedHash,[string]$MissingGate,[string]$HashGate,[string]$JsonGate)
    if(-not $Path -or -not $ExpectedHash -or -not(Test-Path -LiteralPath $Path -PathType Leaf)){Add-UnknownGate $MissingGate;return $null}
    try{$snapshot=Read-Snapshot -LiteralPath $Path -MaximumBytes $MaximumEvidenceBytes}catch{Add-UnknownGate $JsonGate;return $null}
    if($snapshot.Sha256 -ne $ExpectedHash.ToLowerInvariant()){Add-ConflictGate $HashGate;return $null}
    try{$value=$snapshot.Text|ConvertFrom-Json}catch{Add-UnknownGate $JsonGate;return $null}
    [pscustomobject]@{Snapshot=$snapshot;Value=$value}
}

$rootResolved=Get-NormalizedPath -Path $AllowedRoot
if(-not $rootResolved){Add-ConflictGate 'AllowedRootAbsolute'}
elseif($rootResolved -ieq [IO.Path]::GetPathRoot($rootResolved)){Add-ConflictGate 'AllowedRootScoped'}
elseif(-not(Test-Path -LiteralPath $rootResolved -PathType Container)){Add-UnknownGate 'AllowedRootExists'}
elseif(-not(Test-PathChain -Path $rootResolved -Root $rootResolved)){Add-ConflictGate 'AllowedRootReparseSafe'}
$evidenceRootResolved=$null
if($ObservationPath -or $ExpectedObservationSha256){
    $evidenceRootResolved=Get-NormalizedPath -Path $AllowedEvidenceRoot
    if(-not $evidenceRootResolved){Add-UnknownGate 'AllowedEvidenceRootPresent'}
    elseif($evidenceRootResolved -ieq [IO.Path]::GetPathRoot($evidenceRootResolved)){Add-ConflictGate 'AllowedEvidenceRootScoped'}
    elseif(-not(Test-Path -LiteralPath $evidenceRootResolved -PathType Container)){Add-UnknownGate 'AllowedEvidenceRootExists'}
    elseif(-not(Test-PathChain -Path $evidenceRootResolved -Root $evidenceRootResolved)){Add-ConflictGate 'AllowedEvidenceRootReparseSafe'}
}

$proposalEvidence=Read-JsonEvidence -Path $ProposalPath -ExpectedHash $ExpectedProposalSha256 -MissingGate 'ProposalPresent' -HashGate 'ProposalSha256' -JsonGate 'ProposalJson'
$proposal=$null;$approval=$null;$observation=$null;$targetPath=$null;$targetSha256=$null;$proposalSha256=$null;$approvalSha256=$null;$proposalCreated=$null;$approvalCreated=$null;$approvalExpires=$null;$offsetBytes=[int64]0;$sliceBytes=[int64]0
if($proposalEvidence){
    $proposal=$proposalEvidence.Value;$proposalSha256=$proposalEvidence.Snapshot.Sha256
    if(-not(Test-Shape $proposal @('schemaVersion','proposalId','createdAt','source','tool'))){Add-UnknownGate 'ProposalShape'}
    if([string](Get-Value $proposal 'schemaVersion') -cne '1.0'){Add-UnknownGate 'ProposalSchema'}
    try{$proposalCreated=Convert-EvidenceTime -Value (Get-Value $proposal 'createdAt')}catch{Add-UnknownGate 'ProposalCreatedAt'}
    if($proposalCreated){$age=$ReferenceTimeUtc.ToUniversalTime()-$proposalCreated.ToUniversalTime();if($age.TotalSeconds -lt 0 -or $age.TotalMinutes -gt $MaximumProposalAgeMinutes){Add-UnknownGate 'ProposalFreshness'}}
    $source=Get-Value $proposal 'source';if(-not(Test-Shape $source @('kind','metadataSha256','responseSha256','toolCallIndex'))){Add-UnknownGate 'ProposalSourceShape'}
    elseif([string](Get-Value $source 'kind') -cne 'ollama-tool-call' -or [string](Get-Value $source 'metadataSha256') -notmatch '^[a-fA-F0-9]{64}$' -or [string](Get-Value $source 'responseSha256') -notmatch '^[a-fA-F0-9]{64}$' -or -not(Test-Integer (Get-Value $source 'toolCallIndex'))){Add-UnknownGate 'ProposalSource'}
    $tool=Get-Value $proposal 'tool';if(-not(Test-Shape $tool @('name','arguments'))){Add-UnknownGate 'ToolShape'}elseif([string](Get-Value $tool 'name') -cne 'read_file_slice'){Add-UnknownGate 'ToolName'}
    $arguments=Get-Value $tool 'arguments';if(-not(Test-Shape $arguments @('path','offsetBytes','maximumBytes'))){Add-UnknownGate 'ToolArgumentsShape'}else{$targetPath=[string](Get-Value $arguments 'path');$offsetValue=Get-Value $arguments 'offsetBytes';$sliceValue=Get-Value $arguments 'maximumBytes';if(-not(Test-Integer $offsetValue)-or [int64]$offsetValue -lt 0){Add-UnknownGate 'ToolOffset'}else{$offsetBytes=[int64]$offsetValue};if(-not(Test-Integer $sliceValue)-or [int64]$sliceValue -lt 1 -or [int64]$sliceValue -gt $MaximumSliceBytes){Add-UnknownGate 'ToolMaximumBytes'}else{$sliceBytes=[int64]$sliceValue}}
}

$approvalEvidence=Read-JsonEvidence -Path $ApprovalPath -ExpectedHash $ExpectedApprovalSha256 -MissingGate 'ApprovalPresent' -HashGate 'ApprovalSha256' -JsonGate 'ApprovalJson'
if($approvalEvidence){
    $approval=$approvalEvidence.Value;$approvalSha256=$approvalEvidence.Snapshot.Sha256
    if(-not(Test-Shape $approval @('schemaVersion','approvalId','createdAt','expiresAt','decision','proposalSha256','allowedRoot','target'))){Add-UnknownGate 'ApprovalShape'}
    if([string](Get-Value $approval 'schemaVersion') -cne '1.0'){Add-UnknownGate 'ApprovalSchema'}
    if([string](Get-Value $approval 'decision') -cne 'Approved'){Add-UnknownGate 'ApprovalDecision'}
    if($proposalSha256 -and [string](Get-Value $approval 'proposalSha256') -ine $proposalSha256){Add-ConflictGate 'ApprovalProposalBinding'}
    $approvalRoot=Get-NormalizedPath -Path ([string](Get-Value $approval 'allowedRoot'))
    if(-not $approvalRoot){Add-UnknownGate 'ApprovalRoot'}elseif($rootResolved -and $approvalRoot -ine $rootResolved){Add-ConflictGate 'ApprovalRootBinding'}
    try{$approvalCreated=Convert-EvidenceTime -Value (Get-Value $approval 'createdAt');$approvalExpires=Convert-EvidenceTime -Value (Get-Value $approval 'expiresAt')}catch{Add-UnknownGate 'ApprovalTime'}
    if($approvalCreated -and $approvalExpires -and $approvalExpires -le $approvalCreated){Add-UnknownGate 'ApprovalWindow'}
    $approvedTarget=Get-Value $approval 'target';if(-not(Test-Shape $approvedTarget @('path','sha256','bytes'))){Add-UnknownGate 'ApprovalTargetShape'}else{$approvedTargetPath=Get-NormalizedPath -Path ([string](Get-Value $approvedTarget 'path'));$normalizedTargetPath=Get-NormalizedPath -Path $targetPath;if(-not $approvedTargetPath){Add-UnknownGate 'ApprovalTargetPath'}elseif($normalizedTargetPath -and $approvedTargetPath -ine $normalizedTargetPath){Add-ConflictGate 'ApprovalTargetBinding'};$targetSha256=[string](Get-Value $approvedTarget 'sha256');if($targetSha256 -notmatch '^[a-fA-F0-9]{64}$' -or -not(Test-Integer (Get-Value $approvedTarget 'bytes')) -or [int64](Get-Value $approvedTarget 'bytes') -lt 0){Add-UnknownGate 'ApprovalTargetEvidence'}}
}

if($targetPath -and $rootResolved){if(-not(Test-FullyQualifiedPath -Path $targetPath)){Add-ConflictGate 'TargetPathAbsolute'}elseif(-not(Test-PathWithinRoot -Path $targetPath -Root $rootResolved)){Add-ConflictGate 'TargetWithinRoot'}elseif(-not(Test-PathChain -Path $targetPath -Root $rootResolved)){Add-ConflictGate 'TargetReparseSafe'}elseif(-not(Test-Path -LiteralPath $targetPath -PathType Leaf)){Add-UnknownGate 'TargetExists'}}

$observationEvidence=$null
if($ObservationPath -or $ExpectedObservationSha256){$observationEvidence=Read-JsonEvidence -Path $ObservationPath -ExpectedHash $ExpectedObservationSha256 -MissingGate 'ObservationPresent' -HashGate 'ObservationSha256' -JsonGate 'ObservationJson'}elseif($RequireObservation){Add-UnknownGate 'ObservationPresent'}
if($observationEvidence){
    $observation=$observationEvidence.Value
    if(-not(Test-Shape $observation @('schemaVersion','observationId','createdAt','state','proposalSha256','approvalSha256','target','slice','effects'))){Add-UnknownGate 'ObservationShape'}
    if([string](Get-Value $observation 'schemaVersion') -cne '1.0' -or [string](Get-Value $observation 'state') -cne 'SUCCEEDED'){Add-UnknownGate 'ObservationState'}
    if($proposalSha256 -and [string](Get-Value $observation 'proposalSha256') -ine $proposalSha256){Add-ConflictGate 'ObservationProposalBinding'}
    if($approvalSha256 -and [string](Get-Value $observation 'approvalSha256') -ine $approvalSha256){Add-ConflictGate 'ObservationApprovalBinding'}
    try{$observedAt=Convert-EvidenceTime -Value (Get-Value $observation 'createdAt')}catch{Add-UnknownGate 'ObservationCreatedAt';$observedAt=$null}
    if($observedAt -and $approvalCreated -and $observedAt -lt $approvalCreated){Add-ConflictGate 'ObservationApprovalTime'}
    if($observedAt -and $approvalExpires -and $observedAt -gt $approvalExpires){Add-ConflictGate 'ObservationApprovalExpiry'}
    $observedTarget=Get-Value $observation 'target';if(-not(Test-Shape $observedTarget @('path','sha256','bytes'))){Add-UnknownGate 'ObservationTargetShape'}else{$observedTargetPath=Get-NormalizedPath -Path ([string](Get-Value $observedTarget 'path'));$normalizedTargetPath=Get-NormalizedPath -Path $targetPath;if(-not $observedTargetPath -or -not(Test-Integer (Get-Value $observedTarget 'bytes'))){Add-UnknownGate 'ObservationTargetEvidence'}elseif(($normalizedTargetPath -and $observedTargetPath -ine $normalizedTargetPath) -or ($targetSha256 -and [string](Get-Value $observedTarget 'sha256') -ine $targetSha256) -or ($approval -and [int64](Get-Value $observedTarget 'bytes') -ne [int64](Get-Value (Get-Value $approval 'target') 'bytes' -1))){Add-ConflictGate 'ObservationTargetBinding'}}
    $effects=Get-Value $observation 'effects';if(-not(Test-Shape $effects @('toolExecutionPerformed','targetWritePerformed','networkPerformed','processPerformed','transportPerformed'))){Add-UnknownGate 'ObservationEffectsShape'}elseif(-not(Test-ExactBoolean -Value (Get-Value $effects 'targetWritePerformed') -Expected $false)-or -not(Test-ExactBoolean -Value (Get-Value $effects 'networkPerformed') -Expected $false)-or -not(Test-ExactBoolean -Value (Get-Value $effects 'processPerformed') -Expected $false)-or -not(Test-ExactBoolean -Value (Get-Value $effects 'transportPerformed') -Expected $false)-or -not(Test-ExactBoolean -Value (Get-Value $effects 'toolExecutionPerformed') -Expected $true)){Add-ConflictGate 'ObservationEffects'}
    $slice=Get-Value $observation 'slice';if(-not(Test-Shape $slice @('path','offsetBytes','bytes','sha256'))){Add-UnknownGate 'ObservationSliceShape'}else{$slicePath=[string](Get-Value $slice 'path');if(-not(Test-Integer (Get-Value $slice 'offsetBytes')) -or -not(Test-Integer (Get-Value $slice 'bytes')) -or [string](Get-Value $slice 'sha256') -notmatch '^[a-fA-F0-9]{64}$'){Add-UnknownGate 'ObservationSliceEvidence'}elseif([int64](Get-Value $slice 'offsetBytes') -ne $offsetBytes -or [int64](Get-Value $slice 'bytes') -gt $sliceBytes){Add-ConflictGate 'ObservationSliceBinding'}elseif($evidenceRootResolved -and (-not(Test-FullyQualifiedPath -Path $slicePath) -or -not(Test-PathWithinRoot -Path $slicePath -Root $evidenceRootResolved) -or -not(Test-PathChain -Path $slicePath -Root $evidenceRootResolved))){Add-ConflictGate 'SliceWithinEvidenceRoot'}elseif($evidenceRootResolved -and -not(Test-Path -LiteralPath $slicePath -PathType Leaf)){Add-UnknownGate 'SlicePresent'}elseif($evidenceRootResolved){try{$sliceSnapshot=Read-Snapshot -LiteralPath $slicePath -MaximumBytes $MaximumSliceBytes}catch{Add-UnknownGate 'SliceReadable';$sliceSnapshot=$null};if($sliceSnapshot -and ($sliceSnapshot.Sha256 -ne ([string](Get-Value $slice 'sha256')).ToLowerInvariant() -or $sliceSnapshot.Length -ne [int64](Get-Value $slice 'bytes' -1))){Add-ConflictGate 'SliceEvidence'}}}
}elseif(-not $RequireObservation -and $proposal -and $approval -and $targetPath -and $targetSha256 -and $unknownGates.Count -eq 0 -and $conflictGates.Count -eq 0){
    if($ReferenceTimeUtc.ToUniversalTime() -gt $approvalExpires.ToUniversalTime()){Add-UnknownGate 'ApprovalFreshness'}
    else{try{$targetSnapshot=Read-Snapshot -LiteralPath $targetPath -MaximumBytes $MaximumTargetBytes}catch{Add-UnknownGate 'TargetReadable';$targetSnapshot=$null};if($targetSnapshot -and ($targetSnapshot.Sha256 -ne $targetSha256.ToLowerInvariant() -or $targetSnapshot.Length -ne [int64](Get-Value (Get-Value $approval 'target') 'bytes' -1))){Add-ConflictGate 'TargetEvidence'}}
}

$state=if($conflictGates.Count -gt 0){'CONFLICT'}elseif($unknownGates.Count -gt 0){'UNKNOWN'}elseif($observation){'SUCCEEDED'}else{'READY'}
$failedGates=@($conflictGates)+@($unknownGates)
$result=[pscustomobject][ordered]@{SchemaVersion='1.0';State=$state;Eligible=$state -in @('READY','SUCCEEDED');FailedGates=$failedGates;ReferenceTimeUtc=$ReferenceTimeUtc.ToUniversalTime().ToString('o');ProposalCreatedAt=if($proposalCreated){$proposalCreated.ToUniversalTime().ToString('o')}else{$null};ApprovalExpiresAt=if($approvalExpires){$approvalExpires.ToUniversalTime().ToString('o')}else{$null};ProposalSha256=$proposalSha256;ApprovalSha256=$approvalSha256;TargetPath=$targetPath;TargetSha256=$targetSha256;OffsetBytes=$offsetBytes;MaximumBytes=$sliceBytes;AllowedRoot=$rootResolved;AllowedEvidenceRoot=$evidenceRootResolved;ExecutionPerformed=$false;TargetWritePerformed=$false;TransportPerformed=$false}
if($AsJson){$result|ConvertTo-Json -Depth 6 -Compress}else{$result}
if(-not $result.Eligible -and -not $NoThrow){throw "Read-only tool chain is $state`: $($failedGates -join ', ')."}
