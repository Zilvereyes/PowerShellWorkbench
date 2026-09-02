[CmdletBinding(DefaultParameterSetName = 'Roots')]
param(
    [Parameter(ParameterSetName = 'Roots')]
    [string[]]$Root = @((Get-Location).Path),

    [Parameter(Mandatory, ParameterSetName = 'Registry')]
    [string]$RegistryPath,

    [ValidateRange(1, 8)]
    [int]$Depth = 3,

    [switch]$AsJson
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($PSCmdlet.ParameterSetName -eq 'Registry') {
    $registry = Get-Content -LiteralPath (Resolve-Path -LiteralPath $RegistryPath) -Raw | ConvertFrom-Json
    $Root = @(
        @($registry.projects | Where-Object { $_.path } | ForEach-Object path)
        @($registry.profiles | Where-Object { $_.scope } | ForEach-Object scope)
    ) | Where-Object { $_ -match '^(?:[A-Za-z]:\\|\\\\)' } | Select-Object -Unique
}

$excluded = @('.git', '.svn', 'node_modules', 'packages', 'bin', 'obj', 'TestResults', 'Reports', 'outputs', 'artifacts')
$items = foreach ($requestedRoot in ($Root | Select-Object -Unique)) {
    if (-not (Test-Path -LiteralPath $requestedRoot -PathType Container)) {
        [pscustomobject]@{ Root=$requestedRoot; Exists=$false; Technologies=@(); Signals=@(); Error='Directory not found' }
        continue
    }

    $resolved = (Resolve-Path -LiteralPath $requestedRoot).Path
    $files = @(Get-ChildItem -LiteralPath $resolved -File -Recurse -Depth $Depth -ErrorAction SilentlyContinue | Where-Object {
        $relative = $_.FullName.Substring($resolved.Length).TrimStart([char[]]'\\/')
        -not @($excluded | Where-Object { $relative -match ('(^|[\\/])' + [regex]::Escape($_) + '([\\/]|$)') }).Count
    })
    $technologies = New-Object System.Collections.Generic.List[string]
    if (@($files | Where-Object { $_.Extension -in @('.ps1','.psm1','.psd1') }).Count -gt 0) { $technologies.Add('PowerShell') }
    if (@($files | Where-Object { $_.Extension -eq '.py' -or $_.Name -in @('pyproject.toml','requirements.txt') }).Count) { $technologies.Add('Python') }
    if (@($files | Where-Object Name -eq 'package.json').Count) { $technologies.Add('Node') }
    if (@($files | Where-Object { $_.Extension -in @('.sln','.csproj','.fsproj') }).Count -gt 0) { $technologies.Add('.NET') }
    if (@($files | Where-Object { $_.Extension -in @('.c','.cpp','.h','.hpp') -or $_.Name -eq 'CMakeLists.txt' }).Count) { $technologies.Add('Native') }
    if (@($files | Where-Object { $_.Extension -in @('.html','.css','.js','.ts') }).Count -gt 0) { $technologies.Add('Web') }
    if (@($files | Where-Object { $_.Extension -in @('.lua','.toc') }).Count -gt 0) { $technologies.Add('Lua/WoWAddon') }
    if (@($files | Where-Object { $_.Extension -in @('.blp','.m2','.wmo','.adt','.wdt') -or $_.Name -match '^(CASC|wow\.export)' }).Count -gt 0) { $technologies.Add('GameData') }
    if (@($files | Where-Object { $_.Extension -in @('.json','.yaml','.yml','.toml','.xml') }).Count -gt 0) { $technologies.Add('DataFormats') }
    if (@($files | Where-Object Extension -eq '.md').Count -gt 0) { $technologies.Add('Documentation') }

    $signals = @($files | Where-Object { $_.Name -match '^(AGENTS\.md|README.*|package\.json|pyproject\.toml|requirements.*\.txt|CMakeLists\.txt|.*\.(sln|csproj|fsproj|psd1|psm1|toc|lua))$' } |
        Select-Object -First 100 | ForEach-Object { $_.FullName.Substring($resolved.Length).TrimStart([char[]]'\\/') })
    [pscustomobject]@{ Root=$resolved; Exists=$true; Technologies=@($technologies | Select-Object -Unique); Signals=$signals; FileCount=$files.Count; Error=$null }
}

if ($AsJson) { @($items) | ConvertTo-Json -Depth 8 } else { @($items) }
