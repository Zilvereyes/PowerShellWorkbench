$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$adapter=Join-Path $root 'scripts\Invoke-PowerShellWorkbenchOllamaChat.ps1'
$comparator=Join-Path $root 'scripts\Compare-PowerShellWorkbenchOllamaEvidence.ps1'
$utf8=New-Object Text.UTF8Encoding($false)
function Assert-True { param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message} }
function Assert-GatesExactly { param($Result,[string[]]$Expected,[string]$Message) $actual=@($Result.FailedGates);if(($actual-join'|')-cne($Expected-join'|')){throw "$Message Expected [$($Expected-join', ')], got [$($actual-join', ')]."} }
function Get-Sha256 { param([string]$LiteralPath) (Get-FileHash -LiteralPath $LiteralPath -Algorithm SHA256).Hash.ToLowerInvariant() }
function Get-TextSha256 { param([string]$Text) $algorithm=[Security.Cryptography.SHA256]::Create();try{([BitConverter]::ToString($algorithm.ComputeHash($utf8.GetBytes($Text)))).Replace('-','').ToLowerInvariant()}finally{$algorithm.Dispose()} }
function Write-FixtureJson { param([string]$LiteralPath,$Value) [IO.File]::WriteAllText($LiteralPath,($Value|ConvertTo-Json -Depth 12),$utf8) }

$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($comparator,[ref]$tokens,[ref]$errors)
Assert-True ($errors.Count -eq 0) 'Comparator has parser errors.'
$commands=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst]},$true)|ForEach-Object{$_.GetCommandName()}|Where-Object{$_})
foreach($forbidden in @('Start-Process','Invoke-Expression','Invoke-RestMethod','Invoke-WebRequest','Set-Clipboard','Set-Content','Add-Content','Out-File','git','gh')){Assert-True ($commands -notcontains $forbidden) "Comparator contains forbidden command $forbidden."}

$tempRoot=Join-Path ([IO.Path]::GetTempPath()) ('pwb-model-comparison-'+[guid]::NewGuid().ToString('N'))
try{
    New-Item -ItemType Directory -Path $tempRoot|Out-Null
    $prompt='Return EXACT_OK.';$expectedAnswer='EXACT_OK';$digestA='a'*64;$digestB='b'*64
    $responseA=[ordered]@{model='model-a';created_at='2026-09-06T12:00:00Z';message=[ordered]@{role='assistant';content=$expectedAnswer};done=$true;total_duration=900;prompt_eval_count=4;eval_count=2}
    $responseB=[ordered]@{model='model-b';created_at='2026-09-06T12:00:00Z';message=[ordered]@{role='assistant';content='WRONG_FAST'};done=$true;total_duration=100;prompt_eval_count=4;eval_count=1}
    $responseC=[ordered]@{model='model-c';created_at='2026-09-06T12:00:00Z';message=[ordered]@{role='assistant';content=$expectedAnswer};done=$true;total_duration=800;prompt_eval_count=4;eval_count=2}
    $responseD=[ordered]@{model='model-d';created_at='2026-09-06T12:00:00Z';message=[ordered]@{role='assistant';content=$expectedAnswer};done=$true;total_duration=700;prompt_eval_count=4}
    $fixtureA=Join-Path $tempRoot 'response-a.json';$fixtureB=Join-Path $tempRoot 'response-b.json';$fixtureC=Join-Path $tempRoot 'response-c.json';$fixtureD=Join-Path $tempRoot 'response-d.json';Write-FixtureJson -LiteralPath $fixtureA -Value $responseA;Write-FixtureJson -LiteralPath $fixtureB -Value $responseB;Write-FixtureJson -LiteralPath $fixtureC -Value $responseC;Write-FixtureJson -LiteralPath $fixtureD -Value $responseD
    $captureA=&$adapter -Prompt $prompt -ModelId model-a -ModelDigest $digestA -OutputDirectory (Join-Path $tempRoot 'capture-a') -FixtureResponsePath $fixtureA -Execute
    $captureB=&$adapter -Prompt $prompt -ModelId model-b -ModelDigest $digestB -OutputDirectory (Join-Path $tempRoot 'capture-b') -FixtureResponsePath $fixtureB -Execute
    $captureC=&$adapter -Prompt $prompt -ModelId model-c -ModelDigest ('c'*64) -Temperature 0.5 -OutputDirectory (Join-Path $tempRoot 'capture-c') -FixtureResponsePath $fixtureC -Execute
    $captureD=&$adapter -Prompt $prompt -ModelId model-d -ModelDigest ('d'*64) -OutputDirectory (Join-Path $tempRoot 'capture-d') -FixtureResponsePath $fixtureD -Execute
    $manifestPath=Join-Path $tempRoot 'comparison.json'
    $manifest=[ordered]@{schemaVersion='1.0';comparisonId='fixture-comparison';task=[ordered]@{taskId='exact-answer';promptSha256=Get-TextSha256 -Text $prompt;acceptance=[ordered]@{kind='exact-utf8-sha256';expectedAnswerSha256=Get-TextSha256 -Text $expectedAnswer}};candidates=@(
        [ordered]@{candidateId='candidate-b';metadataPath=$captureB.MetadataPath;metadataSha256=Get-Sha256 -LiteralPath $captureB.MetadataPath;modelId='model-b';modelDigest=$digestB},
        [ordered]@{candidateId='candidate-a';metadataPath=$captureA.MetadataPath;metadataSha256=Get-Sha256 -LiteralPath $captureA.MetadataPath;modelId='model-a';modelDigest=$digestA})}
    Write-FixtureJson -LiteralPath $manifestPath -Value $manifest;$manifestSha=Get-Sha256 -LiteralPath $manifestPath
    $result=&$comparator -ManifestPath $manifestPath -ExpectedManifestSha256 $manifestSha -AllowedEvidenceRoot $tempRoot -AcceptUnverifiedModelDigest -AllowFixtureEvidence -NoThrow
    Assert-True ($result.State -eq 'COMPLETE' -and $result.Passed -and -not $result.RetryPerformed -and -not $result.ModelCallPerformed -and -not $result.WritePerformed -and -not $result.TransportPerformed) "Valid comparison did not complete without effects. State=$($result.State); gates=$($result.FailedGates -join ', ')."
    Assert-True ($result.Candidates[0].CandidateId -ceq 'candidate-a' -and $result.Candidates[0].Quality -eq 'PASS' -and $result.Candidates[0].Rank -eq 1) 'Correct candidate was not ranked first.'
    Assert-True ($result.Candidates[1].CandidateId -ceq 'candidate-b' -and $result.Candidates[1].Quality -eq 'FAIL' -and $null -eq $result.Candidates[1].Rank) 'Fast wrong candidate received a rank.'
    Assert-True ($result.Candidates[1].ServerTotalDurationNanoseconds -lt $result.Candidates[0].ServerTotalDurationNanoseconds) 'Fixture does not prove that the wrong answer was faster.'
    $json1=&$comparator -ManifestPath $manifestPath -ExpectedManifestSha256 $manifestSha -AllowedEvidenceRoot $tempRoot -AcceptUnverifiedModelDigest -AllowFixtureEvidence -NoThrow -AsJson
    $json2=&$comparator -ManifestPath $manifestPath -ExpectedManifestSha256 $manifestSha -AllowedEvidenceRoot $tempRoot -AcceptUnverifiedModelDigest -AllowFixtureEvidence -NoThrow -AsJson
    Assert-True (($json1-join"`n") -ceq ($json2-join"`n")) 'Comparison JSON was not deterministic for frozen evidence.'

    $wrongManifest=&$comparator -ManifestPath $manifestPath -ExpectedManifestSha256 ('f'*64) -AllowedEvidenceRoot $tempRoot -AcceptUnverifiedModelDigest -AllowFixtureEvidence -NoThrow
    Assert-True ($wrongManifest.State -eq 'CONFLICT') 'Manifest drift was not CONFLICT.';Assert-GatesExactly -Result $wrongManifest -Expected @('ManifestSha256') -Message 'Manifest hash gate changed.'

    $duplicates=($manifest|ConvertTo-Json -Depth 12|ConvertFrom-Json);$duplicates.candidates=@($manifest.candidates[0],$manifest.candidates[0]);$duplicatePath=Join-Path $tempRoot 'duplicate.json';Write-FixtureJson -LiteralPath $duplicatePath -Value $duplicates;$duplicateResult=&$comparator -ManifestPath $duplicatePath -ExpectedManifestSha256 (Get-Sha256 -LiteralPath $duplicatePath) -AllowedEvidenceRoot $tempRoot -AcceptUnverifiedModelDigest -AllowFixtureEvidence -NoThrow
    Assert-True ($duplicateResult.State -eq 'CONFLICT') 'Duplicate candidate ids were not CONFLICT.';Assert-GatesExactly -Result $duplicateResult -Expected @('CandidateIdsUnique') -Message 'Duplicate candidate gate changed.'

    $promptDrift=($manifest|ConvertTo-Json -Depth 12|ConvertFrom-Json);$promptDrift.task.promptSha256='c'*64;$promptPath=Join-Path $tempRoot 'prompt-drift.json';Write-FixtureJson -LiteralPath $promptPath -Value $promptDrift;$promptResult=&$comparator -ManifestPath $promptPath -ExpectedManifestSha256 (Get-Sha256 -LiteralPath $promptPath) -AllowedEvidenceRoot $tempRoot -AcceptUnverifiedModelDigest -AllowFixtureEvidence -NoThrow
    Assert-True ($promptResult.State -eq 'CONFLICT') 'Prompt drift was not CONFLICT.'
    Assert-GatesExactly -Result $promptResult -Expected @('Candidate[candidate-a].PromptSha256','Candidate[candidate-b].PromptSha256') -Message 'Prompt drift gates changed.'

    $missing=($manifest|ConvertTo-Json -Depth 12|ConvertFrom-Json);$missing.candidates=@([ordered]@{candidateId='candidate-a';metadataPath=(Join-Path $tempRoot 'missing.json');metadataSha256=('d'*64);modelId='model-a';modelDigest=$digestA},$manifest.candidates[0]);$missingPath=Join-Path $tempRoot 'missing-manifest.json';Write-FixtureJson -LiteralPath $missingPath -Value $missing;$missingResult=&$comparator -ManifestPath $missingPath -ExpectedManifestSha256 (Get-Sha256 -LiteralPath $missingPath) -AllowedEvidenceRoot $tempRoot -AcceptUnverifiedModelDigest -AllowFixtureEvidence -NoThrow
    Assert-True ($missingResult.State -eq 'UNKNOWN') 'Missing candidate evidence was not UNKNOWN.';Assert-GatesExactly -Result $missingResult -Expected @('Candidate[candidate-a].EvidenceReadable') -Message 'Missing evidence gate changed.'

    $configurationDrift=($manifest|ConvertTo-Json -Depth 12|ConvertFrom-Json);$configurationDrift.candidates=@($manifest.candidates[1],[ordered]@{candidateId='candidate-c';metadataPath=$captureC.MetadataPath;metadataSha256=Get-Sha256 -LiteralPath $captureC.MetadataPath;modelId='model-c';modelDigest=('c'*64)});$configurationPath=Join-Path $tempRoot 'configuration-drift.json';Write-FixtureJson -LiteralPath $configurationPath -Value $configurationDrift;$configurationResult=&$comparator -ManifestPath $configurationPath -ExpectedManifestSha256 (Get-Sha256 -LiteralPath $configurationPath) -AllowedEvidenceRoot $tempRoot -AcceptUnverifiedModelDigest -AllowFixtureEvidence -NoThrow
    Assert-True ($configurationResult.State -eq 'CONFLICT') 'Request configuration drift was not CONFLICT.';Assert-GatesExactly -Result $configurationResult -Expected @('Candidate[candidate-c].RequestConfiguration') -Message 'Configuration drift gate changed.'

    $missingMetrics=($manifest|ConvertTo-Json -Depth 12|ConvertFrom-Json);$missingMetrics.candidates=@($manifest.candidates[1],[ordered]@{candidateId='candidate-d';metadataPath=$captureD.MetadataPath;metadataSha256=Get-Sha256 -LiteralPath $captureD.MetadataPath;modelId='model-d';modelDigest=('d'*64)});$metricsPath=Join-Path $tempRoot 'missing-metrics.json';Write-FixtureJson -LiteralPath $metricsPath -Value $missingMetrics;$metricsResult=&$comparator -ManifestPath $metricsPath -ExpectedManifestSha256 (Get-Sha256 -LiteralPath $metricsPath) -AllowedEvidenceRoot $tempRoot -AcceptUnverifiedModelDigest -AllowFixtureEvidence -NoThrow
    Assert-True ($metricsResult.State -eq 'UNKNOWN') 'Missing metrics were not UNKNOWN.';Assert-GatesExactly -Result $metricsResult -Expected @('Candidate[candidate-d].Metrics') -Message 'Missing metrics gate changed.'

    $outside=($manifest|ConvertTo-Json -Depth 12|ConvertFrom-Json);$outside.candidates=@($manifest.candidates[1],[ordered]@{candidateId='candidate-z';metadataPath=$comparator;metadataSha256=Get-Sha256 -LiteralPath $comparator;modelId='model-z';modelDigest=('e'*64)});$outsidePath=Join-Path $tempRoot 'outside-root.json';Write-FixtureJson -LiteralPath $outsidePath -Value $outside;$outsideResult=&$comparator -ManifestPath $outsidePath -ExpectedManifestSha256 (Get-Sha256 -LiteralPath $outsidePath) -AllowedEvidenceRoot $tempRoot -AcceptUnverifiedModelDigest -AllowFixtureEvidence -NoThrow
    Assert-True ($outsideResult.State -eq 'CONFLICT') 'Metadata outside the evidence root was not CONFLICT.';Assert-GatesExactly -Result $outsideResult -Expected @('Candidate[candidate-z].MetadataWithinEvidenceRoot') -Message 'Outside-root gate changed.'

    $invalidTask=($manifest|ConvertTo-Json -Depth 12|ConvertFrom-Json);$invalidTask.task.promptSha256='invalid';$invalidTask.task.acceptance.expectedAnswerSha256='invalid';$invalidTaskPath=Join-Path $tempRoot 'invalid-task.json';Write-FixtureJson -LiteralPath $invalidTaskPath -Value $invalidTask;$invalidTaskResult=&$comparator -ManifestPath $invalidTaskPath -ExpectedManifestSha256 (Get-Sha256 -LiteralPath $invalidTaskPath) -AllowedEvidenceRoot $tempRoot -AcceptUnverifiedModelDigest -AllowFixtureEvidence -NoThrow
    Assert-True ($invalidTaskResult.State -eq 'UNKNOWN') 'Invalid task hashes were not UNKNOWN.';Assert-GatesExactly -Result $invalidTaskResult -Expected @('TaskPromptSha256','TaskAnswerSha256') -Message 'Invalid task gates changed.'
}finally{if(Test-Path -LiteralPath $tempRoot){Remove-Item -LiteralPath $tempRoot -Recurse -Force}}
'PowerShell Workbench model comparison contracts passed.'
