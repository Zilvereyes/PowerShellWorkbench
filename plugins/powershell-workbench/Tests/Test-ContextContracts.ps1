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
    $collision=Join-Path $tempRoot 'collision.ps1';Set-Content -LiteralPath $collision -Value '$home = "unsafe"' -Encoding UTF8
    $result=& $guard -Path $collision -NoThrow
    if($result.Passed -or $result.Diagnostics[0].Line -ne 1 -or $result.Diagnostics[0].SuggestedReplacement -ne '$homeEntry'){throw 'Automatic-variable guard did not produce the expected diagnostic.'}
    $clean=Join-Path $tempRoot 'clean.ps1';Set-Content -LiteralPath $clean -Value '$homeEntry = "safe"' -Encoding UTF8
    if(-not((& $guard -Path $clean -NoThrow).Passed)){throw 'Automatic-variable guard rejected a safe variable.'}
    'PowerShell Workbench context contracts passed.'
}finally{Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue}
