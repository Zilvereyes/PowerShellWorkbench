[CmdletBinding()]
param(
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Distribution,
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')][string]$ExpectedVersion,
    [string[]]$CatalogManifestPath = @(),
    [ValidateRange(1, 8760)][int]$MaximumCatalogAgeHours = 24,
    [datetimeoffset]$ReferenceTimeUtc = [datetimeoffset]::UtcNow,
    [switch]$RequireCatalog,
    [switch]$NoThrow
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$failedGates = New-Object System.Collections.Generic.List[string]
$diagnostics = New-Object System.Collections.Generic.List[object]

function Add-FailedGate {
    param([string]$Gate,[string]$Subject,[string]$Message)
    if (-not $failedGates.Contains($Gate)) { $failedGates.Add($Gate) }
    $diagnostics.Add([pscustomobject][ordered]@{ Gate = $Gate; Subject = $Subject; Message = $Message })
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
        ([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally { $algorithm.Dispose() }
}

function Get-CanonicalPath {
    param([string]$Path,[string]$BasePath)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    [IO.Path]::GetFullPath((Join-Path $BasePath $Path))
}

function Get-TreeIdentity {
    param([string]$Root)
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    $items = @(Get-ChildItem -LiteralPath $rootPath -Recurse -Force)
    if (@($items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count -gt 0) {
        throw 'Plugin tree contains a reparse point.'
    }
    $files = @($items | Where-Object { -not $_.PSIsContainer })
    $relativePaths = @($files | ForEach-Object { $_.FullName.Substring($rootPath.Length).TrimStart('\','/').Replace('\','/') })
    [Array]::Sort($relativePaths,[StringComparer]::Ordinal)
    $lines = foreach ($relativePath in $relativePaths) {
        $fullPath = Join-Path $rootPath $relativePath.Replace('/','\')
        $file = Get-Item -LiteralPath $fullPath
        '{0}|{1}|{2}' -f $relativePath,$file.Length,(Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    [pscustomobject][ordered]@{
        FileCount = $relativePaths.Count
        Sha256 = Get-Sha256Text -Text (@($lines) -join "`n")
    }
}

function Read-JsonFile {
    param([string]$Path)
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

$distributionResults = New-Object System.Collections.Generic.List[object]
$distributionNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$sourcePaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$cachePaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
if (@($Distribution).Count -eq 0) { Add-FailedGate -Gate 'DistributionEvidenceRequired' -Subject '<distribution>' -Message 'At least one distribution is required.' }

foreach ($entry in @($Distribution)) {
    $name = [string](Get-PropertyValue -InputObject $entry -Name 'Name')
    $sourceInput = [string](Get-PropertyValue -InputObject $entry -Name 'SourcePath')
    $cacheInput = [string](Get-PropertyValue -InputObject $entry -Name 'CachePath')
    $subject = if ([string]::IsNullOrWhiteSpace($name)) { '<unnamed>' } else { $name }
    if ([string]::IsNullOrWhiteSpace($name)) { Add-FailedGate -Gate 'DistributionNamePresent' -Subject $subject -Message 'Distribution name is missing.' }
    elseif (-not $distributionNames.Add($name)) { Add-FailedGate -Gate 'DistributionNameUnique' -Subject $subject -Message 'Distribution name is duplicated.' }

    $sourcePath = $null
    $cachePath = $null
    if ([string]::IsNullOrWhiteSpace($sourceInput) -or -not [IO.Path]::IsPathRooted($sourceInput)) {
        Add-FailedGate -Gate 'DistributionSourcePathAbsolute' -Subject $subject -Message 'SourcePath must be absolute.'
    } else {
        $sourcePath = [IO.Path]::GetFullPath($sourceInput)
        if (-not $sourcePaths.Add($sourcePath)) { Add-FailedGate -Gate 'DistributionSourcePathUnique' -Subject $subject -Message 'SourcePath is duplicated.' }
    }
    if ([string]::IsNullOrWhiteSpace($cacheInput) -or -not [IO.Path]::IsPathRooted($cacheInput)) {
        Add-FailedGate -Gate 'DistributionCachePathAbsolute' -Subject $subject -Message 'CachePath must be absolute.'
    } else {
        $cachePath = [IO.Path]::GetFullPath($cacheInput)
        if (-not $cachePaths.Add($cachePath)) { Add-FailedGate -Gate 'DistributionCachePathUnique' -Subject $subject -Message 'CachePath is duplicated.' }
    }
    if ($sourcePath -and $cachePath -and $sourcePath -ieq $cachePath) {
        Add-FailedGate -Gate 'DistributionSourceCacheDistinct' -Subject $subject -Message 'SourcePath and CachePath must be distinct.'
    } elseif (($sourcePath -and $cachePaths.Contains($sourcePath)) -or ($cachePath -and $sourcePaths.Contains($cachePath))) {
        Add-FailedGate -Gate 'DistributionRootUnique' -Subject $subject -Message 'A plugin root cannot be reused across source and cache roles.'
    }

    $sourceVersion = $null
    $cacheVersion = $null
    $sourceTree = $null
    $cacheTree = $null
    foreach ($side in @([pscustomobject]@{ Kind='Source'; Path=$sourcePath },[pscustomobject]@{ Kind='Cache'; Path=$cachePath })) {
        if (-not $side.Path) { continue }
        $existsGate = 'Distribution{0}Exists' -f $side.Kind
        if (-not (Test-Path -LiteralPath $side.Path -PathType Container)) {
            Add-FailedGate -Gate $existsGate -Subject $subject -Message "$($side.Kind) plugin root is missing."
            continue
        }
        $manifestPath = Join-Path $side.Path '.codex-plugin\plugin.json'
        $manifestGate = 'Distribution{0}ManifestValid' -f $side.Kind
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            Add-FailedGate -Gate $manifestGate -Subject $subject -Message "$($side.Kind) plugin manifest is missing."
            continue
        }
        try { $manifest = Read-JsonFile -Path $manifestPath }
        catch { Add-FailedGate -Gate $manifestGate -Subject $subject -Message "$($side.Kind) plugin manifest is invalid JSON."; continue }
        if ([string](Get-PropertyValue -InputObject $manifest -Name 'name') -cne 'powershell-workbench') {
            Add-FailedGate -Gate ('Distribution{0}Identity' -f $side.Kind) -Subject $subject -Message "$($side.Kind) plugin name is not powershell-workbench."
        }
        $version = [string](Get-PropertyValue -InputObject $manifest -Name 'version')
        if ($version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') {
            Add-FailedGate -Gate ('Distribution{0}VersionValid' -f $side.Kind) -Subject $subject -Message "$($side.Kind) plugin version is missing or unknown."
        } elseif ($version -cne $ExpectedVersion) {
            Add-FailedGate -Gate ('Distribution{0}VersionExpected' -f $side.Kind) -Subject $subject -Message "$($side.Kind) plugin version '$version' does not match '$ExpectedVersion'."
        }
        if ($side.Kind -eq 'Source') { $sourceVersion = $version } else { $cacheVersion = $version }
        try {
            $tree = Get-TreeIdentity -Root $side.Path
            if ($side.Kind -eq 'Source') { $sourceTree = $tree } else { $cacheTree = $tree }
        } catch { Add-FailedGate -Gate ('Distribution{0}TreeReadable' -f $side.Kind) -Subject $subject -Message $_.Exception.Message }
    }
    if ($sourceTree -and $cacheTree -and ($sourceTree.FileCount -ne $cacheTree.FileCount -or $sourceTree.Sha256 -cne $cacheTree.Sha256)) {
        Add-FailedGate -Gate 'DistributionTreeIdentity' -Subject $subject -Message 'Source and installed cache trees differ.'
    }
    $distributionResults.Add([pscustomobject][ordered]@{
        Name=$name;SourcePath=$sourcePath;CachePath=$cachePath;SourceVersion=$sourceVersion;CacheVersion=$cacheVersion
        SourceFileCount=if($sourceTree){$sourceTree.FileCount}else{$null};CacheFileCount=if($cacheTree){$cacheTree.FileCount}else{$null}
        SourceTreeSha256=if($sourceTree){$sourceTree.Sha256}else{$null};CacheTreeSha256=if($cacheTree){$cacheTree.Sha256}else{$null}
    })
}

$catalogResults = New-Object System.Collections.Generic.List[object]
$catalogPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
if ($RequireCatalog -and @($CatalogManifestPath).Count -eq 0) { Add-FailedGate -Gate 'CatalogEvidenceRequired' -Subject '<catalog>' -Message 'At least one catalog manifest is required.' }
foreach ($manifestInput in @($CatalogManifestPath)) {
    $manifestPath = Get-CanonicalPath -Path $manifestInput -BasePath (Get-Location).Path
    $subject = if ($manifestPath) { $manifestPath } else { '<catalog>' }
    if (-not $manifestPath -or -not $catalogPaths.Add($manifestPath)) {
        Add-FailedGate -Gate 'CatalogManifestPathUnique' -Subject $subject -Message 'Catalog manifest path is empty or duplicated.'
        continue
    }
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        Add-FailedGate -Gate 'CatalogManifestExists' -Subject $subject -Message 'Catalog manifest is missing.'
        continue
    }
    try { $manifest = Read-JsonFile -Path $manifestPath }
    catch { Add-FailedGate -Gate 'CatalogManifestValid' -Subject $subject -Message 'Catalog manifest is invalid JSON.'; continue }
    $schemaVersion = [string](Get-PropertyValue -InputObject $manifest -Name 'schemaVersion')
    $generatedAtText = [string](Get-PropertyValue -InputObject $manifest -Name 'generatedAtUtc')
    $model = [string](Get-PropertyValue -InputObject $manifest -Name 'model')
    $contextWindowText = [string](Get-PropertyValue -InputObject $manifest -Name 'contextWindow')
    $codexVersion = [string](Get-PropertyValue -InputObject $manifest -Name 'codexVersion')
    if ($schemaVersion -cne '1.1') { Add-FailedGate -Gate 'CatalogSchemaVersion' -Subject $subject -Message 'Catalog schema version is unknown.' }
    $generatedAt = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse($generatedAtText,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$generatedAt)) {
        Add-FailedGate -Gate 'CatalogGeneratedAtValid' -Subject $subject -Message 'Catalog generation time is invalid.'
    } else {
        $age = $ReferenceTimeUtc.ToUniversalTime() - $generatedAt.ToUniversalTime()
        if ($age.TotalSeconds -lt 0 -or $age.TotalHours -gt $MaximumCatalogAgeHours) { Add-FailedGate -Gate 'CatalogFreshness' -Subject $subject -Message 'Catalog evidence is stale or from the future.' }
    }
    $contextWindow = [int64]0
    if ([string]::IsNullOrWhiteSpace($model) -or -not [int64]::TryParse($contextWindowText,[ref]$contextWindow) -or $contextWindow -le 0) { Add-FailedGate -Gate 'CatalogModelIdentity' -Subject $subject -Message 'Catalog model or context identity is invalid.' }
    if ([string]::IsNullOrWhiteSpace($codexVersion)) { Add-FailedGate -Gate 'CatalogCodexIdentity' -Subject $subject -Message 'Catalog Codex version is missing.' }
    $manifestDirectory = Split-Path -Parent $manifestPath
    $artifactPath = Get-CanonicalPath -Path ([string](Get-PropertyValue -InputObject $manifest -Name 'catalogPath')) -BasePath $manifestDirectory
    $codexPath = Get-CanonicalPath -Path ([string](Get-PropertyValue -InputObject $manifest -Name 'codexPath')) -BasePath $manifestDirectory
    foreach ($artifact in @([pscustomobject]@{Kind='Artifact';Path=$artifactPath;Expected=[string](Get-PropertyValue -InputObject $manifest -Name 'catalogSha256')},[pscustomobject]@{Kind='Codex';Path=$codexPath;Expected=[string](Get-PropertyValue -InputObject $manifest -Name 'codexSha256')})) {
        if (-not $artifact.Path -or -not (Test-Path -LiteralPath $artifact.Path -PathType Leaf)) {
            Add-FailedGate -Gate ('Catalog{0}Exists' -f $artifact.Kind) -Subject $subject -Message "$($artifact.Kind) evidence file is missing."
        } elseif ($artifact.Expected -notmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash -LiteralPath $artifact.Path -Algorithm SHA256).Hash -ine $artifact.Expected) {
            Add-FailedGate -Gate ('Catalog{0}Hash' -f $artifact.Kind) -Subject $subject -Message "$($artifact.Kind) evidence hash does not match."
        }
    }
    if ($artifactPath -and (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
        try {
            $catalog = Read-JsonFile -Path $artifactPath
            $models = @(Get-PropertyValue -InputObject $catalog -Name 'models')
            if (@($models | Where-Object { [string](Get-PropertyValue -InputObject $_ -Name 'slug') -ceq $model }).Count -ne 1) { Add-FailedGate -Gate 'CatalogModelEntry' -Subject $subject -Message 'Catalog does not contain exactly one matching model entry.' }
        } catch { Add-FailedGate -Gate 'CatalogArtifactValid' -Subject $subject -Message 'Catalog artifact is invalid JSON.' }
    }
    $catalogResults.Add([pscustomobject][ordered]@{ManifestPath=$manifestPath;SchemaVersion=$schemaVersion;GeneratedAtUtc=$generatedAtText;Model=$model;ContextWindow=$contextWindow;CatalogPath=$artifactPath;CodexPath=$codexPath})
}

$result = [pscustomobject][ordered]@{
    SchemaVersion='1.0';Passed=($failedGates.Count -eq 0);ExpectedVersion=$ExpectedVersion
    ReferenceTimeUtc=$ReferenceTimeUtc.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)
    MaximumCatalogAgeHours=$MaximumCatalogAgeHours;WritePerformed=$false
    FailedGates=@($failedGates.ToArray());Diagnostics=@($diagnostics.ToArray())
    Distributions=@($distributionResults.ToArray());Catalogs=@($catalogResults.ToArray())
}
if (-not $result.Passed -and -not $NoThrow) { throw "PowerShell Workbench health validation failed: $($result.FailedGates -join ', ')" }
$result
