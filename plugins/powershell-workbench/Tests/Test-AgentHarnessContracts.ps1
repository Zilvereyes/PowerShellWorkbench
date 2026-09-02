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
function Invoke-EvidenceValidation {
    param([string]$MetadataPath,[hashtable]$Parameters=@{})
    $invoke=@{MetadataPath=$MetadataPath;ExpectedMetadataSha256=(Get-FileHash -LiteralPath $MetadataPath -Algorithm SHA256).Hash;ExpectedExecutableSha256=$script:ExpectedExecutableHash;AcceptUnverifiedRuntimeDeclarations=$true;NoThrow=$true}
    foreach($key in $Parameters.Keys){$invoke[$key]=$Parameters[$key]}
    & $script:validator @invoke
}
function New-Metadata {
    param([string]$Jsonl,[bool]$TimedOut=$false,[int]$ProcessExitCode=0,[string]$CaptureStatus='Completed',[string]$ExecutablePath=$script:HostExecutable)
    $stderr=Join-Path $tempRoot ((Split-Path -Leaf $Jsonl)+'.stderr.log')
    Set-Content -LiteralPath $stderr -Value 'fixture-stderr' -Encoding UTF8
    $path=Join-Path $tempRoot ((Split-Path -Leaf $Jsonl)+'.metadata.json')
    [ordered]@{
        schemaVersion='2.0';captureStatus=$CaptureStatus;timedOut=$TimedOut;outputLimitExceeded=$false;processExitCode=$ProcessExitCode
        startedAt='2026-01-01T00:00:00Z';durationMs=1
        launch=[ordered]@{executablePath=$ExecutablePath;executableSha256=(Get-FileHash $ExecutablePath -Algorithm SHA256).Hash.ToLowerInvariant();workingDirectory=$tempRoot;argumentSha256=('a'*64)}
        declarations=[ordered]@{attestation='unverified-caller-declaration';model=[ordered]@{id='fixture-model';digest='fixture-digest'};provider=[ordered]@{id='fixture-provider';endpoint='http://127.0.0.1:11434/';isLoopback=$true};runtime=[ordered]@{effectiveContext=4096;sandbox='read-only';approvalPolicy='never';profile='fixture'}}
        input=[ordered]@{promptSha256=('b'*64);fixturePath=$Jsonl;fixtureSha256=(Get-FileHash $Jsonl -Algorithm SHA256).Hash.ToLowerInvariant()}
        limits=[ordered]@{timeoutSeconds=30;maxStdoutBytes=1048576;maxStderrBytes=1048576;maxTotalOutputBytes=2097152}
        artifacts=[ordered]@{stdoutJsonl=$Jsonl;stdoutBytes=(Get-Item $Jsonl).Length;stdoutSha256=(Get-FileHash $Jsonl -Algorithm SHA256).Hash.ToLowerInvariant();stderr=$stderr;stderrBytes=(Get-Item $stderr).Length;stderrSha256=(Get-FileHash $stderr -Algorithm SHA256).Hash.ToLowerInvariant()}
    }|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $path -Encoding UTF8
    $path
}

try {
    $script:HostExecutable=(Get-Process -Id $PID).Path
    $script:ExpectedExecutableHash=(Get-FileHash $script:HostExecutable -Algorithm SHA256).Hash
    $success=Join-Path $fixtures 'success.jsonl'
    $result=Invoke-EvidenceValidation -MetadataPath (New-Metadata $success) -Parameters @{MinimumSuccessfulToolCalls=1;ExpectedFinalText='EXACT_OK';RequireExactFinalText=$true}
    Assert-True $result.Passed 'Success fixture did not pass.'

    foreach($name in @('tool-failure-process-zero.jsonl','empty.jsonl','malformed.jsonl','no-tool-call.jsonl')){
        $path=Join-Path $fixtures $name
        $result=Invoke-EvidenceValidation -MetadataPath (New-Metadata $path) -Parameters @{MinimumSuccessfulToolCalls=1}
        Assert-True (-not $result.Passed) "$name produced a false positive."
    }
    $result=Invoke-EvidenceValidation -MetadataPath (New-Metadata $success) -Parameters @{ExpectedExecutableSha256=('0'*64)}
    Assert-True (-not $result.Passed) 'Executable substitution produced a false positive.'

    $tampered=Join-Path $tempRoot 'tampered.jsonl'
    Copy-Item -LiteralPath $success -Destination $tampered
    $metadataPath=New-Metadata $tampered
    Add-Content -LiteralPath $tampered -Value '{"type":"unknown.additive"}'
    $result=Invoke-EvidenceValidation -MetadataPath $metadataPath
    Assert-True (-not $result.Passed) 'Artifact substitution produced a false positive.'

    $substituted=Join-Path $tempRoot 'substituted.jsonl'
    Copy-Item -LiteralPath $success -Destination $substituted
    $metadataPath=New-Metadata $substituted
    $trustedMetadataHash=(Get-FileHash -LiteralPath $metadataPath -Algorithm SHA256).Hash
    Add-Content -LiteralPath $substituted -Value '{"type":"unknown.additive"}'
    $mutableMetadata=Get-Content -LiteralPath $metadataPath -Raw|ConvertFrom-Json
    $mutableMetadata.artifacts.stdoutBytes=(Get-Item -LiteralPath $substituted).Length
    $mutableMetadata.artifacts.stdoutSha256=(Get-FileHash -LiteralPath $substituted -Algorithm SHA256).Hash.ToLowerInvariant()
    $mutableMetadata|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $metadataPath -Encoding UTF8
    $result=& $validator -MetadataPath $metadataPath -ExpectedMetadataSha256 $trustedMetadataHash -ExpectedExecutableSha256 $script:ExpectedExecutableHash -AcceptUnverifiedRuntimeDeclarations -NoThrow
    Assert-True (-not $result.Passed) 'Metadata and artifact substitution bypassed the out-of-band digest.'

    $remoteMetadata=New-Metadata $success
    $remoteObject=Get-Content -LiteralPath $remoteMetadata -Raw|ConvertFrom-Json
    $remoteObject.declarations.provider.endpoint='https://example.com/'
    $remoteObject.declarations.provider.isLoopback=$true
    $remoteObject|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $remoteMetadata -Encoding UTF8
    $result=Invoke-EvidenceValidation -MetadataPath $remoteMetadata
    Assert-True (-not $result.Passed) 'A remote endpoint bypassed validation through a forged isLoopback declaration.'

    $lateMessage=Join-Path $tempRoot 'late-message.jsonl'
    @('{"type":"thread.started","thread_id":"x"}','{"type":"turn.started"}','{"type":"turn.completed"}','{"type":"item.completed","item":{"id":"message-late","type":"agent_message","text":"EXACT_OK"}}')|Set-Content -LiteralPath $lateMessage
    $result=Invoke-EvidenceValidation -MetadataPath (New-Metadata $lateMessage) -Parameters @{ExpectedFinalText='EXACT_OK';RequireExactFinalText=$true}
    Assert-True (-not $result.Passed) 'An agent message outside the active turn satisfied the final-text contract.'

    $largeStderrMetadata=New-Metadata $success
    $largeStderrObject=Get-Content -LiteralPath $largeStderrMetadata -Raw|ConvertFrom-Json
    $largeStderrPath=[string]$largeStderrObject.artifacts.stderr
    [IO.File]::WriteAllText($largeStderrPath,('x'*2048))
    $largeStderrObject.artifacts.stderrBytes=(Get-Item -LiteralPath $largeStderrPath).Length
    $largeStderrObject.artifacts.stderrSha256=(Get-FileHash -LiteralPath $largeStderrPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $largeStderrObject|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $largeStderrMetadata -Encoding UTF8
    $result=Invoke-EvidenceValidation -MetadataPath $largeStderrMetadata -Parameters @{MaxStderrBytes=1024}
    Assert-True (-not $result.Passed) 'Oversized stderr bypassed the validator-side byte limit.'

    $orphan=Join-Path $tempRoot 'orphan.jsonl'
    @('{"type":"thread.started","thread_id":"x"}','{"type":"turn.started"}','{"type":"item.completed","item":{"id":"x","type":"command_execution","status":"completed","exit_code":0}}','{"type":"turn.completed"}')|Set-Content $orphan
    $result=Invoke-EvidenceValidation -MetadataPath (New-Metadata $orphan) -Parameters @{MinimumSuccessfulToolCalls=1}
    Assert-True (-not $result.Passed) 'Orphan completion produced a false positive.'

    $retry=Join-Path $fixtures 'tool-retry.jsonl'
    $result=Invoke-EvidenceValidation -MetadataPath (New-Metadata $retry) -Parameters @{FailOnToolRetry=$true}
    Assert-True (-not $result.Passed) 'Tool retry passed a no-retry gate.'

    $tokens=$null;$errors=$null
    $runnerAst=[Management.Automation.Language.Parser]::ParseFile($runner,[ref]$tokens,[ref]$errors)
    Assert-True (@($errors).Count -eq 0) 'Runner has parser errors.'
    foreach($required in @('ArgumentList','StandardInput.Close','CopyToAsync','PWB_OUTPUT_LIMIT','Kill($true)','stdoutSha256','executableSha256')){
        Assert-True ($runnerAst.Extent.Text.Contains($required)) "Runner is missing contract: $required"
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
    & $providerScript -ConfigPath $configPath -BackupDirectory $backupDirectory -ApplyScopedEdit { param($path) Set-Content -LiteralPath $path -Value 'provider=new' -Encoding UTF8 } -PostCheck { param($path) (Get-Content -LiteralPath $path -Raw).Trim() -eq 'provider=new' } -Confirm:$false
    Assert-True ((Get-Content -LiteralPath $configPath -Raw).Trim() -eq 'provider=new') 'Provider apply transaction failed.'
    $journal=(Get-ChildItem -LiteralPath $backupDirectory -Filter '*.transaction.json' -File|Select-Object -First 1).FullName
    & $providerScript -ConfigPath $configPath -TransactionPath $journal -Restore -Confirm:$false
    Assert-True ((Get-Content -LiteralPath $configPath -Raw).Trim() -eq 'provider=original') 'Provider restore transaction failed.'

    if($PSVersionTable.PSVersion.Major -ge 7){
        $fakeCli=Join-Path $tempRoot 'fake-codex.exe'
        $source=@'
using System;
using System.Threading;
public static class FakeCodex {
    public static int Main(string[] args) {
        if (Environment.GetEnvironmentVariable("PWB_FAKE_TIMEOUT") == "1") { Thread.Sleep(5000); return 0; }
        if (Environment.GetEnvironmentVariable("PWB_FAKE_FLOOD") == "1") { Console.Write(new string('x', 8192)); return 0; }
        Console.WriteLine("{\"type\":\"thread.started\",\"thread_id\":\"fake\"}");
        Console.WriteLine("{\"type\":\"turn.started\"}");
        Console.WriteLine("{\"type\":\"item.completed\",\"item\":{\"id\":\"message-1\",\"type\":\"agent_message\",\"text\":\"EXACT_OK\"}}");
        Console.WriteLine("{\"type\":\"turn.completed\"}");
        Console.Error.WriteLine("fixture-stderr");
        return 0;
    }
}
'@
        $sourcePath=Join-Path $tempRoot 'fake-codex.cs';Set-Content $sourcePath $source
        $compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
        if(-not(Test-Path $compiler)){throw 'Local csc.exe is required.'}
        & $compiler /nologo /target:exe "/out:$fakeCli" $sourcePath
        $capture=& $runner -Prompt 'fixture' -ModelId 'fixture-model' -ModelDigest 'fixture-digest' -ProviderId 'fixture-provider' -Endpoint 'http://127.0.0.1:11434' -EffectiveContext 4096 -WorkingDirectory $tempRoot -OutputDirectory (Join-Path $tempRoot capture) -CodexPath $fakeCli
        Assert-True ($capture.captureStatus -eq 'Completed') 'Bounded runner legitimate control failed.'
        $validated=Invoke-EvidenceValidation -MetadataPath $capture.MetadataPath -Parameters @{ExpectedExecutableSha256=(Get-FileHash $fakeCli -Algorithm SHA256).Hash;ExpectedFinalText='EXACT_OK';RequireExactFinalText=$true}
        Assert-True $validated.Passed 'Captured legitimate control did not validate.'

        $env:PWB_FAKE_FLOOD='1'
        try{$limited=& $runner -Prompt 'flood' -ModelId x -ModelDigest x -ProviderId x -Endpoint 'http://127.0.0.1:1' -EffectiveContext 1 -WorkingDirectory $tempRoot -OutputDirectory (Join-Path $tempRoot flood) -CodexPath $fakeCli -MaxStdoutBytes 1024 -MaxStderrBytes 1024 -MaxTotalOutputBytes 2048}
        finally{Remove-Item Env:PWB_FAKE_FLOOD -ErrorAction SilentlyContinue}
        Assert-True ($limited.outputLimitExceeded -and $limited.captureStatus -eq 'OutputLimitExceeded') 'Output limit was not enforced.'
    }
    'PowerShell Workbench agent harness contracts passed.'
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
