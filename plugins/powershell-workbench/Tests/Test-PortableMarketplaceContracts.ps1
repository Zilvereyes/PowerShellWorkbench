[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$pluginRoot=Split-Path -Parent $PSScriptRoot
$packager=Join-Path $pluginRoot 'scripts\New-PortablePowerShellWorkbenchMarketplace.ps1'
$pluginValidator=Join-Path $pluginRoot 'scripts\Test-PowerShellWorkbenchPlugin.ps1'
$healthValidator=Join-Path $pluginRoot 'scripts\Test-PowerShellWorkbenchHealth.ps1'
$expectedVersion=[string]((Get-Content -LiteralPath (Join-Path $pluginRoot '.codex-plugin\plugin.json') -Raw|ConvertFrom-Json).version)
$tempRoot=Join-Path ([IO.Path]::GetTempPath()) ('powershell-workbench-portability-'+[guid]::NewGuid().ToString('N'))
function Assert-True{param([bool]$Condition,[string]$Message)if(-not$Condition){throw $Message}}
function Assert-Throw{param([scriptblock]$Action,[string]$Pattern,[string]$Message)$caught=$null;try{&$Action}catch{$caught=$_};if(-not$caught-or$caught.Exception.Message-notmatch$Pattern){throw $Message}}
function Get-Snapshot{param([string]$Root)if(-not(Test-Path -LiteralPath $Root)){return '<missing>'};@((Get-ChildItem -LiteralPath $Root -Recurse -Force|ForEach-Object{$length=if($_.PSIsContainer){0}else{$_.Length};$hash=if($_.PSIsContainer){''}else{(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash};"$($_.FullName)|$($_.PSIsContainer)|$length|$hash"}|Sort-Object))-join[Environment]::NewLine}

$tokens=$null;$errors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($packager,[ref]$tokens,[ref]$errors)
Assert-True -Condition ($errors.Count-eq 0) -Message 'Portable marketplace packager has parser errors.'
try{
    New-Item -ItemType Directory -Path $tempRoot|Out-Null
    $destination=Join-Path $tempRoot 'portable-marketplace'
    $preview=&$packager -Destination $destination -WhatIf
    Assert-True -Condition ($preview.State-eq'PREVIEW'-and$preview.Mode-eq'CleanInstall'-and-not$preview.WritePerformed-and-not$preview.TransportPerformed) -Message 'Clean-install preview contract failed.'
    Assert-True -Condition (-not(Test-Path -LiteralPath $destination)) -Message 'Preview created the destination.'
    $installed=&$packager -Destination $destination -Confirm:$false
    Assert-True -Condition ($installed.State-eq'SUCCEEDED'-and$installed.Mode-eq'CleanInstall'-and$installed.WritePerformed-and-not$installed.RestorePerformed-and-not$installed.TransportPerformed) -Message 'Clean-install result contract failed.'
    &$pluginValidator -PluginRoot $installed.PluginPath|Out-Null
    $installedGovernance=& (Join-Path $installed.PluginPath 'Tests\Test-GovernanceContracts.ps1')
    Assert-True -Condition ($installedGovernance -match 'skipped: repository governance context is unavailable') -Message 'Installed plugin governance contract did not explicitly skip unavailable repository context.'
    $marketplace=Get-Content -LiteralPath $installed.MarketplacePath -Raw|ConvertFrom-Json
    Assert-True -Condition ([string]$marketplace.name-ceq'powershell-workbench') -Message 'Clean install marketplace name changed.'
    Assert-True -Condition ([string]$marketplace.plugins[0].source.path-ceq'./plugins/powershell-workbench') -Message 'Marketplace source path is not portable.'
    $health=&$healthValidator -Distribution ([pscustomobject]@{Name='fixture';SourcePath=$pluginRoot;CachePath=$installed.PluginPath}) -ExpectedVersion $expectedVersion -NoThrow
    Assert-True -Condition ($health.Passed) -Message "Clean install tree identity failed: $($health.FailedGates-join', ')."
    $beforeExisting=Get-Snapshot -Root $destination
    $existingPreview=&$packager -Destination $destination -WhatIf
    Assert-True -Condition ($existingPreview.State-eq'PREVIEW'-and$existingPreview.Mode-eq'Upgrade'-and-not$existingPreview.WritePerformed) -Message 'Existing-target non-force preview contract failed.'
    Assert-True -Condition ((Get-Snapshot -Root $destination)-ceq$beforeExisting) -Message 'Existing-target non-force preview changed the destination.'
    Assert-Throw -Action {&$packager -Destination $destination -Confirm:$false} -Pattern 'use -Force' -Message 'Existing targets did not require -Force.'
    Assert-True -Condition ((Get-Snapshot -Root $destination)-ceq$beforeExisting) -Message 'Rejected non-force upgrade changed the destination.'
    $manifestPath=Join-Path $installed.PluginPath '.codex-plugin\plugin.json'
    $oldManifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json;$oldManifest.version='0.7.8';$oldManifest|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $manifestPath -Encoding UTF8
    $marketplace.name='personal';$marketplace|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $installed.MarketplacePath -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $installed.PluginPath 'legacy-marker.txt') -Value 'remove-on-upgrade' -Encoding UTF8
    $beforeUpgrade=Get-Snapshot -Root $destination
    $upgradePreview=&$packager -Destination $destination -Force -WhatIf
    Assert-True -Condition ($upgradePreview.State-eq'PREVIEW'-and$upgradePreview.Mode-eq'Upgrade'-and$upgradePreview.MarketplaceName-ceq'personal'-and$upgradePreview.ExistingPlugin-and$upgradePreview.ExistingMarketplace) -Message 'Upgrade preview contract failed.'
    Assert-True -Condition ((Get-Snapshot -Root $destination)-ceq$beforeUpgrade) -Message 'Upgrade preview changed the destination.'
    $lock=[IO.File]::Open($installed.MarketplacePath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
    try{Assert-Throw -Action {&$packager -Destination $destination -Force -Confirm:$false} -Pattern '.+' -Message 'Locked marketplace did not trigger rollback.'}finally{$lock.Dispose()}
    Assert-True -Condition ((Get-Snapshot -Root $destination)-ceq$beforeUpgrade) -Message 'Failed upgrade did not restore the exact destination snapshot.'
    Assert-True -Condition (@(Get-ChildItem -LiteralPath $destination -Filter '.pwb-tx-*' -Force).Count-eq 0) -Message 'Transaction residue remained after rollback.'
    $upgraded=&$packager -Destination $destination -Force -Confirm:$false
    Assert-True -Condition ($upgraded.State-eq'SUCCEEDED'-and$upgraded.Mode-eq'Upgrade'-and$upgraded.MarketplaceName-ceq'personal'-and-not$upgraded.RestorePerformed) -Message 'Upgrade result contract failed.'
    $upgradedMarketplace=Get-Content -LiteralPath $upgraded.MarketplacePath -Raw|ConvertFrom-Json
    Assert-True -Condition ([string]$upgradedMarketplace.name-ceq'personal') -Message 'Upgrade did not preserve the existing marketplace name.'
    Assert-True -Condition (-not(Test-Path -LiteralPath (Join-Path $upgraded.PluginPath 'legacy-marker.txt'))) -Message 'Upgrade retained an obsolete plugin file.'
    $health=&$healthValidator -Distribution ([pscustomobject]@{Name='fixture';SourcePath=$pluginRoot;CachePath=$upgraded.PluginPath}) -ExpectedVersion $expectedVersion -NoThrow
    Assert-True -Condition ($health.Passed) -Message "Upgrade tree identity failed: $($health.FailedGates-join', ')."
    Assert-True -Condition (@(Get-ChildItem -LiteralPath $destination -Filter '.pwb-tx-*' -Force).Count-eq 0) -Message 'Transaction residue remained after success.'
    $upgradedMarketplace.name='?';$upgradedMarketplace|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $upgraded.MarketplacePath -Encoding UTF8
    $invalidNameBefore=Get-Snapshot -Root $destination
    Assert-Throw -Action {&$packager -Destination $destination -Force -Confirm:$false} -Pattern 'name is missing or invalid' -Message 'Invalid existing marketplace name was accepted.'
    Assert-True -Condition ((Get-Snapshot -Root $destination)-ceq$invalidNameBefore) -Message 'Invalid marketplace-name preflight changed the destination.'
    Set-Content -LiteralPath $upgraded.MarketplacePath -Value '{invalid-json' -Encoding UTF8
    $invalidJsonBefore=Get-Snapshot -Root $destination
    Assert-Throw -Action {&$packager -Destination $destination -Force -Confirm:$false} -Pattern 'invalid JSON' -Message 'Invalid existing marketplace JSON was accepted.'
    Assert-True -Condition ((Get-Snapshot -Root $destination)-ceq$invalidJsonBefore) -Message 'Invalid marketplace-JSON preflight changed the destination.'
    $invalidDestination=Join-Path $tempRoot 'invalid-parent';New-Item -ItemType Directory -Path (Join-Path $invalidDestination '.agents') -Force|Out-Null;Set-Content -LiteralPath (Join-Path $invalidDestination '.agents\plugins') -Value 'blocking-file' -Encoding UTF8
    $invalidBefore=Get-Snapshot -Root $invalidDestination
    Assert-Throw -Action {&$packager -Destination $invalidDestination -Confirm:$false} -Pattern 'metadata parent is a file' -Message 'Invalid marketplace parent did not fail preflight.'
    Assert-True -Condition ((Get-Snapshot -Root $invalidDestination)-ceq$invalidBefore) -Message 'Failed preflight changed the destination.'
    Assert-Throw -Action {&$packager -Destination $pluginRoot -WhatIf} -Pattern 'disjoint' -Message 'Overlapping source and destination were accepted.'
}finally{if(Test-Path -LiteralPath $tempRoot){Remove-Item -LiteralPath $tempRoot -Recurse -Force}}
'PowerShell Workbench portable marketplace contracts passed.'
