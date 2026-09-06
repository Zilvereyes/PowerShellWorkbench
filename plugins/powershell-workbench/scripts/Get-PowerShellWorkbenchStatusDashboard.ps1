[CmdletBinding()]
param(
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Distribution,
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')][string]$ExpectedVersion,
    [Parameter(Mandatory)][string]$ProvenancePath,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedProvenanceSha256,
    [Parameter(Mandatory)][string]$AllowedProvenanceRoot,
    [string[]]$CatalogManifestPath=@(),
    [ValidateRange(1,8760)][int]$MaximumCatalogAgeHours=24,
    [datetimeoffset]$ReferenceTimeUtc=[datetimeoffset]::UtcNow,
    [ValidateRange(1024,10485760)][long]$MaximumProvenanceBytes=1048576,
    [switch]$RequireCatalog,
    [switch]$NoThrow,
    [switch]$AsJson
)

Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$unknownGates=New-Object Collections.Generic.List[string]
$conflictGates=New-Object Collections.Generic.List[string]
$healthScript=Join-Path $PSScriptRoot 'Test-PowerShellWorkbenchHealth.ps1'
function Add-UnknownGate{param([string]$Gate)if(-not$unknownGates.Contains($Gate)){[void]$unknownGates.Add($Gate)}}
function Add-ConflictGate{param([string]$Gate)if(-not$conflictGates.Contains($Gate)){[void]$conflictGates.Add($Gate)}}
function Get-Value{param($Object,[string]$Name,$Default=$null)if($null-eq$Object){return $Default};$property=$Object.PSObject.Properties[$Name];if($null-eq$property){return $Default};$property.Value}
function Test-Shape{param($Object,[string[]]$Expected)if($null-eq$Object){return $false};$names=@($Object.PSObject.Properties.Name);@($names|Where-Object{$Expected-cnotcontains$_}).Count-eq 0-and@($Expected|Where-Object{$names-cnotcontains$_}).Count-eq 0}
function Get-NormalizedPath{param([string]$Path)if([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path) -or $Path -match '^[A-Za-z]:(?:$|[^\\/])' -or $Path -match '^[\\/](?![\\/])'){return $null};try{[IO.Path]::GetFullPath($Path).TrimEnd('\','/')}catch{return $null}}
function Test-PathChain{param([string]$Path,[string]$Root)$current=[IO.Path]::GetFullPath($Path);while($current){if(Test-Path -LiteralPath $current){if((Get-Item -LiteralPath $current).Attributes-band[IO.FileAttributes]::ReparsePoint){return $false}};if($current-ieq$Root){return $true};$parent=Split-Path -Parent $current;if(-not$parent-or$parent-ieq$current){break};$current=$parent.TrimEnd('\','/')};$false}
function Read-Snapshot{param([string]$LiteralPath,[long]$MaximumBytes)$resolved=(Resolve-Path -LiteralPath $LiteralPath).Path;$stream=[IO.File]::Open($resolved,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);try{$memory=[IO.MemoryStream]::new();try{$buffer=New-Object byte[] 8192;while(($count=$stream.Read($buffer,0,$buffer.Length))-gt 0){if($memory.Length-gt($MaximumBytes-$count)){throw 'Release provenance exceeds its byte limit.'};$memory.Write($buffer,0,$count)};$bytes=$memory.ToArray()}finally{$memory.Dispose()}}finally{$stream.Dispose()};$algorithm=[Security.Cryptography.SHA256]::Create();try{$sha=([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()}finally{$algorithm.Dispose()};$decoder=New-Object Text.UTF8Encoding($false,$true);[pscustomobject]@{Path=$resolved;Sha256=$sha;Text=$decoder.GetString($bytes)}}

$healthParameters=@{Distribution=$Distribution;ExpectedVersion=$ExpectedVersion;CatalogManifestPath=$CatalogManifestPath;MaximumCatalogAgeHours=$MaximumCatalogAgeHours;ReferenceTimeUtc=$ReferenceTimeUtc;NoThrow=$true}
if($RequireCatalog){$healthParameters.RequireCatalog=$true}
$health=&$healthScript @healthParameters
foreach($gate in @($health.FailedGates)){if($gate-match'Unique|Distinct|Identity|VersionExpected|TreeIdentity|Freshness|Hash|ModelEntry'){Add-ConflictGate $gate}else{Add-UnknownGate $gate}}

$root=Get-NormalizedPath -Path $AllowedProvenanceRoot
if(-not$root-or$root-ieq[IO.Path]::GetPathRoot($root)){Add-ConflictGate 'AllowedProvenanceRootScoped'}
elseif(-not(Test-Path -LiteralPath $root -PathType Container)){Add-UnknownGate 'AllowedProvenanceRootExists'}
elseif(-not(Test-PathChain -Path $root -Root $root)){Add-ConflictGate 'AllowedProvenanceRootReparseSafe'}
$provenanceNormalized=Get-NormalizedPath -Path $ProvenancePath
$provenance=$null;$snapshot=$null
if($root-and(-not$provenanceNormalized-or-not$provenanceNormalized.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)-or-not(Test-PathChain -Path $provenanceNormalized -Root $root))){Add-ConflictGate 'ReleaseProvenanceWithinRoot'}
elseif(-not(Test-Path -LiteralPath $ProvenancePath -PathType Leaf)){Add-UnknownGate 'ReleaseProvenancePresent'}
else{try{$snapshot=Read-Snapshot -LiteralPath $ProvenancePath -MaximumBytes $MaximumProvenanceBytes}catch{Add-UnknownGate 'ReleaseProvenanceReadable'};if($snapshot){if($snapshot.Sha256-ne$ExpectedProvenanceSha256.ToLowerInvariant()){Add-ConflictGate 'ReleaseProvenanceSha256'}else{try{$provenance=$snapshot.Text|ConvertFrom-Json}catch{Add-UnknownGate 'ReleaseProvenanceJson'}}}}
if($provenance){
    if(-not(Test-Shape $provenance @('schemaVersion','pluginName','pluginVersion','commitSha','sourceRef','sourceTreeSha256'))){Add-UnknownGate 'ReleaseProvenanceShape'}
    if([string](Get-Value $provenance 'schemaVersion')-cne'1.0'-or[string](Get-Value $provenance 'pluginName')-cne'powershell-workbench'){Add-UnknownGate 'ReleaseIdentity'}
    if([string](Get-Value $provenance 'pluginVersion')-cne$ExpectedVersion){Add-ConflictGate 'ReleaseVersion'}
    if([string](Get-Value $provenance 'commitSha')-notmatch'^[a-fA-F0-9]{40}$'){Add-UnknownGate 'ReleaseCommitSha'}
    if([string]::IsNullOrWhiteSpace([string](Get-Value $provenance 'sourceRef'))){Add-UnknownGate 'ReleaseSourceRef'}
    $expectedTree=[string](Get-Value $provenance 'sourceTreeSha256');if($expectedTree-notmatch'^[a-fA-F0-9]{64}$'){Add-UnknownGate 'ReleaseSourceTreeSha256'}
    else{foreach($channel in @($health.Distributions)){if($channel.SourceTreeSha256-and[string]$channel.SourceTreeSha256-ine$expectedTree){Add-ConflictGate 'ReleaseSourceTreeSha256'}}}
}
$channels=@($health.Distributions|ForEach-Object{[pscustomobject][ordered]@{Name=$_.Name;DeclaredVersion=$ExpectedVersion;SourceState=if($_.SourceVersion){'FOUND'}else{'UNKNOWN'};CacheState=if($_.CacheVersion){'FOUND'}else{'UNKNOWN'};ValidationState=if($_.SourceTreeSha256-and$_.CacheTreeSha256-and$_.SourceTreeSha256-ceq$_.CacheTreeSha256){'VALIDATED'}elseif($_.SourceTreeSha256-or$_.CacheTreeSha256){'CONFLICT'}else{'UNKNOWN'};SourceTreeSha256=$_.SourceTreeSha256;CacheTreeSha256=$_.CacheTreeSha256}})
$state=if($conflictGates.Count){'CONFLICT'}elseif($unknownGates.Count){'UNKNOWN'}else{'READY'};$failedGates=$conflictGates.ToArray()+$unknownGates.ToArray()
$result=[pscustomobject][ordered]@{SchemaVersion='1.0';State=$state;Passed=$state-eq'READY';FailedGates=$failedGates;ExpectedVersion=$ExpectedVersion;ReferenceTimeUtc=$health.ReferenceTimeUtc;Stages=[pscustomobject][ordered]@{Declared='DECLARED';Found=if(@($channels|Where-Object{$_.SourceState-ne'FOUND'-or$_.CacheState-ne'FOUND'}).Count){'UNKNOWN'}else{'FOUND'};Validated=if($state-eq'READY'){'VALIDATED'}else{$state}};Release=[pscustomobject][ordered]@{ProvenancePath=if($snapshot){$snapshot.Path}else{$provenanceNormalized};ProvenanceSha256=if($snapshot){$snapshot.Sha256}else{$null};CommitSha=if($provenance){[string](Get-Value $provenance 'commitSha')}else{$null};SourceRef=if($provenance){[string](Get-Value $provenance 'sourceRef')}else{$null};SourceTreeSha256=if($provenance){[string](Get-Value $provenance 'sourceTreeSha256')}else{$null}};Channels=$channels;Catalogs=@($health.Catalogs);WritePerformed=$false;ExecutionPerformed=$false;TransportPerformed=$false}
if($AsJson){$result|ConvertTo-Json -Depth 10 -Compress}else{$result}
if(-not$result.Passed-and-not$NoThrow){throw "PowerShell Workbench status is $state`: $($failedGates-join', ')."}
