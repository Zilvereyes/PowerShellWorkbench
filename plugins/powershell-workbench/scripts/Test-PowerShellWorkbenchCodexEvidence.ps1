[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MetadataPath,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedExecutableSha256,
    [string]$JsonlPath,
    [ValidateRange(0, 100000)][int]$MinimumSuccessfulToolCalls = 0,
    [AllowEmptyString()][string]$ExpectedFinalText,
    [switch]$RequireExactFinalText,
    [switch]$FailOnToolRetry,
    [switch]$AllowRemoteEndpointEvidence,
    [switch]$AcceptUnverifiedRuntimeDeclarations,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedMetadataSha256,
    [ValidateRange(1024, 10485760)][long]$MaxMetadataBytes = 1048576,
    [ValidateRange(1024, 1073741824)][long]$MaxJsonlBytes = 52428800,
    [ValidateRange(1024, 1073741824)][long]$MaxStderrBytes = 10485760,
    [ValidateRange(2048, 2147483648)][long]$MaxTotalArtifactBytes = 62914560,
    [ValidateRange(256, 10485760)][int]$MaxLineCharacters = 1048576,
    [ValidateRange(1, 1000000)][int]$MaxEvents = 100000,
    [ValidateRange(1, 10000)][int]$MaxFailures = 100,
    [string[]]$AllowedStderrRegex = @(),
    [string[]]$AllowedAdvisoryRegex = @(),
    [string]$ExpectedCodexVersion,
    [string]$ExpectedModelId,
    [string]$ExpectedModelDigest,
    [ValidateRange(1,1048576)][int64]$ExpectedEffectiveContext,
    [ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedCatalogSha256,
    [switch]$NoThrow,
    [switch]$AsJson
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:MaximumFailures = $MaxFailures
function Get-PropertyValue { param($Object,[string]$Name,$Default=$null) if($null -eq $Object){return $Default};$p=$Object.PSObject.Properties[$Name];if($null -eq $p){return $Default};$p.Value }
function Get-LowerHash { param([string]$Path) (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Add-Failure { param([string]$Message) if($script:failures.Count -lt $script:MaximumFailures){$script:failures.Add($Message)} }
function Test-AllowedAdvisory {
    param([string]$EventType,$Item,[string]$Status,[string[]]$Patterns)
    if($Patterns.Count -eq 0 -or $EventType -ne 'item.completed' -or [string](Get-PropertyValue -Object $Item -Name 'type') -ne 'error'){return $false}
    if($Status -and $Status -notin @('completed','success','succeeded')){return $false}
    if($null -ne (Get-PropertyValue -Object $Item -Name 'error')){return $false}
    $text=[string](Get-PropertyValue -Object $Item -Name 'text' -Default (Get-PropertyValue -Object $Item -Name 'message'))
    if([string]::IsNullOrWhiteSpace($text) -or $text -match '(?i)\b(?:tool|policy|approval|schema|turn)\b'){return $false}
    foreach($pattern in $Patterns){
        try{if($text -match $pattern){return $true}}
        catch{Add-Failure "AllowedAdvisoryRegex is invalid: $pattern";return $false}
    }
    return $false
}
function Test-JsonNesting {
    param([Parameter(Mandatory)][string]$Text,[ValidateRange(1,256)][int]$MaximumDepth=64)
    $depth=0;$quoted=$false;$escaped=$false
    foreach($character in $Text.ToCharArray()){
        if($escaped){$escaped=$false;continue}
        if($quoted -and $character -eq '\'){$escaped=$true;continue}
        if($character -eq '"'){$quoted=-not $quoted;continue}
        if(-not $quoted -and $character -in @('{','[')){$depth++;if($depth -gt $MaximumDepth){return $false}}
        elseif(-not $quoted -and $character -in @('}',']')){$depth--;if($depth -lt 0){return $false}}
    }
    return $depth -eq 0 -and -not $quoted -and -not $escaped
}

$failures = New-Object System.Collections.Generic.List[string]
$metadataPathResolved = (Resolve-Path -LiteralPath $MetadataPath).Path
if((Get-Item -LiteralPath $metadataPathResolved).Length -gt $MaxMetadataBytes){throw 'Metadata exceeds MaxMetadataBytes.'}
$metadataText=[IO.File]::ReadAllText($metadataPathResolved)
if(-not (Test-JsonNesting -Text $metadataText)){throw 'Metadata JSON exceeds the nesting limit or is structurally incomplete.'}
try{$metadata=$metadataText|ConvertFrom-Json}catch{throw "Metadata is invalid JSON: $($_.Exception.Message)"}
if((Get-LowerHash $metadataPathResolved) -ne $ExpectedMetadataSha256.ToLowerInvariant()){Add-Failure 'Metadata SHA256 does not match the expected out-of-band digest.'}
if((Get-PropertyValue -Object $metadata -Name 'schemaVersion') -ne '2.0'){Add-Failure 'metadata.schemaVersion must be 2.0.'}
if((Get-PropertyValue -Object $metadata -Name 'timedOut' -Default $true) -ne $false){Add-Failure 'The process timed out.'}
if((Get-PropertyValue -Object $metadata -Name 'outputLimitExceeded' -Default $true) -ne $false){Add-Failure 'The process exceeded an output limit.'}
if((Get-PropertyValue -Object $metadata -Name 'captureStatus') -ne 'Completed'){Add-Failure 'Capture status is not Completed.'}
if((Get-PropertyValue -Object $metadata -Name 'processExitCode' -Default -1) -ne 0){Add-Failure 'Process exit code is not zero.'}

$launch=Get-PropertyValue -Object $metadata -Name 'launch'
$executablePath=[string](Get-PropertyValue -Object $launch -Name 'executablePath')
if(-not $executablePath -or -not(Test-Path -LiteralPath $executablePath -PathType Leaf)){Add-Failure 'Recorded executable is unavailable.'}
else{
    $observedExecutableHash=Get-LowerHash $executablePath
    if($observedExecutableHash -ne ([string](Get-PropertyValue -Object $launch -Name 'executableSha256')).ToLowerInvariant()){Add-Failure 'Executable changed after capture.'}
    if($observedExecutableHash -ne $ExpectedExecutableSha256.ToLowerInvariant()){Add-Failure 'Executable does not match the independently expected SHA256.'}
}
$recordedCodexVersion=[string](Get-PropertyValue -Object $launch -Name 'codexVersion')
if($ExpectedCodexVersion -and $recordedCodexVersion -cne $ExpectedCodexVersion){Add-Failure 'Recorded Codex version does not match ExpectedCodexVersion.'}
$declarations=Get-PropertyValue -Object $metadata -Name 'declarations'
if((Get-PropertyValue -Object $declarations -Name 'attestation') -ne 'unverified-caller-declaration'){Add-Failure 'Runtime declaration state is missing or unknown.'}
if(-not $AcceptUnverifiedRuntimeDeclarations){Add-Failure 'Runtime model/provider/context declarations are not independently attested.'}
$provider=Get-PropertyValue -Object $declarations -Name 'provider'
$recordedModel=Get-PropertyValue -Object $declarations -Name 'model'
$recordedRuntime=Get-PropertyValue -Object $declarations -Name 'runtime'
if($ExpectedModelId -and [string](Get-PropertyValue -Object $recordedModel -Name 'id') -cne $ExpectedModelId){Add-Failure 'Recorded model id does not match ExpectedModelId.'}
if($ExpectedModelDigest -and [string](Get-PropertyValue -Object $recordedModel -Name 'digest') -cne $ExpectedModelDigest){Add-Failure 'Recorded model digest does not match ExpectedModelDigest.'}
if($ExpectedEffectiveContext -and [int64](Get-PropertyValue -Object $recordedRuntime -Name 'effectiveContext' -Default 0) -ne $ExpectedEffectiveContext){Add-Failure 'Recorded effective context does not match ExpectedEffectiveContext.'}
$recordedCatalog=Get-PropertyValue -Object $declarations -Name 'catalog'
if($ExpectedCatalogSha256){
    if($null -eq $recordedCatalog -or [string](Get-PropertyValue -Object $recordedCatalog -Name 'catalogSha256') -ine $ExpectedCatalogSha256){Add-Failure 'Recorded catalog SHA256 does not match ExpectedCatalogSha256.'}
}
$providerEndpoint=[string](Get-PropertyValue -Object $provider -Name 'endpoint')
$derivedLoopback=$false
try{$providerUri=[uri]$providerEndpoint;$derivedLoopback=$providerUri.DnsSafeHost.ToLowerInvariant() -in @('localhost','127.0.0.1','::1','[::1]')}catch{Add-Failure 'Declared provider endpoint is not a valid URI.'}
if(-not $AllowRemoteEndpointEvidence -and -not $derivedLoopback){Add-Failure 'Provider endpoint is not loopback.'}

$artifacts=Get-PropertyValue -Object $metadata -Name 'artifacts'
$totalArtifactBytes=[long]0
$recordedJsonl=[string](Get-PropertyValue -Object $artifacts -Name 'stdoutJsonl')
if(-not $JsonlPath){$JsonlPath=$recordedJsonl}
if($JsonlPath -and $recordedJsonl -and [IO.Path]::GetFullPath($JsonlPath) -ne [IO.Path]::GetFullPath($recordedJsonl)){Add-Failure 'JsonlPath does not match the captured artifact path.'}
foreach($artifactName in @('stdout','stderr')){
    $pathProperty=if($artifactName -eq 'stdout'){'stdoutJsonl'}else{'stderr'}
    $path=[string](Get-PropertyValue -Object $artifacts -Name $pathProperty)
    if(-not $path -or -not(Test-Path -LiteralPath $path -PathType Leaf)){Add-Failure "$artifactName artifact is missing.";continue}
    $actualBytes=[long](Get-Item -LiteralPath $path).Length
    $artifactLimit=if($artifactName -eq 'stdout'){$MaxJsonlBytes}else{$MaxStderrBytes}
    if($actualBytes -gt $artifactLimit){Add-Failure "$artifactName artifact exceeds its validator-side byte limit.";continue}
    $totalArtifactBytes+=$actualBytes
    $expectedHash=[string](Get-PropertyValue -Object $artifacts -Name ($artifactName+'Sha256'))
    $expectedBytes=[long](Get-PropertyValue -Object $artifacts -Name ($artifactName+'Bytes') -Default -1)
    if($actualBytes -ne $expectedBytes){Add-Failure "$artifactName byte length does not match metadata."}
    if(-not $expectedHash -or (Get-LowerHash $path) -ne $expectedHash.ToLowerInvariant()){Add-Failure "$artifactName SHA256 does not match metadata."}
    if($artifactName -eq 'stderr'){
        $stderrLineNumber=0
        foreach($stderrLine in [IO.File]::ReadLines($path)){
            $stderrLineNumber++
            if($stderrLine -notmatch '(?i)\b(?:error|fatal|panic)\b|\b(?:policy|approval|schema)\b.*\b(?:error|failed|failure|denied|reject(?:ed|ion)?|violation|invalid)\b'){continue}
            $allowed=$false
            foreach($allowedPattern in $AllowedStderrRegex){
                try{if($stderrLine -match $allowedPattern){$allowed=$true;break}}
                catch{Add-Failure "AllowedStderrRegex is invalid: $allowedPattern";break}
            }
            if(-not $allowed){Add-Failure "stderr failure signal at line $stderrLineNumber."}
        }
    }
}
if($totalArtifactBytes -gt $MaxTotalArtifactBytes){Add-Failure 'Captured artifacts exceed MaxTotalArtifactBytes.'}

$successfulToolCalls=0;$finalText=$null;$toolAttempts=@{};$startedTools=@{};$completedTools=@{};$eventCount=0;$turnActive=$false;$turnCompleted=$false
if($JsonlPath -and (Test-Path -LiteralPath $JsonlPath -PathType Leaf)){
    if((Get-Item -LiteralPath $JsonlPath).Length -gt $MaxJsonlBytes){Add-Failure 'JSONL artifact exceeds MaxJsonlBytes.'}
    else{
        $lineNumber=0
        foreach($line in [IO.File]::ReadLines((Resolve-Path -LiteralPath $JsonlPath).Path)){
            $lineNumber++;if(-not $line.Trim()){continue}
            if($line.Length -gt $MaxLineCharacters){Add-Failure "JSONL line $lineNumber exceeds MaxLineCharacters.";break}
            if(-not (Test-JsonNesting -Text $line)){Add-Failure "JSONL line $lineNumber exceeds the nesting limit or is structurally incomplete.";continue}
            try{$jsonEvent=$line|ConvertFrom-Json}catch{Add-Failure "Malformed JSONL at line $lineNumber.";continue}
            $eventCount++;if($eventCount -gt $MaxEvents){Add-Failure 'JSONL event count exceeds MaxEvents.';break}
            $eventType=[string](Get-PropertyValue -Object $jsonEvent -Name 'type')
            if(-not $eventType){Add-Failure "Event at line $lineNumber has no type.";continue}
            if($eventType -match '(^|\.)(error|failed)$' -or $null -ne(Get-PropertyValue -Object $jsonEvent -Name 'error')){Add-Failure "Failure event at line $lineNumber."}
            if($eventType -eq 'turn.started'){if($turnActive){Add-Failure 'A turn started before the previous turn completed.'};$turnActive=$true}
            if($eventType -eq 'turn.completed'){if(-not $turnActive){Add-Failure 'A turn completed without a matching start.'};$turnActive=$false;$turnCompleted=$true}
            $item=Get-PropertyValue -Object $jsonEvent -Name 'item'
            if($eventType -like 'item.*' -and $null -eq $item){Add-Failure "Item event at line $lineNumber has no item.";continue}
            if($null -eq $item){continue}
            $itemType=[string](Get-PropertyValue -Object $item -Name 'type');$itemId=[string](Get-PropertyValue -Object $item -Name 'id');$status=([string](Get-PropertyValue -Object $item -Name 'status')).ToLowerInvariant();$allowedAdvisory=Test-AllowedAdvisory -EventType $eventType -Item $item -Status $status -Patterns $AllowedAdvisoryRegex
            if(-not $itemType){Add-Failure "Item event at line $lineNumber has no item type."}
            if($status -in @('failed','error','denied','rejected','cancelled') -or $null -ne(Get-PropertyValue -Object $item -Name 'error')){Add-Failure "Item '$itemType' failed."}
            if($itemType -match '(?i)(?:^|[._-])(?:error|failure|failed|policy|approval|schema)(?:$|[._-])' -and -not $allowedAdvisory){Add-Failure "Failure-class item '$itemType'."}
            $isTool=$itemType -in @('command_execution','mcp_tool_call','tool_call','web_search')
            if($isTool){
                if(-not $turnActive){Add-Failure "Tool event '$itemId' occurred outside an active turn."}
                if(-not $itemId){Add-Failure "Tool event at line $lineNumber has no id.";continue}
                $identity=@($itemType,[string](Get-PropertyValue -Object $item -Name 'command'),[string](Get-PropertyValue -Object $item -Name 'name'),[string](Get-PropertyValue -Object $item -Name 'tool'))-join '|'
                if($eventType -eq 'item.started'){
                    if($startedTools.ContainsKey($itemId) -or $completedTools.ContainsKey($itemId)){Add-Failure "Duplicate tool start '$itemId'.";continue}
                    $startedTools[$itemId]=$itemType
                    if(-not $toolAttempts.ContainsKey($identity)){$toolAttempts[$identity]=0};$toolAttempts[$identity]++
                }elseif($eventType -eq 'item.completed'){
                    if($completedTools.ContainsKey($itemId)){Add-Failure "Duplicate tool completion '$itemId'.";continue}
                    if(-not $startedTools.ContainsKey($itemId) -or $startedTools[$itemId] -ne $itemType){Add-Failure "Tool '$itemId' completed without a matching start.";continue}
                    if($status -notin @('completed','success','succeeded')){Add-Failure "Tool '$itemId' has no explicit success status.";continue}
                    $exitCode=Get-PropertyValue -Object $item -Name 'exit_code' -Default (Get-PropertyValue -Object $item -Name 'exitCode')
                    if($itemType -eq 'command_execution' -and ($null -eq $exitCode -or [int]$exitCode -ne 0)){Add-Failure "Command tool '$itemId' has no explicit zero exit code.";continue}
                    $successfulToolCalls++;$startedTools.Remove($itemId);$completedTools[$itemId]=$true
                }
            }
            if($eventType -eq 'item.completed' -and $itemType -eq 'agent_message'){
                if(-not $turnActive){Add-Failure 'Agent message completed outside an active turn.'}
                else{$finalText=[string](Get-PropertyValue -Object $item -Name 'text')}
            }
        }
        if($eventCount -eq 0){Add-Failure 'JSONL output is empty.'}
    }
}
if($startedTools.Count -gt 0){Add-Failure 'One or more tool calls never completed.'}
if($turnActive -or -not $turnCompleted){Add-Failure 'No complete turn lifecycle was recorded.'}
if($FailOnToolRetry -and @($toolAttempts.GetEnumerator()|Where-Object Value -gt 1).Count -gt 0){Add-Failure 'A tool fingerprint was attempted more than once.'}
if($successfulToolCalls -lt $MinimumSuccessfulToolCalls){Add-Failure "Successful tool calls $successfulToolCalls is below required minimum $MinimumSuccessfulToolCalls."}
if($RequireExactFinalText -and $finalText -cne $ExpectedFinalText){Add-Failure 'Final agent text does not exactly match expected text.'}

$result=[pscustomobject]@{SchemaVersion='2.0';Passed=$failures.Count -eq 0;FailureCount=$failures.Count;Failures=@($failures);EventCount=$eventCount;SuccessfulToolCalls=$successfulToolCalls;FinalText=$finalText;RuntimeAttested=$false;MetadataIntegrity='out-of-band-digest';MetadataPath=$metadataPathResolved;JsonlPath=$JsonlPath}
if($AsJson){$result|ConvertTo-Json -Depth 6}else{$result}
if(-not $result.Passed -and -not $NoThrow){throw "Codex JSONL evidence failed validation: $($failures -join ' ')"}
