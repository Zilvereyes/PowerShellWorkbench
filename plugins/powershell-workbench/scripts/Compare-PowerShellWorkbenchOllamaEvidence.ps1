[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ManifestPath,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedManifestSha256,
    [Parameter(Mandatory)][string]$AllowedEvidenceRoot,
    [ValidateRange(2,16)][int]$MinimumCandidates = 2,
    [ValidateRange(1024,10485760)][long]$MaximumEvidenceBytes = 1048576,
    [ValidateRange(1024,1073741824)][long]$MaximumResponseBytes = 16777216,
    [switch]$AcceptUnverifiedModelDigest,
    [switch]$AllowFixtureEvidence,
    [switch]$NoThrow,
    [switch]$AsJson
)

Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$suppressThrow=[bool]$NoThrow
$evidenceByteLimit=$MaximumEvidenceBytes
$responseByteLimit=$MaximumResponseBytes
$unknownGates=New-Object Collections.Generic.List[string]
$conflictGates=New-Object Collections.Generic.List[string]
$utf8=New-Object Text.UTF8Encoding($false)
$validator=Join-Path $PSScriptRoot 'Test-PowerShellWorkbenchOllamaEvidence.ps1'

function Add-UnknownGate { param([string]$Gate) if(-not $unknownGates.Contains($Gate)){[void]$unknownGates.Add($Gate)} }
function Add-ConflictGate { param([string]$Gate) if(-not $conflictGates.Contains($Gate)){[void]$conflictGates.Add($Gate)} }
function Get-Value { param($Object,[string]$Name,$Default=$null) if($null -eq $Object){return $Default};$property=$Object.PSObject.Properties[$Name];if($null -eq $property){return $Default};$property.Value }
function Test-Shape { param($Object,[string[]]$Expected) if($null -eq $Object){return $false};$names=@($Object.PSObject.Properties.Name);@($names|Where-Object{$Expected -cnotcontains $_}).Count -eq 0 -and @($Expected|Where-Object{$names -cnotcontains $_}).Count -eq 0 }
function Test-Integer { param($Value) if($Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64]){return [int64]$Value -ge 0};if($Value -is [uint64]){return $Value -le [uint64][int64]::MaxValue};if($Value -is [single] -or $Value -is [double] -or $Value -is [decimal]){try{$number=[decimal]$Value;return $number -ge 0 -and $number -le [decimal][int64]::MaxValue -and [decimal]::Truncate($number) -eq $number}catch{return $false}};$false }
function Get-ByteSha256 { param([byte[]]$Bytes) $algorithm=[Security.Cryptography.SHA256]::Create();try{([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant()}finally{$algorithm.Dispose()} }
function Read-BoundedSnapshot { param([string]$LiteralPath,[long]$MaximumBytes) $resolved=(Resolve-Path -LiteralPath $LiteralPath).Path;$stream=[IO.File]::Open($resolved,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);try{$memory=[IO.MemoryStream]::new();try{$buffer=New-Object byte[] 8192;while(($count=$stream.Read($buffer,0,$buffer.Length))-gt 0){if($memory.Length -gt ($MaximumBytes-$count)){throw 'Evidence exceeds its byte limit.'};$memory.Write($buffer,0,$count)};$bytes=$memory.ToArray()}finally{$memory.Dispose()}}finally{$stream.Dispose()};$decoder=New-Object Text.UTF8Encoding($false,$true);[pscustomobject]@{Path=$resolved;Bytes=$bytes;Length=$bytes.Length;Sha256=Get-ByteSha256 -Bytes $bytes;Text=$decoder.GetString($bytes)} }
function Get-NormalizedPath { param([string]$Path) if([string]::IsNullOrWhiteSpace($Path)-or -not[IO.Path]::IsPathRooted($Path)-or $Path -match '^[A-Za-z]:(?:$|[^\\/])' -or $Path -match '^[\\/](?![\\/])'){return $null};try{[IO.Path]::GetFullPath($Path).TrimEnd('\','/')}catch{return $null} }
function Test-PathChain { param([string]$Path,[string]$Root) $current=[IO.Path]::GetFullPath($Path);while($current){if(Test-Path -LiteralPath $current){if((Get-Item -LiteralPath $current).Attributes -band [IO.FileAttributes]::ReparsePoint){return $false}};if($current -ieq $Root){return $true};$parent=Split-Path -Parent $current;if(-not $parent -or $parent -ieq $current){break};$current=$parent.TrimEnd('\','/')};$false }
function Test-EvidencePath { param([string]$Path,[string]$Root) $normalized=Get-NormalizedPath -Path $Path;if(-not $normalized){return $false};$normalized.StartsWith($Root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -and (Test-PathChain -Path $normalized -Root $Root) }
function Get-ConfigurationSha256 { param($Request) $options=Get-Value -Object $Request -Name 'options';$configuration=[ordered]@{stream=Get-Value -Object $Request -Name 'stream';think=Get-Value -Object $Request -Name 'think';keep_alive=[string](Get-Value -Object $Request -Name 'keep_alive');temperature=Get-Value -Object $options -Name 'temperature';num_predict=Get-Value -Object $options -Name 'num_predict';seed=Get-Value -Object $options -Name 'seed';tools=Get-Value -Object $Request -Name 'tools'};Get-ByteSha256 -Bytes $utf8.GetBytes(($configuration|ConvertTo-Json -Depth 12 -Compress)) }

$evidenceRoot=Get-NormalizedPath -Path $AllowedEvidenceRoot
if(-not $evidenceRoot -or $evidenceRoot -ieq [IO.Path]::GetPathRoot($evidenceRoot)){Add-ConflictGate 'AllowedEvidenceRootScoped'}
elseif(-not(Test-Path -LiteralPath $evidenceRoot -PathType Container)){Add-UnknownGate 'AllowedEvidenceRootExists'}
elseif(-not(Test-PathChain -Path $evidenceRoot -Root $evidenceRoot)){Add-ConflictGate 'AllowedEvidenceRootReparseSafe'}
$manifest=$null;$manifestSnapshot=$null
if($evidenceRoot -and -not(Test-EvidencePath -Path $ManifestPath -Root $evidenceRoot)){Add-ConflictGate 'ManifestWithinEvidenceRoot'}
elseif(-not(Test-Path -LiteralPath $ManifestPath -PathType Leaf)){Add-UnknownGate 'ManifestPresent'}
else{try{$manifestSnapshot=Read-BoundedSnapshot -LiteralPath $ManifestPath -MaximumBytes $evidenceByteLimit}catch{Add-UnknownGate 'ManifestReadable'};if($manifestSnapshot){if($manifestSnapshot.Sha256 -ne $ExpectedManifestSha256.ToLowerInvariant()){Add-ConflictGate 'ManifestSha256'}else{try{$manifest=$manifestSnapshot.Text|ConvertFrom-Json}catch{Add-UnknownGate 'ManifestJson'}}}}
$task=$null;$candidates=@();$expectedPromptSha=$null;$expectedAnswerSha=$null
if($manifest){
    if(-not(Test-Shape -Object $manifest -Expected @('schemaVersion','comparisonId','task','candidates'))){Add-UnknownGate 'ManifestShape'}
    if([string](Get-Value -Object $manifest -Name 'schemaVersion') -cne '1.0'){Add-UnknownGate 'ManifestSchema'}
    $task=Get-Value -Object $manifest -Name 'task';if(-not(Test-Shape -Object $task -Expected @('taskId','promptSha256','acceptance'))){Add-UnknownGate 'TaskShape'}
    else{$expectedPromptSha=[string](Get-Value -Object $task -Name 'promptSha256');$acceptance=Get-Value -Object $task -Name 'acceptance';if($expectedPromptSha -notmatch '^[a-fA-F0-9]{64}$'){Add-UnknownGate 'TaskPromptSha256'};if(-not(Test-Shape -Object $acceptance -Expected @('kind','expectedAnswerSha256')) -or [string](Get-Value -Object $acceptance -Name 'kind') -cne 'exact-utf8-sha256'){Add-UnknownGate 'TaskAcceptance'}else{$expectedAnswerSha=[string](Get-Value -Object $acceptance -Name 'expectedAnswerSha256');if($expectedAnswerSha -notmatch '^[a-fA-F0-9]{64}$'){Add-UnknownGate 'TaskAnswerSha256'}}}
    $candidates=@(Get-Value -Object $manifest -Name 'candidates' -Default @());if($candidates.Count -lt $MinimumCandidates -or $candidates.Count -gt 16){Add-UnknownGate 'CandidateCount'}
}
$candidateIds=@($candidates|ForEach-Object{[string](Get-Value -Object $_ -Name 'candidateId')});if(@($candidateIds|Select-Object -Unique).Count -ne $candidateIds.Count){Add-ConflictGate 'CandidateIdsUnique'}
$results=New-Object Collections.Generic.List[object];$configurationSha=$null
foreach($candidate in @($candidates|Sort-Object {[string](Get-Value -Object $_ -Name 'candidateId')})){
    $candidateId=[string](Get-Value -Object $candidate -Name 'candidateId');$prefix="Candidate[$candidateId]";$candidateUnknown=New-Object Collections.Generic.List[string];$candidateConflict=New-Object Collections.Generic.List[string]
    if(-not(Test-Shape -Object $candidate -Expected @('candidateId','metadataPath','metadataSha256','modelId','modelDigest')) -or [string]::IsNullOrWhiteSpace($candidateId)){[void]$candidateUnknown.Add('Shape')}
    $metadataPath=[string](Get-Value -Object $candidate -Name 'metadataPath');$metadataSha=[string](Get-Value -Object $candidate -Name 'metadataSha256');$modelId=[string](Get-Value -Object $candidate -Name 'modelId');$modelDigest=[string](Get-Value -Object $candidate -Name 'modelDigest')
    if($evidenceRoot -and -not(Test-EvidencePath -Path $metadataPath -Root $evidenceRoot)){[void]$candidateConflict.Add('MetadataWithinEvidenceRoot')}
    $metadata=$null;$request=$null;$response=$null;$wallDuration=$null;$serverDuration=$null;$promptTokens=$null;$outputTokens=$null;$answerSha=$null;$candidateConfiguration=$null
    if($candidateUnknown.Count -eq 0 -and $candidateConflict.Count -eq 0){
        $parameters=@{MetadataPath=$metadataPath;ExpectedMetadataSha256=$metadataSha;ExpectedModelId=$modelId;ExpectedModelDigest=$modelDigest;NoThrow=$true}
        if($AcceptUnverifiedModelDigest){$parameters.AcceptUnverifiedModelDigest=$true};if($AllowFixtureEvidence){$parameters.AllowFixtureEvidence=$true}
        try{$validation=& $validator @parameters}catch{[void]$candidateUnknown.Add('EvidenceReadable');$validation=$null}
        if($validation -and -not $validation.Passed){foreach($gate in @($validation.FailedGates)){if($gate -match 'Sha256|Model|Endpoint|Effects|Artifact'){[void]$candidateConflict.Add("Evidence.$gate")}else{[void]$candidateUnknown.Add("Evidence.$gate")}}}
        if($validation -and $validation.Passed){
            try{$metadataSnapshot=Read-BoundedSnapshot -LiteralPath $metadataPath -MaximumBytes $evidenceByteLimit;if($metadataSnapshot.Sha256 -ne $metadataSha.ToLowerInvariant()){[void]$candidateConflict.Add('MetadataSha256')}else{$metadata=$metadataSnapshot.Text|ConvertFrom-Json;$artifacts=Get-Value -Object $metadata -Name 'artifacts';$requestPath=[string](Get-Value -Object $artifacts -Name 'requestPath');$responsePath=[string](Get-Value -Object $artifacts -Name 'responsePath');if(-not(Test-EvidencePath -Path $requestPath -Root $evidenceRoot) -or -not(Test-EvidencePath -Path $responsePath -Root $evidenceRoot)){[void]$candidateConflict.Add('ArtifactsWithinEvidenceRoot')}else{$requestSnapshot=Read-BoundedSnapshot -LiteralPath $requestPath -MaximumBytes $evidenceByteLimit;$responseSnapshot=Read-BoundedSnapshot -LiteralPath $responsePath -MaximumBytes $responseByteLimit;if($requestSnapshot.Sha256 -ne ([string](Get-Value -Object $artifacts -Name 'requestSha256')).ToLowerInvariant() -or $responseSnapshot.Sha256 -ne ([string](Get-Value -Object $artifacts -Name 'responseSha256')).ToLowerInvariant()){[void]$candidateConflict.Add('ArtifactSha256')}else{$request=$requestSnapshot.Text|ConvertFrom-Json;$response=$responseSnapshot.Text|ConvertFrom-Json}}}}catch{[void]$candidateUnknown.Add('EvidenceReadable')}
        }
    }
    if($request -and $response){
        $messages=@(Get-Value -Object $request -Name 'messages' -Default @());$prompt=if($messages.Count -eq 1){[string](Get-Value -Object $messages[0] -Name 'content')}else{$null};$promptSha=if($null -ne $prompt){Get-ByteSha256 -Bytes $utf8.GetBytes($prompt)}else{$null};if($expectedPromptSha -match '^[a-fA-F0-9]{64}$' -and $promptSha -ne $expectedPromptSha.ToLowerInvariant()){[void]$candidateConflict.Add('PromptSha256')}
        $candidateConfiguration=Get-ConfigurationSha256 -Request $request;if(-not $configurationSha){$configurationSha=$candidateConfiguration}elseif($candidateConfiguration -ne $configurationSha){[void]$candidateConflict.Add('RequestConfiguration')}
        $message=Get-Value -Object $response -Name 'message';$answer=[string](Get-Value -Object $message -Name 'content');$answerSha=Get-ByteSha256 -Bytes $utf8.GetBytes($answer)
        $wallValue=Get-Value -Object $metadata -Name 'durationMs';$serverValue=Get-Value -Object $response -Name 'total_duration';$promptValue=Get-Value -Object $response -Name 'prompt_eval_count';$outputValue=Get-Value -Object $response -Name 'eval_count'
        if(-not(Test-Integer -Value $wallValue)-or [int64]$wallValue -lt 0 -or -not(Test-Integer -Value $serverValue)-or [int64]$serverValue -lt 0 -or -not(Test-Integer -Value $promptValue)-or [int64]$promptValue -lt 0 -or -not(Test-Integer -Value $outputValue)-or [int64]$outputValue -lt 0){[void]$candidateUnknown.Add('Metrics')}else{$wallDuration=[int64]$wallValue;$serverDuration=[int64]$serverValue;$promptTokens=[int64]$promptValue;$outputTokens=[int64]$outputValue}
    }
    foreach($gate in $candidateConflict){Add-ConflictGate "$prefix.$gate"};foreach($gate in $candidateUnknown){Add-UnknownGate "$prefix.$gate"}
    $quality=if($candidateConflict.Count -gt 0 -or $candidateUnknown.Count -gt 0 -or $expectedAnswerSha -notmatch '^[a-fA-F0-9]{64}$'){'UNKNOWN'}elseif($answerSha -eq $expectedAnswerSha.ToLowerInvariant()){'PASS'}else{'FAIL'}
    [void]$results.Add([pscustomobject][ordered]@{CandidateId=$candidateId;ModelId=$modelId;Quality=$quality;AnswerSha256=$answerSha;WallDurationMs=$wallDuration;ServerTotalDurationNanoseconds=$serverDuration;PromptTokens=$promptTokens;OutputTokens=$outputTokens;ConfigurationSha256=$candidateConfiguration;Rank=$null;FailedGates=$candidateConflict.ToArray()+$candidateUnknown.ToArray()})
}
$rank=1;foreach($item in @($results|Where-Object{$_.Quality -eq 'PASS' -and $null -ne $_.WallDurationMs}|Sort-Object WallDurationMs,CandidateId)){$item.Rank=$rank;$rank++}
$state=if($conflictGates.Count){'CONFLICT'}elseif($unknownGates.Count){'UNKNOWN'}else{'COMPLETE'};$failedGates=$conflictGates.ToArray()+$unknownGates.ToArray()
$result=[pscustomobject][ordered]@{SchemaVersion='1.0';State=$state;Passed=$state -eq 'COMPLETE';FailedGates=$failedGates;ManifestSha256=if($manifestSnapshot){$manifestSnapshot.Sha256}else{$null};ComparisonId=if($manifest){[string](Get-Value -Object $manifest -Name 'comparisonId')}else{$null};PromptSha256=$expectedPromptSha;ExpectedAnswerSha256=$expectedAnswerSha;ConfigurationSha256=$configurationSha;Candidates=$results.ToArray();RetryPerformed=$false;ModelCallPerformed=$false;WritePerformed=$false;TransportPerformed=$false}
if($AsJson){$result|ConvertTo-Json -Depth 10 -Compress}else{$result}
if(-not $result.Passed -and -not $suppressThrow){throw "Model evidence comparison is $state`: $($failedGates -join ', ')."}
