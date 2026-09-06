[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$pluginRoot=Split-Path -Parent $PSScriptRoot;$validator=Join-Path $pluginRoot 'scripts\Test-PowerShellWorkbenchHealth.ps1';$tempRoot=Join-Path ([IO.Path]::GetTempPath()) ('powershell-workbench-health-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $tempRoot|Out-Null
function Assert-GatesExactly{param($Result,[string[]]$Expected,[string]$Message);if(@($Result.FailedGates).Count-ne$Expected.Count-or(Compare-Object @($Result.FailedGates) $Expected)){throw "$Message Actual: $($Result.FailedGates -join ', ')"}}
function Initialize-FixtureRoot{param([string]$Name,[string]$Version='0.7.4');$root=Join-Path $tempRoot $Name;New-Item -ItemType Directory -Path (Join-Path $root '.codex-plugin'),(Join-Path $root 'scripts') -Force|Out-Null;[ordered]@{name='powershell-workbench';version=$Version}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $root '.codex-plugin\plugin.json') -Encoding UTF8;Set-Content -LiteralPath (Join-Path $root 'scripts\fixture.ps1') -Value "'fixture'" -Encoding UTF8;$root}
function Copy-Fixture{param([string]$Source,[string]$Name);$target=Join-Path $tempRoot $Name;Copy-Item -LiteralPath $Source -Destination $target -Recurse;$target}
function Get-Snapshot{param([string[]]$Roots);@($Roots|ForEach-Object{Get-ChildItem -LiteralPath $_ -Recurse -File|ForEach-Object{"$($_.FullName)|$($_.Length)|$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)|$($_.LastWriteTimeUtc.Ticks)"}}|Sort-Object)-join"`n"}
try{
    $source=Initialize-FixtureRoot source;$cache=Copy-Fixture $source cache;$distribution=[pscustomobject]@{Name='personal';SourcePath=$source;CachePath=$cache};$before=Get-Snapshot @($source,$cache)
    $healthy=&$validator -Distribution $distribution -ExpectedVersion '0.7.4' -ReferenceTimeUtc ([datetimeoffset]'2026-09-06T08:00:00Z') -NoThrow
    if(-not$healthy.Passed-or$healthy.WritePerformed-or$healthy.SchemaVersion-ne'1.0'-or$healthy.Distributions[0].SourceTreeSha256-cne$healthy.Distributions[0].CacheTreeSha256){throw 'Healthy distribution contract failed.'}
    if((Get-Snapshot @($source,$cache))-cne$before){throw 'Read-only health validation changed a distribution fixture.'}

    $empty=&$validator -Distribution @() -ExpectedVersion '0.7.4' -NoThrow
    Assert-GatesExactly -Result $empty -Expected @('DistributionEvidenceRequired') -Message 'Missing distribution evidence gate changed.'

    $alias=&$validator -Distribution ([pscustomobject]@{Name='alias';SourcePath=$source;CachePath=$source}) -ExpectedVersion '0.7.4' -NoThrow
    Assert-GatesExactly -Result $alias -Expected @('DistributionSourceCacheDistinct') -Message 'Source/cache alias gate changed.'

    $duplicates=&$validator -Distribution @($distribution,$distribution) -ExpectedVersion '0.7.4' -NoThrow
    Assert-GatesExactly -Result $duplicates -Expected @('DistributionNameUnique','DistributionSourcePathUnique','DistributionCachePathUnique') -Message 'Duplicate distribution gates changed.'

    $crossRoleSource=Copy-Fixture $source cross-role-source
    $crossRole=&$validator -Distribution @($distribution,[pscustomobject]@{Name='cross-role';SourcePath=$crossRoleSource;CachePath=$source}) -ExpectedVersion '0.7.4' -NoThrow
    Assert-GatesExactly -Result $crossRole -Expected @('DistributionRootUnique') -Message 'Cross-role duplicate root gate changed.'

    Set-Content -LiteralPath (Join-Path $cache 'scripts\fixture.ps1') -Value "'drifted'" -Encoding UTF8
    $drift=&$validator -Distribution $distribution -ExpectedVersion '0.7.4' -NoThrow
    Assert-GatesExactly -Result $drift -Expected @('DistributionTreeIdentity') -Message 'Tree drift gate changed.'
    Copy-Item -LiteralPath (Join-Path $source 'scripts\fixture.ps1') -Destination (Join-Path $cache 'scripts\fixture.ps1') -Force

    $unknownSource=Initialize-FixtureRoot unknown-source -Version 'unknown';$unknownCache=Copy-Fixture $unknownSource unknown-cache
    $unknown=&$validator -Distribution ([pscustomobject]@{Name='unknown';SourcePath=$unknownSource;CachePath=$unknownCache}) -ExpectedVersion '0.7.4' -NoThrow
    Assert-GatesExactly -Result $unknown -Expected @('DistributionSourceVersionValid','DistributionCacheVersionValid') -Message 'Unknown-version gates changed.'
    $missingVersionManifest=Get-Content -LiteralPath (Join-Path $unknownSource '.codex-plugin\plugin.json') -Raw|ConvertFrom-Json;$missingVersionManifest.PSObject.Properties.Remove('version');$missingVersionManifest|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $unknownSource '.codex-plugin\plugin.json') -Encoding UTF8
    $missingVersion=&$validator -Distribution ([pscustomobject]@{Name='missing-version';SourcePath=$unknownSource;CachePath=$cache}) -ExpectedVersion '0.7.4' -NoThrow
    Assert-GatesExactly -Result $missingVersion -Expected @('DistributionSourceVersionValid','DistributionTreeIdentity') -Message 'Missing-version gates changed.'

    $missing=&$validator -Distribution ([pscustomobject]@{Name='missing';SourcePath=(Join-Path $tempRoot 'missing-source');CachePath=$cache}) -ExpectedVersion '0.7.4' -NoThrow
    Assert-GatesExactly -Result $missing -Expected @('DistributionSourceExists') -Message 'Missing-source gate changed.'

    $codexPath=Join-Path $tempRoot 'codex.exe';Set-Content -LiteralPath $codexPath -Value 'fixture-codex' -Encoding UTF8
    $catalogPath=Join-Path $tempRoot 'catalog.json';'{"models":[{"slug":"fixture-model"}]}'|Set-Content -LiteralPath $catalogPath -Encoding UTF8
    $manifestPath=Join-Path $tempRoot 'catalog.manifest.json';[ordered]@{schemaVersion='1.1';generatedAtUtc='2026-09-06T07:30:00Z';model='fixture-model';contextWindow=4096;codexPath=$codexPath;codexVersion='0.0.0';codexSha256=(Get-FileHash $codexPath -Algorithm SHA256).Hash.ToLowerInvariant();catalogPath=$catalogPath;catalogSha256=(Get-FileHash $catalogPath -Algorithm SHA256).Hash.ToLowerInvariant()}|ConvertTo-Json|Set-Content -LiteralPath $manifestPath -Encoding UTF8
    $catalogHealthy=&$validator -Distribution $distribution -ExpectedVersion '0.7.4' -CatalogManifestPath $manifestPath -RequireCatalog -ReferenceTimeUtc ([datetimeoffset]'2026-09-06T08:00:00Z') -NoThrow
    if(-not$catalogHealthy.Passed-or$catalogHealthy.Catalogs.Count-ne1){throw 'Healthy catalog contract failed.'}

    $stale=&$validator -Distribution $distribution -ExpectedVersion '0.7.4' -CatalogManifestPath $manifestPath -RequireCatalog -MaximumCatalogAgeHours 1 -ReferenceTimeUtc ([datetimeoffset]'2026-09-06T10:00:00Z') -NoThrow
    Assert-GatesExactly -Result $stale -Expected @('CatalogFreshness') -Message 'Stale catalog gate changed.'
    $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json;$manifest.schemaVersion='unknown';$manifest|ConvertTo-Json|Set-Content -LiteralPath $manifestPath -Encoding UTF8
    $unknownSchema=&$validator -Distribution $distribution -ExpectedVersion '0.7.4' -CatalogManifestPath $manifestPath -ReferenceTimeUtc ([datetimeoffset]'2026-09-06T08:00:00Z') -NoThrow
    Assert-GatesExactly -Result $unknownSchema -Expected @('CatalogSchemaVersion') -Message 'Unknown catalog schema gate changed.'
    $manifest.schemaVersion='1.1';$manifest|ConvertTo-Json|Set-Content -LiteralPath $manifestPath -Encoding UTF8;Set-Content -LiteralPath $catalogPath -Value '{"models":[]}' -Encoding UTF8
    $catalogDrift=&$validator -Distribution $distribution -ExpectedVersion '0.7.4' -CatalogManifestPath $manifestPath -ReferenceTimeUtc ([datetimeoffset]'2026-09-06T08:00:00Z') -NoThrow
    Assert-GatesExactly -Result $catalogDrift -Expected @('CatalogArtifactHash','CatalogModelEntry') -Message 'Catalog drift gates changed.'
    $required=&$validator -Distribution $distribution -ExpectedVersion '0.7.4' -RequireCatalog -NoThrow
    Assert-GatesExactly -Result $required -Expected @('CatalogEvidenceRequired') -Message 'Missing catalog evidence gate changed.'
    'PowerShell Workbench health contracts passed.'
}finally{Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue}
