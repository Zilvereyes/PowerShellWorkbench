[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))

foreach ($requiredFile in @('LICENSE', 'SECURITY.md', 'CONTRIBUTING.md')) {
    if (-not (Test-Path -LiteralPath (Join-Path $repositoryRoot $requiredFile) -PathType Leaf)) {
        throw "Required governance file is missing: $requiredFile"
    }
}

$license = Get-Content -LiteralPath (Join-Path $repositoryRoot 'LICENSE') -Raw
$security = Get-Content -LiteralPath (Join-Path $repositoryRoot 'SECURITY.md') -Raw
$contributing = Get-Content -LiteralPath (Join-Path $repositoryRoot 'CONTRIBUTING.md') -Raw
if ($license -notmatch 'MIT License') { throw 'LICENSE does not declare MIT.' }
if ($security -notmatch 'Do not open a public issue') { throw 'SECURITY.md does not require private reporting.' }
if ($contributing -notmatch 'Windows PowerShell 5\.1 and PowerShell 7') { throw 'CONTRIBUTING.md does not preserve dual-host validation.' }
'PowerShell Workbench governance contracts passed.'
