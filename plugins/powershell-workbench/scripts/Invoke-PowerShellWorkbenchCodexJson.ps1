#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Prompt,

    [Parameter(Mandatory)]
    [string]$ModelId,

    [Parameter(Mandatory)]
    [string]$ModelDigest,

    [Parameter(Mandatory)]
    [switch]$DigestVerified,

    [Parameter(Mandatory)]
    [string]$ProviderId,

    [Parameter(Mandatory)]
    [uri]$Endpoint,

    [Parameter(Mandatory)]
    [ValidateRange(1, 1048576)]
    [int]$EffectiveContext,

    [ValidateSet('read-only', 'workspace-write', 'danger-full-access')]
    [string]$Sandbox = 'read-only',

    [ValidateSet('untrusted', 'on-failure', 'on-request', 'never')]
    [string]$ApprovalPolicy = 'never',

    [string]$Profile = 'default',

    [string]$WorkingDirectory = (Get-Location).Path,

    [string]$OutputDirectory = (Join-Path (Get-Location).Path 'TestResults\CodexJson'),

    [ValidateRange(1, 86400)]
    [int]$TimeoutSeconds = 300,

    [string]$CodexPath,

    [string[]]$GlobalArgument = @(),

    [string[]]$ExecArgument = @('--ephemeral'),

    [string]$FixturePath,

    [switch]$AllowRemoteEndpoint
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if (-not $CodexPath) {
    $command = Get-Command codex -All -ErrorAction Stop | Where-Object { $_.Source -like '*.exe' } | Select-Object -First 1
    if (-not $command) { throw 'No native codex.exe was found. Install the standalone Codex CLI or pass -CodexPath to a native executable; script and cmd wrappers are not accepted by the bounded runner.' }
    $CodexPath = $command.Source
}
$CodexPath = (Resolve-Path -LiteralPath $CodexPath).Path
if ([IO.Path]::GetExtension($CodexPath) -ine '.exe') { throw '-CodexPath must identify a native .exe, not a script or cmd wrapper.' }
$WorkingDirectory = (Resolve-Path -LiteralPath $WorkingDirectory).Path

$endpointHost = $Endpoint.DnsSafeHost.ToLowerInvariant()
$isLoopback = $endpointHost -in @('localhost', '127.0.0.1', '::1', '[::1]')
if (-not $isLoopback -and -not $AllowRemoteEndpoint) {
    throw "Endpoint '$Endpoint' is not an explicit loopback endpoint. Use -AllowRemoteEndpoint only after separate authorization."
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$runId = '{0}-{1}' -f ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')), ([guid]::NewGuid().ToString('N'))
$stdoutPath = Join-Path $OutputDirectory "$runId.stdout.jsonl"
$stderrPath = Join-Path $OutputDirectory "$runId.stderr.log"
$metadataPath = Join-Path $OutputDirectory "$runId.metadata.json"
$utf8 = [Text.UTF8Encoding]::new($false)

function Get-TextSha256 {
    param([Parameter(Mandatory)][string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

$arguments = [Collections.Generic.List[string]]::new()
foreach ($value in $GlobalArgument) { $arguments.Add($value) }
$arguments.Add('--model'); $arguments.Add($ModelId)
$arguments.Add('--sandbox'); $arguments.Add($Sandbox)
$arguments.Add('--ask-for-approval'); $arguments.Add($ApprovalPolicy)
if ($Profile -and $Profile -ne 'default') { $arguments.Add('--profile'); $arguments.Add($Profile) }
$arguments.Add('exec'); $arguments.Add('--json')
foreach ($value in $ExecArgument) { $arguments.Add($value) }
$arguments.Add($Prompt)

$psi = [Diagnostics.ProcessStartInfo]::new()
$psi.FileName = $CodexPath
$psi.WorkingDirectory = $WorkingDirectory
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
foreach ($value in $arguments) { [void]$psi.ArgumentList.Add($value) }

$startedAt = [DateTime]::UtcNow
$stopwatch = [Diagnostics.Stopwatch]::StartNew()
$process = [Diagnostics.Process]::new()
$process.StartInfo = $psi
$timedOut = $false
$captureStatus = 'StartFailed'
$processExitCode = $null
$stdout = ''
$stderr = ''
$startError = $null

try {
    if (-not $process.Start()) { throw 'ProcessStartInfo returned false.' }
    $captureStatus = 'Running'
    $process.StandardInput.Close()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $cancellation = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSeconds))
    try {
        $process.WaitForExitAsync($cancellation.Token).GetAwaiter().GetResult()
        $captureStatus = 'Completed'
    } catch [OperationCanceledException] {
        $timedOut = $true
        $captureStatus = 'TimedOut'
        if (-not $process.HasExited) { $process.Kill($true) }
        $process.WaitForExit()
    } finally {
        $cancellation.Dispose()
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    if ($process.HasExited) { $processExitCode = $process.ExitCode }
} catch {
    $startError = $_.Exception.Message
    if ($captureStatus -eq 'Running') { $captureStatus = 'CaptureFailed' }
} finally {
    $stopwatch.Stop()
    $process.Dispose()
}

[IO.File]::WriteAllText($stdoutPath, $stdout, $utf8)
[IO.File]::WriteAllText($stderrPath, $stderr, $utf8)
$fixtureResolved = $null
$fixtureSha256 = $null
if ($FixturePath) {
    $fixtureResolved = (Resolve-Path -LiteralPath $FixturePath).Path
    $fixtureSha256 = (Get-FileHash -LiteralPath $fixtureResolved -Algorithm SHA256).Hash.ToLowerInvariant()
}
$argumentHashInput = @($arguments | Select-Object -SkipLast 1) | ConvertTo-Json -Compress
$metadata = [ordered]@{
    schemaVersion = '1.0'
    runId = $runId
    captureStatus = $captureStatus
    timedOut = $timedOut
    processExitCode = $processExitCode
    startError = $startError
    startedAt = $startedAt.ToString('o')
    durationMs = [math]::Round($stopwatch.Elapsed.TotalMilliseconds, 0)
    model = [ordered]@{ id=$ModelId; digest=$ModelDigest; digestVerified=[bool]$DigestVerified }
    provider = [ordered]@{ id=$ProviderId; endpoint=$Endpoint.AbsoluteUri; isLoopback=$isLoopback }
    runtime = [ordered]@{ effectiveContext=$EffectiveContext; sandbox=$Sandbox; approvalPolicy=$ApprovalPolicy; profile=$Profile }
    input = [ordered]@{
        promptSha256 = Get-TextSha256 -Text $Prompt
        fixturePath = $fixtureResolved
        fixtureSha256 = $fixtureSha256
        argumentSha256 = Get-TextSha256 -Text $argumentHashInput
    }
    artifacts = [ordered]@{ stdoutJsonl=$stdoutPath; stderr=$stderrPath }
}
[IO.File]::WriteAllText($metadataPath, ($metadata | ConvertTo-Json -Depth 8), $utf8)
$result = [pscustomobject]$metadata
Add-Member -InputObject $result -NotePropertyName MetadataPath -NotePropertyValue $metadataPath
Write-Output $result
