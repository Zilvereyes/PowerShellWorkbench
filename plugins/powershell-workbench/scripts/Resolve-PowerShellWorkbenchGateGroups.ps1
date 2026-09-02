[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [object[]]$Gate,

    [Parameter(Mandatory)]
    [object[]]$GateGroup,

    [string[]]$RequiredGroup
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-RequiredProperty {
    param([object]$InputObject, [string]$Name, [string]$Context)

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { throw "$Context is missing required property '$Name'." }
    $property.Value
}

$gateByName = @{}
$gateOrder = New-Object System.Collections.Generic.List[string]
foreach ($item in @($Gate)) {
    $name = [string](Get-RequiredProperty -InputObject $item -Name 'Name' -Context 'Gate')
    if ([string]::IsNullOrWhiteSpace($name)) { throw 'Gate name cannot be empty.' }
    if ($gateByName.ContainsKey($name)) { throw "Duplicate gate name: $name" }

    $passedValue = Get-RequiredProperty -InputObject $item -Name 'Passed' -Context "Gate '$name'"
    if ($passedValue -isnot [bool]) { throw "Gate '$name' has an unknown Passed value." }

    $gateByName[$name] = [bool]$passedValue
    $gateOrder.Add($name)
}
if ($gateByName.Count -eq 0) { throw 'At least one gate is required.' }

$groupByName = @{}
$groupOrder = New-Object System.Collections.Generic.List[string]
foreach ($item in @($GateGroup)) {
    $name = [string](Get-RequiredProperty -InputObject $item -Name 'Name' -Context 'Gate group')
    if ([string]::IsNullOrWhiteSpace($name)) { throw 'Gate group name cannot be empty.' }
    if ($groupByName.ContainsKey($name)) { throw "Duplicate gate group name: $name" }

    $requiredGates = @((Get-RequiredProperty -InputObject $item -Name 'RequiredGates' -Context "Gate group '$name'") | ForEach-Object { [string]$_ })
    if ($requiredGates.Count -eq 0) { throw "Gate group '$name' must require at least one gate." }
    if ($requiredGates.Count -ne (@($requiredGates | Select-Object -Unique)).Count) { throw "Gate group '$name' contains duplicate gate names." }
    foreach ($gateName in $requiredGates) {
        if (-not $gateByName.ContainsKey($gateName)) { throw "Gate group '$name' references unknown gate '$gateName'." }
    }

    $groupByName[$name] = $requiredGates
    $groupOrder.Add($name)
}
if ($groupByName.Count -eq 0) { throw 'At least one gate group is required.' }

$selectedGroups = @(if ((@($RequiredGroup)).Count) { @($RequiredGroup) } else { @($groupOrder) })
if ($selectedGroups.Count -ne (@($selectedGroups | Select-Object -Unique)).Count) { throw 'RequiredGroup contains duplicate group names.' }
foreach ($groupName in $selectedGroups) {
    if (-not $groupByName.ContainsKey($groupName)) { throw "Unknown required gate group '$groupName'." }
}

$groupResults = foreach ($groupName in $groupOrder) {
    $failed = @($groupByName[$groupName] | Where-Object { -not $gateByName[$_] })
    [pscustomobject][ordered]@{
        Name = $groupName
        Passed = ($failed.Count -eq 0)
        FailedGates = $failed
    }
}

$selectedGateNames = New-Object System.Collections.Generic.List[string]
foreach ($gateName in $gateOrder) {
    foreach ($groupName in $selectedGroups) {
        if ($groupByName[$groupName] -contains $gateName) {
            if (-not $selectedGateNames.Contains($gateName)) { $selectedGateNames.Add($gateName) }
            break
        }
    }
}
$failedGates = @($selectedGateNames | Where-Object { -not $gateByName[$_] })

[pscustomobject][ordered]@{
    SchemaVersion = '1.0'
    Passed = ($failedGates.Count -eq 0)
    RequiredGroups = @($selectedGroups)
    FailedGates = $failedGates
    GateGroups = @($groupResults)
}
