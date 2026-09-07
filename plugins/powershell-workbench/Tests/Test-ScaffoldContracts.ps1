[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$pluginRoot=Split-Path -Parent $PSScriptRoot
$generator=Join-Path $pluginRoot 'scripts\New-PowerShellArtifact.ps1'
$tempRoot=Join-Path ([IO.Path]::GetTempPath()) ('powershell-workbench-scaffold-'+[guid]::NewGuid().ToString('N'))
try{
    New-Item -ItemType Directory -Path $tempRoot|Out-Null
    foreach($projectProfile in @('RecoveryToolkit','WingetDownloader')){
        $item=& $generator -Kind PesterContract -Name 'Fixture' -Destination $tempRoot -Profile $projectProfile -ProjectRoot $tempRoot -Confirm:$false
        if($item.Name -ne 'Test-Fixture.Contract.ps1'){throw "Profile $projectProfile generated a non-discoverable test name: $($item.Name)"}
        Remove-Item -LiteralPath $item.FullName -Force
    }
    'PowerShell Workbench scaffold contracts passed.'
}finally{if(Test-Path -LiteralPath $tempRoot){Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue}}
