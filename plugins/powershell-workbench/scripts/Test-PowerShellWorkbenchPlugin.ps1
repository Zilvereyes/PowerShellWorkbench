[CmdletBinding()]
param(
    [string]$PluginRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (-not $PluginRoot) { $PluginRoot = Split-Path -Parent $PSScriptRoot }

$failures = New-Object System.Collections.Generic.List[string]
$manifestPath = Join-Path $PluginRoot '.codex-plugin\plugin.json'
try {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.name -ne 'powershell-workbench') { $failures.Add('Unexpected plugin name.') }
    if (-not $manifest.version) { $failures.Add('Plugin version is missing.') }
    if (-not (Test-Path -LiteralPath (Join-Path $PluginRoot 'skills'))) { $failures.Add('Skills directory is missing.') }
} catch { $failures.Add("Invalid plugin manifest: $($_.Exception.Message)") }

Get-ChildItem -LiteralPath (Join-Path $PluginRoot 'skills') -Filter 'SKILL.md' -File -Recurse | ForEach-Object {
    $text = Get-Content -LiteralPath $_.FullName -Raw
    if ($text -notmatch '(?s)^---\s*\r?\nname:\s*[a-z0-9-]+\s*\r?\ndescription:\s*.+?\r?\n---') {
        $failures.Add("Invalid skill frontmatter: $($_.FullName)")
    }
}

@(Get-ChildItem -LiteralPath (Join-Path $PluginRoot 'scripts') -Filter '*.ps1' -File) +
@(Get-ChildItem -LiteralPath (Join-Path $PluginRoot 'Tests') -Filter '*.ps1' -File -Recurse -ErrorAction SilentlyContinue) | ForEach-Object {
    $tokens=$null; $errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$tokens,[ref]$errors)
    foreach($parseError in @($errors)) { $failures.Add("Parser error in $($_.Name): $($parseError.Message)") }
}

if ($failures.Count) { $failures | ForEach-Object { Write-Error $_ }; exit 1 }
Write-Output "PowerShell Workbench structural validation passed for $($manifest.version). Contract tests and optional quality gates are separate."
