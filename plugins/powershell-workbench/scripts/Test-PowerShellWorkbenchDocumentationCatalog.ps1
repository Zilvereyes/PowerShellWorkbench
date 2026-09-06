[CmdletBinding()]
param(
    [string]$CatalogPath,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedCatalogSha256,
    [ValidateRange(1,3650)][int]$MaximumAgeDays = 90,
    [datetime]$ReferenceTimeUtc = [datetime]::UtcNow,
    [switch]$NoThrow
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (-not $CatalogPath) {
    $CatalogPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'assets\documentation-source-catalog.json'
}

$failedGates = New-Object System.Collections.Generic.List[string]
$diagnostics = New-Object System.Collections.Generic.List[object]
function Add-FailedGate {
    param([string]$Gate,[string]$Subject,[string]$Message)
    if (-not $failedGates.Contains($Gate)) { $failedGates.Add($Gate) }
    $diagnostics.Add([pscustomobject][ordered]@{ Gate=$Gate; Subject=$Subject; Message=$Message })
}
function Test-AllowedProperties {
    param([object]$Value,[string[]]$Allowed,[string[]]$Required,[string]$Gate,[string]$Subject)
    foreach ($property in $Value.PSObject.Properties) {
        if ($Allowed -notcontains $property.Name) {
            Add-FailedGate -Gate $Gate -Subject $Subject -Message "Unknown property '$($property.Name)'."
        }
    }
    foreach ($name in $Required) {
        if ($null -eq $Value.PSObject.Properties[$name]) {
            Add-FailedGate -Gate $Gate -Subject $Subject -Message "Missing required property '$name'."
        }
    }
}
function Get-PropertyValue {
    param([object]$Value,[string]$Name)
    $property = $Value.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    $property.Value
}

$resolvedPath = $CatalogPath
$catalog = $null
$actualHash = $null
if (-not [IO.Path]::IsPathRooted($CatalogPath)) {
    Add-FailedGate -Gate 'CatalogPathAbsolute' -Subject $CatalogPath -Message 'Documentation catalog path must be absolute.'
} else {
    $resolvedPath = [IO.Path]::GetFullPath($CatalogPath)
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        Add-FailedGate -Gate 'CatalogExists' -Subject $resolvedPath -Message 'Documentation catalog is missing.'
    } else {
        $actualHash = (Get-FileHash -LiteralPath $resolvedPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -cne $ExpectedCatalogSha256.ToLowerInvariant()) {
            Add-FailedGate -Gate 'CatalogHash' -Subject $resolvedPath -Message 'Documentation catalog SHA-256 does not match the independently supplied digest.'
        } else {
            try { $catalog = Get-Content -LiteralPath $resolvedPath -Raw | ConvertFrom-Json }
            catch { Add-FailedGate -Gate 'CatalogValidJson' -Subject $resolvedPath -Message 'Documentation catalog is invalid JSON.' }
        }
    }
}

if ($null -ne $catalog) {
    Test-AllowedProperties -Value $catalog -Allowed @('schemaVersion','catalogId','verifiedAtUtc','domains') -Required @('schemaVersion','catalogId','verifiedAtUtc','domains') -Gate 'CatalogShape' -Subject $resolvedPath
    $schemaVersion = Get-PropertyValue -Value $catalog -Name 'schemaVersion'
    $catalogId = Get-PropertyValue -Value $catalog -Name 'catalogId'
    $verifiedAtText = Get-PropertyValue -Value $catalog -Name 'verifiedAtUtc'
    $domains = @(Get-PropertyValue -Value $catalog -Name 'domains' | Where-Object { $null -ne $_ })
    if ([string]$schemaVersion -cne '1.0') { Add-FailedGate -Gate 'SchemaVersionKnown' -Subject $resolvedPath -Message 'Documentation catalog schema must be 1.0.' }
    if ([string]$catalogId -cne 'powershell-workbench-authoritative-documentation') { Add-FailedGate -Gate 'CatalogIdentity' -Subject $resolvedPath -Message 'Documentation catalog identity is unknown.' }
    $verifiedAt = [datetime]::MinValue
    if (-not [datetime]::TryParse([string]$verifiedAtText,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AdjustToUniversal,[ref]$verifiedAt)) {
        Add-FailedGate -Gate 'CatalogVerifiedAt' -Subject $resolvedPath -Message 'Catalog verification time is invalid.'
    } else {
        $age = $ReferenceTimeUtc.ToUniversalTime() - $verifiedAt.ToUniversalTime()
        if ($age.TotalSeconds -lt 0) { Add-FailedGate -Gate 'CatalogVerifiedAtFuture' -Subject $resolvedPath -Message 'Catalog verification time is in the future.' }
        if ($age.TotalDays -gt $MaximumAgeDays) { Add-FailedGate -Gate 'CatalogStale' -Subject $resolvedPath -Message 'Catalog verification is older than policy allows.' }
    }

    $requiredDomains = @('powershell','microsoft-dism','microsoft-update','ollama')
    $canonicalSkills = @{ powershell='powershell-docs'; 'microsoft-dism'='microsoft-dism-docs'; 'microsoft-update'='microsoft-update-docs'; ollama='ollama-docs' }
    $domainIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $sourceUrls = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($domain in $domains) {
        if ($null -eq $domain) { Add-FailedGate -Gate 'DomainShape' -Subject $resolvedPath -Message 'Domain entries cannot be null.'; continue }
        $domainSubject = [string](Get-PropertyValue -Value $domain -Name 'id')
        Test-AllowedProperties -Value $domain -Allowed @('id','skill','allowedHosts','sources') -Required @('id','skill','allowedHosts','sources') -Gate 'DomainShape' -Subject $domainSubject
        if ([string]::IsNullOrWhiteSpace($domainSubject) -or -not $domainIds.Add($domainSubject)) { Add-FailedGate -Gate 'DomainIdUnique' -Subject $domainSubject -Message 'Domain ids must be nonempty and unique.' }
        if ($requiredDomains -notcontains $domainSubject) { Add-FailedGate -Gate 'DomainKnown' -Subject $domainSubject -Message 'Documentation domain is not recognized.' }
        $skill = [string](Get-PropertyValue -Value $domain -Name 'skill')
        if (-not $canonicalSkills.ContainsKey($domainSubject) -or $skill -cne [string]$canonicalSkills[$domainSubject]) {
            Add-FailedGate -Gate 'DomainSkillBinding' -Subject $domainSubject -Message 'Domain is not bound to its canonical skill.'
        }
        $hosts = @(Get-PropertyValue -Value $domain -Name 'allowedHosts' | Where-Object { $null -ne $_ })
        if ($hosts.Count -eq 0 -or @($hosts | Where-Object { [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0) { Add-FailedGate -Gate 'AllowedHosts' -Subject $domainSubject -Message 'Each domain requires explicit authority hosts.' }
        $sources = @(Get-PropertyValue -Value $domain -Name 'sources' | Where-Object { $null -ne $_ })
        if ($sources.Count -eq 0) { Add-FailedGate -Gate 'DomainSources' -Subject $domainSubject -Message 'Each domain requires at least one source.' }
        $sourceIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        foreach ($source in $sources) {
            if ($null -eq $source) { Add-FailedGate -Gate 'SourceShape' -Subject $domainSubject -Message 'Source entries cannot be null.'; continue }
            $sourceId = [string](Get-PropertyValue -Value $source -Name 'id')
            $sourceUrl = [string](Get-PropertyValue -Value $source -Name 'url')
            $sourcePurpose = [string](Get-PropertyValue -Value $source -Name 'purpose')
            $sourceVersionScope = [string](Get-PropertyValue -Value $source -Name 'versionScope')
            $sourceSubject = "$domainSubject/$sourceId"
            Test-AllowedProperties -Value $source -Allowed @('id','url','purpose','versionScope') -Required @('id','url','purpose','versionScope') -Gate 'SourceShape' -Subject $sourceSubject
            if ([string]::IsNullOrWhiteSpace($sourceId) -or -not $sourceIds.Add($sourceId)) { Add-FailedGate -Gate 'SourceIdUnique' -Subject $sourceSubject -Message 'Source ids must be nonempty and unique within a domain.' }
            if ([string]::IsNullOrWhiteSpace($sourcePurpose) -or [string]::IsNullOrWhiteSpace($sourceVersionScope)) { Add-FailedGate -Gate 'SourceDescription' -Subject $sourceSubject -Message 'Every source needs purpose and version scope.' }
            $uri = $null
            if (-not [uri]::TryCreate($sourceUrl,[UriKind]::Absolute,[ref]$uri)) {
                Add-FailedGate -Gate 'SourceUrlAbsolute' -Subject $sourceSubject -Message 'Source URL must be absolute.'
            } elseif ($uri.Scheme -cne 'https' -or -not $uri.IsDefaultPort -or $uri.UserInfo -or $uri.Fragment) {
                Add-FailedGate -Gate 'SourceUrlSafe' -Subject $sourceSubject -Message 'Source URL must use HTTPS without user info, fragments, or custom ports.'
            } elseif ($hosts -cnotcontains $uri.DnsSafeHost) {
                Add-FailedGate -Gate 'SourceAuthorityHost' -Subject $sourceSubject -Message 'Source URL host is outside the domain authority allowlist.'
            }
            if (-not $sourceUrls.Add($sourceUrl)) { Add-FailedGate -Gate 'SourceUrlUnique' -Subject $sourceSubject -Message 'Source URLs must be globally unique.' }
        }
    }
    foreach ($required in $requiredDomains) {
        if (-not $domainIds.Contains($required)) { Add-FailedGate -Gate 'RequiredDomainPresent' -Subject $required -Message 'Required documentation domain is missing.' }
    }
}

$result = [pscustomobject][ordered]@{
    SchemaVersion = '1.0'
    CatalogPath = $resolvedPath
    CatalogSha256 = $actualHash
    ExpectedCatalogSha256 = $ExpectedCatalogSha256.ToLowerInvariant()
    MaximumAgeDays = $MaximumAgeDays
    ReferenceTimeUtc = $ReferenceTimeUtc.ToUniversalTime().ToString('o')
    Passed = ($failedGates.Count -eq 0)
    FailedGates = @($failedGates | ForEach-Object { $_ })
    Diagnostics = @($diagnostics | ForEach-Object { $_ })
    WritePerformed = $false
    ExecutionPerformed = $false
    NetworkPerformed = $false
    TransportPerformed = $false
}
if (-not $result.Passed -and -not $NoThrow) { throw "Documentation catalog validation failed: $($result.FailedGates -join ', ')." }
$result
