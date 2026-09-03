[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$pluginRoot = Split-Path -Parent $PSScriptRoot
$validator = Join-Path $pluginRoot 'scripts\Test-PowerShellWorkbenchCodexEvidence.ps1'
$runner = Join-Path $pluginRoot 'scripts\Invoke-PowerShellWorkbenchCodexJson.ps1'
$desktopResolver = Join-Path $pluginRoot 'scripts\Resolve-PowerShellWorkbenchCodexDesktop.ps1'
$catalogGenerator = Join-Path $pluginRoot 'scripts\New-PowerShellWorkbenchLocalModelCatalog.ps1'
$gateResolver = Join-Path $pluginRoot 'scripts\Resolve-PowerShellWorkbenchGateGroups.ps1'
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
function New-EvidenceFixture {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Jsonl,[bool]$TimedOut=$false,[int]$ProcessExitCode=0,[string]$CaptureStatus='Completed',[string]$ExecutablePath=$script:HostExecutable,[string]$StderrFixture)
    $stderr=Join-Path $tempRoot ((Split-Path -Leaf $Jsonl)+'.stderr.log')
    if($StderrFixture){Copy-Item -LiteralPath $StderrFixture -Destination $stderr}else{Set-Content -LiteralPath $stderr -Value 'fixture-stderr' -Encoding UTF8}
    $path=Join-Path $tempRoot ((Split-Path -Leaf $Jsonl)+'.metadata.json')
    if($PSCmdlet.ShouldProcess($path,'Create isolated evidence metadata fixture')){
    [ordered]@{
        schemaVersion='2.0';captureStatus=$CaptureStatus;timedOut=$TimedOut;outputLimitExceeded=$false;processExitCode=$ProcessExitCode
        startedAt='2026-01-01T00:00:00Z';durationMs=1
        launch=[ordered]@{executablePath=$ExecutablePath;executableSha256=(Get-FileHash $ExecutablePath -Algorithm SHA256).Hash.ToLowerInvariant();workingDirectory=$tempRoot;argumentSha256=('a'*64)}
        declarations=[ordered]@{attestation='unverified-caller-declaration';model=[ordered]@{id='fixture-model';digest='fixture-digest'};provider=[ordered]@{id='fixture-provider';endpoint='http://127.0.0.1:11434/';isLoopback=$true};runtime=[ordered]@{effectiveContext=4096;sandbox='read-only';approvalPolicy='never';profile='fixture'}}
        input=[ordered]@{promptSha256=('b'*64);fixturePath=$Jsonl;fixtureSha256=(Get-FileHash $Jsonl -Algorithm SHA256).Hash.ToLowerInvariant()}
        limits=[ordered]@{timeoutSeconds=30;maxStdoutBytes=1048576;maxStderrBytes=1048576;maxTotalOutputBytes=2097152}
        artifacts=[ordered]@{stdoutJsonl=$Jsonl;stdoutBytes=(Get-Item $Jsonl).Length;stdoutSha256=(Get-FileHash $Jsonl -Algorithm SHA256).Hash.ToLowerInvariant();stderr=$stderr;stderrBytes=(Get-Item $stderr).Length;stderrSha256=(Get-FileHash $stderr -Algorithm SHA256).Hash.ToLowerInvariant()}
    }|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $path -Encoding UTF8
    }
    $path
}

try {
    $script:HostExecutable=(Get-Process -Id $PID).Path
    $script:ExpectedExecutableHash=(Get-FileHash $script:HostExecutable -Algorithm SHA256).Hash
    $success=Join-Path $fixtures 'success.jsonl'
    $result=Invoke-EvidenceValidation -MetadataPath (New-EvidenceFixture $success) -Parameters @{MinimumSuccessfulToolCalls=1;ExpectedFinalText='EXACT_OK';RequireExactFinalText=$true}
    Assert-True $result.Passed 'Success fixture did not pass.'

    $itemError=Join-Path $fixtures 'item-error.jsonl'
    $result=Invoke-EvidenceValidation -MetadataPath (New-EvidenceFixture $itemError) -Parameters @{ExpectedFinalText='EXACT_OK';RequireExactFinalText=$true}
    Assert-True (-not $result.Passed) 'An item-level error produced a false positive.'

    $advisory=Join-Path $tempRoot 'advisory.jsonl'
    @('{"type":"thread.started","thread_id":"x"}','{"type":"turn.started"}','{"type":"item.completed","item":{"id":"advisory-1","type":"error","status":"completed","text":"Skill descriptions were truncated to fit the skills budget."}}','{"type":"item.completed","item":{"id":"message-1","type":"agent_message","text":"EXACT_OK"}}','{"type":"turn.completed"}')|Set-Content -LiteralPath $advisory -Encoding UTF8
    $result=Invoke-EvidenceValidation -MetadataPath (New-EvidenceFixture $advisory) -Parameters @{ExpectedFinalText='EXACT_OK';RequireExactFinalText=$true}
    Assert-True (-not $result.Passed) 'An advisory error passed without explicit allowlisting.'
    $result=Invoke-EvidenceValidation -MetadataPath (New-EvidenceFixture $advisory) -Parameters @{ExpectedFinalText='EXACT_OK';RequireExactFinalText=$true;AllowedAdvisoryRegex=@('^Skill descriptions were truncated to fit the skills budget\.$')}
    Assert-True $result.Passed 'An exact opt-in advisory allowlist did not apply.'
    $policyAdvisory=Join-Path $tempRoot 'policy-advisory.jsonl'
    @('{"type":"thread.started","thread_id":"x"}','{"type":"turn.started"}','{"type":"item.completed","item":{"id":"advisory-1","type":"error","status":"completed","text":"Policy error: access denied."}}','{"type":"item.completed","item":{"id":"message-1","type":"agent_message","text":"EXACT_OK"}}','{"type":"turn.completed"}')|Set-Content -LiteralPath $policyAdvisory -Encoding UTF8
    $result=Invoke-EvidenceValidation -MetadataPath (New-EvidenceFixture $policyAdvisory) -Parameters @{ExpectedFinalText='EXACT_OK';RequireExactFinalText=$true;AllowedAdvisoryRegex=@('^Policy error: access denied\.$')}
    Assert-True (-not $result.Passed) 'A policy failure bypassed the advisory allowlist.'

    $stderrError=Join-Path $fixtures 'stderr-error.log'
    $result=Invoke-EvidenceValidation -MetadataPath (New-EvidenceFixture $success -StderrFixture $stderrError)
    Assert-True (-not $result.Passed) 'A stderr error signal produced a false positive.'
    $result=Invoke-EvidenceValidation -MetadataPath (New-EvidenceFixture $success -StderrFixture $stderrError) -Parameters @{AllowedStderrRegex=@('^ERROR known harmless fixture$')}
    Assert-True $result.Passed 'An explicit narrow stderr allowlist did not apply.'

    foreach($name in @('tool-failure-process-zero.jsonl','empty.jsonl','malformed.jsonl','no-tool-call.jsonl')){
        $path=Join-Path $fixtures $name
        $result=Invoke-EvidenceValidation -MetadataPath (New-EvidenceFixture $path) -Parameters @{MinimumSuccessfulToolCalls=1}
        Assert-True (-not $result.Passed) "$name produced a false positive."
    }
    $result=Invoke-EvidenceValidation -MetadataPath (New-EvidenceFixture $success) -Parameters @{ExpectedExecutableSha256=('0'*64)}
    Assert-True (-not $result.Passed) 'Executable substitution produced a false positive.'

    $result=Invoke-EvidenceValidation -MetadataPath (New-EvidenceFixture $success) -Parameters @{ExpectedModelId='different-model';ExpectedModelDigest='different-digest';ExpectedEffectiveContext=1;ExpectedCatalogSha256=('0'*64)}
    Assert-True (-not $result.Passed) 'Model, context, or catalog substitution produced a false positive.'

    $tampered=Join-Path $tempRoot 'tampered.jsonl'
    Copy-Item -LiteralPath $success -Destination $tampered
    $metadataPath=New-EvidenceFixture $tampered
    Add-Content -LiteralPath $tampered -Value '{"type":"unknown.additive"}'
    $result=Invoke-EvidenceValidation -MetadataPath $metadataPath
    Assert-True (-not $result.Passed) 'Artifact substitution produced a false positive.'

    $substituted=Join-Path $tempRoot 'substituted.jsonl'
    Copy-Item -LiteralPath $success -Destination $substituted
    $metadataPath=New-EvidenceFixture $substituted
    $trustedMetadataHash=(Get-FileHash -LiteralPath $metadataPath -Algorithm SHA256).Hash
    Add-Content -LiteralPath $substituted -Value '{"type":"unknown.additive"}'
    $mutableMetadata=Get-Content -LiteralPath $metadataPath -Raw|ConvertFrom-Json
    $mutableMetadata.artifacts.stdoutBytes=(Get-Item -LiteralPath $substituted).Length
    $mutableMetadata.artifacts.stdoutSha256=(Get-FileHash -LiteralPath $substituted -Algorithm SHA256).Hash.ToLowerInvariant()
    $mutableMetadata|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $metadataPath -Encoding UTF8
    $result=& $validator -MetadataPath $metadataPath -ExpectedMetadataSha256 $trustedMetadataHash -ExpectedExecutableSha256 $script:ExpectedExecutableHash -AcceptUnverifiedRuntimeDeclarations -NoThrow
    Assert-True (-not $result.Passed) 'Metadata and artifact substitution bypassed the out-of-band digest.'

    $remoteMetadata=New-EvidenceFixture $success
    $remoteObject=Get-Content -LiteralPath $remoteMetadata -Raw|ConvertFrom-Json
    $remoteObject.declarations.provider.endpoint='https://example.com/'
    $remoteObject.declarations.provider.isLoopback=$true
    $remoteObject|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $remoteMetadata -Encoding UTF8
    $result=Invoke-EvidenceValidation -MetadataPath $remoteMetadata
    Assert-True (-not $result.Passed) 'A remote endpoint bypassed validation through a forged isLoopback declaration.'

    $lateMessage=Join-Path $tempRoot 'late-message.jsonl'
    @('{"type":"thread.started","thread_id":"x"}','{"type":"turn.started"}','{"type":"turn.completed"}','{"type":"item.completed","item":{"id":"message-late","type":"agent_message","text":"EXACT_OK"}}')|Set-Content -LiteralPath $lateMessage
    $result=Invoke-EvidenceValidation -MetadataPath (New-EvidenceFixture $lateMessage) -Parameters @{ExpectedFinalText='EXACT_OK';RequireExactFinalText=$true}
    Assert-True (-not $result.Passed) 'An agent message outside the active turn satisfied the final-text contract.'

    $largeStderrMetadata=New-EvidenceFixture $success
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
    $result=Invoke-EvidenceValidation -MetadataPath (New-EvidenceFixture $orphan) -Parameters @{MinimumSuccessfulToolCalls=1}
    Assert-True (-not $result.Passed) 'Orphan completion produced a false positive.'

    $retry=Join-Path $fixtures 'tool-retry.jsonl'
    $result=Invoke-EvidenceValidation -MetadataPath (New-EvidenceFixture $retry) -Parameters @{FailOnToolRetry=$true}
    Assert-True (-not $result.Passed) 'Tool retry passed a no-retry gate.'

    $tokens=$null;$errors=$null
    $runnerAst=[Management.Automation.Language.Parser]::ParseFile($runner,[ref]$tokens,[ref]$errors)
    Assert-True (@($errors).Count -eq 0) 'Runner has parser errors.'
    foreach($required in @('ArgumentList','StandardInput.Close','CopyToAsync','PWB_OUTPUT_LIMIT','Kill($true)','stdoutSha256','executableSha256','Resolve-PowerShellWorkbenchCodexDesktop.ps1','CatalogManifestPath','codexVersion','catalogSha256')){
        Assert-True ($runnerAst.Extent.Text.Contains($required)) "Runner is missing contract: $required"
    }

    foreach($scriptPath in @($desktopResolver,$catalogGenerator,$gateResolver)){
        $tokens=$null;$errors=$null
        [void][Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$errors)
        Assert-True (@($errors).Count -eq 0) "Harness helper has parser errors: $scriptPath"
    }

    $templateText=Get-Content -LiteralPath $providerTemplate -Raw
    $tokens=$null;$errors=$null
    [void][Management.Automation.Language.Parser]::ParseInput($templateText,[ref]$tokens,[ref]$errors)
    Assert-True (@($errors).Count -eq 0) 'Provider transaction template has parser errors.'
    $resumeSection=[regex]::Match($templateText,'(?s)if \(\$PSCmdlet\.ParameterSetName -eq ''Resume''\).*?(?=if \(\$PSCmdlet\.ParameterSetName -eq ''Restore''\))').Value
    Assert-True (-not [string]::IsNullOrWhiteSpace($resumeSection)) 'Read-only resume section was not found.'
    Assert-True ($resumeSection -notmatch '&\s*\$') 'Read-only resume decision invokes a caller-supplied scriptblock.'
    $providerScript=Join-Path $tempRoot 'provider-switch-transaction.ps1'
    Set-Content -LiteralPath $providerScript -Value $templateText -Encoding UTF8
    $configPath=Join-Path $tempRoot 'provider.config'
    $backupDirectory=Join-Path $tempRoot 'provider-transactions'
    Set-Content -LiteralPath $configPath -Value '{"provider":"original","model":"cloud","context":4096}' -Encoding UTF8
    $whatIfBackupDirectory=Join-Path $tempRoot 'what-if-provider-transactions'
    & $providerScript -ConfigPath $configPath -BackupDirectory $whatIfBackupDirectory `
        -ProviderId 'ollama' -ModelId 'fixture-model' -EffectiveContext 131072 -OwnedKeys @('provider','model','context') `
        -ApplyScopedEdit { throw 'WhatIf invoked provider edit.' } -PostCheck { throw 'WhatIf invoked post-check.' } `
        -GetOwnedState { throw 'WhatIf invoked owned-state reader.' } -WhatIf
    Assert-True (-not (Test-Path -LiteralPath $whatIfBackupDirectory)) 'Provider -WhatIf created a backup directory.'
    $applyInvocation=[pscustomobject]@{Count=0}
    $ownedStateReader={
        param($path,$keys)
        [void]$keys
        $state=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
        [pscustomobject]@{providerId=$state.provider;modelId=$state.model;effectiveContext=[int]$state.context;ownedValues=$state}
    }
    $applyResult=& $providerScript -ConfigPath $configPath -BackupDirectory $backupDirectory `
        -ProviderId 'ollama' -ModelId 'fixture-model' -EffectiveContext 131072 -OwnedKeys @('provider','model','context') `
        -ApplyScopedEdit { param($path) $applyInvocation.Count++;Set-Content -LiteralPath $path -Value '{"provider":"ollama","model":"fixture-model","context":131072}' -Encoding UTF8 } `
        -PostCheck { param($path) ((Get-Content -LiteralPath $path -Raw|ConvertFrom-Json).provider -eq 'ollama') } `
        -GetOwnedState $ownedStateReader -Confirm:$false
    Assert-True ($applyResult.phase -eq 'Ready') 'Provider apply transaction did not reach Ready.'
    Assert-True ((Get-Content -LiteralPath $configPath -Raw|ConvertFrom-Json).provider -eq 'ollama') 'Provider apply transaction failed.'
    $committedConfigPath=Join-Path $tempRoot 'committed-provider.config'
    Copy-Item -LiteralPath $configPath -Destination $committedConfigPath
    $journal=(Get-ChildItem -LiteralPath $backupDirectory -Filter '*.transaction.json' -File|Select-Object -First 1).FullName
    $resume=& $providerScript -ConfigPath $configPath -TransactionPath $journal -ResumeDecision `
        -ProviderId 'ollama' -ModelId 'fixture-model' -EffectiveContext 131072 -OwnedKeys @('provider','model','context')
    Assert-True ($resume.decision -eq 'AlreadyReady' -and -not $resume.applyRequired) 'A verified Ready transaction was not recognized read-only.'
    Assert-True ($applyInvocation.Count -eq 1) 'Resume decision repeated the provider switch.'
    $missing=& $providerScript -ConfigPath $configPath -TransactionPath (Join-Path $backupDirectory 'missing.transaction.json') -ResumeDecision `
        -ProviderId 'ollama' -ModelId 'fixture-model' -EffectiveContext 131072 -OwnedKeys @('provider','model','context')
    Assert-True (-not $missing.eligible -and @($missing.failedGates).Count -eq 1 -and $missing.failedGates[0] -eq 'TransactionJournalPresent') 'Missing journal did not fail closed with its exact gate.'

    $interruptedPath=Join-Path $backupDirectory 'interrupted.transaction.json'
    $interrupted=Get-Content -LiteralPath $journal -Raw|ConvertFrom-Json
    $interrupted.phaseHistory=@($interrupted.phaseHistory|Select-Object -First ($interrupted.phaseHistory.Count-1))
    $interrupted.phase='PostCheckPending'
    $interrupted.updatedAt=$interrupted.phaseHistory[-1].recordedAt
    $interrupted|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $interruptedPath -Encoding UTF8
    $resume=& $providerScript -ConfigPath $configPath -TransactionPath $interruptedPath -ResumeDecision `
        -ProviderId 'ollama' -ModelId 'fixture-model' -EffectiveContext 131072 -OwnedKeys @('provider','model','context')
    Assert-True ($resume.decision -eq 'PostCheckRequired' -and -not $resume.applyRequired -and $resume.postCheckRequired) 'Interrupted-after-commit resume attempted to repeat the provider switch.'
    Assert-True ($applyInvocation.Count -eq 1) 'Interrupted resume executed the provider edit.'

    $unknownPath=Join-Path $backupDirectory 'unknown.transaction.json'
    $unknown=Get-Content -LiteralPath $journal -Raw|ConvertFrom-Json;$unknown.phase='UnknownPhase'
    $unknown|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $unknownPath -Encoding UTF8
    $resume=& $providerScript -ConfigPath $configPath -TransactionPath $unknownPath -ResumeDecision `
        -ProviderId 'ollama' -ModelId 'fixture-model' -EffectiveContext 131072 -OwnedKeys @('provider','model','context')
    Assert-True (-not $resume.eligible -and $resume.failedGates -contains 'TransactionPhaseKnown') 'Unknown transaction phase did not fail closed with its exact gate.'

    $resume=& $providerScript -ConfigPath $configPath -TransactionPath $journal -ResumeDecision `
        -ProviderId 'ollama' -ModelId 'fixture-model' -EffectiveContext 131072 -OwnedKeys @('provider','model','context') `
        -EvaluationTimeUtc ([datetime]::UtcNow.AddDays(2))
    Assert-True (-not $resume.eligible -and $resume.failedGates -contains 'TransactionJournalFresh') 'Stale transaction journal did not fail closed with its exact gate.'

    Set-Content -LiteralPath $configPath -Value '{"provider":"drifted","model":"fixture-model","context":131072}' -Encoding UTF8
    $resume=& $providerScript -ConfigPath $configPath -TransactionPath $journal -ResumeDecision `
        -ProviderId 'ollama' -ModelId 'fixture-model' -EffectiveContext 131072 -OwnedKeys @('provider','model','context')
    Assert-True (-not $resume.eligible -and @($resume.failedGates).Count -eq 1 -and $resume.failedGates[0] -eq 'ConfigHashMatchesCommittedPhase') 'Config drift did not preserve the exact failed-gate name.'
    $restoreDriftRejected=$false
    try { & $providerScript -ConfigPath $configPath -TransactionPath $journal -Restore -Confirm:$false }
    catch { $restoreDriftRejected=($_.Exception.Message -eq "Restore blocked by failed gate 'ConfigHashMatchesRestoreSourcePhase'.") }
    Assert-True $restoreDriftRejected 'Restore did not fail closed with its exact gate when current config drifted.'
    Assert-True ((Get-Content -LiteralPath $configPath -Raw|ConvertFrom-Json).provider -eq 'drifted') 'Rejected restore overwrote drifted config.'
    Copy-Item -LiteralPath $committedConfigPath -Destination $configPath -Force
    & $providerScript -ConfigPath $configPath -TransactionPath $journal -Restore -Confirm:$false
    Assert-True ((Get-Content -LiteralPath $configPath -Raw|ConvertFrom-Json).provider -eq 'original') 'Provider restore transaction failed.'
    $nonBooleanRejected=$false
    try {
        & $providerScript -ConfigPath $configPath -BackupDirectory (Join-Path $tempRoot 'nonboolean-transactions') `
            -ProviderId 'ollama' -ModelId 'fixture-model' -EffectiveContext 131072 -OwnedKeys @('provider','model','context') `
            -ApplyScopedEdit { param($path) Set-Content -LiteralPath $path -Value '{"provider":"ollama","model":"fixture-model","context":131072}' -Encoding UTF8 } `
            -PostCheck { param($path) [void]$path; 'true' } -GetOwnedState $ownedStateReader -Confirm:$false|Out-Null
    } catch { $nonBooleanRejected=$true }
    Assert-True $nonBooleanRejected 'A non-Boolean provider post-check was accepted.'
    Assert-True ((Get-Content -LiteralPath $configPath -Raw|ConvertFrom-Json).provider -eq 'original') 'Failed non-Boolean post-check did not restore the backup.'

    $gates=@(
        [pscustomobject]@{Name='LocalProfileVerified';Passed=$true},
        [pscustomobject]@{Name='LoopbackEndpointVerified';Passed=$true},
        [pscustomobject]@{Name='DesktopProcessElevation';Passed=$false},
        [pscustomobject]@{Name='ClipboardPreparation';Passed=$false}
    )
    $groups=@(
        [pscustomobject]@{Name='RuntimePreparation';RequiredGates=@('LocalProfileVerified','LoopbackEndpointVerified')},
        [pscustomobject]@{Name='HostCertification';RequiredGates=@('LocalProfileVerified','LoopbackEndpointVerified','DesktopProcessElevation','ClipboardPreparation')}
    )
    $runtimeDecision=& $gateResolver -Gate $gates -GateGroup $groups -RequiredGroup 'RuntimePreparation'
    Assert-True $runtimeDecision.Passed 'RuntimePreparation was incorrectly blocked by host-only gates.'
    $certificationDecision=& $gateResolver -Gate $gates -GateGroup $groups -RequiredGroup 'HostCertification'
    Assert-True (-not $certificationDecision.Passed) 'HostCertification bypassed host-only gates.'
    Assert-True ((@($certificationDecision.FailedGates) -join ',') -eq 'DesktopProcessElevation,ClipboardPreparation') 'Gate-group result did not preserve exact failed-gate names and order.'
    $duplicateRejected=$false;try{& $gateResolver -Gate $gates -GateGroup @([pscustomobject]@{Name='Bad';RequiredGates=@('LocalProfileVerified','LocalProfileVerified')})|Out-Null}catch{$duplicateRejected=$true}
    Assert-True $duplicateRejected 'Duplicate gate names inside a group were accepted.'

    if($PSVersionTable.PSVersion.Major -ge 7){
        $fakeCli=Join-Path $tempRoot 'fake-codex.exe'
        $source=@'
using System;
using System.Threading;
public static class FakeCodex {
    public static int Main(string[] args) {
        if (args.Length == 1 && args[0] == "--version") { Console.WriteLine("codex-cli 0.0.0"); return 0; }
        if (args.Length == 3 && args[0] == "debug" && args[1] == "models" && args[2] == "--bundled") {
            Console.WriteLine("{\"models\":[{\"slug\":\"online-first\",\"display_name\":\"Online first\",\"description\":\"fixture\",\"shell_type\":\"unified_exec\",\"use_responses_lite\":true,\"tool_mode\":\"code_mode_only\",\"multi_agent_version\":\"v2\",\"service_tier\":\"priority\",\"supports_search_tool\":true},{\"slug\":\"gpt-5.4-mini\",\"display_name\":\"Legacy compatible\",\"description\":\"fixture\",\"shell_type\":\"unified_exec\",\"use_responses_lite\":false,\"service_tiers\":[\"priority\"],\"supports_search_tool\":false}]}");
            return 0;
        }
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
        $catalogPath=Join-Path $tempRoot 'fixture-catalog.json';Set-Content -LiteralPath $catalogPath -Value '{"models":[]}' -Encoding UTF8
        $catalogSha256=(Get-FileHash -LiteralPath $catalogPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $catalogManifestPath=Join-Path $tempRoot 'fixture-catalog.manifest.json'
        [ordered]@{model='fixture-model';contextWindow=4096;codexVersion='0.0.0';codexSha256=(Get-FileHash -LiteralPath $fakeCli -Algorithm SHA256).Hash.ToLowerInvariant();catalogPath=$catalogPath;catalogSha256=$catalogSha256}|ConvertTo-Json|Set-Content -LiteralPath $catalogManifestPath -Encoding UTF8
        $capture=& $runner -Prompt 'fixture' -ModelId 'fixture-model' -ModelDigest 'fixture-digest' -ProviderId 'fixture-provider' -Endpoint 'http://127.0.0.1:11434' -EffectiveContext 4096 -WorkingDirectory $tempRoot -OutputDirectory (Join-Path $tempRoot capture) -CodexPath $fakeCli -CatalogManifestPath $catalogManifestPath
        Assert-True ($capture.captureStatus -eq 'Completed') 'Bounded runner legitimate control failed.'
        $validated=Invoke-EvidenceValidation -MetadataPath $capture.MetadataPath -Parameters @{ExpectedExecutableSha256=(Get-FileHash $fakeCli -Algorithm SHA256).Hash;ExpectedCodexVersion='0.0.0';ExpectedModelId='fixture-model';ExpectedModelDigest='fixture-digest';ExpectedEffectiveContext=4096;ExpectedCatalogSha256=$catalogSha256;ExpectedFinalText='EXACT_OK';RequireExactFinalText=$true}
        Assert-True $validated.Passed 'Captured legitimate control did not validate.'

        $generatedCatalogPath=Join-Path $tempRoot 'generated-local-catalog.json'
        $generatedCatalog=& $catalogGenerator -Model 'qwen3.5:9b' -ContextWindow 131072 -CodexPath $fakeCli -OutputPath $generatedCatalogPath
        $generatedModel=((Get-Content -LiteralPath $generatedCatalog.CatalogPath -Raw)|ConvertFrom-Json).models|Select-Object -First 1
        $generatedManifest=Get-Content -LiteralPath $generatedCatalog.ManifestPath -Raw|ConvertFrom-Json
        Assert-True ($generatedManifest.baseModelSlug -eq 'gpt-5.4-mini') 'Catalog generator did not prefer the legacy-compatible unified_exec template.'
        Assert-True (-not $generatedModel.use_responses_lite) 'Generated local catalog retained Responses Lite.'
        Assert-True ($null -eq $generatedModel.PSObject.Properties['tool_mode']) 'Generated local catalog retained code-mode transport.'
        Assert-True ($null -eq $generatedModel.PSObject.Properties['multi_agent_version']) 'Generated local catalog retained multi-agent transport.'
        Assert-True ($null -eq $generatedModel.PSObject.Properties['service_tier']) 'Generated local catalog retained a cloud service tier.'
        Assert-True ($null -eq $generatedModel.PSObject.Properties['service_tiers']) 'Generated local catalog retained cloud service tiers.'
        Assert-True (-not $generatedModel.supports_search_tool) 'Generated local catalog retained search-tool support.'
        Assert-True ($generatedManifest.unassertedCapabilities -contains 'responses-lite') 'Catalog manifest did not record unasserted Responses Lite transport.'
        Assert-True ($generatedManifest.unassertedCapabilities -contains 'service-tier') 'Catalog manifest did not record unasserted service-tier transport.'

        $originalLocalAppData=$env:LOCALAPPDATA
        $desktopRoot=Join-Path $tempRoot 'OpenAI\Codex\bin\fixture';New-Item -ItemType Directory -Path $desktopRoot -Force|Out-Null
        Copy-Item -LiteralPath $fakeCli -Destination (Join-Path $desktopRoot 'codex.exe')
        try{
            $env:LOCALAPPDATA=$tempRoot
            $defaultCatalog=& $catalogGenerator -Model 'qwen3.5:9b' -ContextWindow 131072 -OutputPath (Join-Path $tempRoot 'default-catalog.json')
            Assert-True ($defaultCatalog.Result -eq 'GENERATED') 'Catalog generator failed when ExpectedCodexSha256 was omitted.'
            $desktopHash=(Get-FileHash -LiteralPath (Join-Path $desktopRoot 'codex.exe') -Algorithm SHA256).Hash
            $hashedCatalog=& $catalogGenerator -Model 'qwen3.5:9b' -ContextWindow 131072 -ExpectedCodexSha256 $desktopHash -OutputPath (Join-Path $tempRoot 'hashed-catalog.json')
            Assert-True ($hashedCatalog.Result -eq 'GENERATED') 'Catalog generator rejected the correct ExpectedCodexSha256.'
            $wrongHashRejected=$false;try{& $catalogGenerator -Model 'qwen3.5:9b' -ContextWindow 131072 -ExpectedCodexSha256 ('0'*64) -OutputPath (Join-Path $tempRoot 'wrong-hash-catalog.json')|Out-Null}catch{$wrongHashRejected=$true}
            Assert-True $wrongHashRejected 'Catalog generator accepted an incorrect ExpectedCodexSha256.'
        }finally{$env:LOCALAPPDATA=$originalLocalAppData}

        $env:PWB_FAKE_FLOOD='1'
        try{$limited=& $runner -Prompt 'flood' -ModelId x -ModelDigest x -ProviderId x -Endpoint 'http://127.0.0.1:1' -EffectiveContext 1 -WorkingDirectory $tempRoot -OutputDirectory (Join-Path $tempRoot flood) -CodexPath $fakeCli -MaxStdoutBytes 1024 -MaxStderrBytes 1024 -MaxTotalOutputBytes 2048}
        finally{Remove-Item Env:PWB_FAKE_FLOOD -ErrorAction SilentlyContinue}
        Assert-True ($limited.outputLimitExceeded -and $limited.captureStatus -eq 'OutputLimitExceeded') 'Output limit was not enforced.'
    }
    'PowerShell Workbench agent harness contracts passed.'
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
