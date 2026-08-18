#Requires -Version 7.4

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. "$PSScriptRoot\_sre-agent-extensions.ps1"

$resourceGroup = 'rg-payload-test'
$definitions = @(Get-ZavaAgentExtensionDefinitions -ResourceGroup $resourceGroup)
$skills = @($definitions | Where-Object Kind -eq 'skills')
$filters = @($definitions | Where-Object Kind -eq 'incidentFilters')

if ($skills.Count -ne 6) { throw "Expected 6 skills, got $($skills.Count)." }
if ($filters.Count -ne 4) { throw "Expected 4 incident filters, got $($filters.Count)." }

$syncAst = (Get-Command Sync-ZavaAgentExtensions).ScriptBlock.Ast
$budgetParameter = $syncAst.Body.ParamBlock.Parameters |
    Where-Object { $_.Name.VariablePath.UserPath -eq 'ReadinessBudgetSeconds' }
if (-not $budgetParameter -or [int]$budgetParameter.DefaultValue.Value -lt 120) {
    throw 'Agent extension PUT readiness budget must default to at least 120 seconds.'
}

$expectedSkills = @(
    'database-incidents'
    'performance-incidents'
    'application-incidents'
    'general-triage'
    'proactive-health-check'
    'incident-correlation'
)
$expectedFilters = @('zava-database', 'zava-performance', 'zava-application', 'zava-unknown')

$actualSkillNames = (@($skills.Name | Sort-Object) -join ',')
$expectedSkillNames = (@($expectedSkills | Sort-Object) -join ',')
if ($actualSkillNames -ne $expectedSkillNames) {
    throw 'Skill names do not match the expected deployment set.'
}
$actualFilterNames = (@($filters.Name | Sort-Object) -join ',')
$expectedFilterNames = (@($expectedFilters | Sort-Object) -join ',')
if ($actualFilterNames -ne $expectedFilterNames) {
    throw 'Incident filter names do not match the expected deployment set.'
}
if (@($definitions.Name | Select-Object -Unique).Count -ne $definitions.Count) {
    throw 'Agent extension names must be unique.'
}

$exactSkillSet = Compare-ZavaAgentExtensionNameSet -Expected $expectedSkills -Actual $skills.Name
if (-not $exactSkillSet.IsExact) {
    throw 'Exact skill-name verification rejected the canonical set.'
}
$extraSkillSet = Compare-ZavaAgentExtensionNameSet -Expected $expectedSkills -Actual @($skills.Name + 'retired-skill')
if ($extraSkillSet.IsExact -or $extraSkillSet.Unexpected -notcontains 'retired-skill') {
    throw 'Exact skill-name verification did not reject an unexpected remote skill.'
}
$missingFilterSet = Compare-ZavaAgentExtensionNameSet -Expected $expectedFilters -Actual @($filters.Name | Where-Object { $_ -ne 'zava-unknown' })
if ($missingFilterSet.IsExact -or $missingFilterSet.Missing -notcontains 'zava-unknown') {
    throw 'Exact incident-filter verification did not reject a missing response plan.'
}
$emptyFilterSet = Compare-ZavaAgentExtensionNameSet -Expected $expectedFilters -Actual @()
if ($emptyFilterSet.IsExact -or $emptyFilterSet.Missing.Count -ne $expectedFilters.Count) {
    throw 'Exact incident-filter verification did not handle an empty remote set.'
}

foreach ($definition in $definitions) {
    $json = ConvertTo-ZavaAgentExtensionPayload -Definition $definition
    $payload = $json | ConvertFrom-Json
    if ($payload.name -ne $definition.Name -or $payload.type -ne $definition.Type) {
        throw "Payload envelope mismatch for $($definition.Name)."
    }
    if ($json.Contains('@@RG@@') -or $json.Contains('@@SHARED@@')) {
        throw "Unresolved placeholder in $($definition.Kind)/$($definition.Name)."
    }
}

foreach ($skill in $skills) {
    if ($skill.Name -ne 'proactive-health-check' -and -not $skill.Properties.skillContent.Contains($resourceGroup)) {
        throw "Resource group substitution missing from skill/$($skill.Name)."
    }
    if (-not $skill.Properties.description -or $skill.Properties.tools.Count -eq 0) {
        throw "Incomplete skill metadata for $($skill.Name)."
    }
}

Write-Host "PASS: generated and validated 6 skill + 4 incident-filter data-plane payloads and exact-name verification without network calls."
