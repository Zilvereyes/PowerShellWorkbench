$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$adapter = Join-Path $root 'scripts\Invoke-PowerShellWorkbenchOllamaChat.ps1'
$validator = Join-Path $root 'scripts\Test-PowerShellWorkbenchOllamaEvidence.ps1'
$digest = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'

function Assert-True { param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message} }
function Assert-Throw { param([scriptblock]$Action,[string]$Pattern) try{& $Action;throw 'Expected failure was not raised.'}catch{if($_.Exception.Message -notmatch $Pattern){throw "Unexpected failure: $($_.Exception.Message)"}} }

foreach($path in @($adapter,$validator)){
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    Assert-True ($errors.Count -eq 0) "$path has parser errors."
    $commands=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst]},$true)|ForEach-Object{$_.GetCommandName()}|Where-Object{$_})
    foreach($forbidden in @('Start-Process','Invoke-Expression','Set-Clipboard','git','gh')){Assert-True ($commands -notcontains $forbidden) "$path contains forbidden command $forbidden."}
    if($path -eq $validator){Assert-True ($commands -notcontains 'Get-FileHash' -and $commands -notcontains 'Get-Content') 'Evidence validator reintroduced separate hash and parse reads.'}
}

$tempRoot=Join-Path ([IO.Path]::GetTempPath()) ('pwb-ollama-contract-'+[guid]::NewGuid().ToString('N'))
$neverCreated=Join-Path $tempRoot 'analyze-output'
try{
    New-Item -ItemType Directory -Path $tempRoot|Out-Null
    $first=& $adapter -Prompt 'Explain the fixture.' -ModelId 'fixture-model' -ModelDigest $digest -OutputDirectory $neverCreated
    $second=& $adapter -Prompt 'Explain the fixture.' -ModelId 'fixture-model' -ModelDigest $digest -OutputDirectory $neverCreated
    Assert-True ($first.result -eq 'ANALYZE_ONLY' -and -not $first.networkPerformed -and -not $first.writePerformed -and -not $first.toolExecutionPerformed) 'AnalyzeOnly performed an effect.'
    Assert-True ($first.requestSha256 -eq $second.requestSha256) 'AnalyzeOnly request identity was not deterministic.'
    $withContext=& $adapter -Prompt 'Explain the fixture.' -ModelId 'fixture-model' -ModelDigest $digest -OutputDirectory $neverCreated -ContextTokens 8192
    Assert-True ($withContext.result -eq 'ANALYZE_ONLY' -and $withContext.requestedContextTokens -eq 8192 -and $null -eq $withContext.observedContextTokens -and $withContext.requestSha256 -ne $first.requestSha256) 'Explicit requested context was not bound into the analysis request while observation remained unknown.'
    Assert-True (-not(Test-Path -LiteralPath $neverCreated)) 'AnalyzeOnly created its output directory.'
    Assert-Throw {& $adapter -Prompt x -ModelId x -ModelDigest $digest -Endpoint 'https://127.0.0.1:11434/api/chat'} 'must use http'
    Assert-Throw {& $adapter -Prompt x -ModelId x -ModelDigest $digest -Endpoint 'http://127.0.0.1:11434/api/generate'} 'exact credential-free'
    Assert-Throw {& $adapter -Prompt x -ModelId x -ModelDigest $digest -Endpoint 'http://example.test:11434/api/chat'} 'literal loopback IP'
    Assert-Throw {& $adapter -Prompt x -ModelId x -ModelDigest $digest -Endpoint 'http://localhost:11434/api/chat'} 'literal loopback IP'
    $ipv6=& $adapter -Prompt x -ModelId x -ModelDigest $digest -Endpoint 'http://[::1]:11434/api/chat'
    Assert-True ($ipv6.result -eq 'ANALYZE_ONLY' -and -not $ipv6.networkPerformed) 'Literal IPv6 loopback preview failed.'

    $responseJson='{"model":"fixture-model","created_at":"2026-09-06T00:00:00Z","message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"read_fixture","arguments":{"path":"fixture.txt"}}}]},"done":true,"total_duration":123,"prompt_eval_count":4,"eval_count":2}'
    $fixturePath=Join-Path $tempRoot 'response-fixture.json'
    [IO.File]::WriteAllText($fixturePath,$responseJson,(New-Object Text.UTF8Encoding($false)))
    $capture=& $adapter -Prompt 'Propose a read only tool.' -ModelId 'fixture-model' -ModelDigest $digest -OutputDirectory (Join-Path $tempRoot 'capture') -FixtureResponsePath $fixturePath -Execute
    Assert-True ($capture.captureStatus -eq 'Completed') "Synthetic capture failed: $($capture.failure)"
    Assert-True ($capture.observation.toolCallCount -eq 1 -and $capture.observation.toolDisposition -eq 'PROPOSED_NOT_EXECUTED') 'Tool proposal was not preserved as non-executed.'
    Assert-True (-not $capture.effects.toolExecutionPerformed -and -not $capture.effects.transportPerformed -and -not $capture.effects.desktopLifecyclePerformed) 'Synthetic capture claimed a forbidden effect.'
    $metadataSha=(Get-FileHash -LiteralPath $capture.MetadataPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $valid=& $validator -MetadataPath $capture.MetadataPath -ExpectedMetadataSha256 $metadataSha -ExpectedModelId fixture-model -ExpectedModelDigest $digest -AcceptUnverifiedModelDigest -AllowFixtureEvidence -NoThrow
    Assert-True $valid.Passed "Valid synthetic evidence failed: $($valid.FailedGates -join ', ')"
    $notAttested=& $validator -MetadataPath $capture.MetadataPath -ExpectedMetadataSha256 $metadataSha -ExpectedModelId fixture-model -ExpectedModelDigest $digest -AllowFixtureEvidence -NoThrow
    Assert-True (-not $notAttested.Passed -and $notAttested.FailedGates.Count -eq 1 -and $notAttested.FailedGates[0] -eq 'ModelDigestNotAttested') 'Unattested digest did not fail with the exact gate.'
    $fixtureNotRuntime=& $validator -MetadataPath $capture.MetadataPath -ExpectedMetadataSha256 $metadataSha -ExpectedModelId fixture-model -ExpectedModelDigest $digest -AcceptUnverifiedModelDigest -NoThrow
    Assert-True (-not $fixtureNotRuntime.Passed -and $fixtureNotRuntime.FailedGates.Count -eq 1 -and $fixtureNotRuntime.FailedGates[0] -eq 'FixtureEvidenceNotRuntime') 'Fixture evidence was mistaken for runtime evidence.'
    $typedMetadata=Get-Content -LiteralPath $capture.MetadataPath -Raw|ConvertFrom-Json
    $typedMetadata.effects.toolExecutionPerformed='False'
    $typedPath=Join-Path $tempRoot 'typed-metadata.json'
    [IO.File]::WriteAllText($typedPath,($typedMetadata|ConvertTo-Json -Depth 12),(New-Object Text.UTF8Encoding($false)))
    $typedSha=(Get-FileHash -LiteralPath $typedPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $typed=& $validator -MetadataPath $typedPath -ExpectedMetadataSha256 $typedSha -ExpectedModelId fixture-model -ExpectedModelDigest $digest -AcceptUnverifiedModelDigest -AllowFixtureEvidence -NoThrow
    Assert-True (-not $typed.Passed -and $typed.FailedGates -contains 'Effects.toolExecutionPerformed') 'String False was coerced into a no-execution claim.'
    $deepPath=Join-Path $tempRoot 'deep-response.json'
    $deepJson='{"model":"fixture-model","done":true,"message":'+('['*70)+(']'*70)+'}'
    [IO.File]::WriteAllText($deepPath,$deepJson,(New-Object Text.UTF8Encoding($false)))
    $deepCapture=& $adapter -Prompt x -ModelId fixture-model -ModelDigest $digest -OutputDirectory (Join-Path $tempRoot 'deep-capture') -FixtureResponsePath $deepPath -Execute
    Assert-True ($deepCapture.captureStatus -eq 'RequestFailed' -and $deepCapture.failure -match 'JSON nesting limit') 'Deep JSON fixture was not rejected before parsing.'
    Add-Content -LiteralPath $capture.artifacts.responsePath -Value 'drift'
    $drift=& $validator -MetadataPath $capture.MetadataPath -ExpectedMetadataSha256 $metadataSha -ExpectedModelId fixture-model -ExpectedModelDigest $digest -AcceptUnverifiedModelDigest -AllowFixtureEvidence -NoThrow
    Assert-True (-not $drift.Passed -and $drift.FailedGates -contains 'Artifacts.response.Sha256') 'Response drift was not rejected by exact hash gate.'
}finally{
    if(Test-Path -LiteralPath $tempRoot){Remove-Item -LiteralPath $tempRoot -Recurse -Force}
}
'Ollama adapter contracts passed.'
