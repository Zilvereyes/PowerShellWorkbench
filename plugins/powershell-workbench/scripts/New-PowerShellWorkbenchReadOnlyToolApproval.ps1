[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProposalPath,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedProposalSha256,
    [Parameter(Mandatory)][string]$AllowedRoot,
    [Parameter(Mandatory)][datetimeoffset]$CreatedAt,
    [Parameter(Mandatory)][datetimeoffset]$ExpiresAt,
    [ValidateRange(1,1440)][int]$MaximumProposalAgeMinutes = 30,
    [ValidateRange(1,1048576)][int]$MaximumSliceBytes = 65536,
    [ValidateRange(1024,1073741824)][long]$MaximumTargetBytes = 67108864,
    [Parameter(Mandatory)][string]$AllowedEvidenceRoot,
    [Parameter(Mandatory)][string]$OutputPath,
    [switch]$Approve,
    [switch]$NoThrow
)

Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$suppressThrow=[bool]$NoThrow
$utf8=New-Object Text.UTF8Encoding($false)
$resolver=Join-Path $PSScriptRoot 'Resolve-PowerShellWorkbenchReadOnlyToolChain.ps1'
function Get-BytesSha256 { param([byte[]]$Bytes) $algorithm=[Security.Cryptography.SHA256]::Create();try{([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant()}finally{$algorithm.Dispose()} }
function Read-Snapshot { param([string]$LiteralPath,[long]$MaximumBytes) $resolved=(Resolve-Path -LiteralPath $LiteralPath).Path;$stream=[IO.File]::Open($resolved,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);try{$memory=[IO.MemoryStream]::new();try{$buffer=New-Object byte[] 8192;while(($count=$stream.Read($buffer,0,$buffer.Length))-gt 0){if($memory.Length -gt ($MaximumBytes-$count)){throw 'Target exceeds its byte limit.'};$memory.Write($buffer,0,$count)};$bytes=$memory.ToArray()}finally{$memory.Dispose()}}finally{$stream.Dispose()};[pscustomobject]@{Path=$resolved;Bytes=$bytes.Length;Sha256=Get-BytesSha256 -Bytes $bytes} }
function Get-NormalizedPath { param([string]$Path) if([string]::IsNullOrWhiteSpace($Path)-or -not[IO.Path]::IsPathRooted($Path)-or $Path -match '^[A-Za-z]:(?:$|[^\\/])' -or $Path -match '^[\\/](?![\\/])'){return $null};try{[IO.Path]::GetFullPath($Path).TrimEnd('\','/')}catch{return $null} }
function Test-PathChain { param([string]$Path,[string]$Root) $current=[IO.Path]::GetFullPath($Path);while($current){if(Test-Path -LiteralPath $current){if((Get-Item -LiteralPath $current).Attributes -band [IO.FileAttributes]::ReparsePoint){return $false}};if($current -ieq $Root){return $true};$parent=Split-Path -Parent $current;if(-not $parent -or $parent -ieq $current){break};$current=$parent.TrimEnd('\','/')};$false }
function Get-ApprovalFailure { param([string[]]$Gates,[string]$State='CONFLICT') $result=[pscustomobject][ordered]@{SchemaVersion='1.0';State=$State;Eligible=$false;FailedGates=$Gates;WritePerformed=$false;ToolExecutionPerformed=$false;TransportPerformed=$false};if(-not $suppressThrow){throw "Read-only tool approval is $State`: $($Gates -join ', ')."};$result }

if($ExpiresAt.ToUniversalTime() -le $CreatedAt.ToUniversalTime()){return (Get-ApprovalFailure -Gates @('ApprovalWindow') -State 'UNKNOWN')}
$missingApprovalPath=Join-Path ([IO.Path]::GetTempPath()) ('pwb-intentionally-missing-'+[guid]::NewGuid().ToString('N')+'.json')
$proposalDecision=& $resolver -ProposalPath $ProposalPath -ExpectedProposalSha256 $ExpectedProposalSha256 -ApprovalPath $missingApprovalPath -ExpectedApprovalSha256 ('0'*64) -AllowedRoot $AllowedRoot -ReferenceTimeUtc $CreatedAt -MaximumProposalAgeMinutes $MaximumProposalAgeMinutes -MaximumSliceBytes $MaximumSliceBytes -MaximumTargetBytes $MaximumTargetBytes -NoThrow
$proposalGates=@($proposalDecision.FailedGates|Where-Object{$_ -cne 'ApprovalPresent'})
if($proposalGates.Count -gt 0){return (Get-ApprovalFailure -Gates $proposalGates -State $proposalDecision.State)}
$approvedRoot=Get-NormalizedPath -Path $proposalDecision.AllowedRoot
if(-not $approvedRoot -or -not(Test-PathChain -Path $proposalDecision.TargetPath -Root $approvedRoot)){return (Get-ApprovalFailure -Gates @('TargetReparseSafe'))}
$targetSnapshot=Read-Snapshot -LiteralPath $proposalDecision.TargetPath -MaximumBytes $MaximumTargetBytes
if(-not $targetSnapshot.Path.StartsWith($approvedRoot+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or -not(Test-PathChain -Path $targetSnapshot.Path -Root $approvedRoot)){return (Get-ApprovalFailure -Gates @('TargetBoundaryDrift'))}
$created=$CreatedAt.ToUniversalTime().ToString('o');$expires=$ExpiresAt.ToUniversalTime().ToString('o');$seed="$($ExpectedProposalSha256.ToLowerInvariant())|$created|$expires|$($proposalDecision.AllowedRoot)|$($targetSnapshot.Path)|$($targetSnapshot.Sha256)|$($targetSnapshot.Bytes)";$approvalId=Get-BytesSha256 -Bytes $utf8.GetBytes($seed)
$approval=[ordered]@{schemaVersion='1.0';approvalId=$approvalId;createdAt=$created;expiresAt=$expires;decision='Approved';proposalSha256=$ExpectedProposalSha256.ToLowerInvariant();allowedRoot=$proposalDecision.AllowedRoot;target=[ordered]@{path=$targetSnapshot.Path;sha256=$targetSnapshot.Sha256;bytes=$targetSnapshot.Bytes}}
$approvalBytes=$utf8.GetBytes(($approval|ConvertTo-Json -Depth 8 -Compress));$approvalSha=Get-BytesSha256 -Bytes $approvalBytes
$evidenceRoot=Get-NormalizedPath -Path $AllowedEvidenceRoot;$normalizedOutput=Get-NormalizedPath -Path $OutputPath
if(-not $evidenceRoot -or $evidenceRoot -ieq [IO.Path]::GetPathRoot($evidenceRoot) -or -not(Test-Path -LiteralPath $evidenceRoot -PathType Container)){return (Get-ApprovalFailure -Gates @('AllowedEvidenceRoot'))}
if(-not $normalizedOutput -or -not $normalizedOutput.StartsWith($evidenceRoot+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){return (Get-ApprovalFailure -Gates @('OutputPathWithinEvidenceRoot'))}
if(-not(Test-PathChain -Path $normalizedOutput -Root $evidenceRoot)){return (Get-ApprovalFailure -Gates @('OutputPathReparseSafe'))}
$parent=Split-Path -Parent $normalizedOutput;if(-not(Test-Path -LiteralPath $parent -PathType Container)){return (Get-ApprovalFailure -Gates @('OutputParentExists') -State 'UNKNOWN')}
if($Approve){if(-not(Test-PathChain -Path $normalizedOutput -Root $evidenceRoot)){return (Get-ApprovalFailure -Gates @('OutputPathReparseSafe'))};$stream=[IO.File]::Open($normalizedOutput,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read);try{$stream.Write($approvalBytes,0,$approvalBytes.Length)}finally{$stream.Dispose()}}
[pscustomobject][ordered]@{SchemaVersion='1.0';State=if($Approve){'WRITTEN'}else{'PREVIEW'};Eligible=$true;FailedGates=@();ApprovalPath=$normalizedOutput;ApprovalSha256=$approvalSha;ApprovalJson=$utf8.GetString($approvalBytes);WritePerformed=[bool]$Approve;ToolExecutionPerformed=$false;TransportPerformed=$false}
