[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$InputPath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$SchemaPath,
    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (-not $SchemaPath) { $SchemaPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'skills\powershell-agent-harness-development\assets\schemas\powershell-workbench-handoff.schema.json' }

function Get-Sha256Text {
    param([Parameter(Mandatory)][string]$Text)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        ([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally { $algorithm.Dispose() }
}

function ConvertTo-CanonicalJson {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [string] -or $Value -is [char]) {
        $builder = New-Object Text.StringBuilder
        [void]$builder.Append('"')
        foreach ($character in ([string]$Value).ToCharArray()) {
            $escaped = $true
            switch ([int]$character) {
                8 { [void]$builder.Append('\b') }
                9 { [void]$builder.Append('\t') }
                10 { [void]$builder.Append('\n') }
                12 { [void]$builder.Append('\f') }
                13 { [void]$builder.Append('\r') }
                34 { [void]$builder.Append('\"') }
                92 { [void]$builder.Append('\\') }
                default { $escaped = $false }
            }
            if (-not $escaped) {
                if ([int]$character -lt 32) { [void]$builder.Append(('\u{0:x4}' -f [int]$character)) }
                else { [void]$builder.Append($character) }
            }
        }
        [void]$builder.Append('"')
        return $builder.ToString()
    }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64] -or
        $Value -is [single] -or $Value -is [double] -or $Value -is [decimal]) {
        return ([IFormattable]$Value).ToString($null,[Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [Collections.IDictionary]) {
        $parts = foreach ($key in $Value.Keys) { (ConvertTo-CanonicalJson ([string]$key)) + ':' + (ConvertTo-CanonicalJson $Value[$key]) }
        return '{' + (@($parts) -join ',') + '}'
    }
    if ($Value -is [Collections.IEnumerable]) {
        $parts = foreach ($item in $Value) { ConvertTo-CanonicalJson $item }
        return '[' + (@($parts) -join ',') + ']'
    }
    if ($Value -is [psobject]) {
        $parts = foreach ($property in $Value.PSObject.Properties) { (ConvertTo-CanonicalJson $property.Name) + ':' + (ConvertTo-CanonicalJson $property.Value) }
        return '{' + (@($parts) -join ',') + '}'
    }
    throw "Unsupported canonical JSON value type '$($Value.GetType().FullName)'."
}

function Get-RequiredProperty {
    param([object]$InputObject,[string]$Name,[string]$Context)
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { throw "$Context is missing required property '$Name'." }
    $property.Value
}

function Assert-AllowedProperties {
    param([object]$InputObject,[string[]]$Allowed,[string]$Context)
    foreach ($property in $InputObject.PSObject.Properties) {
        if ($Allowed -notcontains $property.Name) { throw "$Context contains unknown property '$($property.Name)'." }
    }
}

function Assert-Text {
    param([object]$Value,[string]$Context)
    if ([string]::IsNullOrWhiteSpace([string]$Value)) { throw "$Context cannot be empty." }
    [string]$Value
}

function Assert-Sha256 {
    param([object]$Value,[string]$Context)
    $text = [string]$Value
    if ($text -notmatch '^[a-fA-F0-9]{64}$') { throw "$Context must be a SHA-256 digest." }
    $text.ToLowerInvariant()
}

function Convert-Task {
    param([object]$Value,[string]$Context)
    Assert-AllowedProperties $Value @('taskId','title') $Context
    [ordered]@{
        taskId = Assert-Text (Get-RequiredProperty $Value 'taskId' $Context) "$Context.taskId"
        title = Assert-Text (Get-RequiredProperty $Value 'title' $Context) "$Context.title"
    }
}

function Convert-FileEvidence {
    param([object]$Value,[string]$Context)
    Assert-AllowedProperties $Value @('path','sha256') $Context
    $path = Assert-Text (Get-RequiredProperty $Value 'path' $Context) "$Context.path"
    if ([IO.Path]::IsPathRooted($path) -or $path -match '^[A-Za-z]:' -or $path -match '(^|[\\/])\.\.([\\/]|$)') { throw "$Context.path must be a portable relative path." }
    [ordered]@{path=$path.Replace('\','/');sha256=Assert-Sha256 (Get-RequiredProperty $Value 'sha256' $Context) "$Context.sha256"}
}

function Convert-StringArray {
    param([object[]]$Value,[string]$Context)
    @($Value | ForEach-Object { Assert-Text $_ $Context })
}

$resolvedInput = (Resolve-Path -LiteralPath $InputPath).Path
$resolvedSchema = (Resolve-Path -LiteralPath $SchemaPath).Path
$schemaObject = Get-Content -LiteralPath $resolvedSchema -Raw | ConvertFrom-Json
if ([string]$schemaObject.title -ne 'PowerShell Workbench portable handoff input') { throw 'Unexpected handoff schema.' }
if ([string]$schemaObject.'$id' -ne 'https://zilvereyes.github.io/PowerShellWorkbench/schemas/handoff-input-1.0.json') { throw 'Unexpected handoff schema identity.' }
$schemaSha256 = (Get-FileHash -LiteralPath $resolvedSchema -Algorithm SHA256).Hash.ToLowerInvariant()
$inputObject = Get-Content -LiteralPath $resolvedInput -Raw | ConvertFrom-Json

$allowedTopLevel = @('schemaVersion','handoffId','createdAt','source','destination','project','objective','verifiedFacts','changedFiles','testResults','unresolvedDecisions','authorityBoundaries','safetyBoundaries','requestedActions','reloadCanary')
Assert-AllowedProperties $inputObject $allowedTopLevel 'Handoff'
foreach ($name in $allowedTopLevel) { [void](Get-RequiredProperty $inputObject $name 'Handoff') }
if ([string]$inputObject.schemaVersion -ne '1.0') { throw 'Unsupported handoff schema version.' }
$handoffId = Assert-Text $inputObject.handoffId 'Handoff.handoffId'
if ($handoffId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') { throw 'Handoff.handoffId is not a portable identifier.' }
$createdAtValue = $inputObject.createdAt
if ($createdAtValue -is [datetimeoffset]) { $createdAt = [datetimeoffset]$createdAtValue }
elseif ($createdAtValue -is [datetime]) { $createdAt = [datetimeoffset]([datetime]$createdAtValue) }
else {
    $createdAtText = [string]$createdAtValue
    if ($createdAtText -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,7})?(Z|[+-]\d{2}:\d{2})$') { throw 'Handoff.createdAt must be an ISO date-time with an explicit offset.' }
    try { $createdAt = [datetimeoffset]::Parse($createdAtText,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind) }
    catch { throw 'Handoff.createdAt must be a valid ISO date-time.' }
}

$project = Get-RequiredProperty $inputObject 'project' 'Handoff'
Assert-AllowedProperties $project @('root','pluginVersion','pluginSha256') 'Handoff.project'
$projectRoot = Assert-Text (Get-RequiredProperty $project 'root' 'Handoff.project') 'Handoff.project.root'
if (-not [IO.Path]::IsPathRooted($projectRoot)) { throw 'Handoff.project.root must be absolute.' }

$facts = foreach ($fact in @($inputObject.verifiedFacts)) {
    Assert-AllowedProperties $fact @('statement','evidence') 'Verified fact'
    $statement = Assert-Text (Get-RequiredProperty $fact 'statement' 'Verified fact') 'Verified fact.statement'
    $factEvidence = Get-RequiredProperty $fact 'evidence' 'Verified fact'
    $evidence = @($factEvidence | ForEach-Object { Convert-FileEvidence $_ 'Verified fact evidence' })
    if ($evidence.Count -eq 0) { throw 'Verified fact evidence cannot be empty.' }
    [ordered]@{statement=$statement;evidence=$evidence}
}
$changedFiles = @($inputObject.changedFiles | ForEach-Object { Convert-FileEvidence $_ 'Changed file' })
$tests = foreach ($test in @($inputObject.testResults)) {
    Assert-AllowedProperties $test @('name','runtime','status','evidenceSha256') 'Test result'
    $status = Assert-Text (Get-RequiredProperty $test 'status' 'Test result') 'Test result.status'
    if (@('Passed','Failed','Blocked','NotRun') -notcontains $status) { throw "Unknown test status '$status'." }
    [ordered]@{
        name=Assert-Text (Get-RequiredProperty $test 'name' 'Test result') 'Test result.name'
        runtime=Assert-Text (Get-RequiredProperty $test 'runtime' 'Test result') 'Test result.runtime'
        status=$status
        evidenceSha256=Assert-Sha256 (Get-RequiredProperty $test 'evidenceSha256' 'Test result') 'Test result.evidenceSha256'
    }
}

$payload = [ordered]@{
    schemaVersion='1.0';handoffId=$handoffId;createdAt=$createdAt.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)
    source=Convert-Task $inputObject.source 'Handoff.source';destination=Convert-Task $inputObject.destination 'Handoff.destination'
    project=[ordered]@{root=$projectRoot;pluginVersion=Assert-Text (Get-RequiredProperty $project 'pluginVersion' 'Handoff.project') 'Handoff.project.pluginVersion';pluginSha256=Assert-Sha256 (Get-RequiredProperty $project 'pluginSha256' 'Handoff.project') 'Handoff.project.pluginSha256'}
    objective=Assert-Text $inputObject.objective 'Handoff.objective';verifiedFacts=@($facts);changedFiles=@($changedFiles);testResults=@($tests)
    unresolvedDecisions=@(Convert-StringArray @($inputObject.unresolvedDecisions) 'Handoff.unresolvedDecisions')
    authorityBoundaries=@(Convert-StringArray @($inputObject.authorityBoundaries) 'Handoff.authorityBoundaries')
    safetyBoundaries=@(Convert-StringArray @($inputObject.safetyBoundaries) 'Handoff.safetyBoundaries')
    requestedActions=@(Convert-StringArray @($inputObject.requestedActions) 'Handoff.requestedActions')
    reloadCanary=Assert-Text $inputObject.reloadCanary 'Handoff.reloadCanary'
}
$payloadJson = ConvertTo-CanonicalJson $payload
$payloadSha256 = Get-Sha256Text -Text $payloadJson
$artifact = [ordered]@{artifactKind='PowerShellWorkbenchHandoff';schemaVersion='1.0';schemaSha256=$schemaSha256;payloadSha256=$payloadSha256;payload=$payload}
$artifactJson = ConvertTo-CanonicalJson $artifact
$markdown = @(
    "# PowerShell Workbench handoff: $handoffId",'',
    "Payload SHA-256: ``$payloadSha256``", "Schema SHA-256: ``$schemaSha256``",'',
    '## Objective','',([string]$payload.objective),'',
    '## Canonical payload','', '```json', $payloadJson, '```',''
) -join "`n"

$resolvedOutput = [IO.Path]::GetFullPath($OutputDirectory)
$jsonPath = Join-Path $resolvedOutput "$handoffId.json"
$markdownPath = Join-Path $resolvedOutput "$handoffId.md"
if (-not $Force -and ((Test-Path -LiteralPath $jsonPath) -or (Test-Path -LiteralPath $markdownPath))) { throw 'Handoff output already exists. Use -Force to replace the local artifacts.' }
if (-not $PSCmdlet.ShouldProcess($resolvedOutput, 'Write validated local JSON and Markdown handoff artifacts')) { return }
if (-not (Test-Path -LiteralPath $resolvedOutput)) { New-Item -ItemType Directory -Path $resolvedOutput -Force | Out-Null }
[IO.File]::WriteAllText($jsonPath,$artifactJson,(New-Object Text.UTF8Encoding($false)))
[IO.File]::WriteAllText($markdownPath,$markdown,(New-Object Text.UTF8Encoding($false)))
[pscustomobject][ordered]@{result='GENERATED_LOCAL_ONLY';handoffId=$handoffId;jsonPath=$jsonPath;markdownPath=$markdownPath;payloadSha256=$payloadSha256;schemaSha256=$schemaSha256;transportPerformed=$false;executionPerformed=$false}
