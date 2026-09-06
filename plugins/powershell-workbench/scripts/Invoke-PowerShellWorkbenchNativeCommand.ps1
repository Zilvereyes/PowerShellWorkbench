[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$FilePath,
    [string[]]$ArgumentList = @(),
    [string]$WorkingDirectory = (Get-Location).Path,
    [string]$ReportDirectory = (Join-Path (Get-Location).Path 'Reports\NativeCommands'),
    [string]$StepId = 'native-command',
    [scriptblock]$Verify,
    [ValidateSet('ProcessLaunch','ArtifactIntegrity','InstalledState','Custom')][string]$VerificationScope,
    [int[]]$SuccessExitCodes = @(0),
    [switch]$RequireVerification,
    [ValidateSet('None','Possible','Expected','Unknown')][string]$MutationIntent = 'Unknown',
    [ValidateSet('Mount','Commit','BootMedia','RegistryHive','DiskWrite','ACL')][string[]]$RiskSurface = @(),
    [switch]$Rollback,
    [switch]$AnalyzeOnly,
    [switch]$NoThrow
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Protect-OperatorText {
    param([AllowNull()][string]$Text)
    if($null -eq $Text){return $null}
    $Text -replace '(?i)((?:api[_-]?key|token|password|secret|authorization)\s*[=:]\s*)[^\s;]+','$1[REDACTED]'
}

function Write-OperatorLine {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Operator-visible, color-coded progress is an explicit workbench feature.')]
    param([string]$Message,[ConsoleColor]$Color)
    $originalColor=[Console]::ForegroundColor
    try{[Console]::ForegroundColor=$Color;[Console]::WriteLine($Message)}finally{[Console]::ForegroundColor=$originalColor}
}

function Write-OperatorBlock {
    param([ValidateSet('STARTER','FAERDIG','VERIFICERET','FEJL','ROLLBACK')][string]$State,[string]$Message)
    $color=@{STARTER='Cyan';FAERDIG='Green';VERIFICERET='Green';FEJL='Red';ROLLBACK='Yellow'}[$State]
    Write-OperatorLine -Message ("`n========== {0} ==========" -f $State) -Color $color
    Write-OperatorLine -Message $Message -Color $color
    Write-OperatorLine -Message ('=' * (22 + $State.Length)) -Color $color
}

$resolvedFile=(Resolve-Path -LiteralPath $FilePath -ErrorAction Stop).Path
$resolvedWorkingDirectory=(Resolve-Path -LiteralPath $WorkingDirectory -ErrorAction Stop).Path
if($SuccessExitCodes.Count -eq 0){throw 'SuccessExitCodes cannot be empty.'}
if($RequireVerification -and -not $Verify){throw 'RequireVerification requires a Verify script block.'}
if($PSBoundParameters.ContainsKey('VerificationScope') -and -not $Verify){throw 'VerificationScope requires a Verify script block.'}
$effectiveVerificationScope=if($Verify){if($PSBoundParameters.ContainsKey('VerificationScope')){$VerificationScope}else{'Custom'}}else{'None'}
$runId='{0}-{1}' -f ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')),[guid]::NewGuid().ToString('N')
if(-not(Test-Path -LiteralPath $ReportDirectory -PathType Container)){New-Item -ItemType Directory -Path $ReportDirectory -Force|Out-Null}
$reportPath=Join-Path $ReportDirectory "$runId.json";$timelinePath=Join-Path $ReportDirectory "$runId.timeline.txt"
$startedAt=[DateTime]::UtcNow;$timeline=New-Object System.Collections.Generic.List[string]
$safeArguments=@($ArgumentList|ForEach-Object {Protect-OperatorText ([string]$_)})
$timeline.Add("STARTER $($startedAt.ToString('o')) $StepId")
Write-OperatorBlock -State 'STARTER' -Message "[$StepId] $resolvedFile $($safeArguments -join ' ')"
$exitCode=$null;$executionError=$null;$verificationError=$null;$verificationState='NotRun';$processStarted=$false;$succeeded=$false;$contractMutationIntent=if($AnalyzeOnly){'None'} else { $MutationIntent }
if($AnalyzeOnly){$timeline.Add('ANALYZE_ONLY process was not started.');Write-OperatorBlock -State 'FAERDIG' -Message "[$StepId] analyse udfoert; processen blev ikke startet."}else{
    try{
        Push-Location -LiteralPath $resolvedWorkingDirectory
        try{
            $processStarted = $true
            $previousErrorActionPreference=$ErrorActionPreference
            try{
                $ErrorActionPreference='Continue'
                & $resolvedFile @ArgumentList 2>&1|ForEach-Object {$line=Protect-OperatorText ([string]$_);$timeline.Add("OUTPUT $line");Write-OperatorLine -Message $line -Color 'Gray'}
                $exitCode=$LASTEXITCODE
            }finally{$ErrorActionPreference=$previousErrorActionPreference}
        }finally{Pop-Location}
        $succeeded=$SuccessExitCodes -contains $exitCode
        if($succeeded){Write-OperatorBlock -State 'FAERDIG' -Message "[$StepId] afsluttet med accepteret exit code $exitCode.";$timeline.Add("FAERDIG accepted exit code $exitCode.")}else{Write-OperatorBlock -State 'FEJL' -Message "[$StepId] afsluttet med ikke-accepteret exit code $exitCode.";$timeline.Add("FEJL unaccepted exit code $exitCode.")}
    }catch{$executionError=$_.Exception.Message;Write-OperatorBlock -State 'FEJL' -Message "[$StepId] kunne ikke koeres: $executionError";$timeline.Add("FEJL $executionError")}
}
$observedTargetMutation=if($AnalyzeOnly){$false}else{$null}
$baseResult=[pscustomobject]@{StepId=$StepId;ExitCode=$exitCode;Succeeded=$succeeded;ExecutionError=$executionError;AnalyzeOnly=[bool]$AnalyzeOnly;ProcessStarted=$processStarted;ExecutionOccurred=$processStarted;TargetMutation=$observedTargetMutation;MutationIntent=$contractMutationIntent;RiskSurfaces=@($RiskSurface)}
if(-not $AnalyzeOnly -and $succeeded -and $Verify){
    try{if([bool](& $Verify $baseResult)){$verificationState='Passed'}else{$verificationState='Failed'}}catch{$verificationState='Failed';$verificationError=$_.Exception.Message}
}
$verified=$verificationState -eq 'Passed'
if($verified){Write-OperatorBlock -State 'VERIFICERET' -Message "[$StepId] post-check bestod ($effectiveVerificationScope).";$timeline.Add("VERIFICERET post-check bestod ($effectiveVerificationScope).")}elseif($verificationState -eq 'Failed'){Write-OperatorBlock -State 'FEJL' -Message "[$StepId] post-check fejlede ($effectiveVerificationScope).";$timeline.Add("FEJL post-check failed ($effectiveVerificationScope).")}elseif(-not $AnalyzeOnly){$timeline.Add('VERIFICATION_NOT_RUN no post-check was executed.')}
$contractFailed=(-not $AnalyzeOnly) -and ((-not $succeeded) -or $verificationState -eq 'Failed' -or ($RequireVerification -and -not $verified))
if($contractFailed -and $Rollback){Write-OperatorBlock -State 'ROLLBACK' -Message "[$StepId] rollback er paakraevet; udfoer kun en eksplicit godkendt rollback-kommando.";$timeline.Add('ROLLBACK requested; no rollback command was executed.')}
$finishedAt=[DateTime]::UtcNow
$result=[pscustomobject]@{
    SchemaVersion='2.0'
    RunId=$runId
    StepId=$StepId
    StartedAtUtc=$startedAt.ToString('o')
    FinishedAtUtc=$finishedAt.ToString('o')
    Executable=[pscustomobject]@{Path=$resolvedFile;FileVersion=(Get-Item -LiteralPath $resolvedFile).VersionInfo.FileVersion;Sha256=(Get-FileHash -LiteralPath $resolvedFile -Algorithm SHA256).Hash.ToLowerInvariant()}
    Arguments=$safeArguments
    WorkingDirectory=$resolvedWorkingDirectory
    ExitCode=$exitCode
    SuccessExitCodes=@($SuccessExitCodes)
    Succeeded=$succeeded
    ExecutionError=$executionError
    VerificationState=$verificationState
    VerificationScope=$effectiveVerificationScope
    VerificationError=$verificationError
    VerificationRequired=[bool]$RequireVerification
    Verified=$verified
    AnalyzeOnly=[bool]$AnalyzeOnly
    ProcessStarted=$processStarted
    ExecutionOccurred=$processStarted
    TargetMutation=$observedTargetMutation
    MutationIntent=$contractMutationIntent
    RiskSurfaces=@($RiskSurface)
    ReportsWritten=$true
    TimelinePath=$timelinePath
    ReportPath=$reportPath
}
$timeline|Set-Content -LiteralPath $timelinePath -Encoding UTF8
$result|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $reportPath -Encoding UTF8
if($contractFailed -and -not $NoThrow){throw "Native command '$StepId' failed its execution or verification contract. See $reportPath"}
$result
