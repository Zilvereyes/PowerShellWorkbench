[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$pluginRoot=Split-Path -Parent $PSScriptRoot;$doctor=Join-Path $pluginRoot 'scripts\Invoke-PowerShellWorkbenchDoctor.ps1';$newProfile=Join-Path $pluginRoot 'scripts\New-PowerShellWorkbenchProjectProfile.ps1';$tempRoot=Join-Path ([IO.Path]::GetTempPath()) ('powershell-workbench-doctor-'+[guid]::NewGuid().ToString('N'))
try{
    New-Item -ItemType Directory -Path $tempRoot|Out-Null;[IO.File]::WriteAllText((Join-Path $tempRoot 'fixture.ps1'),"function Get-Fixture {`n 'ok'`n}`n",(New-Object Text.UTF8Encoding($false)))
    $missing=& $doctor -ProjectRoot $tempRoot -Fast
    if($missing.State -ne 'READY' -or $missing.ProfileState -ne 'MISSING' -or $missing.Context.RuntimeProbeState -ne 'SKIPPED' -or $missing.NextSafeAction -notmatch 'New-PowerShellWorkbenchProjectProfile' -or $missing.WritePerformed -or $missing.NetworkPerformed -or $missing.ProcessPerformed -or $missing.TransportPerformed){throw 'Doctor did not return a non-executing missing-profile diagnosis with an explicit skipped runtime state.'}
    $profileResult=& $newProfile -ProjectRoot $tempRoot -Confirm:$false
    $waiting=& $doctor -ProjectRoot $tempRoot -ProfilePath $profileResult.ProfilePath -Fast -AllowedEncoding Utf8NoBom -AllowedLineEnding LF
    if($waiting.ProfileState -ne 'VALID' -or $waiting.State -ne 'WAITING' -or $waiting.Assessment.FailedGates -notcontains 'AssessmentProfilePresent' -or $waiting.TextIntegrity.FailedGates.Count -ne 0){throw 'Doctor did not compose valid profile, missing assessment, and text-policy evidence.'}
    $json=& $doctor -ProjectRoot $tempRoot -ProfilePath $profileResult.ProfilePath -Fast -AsJson|ConvertFrom-Json
    if($json.SchemaVersion -ne '1.0' -or $json.WritePerformed -or $json.TransportPerformed){throw 'Doctor JSON did not preserve no-execution guarantees.'}
    'PowerShell Workbench Doctor contracts passed.'
}finally{if(Test-Path -LiteralPath $tempRoot){Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue}}
