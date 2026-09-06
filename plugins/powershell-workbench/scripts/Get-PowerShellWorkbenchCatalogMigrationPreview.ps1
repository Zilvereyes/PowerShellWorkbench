[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ManifestPath,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedManifestSha256,
    [Parameter(Mandatory)][string]$DestinationCatalogPath,
    [Parameter(Mandatory)][string]$AllowedWriteRoot,
    [Parameter(Mandatory)][datetimeoffset]$ReferenceTimeUtc,
    [ValidateRange(1,8760)][int]$MaximumSourceAgeHours = 24,
    [ValidateSet('1.1')][string]$TargetSchemaVersion = '1.1',
    [switch]$NoThrow
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$failedGates = New-Object System.Collections.Generic.List[string]
$diagnostics = New-Object System.Collections.Generic.List[object]

function Add-FailedGate {
    param([string]$Gate,[string]$Subject,[string]$Message)
    if (-not $failedGates.Contains($Gate)) { $failedGates.Add($Gate) }
    $diagnostics.Add([pscustomobject][ordered]@{ Gate=$Gate;Subject=$Subject;Message=$Message })
}

function Get-PropertyValue {
    param([object]$InputObject,[string]$Name)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    $property.Value
}

function Get-Sha256Text {
    param([string]$Text)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
        ([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()
    } finally { $algorithm.Dispose() }
}

function Test-PathWithinRoot {
    param([string]$Path,[string]$Root)
    $separator = [IO.Path]::DirectorySeparatorChar
    $normalizedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    $normalizedPath = [IO.Path]::GetFullPath($Path)
    $normalizedPath.StartsWith($normalizedRoot + $separator,[StringComparison]::OrdinalIgnoreCase)
}

function Test-FullyQualifiedPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path)) { return $false }
    if ($Path -match '^[A-Za-z]:($|[^\\/])' -or $Path -match '^[\\/](?![\\/])') { return $false }
    $true
}

function Test-PathChainWithoutReparsePoint {
    param([string]$Path,[string]$Root)
    $normalizedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    $current = [IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
        }
        if ($current -ieq $normalizedRoot) { return $true }
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ieq $current) { break }
        $current = $parent.TrimEnd('\','/')
    }
    $false
}

function Test-ManifestShape {
    param([object]$Manifest,[string]$SchemaVersion)
    $common = @('schemaVersion','generatedAtUtc','model','contextWindow','codexPath','codexVersion','codexSha256','baseModelSlug','bundledCatalogSha256','catalogPath','catalogSha256','unassertedCapabilities')
    $allowed = if ($SchemaVersion -ceq '1.1') { @($common + 'transport') } else { $common }
    $required = if ($SchemaVersion -ceq '1.1') { $allowed } else { $common }
    $names = @($Manifest.PSObject.Properties.Name)
    if (@($names | Where-Object { $allowed -cnotcontains $_ }).Count -gt 0) { return $false }
    if (@($required | Where-Object { $names -cnotcontains $_ }).Count -gt 0) { return $false }
    $true
}

function Test-NonEmptyUniqueStringArray {
    param([object[]]$Values)
    if (@($Values).Count -eq 0) { return $false }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($value in @($Values)) {
        if ([string]::IsNullOrWhiteSpace([string]$value) -or -not $seen.Add([string]$value)) { return $false }
    }
    $true
}

function Test-ExactStringArray {
    param([object[]]$Actual,[string[]]$Expected)
    if (@($Actual).Count -ne $Expected.Count) { return $false }
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        if ([string]$Actual[$index] -cne $Expected[$index]) { return $false }
    }
    $true
}

function Test-TransportSnapshotShape {
    param([object]$Snapshot)
    if ($null -eq $Snapshot -or $Snapshot -is [string] -or $Snapshot -is [Collections.IEnumerable]) { return $false }
    $names = @($Snapshot.PSObject.Properties.Name)
    $expected = @('use_responses_lite','tool_mode','multi_agent_version','supports_search_tool')
    @($names | Where-Object { $expected -cnotcontains $_ }).Count -eq 0 -and
        @($expected | Where-Object { $names -cnotcontains $_ }).Count -eq 0
}

function Test-TransportSnapshotValueTypes {
    param([object]$Snapshot)
    if (-not (Test-TransportSnapshotShape -Snapshot $Snapshot)) { return $false }
    $responsesLite = Get-PropertyValue -InputObject $Snapshot -Name 'use_responses_lite'
    $toolMode = Get-PropertyValue -InputObject $Snapshot -Name 'tool_mode'
    $multiAgentVersion = Get-PropertyValue -InputObject $Snapshot -Name 'multi_agent_version'
    $supportsSearch = Get-PropertyValue -InputObject $Snapshot -Name 'supports_search_tool'
    ($null -eq $responsesLite -or $responsesLite -is [bool]) -and
        ($null -eq $toolMode -or $toolMode -is [string]) -and
        ($null -eq $multiAgentVersion -or $multiAgentVersion -is [string]) -and
        ($null -eq $supportsSearch -or $supportsSearch -is [bool])
}

function Test-EffectiveTransportInvariant {
    param([object]$Snapshot)
    if (-not (Test-TransportSnapshotValueTypes -Snapshot $Snapshot)) { return $false }
    $responsesLite = Get-PropertyValue -InputObject $Snapshot -Name 'use_responses_lite'
    $toolMode = Get-PropertyValue -InputObject $Snapshot -Name 'tool_mode'
    $multiAgentVersion = Get-PropertyValue -InputObject $Snapshot -Name 'multi_agent_version'
    $supportsSearch = Get-PropertyValue -InputObject $Snapshot -Name 'supports_search_tool'
    ($null -eq $responsesLite -or ($responsesLite -is [bool] -and -not $responsesLite)) -and
        $null -eq $toolMode -and
        $null -eq $multiAgentVersion -and
        ($null -eq $supportsSearch -or ($supportsSearch -is [bool] -and -not $supportsSearch))
}

$manifestResolved = $null
$destinationResolved = $null
$destinationManifestPath = $null
$allowedRootResolved = $null
$allowedRootUsable = $false
$manifestSha256 = $null
$catalogPath = $null
$catalogSha256 = $null
$codexPath = $null
$codexSha256 = $null
$sourceSchemaVersion = $null
$model = $null
$displayName = $null
$contextWindow = [int64]0
$manifest = $null
$referenceTimeResolved = $ReferenceTimeUtc.ToUniversalTime()
$generatorPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'New-PowerShellWorkbenchLocalModelCatalog.ps1'))
$generatorSha256 = $null
$sourceGeneratedAtUtc = $null
$bundledCatalogSha256 = $null

if (-not (Test-FullyQualifiedPath -Path $ManifestPath)) {
    Add-FailedGate -Gate 'SourceManifestPathAbsolute' -Subject $ManifestPath -Message 'ManifestPath must be absolute.'
} else { $manifestResolved = [IO.Path]::GetFullPath($ManifestPath) }

if (-not (Test-FullyQualifiedPath -Path $AllowedWriteRoot)) {
    Add-FailedGate -Gate 'AllowedWriteRootAbsolute' -Subject $AllowedWriteRoot -Message 'AllowedWriteRoot must be absolute.'
} else {
    $allowedRootResolved = [IO.Path]::GetFullPath($AllowedWriteRoot).TrimEnd('\','/')
    if ($allowedRootResolved -ieq [IO.Path]::GetPathRoot($allowedRootResolved)) {
        Add-FailedGate -Gate 'AllowedWriteRootScoped' -Subject $allowedRootResolved -Message 'AllowedWriteRoot cannot be a drive root.'
    } elseif (-not (Test-Path -LiteralPath $allowedRootResolved -PathType Container)) {
        Add-FailedGate -Gate 'AllowedWriteRootExists' -Subject $allowedRootResolved -Message 'AllowedWriteRoot does not exist.'
    } elseif ((Get-Item -LiteralPath $allowedRootResolved).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        Add-FailedGate -Gate 'AllowedWriteRootNotReparsePoint' -Subject $allowedRootResolved -Message 'AllowedWriteRoot cannot be a reparse point.'
    } else { $allowedRootUsable = $true }
}

if (-not (Test-FullyQualifiedPath -Path $DestinationCatalogPath)) {
    Add-FailedGate -Gate 'DestinationCatalogPathAbsolute' -Subject $DestinationCatalogPath -Message 'DestinationCatalogPath must be absolute.'
} else {
    $destinationResolved = [IO.Path]::GetFullPath($DestinationCatalogPath)
    $destinationManifestPath = "$destinationResolved.manifest.json"
    if ($allowedRootUsable -and -not (Test-PathWithinRoot -Path $destinationResolved -Root $allowedRootResolved)) {
        Add-FailedGate -Gate 'DestinationPathAllowed' -Subject $destinationResolved -Message 'DestinationCatalogPath is outside AllowedWriteRoot.'
    } elseif ($allowedRootUsable -and
        (-not (Test-PathChainWithoutReparsePoint -Path $destinationResolved -Root $allowedRootResolved) -or
        -not (Test-PathChainWithoutReparsePoint -Path $destinationManifestPath -Root $allowedRootResolved))) {
        Add-FailedGate -Gate 'DestinationPathNotReparsePoint' -Subject $destinationResolved -Message 'Destination paths cannot traverse a reparse point.'
    }
}

if ($manifestResolved) {
    if (-not (Test-Path -LiteralPath $manifestResolved -PathType Leaf)) {
        Add-FailedGate -Gate 'SourceManifestExists' -Subject $manifestResolved -Message 'Source catalog manifest is missing.'
    } else {
        $manifestSha256 = (Get-FileHash -LiteralPath $manifestResolved -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($manifestSha256 -cne $ExpectedManifestSha256.ToLowerInvariant()) {
            Add-FailedGate -Gate 'SourceManifestHash' -Subject $manifestResolved -Message 'Source manifest SHA-256 does not match ExpectedManifestSha256.'
        } else {
            try { $manifest = Get-Content -LiteralPath $manifestResolved -Raw | ConvertFrom-Json }
            catch { Add-FailedGate -Gate 'SourceManifestValid' -Subject $manifestResolved -Message 'Source catalog manifest is invalid JSON.' }
        }
    }
}

if ($manifest) {
    $sourceSchemaVersion = [string](Get-PropertyValue -InputObject $manifest -Name 'schemaVersion')
    if ($sourceSchemaVersion -cnotin @('1.0','1.1')) {
        Add-FailedGate -Gate 'SourceSchemaSupported' -Subject $manifestResolved -Message 'Source schema version is unknown or unsupported.'
    } elseif (-not (Test-ManifestShape -Manifest $manifest -SchemaVersion $sourceSchemaVersion)) {
        Add-FailedGate -Gate 'SourceManifestShape' -Subject $manifestResolved -Message 'Source manifest properties do not match its declared schema.'
    }

    $generatedAtText = [string](Get-PropertyValue -InputObject $manifest -Name 'generatedAtUtc')
    $generatedAt = [datetimeoffset]::MinValue
    $codexVersion = [string](Get-PropertyValue -InputObject $manifest -Name 'codexVersion')
    $baseModelSlug = [string](Get-PropertyValue -InputObject $manifest -Name 'baseModelSlug')
    $bundledCatalogSha256 = [string](Get-PropertyValue -InputObject $manifest -Name 'bundledCatalogSha256')
    $generatedAtValid = [datetimeoffset]::TryParse($generatedAtText,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$generatedAt)
    if (-not $generatedAtValid -or $codexVersion -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$' -or [string]::IsNullOrWhiteSpace($baseModelSlug) -or $bundledCatalogSha256 -notmatch '^[a-fA-F0-9]{64}$') {
        Add-FailedGate -Gate 'SourceGenerationIdentity' -Subject $manifestResolved -Message 'Source generation time, Codex version, base model, or bundled catalog identity is invalid.'
    } else {
        $sourceGeneratedAtUtc = $generatedAt.ToUniversalTime()
        $sourceAge = $referenceTimeResolved - $sourceGeneratedAtUtc
        if ($sourceGeneratedAtUtc -gt $referenceTimeResolved -or $sourceAge.TotalHours -gt $MaximumSourceAgeHours) {
            Add-FailedGate -Gate 'SourceFreshness' -Subject $manifestResolved -Message 'Source manifest is stale or generated after ReferenceTimeUtc.'
        }
    }
    $unasserted = @(Get-PropertyValue -InputObject $manifest -Name 'unassertedCapabilities')
    if (-not (Test-NonEmptyUniqueStringArray -Values $unasserted)) {
        Add-FailedGate -Gate 'SourceCapabilityEvidence' -Subject $manifestResolved -Message 'Source unasserted capabilities must be non-empty unique strings.'
    }

    $model = [string](Get-PropertyValue -InputObject $manifest -Name 'model')
    $contextText = [string](Get-PropertyValue -InputObject $manifest -Name 'contextWindow')
    if ([string]::IsNullOrWhiteSpace($model) -or -not [int64]::TryParse($contextText,[ref]$contextWindow) -or $contextWindow -le 0) {
        Add-FailedGate -Gate 'SourceModelIdentity' -Subject $manifestResolved -Message 'Source model or context identity is invalid.'
    }

    $catalogInput = [string](Get-PropertyValue -InputObject $manifest -Name 'catalogPath')
    if (-not (Test-FullyQualifiedPath -Path $catalogInput)) {
        Add-FailedGate -Gate 'SourceCatalogPathAbsolute' -Subject $manifestResolved -Message 'Source catalog path must be absolute.'
    } else {
        $catalogPath = [IO.Path]::GetFullPath($catalogInput)
        if (-not (Test-Path -LiteralPath $catalogPath -PathType Leaf)) {
            Add-FailedGate -Gate 'SourceCatalogExists' -Subject $catalogPath -Message 'Source catalog is missing.'
        } else {
            $catalogSha256 = (Get-FileHash -LiteralPath $catalogPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $declaredCatalogSha256 = [string](Get-PropertyValue -InputObject $manifest -Name 'catalogSha256')
            if ($declaredCatalogSha256 -notmatch '^[a-fA-F0-9]{64}$' -or $catalogSha256 -cne $declaredCatalogSha256.ToLowerInvariant()) {
                Add-FailedGate -Gate 'SourceCatalogHash' -Subject $catalogPath -Message 'Source catalog SHA-256 does not match its manifest.'
            } else {
                try {
                    $catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
                    $models = @(Get-PropertyValue -InputObject $catalog -Name 'models')
                    $catalogMatches = @($models | Where-Object { [string](Get-PropertyValue -InputObject $_ -Name 'slug') -ceq $model })
                    if ($catalogMatches.Count -ne 1) {
                        Add-FailedGate -Gate 'SourceCatalogModelEntry' -Subject $catalogPath -Message 'Source catalog must contain exactly one matching model entry.'
                    } else { $displayName = [string](Get-PropertyValue -InputObject $catalogMatches[0] -Name 'display_name') }
                } catch { Add-FailedGate -Gate 'SourceCatalogValid' -Subject $catalogPath -Message 'Source catalog is invalid JSON.' }
            }
        }
    }

    $codexInput = [string](Get-PropertyValue -InputObject $manifest -Name 'codexPath')
    if (-not (Test-FullyQualifiedPath -Path $codexInput)) {
        Add-FailedGate -Gate 'SourceCodexPathAbsolute' -Subject $manifestResolved -Message 'Source Codex path must be absolute.'
    } else {
        $codexPath = [IO.Path]::GetFullPath($codexInput)
        if (-not (Test-Path -LiteralPath $codexPath -PathType Leaf)) {
            Add-FailedGate -Gate 'SourceCodexExists' -Subject $codexPath -Message 'Source Codex executable is missing.'
        } else {
            $codexSha256 = (Get-FileHash -LiteralPath $codexPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $declaredCodexSha256 = [string](Get-PropertyValue -InputObject $manifest -Name 'codexSha256')
            if ($declaredCodexSha256 -notmatch '^[a-fA-F0-9]{64}$' -or $codexSha256 -cne $declaredCodexSha256.ToLowerInvariant()) {
                Add-FailedGate -Gate 'SourceCodexHash' -Subject $codexPath -Message 'Source Codex SHA-256 does not match its manifest.'
            }
        }
    }

    if ($sourceSchemaVersion -ceq '1.1') {
        $transport = Get-PropertyValue -InputObject $manifest -Name 'transport'
        $transportNames = if ($null -eq $transport) { @() } else { @($transport.PSObject.Properties.Name) }
        $transportBase = if ($null -eq $transport) { $null } else { Get-PropertyValue -InputObject $transport -Name 'base' }
        $transportEffective = if ($null -eq $transport) { $null } else { Get-PropertyValue -InputObject $transport -Name 'effective' }
        $transportOverrides = if ($null -eq $transport) { @() } else { @(Get-PropertyValue -InputObject $transport -Name 'overrides') }
        $expectedOverrides = @('use_responses_lite=false when present','tool_mode removed when present','multi_agent_version removed when present','service_tier/service_tiers removed when present','supports_search_tool=false when present')
        $expectedUnasserted = @('reasoning-levels','speed-tiers','service-tier','input-modalities','responses-lite','tool-mode','multi-agent-version','search-tool')
        if ($null -eq $transport -or @($transportNames | Where-Object { @('base','effective','overrides') -cnotcontains $_ }).Count -gt 0 -or @(@('base','effective','overrides') | Where-Object { $transportNames -cnotcontains $_ }).Count -gt 0 -or -not (Test-TransportSnapshotValueTypes -Snapshot $transportBase) -or -not (Test-EffectiveTransportInvariant -Snapshot $transportEffective) -or -not (Test-ExactStringArray -Actual $transportOverrides -Expected $expectedOverrides) -or -not (Test-ExactStringArray -Actual $unasserted -Expected $expectedUnasserted)) {
            Add-FailedGate -Gate 'SourceTransportEvidence' -Subject $manifestResolved -Message 'Schema 1.1 transport evidence is incomplete.'
        }
    }
}

if ($destinationResolved -and $codexPath -and ($destinationResolved -ieq $codexPath -or $destinationManifestPath -ieq $codexPath)) {
    Add-FailedGate -Gate 'DestinationPathSafe' -Subject $destinationResolved -Message 'Destination paths cannot replace the Codex executable.'
}
if ($destinationResolved -and $catalogPath -and $destinationResolved -ine $catalogPath -and (Test-Path -LiteralPath $destinationResolved)) {
    Add-FailedGate -Gate 'DestinationCatalogAvailable' -Subject $destinationResolved -Message 'A non-source destination catalog already exists.'
}
if ($destinationManifestPath -and $manifestResolved -and $destinationManifestPath -ine $manifestResolved -and (Test-Path -LiteralPath $destinationManifestPath)) {
    Add-FailedGate -Gate 'DestinationManifestAvailable' -Subject $destinationManifestPath -Message 'A non-source destination manifest already exists.'
}

$migrationRequired = $sourceSchemaVersion -ceq '1.0'
$plan = $null
if ($migrationRequired) {
    if (-not (Test-Path -LiteralPath $generatorPath -PathType Leaf)) {
        Add-FailedGate -Gate 'GeneratorExists' -Subject $generatorPath -Message 'Catalog generator is missing.'
    } else { $generatorSha256 = (Get-FileHash -LiteralPath $generatorPath -Algorithm SHA256).Hash.ToLowerInvariant() }
}
if ($failedGates.Count -eq 0 -and $migrationRequired) {
    $generatorArguments = [ordered]@{
        Model=$model;ContextWindow=$contextWindow;DisplayName=$displayName;CodexPath=$codexPath
        ExpectedCodexSha256=$codexSha256;OutputPath=$destinationResolved
    }
    $plan = [ordered]@{
        Operation='RegenerateCatalog';SourceSchemaVersion=$sourceSchemaVersion;TargetSchemaVersion=$TargetSchemaVersion
        SourceManifestPath=$manifestResolved;SourceManifestSha256=$manifestSha256;SourceCatalogPath=$catalogPath;SourceCatalogSha256=$catalogSha256
        SourceGeneratedAtUtc=$sourceGeneratedAtUtc.ToString('o');ReferenceTimeUtc=$referenceTimeResolved.ToString('o');MaximumSourceAgeHours=$MaximumSourceAgeHours
        SourceCodexPath=$codexPath;SourceCodexSha256=$codexSha256;BundledCatalogSha256=$bundledCatalogSha256.ToLowerInvariant()
        DestinationCatalogPath=$destinationResolved;DestinationManifestPath=$destinationManifestPath;AllowedWriteRoot=$allowedRootResolved
        GeneratorPath=$generatorPath;GeneratorSha256=$generatorSha256;GeneratorArguments=$generatorArguments
        BackupRequired=$true;PostValidationRequired=$true;ExplicitApplyAuthorizationRequired=$true
    }
}
$planSha256 = if ($plan) { Get-Sha256Text -Text ($plan | ConvertTo-Json -Depth 8 -Compress) } else { $null }
$state = if ($failedGates.Count -gt 0) { 'BLOCKED' } elseif ($migrationRequired) { 'PREVIEW_READY' } else { 'NO_CHANGE' }
$result = [pscustomobject][ordered]@{
    SchemaVersion='1.0';State=$state;Eligible=($state -ceq 'PREVIEW_READY');MigrationRequired=$migrationRequired
    SourceSchemaVersion=$sourceSchemaVersion;TargetSchemaVersion=$TargetSchemaVersion;ManifestPath=$manifestResolved;ManifestSha256=$manifestSha256
    DestinationCatalogPath=$destinationResolved;DestinationManifestPath=$destinationManifestPath;AllowedWriteRoot=$allowedRootResolved
    ReferenceTimeUtc=$referenceTimeResolved.ToString('o');MaximumSourceAgeHours=$MaximumSourceAgeHours
    FailedGates=@($failedGates.ToArray());Diagnostics=@($diagnostics.ToArray());Plan=$plan;PlanSha256=$planSha256
    WritePerformed=$false;ExecutionPerformed=$false;TransportPerformed=$false
}
if ($state -ceq 'BLOCKED' -and -not $NoThrow) { throw "Catalog migration preview blocked: $($result.FailedGates -join ', ')" }
$result
