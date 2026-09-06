[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Prompt,
    [Parameter(Mandatory)][string]$ModelId,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ModelDigest,
    [uri]$Endpoint = 'http://127.0.0.1:11434/api/chat',
    [string]$OutputDirectory = (Join-Path (Get-Location).Path 'TestResults\OllamaChat'),
    [ValidateRange(1, 3600)][int]$TimeoutSeconds = 120,
    [ValidateRange(1, 1048576)][int]$MaxPromptBytes = 262144,
    [ValidateRange(1024, 10485760)][int]$MaxRequestBytes = 1048576,
    [ValidateRange(1024, 1073741824)][long]$MaxResponseBytes = 16777216,
    [ValidateRange(1, 1048576)][int]$MaxOutputTokens = 4096,
    [ValidateRange(0.0, 2.0)][double]$Temperature = 0.0,
    [Nullable[int]]$Seed,
    [ValidatePattern('^(0|[1-9][0-9]*[smh])$')][string]$KeepAlive = '0',
    [string]$FixtureResponsePath,
    [switch]$Execute
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false)
$strictUtf8 = New-Object Text.UTF8Encoding($false, $true)

function Get-ByteSha256 {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
}

function Read-BoundedSnapshot {
    param([Parameter(Mandatory)][string]$LiteralPath,[Parameter(Mandatory)][long]$MaximumBytes)
    $resolved = (Resolve-Path -LiteralPath $LiteralPath).Path
    $stream = [IO.File]::Open($resolved, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $memory = [IO.MemoryStream]::new()
        try {
            $buffer = New-Object byte[] 8192
            while (($readCount = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                if ($memory.Length -gt ($MaximumBytes - $readCount)) { throw 'PWB_OLLAMA_RESPONSE_LIMIT' }
                $memory.Write($buffer, 0, $readCount)
            }
            $bytes = $memory.ToArray()
        } finally { $memory.Dispose() }
    } finally { $stream.Dispose() }
    [pscustomobject]@{ Path = $resolved; Bytes = $bytes; Sha256 = Get-ByteSha256 -Bytes $bytes }
}

function Write-NewUtf8File {
    param([Parameter(Mandatory)][string]$LiteralPath,[Parameter(Mandatory)][byte[]]$Bytes)
    $stream = [IO.File]::Open($LiteralPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try { $stream.Write($Bytes, 0, $Bytes.Length) }
    finally { $stream.Dispose() }
}

function Get-PropertyValue {
    param([object]$InputObject,[string]$Name,$Default=$null)
    if ($null -eq $InputObject) { return $Default }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    $property.Value
}

function Test-JsonNesting {
    param([Parameter(Mandatory)][string]$Text,[ValidateRange(1,256)][int]$MaximumDepth = 64)
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

$endpointAddress = $null
$endpointHost = $Endpoint.DnsSafeHost.Trim('[',']')
$isLoopback = [Net.IPAddress]::TryParse($endpointHost, [ref]$endpointAddress) -and [Net.IPAddress]::IsLoopback($endpointAddress)
if (-not $isLoopback) { throw 'Ollama chat endpoint must use a literal loopback IP address.' }
if ($Endpoint.Scheme -cne 'http') { throw 'Ollama chat endpoint must use http on loopback.' }
if ($Endpoint.AbsolutePath -cne '/api/chat' -or $Endpoint.Query -or $Endpoint.Fragment -or -not [string]::IsNullOrEmpty($Endpoint.UserInfo)) {
    throw 'Ollama chat endpoint must be the exact credential-free /api/chat endpoint without query or fragment.'
}
if ([string]::IsNullOrWhiteSpace($Prompt)) { throw 'Prompt cannot be empty.' }
if ([string]::IsNullOrWhiteSpace($ModelId)) { throw 'ModelId cannot be empty.' }

$promptBytes = $utf8.GetByteCount($Prompt)
if ($promptBytes -gt $MaxPromptBytes) { throw 'Prompt exceeds MaxPromptBytes.' }
$options = [ordered]@{ temperature = $Temperature; num_predict = $MaxOutputTokens }
if ($null -ne $Seed) { $options.seed = $Seed.Value }
$request = [ordered]@{
    model = $ModelId
    messages = @([ordered]@{ role = 'user'; content = $Prompt })
    stream = $false
    think = $false
    keep_alive = $KeepAlive
    options = $options
}
$requestJson = $request | ConvertTo-Json -Depth 10 -Compress
$requestBytes = $utf8.GetBytes($requestJson)
if ($requestBytes.Length -gt $MaxRequestBytes) { throw 'Serialized request exceeds MaxRequestBytes.' }
$requestSha256 = Get-ByteSha256 -Bytes $requestBytes
$plan = [pscustomobject][ordered]@{
    result = if ($Execute) { 'EXECUTION_REQUESTED' } else { 'ANALYZE_ONLY' }
    endpoint = $Endpoint.AbsoluteUri
    model = [ordered]@{ id = $ModelId; digest = $ModelDigest.ToLowerInvariant(); digestAttestation = 'unverified-caller-declaration' }
    requestSha256 = $requestSha256
    requestBytes = $requestBytes.Length
    timeoutSeconds = $TimeoutSeconds
    maxResponseBytes = $MaxResponseBytes
    networkPerformed = $false
    writePerformed = $false
    toolExecutionPerformed = $false
    desktopLifecyclePerformed = $false
    providerSwitchPerformed = $false
}
if (-not $Execute) { return $plan }

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$resolvedOutput = (Resolve-Path -LiteralPath $OutputDirectory).Path
$runId = '{0}-{1}' -f ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')), ([guid]::NewGuid().ToString('N'))
$requestPath = Join-Path $resolvedOutput "$runId.request.json"
$responsePath = Join-Path $resolvedOutput "$runId.response.json"
$metadataPath = Join-Path $resolvedOutput "$runId.metadata.json"
Write-NewUtf8File -LiteralPath $requestPath -Bytes $requestBytes

$startedAt = [DateTime]::UtcNow
$stopwatch = [Diagnostics.Stopwatch]::StartNew()
$httpStatusCode = $null
$captureStatus = 'RequestFailed'
$failure = $null
$responseBytes = New-Object byte[] 0
$observedModel = $null
$done = $false
$toolCallCount = 0
$networkPerformed = $false
$captureMode = if ($FixtureResponsePath) { 'Fixture' } else { 'LiveLoopback' }
$fixtureResolved = $null
$fixtureSha256 = $null
$cancellation = $null
$client = $null
$handler = $null
try {
    if ($FixtureResponsePath) {
        $fixtureSnapshot = Read-BoundedSnapshot -LiteralPath $FixtureResponsePath -MaximumBytes $MaxResponseBytes
        $fixtureResolved = $fixtureSnapshot.Path
        $responseBytes = $fixtureSnapshot.Bytes
        $fixtureSha256 = $fixtureSnapshot.Sha256
        $httpStatusCode = 200
    } else {
        $handler = [Net.Http.HttpClientHandler]::new()
        $handler.AllowAutoRedirect = $false
        $handler.UseProxy = $false
        $client = [Net.Http.HttpClient]::new($handler)
        $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
        $cancellation = [Threading.CancellationTokenSource]::new()
        $cancellation.CancelAfter([TimeSpan]::FromSeconds($TimeoutSeconds))
        try {
            $content = [Net.Http.ByteArrayContent]::new($requestBytes)
            $content.Headers.ContentType = [Net.Http.Headers.MediaTypeHeaderValue]::new('application/json')
            $requestMessage = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, $Endpoint)
            $requestMessage.Content = $content
            try {
                $networkPerformed = $true
                $response = $client.SendAsync($requestMessage, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cancellation.Token).GetAwaiter().GetResult()
                try {
                    $httpStatusCode = [int]$response.StatusCode
                    $declaredLength = $response.Content.Headers.ContentLength
                    if ($null -ne $declaredLength -and $declaredLength -gt $MaxResponseBytes) { throw 'PWB_OLLAMA_RESPONSE_LIMIT' }
                    $inputStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                    try {
                        $memory = New-Object IO.MemoryStream
                        try {
                            $buffer = New-Object byte[] 8192
                            while (($read = $inputStream.ReadAsync($buffer, 0, $buffer.Length, $cancellation.Token).GetAwaiter().GetResult()) -gt 0) {
                                if ($memory.Length -gt ($MaxResponseBytes - $read)) { throw 'PWB_OLLAMA_RESPONSE_LIMIT' }
                                $memory.Write($buffer, 0, $read)
                            }
                            $responseBytes = $memory.ToArray()
                        } finally { $memory.Dispose() }
                    } finally { $inputStream.Dispose() }
                    if (-not $response.IsSuccessStatusCode) { throw "Ollama returned HTTP $httpStatusCode." }
                } finally { $response.Dispose() }
            } finally { $requestMessage.Dispose() }
        } finally {
            $client.Dispose()
            $handler.Dispose()
        }
    }
    if ($responseBytes.Length -eq 0) { throw 'Ollama returned an empty response.' }
    try { $responseText = $strictUtf8.GetString($responseBytes) }
    catch { throw 'Ollama response is not valid UTF-8.' }
    if (-not(Test-JsonNesting -Text $responseText)) { throw 'Ollama response exceeds the JSON nesting limit or is structurally incomplete.' }
    try { $responseObject = $responseText | ConvertFrom-Json }
    catch { throw "Ollama returned invalid JSON: $($_.Exception.Message)" }
    $observedModel = [string](Get-PropertyValue -InputObject $responseObject -Name 'model')
    if ($observedModel -cne $ModelId) { throw 'Ollama response model does not exactly match ModelId.' }
    $doneValue = Get-PropertyValue -InputObject $responseObject -Name 'done'
    $done = $doneValue -is [bool] -and $doneValue
    if (-not $done) { throw 'Ollama response did not contain done=true.' }
    $message = Get-PropertyValue -InputObject $responseObject -Name 'message'
    $toolCalls = Get-PropertyValue -InputObject $message -Name 'tool_calls'
    if ($null -ne $toolCalls) { $toolCallCount = @($toolCalls).Count }
    $captureStatus = 'Completed'
} catch {
    if ($null -ne $cancellation -and $cancellation.IsCancellationRequested) { $captureStatus = 'TimedOut'; $failure = 'Ollama request timed out.' }
    elseif ($_.Exception.Message -eq 'PWB_OLLAMA_RESPONSE_LIMIT') { $captureStatus = 'ResponseLimitExceeded'; $failure = 'Ollama response exceeded MaxResponseBytes.' }
    else { $failure = $_.Exception.Message }
} finally {
    $stopwatch.Stop()
    if ($null -ne $cancellation) { $cancellation.Dispose() }
}
Write-NewUtf8File -LiteralPath $responsePath -Bytes $responseBytes
$responseSha256 = Get-ByteSha256 -Bytes $responseBytes
$metadata = [ordered]@{
    schemaVersion = '1.0'
    runId = $runId
    captureStatus = $captureStatus
    failure = $failure
    startedAt = $startedAt.ToString('o')
    durationMs = [math]::Round($stopwatch.Elapsed.TotalMilliseconds, 0)
    captureMode = $captureMode
    fixture = [ordered]@{ path = $fixtureResolved; sha256 = $fixtureSha256 }
    endpoint = [ordered]@{ uri = $Endpoint.AbsoluteUri; isLoopback = $true; wireApi = 'ollama-chat' }
    model = [ordered]@{ requestedId = $ModelId; observedId = $observedModel; expectedDigest = $ModelDigest.ToLowerInvariant(); digestAttestation = 'unverified-caller-declaration' }
    limits = [ordered]@{ timeoutSeconds = $TimeoutSeconds; maxPromptBytes = $MaxPromptBytes; maxRequestBytes = $MaxRequestBytes; maxResponseBytes = $MaxResponseBytes; maxOutputTokens = $MaxOutputTokens }
    observation = [ordered]@{ httpStatusCode = $httpStatusCode; done = $done; toolCallCount = $toolCallCount; toolDisposition = if ($toolCallCount -gt 0) { 'PROPOSED_NOT_EXECUTED' } else { 'NONE' } }
    effects = [ordered]@{ networkPerformed = $networkPerformed; writePerformed = $true; toolExecutionPerformed = $false; desktopLifecyclePerformed = $false; providerSwitchPerformed = $false; transportPerformed = $false }
    artifacts = [ordered]@{
        requestPath = $requestPath; requestBytes = $requestBytes.Length; requestSha256 = $requestSha256
        responsePath = $responsePath; responseBytes = $responseBytes.Length; responseSha256 = $responseSha256
    }
}
$metadataBytes = $utf8.GetBytes(($metadata | ConvertTo-Json -Depth 12))
Write-NewUtf8File -LiteralPath $metadataPath -Bytes $metadataBytes
$result = [pscustomobject]$metadata
Add-Member -InputObject $result -NotePropertyName MetadataPath -NotePropertyValue $metadataPath
Write-Output $result
