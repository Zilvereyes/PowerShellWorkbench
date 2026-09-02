[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$pluginRoot=Split-Path -Parent $PSScriptRoot;$runner=Join-Path $pluginRoot 'scripts\Invoke-PowerShellWorkbenchNativeCommand.ps1';$tempRoot=Join-Path ([IO.Path]::GetTempPath()) ('powershell-workbench-native-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $tempRoot|Out-Null
try{
    $analyze=& $runner -FilePath $env:ComSpec -ArgumentList @('/d','/c','echo should-not-run') -WorkingDirectory $tempRoot -ReportDirectory $tempRoot -StepId 'analyze' -AnalyzeOnly
    if(-not $analyze.AnalyzeOnly -or $analyze.TargetMutation -or -not(Test-Path -LiteralPath $analyze.ReportPath)){throw 'Analyze-only contract failed.'}
    $run=& $runner -FilePath $env:ComSpec -ArgumentList @('/d','/c','echo operator-visible') -WorkingDirectory $tempRoot -ReportDirectory $tempRoot -StepId 'success' -Verify {param($result)$result.ExitCode -eq 0}
    if($run.ExitCode -ne 0 -or -not $run.Verified -or -not $run.ReportsWritten){throw 'Native command success contract failed.'}
    'PowerShell Workbench native command contracts passed.'
}finally{Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue}
