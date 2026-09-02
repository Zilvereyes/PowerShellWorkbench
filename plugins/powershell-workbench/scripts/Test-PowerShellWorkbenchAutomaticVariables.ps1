[CmdletBinding()]
param(
    [Parameter(Mandatory,ValueFromPipeline,ValueFromPipelineByPropertyName)][Alias('FullName')][string[]]$Path,
    [switch]$NoThrow,
    [switch]$AsJson
)

begin {
    Set-StrictMode -Version 2.0
    $ErrorActionPreference='Stop'
    $protected=@{home='homeEntry';host='hostInfo';pid='processId';error='parseError';args='arguments';input='inputValue';matches='matchResult';pshome='powerShellHome';executioncontext='executionContextInfo';myinvocation='invocationInfo'}
    $diagnostics=New-Object System.Collections.Generic.List[object]
}
process {
    foreach($candidate in $Path){
        $resolved=(Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path;$tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile($resolved,[ref]$tokens,[ref]$errors)
        foreach($assignment in $ast.FindAll({param($node)$node -is [Management.Automation.Language.AssignmentStatementAst]},$true)){
            $variable=$assignment.Left -as [Management.Automation.Language.VariableExpressionAst];if($null -eq $variable){continue}
            $name=($variable.VariablePath.UserPath -replace '^(?i:(global|script|local|private):)','').ToLowerInvariant()
            if($protected.ContainsKey($name)){$diagnostics.Add([pscustomobject]@{Path=$resolved;Line=$variable.Extent.StartLineNumber;Column=$variable.Extent.StartColumnNumber;Variable='$'+$variable.VariablePath.UserPath;SuggestedReplacement='$'+$protected[$name];Rule='PSWorkbench.ProtectedAutomaticVariable';Message="Assignment to protected automatic variable '$$name'. Use '$$($protected[$name])' instead."})}
        }
    }
}
end {
    $result=[pscustomobject]@{SchemaVersion='1.0';Passed=($diagnostics.Count -eq 0);Diagnostics=@($diagnostics.ToArray())}
    if($AsJson){$result|ConvertTo-Json -Depth 6}else{$result}
    if(-not $result.Passed -and -not $NoThrow){throw "Protected automatic-variable assignments were found: $($diagnostics.Count)"}
}
