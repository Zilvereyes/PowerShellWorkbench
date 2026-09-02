#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Prompt,
    [Parameter(Mandatory)][string]$ModelId,
    [Parameter(Mandatory)][string]$ModelDigest,
    [Parameter(Mandatory)][string]$ProviderId,
    [Parameter(Mandatory)][uri]$Endpoint,
    [Parameter(Mandatory)][ValidateRange(1, 1048576)][int]$EffectiveContext,
    [ValidateSet('read-only', 'workspace-write', 'danger-full-access')][string]$Sandbox = 'read-only',
    [ValidateSet('untrusted', 'on-failure', 'on-request', 'never')][string]$ApprovalPolicy = 'never',
    [Alias('Profile')][string]$WorkbenchProfile = 'default',
    [string]$WorkingDirectory = (Get-Location).Path,
    [string]$OutputDirectory = (Join-Path (Get-Location).Path 'TestResults\CodexJson'),
    [ValidateRange(1, 86400)][int]$TimeoutSeconds = 300,
    [ValidateRange(1024, 1073741824)][long]$MaxStdoutBytes = 52428800,
    [ValidateRange(1024, 1073741824)][long]$MaxStderrBytes = 10485760,
    [ValidateRange(2048, 2147483648)][long]$MaxTotalOutputBytes = 62914560,
    [string]$CodexPath,
    [string]$CatalogManifestPath,
    [string[]]$GlobalArgument = @(),
    [string[]]$ExecArgument = @('--ephemeral'),
    [string]$FixturePath,
    [switch]$AllowRemoteEndpoint
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if (-not ('PowerShellWorkbench.BoundedWriteStream' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;

namespace PowerShellWorkbench {
    public sealed class BoundedWriteStream : Stream {
        private readonly Stream inner;
        private readonly long maximum;
        public long BytesWritten { get; private set; }
        public BoundedWriteStream(Stream inner, long maximum) {
            this.inner = inner ?? throw new ArgumentNullException(nameof(inner));
            this.maximum = maximum;
        }
        public override bool CanRead => false;
        public override bool CanSeek => false;
        public override bool CanWrite => true;
        public override long Length => BytesWritten;
        public override long Position { get => BytesWritten; set => throw new NotSupportedException(); }
        public override void Flush() => inner.Flush();
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) {
            if (count < 0 || BytesWritten > maximum - count) throw new IOException("PWB_OUTPUT_LIMIT");
            inner.Write(buffer, offset, count);
            BytesWritten += count;
        }
        protected override void Dispose(bool disposing) {
            if (disposing) inner.Dispose();
            base.Dispose(disposing);
        }
    }
}
'@
}

if (-not $CodexPath) { $CodexPath = (& (Join-Path $PSScriptRoot 'Resolve-PowerShellWorkbenchCodexDesktop.ps1')).Path }
$CodexPath = (Resolve-Path -LiteralPath $CodexPath).Path
if ([IO.Path]::GetExtension($CodexPath) -ine '.exe') { throw '-CodexPath must identify a native .exe.' }
$codexExecutableSha256 = (Get-FileHash -LiteralPath $CodexPath -Algorithm SHA256).Hash.ToLowerInvariant()
$codexVersionOutput = (& $CodexPath --version 2>$null) -join "`n"
if ($LASTEXITCODE -ne 0 -or $codexVersionOutput -notmatch '^codex-cli\s+(?<version>\d+\.\d+\.\d+)$') { throw "Could not obtain a deterministic Codex version from '$CodexPath'." }
$codexVersion = $Matches.version
$WorkingDirectory = (Resolve-Path -LiteralPath $WorkingDirectory).Path
if ($MaxTotalOutputBytes -lt ($MaxStdoutBytes + $MaxStderrBytes)) { throw '-MaxTotalOutputBytes must be at least the sum of the per-stream limits.' }
$catalogManifestResolved=$null;$catalogManifestSha256=$null;$catalogPath=$null;$catalogSha256=$null
if($CatalogManifestPath){
    $catalogManifestResolved=(Resolve-Path -LiteralPath $CatalogManifestPath).Path
    try{$catalogManifest=Get-Content -LiteralPath $catalogManifestResolved -Raw|ConvertFrom-Json -Depth 20}catch{throw "Catalog manifest is invalid JSON: $($_.Exception.Message)"}
    if([string]$catalogManifest.model -cne $ModelId -or [int64]$catalogManifest.contextWindow -ne $EffectiveContext){throw 'Catalog manifest model or context does not match this run.'}
    if([string]$catalogManifest.codexSha256 -ine $codexExecutableSha256 -or [string]$catalogManifest.codexVersion -cne $codexVersion){throw 'Catalog manifest Codex identity does not match this runner.'}
    $catalogPath=(Resolve-Path -LiteralPath ([string]$catalogManifest.catalogPath)).Path
    $catalogSha256=(Get-FileHash -LiteralPath $catalogPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if($catalogSha256 -ine [string]$catalogManifest.catalogSha256){throw 'Catalog SHA256 does not match its manifest.'}
    $catalogManifestSha256=(Get-FileHash -LiteralPath $catalogManifestResolved -Algorithm SHA256).Hash.ToLowerInvariant()
}

$endpointHost = $Endpoint.DnsSafeHost.ToLowerInvariant()
$isLoopback = $endpointHost -in @('localhost', '127.0.0.1', '::1', '[::1]')
if (-not $isLoopback -and -not $AllowRemoteEndpoint) { throw "Endpoint '$Endpoint' is not loopback. Remote use requires explicit authorization and -AllowRemoteEndpoint." }

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$runId = '{0}-{1}' -f ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')), ([guid]::NewGuid().ToString('N'))
$stdoutPath = Join-Path $OutputDirectory "$runId.stdout.jsonl"
$stderrPath = Join-Path $OutputDirectory "$runId.stderr.log"
$metadataPath = Join-Path $OutputDirectory "$runId.metadata.json"
$utf8 = [Text.UTF8Encoding]::new($false)

function Get-TextSha256 {
    param([Parameter(Mandatory)][string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

$arguments = [Collections.Generic.List[string]]::new()
foreach ($value in $GlobalArgument) { $arguments.Add($value) }
$arguments.Add('--model'); $arguments.Add($ModelId)
$arguments.Add('--sandbox'); $arguments.Add($Sandbox)
$arguments.Add('--ask-for-approval'); $arguments.Add($ApprovalPolicy)
if ($WorkbenchProfile -and $WorkbenchProfile -ne 'default') { $arguments.Add('--profile'); $arguments.Add($WorkbenchProfile) }
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
$outputLimitExceeded = $false
$captureStatus = 'StartFailed'
$processExitCode = $null
$startError = $null
$stdoutSink = $null
$stderrSink = $null

try {
    $stdoutSink = [PowerShellWorkbench.BoundedWriteStream]::new([IO.File]::Open($stdoutPath, 'CreateNew', 'Write', 'Read'), $MaxStdoutBytes)
    $stderrSink = [PowerShellWorkbench.BoundedWriteStream]::new([IO.File]::Open($stderrPath, 'CreateNew', 'Write', 'Read'), $MaxStderrBytes)
    if (-not $process.Start()) { throw 'ProcessStartInfo returned false.' }
    $captureStatus = 'Running'
    $process.StandardInput.Close()
    $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($stdoutSink)
    $stderrTask = $process.StandardError.BaseStream.CopyToAsync($stderrSink)

    while (-not $process.HasExited) {
        if ($stdoutTask.IsFaulted -or $stderrTask.IsFaulted -or (($stdoutSink.BytesWritten + $stderrSink.BytesWritten) -gt $MaxTotalOutputBytes)) {
            $outputLimitExceeded = $true
            $captureStatus = 'OutputLimitExceeded'
            $process.Kill($true)
            break
        }
        if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            $timedOut = $true
            $captureStatus = 'TimedOut'
            $process.Kill($true)
            break
        }
        Start-Sleep -Milliseconds 10
    }
    $process.WaitForExit()
    try { [Threading.Tasks.Task]::WhenAll([Threading.Tasks.Task[]]@($stdoutTask, $stderrTask)).GetAwaiter().GetResult() }
    catch {
        if ($_.Exception.ToString().Contains('PWB_OUTPUT_LIMIT')) { $outputLimitExceeded = $true; $captureStatus = 'OutputLimitExceeded' }
        else { throw }
    }
    if (($stdoutSink.BytesWritten + $stderrSink.BytesWritten) -gt $MaxTotalOutputBytes) { $outputLimitExceeded = $true; $captureStatus = 'OutputLimitExceeded' }
    if (-not $timedOut -and -not $outputLimitExceeded) { $captureStatus = 'Completed' }
    $processExitCode = $process.ExitCode
} catch {
    $startError = $_.Exception.Message
    if ($captureStatus -eq 'Running') { $captureStatus = 'CaptureFailed' }
    try { if (-not $process.HasExited) { $process.Kill($true) } }
    catch { Write-Verbose "Unable to terminate the failed process: $($_.Exception.Message)" }
} finally {
    if ($stdoutSink) { $stdoutSink.Flush(); $stdoutSink.Dispose() }
    if ($stderrSink) { $stderrSink.Flush(); $stderrSink.Dispose() }
    $stopwatch.Stop()
    $process.Dispose()
}

if (-not (Test-Path -LiteralPath $stdoutPath)) { [IO.File]::WriteAllBytes($stdoutPath, [byte[]]@()) }
if (-not (Test-Path -LiteralPath $stderrPath)) { [IO.File]::WriteAllBytes($stderrPath, [byte[]]@()) }
$fixtureResolved = $null
$fixtureSha256 = $null
if ($FixturePath) {
    $fixtureResolved = (Resolve-Path -LiteralPath $FixturePath).Path
    $fixtureSha256 = (Get-FileHash -LiteralPath $fixtureResolved -Algorithm SHA256).Hash.ToLowerInvariant()
}
$argumentHashInput = @($arguments | Select-Object -SkipLast 1) | ConvertTo-Json -Compress
$metadata = [ordered]@{
    schemaVersion = '2.0'
    runId = $runId
    captureStatus = $captureStatus
    timedOut = $timedOut
    outputLimitExceeded = $outputLimitExceeded
    processExitCode = $processExitCode
    startError = $startError
    startedAt = $startedAt.ToString('o')
    durationMs = [math]::Round($stopwatch.Elapsed.TotalMilliseconds, 0)
    launch = [ordered]@{
        executablePath = $CodexPath
        executableSha256 = $codexExecutableSha256
        codexVersion = $codexVersion
        workingDirectory = $WorkingDirectory
        argumentSha256 = Get-TextSha256 -Text $argumentHashInput
    }
    declarations = [ordered]@{
        attestation = 'unverified-caller-declaration'
        model = [ordered]@{ id=$ModelId; digest=$ModelDigest }
        provider = [ordered]@{ id=$ProviderId; endpoint=$Endpoint.AbsoluteUri; isLoopback=$isLoopback }
        runtime = [ordered]@{ effectiveContext=$EffectiveContext; sandbox=$Sandbox; approvalPolicy=$ApprovalPolicy; profile=$WorkbenchProfile }
        catalog = [ordered]@{ manifestPath=$catalogManifestResolved; manifestSha256=$catalogManifestSha256; catalogPath=$catalogPath; catalogSha256=$catalogSha256 }
    }
    input = [ordered]@{ promptSha256=Get-TextSha256 -Text $Prompt; fixturePath=$fixtureResolved; fixtureSha256=$fixtureSha256 }
    limits = [ordered]@{ timeoutSeconds=$TimeoutSeconds; maxStdoutBytes=$MaxStdoutBytes; maxStderrBytes=$MaxStderrBytes; maxTotalOutputBytes=$MaxTotalOutputBytes }
    artifacts = [ordered]@{
        stdoutJsonl=$stdoutPath; stdoutBytes=(Get-Item -LiteralPath $stdoutPath).Length; stdoutSha256=(Get-FileHash -LiteralPath $stdoutPath -Algorithm SHA256).Hash.ToLowerInvariant()
        stderr=$stderrPath; stderrBytes=(Get-Item -LiteralPath $stderrPath).Length; stderrSha256=(Get-FileHash -LiteralPath $stderrPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}
[IO.File]::WriteAllText($metadataPath, ($metadata | ConvertTo-Json -Depth 10), $utf8)
$result = [pscustomobject]$metadata
Add-Member -InputObject $result -NotePropertyName MetadataPath -NotePropertyValue $metadataPath
Write-Output $result
