[CmdletBinding()]
param(
    [switch]$AsJson
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$names = @('powershell', 'pwsh', 'git', 'gh', 'node', 'npm', 'codex', 'docker', 'winget')
$tools = foreach ($name in $names) {
    $command = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
    [pscustomobject]@{
        Name      = $name
        Available = [bool]$command
        Path      = if ($command) { $command.Source } else { $null }
        Kind      = if ($command) { $command.CommandType.ToString() } else { 'Missing' }
    }
}

$desktopCandidates = @()
$desktopBin = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
if (Test-Path -LiteralPath $desktopBin) {
    $desktopCandidates = @(Get-ChildItem -LiteralPath $desktopBin -Filter 'codex.exe' -File -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -ExpandProperty FullName)
}

$npmBin = Join-Path $env:APPDATA 'npm'
$processArchitecture = if ([Environment]::Is64BitProcess) { 'x64' } else { 'x86' }
$result = [pscustomobject]@{
    SchemaVersion          = '1.0'
    PowerShellEdition      = $PSVersionTable.PSEdition
    PowerShellVersion      = $PSVersionTable.PSVersion.ToString()
    ProcessArchitecture    = $processArchitecture
    PathEntries            = @($env:Path -split ';' | Where-Object { $_ })
    Tools                  = @($tools)
    NpmBin                 = $npmBin
    NpmBinOnPath           = @($env:Path -split ';') -contains $npmBin
    CodexDesktopCandidates = $desktopCandidates
    Guidance               = @(
        'A PATH entry does not install a missing executable.',
        'Prefer a supported standalone Codex CLI installation when Node and npm are absent.',
        'Do not add a version-specific Codex Desktop bin directory to persistent PATH.'
    )
}

if ($AsJson) { $result | ConvertTo-Json -Depth 8 } else { $result }
