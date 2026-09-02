[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProfilePath,
    [switch]$AllowAbsoluteRoots,
    [switch]$AllowExternalComponentRoots,
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
$components=foreach($component in @($profileDocument.components)){
    $componentRoot=Resolve-ProfileRoot -Value ([string]$component.root) -Label "Component '$($component.id)'"
    if(-not $AllowExternalComponentRoots -and -not($componentRoot.Equals($projectRoot,[StringComparison]::OrdinalIgnoreCase) -or $componentRoot.StartsWith($projectPrefix,[StringComparison]::OrdinalIgnoreCase))){throw "Component '$($component.id)' resolves outside the project root. Use -AllowExternalComponentRoots only when explicitly required."}
    [pscustomobject]@{Id=[string]$component.id;Role=[string]$component.role;ConfiguredRoot=[string]$component.root;ResolvedRoot=$componentRoot;Exists=(Test-Path -LiteralPath $componentRoot -PathType Container)}
}
$paths=[ordered]@{}
foreach($property in @($profileDocument.paths.PSObject.Properties)){if([IO.Path]::IsPathRooted([string]$property.Value) -and -not $AllowAbsoluteRoots){throw "Configured path '$($property.Name)' must be relative."};$paths[$property.Name]=[IO.Path]::GetFullPath((Join-Path $projectRoot ([string]$property.Value)))}
$result=[pscustomobject]@{SchemaVersion='1.0';ProfilePath=$profilePathResolved;ProjectName=[string]$profileDocument.project.name;ProjectRoot=$projectRoot;ProjectRootExists=(Test-Path -LiteralPath $projectRoot -PathType Container);Components=@($components);WindowsTargets=@($profileDocument.targets.windows);Paths=[pscustomobject]$paths}
if($AsJson){$result|ConvertTo-Json -Depth 10}else{$result}
