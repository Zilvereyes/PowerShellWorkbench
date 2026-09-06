[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProposalPath,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedProposalSha256,
    [Parameter(Mandatory)][string]$ApprovalPath,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedApprovalSha256,
    [Parameter(Mandatory)][string]$AllowedRoot,
    [Parameter(Mandatory)][datetimeoffset]$ReferenceTimeUtc,
    [Parameter(Mandatory)][string]$AllowedEvidenceRoot,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidateRange(1,1440)][int]$MaximumProposalAgeMinutes = 30,
    [ValidateRange(1,1048576)][int]$MaximumSliceBytes = 65536,
    [ValidateRange(1024,1073741824)][long]$MaximumTargetBytes = 67108864,
    [switch]$Execute,
    [switch]$NoThrow
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$resolver = Join-Path $PSScriptRoot 'Resolve-PowerShellWorkbenchReadOnlyToolChain.ps1'
$decision = & $resolver -ProposalPath $ProposalPath -ExpectedProposalSha256 $ExpectedProposalSha256 `
    -ApprovalPath $ApprovalPath -ExpectedApprovalSha256 $ExpectedApprovalSha256 -AllowedRoot $AllowedRoot `
    -ReferenceTimeUtc $ReferenceTimeUtc -MaximumProposalAgeMinutes $MaximumProposalAgeMinutes `
    -MaximumSliceBytes $MaximumSliceBytes -MaximumTargetBytes $MaximumTargetBytes -NoThrow
if($decision.State -ne 'READY'){
    if(-not $NoThrow){throw "Read-only tool execution is $($decision.State): $($decision.FailedGates -join ', ')."}
    return $decision
}
function Read-Snapshot {
    param([string]$LiteralPath,[long]$MaximumBytes)
    $resolved=(Resolve-Path -LiteralPath $LiteralPath).Path
    $stream=[IO.File]::Open($resolved,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{$memory=[IO.MemoryStream]::new();try{$buffer=New-Object byte[] 8192;while(($count=$stream.Read($buffer,0,$buffer.Length))-gt 0){if($memory.Length -gt ($MaximumBytes-$count)){throw 'Snapshot exceeds its byte limit.'};$memory.Write($buffer,0,$count)};$bytes=$memory.ToArray()}finally{$memory.Dispose()}}finally{$stream.Dispose()}
    $algorithm=[Security.Cryptography.SHA256]::Create();try{$hash=([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()}finally{$algorithm.Dispose()}
    [pscustomobject]@{Path=$resolved;Bytes=$bytes;Length=$bytes.Length;Sha256=$hash}
}
function Get-Value { param($Object,[string]$Name) $Object.PSObject.Properties[$Name].Value }
function Write-NewByteFile { param([string]$LiteralPath,[byte[]]$Bytes) $stream=[IO.File]::Open($LiteralPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read);try{$stream.Write($Bytes,0,$Bytes.Length)}finally{$stream.Dispose()} }
function Get-TextSha256 { param([string]$Text) $algorithm=[Security.Cryptography.SHA256]::Create();try{$bytes=[Text.UTF8Encoding]::new($false).GetBytes($Text);([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()}finally{$algorithm.Dispose()} }
function Test-FullyQualifiedPath { param([string]$Path) if([string]::IsNullOrWhiteSpace($Path)-or -not[IO.Path]::IsPathRooted($Path)){return $false};if($Path -match '^[A-Za-z]:(?:$|[^\\/])' -or $Path -match '^[\\/](?![\\/])'){return $false};$true }
function Test-PathChain { param([string]$Path,[string]$Root) $rootPath=[IO.Path]::GetFullPath($Root).TrimEnd('\','/');$current=[IO.Path]::GetFullPath($Path);while($current){if(Test-Path -LiteralPath $current){if((Get-Item -LiteralPath $current).Attributes -band [IO.FileAttributes]::ReparsePoint){return $false}};if($current -ieq $rootPath){return $true};$parent=Split-Path -Parent $current;if(-not $parent -or $parent -ieq $current){break};$current=$parent.TrimEnd('\','/')};$false }

$evidenceRoot=$null;$outputResolvedCandidate=$null;$outputGates=New-Object Collections.Generic.List[string]
try{if(Test-FullyQualifiedPath -Path $AllowedEvidenceRoot){$evidenceRoot=[IO.Path]::GetFullPath($AllowedEvidenceRoot).TrimEnd('\','/')}}catch{$evidenceRoot=$null}
try{if(Test-FullyQualifiedPath -Path $OutputDirectory){$outputResolvedCandidate=[IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\','/')}}catch{$outputResolvedCandidate=$null}
if(-not $evidenceRoot){$outputGates.Add('AllowedEvidenceRootAbsolute')}
elseif($evidenceRoot -ieq [IO.Path]::GetPathRoot($evidenceRoot)){$outputGates.Add('AllowedEvidenceRootScoped')}
elseif(-not(Test-Path -LiteralPath $evidenceRoot -PathType Container)){$outputGates.Add('AllowedEvidenceRootExists')}
elseif(-not(Test-PathChain -Path $evidenceRoot -Root $evidenceRoot)){$outputGates.Add('AllowedEvidenceRootReparseSafe')}
if(-not $outputResolvedCandidate){$outputGates.Add('OutputDirectoryAbsolute')}
elseif($evidenceRoot -and -not $outputResolvedCandidate.StartsWith($evidenceRoot+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){$outputGates.Add('OutputDirectoryWithinEvidenceRoot')}
elseif(-not(Test-Path -LiteralPath $outputResolvedCandidate -PathType Container)){$outputGates.Add('OutputDirectoryExists')}
elseif($evidenceRoot -and -not(Test-PathChain -Path $outputResolvedCandidate -Root $evidenceRoot)){$outputGates.Add('OutputDirectoryReparseSafe')}
if($outputGates.Count -gt 0){$result=[pscustomobject][ordered]@{SchemaVersion='1.0';State='CONFLICT';Eligible=$false;FailedGates=@($outputGates);ExecutionPerformed=$false;TargetWritePerformed=$false;TransportPerformed=$false};if(-not $NoThrow){throw "Read-only tool output boundary is CONFLICT: $($outputGates -join ', ')."};return $result}
if(-not $Execute){return $decision}

$proposalSnapshot=Read-Snapshot -LiteralPath $ProposalPath -MaximumBytes 1048576
$approvalSnapshot=Read-Snapshot -LiteralPath $ApprovalPath -MaximumBytes 1048576
if($proposalSnapshot.Sha256 -ne $ExpectedProposalSha256.ToLowerInvariant() -or $approvalSnapshot.Sha256 -ne $ExpectedApprovalSha256.ToLowerInvariant()){
    $result=[pscustomobject][ordered]@{SchemaVersion='1.0';State='CONFLICT';Eligible=$false;FailedGates=@('ExecutionEvidenceDrift');ExecutionPerformed=$false;TargetWritePerformed=$false;TransportPerformed=$false}
    if(-not $NoThrow){throw 'Read-only tool evidence drifted after preflight.'};return $result
}
$decoder=New-Object Text.UTF8Encoding($false,$true)
$proposal=$decoder.GetString($proposalSnapshot.Bytes)|ConvertFrom-Json
$approval=$decoder.GetString($approvalSnapshot.Bytes)|ConvertFrom-Json
$tool=Get-Value $proposal 'tool';$arguments=Get-Value $tool 'arguments';$target=Get-Value $approval 'target'
$targetSnapshot=Read-Snapshot -LiteralPath ([string](Get-Value $arguments 'path')) -MaximumBytes $MaximumTargetBytes
$targetRoot=[IO.Path]::GetFullPath($AllowedRoot).TrimEnd('\','/')
if(-not $targetSnapshot.Path.StartsWith($targetRoot+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or -not(Test-PathChain -Path $targetSnapshot.Path -Root $targetRoot)){
    $result=[pscustomobject][ordered]@{SchemaVersion='1.0';State='CONFLICT';Eligible=$false;FailedGates=@('TargetBoundaryDrift');ExecutionPerformed=$false;TargetWritePerformed=$false;TransportPerformed=$false}
    if(-not $NoThrow){throw 'Read-only tool target boundary drifted after preflight.'};return $result
}
if($targetSnapshot.Sha256 -ne [string](Get-Value $target 'sha256') -or $targetSnapshot.Length -ne [int64](Get-Value $target 'bytes')){
    $result=[pscustomobject][ordered]@{SchemaVersion='1.0';State='CONFLICT';Eligible=$false;FailedGates=@('TargetEvidence');ExecutionPerformed=$false;TargetWritePerformed=$false;TransportPerformed=$false}
    if(-not $NoThrow){throw 'Read-only tool target drifted after approval.'};return $result
}
$offset=[int64](Get-Value $arguments 'offsetBytes');$maximum=[int64](Get-Value $arguments 'maximumBytes')
if($offset -gt $targetSnapshot.Length){$result=[pscustomobject][ordered]@{SchemaVersion='1.0';State='CONFLICT';Eligible=$false;FailedGates=@('TargetOffset');ExecutionPerformed=$false;TargetWritePerformed=$false;TransportPerformed=$false};if(-not $NoThrow){throw 'Read-only tool offset exceeds the approved target length.'};return $result}
$available=$targetSnapshot.Length-$offset;$length=[int][math]::Min($available,$maximum);$sliceBytes=New-Object byte[] $length;if($length -gt 0){[Array]::Copy($targetSnapshot.Bytes,$offset,$sliceBytes,0,$length)}
$sliceSha256=if($length -eq 0){Get-TextSha256 -Text ''}else{$algorithm=[Security.Cryptography.SHA256]::Create();try{([BitConverter]::ToString($algorithm.ComputeHash($sliceBytes))).Replace('-','').ToLowerInvariant()}finally{$algorithm.Dispose()}}
$createdAt=$ReferenceTimeUtc.ToUniversalTime().ToString('o')
$observationId=Get-TextSha256 -Text ($proposalSnapshot.Sha256+'|'+$approvalSnapshot.Sha256+'|'+$targetSnapshot.Sha256+'|'+$sliceSha256+'|'+$createdAt)
$outputResolved=(Resolve-Path -LiteralPath $OutputDirectory).Path
$slicePath=Join-Path $outputResolved "$observationId.slice.bin";$observationPath=Join-Path $outputResolved "$observationId.observation.json"
if(-not(Test-PathChain -Path $slicePath -Root $evidenceRoot)){throw 'Read-only tool output path changed after preflight.'}
Write-NewByteFile -LiteralPath $slicePath -Bytes $sliceBytes
$observation=[ordered]@{schemaVersion='1.0';observationId=$observationId;createdAt=$createdAt;state='SUCCEEDED';proposalSha256=$proposalSnapshot.Sha256;approvalSha256=$approvalSnapshot.Sha256;target=[ordered]@{path=$targetSnapshot.Path;sha256=$targetSnapshot.Sha256;bytes=$targetSnapshot.Length};slice=[ordered]@{path=$slicePath;offsetBytes=$offset;bytes=$sliceBytes.Length;sha256=$sliceSha256};effects=[ordered]@{toolExecutionPerformed=$true;targetWritePerformed=$false;networkPerformed=$false;processPerformed=$false;transportPerformed=$false}}
$utf8=New-Object Text.UTF8Encoding($false);$observationBytes=$utf8.GetBytes(($observation|ConvertTo-Json -Depth 8))
try{Write-NewByteFile -LiteralPath $observationPath -Bytes $observationBytes}catch{if(Test-Path -LiteralPath $slicePath){Remove-Item -LiteralPath $slicePath -Force};throw}
[pscustomobject][ordered]@{SchemaVersion='1.0';State='SUCCEEDED';Eligible=$true;FailedGates=@();ProposalSha256=$proposalSnapshot.Sha256;ApprovalSha256=$approvalSnapshot.Sha256;ObservationPath=$observationPath;ObservationSha256=(Get-TextSha256 -Text ($utf8.GetString($observationBytes)));SlicePath=$slicePath;SliceSha256=$sliceSha256;ExecutionPerformed=$true;TargetWritePerformed=$false;NetworkPerformed=$false;ProcessPerformed=$false;TransportPerformed=$false}
