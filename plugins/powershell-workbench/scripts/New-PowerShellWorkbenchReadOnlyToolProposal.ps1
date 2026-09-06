[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MetadataPath,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedMetadataSha256,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedResponseSha256,
    [Parameter(Mandatory)][string]$ExpectedModelId,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedModelDigest,
    [Parameter(Mandatory)][datetimeoffset]$CreatedAt,
    [ValidateRange(0,1024)][int]$ToolCallIndex = 0,
    [ValidateRange(1,1048576)][int]$MaximumSliceBytes = 65536,
    [ValidateRange(1024,10485760)][long]$MaximumEvidenceBytes = 1048576,
    [ValidateRange(1024,1073741824)][long]$MaximumResponseBytes = 16777216,
    [Parameter(Mandatory)][string]$AllowedEvidenceRoot,
    [Parameter(Mandatory)][string]$OutputPath,
    [switch]$AcceptUnverifiedModelDigest,
    [switch]$AllowFixtureEvidence,
    [switch]$Write,
    [switch]$NoThrow
)

Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$utf8=New-Object Text.UTF8Encoding($false)
$validator=Join-Path $PSScriptRoot 'Test-PowerShellWorkbenchOllamaEvidence.ps1'
function Get-Value { param($Object,[string]$Name,$Default=$null) if($null -eq $Object){return $Default};$property=$Object.PSObject.Properties[$Name];if($null -eq $property){return $Default};$property.Value }
function Test-Shape { param($Object,[string[]]$Expected) if($null -eq $Object){return $false};$names=@($Object.PSObject.Properties.Name);@($names|Where-Object{$Expected -cnotcontains $_}).Count -eq 0 -and @($Expected|Where-Object{$names -cnotcontains $_}).Count -eq 0 }
function Test-Integer { param($Value) $Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64] }
function Get-BytesSha256 { param([byte[]]$Bytes) $algorithm=[Security.Cryptography.SHA256]::Create();try{([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant()}finally{$algorithm.Dispose()} }
function Read-Snapshot { param([string]$LiteralPath,[long]$MaximumBytes) $resolved=(Resolve-Path -LiteralPath $LiteralPath).Path;$stream=[IO.File]::Open($resolved,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);try{$memory=[IO.MemoryStream]::new();try{$buffer=New-Object byte[] 8192;while(($count=$stream.Read($buffer,0,$buffer.Length))-gt 0){if($memory.Length -gt ($MaximumBytes-$count)){throw 'Evidence exceeds its byte limit.'};$memory.Write($buffer,0,$count)};$bytes=$memory.ToArray()}finally{$memory.Dispose()}}finally{$stream.Dispose()};$decoder=New-Object Text.UTF8Encoding($false,$true);[pscustomobject]@{Path=$resolved;Bytes=$bytes;Sha256=Get-BytesSha256 -Bytes $bytes;Text=$decoder.GetString($bytes)} }
function Get-NormalizedPath { param([string]$Path) if([string]::IsNullOrWhiteSpace($Path)-or -not[IO.Path]::IsPathRooted($Path)-or $Path -match '^[A-Za-z]:(?:$|[^\\/])' -or $Path -match '^[\\/](?![\\/])'){return $null};try{[IO.Path]::GetFullPath($Path).TrimEnd('\','/')}catch{return $null} }
function Test-PathChain { param([string]$Path,[string]$Root) $current=[IO.Path]::GetFullPath($Path);while($current){if(Test-Path -LiteralPath $current){if((Get-Item -LiteralPath $current).Attributes -band [IO.FileAttributes]::ReparsePoint){return $false}};if($current -ieq $Root){return $true};$parent=Split-Path -Parent $current;if(-not $parent -or $parent -ieq $current){break};$current=$parent.TrimEnd('\','/')};$false }
function Stop-Proposal { param([string[]]$Gates,[string]$State='CONFLICT') $result=[pscustomobject][ordered]@{SchemaVersion='1.0';State=$State;Eligible=$false;FailedGates=$Gates;WritePerformed=$false;ToolExecutionPerformed=$false;TransportPerformed=$false};if(-not $NoThrow){throw "Read-only tool proposal is $State`: $($Gates -join ', ')."};$result }

$validationParameters=@{MetadataPath=$MetadataPath;ExpectedMetadataSha256=$ExpectedMetadataSha256;ExpectedModelId=$ExpectedModelId;ExpectedModelDigest=$ExpectedModelDigest;ReadFileSliceMaximumBytes=$MaximumSliceBytes;ExpectReadFileSliceProposal=$true;NoThrow=$true}
if($AcceptUnverifiedModelDigest){$validationParameters.AcceptUnverifiedModelDigest=$true}
if($AllowFixtureEvidence){$validationParameters.AllowFixtureEvidence=$true}
$validated=& $validator @validationParameters
if(-not $validated.Passed){return (Stop-Proposal -Gates @($validated.FailedGates|ForEach-Object{"OllamaEvidence.$_"}))}
$metadataSnapshot=Read-Snapshot -LiteralPath $MetadataPath -MaximumBytes $MaximumEvidenceBytes
if($metadataSnapshot.Sha256 -ne $ExpectedMetadataSha256.ToLowerInvariant()){return (Stop-Proposal -Gates @('MetadataSha256'))}
$metadata=$metadataSnapshot.Text|ConvertFrom-Json
$artifacts=Get-Value $metadata 'artifacts';$responsePath=[string](Get-Value $artifacts 'responsePath')
$responseSnapshot=Read-Snapshot -LiteralPath $responsePath -MaximumBytes $MaximumResponseBytes
if($responseSnapshot.Sha256 -ne $ExpectedResponseSha256.ToLowerInvariant() -or $responseSnapshot.Sha256 -ne ([string](Get-Value $artifacts 'responseSha256')).ToLowerInvariant()){return (Stop-Proposal -Gates @('ResponseSha256'))}
$response=$responseSnapshot.Text|ConvertFrom-Json;$message=Get-Value $response 'message';$toolCalls=@(Get-Value -Object $message -Name 'tool_calls' -Default @())
if($ToolCallIndex -ge $toolCalls.Count){return (Stop-Proposal -Gates @('ToolCallIndex'))}
$function=Get-Value $toolCalls[$ToolCallIndex] 'function';$arguments=Get-Value $function 'arguments'
if([string](Get-Value $function 'name') -cne 'read_file_slice'){return (Stop-Proposal -Gates @('ToolName'))}
if(-not(Test-Shape -Object $arguments -Expected @('path','offsetBytes','maximumBytes'))){return (Stop-Proposal -Gates @('ToolArgumentsShape'))}
$offset=Get-Value $arguments 'offsetBytes';$maximum=Get-Value $arguments 'maximumBytes';$targetPath=[string](Get-Value $arguments 'path')
if(-not(Test-Integer -Value $offset)-or [int64]$offset -lt 0){return (Stop-Proposal -Gates @('ToolOffset'))}
if(-not(Test-Integer -Value $maximum)-or [int64]$maximum -lt 1 -or [int64]$maximum -gt $MaximumSliceBytes){return (Stop-Proposal -Gates @('ToolMaximumBytes'))}
if(-not(Get-NormalizedPath -Path $targetPath)){return (Stop-Proposal -Gates @('ToolPathAbsolute'))}
$created=$CreatedAt.ToUniversalTime().ToString('o');$seed="$($metadataSnapshot.Sha256)|$($responseSnapshot.Sha256)|$ToolCallIndex|$created|$targetPath|$offset|$maximum";$proposalId=Get-BytesSha256 -Bytes $utf8.GetBytes($seed)
$proposal=[ordered]@{schemaVersion='1.0';proposalId=$proposalId;createdAt=$created;source=[ordered]@{kind='ollama-tool-call';metadataSha256=$metadataSnapshot.Sha256;responseSha256=$responseSnapshot.Sha256;toolCallIndex=$ToolCallIndex};tool=[ordered]@{name='read_file_slice';arguments=[ordered]@{path=$targetPath;offsetBytes=[int64]$offset;maximumBytes=[int64]$maximum}}}
$proposalBytes=$utf8.GetBytes(($proposal|ConvertTo-Json -Depth 10 -Compress));$proposalSha=Get-BytesSha256 -Bytes $proposalBytes
$evidenceRoot=Get-NormalizedPath -Path $AllowedEvidenceRoot;$normalizedOutput=Get-NormalizedPath -Path $OutputPath
if(-not $evidenceRoot -or $evidenceRoot -ieq [IO.Path]::GetPathRoot($evidenceRoot) -or -not(Test-Path -LiteralPath $evidenceRoot -PathType Container)){return (Stop-Proposal -Gates @('AllowedEvidenceRoot'))}
if(-not $normalizedOutput -or -not $normalizedOutput.StartsWith($evidenceRoot+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){return (Stop-Proposal -Gates @('OutputPathWithinEvidenceRoot'))}
if(-not(Test-PathChain -Path $normalizedOutput -Root $evidenceRoot)){return (Stop-Proposal -Gates @('OutputPathReparseSafe'))}
$parent=Split-Path -Parent $normalizedOutput;if(-not(Test-Path -LiteralPath $parent -PathType Container)){return (Stop-Proposal -Gates @('OutputParentExists') -State 'UNKNOWN')}
if($Write){if(-not(Test-PathChain -Path $normalizedOutput -Root $evidenceRoot)){return (Stop-Proposal -Gates @('OutputPathReparseSafe'))};$stream=[IO.File]::Open($normalizedOutput,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read);try{$stream.Write($proposalBytes,0,$proposalBytes.Length)}finally{$stream.Dispose()}}
[pscustomobject][ordered]@{SchemaVersion='1.0';State=if($Write){'WRITTEN'}else{'PREVIEW'};Eligible=$true;FailedGates=@();ProposalPath=$normalizedOutput;ProposalSha256=$proposalSha;ProposalJson=$utf8.GetString($proposalBytes);WritePerformed=[bool]$Write;ToolExecutionPerformed=$false;TransportPerformed=$false}
