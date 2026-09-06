[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$pluginRoot = Split-Path -Parent $PSScriptRoot
$previewer = Join-Path $pluginRoot 'scripts\Get-PowerShellWorkbenchCatalogMigrationPreview.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('powershell-workbench-catalog-migration-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null
function Assert-GatesExactly { param($Result,[string[]]$Expected,[string]$Message);if(@($Result.FailedGates).Count-ne$Expected.Count-or(Compare-Object @($Result.FailedGates) $Expected)){throw "$Message Actual: $($Result.FailedGates -join ', ')"} }
function Get-Snapshot { param([string]$Root);@((Get-ChildItem -LiteralPath $Root -Recurse -File|ForEach-Object{"$($_.FullName)|$($_.Length)|$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)|$($_.LastWriteTimeUtc.Ticks)"})|Sort-Object)-join"`n" }
function Initialize-Fixture {
    param([string]$Name,[string]$SchemaVersion='1.0',[switch]$UnknownProperty)
    $root=Join-Path $tempRoot $Name;New-Item -ItemType Directory -Path $root|Out-Null
    $codexPath=Join-Path $root 'codex.exe';Set-Content -LiteralPath $codexPath -Value 'fixture-codex' -Encoding UTF8
    $catalogPath=Join-Path $root 'catalog.json';'{"models":[{"slug":"fixture-model","display_name":"Fixture model"}]}'|Set-Content -LiteralPath $catalogPath -Encoding UTF8
    $manifest=[ordered]@{schemaVersion=$SchemaVersion;generatedAtUtc='2026-09-06T08:00:00Z';model='fixture-model';contextWindow=4096;codexPath=$codexPath;codexVersion='0.0.0';codexSha256=(Get-FileHash $codexPath -Algorithm SHA256).Hash.ToLowerInvariant();baseModelSlug='fixture-base';bundledCatalogSha256=('a'*64);catalogPath=$catalogPath;catalogSha256=(Get-FileHash $catalogPath -Algorithm SHA256).Hash.ToLowerInvariant();unassertedCapabilities=@('reasoning-levels')}
    if($SchemaVersion-ceq'1.1'){$manifest.transport=[ordered]@{base=[ordered]@{};effective=[ordered]@{};overrides=@('fixture')}}
    if($UnknownProperty){$manifest.unexpected='blocked'}
    $manifestPath=Join-Path $root 'catalog.json.manifest.json';$manifest|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $manifestPath -Encoding UTF8
    [pscustomobject]@{Root=$root;ManifestPath=$manifestPath;ManifestSha256=(Get-FileHash $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant();CatalogPath=$catalogPath;CodexPath=$codexPath}
}
try {
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($previewer,[ref]$tokens,[ref]$errors)
    if(@($errors).Count-ne0){throw 'Catalog migration previewer has parser errors.'}
    $commands=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.CommandAst]},$true)|ForEach-Object{$_.GetCommandName()}|Where-Object{$_})
    foreach($forbidden in @('Set-Content','Add-Content','Out-File','New-Item','Copy-Item','Move-Item','Remove-Item','Start-Process','Invoke-RestMethod','Invoke-WebRequest','Invoke-Expression','Set-Clipboard','git','gh')){if($commands-contains$forbidden){throw "Previewer contains forbidden command '$forbidden'."}}

    $fixture=Initialize-Fixture -Name legacy;$before=Get-Snapshot -Root $fixture.Root
    $first=&$previewer -ManifestPath $fixture.ManifestPath -ExpectedManifestSha256 $fixture.ManifestSha256 -DestinationCatalogPath $fixture.CatalogPath -AllowedWriteRoot $fixture.Root -NoThrow
    $second=&$previewer -ManifestPath $fixture.ManifestPath -ExpectedManifestSha256 $fixture.ManifestSha256 -DestinationCatalogPath $fixture.CatalogPath -AllowedWriteRoot $fixture.Root -NoThrow
    if($first.State-cne'PREVIEW_READY'-or-not$first.Eligible-or-not$first.MigrationRequired-or$first.WritePerformed-or$first.ExecutionPerformed-or$first.TransportPerformed){throw 'Legacy preview readiness contract failed.'}
    if($first.Plan.Operation-cne'RegenerateCatalog'-or-not$first.Plan.BackupRequired-or-not$first.Plan.PostValidationRequired-or-not$first.Plan.ExplicitApplyAuthorizationRequired){throw 'Migration plan safety contract failed.'}
    if($first.PlanSha256-cne$second.PlanSha256-or(($first|ConvertTo-Json -Depth 12 -Compress)-cne($second|ConvertTo-Json -Depth 12 -Compress))){throw 'Migration preview is not deterministic.'}
    if((Get-Snapshot -Root $fixture.Root)-cne$before){throw 'Migration preview changed source evidence.'}

    $current=Initialize-Fixture -Name current -SchemaVersion '1.1';$noChange=&$previewer -ManifestPath $current.ManifestPath -ExpectedManifestSha256 $current.ManifestSha256 -DestinationCatalogPath $current.CatalogPath -AllowedWriteRoot $current.Root -NoThrow
    if($noChange.State-cne'NO_CHANGE'-or$noChange.Eligible-or$noChange.MigrationRequired-or$null-ne$noChange.Plan){throw 'Current-schema no-change contract failed.'}

    $transportManifest=Get-Content -LiteralPath $current.ManifestPath -Raw|ConvertFrom-Json;$transportManifest.transport=$null;$transportManifest|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $current.ManifestPath -Encoding UTF8
    $transportResult=&$previewer -ManifestPath $current.ManifestPath -ExpectedManifestSha256 (Get-FileHash $current.ManifestPath -Algorithm SHA256).Hash -DestinationCatalogPath $current.CatalogPath -AllowedWriteRoot $current.Root -NoThrow
    Assert-GatesExactly -Result $transportResult -Expected @('SourceTransportEvidence') -Message 'Incomplete transport evidence gate changed.'

    $hashDrift=&$previewer -ManifestPath $fixture.ManifestPath -ExpectedManifestSha256 ('0'*64) -DestinationCatalogPath $fixture.CatalogPath -AllowedWriteRoot $fixture.Root -NoThrow
    Assert-GatesExactly -Result $hashDrift -Expected @('SourceManifestHash') -Message 'Manifest drift gate changed.'

    $unknown=Initialize-Fixture -Name unknown -SchemaVersion '9.9';$unknownResult=&$previewer -ManifestPath $unknown.ManifestPath -ExpectedManifestSha256 $unknown.ManifestSha256 -DestinationCatalogPath $unknown.CatalogPath -AllowedWriteRoot $unknown.Root -NoThrow
    Assert-GatesExactly -Result $unknownResult -Expected @('SourceSchemaSupported') -Message 'Unknown schema gate changed.'

    $extra=Initialize-Fixture -Name extra -UnknownProperty;$extraResult=&$previewer -ManifestPath $extra.ManifestPath -ExpectedManifestSha256 $extra.ManifestSha256 -DestinationCatalogPath $extra.CatalogPath -AllowedWriteRoot $extra.Root -NoThrow
    Assert-GatesExactly -Result $extraResult -Expected @('SourceManifestShape') -Message 'Unexpected manifest property gate changed.'

    $identity=Initialize-Fixture -Name identity;$identityManifest=Get-Content -LiteralPath $identity.ManifestPath -Raw|ConvertFrom-Json;$identityManifest.bundledCatalogSha256='unknown';$identityManifest|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $identity.ManifestPath -Encoding UTF8
    $identityResult=&$previewer -ManifestPath $identity.ManifestPath -ExpectedManifestSha256 (Get-FileHash $identity.ManifestPath -Algorithm SHA256).Hash -DestinationCatalogPath $identity.CatalogPath -AllowedWriteRoot $identity.Root -NoThrow
    Assert-GatesExactly -Result $identityResult -Expected @('SourceGenerationIdentity') -Message 'Generation identity gate changed.'

    $capabilities=Initialize-Fixture -Name capabilities;$capabilitiesManifest=Get-Content -LiteralPath $capabilities.ManifestPath -Raw|ConvertFrom-Json;$capabilitiesManifest.unassertedCapabilities=@('duplicate','duplicate');$capabilitiesManifest|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $capabilities.ManifestPath -Encoding UTF8
    $capabilitiesResult=&$previewer -ManifestPath $capabilities.ManifestPath -ExpectedManifestSha256 (Get-FileHash $capabilities.ManifestPath -Algorithm SHA256).Hash -DestinationCatalogPath $capabilities.CatalogPath -AllowedWriteRoot $capabilities.Root -NoThrow
    Assert-GatesExactly -Result $capabilitiesResult -Expected @('SourceCapabilityEvidence') -Message 'Capability evidence gate changed.'

    Set-Content -LiteralPath $fixture.CatalogPath -Value '{"models":[]}' -Encoding UTF8
    $catalogDrift=&$previewer -ManifestPath $fixture.ManifestPath -ExpectedManifestSha256 $fixture.ManifestSha256 -DestinationCatalogPath $fixture.CatalogPath -AllowedWriteRoot $fixture.Root -NoThrow
    Assert-GatesExactly -Result $catalogDrift -Expected @('SourceCatalogHash') -Message 'Catalog drift gate changed.'

    $boundary=Initialize-Fixture -Name boundary -SchemaVersion '1.1';$outside=Join-Path $tempRoot 'outside.json';$outsideResult=&$previewer -ManifestPath $boundary.ManifestPath -ExpectedManifestSha256 $boundary.ManifestSha256 -DestinationCatalogPath $outside -AllowedWriteRoot $boundary.Root -NoThrow
    Assert-GatesExactly -Result $outsideResult -Expected @('DestinationPathAllowed') -Message 'Destination boundary gate changed.'
    'PowerShell Workbench catalog migration contracts passed.'
} finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
