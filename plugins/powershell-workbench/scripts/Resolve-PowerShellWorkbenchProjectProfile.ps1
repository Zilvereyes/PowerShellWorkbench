[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProfilePath,
    [switch]$AllowAbsoluteRoots,
    [switch]$AllowExternalComponentRoots,
    [switch]$AllowExternalPaths,
    [switch]$AsJson
)

Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$profilePathResolved=(Resolve-Path -LiteralPath $ProfilePath -ErrorAction Stop).Path
try{$profileDocument=Get-Content -LiteralPath $profilePathResolved -Raw|ConvertFrom-Json}catch{throw "Project profile is invalid JSON: $($_.Exception.Message)"}
if([string]$profileDocument.schemaVersion -ne '1.0'){throw 'Project profile schemaVersion must be 1.0.'}
$profileDirectory=Split-Path -Parent $profilePathResolved
function Resolve-ProfileRoot {
    param([string]$Value,[string]$Label)
    if([string]::IsNullOrWhiteSpace($Value)){throw "$Label root is missing."}
    if([IO.Path]::IsPathRooted($Value) -and -not $AllowAbsoluteRoots){throw "$Label root must be relative. Use -AllowAbsoluteRoots only when explicitly required."}
    [IO.Path]::GetFullPath($(if([IO.Path]::IsPathRooted($Value)){$Value}else{Join-Path $profileDirectory $Value}))
}
$projectRoot=Resolve-ProfileRoot -Value ([string]$profileDocument.project.root) -Label 'Project'
$projectPrefix=$projectRoot.TrimEnd([char[]]'\\/')+[IO.Path]::DirectorySeparatorChar
function Test-WithinProjectRoot {
    param([string]$Path)
    $Path.Equals($projectRoot,[StringComparison]::OrdinalIgnoreCase) -or $Path.StartsWith($projectPrefix,[StringComparison]::OrdinalIgnoreCase)
}
$components=foreach($component in @($profileDocument.components)){
    $componentRoot=Resolve-ProfileRoot -Value ([string]$component.root) -Label "Component '$($component.id)'"
    if(-not $AllowExternalComponentRoots -and -not(Test-WithinProjectRoot -Path $componentRoot)){throw "Component '$($component.id)' resolves outside the project root. Use -AllowExternalComponentRoots only when explicitly required."}
    [pscustomobject]@{Id=[string]$component.id;Role=[string]$component.role;ConfiguredRoot=[string]$component.root;ResolvedRoot=$componentRoot;Exists=(Test-Path -LiteralPath $componentRoot -PathType Container)}
}
$paths=[ordered]@{}
$pathDetails=[ordered]@{}
foreach($property in @($profileDocument.paths.PSObject.Properties)){
    $configuredPath=[string]$property.Value
    if([string]::IsNullOrWhiteSpace($configuredPath)){throw "Configured path '$($property.Name)' is missing."}
    if([IO.Path]::IsPathRooted($configuredPath) -and -not $AllowAbsoluteRoots){throw "Configured path '$($property.Name)' must be relative."}
    $resolvedPath=[IO.Path]::GetFullPath($(if([IO.Path]::IsPathRooted($configuredPath)){$configuredPath}else{Join-Path $projectRoot $configuredPath}))
    $withinProject=Test-WithinProjectRoot -Path $resolvedPath
    if(-not $AllowExternalPaths -and -not $withinProject){throw "Configured path '$($property.Name)' resolves outside the project root. Use -AllowExternalPaths only when explicitly required."}
    $paths[$property.Name]=$resolvedPath
    $pathDetails[$property.Name]=[pscustomobject]@{ConfiguredPath=$configuredPath;ResolvedPath=$resolvedPath;Exists=(Test-Path -LiteralPath $resolvedPath);WithinProject=$withinProject}
}
$result=[pscustomobject]@{SchemaVersion='1.0';ProfilePath=$profilePathResolved;ProjectName=[string]$profileDocument.project.name;ProjectRoot=$projectRoot;ProjectRootExists=(Test-Path -LiteralPath $projectRoot -PathType Container);Components=@($components);WindowsTargets=@($profileDocument.targets.windows);Paths=[pscustomobject]$paths;PathDetails=[pscustomobject]$pathDetails}
$quality=$profileDocument.quality
if($null -ne $quality){
    foreach($relativePath in @($quality.scopes)+@($quality.excludeRoots)){if([string]::IsNullOrWhiteSpace([string]$relativePath)-or[IO.Path]::IsPathRooted([string]$relativePath)-or([string]$relativePath)-match'(^|[\\/])\.\.([\\/]|$)'){throw 'Quality scope and exclusion paths must be non-empty portable relative paths.'}}
    Add-Member -InputObject $result -NotePropertyName Quality -NotePropertyValue ([pscustomobject][ordered]@{Scopes=@($quality.scopes);ExcludeRoots=@($quality.excludeRoots);AdvisoryRules=@($quality.advisoryRules);BlockingRules=@($quality.blockingRules)})
}
if($AsJson){$result|ConvertTo-Json -Depth 10}else{$result}
