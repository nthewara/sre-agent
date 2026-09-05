#Requires -Version 7.4

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. "$PSScriptRoot\_sre-agent-extensions.ps1"

$resourceGroup = 'rg-payload-test'
$definitions = @(Get-ZavaAgentExtensionDefinitions -ResourceGroup $resourceGroup)
$skills = @($definitions | Where-Object Kind -eq 'skills')
$filters = @($definitions | Where-Object Kind -eq 'incidentFilters')

if ($skills.Count -ne 7) { throw "Expected 7 skills, got $($skills.Count)." }
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
    'daily-health-report'
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
$missingDailySkillSet = Compare-ZavaAgentExtensionNameSet -Expected $expectedSkills -Actual @($skills.Name | Where-Object { $_ -ne 'daily-health-report' })
if ($missingDailySkillSet.IsExact -or $missingDailySkillSet.Missing -notcontains 'daily-health-report') {
    throw 'Exact skill-name verification accepted the old six-skill deployment without daily reporting.'
}
$duplicateDailySkillSet = Compare-ZavaAgentExtensionNameSet -Expected $expectedSkills -Actual @($skills.Name + 'daily-health-report')
if ($duplicateDailySkillSet.IsExact -or $duplicateDailySkillSet.Duplicates -notcontains 'daily-health-report') {
    throw 'Exact skill-name verification did not reject a duplicate daily reporter.'
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
    if ($payload.tags -isnot [array] -or $payload.tags.Count -ne 0) {
        throw "Payload tags must remain an empty JSON array for $($definition.Name)."
    }
    if ($definition.Kind -eq 'skills') {
        if ($payload.properties.skillContent -cne $definition.Properties.skillContent -or
            $payload.properties.description -cne $definition.Properties.description) {
            throw "Skill text changed during JSON serialization for $($definition.Name)."
        }
        $toolSet = Compare-ZavaAgentExtensionNameSet -Expected $definition.Properties.tools -Actual $payload.properties.tools
        if ($payload.properties.tools -isnot [array] -or -not $toolSet.IsExact -or
            $payload.properties.additionalFiles -isnot [array] -or $payload.properties.additionalFiles.Count -ne 0) {
            throw "Skill tool/additional-file arrays changed during JSON serialization for $($definition.Name)."
        }
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

function Assert-DailyReportContract {
    param(
        [Parameter(Mandatory)]
        [object]$Properties,
        [Parameter(Mandatory)]
        [string]$ResourceGroup
    )

    $allowedTools = @('RunAzCliReadCommands', 'RunKubectlReadCommand', 'SearchMemory')
    $prohibitedTools = @(
        'RunAzCliWriteCommands', 'RunKubectlWriteCommand', 'ExecutePythonCode',
        'SendOutlookEmail'
    )
    if (@($Properties.tools | Where-Object { $_ -in $prohibitedTools }).Count -gt 0) {
        throw 'Daily report contract: write, code-execution or notification tool enabled.'
    }
    $toolSet = Compare-ZavaAgentExtensionNameSet -Expected $allowedTools -Actual $Properties.tools
    if (-not $toolSet.IsExact) {
        throw 'Daily report contract: tool list must be exactly the three permitted read tools, without duplicates.'
    }

    $text = $Properties.skillContent -replace '\s+', ' '
    $requiredInstructions = [ordered]@{
        AlwaysReport = 'Always return a Markdown digest'
        NoSilence = 'Never complete silently.'
        Scope = "Resource Group ``$ResourceGroup``"
        Namespace = 'private AKS namespace `zava-demo`'
        Role = "AppRoleName == 'zava-api'"
        ResourceScope = "where _ResourceId =~ '<app-insights-resource-id>'"
        NoRemediation = 'No writes, remediation, incident modification, handoffs, or delegation.'
        NoSubagents = 'Do not load other skills, launch subagents'
        NoSql = 'SQL execution (including SELECT)'
        NoNotifications = 'do not send email, chat notifications or webhooks.'
        ReviewMode = 'in Review mode'
        RbacBoundary = 'are not a separate RBAC boundary'
        DayWindow = 'previous 24 hours [T-24h, T)'
        CurrentWindow = 'current last 15 minutes [T-15m, T)'
        Timezone = 'schedule timezone not supplied'
        CoverageGuard = 'at least 100 observed samples spanning at least 20 hourly buckets'
        BaselineGuard = 'current endpoint data is sufficient and fresh'
        Retention = 'never request a 7-day baseline'
        ProbeExclusion = "Path !contains '__probe' and Name !contains '__probe'"
        WeightedRequests = 'Requests = sum(Weight)'
        Http5xx = 'Http5xx = sumif(Weight, Code between (500 .. 599))'
        Denominator = '100.0 * Http5xx / Requests'
        NoTraffic = 'A zero denominator means Unknown'
        Freshness = 'Last observation older than 5 minutes at T is stale'
        Database = '`Ready` proves control-plane state, not app-to-database connectivity'
        KubernetesHistory = 'Do not assume Container Insights'
        Restarts = 'Restart counters are since container/pod creation'
        AlertWindow = 'Never compare a 24-hour error count to a 5-minute threshold'
        CurrentAlerts = 'monitorCondition=Fired&timeRange=30d&pageCount=250'
        Recovery = 'recovery unverified'
        NoInventedCauses = 'no invented baselines, correlations or root causes'
        Assessments = '**Healthy**, **Needs attention**, **Unknown**'
        UnknownEvidence = 'denied, stale, sparse or there is no traffic, use Unknown, not Healthy'
        Evidence = '**Evidence references**'
        Followups = '**Top follow-ups**'
        ReadOnly = 'Read-only report. No resources or incidents were changed.'
    }
    foreach ($requirement in $requiredInstructions.GetEnumerator()) {
        if (-not $text.Contains($requirement.Value, [System.StringComparison]::Ordinal)) {
            throw "Daily report contract: missing $($requirement.Key) instruction."
        }
    }
}

$daily = $skills | Where-Object Name -eq 'daily-health-report'
$dailyPayload = ConvertTo-ZavaAgentExtensionPayload -Definition $daily | ConvertFrom-Json
Assert-DailyReportContract -Properties $dailyPayload.properties -ResourceGroup $resourceGroup

$dailySource = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot '../sre-config/skills/daily-health-report.md'))
if ($dailySource.Contains('@@SHARED@@')) {
    throw 'Daily reporting must not inherit the remediation-capable shared context.'
}

$repeatDaily = Get-ZavaAgentExtensionDefinitions -ResourceGroup $resourceGroup |
    Where-Object Name -eq 'daily-health-report'
if ((ConvertTo-ZavaAgentExtensionPayload -Definition $repeatDaily) -cne
    (ConvertTo-ZavaAgentExtensionPayload -Definition $daily)) {
    throw 'Repeated daily-report payload generation must be deterministic for idempotent PUT synchronization.'
}
$otherResourceGroup = 'rg-payload-secondary'
$otherDaily = Get-ZavaAgentExtensionDefinitions -ResourceGroup $otherResourceGroup |
    Where-Object Name -eq 'daily-health-report'
$otherDailyPayload = ConvertTo-ZavaAgentExtensionPayload -Definition $otherDaily | ConvertFrom-Json
Assert-DailyReportContract -Properties $otherDailyPayload.properties -ResourceGroup $otherResourceGroup
if ($otherDailyPayload.properties.skillContent.Contains($resourceGroup)) {
    throw 'Daily-report payload leaked a previously substituted resource group.'
}

$invalidDailyCases = [ordered]@{
    AzureWrite = { param($p) $p.tools += 'RunAzCliWriteCommands' }
    KubernetesWrite = { param($p) $p.tools += 'RunKubectlWriteCommand' }
    GenericExecution = { param($p) $p.tools += 'ExecutePythonCode' }
    Notification = { param($p) $p.tools += 'SendOutlookEmail' }
    UnlistedTool = { param($p) $p.tools += 'UnlistedTool' }
    MissingKubernetes = { param($p) $p.tools = @($p.tools | Where-Object { $_ -ne 'RunKubectlReadCommand' }) }
    DuplicateTool = { param($p) $p.tools += 'SearchMemory' }
    SilentHealthy = { param($p) $p.skillContent = $p.skillContent.Replace('Always return a Markdown digest', 'Complete silently when healthy') }
    RemediationHandoff = { param($p) $p.skillContent = $p.skillContent.Replace('No writes, remediation, incident modification, handoffs, or delegation.', 'Hand off to a remediation skill.') }
    HealthyWithoutData = { param($p) $p.skillContent = $p.skillContent.Replace('A zero denominator means Unknown', 'A zero denominator means Healthy') }
}
foreach ($case in $invalidDailyCases.GetEnumerator()) {
    $invalidPayload = ConvertTo-ZavaAgentExtensionPayload -Definition $daily | ConvertFrom-Json
    & $case.Value $invalidPayload.properties
    $rejected = $false
    try {
        Assert-DailyReportContract -Properties $invalidPayload.properties -ResourceGroup $resourceGroup
    } catch {
        if (-not $_.Exception.Message.StartsWith('Daily report contract:', [System.StringComparison]::Ordinal)) {
            throw
        }
        $rejected = $true
    }
    if (-not $rejected) { throw "Daily-report validation accepted invalid case $($case.Key)." }
}

$proactive = $skills | Where-Object Name -eq 'proactive-health-check'
foreach ($instruction in @('over the last 15 minutes', 'hand off to the matching domain skill', 'If everything is in baseline, complete silently.')) {
    if (-not $proactive.Properties.skillContent.Contains($instruction)) {
        throw "Separate proactive-health-check semantics changed: missing '$instruction'."
    }
}

Write-Host "PASS: generated and validated 7 skill + 4 incident-filter data-plane payloads, exact-name sets, daily read-only/reporting contracts and rejection cases without network calls."
