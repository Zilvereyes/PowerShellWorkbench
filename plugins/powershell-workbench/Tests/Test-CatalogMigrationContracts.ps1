[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$pluginRoot = Split-Path -Parent $PSScriptRoot
$previewer = Join-Path $pluginRoot 'scripts\Get-PowerShellWorkbenchCatalogMigrationPreview.ps1'
$generator = Join-Path $pluginRoot 'scripts\New-PowerShellWorkbenchLocalModelCatalog.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('powershell-workbench-catalog-migration-' + [guid]::NewGuid().ToString('N'))
$referenceTime = [datetimeoffset]'2026-09-06T12:00:00Z'
$maximumSourceAgeHours = 24
$expectedOverrides = @(
    'use_responses_lite=false when present',
    'tool_mode removed when present',
    'multi_agent_version removed when present',
    'service_tier/service_tiers removed when present',
    'supports_search_tool=false when present'
)
$expectedUnasserted = @(
    'reasoning-levels',
    'speed-tiers',
    'service-tier',
    'input-modalities',
    'responses-lite',
    'tool-mode',
    'multi-agent-version',
    'search-tool'
)
New-Item -ItemType Directory -Path $tempRoot | Out-Null

function Assert-GatesExactly {
    param($Result,[string[]]$Expected,[string]$Message)
    if (@($Result.FailedGates).Count -ne $Expected.Count -or (Compare-Object @($Result.FailedGates) $Expected)) {
        throw "$Message Actual: $($Result.FailedGates -join ', ')"
    }
}

function Get-Snapshot {
    param([string]$Root)
    @((Get-ChildItem -LiteralPath $Root -Recurse -File | ForEach-Object {
        "$($_.FullName)|$($_.Length)|$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)|$($_.LastWriteTimeUtc.Ticks)"
    }) | Sort-Object) -join "`n"
}

function Initialize-Fixture {
    param([string]$Name,[string]$SchemaVersion = '1.0',[switch]$UnknownProperty)
    $root = Join-Path $tempRoot $Name
    New-Item -ItemType Directory -Path $root | Out-Null
    $codexPath = Join-Path $root 'codex.exe'
    Set-Content -LiteralPath $codexPath -Value 'fixture-codex' -Encoding UTF8
    $catalogPath = Join-Path $root 'catalog.json'
    '{"models":[{"slug":"fixture-model","display_name":"Fixture model"}]}' |
        Set-Content -LiteralPath $catalogPath -Encoding UTF8
    $unasserted = if ($SchemaVersion -ceq '1.1') { $expectedUnasserted } else { @('reasoning-levels') }
    $manifest = [ordered]@{
        schemaVersion=$SchemaVersion;generatedAtUtc='2026-09-06T08:00:00Z';model='fixture-model';contextWindow=4096
        codexPath=$codexPath;codexVersion='0.0.0';codexSha256=(Get-FileHash $codexPath -Algorithm SHA256).Hash.ToLowerInvariant()
        baseModelSlug='fixture-base';bundledCatalogSha256=('a' * 64);catalogPath=$catalogPath
        catalogSha256=(Get-FileHash $catalogPath -Algorithm SHA256).Hash.ToLowerInvariant();unassertedCapabilities=$unasserted
    }
    if ($SchemaVersion -ceq '1.1') {
        $snapshot = [ordered]@{use_responses_lite=$false;tool_mode=$null;multi_agent_version=$null;supports_search_tool=$false}
        $manifest.transport = [ordered]@{base=$snapshot;effective=$snapshot;overrides=$expectedOverrides}
    }
    if ($UnknownProperty) { $manifest.unexpected = 'blocked' }
    $manifestPath = Join-Path $root 'catalog.json.manifest.json'
    $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    [pscustomobject]@{
        Root=$root;ManifestPath=$manifestPath
        ManifestSha256=(Get-FileHash $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
        CatalogPath=$catalogPath;CodexPath=$codexPath
    }
}

function Invoke-Preview {
    param(
        [Parameter(Mandatory)]$Fixture,
        [string]$ExpectedManifestSha256,
        [string]$DestinationCatalogPath,
        [string]$AllowedWriteRoot,
        [datetimeoffset]$At = $referenceTime,
        [int]$MaximumAgeHours = $maximumSourceAgeHours
    )
    if ([string]::IsNullOrWhiteSpace($ExpectedManifestSha256)) { $ExpectedManifestSha256 = $Fixture.ManifestSha256 }
    if ([string]::IsNullOrWhiteSpace($DestinationCatalogPath)) { $DestinationCatalogPath = $Fixture.CatalogPath }
    if ([string]::IsNullOrWhiteSpace($AllowedWriteRoot)) { $AllowedWriteRoot = $Fixture.Root }
    & $previewer -ManifestPath $Fixture.ManifestPath -ExpectedManifestSha256 $ExpectedManifestSha256 `
        -DestinationCatalogPath $DestinationCatalogPath -AllowedWriteRoot $AllowedWriteRoot `
        -ReferenceTimeUtc $At -MaximumSourceAgeHours $MaximumAgeHours -NoThrow
}

try {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($previewer,[ref]$tokens,[ref]$errors)
    if (@($errors).Count -ne 0) { throw 'Catalog migration previewer has parser errors.' }
    $commands = @($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst]},$true) |
        ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
    foreach ($forbidden in @(
        'Set-Content','Add-Content','Out-File','New-Item','Copy-Item','Move-Item','Remove-Item','Start-Process',
        'Invoke-RestMethod','Invoke-WebRequest','Invoke-Expression','Set-Clipboard','git','gh'
    )) {
        if ($commands -contains $forbidden) { throw "Previewer contains forbidden command '$forbidden'." }
    }

    $fixture = Initialize-Fixture -Name legacy
    $before = Get-Snapshot -Root $fixture.Root
    $first = Invoke-Preview -Fixture $fixture
    $second = Invoke-Preview -Fixture $fixture
    if ($first.State -cne 'PREVIEW_READY' -or -not $first.Eligible -or -not $first.MigrationRequired -or
        $first.WritePerformed -or $first.ExecutionPerformed -or $first.TransportPerformed) {
        throw 'Legacy preview readiness contract failed.'
    }
    if ($first.Plan.Operation -cne 'RegenerateCatalog' -or -not $first.Plan.BackupRequired -or
        -not $first.Plan.PostValidationRequired -or -not $first.Plan.ExplicitApplyAuthorizationRequired) {
        throw 'Migration plan safety contract failed.'
    }
    if ($first.Plan.GeneratorPath -cne [IO.Path]::GetFullPath($generator) -or
        $first.Plan.GeneratorSha256 -cne (Get-FileHash -LiteralPath $generator -Algorithm SHA256).Hash.ToLowerInvariant() -or
        $first.Plan.AllowedWriteRoot -cne [IO.Path]::GetFullPath($fixture.Root) -or
        $first.Plan.BundledCatalogSha256 -cne ('a' * 64)) {
        throw 'Migration plan provenance binding failed.'
    }
    $argumentNames = @($first.Plan.GeneratorArguments.Keys)
    $expectedArgumentNames = @('Model','ContextWindow','DisplayName','CodexPath','ExpectedCodexSha256','OutputPath')
    if (Compare-Object $argumentNames $expectedArgumentNames -SyncWindow 0) { throw 'Generator argument mapping changed.' }
    if ($first.Plan.GeneratorArguments.OutputPath -cne $fixture.CatalogPath -or
        $first.Plan.GeneratorArguments.ExpectedCodexSha256 -cne $first.Plan.SourceCodexSha256) {
        throw 'Generator argument values are not bound to verified evidence.'
    }
    if ($first.PlanSha256 -cne $second.PlanSha256 -or
        (($first | ConvertTo-Json -Depth 12 -Compress) -cne ($second | ConvertTo-Json -Depth 12 -Compress))) {
        throw 'Migration preview is not deterministic.'
    }
    if ((Get-Snapshot -Root $fixture.Root) -cne $before) { throw 'Migration preview changed source evidence.' }

    $widerRoot = Invoke-Preview -Fixture $fixture -AllowedWriteRoot $tempRoot
    if ($widerRoot.State -cne 'PREVIEW_READY' -or $widerRoot.PlanSha256 -ceq $first.PlanSha256) {
        throw 'Allowed root policy is not bound into PlanSha256.'
    }
    $laterReference = Invoke-Preview -Fixture $fixture -At ([datetimeoffset]'2026-09-06T13:00:00Z')
    if ($laterReference.State -cne 'PREVIEW_READY' -or $laterReference.PlanSha256 -ceq $first.PlanSha256) {
        throw 'Freshness policy is not bound into PlanSha256.'
    }

    $current = Initialize-Fixture -Name current -SchemaVersion '1.1'
    $noChange = Invoke-Preview -Fixture $current
    if ($noChange.State -cne 'NO_CHANGE' -or $noChange.Eligible -or $noChange.MigrationRequired -or $null -ne $noChange.Plan) {
        throw 'Current-schema no-change contract failed.'
    }

    $transportManifest = Get-Content -LiteralPath $current.ManifestPath -Raw | ConvertFrom-Json
    $transportManifest.transport.effective.tool_mode = 'code_mode_only'
    $transportManifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $current.ManifestPath -Encoding UTF8
    $transportResult = Invoke-Preview -Fixture $current -ExpectedManifestSha256 (Get-FileHash $current.ManifestPath -Algorithm SHA256).Hash
    Assert-GatesExactly -Result $transportResult -Expected @('SourceTransportEvidence') -Message 'Transport invariant gate changed.'

    foreach ($falseLike in @(0,'False')) {
        $typedTransport = Initialize-Fixture -Name ("transport-type-$falseLike") -SchemaVersion '1.1'
        $typedManifest = Get-Content -LiteralPath $typedTransport.ManifestPath -Raw | ConvertFrom-Json
        $typedManifest.transport.effective.use_responses_lite = $falseLike
        $typedManifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $typedTransport.ManifestPath -Encoding UTF8
        $typedResult = Invoke-Preview -Fixture $typedTransport `
            -ExpectedManifestSha256 (Get-FileHash $typedTransport.ManifestPath -Algorithm SHA256).Hash
        Assert-GatesExactly -Result $typedResult -Expected @('SourceTransportEvidence') `
            -Message "Transport type gate changed for '$falseLike'."
    }

    $hashDrift = Invoke-Preview -Fixture $fixture -ExpectedManifestSha256 ('0' * 64)
    Assert-GatesExactly -Result $hashDrift -Expected @('SourceManifestHash') -Message 'Manifest drift gate changed.'

    $unknown = Initialize-Fixture -Name unknown -SchemaVersion '9.9'
    $unknownResult = Invoke-Preview -Fixture $unknown
    Assert-GatesExactly -Result $unknownResult -Expected @('SourceSchemaSupported') -Message 'Unknown schema gate changed.'

    $extra = Initialize-Fixture -Name extra -UnknownProperty
    $extraResult = Invoke-Preview -Fixture $extra
    Assert-GatesExactly -Result $extraResult -Expected @('SourceManifestShape') -Message 'Unexpected manifest property gate changed.'

    $identity = Initialize-Fixture -Name identity
    $identityManifest = Get-Content -LiteralPath $identity.ManifestPath -Raw | ConvertFrom-Json
    $identityManifest.bundledCatalogSha256 = 'unknown'
    $identityManifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $identity.ManifestPath -Encoding UTF8
    $identityResult = Invoke-Preview -Fixture $identity -ExpectedManifestSha256 (Get-FileHash $identity.ManifestPath -Algorithm SHA256).Hash
    Assert-GatesExactly -Result $identityResult -Expected @('SourceGenerationIdentity') -Message 'Generation identity gate changed.'

    $capabilities = Initialize-Fixture -Name capabilities
    $capabilitiesManifest = Get-Content -LiteralPath $capabilities.ManifestPath -Raw | ConvertFrom-Json
    $capabilitiesManifest.unassertedCapabilities = @('duplicate','duplicate')
    $capabilitiesManifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $capabilities.ManifestPath -Encoding UTF8
    $capabilitiesResult = Invoke-Preview -Fixture $capabilities -ExpectedManifestSha256 (Get-FileHash $capabilities.ManifestPath -Algorithm SHA256).Hash
    Assert-GatesExactly -Result $capabilitiesResult -Expected @('SourceCapabilityEvidence') -Message 'Capability evidence gate changed.'

    $stale = Initialize-Fixture -Name stale
    $staleManifest = Get-Content -LiteralPath $stale.ManifestPath -Raw | ConvertFrom-Json
    $staleManifest.generatedAtUtc = '2026-09-04T08:00:00Z'
    $staleManifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $stale.ManifestPath -Encoding UTF8
    $staleResult = Invoke-Preview -Fixture $stale -ExpectedManifestSha256 (Get-FileHash $stale.ManifestPath -Algorithm SHA256).Hash
    Assert-GatesExactly -Result $staleResult -Expected @('SourceFreshness') -Message 'Stale source gate changed.'

    $future = Initialize-Fixture -Name future
    $futureManifest = Get-Content -LiteralPath $future.ManifestPath -Raw | ConvertFrom-Json
    $futureManifest.generatedAtUtc = '2026-09-07T08:00:00Z'
    $futureManifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $future.ManifestPath -Encoding UTF8
    $futureResult = Invoke-Preview -Fixture $future -ExpectedManifestSha256 (Get-FileHash $future.ManifestPath -Algorithm SHA256).Hash
    Assert-GatesExactly -Result $futureResult -Expected @('SourceFreshness') -Message 'Future source gate changed.'

    Set-Content -LiteralPath $fixture.CatalogPath -Value '{"models":[]}' -Encoding UTF8
    $catalogDrift = Invoke-Preview -Fixture $fixture
    Assert-GatesExactly -Result $catalogDrift -Expected @('SourceCatalogHash') -Message 'Catalog drift gate changed.'

    $boundary = Initialize-Fixture -Name boundary -SchemaVersion '1.1'
    $outside = Join-Path $tempRoot 'outside.json'
    $outsideResult = Invoke-Preview -Fixture $boundary -DestinationCatalogPath $outside
    Assert-GatesExactly -Result $outsideResult -Expected @('DestinationPathAllowed') -Message 'Destination boundary gate changed.'

    $driveRelativeManifest = [pscustomobject]@{
        Root=$boundary.Root;ManifestPath='C:relative-manifest.json';ManifestSha256=$boundary.ManifestSha256
        CatalogPath=$boundary.CatalogPath;CodexPath=$boundary.CodexPath
    }
    $driveRelativeManifestResult = Invoke-Preview -Fixture $driveRelativeManifest
    Assert-GatesExactly -Result $driveRelativeManifestResult -Expected @('SourceManifestPathAbsolute') `
        -Message 'Drive-relative manifest gate changed.'

    $driveRelativeDestinationResult = Invoke-Preview -Fixture $boundary -DestinationCatalogPath 'C:relative-catalog.json'
    Assert-GatesExactly -Result $driveRelativeDestinationResult -Expected @('DestinationCatalogPathAbsolute') `
        -Message 'Drive-relative destination gate changed.'

    $driveRelativeRootResult = Invoke-Preview -Fixture $boundary -AllowedWriteRoot 'C:relative-root'
    Assert-GatesExactly -Result $driveRelativeRootResult -Expected @('AllowedWriteRootAbsolute') `
        -Message 'Drive-relative allowed root gate changed.'

    $relativeCatalog = Initialize-Fixture -Name relative-catalog
    $relativeCatalogManifest = Get-Content -LiteralPath $relativeCatalog.ManifestPath -Raw | ConvertFrom-Json
    $relativeCatalogManifest.catalogPath = 'C:relative-catalog.json'
    $relativeCatalogManifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $relativeCatalog.ManifestPath -Encoding UTF8
    $relativeCatalogResult = Invoke-Preview -Fixture $relativeCatalog `
        -ExpectedManifestSha256 (Get-FileHash $relativeCatalog.ManifestPath -Algorithm SHA256).Hash
    Assert-GatesExactly -Result $relativeCatalogResult -Expected @('SourceCatalogPathAbsolute') `
        -Message 'Drive-relative source catalog gate changed.'

    $relativeCodex = Initialize-Fixture -Name relative-codex
    $relativeCodexManifest = Get-Content -LiteralPath $relativeCodex.ManifestPath -Raw | ConvertFrom-Json
    $relativeCodexManifest.codexPath = 'C:relative-codex.exe'
    $relativeCodexManifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $relativeCodex.ManifestPath -Encoding UTF8
    $relativeCodexResult = Invoke-Preview -Fixture $relativeCodex `
        -ExpectedManifestSha256 (Get-FileHash $relativeCodex.ManifestPath -Algorithm SHA256).Hash
    Assert-GatesExactly -Result $relativeCodexResult -Expected @('SourceCodexPathAbsolute') `
        -Message 'Drive-relative source Codex gate changed.'

    $reparse = Initialize-Fixture -Name reparse
    $reparseTarget = Join-Path $tempRoot 'reparse-target'
    New-Item -ItemType Directory -Path $reparseTarget | Out-Null
    $reparseLink = Join-Path $reparse.Root 'linked'
    New-Item -ItemType Junction -Path $reparseLink -Target $reparseTarget | Out-Null
    $reparseResult = Invoke-Preview -Fixture $reparse -DestinationCatalogPath (Join-Path $reparseLink 'catalog.json')
    Assert-GatesExactly -Result $reparseResult -Expected @('DestinationPathNotReparsePoint') -Message 'Destination reparse gate changed.'

    $rootReparseResult = Invoke-Preview -Fixture $reparse -DestinationCatalogPath (Join-Path $reparseLink 'catalog.json') `
        -AllowedWriteRoot $reparseLink
    Assert-GatesExactly -Result $rootReparseResult -Expected @('AllowedWriteRootNotReparsePoint') `
        -Message 'Allowed root reparse gate changed.'

    'PowerShell Workbench catalog migration contracts passed.'
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
