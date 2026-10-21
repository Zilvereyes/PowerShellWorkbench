[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourcePath,
    [Parameter(Mandatory)][string]$ArchivePath,
    [Parameter(Mandatory)][string]$Purpose,
    [ValidateSet('fragment','function','script','module','assembly')][string]$Kind = 'fragment',
    [string]$ComponentId = ([guid]::NewGuid().ToString()),
    [object[]]$Dependencies = @(),
    [string]$PythonExecutable = 'python'
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$pythonCommand = Get-Command -Name $PythonExecutable -CommandType Application -ErrorAction Stop | Select-Object -First 1
$contractPath = [IO.Path]::GetTempFileName()
$dependencyPath = [IO.Path]::GetTempFileName()
try {
    $contract = [ordered]@{ inputs=@(); outputs=@(); bindings=@(); effects=@(); unresolved=@('Generated code requires explicit dependency and behavioral contract review'); reviewed=$false }
    [IO.File]::WriteAllText($contractPath, ($contract | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    $dependencyJson = ConvertTo-Json -InputObject @($Dependencies) -Depth 8
    [IO.File]::WriteAllText($dependencyPath, $dependencyJson, (New-Object Text.UTF8Encoding($false)))
    $worker = Join-Path $PSScriptRoot 'workbench_components.py'
    $registrationJson = & $pythonCommand.Source $worker register --archive $ArchivePath --source $SourcePath --language powershell --purpose $Purpose --kind $Kind --component-id $ComponentId --contract $contractPath --dependencies $dependencyPath
    if ($LASTEXITCODE -ne 0) { throw "Component registration failed; generated code is not cleared for execution: $SourcePath" }
    ($registrationJson -join "`n") | ConvertFrom-Json
} finally {
    Remove-Item -LiteralPath $contractPath,$dependencyPath -Force -ErrorAction SilentlyContinue
}
