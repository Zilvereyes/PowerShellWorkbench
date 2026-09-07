[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$pluginRoot=Split-Path -Parent $PSScriptRoot;$diagnostic=Join-Path $pluginRoot 'scripts\Get-PowerShellWorkbenchTextIntegrity.ps1';$tempRoot=Join-Path ([IO.Path]::GetTempPath()) ('powershell-workbench-text-integrity-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $tempRoot|Out-Null
function Assert-True{param([bool]$Condition,[string]$Message)if(-not $Condition){throw $Message}}
function Get-Snapshot{param([string]$Root)@((Get-ChildItem -LiteralPath $Root -Recurse -Force -File|ForEach-Object{"$($_.FullName)|$($_.Length)|$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)"})|Sort-Object)-join"`n"}
try{
    $lf=Join-Path $tempRoot 'lf.ps1';$crlf=Join-Path $tempRoot 'crlf.ps1';$bom=Join-Path $tempRoot 'bom.psm1';$invalid=Join-Path $tempRoot 'invalid.ps1';$ignored=Join-Path $tempRoot 'ignored.txt'
    [IO.File]::WriteAllText($lf,"function Test-Text {`n    'ok'`n}`n",(New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText($crlf,"function Test-Text {`r`n    'ok'`r`n}`r`n",(New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText($bom,"function Get-Bom {`r`n    'ok'`r`n}`r`n",(New-Object Text.UTF8Encoding($true)))
    [IO.File]::WriteAllBytes($invalid,[byte[]](0xff,0xfe,0xfd));Set-Content -LiteralPath $ignored -Value 'ignored' -Encoding UTF8
    $before=Get-Snapshot $tempRoot
    $lfResult=&$diagnostic -Path $lf -NoThrow
    Assert-True ($lfResult.Passed -and $lfResult.FileCount -eq 1 -and $lfResult.Files[0].Encoding -eq 'Utf8NoBom' -and $lfResult.Files[0].LineEndings.Style -eq 'LF') 'UTF-8 LF fixture was not classified correctly.'
    $crlfResult=&$diagnostic -Path $crlf -ExpectedNormalizedTextSha256 $lfResult.Files[0].NormalizedTextSha256 -NoThrow
    Assert-True ($crlfResult.Files[0].ComparisonState -eq 'BYTE_ONLY_DRIFT' -and $crlfResult.Files[0].LineEndings.Style -eq 'CRLF') 'CRLF byte-only drift was not distinguished from semantic drift.'
    $semantic=&$diagnostic -Path $crlf -ExpectedNormalizedTextSha256 ('0'*64) -NoThrow
    Assert-True ($semantic.Files[0].ComparisonState -eq 'SEMANTIC_DRIFT') 'Semantic drift was not reported.'
    $directory=&$diagnostic -Path $tempRoot -NoThrow
    Assert-True (-not $directory.Passed -and $directory.FileCount -eq 4 -and @($directory.Files.Path|Where-Object {$_ -eq 'ignored.txt'}).Count -eq 0) 'Directory extension filtering or fail-closed invalid-text handling failed.'
    Assert-True ((@($directory.Files|Where-Object {$_.Encoding -eq 'Utf8Bom'}).Count -eq 1)) 'UTF-8 BOM was not reported.'
    $bad=&$diagnostic -Path $invalid -NoThrow
    Assert-True (-not $bad.Passed -and @($bad.FailedGates) -eq 'TextSnapshotReadable' -and $bad.Files[0].ComparisonState -eq 'UNKNOWN') 'Invalid UTF-8 did not fail closed.'
    $json=&$diagnostic -Path $lf -AsJson -NoThrow|ConvertFrom-Json
    Assert-True ($json.SchemaVersion -eq '1.0' -and -not $json.WritePerformed -and -not $json.NetworkPerformed -and -not $json.TransportPerformed) 'JSON/no-execution contract failed.'
    Assert-True ((Get-Snapshot $tempRoot) -ceq $before) 'Read-only text diagnostic changed a fixture.'
    'PowerShell Workbench text integrity contracts passed.'
}finally{Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue}
