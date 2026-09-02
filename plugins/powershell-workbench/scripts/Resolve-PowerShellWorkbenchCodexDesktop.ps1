[CmdletBinding()]
param(
    [string]$DesktopBinRoot = (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'),
    [ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedSha256,
    [switch]$AsJson
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if(-not (Test-Path -LiteralPath $DesktopBinRoot -PathType Container)){throw "Codex Desktop bin root was not found: $DesktopBinRoot"}
$candidates=foreach($candidate in Get-ChildItem -LiteralPath $DesktopBinRoot -Filter 'codex.exe' -File -Recurse){
    $versionOutput=(& $candidate.FullName --version 2>$null) -join "`n"
    if($LASTEXITCODE -ne 0 -or $versionOutput -notmatch '^codex-cli\s+(?<version>\d+\.\d+\.\d+)$'){continue}
    [pscustomobject]@{Path=$candidate.FullName;Version=[version]$Matches.version;Sha256=(Get-FileHash -LiteralPath $candidate.FullName -Algorithm SHA256).Hash.ToLowerInvariant();LastWriteTimeUtc=$candidate.LastWriteTimeUtc}
}
if(-not $candidates){throw "No versioned Codex Desktop binary was found below '$DesktopBinRoot'."}
$selected=$candidates|Sort-Object Version,LastWriteTimeUtc,Path -Descending|Select-Object -First 1
if($ExpectedSha256 -and $selected.Sha256 -ne $ExpectedSha256.ToLowerInvariant()){throw "Codex Desktop SHA256 does not match ExpectedSha256: $($selected.Path)"}
$result=[pscustomobject]@{Path=$selected.Path;Version=$selected.Version.ToString();Sha256=$selected.Sha256;Source='codex-desktop'}
if($AsJson){$result|ConvertTo-Json -Depth 4}else{$result}
