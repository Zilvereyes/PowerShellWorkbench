[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('AdvancedFunction', 'Script', 'Module', 'Manifest', 'PesterBasic', 'PesterSynthetic', 'PesterContract', 'JsonContract', 'MarkdownDecision', 'MarkdownHelp', 'PSScriptAnalyzerConfig', 'MegaLinterConfig', 'GitHubWorkflow')]
    [string]$Kind,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z][A-Za-z0-9_.-]*$')]
    [string]$Name,

    [Parameter(Mandatory = $true)]
    [string]$Destination,

    [Parameter(Mandatory = $true)]
    [ValidateSet('Generic', 'RecoveryToolkit', 'WingetDownloader')]
    [string]$Profile,

    [string]$ProjectRoot,

    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$templateRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'skills\powershell-scaffold\assets\templates'
$resolvedDestination = [System.IO.Path]::GetFullPath($Destination)
$isPrivateFunction = $Kind -eq 'AdvancedFunction' -and $resolvedDestination -match '[\\/]Private(?:[\\/]|$)'
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $resolverPath = Join-Path $PSScriptRoot 'Resolve-PowerShellWorkbenchContext.ps1'
    $context = & $resolverPath -StartPath $resolvedDestination -RequestedProfile $Profile
    $ProjectRoot = $context.ProjectRoot
}
elseif (Test-Path -LiteralPath $ProjectRoot) {
    $ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
}
else {
    throw "ProjectRoot does not exist: $ProjectRoot"
}

switch ($Profile) {
    'RecoveryToolkit' {
        $pathHint = 'Place public functions in the matching domain folder and shared helpers under Private.'
        $testStyle = 'Test_<Name>.<Basic|Synthetic|Contract>.ps1'
        $loggingGuidance = 'Return structured objects and preserve the toolkit reporting boundary.'
        $safetyGuidance = 'Keep servicing and staging contracts non-executable; require explicit authorization for elevation or writes.'
    }
    'WingetDownloader' {
        $pathHint = 'Use WD-prefixed private helpers and retain a deliberate public command surface.'
        $testStyle = 'Test_<Name>.<Basic|Synthetic|Contract>.ps1'
        $loggingGuidance = 'Preserve structured status, error records, WinGet exit codes, and SHA-256 evidence.'
        $safetyGuidance = 'Do not execute installers, delete caches, or perform online or offline servicing implicitly.'
    }
    default {
        $pathHint = 'Use Public and Private folders when the module benefits from a split layout.'
        $testStyle = '<Name>.Tests.ps1'
        $loggingGuidance = 'Return structured objects and keep host-only output at the outer command boundary.'
        $safetyGuidance = 'Use ShouldProcess for mutations and keep destructive or elevated work explicit.'
    }
}

$templateName = switch ($Kind) {
    'AdvancedFunction' { if ($isPrivateFunction) { 'advanced-function-private.ps1.tmpl' } else { 'advanced-function-public.ps1.tmpl' } }
    'Script' { 'script.ps1.tmpl' }
    'Module' { 'module.psm1.tmpl' }
    'Manifest' { 'manifest.psd1.tmpl' }
    'PesterBasic' { 'pester-basic.tests.ps1.tmpl' }
    'PesterSynthetic' { 'pester-synthetic.tests.ps1.tmpl' }
    'PesterContract' { 'pester-contract.tests.ps1.tmpl' }
    'JsonContract' { 'contract.json.tmpl' }
    'MarkdownDecision' { 'decision.md.tmpl' }
    'MarkdownHelp' { 'help.md.tmpl' }
    'PSScriptAnalyzerConfig' { 'PSScriptAnalyzerSettings.psd1.tmpl' }
    'MegaLinterConfig' { 'mega-linter.yml.tmpl' }
    'GitHubWorkflow' { 'powershell-quality.yml.tmpl' }
}

$outputName = switch ($Kind) {
    'AdvancedFunction' { "$Name.ps1" }
    'Script' { "$Name.ps1" }
    'Module' { "$Name.psm1" }
    'Manifest' { "$Name.psd1" }
    'PesterBasic' { if ($Profile -eq 'Generic') { "$Name.Tests.ps1" } else { "Test_$Name.Basic.ps1" } }
    'PesterSynthetic' { if ($Profile -eq 'Generic') { "$Name.Synthetic.Tests.ps1" } else { "Test_$Name.Synthetic.ps1" } }
    'PesterContract' { if ($Profile -eq 'Generic') { "$Name.Contract.Tests.ps1" } else { "Test_$Name.Contract.ps1" } }
    'JsonContract' { "$Name.contract.json" }
    'MarkdownDecision' { "ADR-$Name.md" }
    'MarkdownHelp' { "about_$Name.md" }
    'PSScriptAnalyzerConfig' { 'PSScriptAnalyzerSettings.psd1' }
    'MegaLinterConfig' { '.mega-linter.yml' }
    'GitHubWorkflow' { 'powershell-quality.yml' }
}

$templatePath = Join-Path $templateRoot $templateName
$outputPath = Join-Path $resolvedDestination $outputName
if ((Test-Path -LiteralPath $outputPath) -and -not $Force) {
    throw "Refusing to overwrite existing file: $outputPath. Pass -Force only when replacement is intentional."
}

$tokens = [ordered]@{
    NAME = $Name
    PROFILE = $Profile
    DATE = (Get-Date -Format 'yyyy-MM-dd')
    GUID = ([guid]::NewGuid().Guid)
    PROJECT_ROOT = $ProjectRoot
    PROJECT_ROOT_JSON = ($ProjectRoot | ConvertTo-Json -Compress)
    PATH_HINT = $pathHint
    TEST_STYLE = $testStyle
    LOGGING_GUIDANCE = $loggingGuidance
    SAFETY_GUIDANCE = $safetyGuidance
}

$content = [System.IO.File]::ReadAllText($templatePath)
foreach ($tokenName in $tokens.Keys) {
    $content = $content.Replace('{{' + $tokenName + '}}', [string]$tokens[$tokenName])
}

if ($PSCmdlet.ShouldProcess($outputPath, "Generate $Kind artifact")) {
    if (-not (Test-Path -LiteralPath $resolvedDestination)) {
        $null = New-Item -ItemType Directory -Path $resolvedDestination -Force
    }
    [System.IO.File]::WriteAllText($outputPath, $content, [System.Text.UTF8Encoding]::new($false))
    Get-Item -LiteralPath $outputPath
}
