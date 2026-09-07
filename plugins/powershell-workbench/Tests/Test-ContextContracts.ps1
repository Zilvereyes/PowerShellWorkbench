[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$pluginRoot=Split-Path -Parent $PSScriptRoot;$resolver=Join-Path $pluginRoot 'scripts\Resolve-PowerShellWorkbenchContext.ps1';$guard=Join-Path $pluginRoot 'scripts\Test-PowerShellWorkbenchAutomaticVariables.ps1';$tempRoot=Join-Path ([IO.Path]::GetTempPath()) ('powershell-workbench-context-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $tempRoot|Out-Null
try{
    $servicingScript=Join-Path $tempRoot 'Build-Media.ps1';Set-Content -LiteralPath $servicingScript -Value 'dism.exe /Mount-Image /ImageFile:install.wim`noscdimg.exe -bboot.stl output.iso' -Encoding UTF8
    $context=& $resolver -Path $tempRoot
    if($context.Profile -ne 'WindowsServicingToolkit'){throw 'Servicing capabilities did not select WindowsServicingToolkit.'}
    if('DISM' -notin $context.NativeTools -or 'Mount' -notin $context.RiskSurfaces){throw 'Servicing inventory is incomplete.'}
    $boundaryRoot=Join-Path $tempRoot 'BoundaryProject';$sourceRoot=Join-Path $boundaryRoot 'Source';New-Item -ItemType Directory -Path (Join-Path $boundaryRoot '.git'),$sourceRoot -Force|Out-Null
    Set-Content -LiteralPath (Join-Path $sourceRoot 'Build-Media.ps1') -Value 'dism.exe /Mount-Image /ImageFile:install.wim' -Encoding UTF8
    $boundaryContext=& $resolver -Path $sourceRoot
    if($boundaryContext.ProjectRoot -ne $boundaryRoot -or $boundaryContext.ProjectRootEvidence -ne 'RepositoryBoundary:.git' -or $boundaryContext.Profile -ne 'WindowsServicingToolkit' -or $boundaryContext.ProfileEvidence -ne 'Capability:WindowsServicingToolkit'){throw 'Explicit repository boundary did not retain its project root while classifying servicing capabilities.'}
    $requestedContext=& $resolver -Path $sourceRoot -RequestedProfile RecoveryToolkit
    if($requestedContext.ProjectRoot -ne $boundaryRoot -or $requestedContext.Profile -ne 'RecoveryToolkit' -or $requestedContext.ProfileEvidence -ne 'RequestedProfile:RecoveryToolkit'){throw 'An explicit requested profile did not take precedence over boundary capability heuristics.'}
    $unrelatedRoot=Join-Path $tempRoot 'UnrelatedServicingParent';$nestedRoot=Join-Path $unrelatedRoot 'NestedScriptOnlyProject';New-Item -ItemType Directory -Path $nestedRoot -Force|Out-Null
    Set-Content -LiteralPath (Join-Path $unrelatedRoot 'Build-Media.ps1') -Value 'dism.exe /Mount-Image /ImageFile:install.wim' -Encoding UTF8
    $nestedContext=& $resolver -Path $nestedRoot
    if($nestedContext.ProjectRoot -ne $nestedRoot -or $nestedContext.Profile -ne 'Generic' -or $nestedContext.Source -ne 'StartPath'){throw 'Default context resolution scanned an unrelated ancestor or failed to retain the start path.'}
    $ancestorContext=& $resolver -Path $nestedRoot -AllowAncestorHeuristics
    if($ancestorContext.ProjectRoot -ne $unrelatedRoot -or $ancestorContext.Profile -ne 'WindowsServicingToolkit' -or $ancestorContext.Source -ne 'Ancestor'){throw 'Opt-in ancestor heuristics did not remain available for deliberate wider classification.'}
    if(@($context.DetectedPowerShellRuntimes | Where-Object { $_.Architecture -eq 'Unknown' }).Count -gt 0){throw 'Runtime inventory did not probe executable architecture.'}
    $skippedRuntimeContext=& $resolver -Path $tempRoot -SkipRuntimeProbe
    if($skippedRuntimeContext.RuntimeProbeState -ne 'SKIPPED' -or @($skippedRuntimeContext.DetectedPowerShellRuntimes).Count -ne 0){throw 'SkipRuntimeProbe did not preserve an explicit no-probe state.'}
    $collision=Join-Path $tempRoot 'collision.ps1';Set-Content -LiteralPath $collision -Value '$home = "unsafe"' -Encoding UTF8
    $result=& $guard -Path $collision -NoThrow
    if($result.Passed -or $result.Diagnostics[0].Line -ne 1 -or $result.Diagnostics[0].SuggestedReplacement -ne '$homeEntry' -or $result.Diagnostics[0].Message -ne 'Assignment to protected automatic variable ''$home''. Use ''$homeEntry'' instead.'){throw 'Automatic-variable guard did not produce the expected diagnostic.'}
    $clean=Join-Path $tempRoot 'clean.ps1';Set-Content -LiteralPath $clean -Value '$homeEntry = "safe"' -Encoding UTF8
    if(-not((& $guard -Path $clean -NoThrow).Passed)){throw 'Automatic-variable guard rejected a safe variable.'}
    'PowerShell Workbench context contracts passed.'
}finally{Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue}
