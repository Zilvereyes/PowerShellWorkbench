[CmdletBinding(DefaultParameterSetName = 'Text')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Text')]
    [AllowEmptyString()]
    [string]$PatchText,

    [Parameter(Mandatory = $true, ParameterSetName = 'Path')]
    [string]$PatchPath,

    [ValidateSet('Unknown', 'DirectArgument', 'Pipeline', 'StandardInput', 'ShellText')]
    [string]$InvocationMode = 'Unknown',

    [ValidateSet('Unknown', 'DedicatedTool', 'NativeExecutable', 'WindowsBatchWrapper')]
    [string]$HostAdapter = 'Unknown',

    [ValidateRange(1, 67108864)]
    [long]$MaximumBytes = 4194304
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$failedGates = New-Object System.Collections.Generic.List[string]
$resolvedPatchPath = $null
$sourceKind = $PSCmdlet.ParameterSetName
$detectedEncoding = $null
$bytes = $null
$text = $null
$sha256 = $null
$targetPaths = @()
$targetIdentities = @()
$byteLength = 0
$encodingEvidence = $null

function ConvertTo-PatchTargetIdentity {
    param([string]$Path)

    $segments = @($Path.Trim().Replace('\', '/').Split('/'))
    $stack = New-Object System.Collections.Generic.List[string]
    foreach ($segment in $segments) {
        if (-not $segment -or $segment -eq '.') { continue }
        if ($segment -eq '..') {
            if ($stack.Count -eq 0) { return $null }
            $stack.RemoveAt($stack.Count - 1)
            continue
        }
        $stack.Add($segment)
    }
    if ($stack.Count -eq 0) { return $null }
    return (($stack -join '/').ToLowerInvariant())
}

if ($sourceKind -eq 'Path') {
    try {
        $resolvedPatchPath = [IO.Path]::GetFullPath($PatchPath)
    } catch {
        $failedGates.Add('PatchFileExists')
    }

    if ($resolvedPatchPath -and (Test-Path -LiteralPath $resolvedPatchPath -PathType Leaf)) {
        try {
            $fileInfo = Get-Item -LiteralPath $resolvedPatchPath
            $byteLength = $fileInfo.Length
            if ($byteLength -gt $MaximumBytes) {
                $failedGates.Add('PatchWithinByteLimit')
            } else {
                $bytes = [IO.File]::ReadAllBytes($resolvedPatchPath)
            }
        } catch {
            $failedGates.Add('PatchReadable')
        }
    } elseif (-not $failedGates.Contains('PatchFileExists')) {
        $failedGates.Add('PatchFileExists')
    }
} else {
    $text = $PatchText
    $textEncoder = New-Object Text.UTF8Encoding($false, $true)
    $byteLength = $textEncoder.GetByteCount($text)
    $detectedEncoding = 'Utf8NoBomReencodedText'
    $encodingEvidence = 'ReencodedText'
    if ($byteLength -gt $MaximumBytes) {
        $failedGates.Add('PatchWithinByteLimit')
    } else {
        $bytes = $textEncoder.GetBytes($text)
    }
}

if ($null -ne $bytes) {
    $hasUtf8Bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $hasUtf16LeBom = $bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE
    $hasUtf16BeBom = $bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF
    $hasUtf32LeBom = $bytes.Length -ge 4 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE -and $bytes[2] -eq 0x00 -and $bytes[3] -eq 0x00
    $hasUtf32BeBom = $bytes.Length -ge 4 -and $bytes[0] -eq 0x00 -and $bytes[1] -eq 0x00 -and $bytes[2] -eq 0xFE -and $bytes[3] -eq 0xFF

    if ($sourceKind -eq 'Path') {
        if ($hasUtf32LeBom) { $detectedEncoding = 'Utf32LittleEndianBom' }
        elseif ($hasUtf32BeBom) { $detectedEncoding = 'Utf32BigEndianBom' }
        elseif ($hasUtf8Bom) { $detectedEncoding = 'Utf8Bom' }
        elseif ($hasUtf16LeBom) { $detectedEncoding = 'Utf16LittleEndianBom' }
        elseif ($hasUtf16BeBom) { $detectedEncoding = 'Utf16BigEndianBom' }
        else {
            try {
                $text = (New-Object Text.UTF8Encoding($false, $true)).GetString($bytes)
                $detectedEncoding = 'Utf8NoBom'
                $encodingEvidence = 'SourceBytes'
            } catch {
                $detectedEncoding = 'UnknownOrInvalidUtf8'
            }
        }

        if ($detectedEncoding -ne 'Utf8NoBom') {
            $failedGates.Add('PatchEncodingUtf8NoBom')
        }
    }

    if ($detectedEncoding -eq 'Utf8NoBom' -or $detectedEncoding -eq 'Utf8NoBomReencodedText') {
        if ($null -eq $text) {
            $text = (New-Object Text.UTF8Encoding($false, $true)).GetString($bytes)
        }

        if ([Array]::IndexOf($bytes, [byte]0) -ge 0) {
            $failedGates.Add('PatchNoNulBytes')
        }

        $envelopePattern = '\A\*\*\* Begin Patch\r?\n(?s:.*?)\r?\n\*\*\* End Patch(?:\r?\n)?\z'
        if (-not [regex]::IsMatch($text, $envelopePattern)) {
            $failedGates.Add('PatchEnvelope')
        }

        $operationMatches = [regex]::Matches($text, '(?m)^\*\*\* (?:Add|Update|Delete) File: (?<path>.+?)\r?$')
        if ($operationMatches.Count -eq 0) {
            $failedGates.Add('PatchHasOperation')
        } else {
            $targetCounts = @{}
            foreach ($operationMatch in $operationMatches) {
                $targetPath = $operationMatch.Groups['path'].Value.Trim()
                $targetPaths += $targetPath
                $targetIdentity = ConvertTo-PatchTargetIdentity -Path $targetPath
                if (-not $targetIdentity) {
                    if (-not $failedGates.Contains('PatchTargetPathCanonical')) { $failedGates.Add('PatchTargetPathCanonical') }
                    continue
                }
                $targetIdentities += $targetIdentity
                if ($targetCounts.ContainsKey($targetIdentity)) { $targetCounts[$targetIdentity]++ }
                else { $targetCounts[$targetIdentity] = 1 }
            }
            if (@($targetCounts.GetEnumerator() | Where-Object { $_.Value -gt 1 }).Count -gt 0) {
                $failedGates.Add('PatchSingleOperationPerTarget')
            }
        }
    }

    $hashAlgorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $sha256 = ([BitConverter]::ToString($hashAlgorithm.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $hashAlgorithm.Dispose()
    }
}

if ($InvocationMode -eq 'Unknown') {
    $failedGates.Add('InvocationModeKnown')
} elseif ($InvocationMode -ne 'DirectArgument') {
    $failedGates.Add('InvocationModeDirectArgument')
}

if ($HostAdapter -eq 'Unknown') {
    $failedGates.Add('HostAdapterKnown')
} elseif ($HostAdapter -eq 'WindowsBatchWrapper') {
    $failedGates.Add('HostAdapterMultilineArgumentSafe')
}

[pscustomobject][ordered]@{
    SchemaVersion = '1.0'
    SourceKind = $sourceKind
    PatchPath = $resolvedPatchPath
    InvocationMode = $InvocationMode
    HostAdapter = $HostAdapter
    Eligible = ($failedGates.Count -eq 0)
    FailedGates = @($failedGates)
    DetectedEncoding = $detectedEncoding
    EncodingEvidence = $encodingEvidence
    ByteLength = $byteLength
    MaximumBytes = $MaximumBytes
    PatchSha256 = $sha256
    OperationCount = $targetPaths.Count
    TargetPaths = @($targetPaths)
    TargetIdentities = @($targetIdentities)
    ExecutionOccurred = $false
    TransportPerformed = $false
    TargetMutation = $false
    Recommendation = 'Submit the complete validated patch through a dedicated tool or native executable as one direct argument; do not use a Windows batch wrapper, pipeline, stdin, or shell evaluation.'
}
