[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$pluginRoot = Split-Path -Parent $PSScriptRoot
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('workbench-components-' + [guid]::NewGuid().ToString('N'))
try {
    $null = New-Item -ItemType Directory -Path $tempRoot
    $source = Join-Path $tempRoot 'fixture.ps1'
    [IO.File]::WriteAllText($source, 'function Get-Fixture { param($Value) $script:State = $Value; & $SelectedCommand }; throw "DO_NOT_EXECUTE"', (New-Object Text.UTF8Encoding($false)))
    $analyzer = Join-Path $pluginRoot 'scripts/Get-PowerShellWorkbenchCodeAnalysis.ps1'
    $analysis = (& $analyzer -Path $source) | ConvertFrom-Json
    if (-not $analysis.passed -or $analysis.sourceExecutionPerformed -or $analysis.dependencyAnalysisComplete) { throw 'AST scope/no-execution contract failed.' }
    if ($analysis.dynamicCommandCount -ne 1 -or @($analysis.functions).Count -ne 1) { throw 'AST function/dynamic-command inventory failed.' }
    if (@($analysis.variables | Where-Object { $_.name -eq 'script:State' }).Count -ne 1) { throw 'Script-scope variable was not inventoried.' }
    [IO.File]::WriteAllText($source, 'function {', (New-Object Text.UTF8Encoding($false)))
    $invalid = (& $analyzer -Path $source) | ConvertFrom-Json
    if ($invalid.passed -or @($invalid.errors).Count -eq 0) { throw 'Malformed PowerShell was not rejected.' }
    $generator = Join-Path $pluginRoot 'scripts/New-PowerShellArtifact.ps1'
    $item = & $generator -Kind AdvancedFunction -Name Get-Registered -Destination $tempRoot -Profile Generic -ProjectRoot $tempRoot -Confirm:$false
    if (-not $item.ComponentId -or $item.ComponentVersion -ne '1.0.0') { throw 'Generator did not return a component ID and version.' }
    $recordPath = Join-Path $item.ComponentArchive ($item.ComponentId + '/1.0.0/component.json')
    $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
    if ($record.contract.reviewed -or @($record.contract.unresolved).Count -eq 0) { throw 'Generated template was not registered as draft.' }
    if ($record.sha256 -cne (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()) { throw 'Registered snapshot hash differs from generated code.' }
    'PowerShell Workbench component pipeline contracts passed.'
} finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
