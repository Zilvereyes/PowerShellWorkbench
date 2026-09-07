[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$ProjectRoot,
    [string]$ProfilePath,
    [string]$Destination,
    [ValidateSet('tree','git','ledger','manifest')][string]$SourceKind='tree',
    [ValidatePattern('^[a-fA-F0-9]{64}$')][string]$SourceIdentity,
    [switch]$Write,
    [switch]$NoWrite,
    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-Sha256Digest {
    param([byte[]]$Bytes)
    $sha=[Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function Get-TreeIdentity {
    param([string]$Root,[string]$ExcludePath)
    $reparsePoints=@(Get-ChildItem -LiteralPath $Root -Recurse -Force -Attributes ReparsePoint -ErrorAction Stop)
    if($reparsePoints.Count -gt 0){throw "Tree source identity is unavailable because the project contains reparse point(s): $($reparsePoints[0].FullName). Use an explicit source identity after reviewing the boundary."}
    $files=@(Get-ChildItem -LiteralPath $Root -Recurse -Force -File | Where-Object { -not $_.FullName.Equals($ExcludePath,[StringComparison]::OrdinalIgnoreCase) })
    $lines=@($files | ForEach-Object {
        $relative=$_.FullName.Substring($Root.TrimEnd('\\').Length).TrimStart('\\').Replace('\\','/')
        "$relative|$($_.Length)|$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant())"
    } | Sort-Object)
    Get-Sha256Digest ([Text.UTF8Encoding]::new($false).GetBytes(($lines -join "`n")))
}

if ($Write -and $NoWrite) { throw 'Write and NoWrite cannot be combined.' }
$resolvedRoot=(Resolve-Path -LiteralPath $ProjectRoot -ErrorAction Stop).Path
if (-not $ProfilePath) { $ProfilePath=Join-Path $resolvedRoot '.powershell-workbench\project-profile.json' }
$resolvedProfile=(Resolve-Path -LiteralPath $ProfilePath -ErrorAction Stop).Path
if (-not $Destination) { $Destination=Join-Path (Split-Path -Parent $resolvedProfile) 'project-assessment.json' }
$resolvedDestination=[IO.Path]::GetFullPath($Destination)
$mode=if ($Write -and -not $NoWrite) { 'WRITE' } else { 'PREVIEW' }
if ($mode -eq 'WRITE' -and (Test-Path -LiteralPath $resolvedDestination) -and -not $Force) { throw "Project assessment already exists: $resolvedDestination. Use -Force to replace it." }
$profileHash=(Get-FileHash -LiteralPath $resolvedProfile -Algorithm SHA256).Hash.ToLowerInvariant()
if ($SourceKind -eq 'tree') { $identity=Get-TreeIdentity -Root $resolvedRoot -ExcludePath $resolvedDestination }
else { if (-not $SourceIdentity) { throw "SourceIdentity is required for source kind '$SourceKind'." }; $identity=$SourceIdentity.ToLowerInvariant() }
$profileDocument=Get-Content -LiteralPath $resolvedProfile -Raw | ConvertFrom-Json
$targets=@($profileDocument.targets.windows | ForEach-Object { [ordered]@{ name=[string]$_; status='NOT_RUN'; applicability='UNKNOWN'; freshness='UNKNOWN'; proofs=[ordered]@{ safeOffline='UNKNOWN'; live='UNKNOWN'; postcondition='UNKNOWN' }; evidence=@() } })
$document=[ordered]@{
    schemaVersion='1.1'
    source=[ordered]@{ kind=$SourceKind; identity=[ordered]@{ algorithm='SHA256'; value=$identity } }
    profileSha256=$profileHash
    host=[ordered]@{ binding='UNBOUND'; sanitizationStatus='UNKNOWN' }
    nextAllowedAction='Review source identity, host binding, target applicability, proofs, and evidence before declaring any target ready.'
    targets=$targets
}
$result=[pscustomobject][ordered]@{ SchemaVersion='1.1'; Mode=$mode; AssessmentPath=$resolvedDestination; ProjectRoot=$resolvedRoot; ProfilePath=$resolvedProfile; ProfileSha256=$profileHash; SourceIdentity=$identity; AssessmentDocument=$document; WritePerformed=$false; NetworkPerformed=$false; ProcessPerformed=$false; TransportPerformed=$false }
if ($mode -eq 'PREVIEW') { return $result }
if ($PSCmdlet.ShouldProcess($resolvedDestination,'Write reviewed project assessment sidecar')) {
    $parent=Split-Path -Parent $resolvedDestination
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [IO.File]::WriteAllText($resolvedDestination,($document | ConvertTo-Json -Depth 12),(New-Object Text.UTF8Encoding($false)))
    $result.WritePerformed=$true
}
$result
