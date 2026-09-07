[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)][string]$SourcePath,
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$ProjectRoot,
    [string[]]$FunctionName = @(),
    [string[]]$RegionName = @(),
    [Alias('Write')][switch]$WriteOutput,
    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-Sha256Text {
    param([AllowEmptyString()][string]$Text)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($Text)
        ([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally { $algorithm.Dispose() }
}

function Get-RelativePath {
    param([string]$Root,[string]$Path)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    $pathFull = [IO.Path]::GetFullPath($Path)
    $separator = [IO.Path]::DirectorySeparatorChar
    if (-not ($pathFull.Equals($rootFull,[StringComparison]::OrdinalIgnoreCase) -or $pathFull.StartsWith($rootFull + $separator,[StringComparison]::OrdinalIgnoreCase))) {
        throw 'SourcePath must be contained by ProjectRoot.'
    }
    $pathFull.Substring($rootFull.Length).TrimStart('\','/').Replace('\','/')
}

function Add-Gate {
    param([Collections.Generic.List[string]]$List,[string]$Gate)
    if (-not $List.Contains($Gate)) { [void]$List.Add($Gate) }
}

$resolvedSource = [IO.Path]::GetFullPath($SourcePath)
if (-not (Test-Path -LiteralPath $resolvedSource -PathType Leaf)) { throw 'SourcePath must be an existing file.' }
if (-not $ProjectRoot) { $ProjectRoot = Split-Path -Parent $resolvedSource }
$resolvedRoot = [IO.Path]::GetFullPath($ProjectRoot)
$sourceRelative = Get-RelativePath -Root $resolvedRoot -Path $resolvedSource
$sourceText = [IO.File]::ReadAllText($resolvedSource)
$sourceSha256 = (Get-FileHash -LiteralPath $resolvedSource -Algorithm SHA256).Hash.ToLowerInvariant()

$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($sourceText,[ref]$tokens,[ref]$parseErrors)
$failedGates = New-Object 'System.Collections.Generic.List[string]'
if (@($parseErrors).Count -gt 0) { Add-Gate -List $failedGates -Gate 'SourceParses' }
if (@($FunctionName).Count -eq 0 -and @($RegionName).Count -eq 0) { Add-Gate -List $failedGates -Gate 'SelectorRequired' }

$fragments = New-Object System.Collections.Generic.List[object]
$functionAsts = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))
foreach ($name in @($FunctionName)) {
    if ([string]::IsNullOrWhiteSpace($name)) { Add-Gate -List $failedGates -Gate 'SelectorNamePresent'; continue }
    $functionMatches = @($functionAsts | Where-Object { $_.Name -ieq $name })
    if ($functionMatches.Count -ne 1) { Add-Gate -List $failedGates -Gate 'FunctionSelectorUnique'; continue }
    $text = $functionMatches[0].Extent.Text.TrimEnd()
    [void]$fragments.Add([pscustomobject][ordered]@{
        kind = 'Function'
        name = $functionMatches[0].Name
        startLine = $functionMatches[0].Extent.StartLineNumber
        endLine = $functionMatches[0].Extent.EndLineNumber
        sha256 = Get-Sha256Text -Text $text
        text = $text
    })
}

$lines = [Text.RegularExpressions.Regex]::Split($sourceText, '\r?\n')
for ($index = 0; $index -lt $lines.Count; $index++) {
    if ($lines[$index] -match '^\s*#region\s+(.+?)\s*$') {
        $region = $Matches[1]
        if (@($RegionName | Where-Object { $_ -ieq $region }).Count -eq 0) { continue }
        $end = $null
        for ($scan = $index + 1; $scan -lt $lines.Count; $scan++) {
            if ($lines[$scan] -match '^\s*#endregion\b') { $end = $scan; break }
        }
        if ($null -eq $end) { Add-Gate -List $failedGates -Gate 'RegionHasEnd'; continue }
        $bodyLines = @()
        if ($end -gt ($index + 1)) { $bodyLines = @($lines[($index + 1)..($end - 1)]) }
        $text = ($bodyLines -join "`n").Trim()
        [void]$fragments.Add([pscustomobject][ordered]@{
            kind = 'Region'
            name = $region
            startLine = $index + 2
            endLine = $end
            sha256 = Get-Sha256Text -Text $text
            text = $text
        })
    }
}
foreach ($name in @($RegionName)) {
    if ([string]::IsNullOrWhiteSpace($name)) { Add-Gate -List $failedGates -Gate 'SelectorNamePresent'; continue }
    if (@($fragments.ToArray() | Where-Object { $_.kind -eq 'Region' -and $_.name -ieq $name }).Count -ne 1) { Add-Gate -List $failedGates -Gate 'RegionSelectorUnique' }
}
if ($fragments.Count -eq 0) { Add-Gate -List $failedGates -Gate 'FragmentSelected' }
$fragmentArray = @($fragments.ToArray())
$failedGateArray = @($failedGates.ToArray())

$artifact = [pscustomobject][ordered]@{
    schemaVersion = '1.0'
    artifactKind = 'PowerShellWorkbenchFragmentTemplate'
    source = [pscustomobject][ordered]@{ projectRoot = $resolvedRoot; relativePath = $sourceRelative; sha256 = $sourceSha256 }
    fragments = $fragmentArray
    failedGates = $failedGateArray
}
$json = $artifact | ConvertTo-Json -Depth 12
$resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
$state = if ($failedGates.Count -eq 0) { if ($WriteOutput) { 'READY_TO_WRITE' } else { 'PREVIEW' } } else { 'BLOCKED' }
if ($WriteOutput -and $failedGates.Count -eq 0) {
    if ((Test-Path -LiteralPath $resolvedOutput) -and -not $Force) { throw 'OutputPath already exists. Use -Force to replace it.' }
    if ($PSCmdlet.ShouldProcess($resolvedOutput, 'Write PowerShell fragment template')) {
        $parent = Split-Path -Parent $resolvedOutput
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        [IO.File]::WriteAllText($resolvedOutput, $json, (New-Object Text.UTF8Encoding($false)))
        $state = 'SUCCEEDED'
    }
}
$templateSha256 = Get-Sha256Text -Text $json
if ($state -eq 'SUCCEEDED') { $templateSha256 = (Get-FileHash -LiteralPath $resolvedOutput -Algorithm SHA256).Hash.ToLowerInvariant() }
[pscustomobject][ordered]@{
    schemaVersion = '1.0'
    state = $state
    outputPath = $resolvedOutput
    sourcePath = $resolvedSource
    sourceSha256 = $sourceSha256
    fragmentCount = $fragments.Count
    failedGates = $failedGateArray
    writePerformed = ($state -eq 'SUCCEEDED')
    templateSha256 = $templateSha256
}
