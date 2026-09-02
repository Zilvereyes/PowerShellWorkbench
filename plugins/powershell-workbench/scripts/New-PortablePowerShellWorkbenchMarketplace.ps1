[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$Destination,

    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$pluginRoot = Split-Path -Parent $PSScriptRoot
$destinationRoot = [System.IO.Path]::GetFullPath($Destination)
$pluginDestination = Join-Path $destinationRoot 'plugins\powershell-workbench'
$marketplacePath = Join-Path $destinationRoot '.agents\plugins\marketplace.json'
$pluginRoot = [System.IO.Path]::GetFullPath($pluginRoot).TrimEnd([char[]]'\/')
$pluginDestination = [System.IO.Path]::GetFullPath($pluginDestination).TrimEnd([char[]]'\/')
$separator = [System.IO.Path]::DirectorySeparatorChar

if ($pluginDestination.Equals($pluginRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
    $pluginDestination.StartsWith($pluginRoot + $separator, [System.StringComparison]::OrdinalIgnoreCase) -or
    $pluginRoot.StartsWith($pluginDestination + $separator, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Plugin source and destination must be disjoint in both directions.'
}
if ((Test-Path -LiteralPath $pluginDestination) -and -not $Force) {
    throw "Portable plugin destination already exists: $pluginDestination"
}

$marketplace = [ordered]@{
    name = 'powershell-workbench'
    interface = [ordered]@{ displayName = 'PowerShell Workbench' }
    plugins = @(
        [ordered]@{
            name = 'powershell-workbench'
            source = [ordered]@{ source = 'local'; path = './plugins/powershell-workbench' }
            policy = [ordered]@{ installation = 'AVAILABLE'; authentication = 'ON_INSTALL' }
            category = 'Productivity'
        }
    )
}

if ($PSCmdlet.ShouldProcess($destinationRoot, 'Create portable PowerShell Workbench marketplace')) {
    $pluginParent = Split-Path -Parent $pluginDestination
    $null = New-Item -ItemType Directory -Path $pluginParent -Force
    $stagingPath = Join-Path $pluginParent ('.powershell-workbench-staging-' + [guid]::NewGuid().ToString('N'))
    Copy-Item -LiteralPath $pluginRoot -Destination $stagingPath -Recurse
    if (-not (Test-Path -LiteralPath (Join-Path $stagingPath '.codex-plugin\plugin.json') -PathType Leaf)) { throw 'Staged plugin validation failed.' }
    if (Test-Path -LiteralPath $pluginDestination) {
        $verifiedTarget = [System.IO.Path]::GetFullPath((Get-Item -LiteralPath $pluginDestination -Force).FullName).TrimEnd([char[]]'\/')
        if (-not $verifiedTarget.Equals($pluginDestination, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'Resolved replacement target changed before deletion.' }
        Remove-Item -LiteralPath $verifiedTarget -Recurse -Force
    }
    Move-Item -LiteralPath $stagingPath -Destination $pluginDestination
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $marketplacePath) -Force
    $marketplace | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $marketplacePath -Encoding UTF8
    [pscustomobject]@{ MarketplaceRoot = $destinationRoot; PluginPath = $pluginDestination; MarketplacePath = $marketplacePath }
}
