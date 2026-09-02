[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$pluginRoot = Split-Path -Parent $PSScriptRoot
$validator = Join-Path $pluginRoot 'scripts\Test-PowerShellWorkbenchCodexEvidence.ps1'
$runner = Join-Path $pluginRoot 'scripts\Invoke-PowerShellWorkbenchCodexJson.ps1'
$providerTemplate = Join-Path $pluginRoot 'skills\powershell-agent-harness-development\assets\templates\provider-switch-transaction.ps1.tmpl'
$fixtures = Join-Path $PSScriptRoot 'Fixtures'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('powershell-workbench-agent-harness-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null

function Assert-True { param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message} }
function New-Metadata {
    param([string]$Jsonl,[bool]$TimedOut=$false,[int]$ProcessExitCode=0,[string]$CaptureStatus='Completed')
    $path=Join-Path $tempRoot ((Split-Path -Leaf $Jsonl)+'.metadata.json')
    [ordered]@{
        schemaVersion='1.0'; captureStatus=$CaptureStatus; timedOut=$TimedOut; processExitCode=$ProcessExitCode
        startedAt='2026-01-01T00:00:00.0000000Z'; durationMs=1
        model=[ordered]@{id='fixture-model';digest='fixture-digest';digestVerified=$true}
        provider=[ordered]@{id='fixture-provider';endpoint='http://127.0.0.1:11434/';isLoopback=$true}
        runtime=[ordered]@{effectiveContext=4096;sandbox='read-only';approvalPolicy='never';profile='fixture'}
        input=[ordered]@{promptSha256='fixture-prompt-sha256';fixturePath=$Jsonl;fixtureSha256='fixture-sha256'}
        artifacts=[ordered]@{stdoutJsonl=$Jsonl;stderr=(Join-Path $tempRoot 'stderr.log')}
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

try {
    $success=Join-Path $fixtures 'success.jsonl'
    $result=& $validator -MetadataPath (New-Metadata $success) -MinimumSuccessfulToolCalls 1 -ExpectedFinalText 'EXACT_OK' -RequireExactFinalText -NoThrow
    Assert-True $result.Passed 'Success fixture did not pass.'

    foreach($name in @('tool-failure-process-zero.jsonl','empty.jsonl','malformed.jsonl')){
        $path=Join-Path $fixtures $name
        $result=& $validator -MetadataPath (New-Metadata $path) -NoThrow
        Assert-True (-not $result.Passed) "$name produced a false positive."
    }
    $timeout=Join-Path $fixtures 'empty.jsonl'
    $result=& $validator -MetadataPath (New-Metadata $timeout $true 0 'TimedOut') -NoThrow
    Assert-True (-not $result.Passed) 'Timeout fixture produced a false positive.'

    $noTool=Join-Path $fixtures 'no-tool-call.jsonl'
    $result=& $validator -MetadataPath (New-Metadata $noTool) -MinimumSuccessfulToolCalls 1 -NoThrow
    Assert-True (-not $result.Passed) 'No-tool fixture passed a required-tool gate.'

    $retry=Join-Path $fixtures 'tool-retry.jsonl'
    $result=& $validator -MetadataPath (New-Metadata $retry) -FailOnToolRetry -NoThrow
    Assert-True (-not $result.Passed) 'Tool retry fixture passed a no-retry gate.'

    $tokens=$null;$errors=$null
    $runnerAst=[Management.Automation.Language.Parser]::ParseFile($runner,[ref]$tokens,[ref]$errors)
    Assert-True (@($errors).Count -eq 0) 'Runner has parser errors.'
    $runnerText=$runnerAst.Extent.Text
    foreach($required in @('ArgumentList','RedirectStandardInput','StandardInput.Close','WaitForExitAsync','Kill($true)','RedirectStandardOutput','RedirectStandardError')){
        Assert-True ($runnerText.Contains($required)) "Runner is missing required bounded-process contract: $required"
    }

    $templateText=Get-Content -LiteralPath $providerTemplate -Raw
    $tokens=$null;$errors=$null
    [void][Management.Automation.Language.Parser]::ParseInput($templateText,[ref]$tokens,[ref]$errors)
    Assert-True (@($errors).Count -eq 0) 'Provider transaction template has parser errors.'

    $providerScript=Join-Path $tempRoot 'provider-switch-transaction.ps1'
    Set-Content -LiteralPath $providerScript -Value $templateText -Encoding UTF8
    $configPath=Join-Path $tempRoot 'provider.config'
    $backupDirectory=Join-Path $tempRoot 'provider-transactions'
    Set-Content -LiteralPath $configPath -Value 'provider=original' -Encoding UTF8
    & $providerScript -ConfigPath $configPath -BackupDirectory $backupDirectory `
        -ApplyScopedEdit { param($path) Set-Content -LiteralPath $path -Value 'provider=new' -Encoding UTF8 } `
        -PostCheck { param($path) (Get-Content -LiteralPath $path -Raw).Trim() -eq 'provider=new' } -Confirm:$false
    Assert-True ((Get-Content -LiteralPath $configPath -Raw).Trim() -eq 'provider=new') 'Provider apply transaction did not change the config.'
    $journal=(Get-ChildItem -LiteralPath $backupDirectory -Filter '*.transaction.json' -File | Select-Object -First 1).FullName
    & $providerScript -ConfigPath $configPath -TransactionPath $journal -Restore -Confirm:$false
    Assert-True ((Get-Content -LiteralPath $configPath -Raw).Trim() -eq 'provider=original') 'Provider restore transaction did not restore the config.'

    $rollbackObserved=$false
    try {
        & $providerScript -ConfigPath $configPath -BackupDirectory $backupDirectory `
            -ApplyScopedEdit { param($path) Set-Content -LiteralPath $path -Value 'provider=bad' -Encoding UTF8 } `
            -PostCheck { param($path) $false } -Confirm:$false
    } catch { $rollbackObserved=$true }
    Assert-True $rollbackObserved 'Failed provider post-check did not fail the transaction.'
    Assert-True ((Get-Content -LiteralPath $configPath -Raw).Trim() -eq 'provider=original') 'Failed provider transaction did not roll back.'

    if ($PSVersionTable.PSVersion.Major -ge 7) {
        $fakeCli=Join-Path $tempRoot 'fake-codex.exe'
        $source=@'
using System;
using System.Threading;
public static class FakeCodex {
    public static int Main(string[] args) {
        if (Environment.GetEnvironmentVariable("PWB_FAKE_TIMEOUT") == "1") { Thread.Sleep(5000); return 0; }
        Console.WriteLine("{\"type\":\"thread.started\",\"thread_id\":\"fake\"}");
        Console.WriteLine("{\"type\":\"turn.started\"}");
        Console.WriteLine("{\"type\":\"item.completed\",\"item\":{\"id\":\"message-1\",\"type\":\"agent_message\",\"text\":\"EXACT_OK\"}}");
        Console.WriteLine("{\"type\":\"turn.completed\"}");
        Console.Error.WriteLine("fixture-stderr");
        return 0;
    }
}
'@
        $sourcePath=Join-Path $tempRoot 'fake-codex.cs'
        Set-Content -LiteralPath $sourcePath -Value $source -Encoding UTF8
        $compilerCommand=Get-Command csc.exe -ErrorAction SilentlyContinue | Select-Object -First 1
        $compilerPath=if($compilerCommand){$compilerCommand.Source}else{$null}
        if (-not $compilerPath) {
            $frameworkCompiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
            if (Test-Path -LiteralPath $frameworkCompiler) { $compilerPath=$frameworkCompiler }
        }
        if (-not $compilerPath) { throw 'A local C# compiler is required for the PowerShell 7 bounded-runner contract test.' }
        & $compilerPath /nologo /target:exe "/out:$fakeCli" $sourcePath
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $fakeCli)) { throw 'Failed to compile the local fake Codex CLI.' }
        $captureOutput=@(& $runner -Prompt 'fixture prompt' -ModelId 'fixture-model' -ModelDigest 'fixture-digest' -DigestVerified `
            -ProviderId 'fixture-provider' -Endpoint 'http://127.0.0.1:11434' -EffectiveContext 4096 `
            -WorkingDirectory $tempRoot -OutputDirectory (Join-Path $tempRoot 'capture') -CodexPath $fakeCli)
        $capture=$captureOutput | Where-Object { $null -ne $_ -and $null -ne $_.PSObject.Properties['captureStatus'] } | Select-Object -Last 1
        Assert-True ($null -ne $capture) 'The bounded runner should return its metadata result object.'
        Assert-True ($capture.captureStatus -eq 'Completed' -and $capture.processExitCode -eq 0 -and -not $capture.timedOut) 'Bounded runner did not capture a successful process.'
        Assert-True ((Get-Content -LiteralPath $capture.artifacts.stderr -Raw).Trim() -eq 'fixture-stderr') 'Bounded runner did not capture stderr.'

        $env:PWB_FAKE_TIMEOUT='1'
        try {
            $timeoutOutput=@(& $runner -Prompt 'fixture timeout' -ModelId 'fixture-model' -ModelDigest 'fixture-digest' -DigestVerified `
                -ProviderId 'fixture-provider' -Endpoint 'http://127.0.0.1:11434' -EffectiveContext 4096 `
                -WorkingDirectory $tempRoot -OutputDirectory (Join-Path $tempRoot 'timeout-capture') -CodexPath $fakeCli -TimeoutSeconds 1)
        } finally { Remove-Item Env:PWB_FAKE_TIMEOUT -ErrorAction SilentlyContinue }
        $timeoutCapture=$timeoutOutput | Where-Object { $null -ne $_ -and $null -ne $_.PSObject.Properties['captureStatus'] } | Select-Object -Last 1
        Assert-True ($null -ne $timeoutCapture) 'The timeout runner should return its metadata result object.'
        Assert-True ($timeoutCapture.timedOut -and $timeoutCapture.captureStatus -eq 'TimedOut') 'Bounded runner did not report timeout.'
    }
    Write-Output 'PowerShell Workbench agent harness contracts passed.'
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
