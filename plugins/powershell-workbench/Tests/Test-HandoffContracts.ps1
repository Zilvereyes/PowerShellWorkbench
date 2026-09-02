[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$pluginRoot = Split-Path -Parent $PSScriptRoot
$generator = Join-Path $pluginRoot 'scripts\New-PowerShellWorkbenchHandoff.ps1'
$schema = Join-Path $pluginRoot 'skills\powershell-agent-harness-development\assets\schemas\powershell-workbench-handoff.schema.json'
$template = Join-Path $pluginRoot 'skills\powershell-agent-harness-development\assets\templates\handoff-input.json.tmpl'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('powershell-workbench-handoff-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null

function Assert-True { param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message} }

try {
    [void](Get-Content -LiteralPath $schema -Raw|ConvertFrom-Json)
    [void](Get-Content -LiteralPath $template -Raw|ConvertFrom-Json)
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($generator,[ref]$tokens,[ref]$errors)
    Assert-True (@($errors).Count -eq 0) 'Handoff generator has parser errors.'
    $forbidden=@('Invoke-RestMethod','Invoke-WebRequest','Start-Process','Invoke-Expression','Set-Clipboard','git','gh')
    $commands=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst]},$true)|ForEach-Object{$_.GetCommandName()}|Where-Object{$_})
    foreach($command in $forbidden){Assert-True ($commands -notcontains $command) "Handoff generator contains forbidden execution or transport command '$command'."}

    $inputPath=Join-Path $tempRoot 'input.json'
    $input=[ordered]@{
        schemaVersion='1.0';handoffId='deterministic-fixture';createdAt='2026-09-03T00:00:00Z'
        source=[ordered]@{taskId='source-id';title='Source task'};destination=[ordered]@{taskId='destination-id';title='Destination task'}
        project=[ordered]@{root=$tempRoot;pluginVersion='0.7.0';pluginSha256=('a'*64)}
        objective='Generate local-only deterministic handoff artifacts.'
        verifiedFacts=@([ordered]@{statement='Fixture passed validation.';evidence=@([ordered]@{path='evidence/result.json';sha256=('b'*64)})})
        changedFiles=@([ordered]@{path='scripts/example.ps1';sha256=('c'*64)})
        testResults=@([ordered]@{name='Fixture';runtime='Windows PowerShell 5.1';status='Passed';evidenceSha256=('d'*64)})
        unresolvedDecisions=@('Whether to transport the artifact.');authorityBoundaries=@('Code owns pass and fail.')
        safetyBoundaries=@('No execution or transport.');requestedActions=@('Review locally.');reloadCanary='PWB_HANDOFF_RELOAD_OK'
    }
    $input|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $inputPath -Encoding UTF8

    $whatIfOutput=Join-Path $tempRoot 'what-if-output'
    & $generator -InputPath $inputPath -OutputDirectory $whatIfOutput -WhatIf
    Assert-True (-not (Test-Path -LiteralPath $whatIfOutput)) 'Handoff -WhatIf created an output directory.'

    $first=& $generator -InputPath $inputPath -OutputDirectory (Join-Path $tempRoot 'first') -Confirm:$false
    $second=& $generator -InputPath $inputPath -OutputDirectory (Join-Path $tempRoot 'second') -Confirm:$false
    Assert-True ($first.result -eq 'GENERATED_LOCAL_ONLY' -and -not $first.transportPerformed -and -not $first.executionPerformed) 'Handoff result did not preserve no-execution/no-transport guarantees.'
    Assert-True ((Get-FileHash -LiteralPath $first.jsonPath -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $second.jsonPath -Algorithm SHA256).Hash) 'Repeated JSON generation was not deterministic.'
    Assert-True ((Get-FileHash -LiteralPath $first.markdownPath -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $second.markdownPath -Algorithm SHA256).Hash) 'Repeated Markdown generation was not deterministic.'

    $artifact=Get-Content -LiteralPath $first.jsonPath -Raw|ConvertFrom-Json
    Assert-True ($artifact.payload.project.root -eq [IO.Path]::GetFullPath($tempRoot)) 'Canonical JSON did not preserve the project path through parse roundtrip.'
    Assert-True ($artifact.schemaSha256 -eq (Get-FileHash -LiteralPath $schema -Algorithm SHA256).Hash.ToLowerInvariant()) 'Generated handoff was not bound to the schema hash.'
    $markdown=Get-Content -LiteralPath $first.markdownPath -Raw
    $match=[regex]::Match($markdown,'(?s)```json\r?\n(?<json>.*?)\r?\n```')
    Assert-True $match.Success 'Markdown handoff does not contain its canonical JSON payload.'
    $embedded=$match.Groups['json'].Value|ConvertFrom-Json
    Assert-True (($embedded|ConvertTo-Json -Depth 12 -Compress) -eq ($artifact.payload|ConvertTo-Json -Depth 12 -Compress)) 'JSON and Markdown handoffs are not semantically equivalent.'
    Assert-True ($markdown.Contains($artifact.payloadSha256)) 'Markdown handoff does not carry the JSON payload hash.'

    $invalid=$input.PSObject.Copy();$invalid.testResults=@([ordered]@{name='Fixture';runtime='PS';status='Unknown';evidenceSha256=('d'*64)})
    $invalidPath=Join-Path $tempRoot 'invalid.json';$invalid|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $invalidPath -Encoding UTF8
    $rejected=$false;try{& $generator -InputPath $invalidPath -OutputDirectory (Join-Path $tempRoot 'invalid-output') -Confirm:$false|Out-Null}catch{$rejected=$true}
    Assert-True $rejected 'Unknown test status did not fail closed.'
    'PowerShell Workbench handoff contracts passed.'
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
