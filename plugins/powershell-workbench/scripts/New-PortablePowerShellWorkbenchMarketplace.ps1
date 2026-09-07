[CmdletBinding(SupportsShouldProcess = $true)]
param([Parameter(Mandatory)][string]$Destination,[switch]$Force)

Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$pluginRoot=[IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd('\','/')
$destinationRoot=[IO.Path]::GetFullPath($Destination).TrimEnd('\','/')
$pluginDestination=[IO.Path]::GetFullPath((Join-Path $destinationRoot 'plugins\powershell-workbench')).TrimEnd('\','/')
$marketplacePath=[IO.Path]::GetFullPath((Join-Path $destinationRoot '.agents\plugins\marketplace.json'))
$separator=[IO.Path]::DirectorySeparatorChar
$utf8=New-Object Text.UTF8Encoding($false)
function Test-PathChain{param([string]$Path)$current=[IO.Path]::GetFullPath($Path);while($current){if(Test-Path -LiteralPath $current){if((Get-Item -LiteralPath $current -Force).Attributes-band[IO.FileAttributes]::ReparsePoint){return $false}};$parent=Split-Path -Parent $current;if(-not$parent-or$parent-ieq$current){break};$current=$parent};$true}

if($pluginDestination.Equals($pluginRoot,[StringComparison]::OrdinalIgnoreCase)-or$pluginDestination.StartsWith($pluginRoot+$separator,[StringComparison]::OrdinalIgnoreCase)-or$pluginRoot.StartsWith($pluginDestination+$separator,[StringComparison]::OrdinalIgnoreCase)){throw 'Plugin source and destination must be disjoint in both directions.'}
if(-not(Test-PathChain -Path $pluginRoot)-or-not(Test-PathChain -Path $destinationRoot)){throw 'Plugin source and destination path chains must not contain reparse points.'}
if(Test-Path -LiteralPath $destinationRoot -PathType Leaf){throw 'Marketplace destination root is a file.'}
$marketplaceParent=Split-Path -Parent $marketplacePath
if(Test-Path -LiteralPath $marketplaceParent -PathType Leaf){throw 'Marketplace metadata parent is a file.'}
$pluginExists=Test-Path -LiteralPath $pluginDestination -PathType Container
$marketplaceExists=Test-Path -LiteralPath $marketplacePath -PathType Leaf
if((Test-Path -LiteralPath $pluginDestination)-and-not$pluginExists){throw 'Portable plugin destination exists but is not a directory.'}
if((Test-Path -LiteralPath $marketplacePath)-and-not$marketplaceExists){throw 'Marketplace metadata target exists but is not a file.'}
$marketplaceName='powershell-workbench'
if($marketplaceExists){
    try{$existingMarketplace=Get-Content -LiteralPath $marketplacePath -Raw|ConvertFrom-Json}catch{throw 'Existing marketplace metadata is invalid JSON.'}
    $marketplaceName=[string]$existingMarketplace.name
    if($marketplaceName-notmatch'^[A-Za-z0-9][A-Za-z0-9._-]*$'){throw 'Existing marketplace name is missing or invalid.'}
}
$mode=if($pluginExists-or$marketplaceExists){'Upgrade'}else{'CleanInstall'}
$plan=[pscustomobject][ordered]@{SchemaVersion='1.0';State='PREVIEW';Mode=$mode;MarketplaceName=$marketplaceName;MarketplaceRoot=$destinationRoot;PluginPath=$pluginDestination;MarketplacePath=$marketplacePath;ExistingPlugin=$pluginExists;ExistingMarketplace=$marketplaceExists;WritePerformed=$false;RestorePerformed=$false;TransportPerformed=$false}
if(($pluginExists-or$marketplaceExists)-and-not$Force){
    if($WhatIfPreference){return $plan}
    throw 'Portable marketplace targets already exist; use -Force for a reversible upgrade.'
}
if(-not$PSCmdlet.ShouldProcess($destinationRoot,"Perform reversible portable marketplace $mode")){return $plan}

$marketplace=[ordered]@{name=$marketplaceName;interface=[ordered]@{displayName='PowerShell Workbench'};plugins=@([ordered]@{name='powershell-workbench';source=[ordered]@{source='local';path='./plugins/powershell-workbench'};policy=[ordered]@{installation='AVAILABLE';authentication='ON_INSTALL'};category='Productivity'})}
$null=New-Item -ItemType Directory -Path $destinationRoot -Force
$transactionRoot=Join-Path $destinationRoot ('.pwb-tx-'+[guid]::NewGuid().ToString('N').Substring(0,8))
$stagedPlugin=Join-Path $transactionRoot 'p';$stagedMarketplace=Join-Path $transactionRoot 'm.json';$backupPlugin=Join-Path $transactionRoot 'bp';$backupMarketplace=Join-Path $transactionRoot 'bm.json'
$newPluginPlaced=$false;$newMarketplacePlaced=$false;$restorePerformed=$false;$preserveTransaction=$false
try{
    $null=New-Item -ItemType Directory -Path $transactionRoot
    Copy-Item -LiteralPath $pluginRoot -Destination $stagedPlugin -Recurse
    $validator=Join-Path $stagedPlugin 'scripts\Test-PowerShellWorkbenchPlugin.ps1'
    if(-not(Test-Path -LiteralPath $validator -PathType Leaf)){throw 'Staged plugin validator is missing.'}
    &$validator -PluginRoot $stagedPlugin|Out-Null
    [IO.File]::WriteAllText($stagedMarketplace,($marketplace|ConvertTo-Json -Depth 8),$utf8)
    $stagedDocument=Get-Content -LiteralPath $stagedMarketplace -Raw|ConvertFrom-Json
    if([string]$stagedDocument.name-cne$marketplaceName-or@($stagedDocument.plugins).Count-ne 1){throw 'Staged marketplace validation failed.'}
    if($pluginExists){Move-Item -LiteralPath $pluginDestination -Destination $backupPlugin}
    if($marketplaceExists){Move-Item -LiteralPath $marketplacePath -Destination $backupMarketplace}
    $null=New-Item -ItemType Directory -Path (Split-Path -Parent $pluginDestination) -Force
    Move-Item -LiteralPath $stagedPlugin -Destination $pluginDestination;$newPluginPlaced=$true
    $null=New-Item -ItemType Directory -Path $marketplaceParent -Force
    Move-Item -LiteralPath $stagedMarketplace -Destination $marketplacePath;$newMarketplacePlaced=$true
}catch{
    $primaryError=$_
    try{
        if($newMarketplacePlaced-and(Test-Path -LiteralPath $marketplacePath -PathType Leaf)){Remove-Item -LiteralPath $marketplacePath -Force}
        if(Test-Path -LiteralPath $backupMarketplace -PathType Leaf){Move-Item -LiteralPath $backupMarketplace -Destination $marketplacePath;$restorePerformed=$true}
        if($newPluginPlaced-and(Test-Path -LiteralPath $pluginDestination -PathType Container)){Remove-Item -LiteralPath $pluginDestination -Recurse -Force}
        if(Test-Path -LiteralPath $backupPlugin -PathType Container){Move-Item -LiteralPath $backupPlugin -Destination $pluginDestination;$restorePerformed=$true}
    }catch{$preserveTransaction=$true;throw "Portable marketplace transaction failed and rollback also failed; retained recovery artifacts: $transactionRoot. Primary: $($primaryError.Exception.Message) Rollback: $($_.Exception.Message)"}
    throw $primaryError
}finally{if(-not$preserveTransaction-and(Test-Path -LiteralPath $transactionRoot -PathType Container)){Remove-Item -LiteralPath $transactionRoot -Recurse -Force}}

[pscustomobject][ordered]@{SchemaVersion='1.0';State='SUCCEEDED';Mode=$mode;MarketplaceName=$marketplaceName;MarketplaceRoot=$destinationRoot;PluginPath=$pluginDestination;MarketplacePath=$marketplacePath;ExistingPlugin=$pluginExists;ExistingMarketplace=$marketplaceExists;WritePerformed=$true;RestorePerformed=$restorePerformed;TransportPerformed=$false}
