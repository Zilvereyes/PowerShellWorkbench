[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('parse','search','register','gate')][string]$Action,
    [Parameter(Mandatory)][string[]]$ArgumentList,
    [string]$PythonExecutable = 'python'
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$pythonCommand = Get-Command -Name $PythonExecutable -CommandType Application -ErrorAction Stop | Select-Object -First 1
$worker = Join-Path $PSScriptRoot 'workbench_components.py'
# Argument arrays preserve boundaries; never invoke generated code or a shell string.
& $pythonCommand.Source $worker $Action @ArgumentList
if ($LASTEXITCODE -ne 0) { throw "Workbench component $Action failed with exit code $LASTEXITCODE." }
