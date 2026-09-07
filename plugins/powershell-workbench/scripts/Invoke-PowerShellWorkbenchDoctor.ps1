[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProjectRoot,
    [string]$ProfilePath,
    [string]$AssessmentPath,
    [object[]]$Distribution=@(),
    [string]$ExpectedVersion,
    [string[]]$IncludeExtension=@('.ps1','.psm1','.psd1'),
    [ValidateSet('Utf8NoBom','Utf8Bom','Utf16LittleEndianBom','Utf16BigEndianBom','Utf32LittleEndianBom','Utf32BigEndianBom')][string[]]$AllowedEncoding=@(),
    [ValidateSet('LF','CRLF','CR','None')][string[]]$AllowedLineEnding=@(),
    [switch]$DisallowMixedLineEndings,
    [switch]$Fast,
    [switch]$IncludeRuntimeProbe,
    [switch]$AsJson
)

Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$resolvedRoot=(Resolve-Path -LiteralPath $ProjectRoot -ErrorAction Stop).Path
if(-not$ProfilePath){$ProfilePath=Join-Path $resolvedRoot '.powershell-workbench\project-profile.json'}
$context=& (Join-Path $PSScriptRoot 'Resolve-PowerShellWorkbenchContext.ps1') -StartPath $resolvedRoot -Fast:$Fast -SkipRuntimeProbe:(-not $IncludeRuntimeProbe)
$environment=& (Join-Path $PSScriptRoot 'Get-PowerShellWorkbenchEnvironment.ps1')
$profileResult=$null;$assessment=$null;$profileState='MISSING';$quality=$null
if(Test-Path -LiteralPath $ProfilePath -PathType Leaf){
    try{$profileResult=& (Join-Path $PSScriptRoot 'Resolve-PowerShellWorkbenchProjectProfile.ps1') -ProfilePath $ProfilePath;$profileState='VALID';$quality=$profileResult.Quality
        $assessment=& (Join-Path $PSScriptRoot 'Get-PowerShellWorkbenchProjectAssessment.ps1') -ProfilePath $ProfilePath -AssessmentPath $AssessmentPath
    }catch{$profileState='INVALID';$profileResult=[pscustomobject]@{Error=$_.Exception.Message}}
}
$textArguments=@{Path=$resolvedRoot;IncludeExtension=$IncludeExtension;NoThrow=$true;DisallowMixedLineEndings=[bool]$DisallowMixedLineEndings}
if(@($AllowedEncoding).Count -gt 0){$textArguments.AllowedEncoding=$AllowedEncoding}
if(@($AllowedLineEnding).Count -gt 0){$textArguments.AllowedLineEnding=$AllowedLineEnding}
$text=& (Join-Path $PSScriptRoot 'Get-PowerShellWorkbenchTextIntegrity.ps1') @textArguments
$health=$null;if(@($Distribution).Count -gt 0 -and -not[string]::IsNullOrWhiteSpace($ExpectedVersion)){$health=& (Join-Path $PSScriptRoot 'Test-PowerShellWorkbenchHealth.ps1') -Distribution $Distribution -ExpectedVersion $ExpectedVersion -NoThrow}
$duplicateState='UNKNOWN';if($health -and $health.Passed -and @($health.Distributions).Count -gt 1){$hashes=@($health.Distributions|ForEach-Object{$_.SourceTreeSha256}|Select-Object -Unique);if($hashes.Count -eq 1){$duplicateState='DUPLICATE_IDENTICAL'}else{$duplicateState='CONFLICT'}}
$next='Review diagnostic output before any change.'
if($profileState -eq 'MISSING'){$next='Preview a portable project profile with New-PowerShellWorkbenchProjectProfile.ps1 -NoWrite.'}
elseif($profileState -eq 'INVALID'){$next='Repair the project profile before assessing readiness.'}
elseif($assessment -and -not$assessment.IsConfigured){$next='Preview an assessment sidecar with New-PowerShellWorkbenchProjectAssessment.ps1 -NoWrite.'}
elseif($assessment -and -not$assessment.IsValid){$next='Resolve the assessment failed gates without declaring targets PASS.'}
elseif(-not$text.Passed){$next='Review text-policy failed gates; apply no encoding or line-ending change automatically.'}
elseif($duplicateState -eq 'DUPLICATE_IDENTICAL'){$next='Keep one channel authoritative for future upgrades; do not uninstall a channel automatically.'}
$result=[pscustomobject][ordered]@{SchemaVersion='1.0';State=if($profileState -eq 'INVALID' -or -not$text.Passed){'BLOCKED'}elseif($assessment -and $assessment.ReadinessStatus -ne 'PASS'){'WAITING'}else{'READY'};ProjectRoot=$resolvedRoot;Context=$context;Environment=$environment;ProfileState=$profileState;Profile=$profileResult;Assessment=$assessment;QualityPlan=$quality;TextIntegrity=$text;InstallationHealth=$health;DuplicateState=$duplicateState;NextSafeAction=$next;WritePerformed=$false;NetworkPerformed=$false;ProcessPerformed=[bool]$IncludeRuntimeProbe;TransportPerformed=$false}
if($AsJson){$result|ConvertTo-Json -Depth 16}else{$result}
