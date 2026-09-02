[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$FilePath,
    [string[]]$ArgumentList = @(),
    [string]$WorkingDirectory = (Get-Location).Path,
    [string]$ReportDirectory = (Join-Path (Get-Location).Path 'Reports\NativeCommands'),
    [string]$StepId = 'native-command',
    [scriptblock]$Verify,
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
$runId='{0}-{1}' -f ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')),[guid]::NewGuid().ToString('N')
if(-not(Test-Path -LiteralPath $ReportDirectory -PathType Container)){New-Item -ItemType Directory -Path $ReportDirectory -Force|Out-Null}
$reportPath=Join-Path $ReportDirectory "$runId.json";$timelinePath=Join-Path $ReportDirectory "$runId.timeline.txt"
$startedAt=[DateTime]::UtcNow;$timeline=New-Object System.Collections.Generic.List[string]
$safeArguments=@($ArgumentList|ForEach-Object {Protect-OperatorText ([string]$_)})
$timeline.Add("STARTER $($startedAt.ToString('o')) $StepId")
Write-OperatorBlock -State 'STARTER' -Message "[$StepId] $resolvedFile $($safeArguments -join ' ')"
$exitCode=$null;$executionError=$null;$verified=$false;$targetMutation=$false;$processStarted=$false
if($AnalyzeOnly){$timeline.Add('ANALYZE_ONLY process was not started.');Write-OperatorBlock -State 'FAERDIG' -Message "[$StepId] analyse udfoert; processen blev ikke startet."}else{
    try{
        Push-Location -LiteralPath $resolvedWorkingDirectory
        try{
            & $resolvedFile @ArgumentList 2>&1|ForEach-Object {$line=Protect-OperatorText ([string]$_);$timeline.Add("OUTPUT $line");Write-OperatorLine -Message $line -Color 'Gray'}
            $exitCode=$LASTEXITCODE;$processStarted=$true
        }finally{Pop-Location}
        if($exitCode -eq 0){Write-OperatorBlock -State 'FAERDIG' -Message "[$StepId] afsluttet med exit code 0.";$timeline.Add('FAERDIG exit code 0.')}else{Write-OperatorBlock -State 'FEJL' -Message "[$StepId] afsluttet med exit code $exitCode.";$timeline.Add("FEJL exit code $exitCode.")}
    }catch{$executionError=$_.Exception.Message;Write-OperatorBlock -State 'FEJL' -Message "[$StepId] kunne ikke koeres: $executionError";$timeline.Add("FEJL $executionError")}
}
$baseResult=[pscustomobject]@{StepId=$StepId;ExitCode=$exitCode;ExecutionError=$executionError;AnalyzeOnly=[bool]$AnalyzeOnly;ProcessStarted=$processStarted;TargetMutation=$targetMutation}
if(-not $AnalyzeOnly -and -not $executionError -and $exitCode -eq 0){$verified=$true;if($Verify){try{$verified=[bool](& $Verify $baseResult)}catch{$verified=$false;$executionError=$_.Exception.Message}}}
if($verified){Write-OperatorBlock -State 'VERIFICERET' -Message "[$StepId] post-check bestod.";$timeline.Add('VERIFICERET post-check bestod.')}elseif($Rollback){Write-OperatorBlock -State 'ROLLBACK' -Message "[$StepId] rollback er paakraevet; udfoer kun en eksplicit godkendt rollback-kommando.";$timeline.Add('ROLLBACK requested; no rollback command was executed.')}elseif(-not $AnalyzeOnly){Write-OperatorBlock -State 'FEJL' -Message "[$StepId] blev ikke verificeret.";$timeline.Add('FEJL post-check failed or was not supplied.')}
$finishedAt=[DateTime]::UtcNow
$result=[pscustomobject]@{SchemaVersion='1.0';RunId=$runId;StepId=$StepId;StartedAtUtc=$startedAt.ToString('o');FinishedAtUtc=$finishedAt.ToString('o');Executable=[pscustomobject]@{Path=$resolvedFile;FileVersion=(Get-Item -LiteralPath $resolvedFile).VersionInfo.FileVersion;Sha256=(Get-FileHash -LiteralPath $resolvedFile -Algorithm SHA256).Hash.ToLowerInvariant()};Arguments=$safeArguments;WorkingDirectory=$resolvedWorkingDirectory;ExitCode=$exitCode;ExecutionError=$executionError;Verified=$verified;AnalyzeOnly=[bool]$AnalyzeOnly;ProcessStarted=$processStarted;TargetMutation=$targetMutation;ReportsWritten=$true;TimelinePath=$timelinePath;ReportPath=$reportPath}
$timeline|Set-Content -LiteralPath $timelinePath -Encoding UTF8
$result|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $reportPath -Encoding UTF8
if(((-not $AnalyzeOnly) -and ($executionError -or $exitCode -ne 0 -or -not $verified)) -and -not $NoThrow){throw "Native command '$StepId' failed or was not verified. See $reportPath"}
$result
