[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ManifestPath,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedManifestSha256,
    [Parameter(Mandatory)][string]$DestinationCatalogPath,
    [Parameter(Mandatory)][string]$AllowedWriteRoot,
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

$manifestResolved = $null
$destinationResolved = $null
$destinationManifestPath = $null
$allowedRootResolved = $null
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

if (-not [IO.Path]::IsPathRooted($ManifestPath)) {
    Add-FailedGate -Gate 'SourceManifestPathAbsolute' -Subject $ManifestPath -Message 'ManifestPath must be absolute.'
} else { $manifestResolved = [IO.Path]::GetFullPath($ManifestPath) }

if (-not [IO.Path]::IsPathRooted($AllowedWriteRoot)) {
    Add-FailedGate -Gate 'AllowedWriteRootAbsolute' -Subject $AllowedWriteRoot -Message 'AllowedWriteRoot must be absolute.'
} else {
    $allowedRootResolved = [IO.Path]::GetFullPath($AllowedWriteRoot).TrimEnd('\','/')
    if ($allowedRootResolved -ieq [IO.Path]::GetPathRoot($allowedRootResolved)) {
        Add-FailedGate -Gate 'AllowedWriteRootScoped' -Subject $allowedRootResolved -Message 'AllowedWriteRoot cannot be a drive root.'
    } elseif (-not (Test-Path -LiteralPath $allowedRootResolved -PathType Container)) {
        Add-FailedGate -Gate 'AllowedWriteRootExists' -Subject $allowedRootResolved -Message 'AllowedWriteRoot does not exist.'
    } elseif ((Get-Item -LiteralPath $allowedRootResolved).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        Add-FailedGate -Gate 'AllowedWriteRootNotReparsePoint' -Subject $allowedRootResolved -Message 'AllowedWriteRoot cannot be a reparse point.'
    }
}

if (-not [IO.Path]::IsPathRooted($DestinationCatalogPath)) {
    Add-FailedGate -Gate 'DestinationCatalogPathAbsolute' -Subject $DestinationCatalogPath -Message 'DestinationCatalogPath must be absolute.'
} else {
    $destinationResolved = [IO.Path]::GetFullPath($DestinationCatalogPath)
    $destinationManifestPath = "$destinationResolved.manifest.json"
    if ($allowedRootResolved -and -not (Test-PathWithinRoot -Path $destinationResolved -Root $allowedRootResolved)) {
        Add-FailedGate -Gate 'DestinationPathAllowed' -Subject $destinationResolved -Message 'DestinationCatalogPath is outside AllowedWriteRoot.'
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
    if ([string]::IsNullOrWhiteSpace($catalogInput) -or -not [IO.Path]::IsPathRooted($catalogInput)) {
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
    if ([string]::IsNullOrWhiteSpace($codexInput) -or -not [IO.Path]::IsPathRooted($codexInput)) {
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
        $transportOverrides = if ($null -eq $transport) { @() } else { @(Get-PropertyValue -InputObject $transport -Name 'overrides') }
        if ($null -eq $transport -or @($transportNames | Where-Object { @('base','effective','overrides') -cnotcontains $_ }).Count -gt 0 -or @(@('base','effective','overrides') | Where-Object { $transportNames -cnotcontains $_ }).Count -gt 0 -or -not (Test-NonEmptyUniqueStringArray -Values $transportOverrides)) {
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
if ($failedGates.Count -eq 0 -and $migrationRequired) {
    $plan = [ordered]@{
        Operation='RegenerateCatalog';SourceSchemaVersion=$sourceSchemaVersion;TargetSchemaVersion=$TargetSchemaVersion
        SourceManifestPath=$manifestResolved;SourceManifestSha256=$manifestSha256;SourceCatalogPath=$catalogPath;SourceCatalogSha256=$catalogSha256
        SourceCodexPath=$codexPath;SourceCodexSha256=$codexSha256;DestinationCatalogPath=$destinationResolved;DestinationManifestPath=$destinationManifestPath
        Generator='New-PowerShellWorkbenchLocalModelCatalog.ps1';Model=$model;DisplayName=$displayName;ContextWindow=$contextWindow
        BackupRequired=$true;PostValidationRequired=$true;ExplicitApplyAuthorizationRequired=$true
    }
}
$planSha256 = if ($plan) { Get-Sha256Text -Text ($plan | ConvertTo-Json -Depth 8 -Compress) } else { $null }
$state = if ($failedGates.Count -gt 0) { 'BLOCKED' } elseif ($migrationRequired) { 'PREVIEW_READY' } else { 'NO_CHANGE' }
$result = [pscustomobject][ordered]@{
    SchemaVersion='1.0';State=$state;Eligible=($state -ceq 'PREVIEW_READY');MigrationRequired=$migrationRequired
    SourceSchemaVersion=$sourceSchemaVersion;TargetSchemaVersion=$TargetSchemaVersion;ManifestPath=$manifestResolved;ManifestSha256=$manifestSha256
    DestinationCatalogPath=$destinationResolved;DestinationManifestPath=$destinationManifestPath;AllowedWriteRoot=$allowedRootResolved
    FailedGates=@($failedGates.ToArray());Diagnostics=@($diagnostics.ToArray());Plan=$plan;PlanSha256=$planSha256
    WritePerformed=$false;ExecutionPerformed=$false;TransportPerformed=$false
}
if ($state -ceq 'BLOCKED' -and -not $NoThrow) { throw "Catalog migration preview blocked: $($result.FailedGates -join ', ')" }
$result
