[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MetadataPath,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedMetadataSha256,
    [Parameter(Mandatory)][string]$ExpectedModelId,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedModelDigest,
    [ValidateRange(1024, 10485760)][long]$MaxMetadataBytes = 1048576,
    [ValidateRange(1024, 10485760)][long]$MaxRequestBytes = 1048576,
    [ValidateRange(1024, 1073741824)][long]$MaxResponseBytes = 16777216,
    [switch]$AcceptUnverifiedModelDigest,
    [switch]$AllowFixtureEvidence,
    [switch]$NoThrow,
    [switch]$AsJson
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
function Get-Value { param($Object,[string]$Name,$Default=$null) if($null -eq $Object){return $Default};$property=$Object.PSObject.Properties[$Name];if($null -eq $property){return $Default};$property.Value }
$failures = New-Object Collections.Generic.List[string]
function Add-Failure { param([string]$Name) if(-not $failures.Contains($Name)){$failures.Add($Name)} }
function Read-BoundedSnapshot {
    param([string]$LiteralPath,[long]$MaximumBytes)
    $resolved = (Resolve-Path -LiteralPath $LiteralPath).Path
    $stream = [IO.File]::Open($resolved, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $memory = [IO.MemoryStream]::new()
        try {
            $buffer = New-Object byte[] 8192
            while (($readCount = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                if ($memory.Length -gt ($MaximumBytes - $readCount)) { throw 'Snapshot exceeds its validator-side byte limit.' }
                $memory.Write($buffer, 0, $readCount)
            }
            $bytes = $memory.ToArray()
        } finally { $memory.Dispose() }
    } finally { $stream.Dispose() }
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { $sha256 = ([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
    $decoder = New-Object Text.UTF8Encoding($false, $true)
    [pscustomobject]@{ Path = $resolved; Bytes = $bytes.Length; Sha256 = $sha256; Text = $decoder.GetString($bytes) }
}
function Test-ExactBoolean { param($Value,[bool]$Expected) $Value -is [bool] -and $Value -eq $Expected }
function Test-IntegerValue { param($Value) $Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64] }
function Test-Allowlist {
    param($Object,[string[]]$Allowed,[string]$Gate)
    if($null -eq $Object){Add-Failure $Gate;return}
    foreach($property in $Object.PSObject.Properties){if($Allowed -notcontains $property.Name){Add-Failure $Gate;return}}
}
function Test-JsonNesting {
    param([string]$Text,[ValidateRange(1,256)][int]$MaximumDepth = 64)
    $depth=0;$quoted=$false;$escaped=$false
    foreach($character in $Text.ToCharArray()){
        if($escaped){$escaped=$false;continue}
        if($quoted -and $character -eq '\'){$escaped=$true;continue}
        if($character -eq '"'){$quoted=-not $quoted;continue}
        if(-not $quoted -and $character -in @('{','[')){$depth++;if($depth -gt $MaximumDepth){return $false}}
        elseif(-not $quoted -and $character -in @('}',']')){$depth--;if($depth -lt 0){return $false}}
    }
    $depth -eq 0 -and -not $quoted -and -not $escaped
}
$requestPath = $null
$responsePath = $null

$metadataSnapshot = Read-BoundedSnapshot -LiteralPath $MetadataPath -MaximumBytes $MaxMetadataBytes
$resolvedMetadata = $metadataSnapshot.Path
if ($metadataSnapshot.Sha256 -ne $ExpectedMetadataSha256.ToLowerInvariant()) { Add-Failure 'MetadataSha256' }
if (-not(Test-JsonNesting -Text $metadataSnapshot.Text)) { throw 'Metadata exceeds the JSON nesting limit or is structurally incomplete.' }
try { $metadata = $metadataSnapshot.Text | ConvertFrom-Json }
catch { throw "Metadata is invalid JSON: $($_.Exception.Message)" }
if ([string](Get-Value $metadata 'schemaVersion') -cne '1.0') { Add-Failure 'SchemaVersion' }
if ([string](Get-Value $metadata 'captureStatus') -cne 'Completed') { Add-Failure 'CaptureStatus' }
$captureMode = [string](Get-Value $metadata 'captureMode')
if ($captureMode -notin @('LiveLoopback','Fixture')) { Add-Failure 'CaptureMode' }
if ($captureMode -eq 'Fixture' -and -not $AllowFixtureEvidence) { Add-Failure 'FixtureEvidenceNotRuntime' }
$fixture = Get-Value $metadata 'fixture'
if ($captureMode -eq 'Fixture') {
    $fixturePath = [string](Get-Value $fixture 'path')
    $fixtureSha256 = [string](Get-Value $fixture 'sha256')
    if (-not $fixturePath -or -not(Test-Path -LiteralPath $fixturePath -PathType Leaf) -or -not $fixtureSha256) { Add-Failure 'FixtureSha256' }
    else {
        try { $fixtureSnapshot = Read-BoundedSnapshot -LiteralPath $fixturePath -MaximumBytes $MaxResponseBytes }
        catch { Add-Failure 'FixtureSha256'; $fixtureSnapshot = $null }
        if ($null -ne $fixtureSnapshot -and $fixtureSnapshot.Sha256 -ne $fixtureSha256.ToLowerInvariant()) { Add-Failure 'FixtureSha256' }
    }
}

$endpoint = Get-Value $metadata 'endpoint'
try {
    $uri = [uri][string](Get-Value $endpoint 'uri')
    $endpointAddress = $null
    $endpointHost = $uri.DnsSafeHost.Trim('[',']')
    $isLoopback = [Net.IPAddress]::TryParse($endpointHost,[ref]$endpointAddress) -and [Net.IPAddress]::IsLoopback($endpointAddress)
    if (-not $isLoopback -or $uri.Scheme -cne 'http' -or $uri.AbsolutePath -cne '/api/chat' -or $uri.Query -or $uri.Fragment -or $uri.UserInfo) { Add-Failure 'Endpoint' }
} catch { Add-Failure 'Endpoint' }
if (-not(Test-ExactBoolean (Get-Value $endpoint 'isLoopback') $true) -or [string](Get-Value $endpoint 'wireApi') -cne 'ollama-chat') { Add-Failure 'EndpointEvidence' }

$model = Get-Value $metadata 'model'
if ([string](Get-Value $model 'requestedId') -cne $ExpectedModelId -or [string](Get-Value $model 'observedId') -cne $ExpectedModelId) { Add-Failure 'ModelId' }
if ([string](Get-Value $model 'expectedDigest') -ine $ExpectedModelDigest) { Add-Failure 'ModelDigest' }
if ([string](Get-Value $model 'digestAttestation') -cne 'unverified-caller-declaration') { Add-Failure 'ModelDigestAttestationState' }
elseif (-not $AcceptUnverifiedModelDigest) { Add-Failure 'ModelDigestNotAttested' }

$effects = Get-Value $metadata 'effects'
foreach ($name in @('toolExecutionPerformed','desktopLifecyclePerformed','providerSwitchPerformed','transportPerformed')) {
    if (-not(Test-ExactBoolean (Get-Value $effects $name) $false)) { Add-Failure "Effects.$name" }
}
if (-not(Test-ExactBoolean (Get-Value $effects 'writePerformed') $true)) { Add-Failure 'Effects.Capture' }
if ($captureMode -eq 'LiveLoopback' -and -not(Test-ExactBoolean (Get-Value $effects 'networkPerformed') $true)) { Add-Failure 'Effects.Network' }
if ($captureMode -eq 'Fixture' -and -not(Test-ExactBoolean (Get-Value $effects 'networkPerformed') $false)) { Add-Failure 'Effects.Network' }
$observation = Get-Value $metadata 'observation'
$statusCodeValue = Get-Value $observation 'httpStatusCode'
$statusCode = if(Test-IntegerValue $statusCodeValue){[int]$statusCodeValue}else{0}
if(-not(Test-IntegerValue $statusCodeValue)){Add-Failure 'HttpStatusCodeType'}
if ($statusCode -lt 200 -or $statusCode -ge 300) { Add-Failure 'HttpStatusCode' }
if (-not(Test-ExactBoolean (Get-Value $observation 'done') $true)) { Add-Failure 'Done' }
$toolCallCountValue = Get-Value $observation 'toolCallCount'
$toolCallCount = if(Test-IntegerValue $toolCallCountValue){[int]$toolCallCountValue}else{-1}
if(-not(Test-IntegerValue $toolCallCountValue)){Add-Failure 'ToolCallCountType'}
$expectedDisposition = if ($toolCallCount -gt 0) { 'PROPOSED_NOT_EXECUTED' } elseif ($toolCallCount -eq 0) { 'NONE' } else { 'UNKNOWN' }
if ([string](Get-Value $observation 'toolDisposition') -cne $expectedDisposition) { Add-Failure 'ToolDisposition' }

$artifacts = Get-Value $metadata 'artifacts'
$artifactSnapshots = @{}
foreach ($name in @('request','response')) {
    $path = [string](Get-Value $artifacts ($name + 'Path'))
    if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { Add-Failure "Artifacts.$name.Missing"; continue }
    $limit = if ($name -eq 'request') { $MaxRequestBytes } else { $MaxResponseBytes }
    try { $snapshot = Read-BoundedSnapshot -LiteralPath $path -MaximumBytes $limit }
    catch { Add-Failure "Artifacts.$name.Limit"; continue }
    $actualBytes = [long]$snapshot.Bytes
    if ($actualBytes -ne [long](Get-Value $artifacts ($name + 'Bytes') -1)) { Add-Failure "Artifacts.$name.Bytes" }
    if ($snapshot.Sha256 -ne ([string](Get-Value $artifacts ($name + 'Sha256'))).ToLowerInvariant()) { Add-Failure "Artifacts.$name.Sha256" }
    $artifactSnapshots[$name] = $snapshot
    if ($name -eq 'request') { $requestPath = $path } else { $responsePath = $path }
}
if ($requestPath) {
    if (-not(Test-JsonNesting -Text $artifactSnapshots['request'].Text)) { Add-Failure 'Request.JsonNesting'; $request = $null }
    else { try { $request = $artifactSnapshots['request'].Text | ConvertFrom-Json } catch { Add-Failure 'Request.Json'; $request = $null } }
    if ($request) {
        Test-Allowlist $request @('model','messages','stream','think','keep_alive','options') 'Request.Properties'
        if ([string](Get-Value $request 'model') -cne $ExpectedModelId) { Add-Failure 'Request.ModelId' }
        if (-not(Test-ExactBoolean (Get-Value $request 'stream') $false)) { Add-Failure 'Request.Stream' }
        if (-not(Test-ExactBoolean (Get-Value $request 'think') $false)) { Add-Failure 'Request.Think' }
        if ([string](Get-Value $request 'keep_alive') -notmatch '^(0|[1-9][0-9]*[smh])$') { Add-Failure 'Request.KeepAlive' }
        $messages = @(Get-Value $request 'messages' @())
        if ($messages.Count -ne 1 -or [string](Get-Value $messages[0] 'role') -cne 'user' -or [string]::IsNullOrWhiteSpace([string](Get-Value $messages[0] 'content'))) { Add-Failure 'Request.Messages' }
        else { Test-Allowlist $messages[0] @('role','content') 'Request.MessageProperties' }
        $options = Get-Value $request 'options'
        Test-Allowlist $options @('temperature','num_predict','seed') 'Request.OptionsProperties'
        $numPredict = Get-Value $options 'num_predict'
        if(-not(Test-IntegerValue $numPredict) -or [int64]$numPredict -lt 1 -or [int64]$numPredict -gt 1048576){Add-Failure 'Request.MaxOutputTokens'}
        if ($null -ne (Get-Value $request 'tools')) { Add-Failure 'Request.Tools' }
    }
}
if ($responsePath) {
    if (-not(Test-JsonNesting -Text $artifactSnapshots['response'].Text)) { Add-Failure 'Response.JsonNesting'; $response = $null }
    else { try { $response = $artifactSnapshots['response'].Text | ConvertFrom-Json } catch { Add-Failure 'Response.Json'; $response = $null } }
    if ($response) {
        if ([string](Get-Value $response 'model') -cne $ExpectedModelId) { Add-Failure 'Response.ModelId' }
        if (-not(Test-ExactBoolean (Get-Value $response 'done') $true)) { Add-Failure 'Response.Done' }
        $responseMessage = Get-Value $response 'message'
        $responseToolCalls = Get-Value $responseMessage 'tool_calls'
        $responseToolCount = if ($null -ne $responseToolCalls) { @($responseToolCalls).Count } else { 0 }
        if ($responseToolCount -ne $toolCallCount) { Add-Failure 'Response.ToolCallCount' }
    }
}

$result = [pscustomobject][ordered]@{
    SchemaVersion = '1.0'
    Passed = $failures.Count -eq 0
    FailureCount = $failures.Count
    FailedGates = @($failures)
    MetadataIntegrity = 'out-of-band-digest'
    ModelIdObserved = [string](Get-Value $model 'observedId')
    ModelDigestAttested = $false
    ToolCallCount = $toolCallCount
    ToolExecutionPerformed = $false
    MetadataPath = $resolvedMetadata
}
if ($AsJson) { $result | ConvertTo-Json -Depth 5 -Compress } else { $result }
if (-not $result.Passed -and -not $NoThrow) { throw "Ollama evidence failed validation: $($failures -join ', ')." }
