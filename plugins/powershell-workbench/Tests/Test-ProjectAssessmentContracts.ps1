[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$pluginRoot=Split-Path -Parent $PSScriptRoot
$assessmentScript=Join-Path $pluginRoot 'scripts\Get-PowerShellWorkbenchProjectAssessment.ps1'
$portalScript=Join-Path $pluginRoot 'scripts\Show-PowerShellWorkbenchProjectPortal.ps1'
$tempRoot=Join-Path ([IO.Path]::GetTempPath()) ('powershell-workbench-assessment-'+[guid]::NewGuid().ToString('N'))
$profileDirectory=Join-Path $tempRoot '.powershell-workbench'; $profilePath=Join-Path $profileDirectory 'project-profile.json'; $assessmentPath=Join-Path $profileDirectory 'project-assessment.json'
try{
    New-Item -ItemType Directory -Path $profileDirectory -Force|Out-Null
    @{schemaVersion='1.0';project=@{name='Fixture';root='..'};components=@();targets=@{windows=@('Windows 10 Home','Windows 10 Pro','Windows 11')};paths=@{reports='Reports'}}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $profilePath -Encoding UTF8
    $missing=& $assessmentScript -ProfilePath $profilePath
    if($missing.IsConfigured -or $missing.IsValid -or $missing.FailedGates -notcontains 'AssessmentProfilePresent' -or $missing.WritePerformed -or $missing.NetworkPerformed -or $missing.ProcessPerformed -or $missing.TransportPerformed){throw 'Missing assessment was not reported as a non-executing fail-closed state.'}
    $evidencePath=Join-Path $profileDirectory 'evidence.json'; [IO.File]::WriteAllText($evidencePath,'{"result":"pass"}',(New-Object Text.UTF8Encoding($false)))
    $evidenceHash=(Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
    [ordered]@{schemaVersion='1.0';source=[ordered]@{commit='a3449c20f6b089259088cbf7f8712111989940d9'};host=[ordered]@{binding='fixture-host';sanitizationStatus='SANITIZED'};nextAllowedAction='Review the bounded report.';targets=@([ordered]@{name='Windows 10 Home';status='PASS';evidence=@([ordered]@{path='evidence.json';sha256=$evidenceHash})},[ordered]@{name='Windows 10 Pro';status='WAITING';evidence=@()},[ordered]@{name='Windows 11';status='NOT_RUN';evidence=@()})}|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $assessmentPath -Encoding UTF8
    $valid=& $assessmentScript -ProfilePath $profilePath -AssessmentPath $assessmentPath
    if(-not $valid.IsConfigured -or -not $valid.IsValid -or $valid.ReadinessStatus -ne 'WAITING' -or $valid.Targets.Count -ne 3 -or $valid.Targets[0].Evidence[0].State -ne 'VERIFIED' -or $valid.NextAllowedAction -ne 'Review the bounded report.'){throw 'Valid assessment did not preserve target, evidence, and next-action state.'}
    $json=& $assessmentScript -ProfilePath $profilePath -AssessmentPath $assessmentPath -AsJson|ConvertFrom-Json
    if(-not $json.IsValid -or $json.Targets[0].Status -ne 'PASS'){throw 'Assessment JSON did not preserve valid state.'}
    [IO.File]::WriteAllText($evidencePath,'{"result":"drift"}',(New-Object Text.UTF8Encoding($false)))
    $drifted=& $assessmentScript -ProfilePath $profilePath -AssessmentPath $assessmentPath
    if($drifted.IsValid -or $drifted.ReadinessStatus -ne 'BLOCKED' -or $drifted.Targets[0].FailedGates -notcontains 'EvidenceHash' -or $drifted.Targets[0].FailedGates -notcontains 'PassRequiresVerifiedEvidence'){throw 'Drifted PASS evidence did not fail with exact target gates.'}
    $portal=& $portalScript -ProfilePath $profilePath -AssessmentPath $assessmentPath
    if($portal.Assessment.Targets[0].Evidence[0].State -ne 'DRIFTED' -or $portal.WasUpdated){throw 'Portal did not expose assessment drift read-only.'}
}finally{Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue}
