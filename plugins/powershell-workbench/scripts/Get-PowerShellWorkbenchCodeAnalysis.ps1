[CmdletBinding()]
param([Parameter(Mandatory)][string]$Path)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
# Parse source as data. Never dot-source, import, or invoke the inspected file.
$resolvedPath = [IO.Path]::GetFullPath($Path)
if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) { throw 'Source file is missing.' }
if ((Get-Item -LiteralPath $resolvedPath).Length -gt 4194304) { throw 'Source exceeds 4 MiB.' }
$sourceText = [IO.File]::ReadAllText($resolvedPath)
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($sourceText, [ref]$tokens, [ref]$parseErrors)
$variables = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.VariableExpressionAst] }, $true) | ForEach-Object {
    [pscustomobject][ordered]@{
        name = $_.VariablePath.UserPath
        line = $_.Extent.StartLineNumber
        offset = $_.Extent.StartOffset
        parentKind = $_.Parent.GetType().Name
        scopeQualified = (-not $_.VariablePath.IsUnqualified)
    }
})
$assignments = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] }, $true) | ForEach-Object {
    [pscustomobject][ordered]@{ target=$_.Left.Extent.Text; operator=[string]$_.Operator; line=$_.Extent.StartLineNumber }
})
$commands = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true) | ForEach-Object {
    [pscustomobject][ordered]@{ name=$_.GetCommandName(); invocationOperator=[string]$_.InvocationOperator; line=$_.Extent.StartLineNumber }
})
$functions = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object {
    [pscustomobject][ordered]@{ name=$_.Name; startOffset=$_.Extent.StartOffset; endOffset=$_.Extent.EndOffset; startLine=$_.Extent.StartLineNumber; endLine=$_.Extent.EndLineNumber }
})
$errors = @($parseErrors | ForEach-Object {
    [pscustomobject][ordered]@{ id=$_.ErrorId; message=$_.Message; line=$_.Extent.StartLineNumber }
})
[pscustomobject][ordered]@{
    schemaVersion = '1.0'
    passed = ($errors.Count -eq 0)
    runtimeVersion = $PSVersionTable.PSVersion.ToString()
    variables = $variables
    assignments = $assignments
    commands = $commands
    functions = $functions
    dynamicCommandCount = @($commands | Where-Object { [string]::IsNullOrWhiteSpace($_.name) }).Count
    errors = $errors
    dependencyAnalysisComplete = $false
    limitations = @('AST inventory is not scope/data-flow closure proof. Review caller state, automatic variables, closures, member mutation, splatting, streams and control flow.')
    sourceExecutionPerformed = $false
} | ConvertTo-Json -Depth 12
