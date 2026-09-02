[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$MetadataPath,

    [string]$JsonlPath,

    [ValidateRange(0, 100000)]
    [int]$MinimumSuccessfulToolCalls = 0,

    [AllowEmptyString()]
    [string]$ExpectedFinalText,

    [switch]$RequireExactFinalText,

    [switch]$FailOnToolRetry,

    [switch]$AllowRemoteEndpointEvidence,

    [switch]$NoThrow,

    [switch]$AsJson
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-PropertyValue {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

$failures = New-Object System.Collections.Generic.List[string]
try { $metadata = Get-Content -LiteralPath (Resolve-Path -LiteralPath $MetadataPath) -Raw | ConvertFrom-Json }
catch { throw "Metadata is unavailable or invalid JSON: $($_.Exception.Message)" }

if ((Get-PropertyValue $metadata 'schemaVersion') -ne '1.0') { $failures.Add('metadata.schemaVersion must be 1.0.') }
if ((Get-PropertyValue $metadata 'timedOut' $true) -ne $false) { $failures.Add('The process timed out.') }
if ((Get-PropertyValue $metadata 'captureStatus') -ne 'Completed') { $failures.Add('Capture status is not Completed.') }
if ((Get-PropertyValue $metadata 'processExitCode' -1) -ne 0) { $failures.Add('Process exit code is not zero.') }
if (-not (Get-PropertyValue (Get-PropertyValue $metadata 'model') 'id')) { $failures.Add('Model id is missing.') }
if (-not (Get-PropertyValue (Get-PropertyValue $metadata 'model') 'digest')) { $failures.Add('Model digest is missing.') }
if ((Get-PropertyValue (Get-PropertyValue $metadata 'model') 'digestVerified' $false) -ne $true) { $failures.Add('Model digest is not verified.') }
if (-not (Get-PropertyValue (Get-PropertyValue $metadata 'provider') 'id')) { $failures.Add('Provider id is missing.') }
if (-not (Get-PropertyValue (Get-PropertyValue $metadata 'provider') 'endpoint')) { $failures.Add('Provider endpoint is missing.') }
if (-not $AllowRemoteEndpointEvidence -and (Get-PropertyValue (Get-PropertyValue $metadata 'provider') 'isLoopback' $false) -ne $true) { $failures.Add('Provider endpoint evidence is not loopback.') }
$runtime = Get-PropertyValue $metadata 'runtime'
foreach ($field in @('effectiveContext','sandbox','approvalPolicy','profile')) {
    if ($null -eq (Get-PropertyValue $runtime $field)) { $failures.Add("runtime.$field is missing.") }
}
$inputEvidence = Get-PropertyValue $metadata 'input'
if (-not (Get-PropertyValue $inputEvidence 'promptSha256')) { $failures.Add('Prompt SHA256 is missing.') }
if (-not (Get-PropertyValue $metadata 'startedAt')) { $failures.Add('Start time is missing.') }
if ([double](Get-PropertyValue $metadata 'durationMs' -1) -lt 0) { $failures.Add('Duration is missing or negative.') }

if (-not $JsonlPath) { $JsonlPath = Get-PropertyValue (Get-PropertyValue $metadata 'artifacts') 'stdoutJsonl' }
if (-not $JsonlPath -or -not (Test-Path -LiteralPath $JsonlPath -PathType Leaf)) { $failures.Add('JSONL artifact is missing.') }

$events = New-Object System.Collections.Generic.List[object]
$successfulToolCalls = 0
$finalText = $null
$toolAttempts = @{}
if ($JsonlPath -and (Test-Path -LiteralPath $JsonlPath -PathType Leaf)) {
    $lines = @(Get-Content -LiteralPath $JsonlPath)
    if (-not @($lines | Where-Object { $_.Trim() }).Count) { $failures.Add('JSONL output is empty.') }
    $lineNumber = 0
    foreach ($line in $lines) {
        $lineNumber++
        if (-not $line.Trim()) { continue }
        try { $event = $line | ConvertFrom-Json }
        catch { $failures.Add("Malformed JSONL at line $lineNumber."); continue }
        $events.Add($event)
        $eventType = [string](Get-PropertyValue $event 'type')
        if (-not $eventType) { $failures.Add("Event at line $lineNumber has no type."); continue }
        if ($eventType -match '(^|\.)(error|failed)$') { $failures.Add("Failure event '$eventType' at line $lineNumber.") }
        if ($null -ne (Get-PropertyValue $event 'error')) { $failures.Add("Event error at line $lineNumber.") }

        $item = Get-PropertyValue $event 'item'
        if ($eventType -like 'item.*' -and $null -eq $item) { $failures.Add("Item event at line $lineNumber has no item."); continue }
        if ($null -eq $item) { continue }
        $itemType = [string](Get-PropertyValue $item 'type')
        $status = ([string](Get-PropertyValue $item 'status')).ToLowerInvariant()
        if (-not $itemType) { $failures.Add("Item event at line $lineNumber has no item type.") }
        if ($status -in @('failed','error','denied','rejected','cancelled')) { $failures.Add("Item '$itemType' has failure status '$status'.") }
        if ($itemType -match '(policy.*(violation|failure|error)|approval_request|approval.*(denied|failure|error)|schema.*(failure|error))') { $failures.Add("Authority or schema failure item '$itemType'.") }
        if ($null -ne (Get-PropertyValue $item 'error')) { $failures.Add("Item '$itemType' contains an error.") }
        $exitCode = Get-PropertyValue $item 'exit_code' (Get-PropertyValue $item 'exitCode')
        if ($null -ne $exitCode -and [int]$exitCode -ne 0) { $failures.Add("Tool '$itemType' has exit code $exitCode.") }

        $isTool = $itemType -in @('command_execution','mcp_tool_call','tool_call','web_search')
        if ($isTool -and $eventType -eq 'item.started') {
            $identity = @(
                $itemType,
                [string](Get-PropertyValue $item 'command'),
                [string](Get-PropertyValue $item 'name'),
                [string](Get-PropertyValue $item 'tool')
            ) -join '|'
            if (-not $toolAttempts.ContainsKey($identity)) { $toolAttempts[$identity] = 0 }
            $toolAttempts[$identity]++
        }
        if ($isTool -and $eventType -eq 'item.completed' -and $status -notin @('failed','error','denied','rejected','cancelled') -and ($null -eq $exitCode -or [int]$exitCode -eq 0)) {
            $successfulToolCalls++
        }
        if ($eventType -eq 'item.completed' -and $itemType -eq 'agent_message') { $finalText = [string](Get-PropertyValue $item 'text') }
    }
}

if ($FailOnToolRetry -and @($toolAttempts.GetEnumerator() | Where-Object Value -gt 1).Count -gt 0) { $failures.Add('A tool call fingerprint was attempted more than once.') }
if ($successfulToolCalls -lt $MinimumSuccessfulToolCalls) { $failures.Add("Successful tool calls $successfulToolCalls is below required minimum $MinimumSuccessfulToolCalls.") }
if ($RequireExactFinalText -and $finalText -cne $ExpectedFinalText) { $failures.Add('Final agent text does not exactly match the expected text.') }

$result = [pscustomobject]@{
    SchemaVersion = '1.0'
    Passed = $failures.Count -eq 0
    FailureCount = $failures.Count
    Failures = @($failures)
    EventCount = $events.Count
    SuccessfulToolCalls = $successfulToolCalls
    FinalText = $finalText
    MetadataPath = (Resolve-Path -LiteralPath $MetadataPath).Path
    JsonlPath = if ($JsonlPath -and (Test-Path -LiteralPath $JsonlPath)) { (Resolve-Path -LiteralPath $JsonlPath).Path } else { $JsonlPath }
}
if ($AsJson) { $result | ConvertTo-Json -Depth 6 } else { $result }
if (-not $result.Passed -and -not $NoThrow) { throw "Codex JSONL evidence failed validation: $($failures -join ' ')" }
