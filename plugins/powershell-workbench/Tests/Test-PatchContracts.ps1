[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$pluginRoot = Split-Path -Parent $PSScriptRoot
$validator = Join-Path $pluginRoot 'scripts\Test-PowerShellWorkbenchPatch.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('powershell-workbench-patch-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-FailedGatesExactly {
    param($Result, [string[]]$Expected, [string]$Message)
    $actual = @($Result.FailedGates)
    Assert-True ($actual.Count -eq $Expected.Count) "$Message Expected $($Expected.Count) failed gates but received $($actual.Count): $($actual -join ', ')."
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        Assert-True ($actual[$index] -eq $Expected[$index]) "$Message Expected failed gate '$($Expected[$index])' at index $index but received '$($actual[$index])'."
    }
}

try {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($validator, [ref]$tokens, [ref]$errors)
    Assert-True (@($errors).Count -eq 0) 'Patch validator has parser errors.'
    $forbidden = @('apply_patch', 'applypatch', 'Invoke-Expression', 'Start-Process', 'Invoke-RestMethod', 'Invoke-WebRequest', 'Set-Clipboard', 'git', 'gh')
    $commands = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
    foreach ($command in $forbidden) {
        Assert-True ($commands -notcontains $command) "Patch validator contains forbidden execution or transport command '$command'."
    }
    $validatorSource = Get-Content -LiteralPath $validator -Raw
    Assert-True ($validatorSource -notmatch 'ReadAllBytes') 'Patch validator regressed to an unbounded, separately reopened file read.'
    Assert-True ($validatorSource -match 'Read-BoundedPatchFile' -and $validatorSource -match 'PatchStableDuringRead') 'Patch validator does not expose its bounded stable-read contract.'

    $validPatch = @'
*** Begin Patch
*** Update File: scripts/example.ps1
@@
-Write-Output 'old'
+Write-Output 'new'
*** End Patch
'@.TrimEnd("`r", "`n")
    $safeTransport = @{ InvocationMode = 'DirectArgument'; HostAdapter = 'DedicatedTool' }

    $unknownTransport = & $validator -PatchText $validPatch
    Assert-FailedGatesExactly -Result $unknownTransport -Expected @('InvocationModeKnown', 'HostAdapterKnown') -Message 'Missing transport metadata did not fail closed.'

    $direct = & $validator -PatchText $validPatch @safeTransport
    Assert-True $direct.Eligible 'Valid direct-argument patch was rejected.'
    Assert-FailedGatesExactly -Result $direct -Expected @() -Message 'Valid direct-argument patch failed unexpectedly.'
    Assert-True ($direct.DetectedEncoding -eq 'Utf8NoBomReencodedText' -and $direct.EncodingEvidence -eq 'ReencodedText' -and $direct.OperationCount -eq 1) 'Valid patch metadata was not preserved.'
    Assert-True ($direct.TargetPaths.Count -eq 1 -and $direct.TargetPaths[0] -eq 'scripts/example.ps1') 'Valid patch target was not preserved.'
    Assert-True (-not $direct.ExecutionOccurred -and -not $direct.TransportPerformed -and -not $direct.TargetMutation) 'Patch validator violated its read-only contract.'
    Assert-True ($direct.PatchSha256 -match '^[0-9a-f]{64}$') 'Patch validator did not bind the payload to SHA-256.'

    foreach ($mode in @('Pipeline', 'StandardInput', 'ShellText')) {
        $rejectedMode = & $validator -PatchText $validPatch -InvocationMode $mode -HostAdapter DedicatedTool
        Assert-True (-not $rejectedMode.Eligible) "Invocation mode '$mode' did not fail closed."
        Assert-FailedGatesExactly -Result $rejectedMode -Expected @('InvocationModeDirectArgument') -Message "Invocation mode '$mode' propagated the wrong failed gate."
    }

    $batchWrapperResult = & $validator -PatchText $validPatch -InvocationMode DirectArgument -HostAdapter WindowsBatchWrapper
    Assert-True (-not $batchWrapperResult.Eligible) 'Windows batch wrapper did not fail closed.'
    Assert-FailedGatesExactly -Result $batchWrapperResult -Expected @('HostAdapterMultilineArgumentSafe') -Message 'Windows batch wrapper propagated the wrong failed gate.'

    $nativeResult = & $validator -PatchText $validPatch -InvocationMode DirectArgument -HostAdapter NativeExecutable
    Assert-True $nativeResult.Eligible 'Native executable direct-argument adapter was rejected.'
    Assert-FailedGatesExactly -Result $nativeResult -Expected @() -Message 'Native executable direct-argument adapter failed unexpectedly.'

    $missingEnvelope = $validPatch -replace '\*\*\* End Patch$', '*** End Patched'
    $envelopeResult = & $validator -PatchText $missingEnvelope @safeTransport
    Assert-FailedGatesExactly -Result $envelopeResult -Expected @('PatchEnvelope') -Message 'Malformed patch envelope propagated the wrong failed gate.'

    $noOperation = "*** Begin Patch`n`n*** End Patch"
    $noOperationResult = & $validator -PatchText $noOperation @safeTransport
    Assert-FailedGatesExactly -Result $noOperationResult -Expected @('PatchHasOperation') -Message 'Operation-free patch propagated the wrong failed gate.'

    $duplicateTarget = @'
*** Begin Patch
*** Update File: scripts/example.ps1
@@
-one
+two
*** Delete File: scripts/example.ps1
*** End Patch
'@.TrimEnd("`r", "`n")
    $duplicateResult = & $validator -PatchText $duplicateTarget @safeTransport
    Assert-FailedGatesExactly -Result $duplicateResult -Expected @('PatchSingleOperationPerTarget') -Message 'Duplicate patch target propagated the wrong failed gate.'

    $aliasedDuplicateTarget = @'
*** Begin Patch
*** Update File: scripts\example.ps1
@@
-one
+two
*** Delete File: scripts/./EXAMPLE.ps1
*** End Patch
'@.TrimEnd("`r", "`n")
    $aliasedDuplicateResult = & $validator -PatchText $aliasedDuplicateTarget @safeTransport
    Assert-FailedGatesExactly -Result $aliasedDuplicateResult -Expected @('PatchSingleOperationPerTarget') -Message 'Aliased Windows patch target did not fail closed.'

    $escapingTarget = @'
*** Begin Patch
*** Update File: ../outside.ps1
@@
-one
+two
*** End Patch
'@.TrimEnd("`r", "`n")
    $escapingTargetResult = & $validator -PatchText $escapingTarget @safeTransport
    Assert-FailedGatesExactly -Result $escapingTargetResult -Expected @('PatchTargetPathCanonical') -Message 'Escaping target path propagated the wrong failed gate.'

    $validPath = Join-Path $tempRoot 'valid.patch'
    [IO.File]::WriteAllText($validPath, $validPatch, (New-Object Text.UTF8Encoding($false)))
    $beforeHash = (Get-FileHash -LiteralPath $validPath -Algorithm SHA256).Hash
    $beforeFiles = @((Get-ChildItem -LiteralPath $tempRoot -File | Sort-Object Name).Name)
    $pathResult = & $validator -PatchPath $validPath @safeTransport
    $afterHash = (Get-FileHash -LiteralPath $validPath -Algorithm SHA256).Hash
    $afterFiles = @((Get-ChildItem -LiteralPath $tempRoot -File | Sort-Object Name).Name)
    Assert-True $pathResult.Eligible 'Valid UTF-8 no-BOM patch file was rejected.'
    Assert-True ($beforeHash -eq $afterHash) 'Patch validator modified the input patch file.'
    Assert-True (($beforeFiles -join '|') -eq ($afterFiles -join '|')) 'Patch validator created a file while validating a patch path.'

    $utf8BomPath = Join-Path $tempRoot 'utf8-bom.patch'
    [IO.File]::WriteAllText($utf8BomPath, $validPatch, (New-Object Text.UTF8Encoding($true)))
    $utf8BomResult = & $validator -PatchPath $utf8BomPath @safeTransport
    Assert-FailedGatesExactly -Result $utf8BomResult -Expected @('PatchEncodingUtf8NoBom') -Message 'UTF-8 BOM propagated the wrong failed gate.'

    $utf16Path = Join-Path $tempRoot 'utf16.patch'
    [IO.File]::WriteAllText($utf16Path, $validPatch, [Text.Encoding]::Unicode)
    $utf16Result = & $validator -PatchPath $utf16Path @safeTransport
    Assert-FailedGatesExactly -Result $utf16Result -Expected @('PatchEncodingUtf8NoBom') -Message 'UTF-16 propagated the wrong failed gate.'

    $missingPathResult = & $validator -PatchPath (Join-Path $tempRoot 'missing.patch') @safeTransport
    Assert-FailedGatesExactly -Result $missingPathResult -Expected @('PatchFileExists') -Message 'Missing patch file propagated the wrong failed gate.'

    $oversizedTextResult = & $validator -PatchText $validPatch -MaximumBytes 8 @safeTransport
    Assert-FailedGatesExactly -Result $oversizedTextResult -Expected @('PatchWithinByteLimit') -Message 'Oversized text patch propagated the wrong failed gate.'
    Assert-True ($null -eq $oversizedTextResult.PatchSha256) 'Oversized text patch was hashed after failing its byte limit.'

    $oversizedPath = Join-Path $tempRoot 'oversized.patch'
    [IO.File]::WriteAllBytes($oversizedPath, (New-Object byte[] 9))
    $oversizedPathResult = & $validator -PatchPath $oversizedPath -MaximumBytes 8 @safeTransport
    Assert-FailedGatesExactly -Result $oversizedPathResult -Expected @('PatchWithinByteLimit') -Message 'Oversized patch file propagated the wrong failed gate.'
    Assert-True ($null -eq $oversizedPathResult.PatchSha256 -and $oversizedPathResult.ByteLength -eq 9) 'Oversized patch file was read or lost its observed length.'

    'PowerShell Workbench patch contracts passed.'
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
