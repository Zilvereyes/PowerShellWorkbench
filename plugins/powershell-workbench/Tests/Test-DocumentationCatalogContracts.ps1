[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$pluginRoot=Split-Path -Parent $PSScriptRoot
$validator=Join-Path $pluginRoot 'scripts\Test-PowerShellWorkbenchDocumentationCatalog.ps1'
$catalogPath=Join-Path $pluginRoot 'assets\documentation-source-catalog.json'
$tempRoot=Join-Path ([IO.Path]::GetTempPath()) ('powershell-workbench-doc-catalog-'+[guid]::NewGuid().ToString('N'))
function Assert-True{param([bool]$Condition,[string]$Message)if(-not$Condition){throw $Message}}
function Get-Hash{param([string]$Path)(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function Write-Fixture{param([object]$Value,[string]$Path)$Value|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $Path -Encoding UTF8;Get-Hash -Path $Path}

$tokens=$null;$errors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($validator,[ref]$tokens,[ref]$errors)
Assert-True -Condition ($errors.Count-eq 0) -Message 'Documentation catalog validator has parser errors.'
$sourceText=Get-Content -LiteralPath $validator -Raw
foreach($forbidden in @('Invoke-WebRequest','Invoke-RestMethod','Start-Process','Set-Content','Add-Content','Out-File','Remove-Item')){Assert-True -Condition ($sourceText-notmatch [regex]::Escape($forbidden)) -Message "Validator contains forbidden operation $forbidden."}
try{
    New-Item -ItemType Directory -Path $tempRoot|Out-Null
    $catalogHash=Get-Hash -Path $catalogPath
    $before=Get-Item -LiteralPath $catalogPath|Select-Object Length,LastWriteTimeUtc
    $healthy=&$validator -CatalogPath $catalogPath -ExpectedCatalogSha256 $catalogHash -ReferenceTimeUtc ([datetime]'2026-09-06T12:00:00Z') -NoThrow
    Assert-True -Condition ($healthy.Passed-and-not$healthy.WritePerformed-and-not$healthy.ExecutionPerformed-and-not$healthy.NetworkPerformed-and-not$healthy.TransportPerformed) -Message 'Healthy documentation catalog contract failed.'
    $after=Get-Item -LiteralPath $catalogPath|Select-Object Length,LastWriteTimeUtc
    Assert-True -Condition (($before|ConvertTo-Json)-ceq($after|ConvertTo-Json)) -Message 'Validation changed the source catalog.'
    $wrong=&$validator -CatalogPath $catalogPath -ExpectedCatalogSha256 ('0'*64) -ReferenceTimeUtc ([datetime]'2026-09-06T12:00:00Z') -NoThrow
    Assert-True -Condition (-not$wrong.Passed-and$wrong.FailedGates-ccontains'CatalogHash') -Message 'Catalog hash drift did not fail closed.'

    $fixture=Get-Content -LiteralPath $catalogPath -Raw|ConvertFrom-Json
    $fixture.schemaVersion='9.9';$path=Join-Path $tempRoot 'schema.json';$hash=Write-Fixture -Value $fixture -Path $path
    $result=&$validator -CatalogPath $path -ExpectedCatalogSha256 $hash -ReferenceTimeUtc ([datetime]'2026-09-06T12:00:00Z') -NoThrow
    Assert-True -Condition ($result.FailedGates-ccontains'SchemaVersionKnown') -Message 'Unknown schema gate changed.'

    $fixture=Get-Content -LiteralPath $catalogPath -Raw|ConvertFrom-Json
    $fixture.verifiedAtUtc='2025-01-01T00:00:00Z';$path=Join-Path $tempRoot 'stale.json';$hash=Write-Fixture -Value $fixture -Path $path
    $result=&$validator -CatalogPath $path -ExpectedCatalogSha256 $hash -MaximumAgeDays 30 -ReferenceTimeUtc ([datetime]'2026-09-06T12:00:00Z') -NoThrow
    Assert-True -Condition ($result.FailedGates-ccontains'CatalogStale') -Message 'Stale catalog gate changed.'

    $fixture=Get-Content -LiteralPath $catalogPath -Raw|ConvertFrom-Json
    $fixture.domains[0].sources[0].url='https://example.invalid/powershell';$path=Join-Path $tempRoot 'host.json';$hash=Write-Fixture -Value $fixture -Path $path
    $result=&$validator -CatalogPath $path -ExpectedCatalogSha256 $hash -ReferenceTimeUtc ([datetime]'2026-09-06T12:00:00Z') -NoThrow
    Assert-True -Condition ($result.FailedGates-ccontains'SourceAuthorityHost') -Message 'Authority-host gate changed.'

    $fixture=Get-Content -LiteralPath $catalogPath -Raw|ConvertFrom-Json
    $fixture.domains[0].id='unknown-domain';$path=Join-Path $tempRoot 'domain.json';$hash=Write-Fixture -Value $fixture -Path $path
    $result=&$validator -CatalogPath $path -ExpectedCatalogSha256 $hash -ReferenceTimeUtc ([datetime]'2026-09-06T12:00:00Z') -NoThrow
    Assert-True -Condition ($result.FailedGates-ccontains'DomainKnown'-and$result.FailedGates-ccontains'RequiredDomainPresent') -Message 'Unknown or missing domain gates changed.'

    $fixture=Get-Content -LiteralPath $catalogPath -Raw|ConvertFrom-Json
    $fixture.domains[0].PSObject.Properties.Remove('sources');$path=Join-Path $tempRoot 'missing.json';$hash=Write-Fixture -Value $fixture -Path $path
    $result=&$validator -CatalogPath $path -ExpectedCatalogSha256 $hash -ReferenceTimeUtc ([datetime]'2026-09-06T12:00:00Z') -NoThrow
    Assert-True -Condition ($result.FailedGates-ccontains'DomainShape'-and$result.FailedGates-ccontains'DomainSources') -Message "Missing domain state did not preserve exact gates: $($result.FailedGates-join', ')."

    foreach($skill in @('powershell-docs','microsoft-dism-docs','microsoft-update-docs','ollama-docs')){Assert-True -Condition (Test-Path -LiteralPath (Join-Path $pluginRoot "skills\$skill\SKILL.md") -PathType Leaf) -Message "Catalog-bound skill is missing: $skill."}
}finally{if(Test-Path -LiteralPath $tempRoot){Remove-Item -LiteralPath $tempRoot -Recurse -Force}}
'PowerShell Workbench documentation catalog contracts passed.'
