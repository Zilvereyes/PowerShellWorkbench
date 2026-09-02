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

if ($destinationRoot.StartsWith($pluginRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Destination must not be inside the plugin source directory.'
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
    if (Test-Path -LiteralPath $pluginDestination) { Remove-Item -LiteralPath $pluginDestination -Recurse -Force }
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $pluginDestination) -Force
    Copy-Item -LiteralPath $pluginRoot -Destination $pluginDestination -Recurse
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $marketplacePath) -Force
    $marketplace | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $marketplacePath -Encoding UTF8
    [pscustomobject]@{ MarketplaceRoot = $destinationRoot; PluginPath = $pluginDestination; MarketplacePath = $marketplacePath }
}
