[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$pluginRoot=Split-Path -Parent $PSScriptRoot;$runner=Join-Path $pluginRoot 'scripts\Invoke-PowerShellWorkbenchNativeCommand.ps1';$tempRoot=Join-Path ([IO.Path]::GetTempPath()) ('powershell-workbench-native-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $tempRoot|Out-Null
try{
    $analyze=& $runner -FilePath $env:ComSpec -ArgumentList @('/d','/c','echo should-not-run') -WorkingDirectory $tempRoot -ReportDirectory $tempRoot -StepId 'analyze' -AnalyzeOnly
    if(-not $analyze.AnalyzeOnly -or $analyze.TargetMutation -or $analyze.MutationIntent -ne 'None' -or $analyze.ExecutionOccurred -or $analyze.Succeeded -or $analyze.VerificationState -ne 'NotRun' -or $analyze.VerificationScope -ne 'None' -or -not(Test-Path -LiteralPath $analyze.ReportPath)){throw 'Analyze-only contract failed.'}

    $unverified=& $runner -FilePath $env:ComSpec -ArgumentList @('/d','/c','echo execution-only') -WorkingDirectory $tempRoot -ReportDirectory $tempRoot -StepId 'execution-only' -MutationIntent 'Possible'
    if(-not $unverified.Succeeded -or $unverified.Verified -or $unverified.VerificationState -ne 'NotRun' -or $unverified.VerificationScope -ne 'None'){throw 'Execution-only success must not be reported as verified.'}

    $run=& $runner -FilePath $env:ComSpec -ArgumentList @('/d','/c','echo operator-visible') -WorkingDirectory $tempRoot -ReportDirectory $tempRoot -StepId 'success' -MutationIntent 'Expected' -VerificationScope ProcessLaunch -RequireVerification -Verify {param($result)$result.ExitCode -eq 0}
    if($run.MutationIntent -ne 'Expected' -or -not $run.ExecutionOccurred -or $null -ne $run.TargetMutation){throw 'Native command mutation contract was not preserved.'}
    if($run.SchemaVersion -ne '2.0' -or $run.ExitCode -ne 0 -or -not $run.Succeeded -or -not $run.Verified -or $run.VerificationState -ne 'Passed' -or $run.VerificationScope -ne 'ProcessLaunch' -or -not $run.VerificationRequired -or -not $run.ReportsWritten){throw 'Native command success contract failed.'}

    $accepted=& $runner -FilePath $env:ComSpec -ArgumentList @('/d','/c','echo accepted-nonzero & exit /b 7') -WorkingDirectory $tempRoot -ReportDirectory $tempRoot -StepId 'accepted-nonzero' -SuccessExitCodes @(0,7)
    if(-not $accepted.Succeeded -or $accepted.ExitCode -ne 7 -or $accepted.VerificationState -ne 'NotRun'){throw 'Accepted exit-code contract failed.'}

    $verificationFailure=& $runner -FilePath $env:ComSpec -ArgumentList @('/d','/c','echo verification-failure') -WorkingDirectory $tempRoot -ReportDirectory $tempRoot -StepId 'verification-failure' -VerificationScope ArtifactIntegrity -Verify {$false} -NoThrow
    if(-not $verificationFailure.Succeeded -or $verificationFailure.Verified -or $verificationFailure.VerificationState -ne 'Failed' -or $verificationFailure.ExecutionError){throw 'Verification failure was not kept separate from execution success.'}

    $verificationError=& $runner -FilePath $env:ComSpec -ArgumentList @('/d','/c','echo verification-error') -WorkingDirectory $tempRoot -ReportDirectory $tempRoot -StepId 'verification-error' -VerificationScope InstalledState -Verify {throw 'synthetic post-check error'} -NoThrow
    if(-not $verificationError.Succeeded -or $verificationError.ExecutionError -or $verificationError.VerificationState -ne 'Failed' -or $verificationError.VerificationError -ne 'synthetic post-check error'){throw 'Verification exception was not isolated from execution evidence.'}

    $executionFailure=& $runner -FilePath $env:ComSpec -ArgumentList @('/d','/c','echo native-error 1>&2 & exit /b 9') -WorkingDirectory $tempRoot -ReportDirectory $tempRoot -StepId 'execution-failure' -NoThrow
    if($executionFailure.Succeeded -or $executionFailure.ExitCode -ne 9 -or $executionFailure.ExecutionError -or $executionFailure.VerificationState -ne 'NotRun'){throw 'Native execution failure contract failed.'}
    if(-not((Get-Content -LiteralPath $executionFailure.TimelinePath -Raw) -match 'OUTPUT native-error')){throw 'Native stderr was not retained in the execution timeline.'}

    $missingVerifierSentinel=Join-Path $tempRoot 'missing-verifier-ran.txt';$missingVerifierRejected=$false
    try{& $runner -FilePath $env:ComSpec -ArgumentList @('/d','/c',"echo unexpected>$missingVerifierSentinel") -WorkingDirectory $tempRoot -ReportDirectory $tempRoot -StepId 'missing-verifier' -RequireVerification|Out-Null}catch{$missingVerifierRejected=$true}
    if(-not $missingVerifierRejected -or (Test-Path -LiteralPath $missingVerifierSentinel)){throw 'RequireVerification must fail closed before process execution when Verify is missing.'}

    $report=Get-Content -LiteralPath $run.ReportPath -Raw|ConvertFrom-Json
    if($report.Succeeded -ne $true -or $report.VerificationState -ne 'Passed' -or $report.VerificationScope -ne 'ProcessLaunch'){throw 'Persisted native command report did not preserve result semantics.'}
    $global:LASTEXITCODE=0
    'PowerShell Workbench native command contracts passed.'
}finally{Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue}
