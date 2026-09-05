@{
    Skills = @(
        @{
            Name = 'database-incidents'
            Description = 'Use for Zava PostgreSQL AVAILABILITY incidents — alert `postgres-unreachable` (zava-api cannot reach PostgreSQL; connection refused or, more often, timeout). Diagnose the cause from ARM state — stopped server vs network partition — and remediate: restart the server, or remove the in-cluster Kubernetes NetworkPolicy / matching NSG deny rule that blocks PG egress.'
            Tools = @(
                'RunAzCliReadCommands'
                'RunAzCliWriteCommands'
                'RunKubectlReadCommand'
                'RunKubectlWriteCommand'
                'SearchMemory'
                'learn-docs_microsoft_docs_search'
                'learn-docs_microsoft_docs_fetch'
            )
            ContentFile = 'skills/database-incidents.md'
        }
        @{
            Name = 'performance-incidents'
            Description = 'Use for Zava query-LATENCY / slow-endpoint incidents — alert `Zava-products-query-slow` (a /api/products/category endpoint breached its latency threshold). Diagnose the PostgreSQL query path, check nearby alerts with `incident-correlation`, and do not treat a co-firing 5xx as the same cause without a direct dependency-failure mechanism. Apply read-mostly DDL (CREATE INDEX) via the in-cluster SQL helper when the query plan proves it is needed.'
            Tools = @(
                'RunAzCliReadCommands'
                'RunAzCliWriteCommands'
                'RunKubectlReadCommand'
                'RunKubectlWriteCommand'
                'SearchMemory'
                'learn-docs_microsoft_docs_search'
                'learn-docs_microsoft_docs_fetch'
            )
            ContentFile = 'skills/performance-incidents.md'
        }
        @{
            Name = 'application-incidents'
            Description = 'Use for Zava APPLICATION-layer HTTP 5xx incidents — alert `Zava-http-5xx-errors` (zava-api returning HTTP 5xx). Rule out a direct DB failure path, check nearby alerts with `incident-correlation`, and correlate the 5xx onset with a recent rollout. Do not attribute it to a co-firing latency alert unless dependency failures prove that mechanism.'
            Tools = @(
                'RunAzCliReadCommands'
                'RunAzCliWriteCommands'
                'RunKubectlReadCommand'
                'RunKubectlWriteCommand'
                'SearchMemory'
                'learn-docs_microsoft_docs_search'
                'learn-docs_microsoft_docs_fetch'
            )
            ContentFile = 'skills/application-incidents.md'
        }
        @{
            Name = 'general-triage'
            Description = 'Use for ANY Zava incident that does not match a specific known scenario — novel / unknown alerts routed to the unknown response plan. Triage from first principles: identify the impacted resource, gather telemetry, form hypotheses, and propose a remediation for human approval (this path runs in Review mode). Do not auto-remediate beyond clearly read-only/safe steps.'
            Tools = @(
                'RunAzCliReadCommands'
                'SearchMemory'
                'learn-docs_microsoft_docs_search'
                'learn-docs_microsoft_docs_fetch'
            )
            ContentFile = 'skills/general-triage.md'
        }
        @{
            Name = 'proactive-health-check'
            Description = 'Use when a human operator asks for a proactive health check of the Zava Athletic API — request success rate, latency, exception patterns, PostgreSQL state — to detect anomalies before they become alerts. Hands off to the matching domain skill (database / performance / application) if a known failure mode is found; otherwise completes silently.'
            Tools = @(
                'RunAzCliReadCommands'
                'SearchMemory'
                'ExecutePythonCode'
                'learn-docs_microsoft_code_sample_search'
                'learn-docs_microsoft_docs_fetch'
                'learn-docs_microsoft_docs_search'
            )
            ContentFile = 'skills/proactive-health-check.md'
        }
        @{
            Name = 'daily-health-report'
            Description = 'Use for a scheduled or on-demand Zava daily health digest. Always return a read-only Markdown report for the previous 24 hours and current last 15 minutes, including healthy, needs-attention, or unknown status, evidence freshness, coverage gaps, and human follow-ups. Never remediate, delegate, or complete silently.'
            Tools = @(
                'RunAzCliReadCommands'
                'RunKubectlReadCommand'
                'SearchMemory'
            )
            ContentFile = 'skills/daily-health-report.md'
        }
        @{
            Name = 'incident-correlation'
            Description = 'Use during a Zava incident when nearby alerts or conflicting evidence require correlation. Review fired alerts, relevant disabled rules, Azure Service Health, and telemetry to determine whether conditions share a mechanism or should remain independent.'
            Tools = @(
                'RunAzCliReadCommands'
                'SearchMemory'
            )
            ContentFile = 'skills/incident-correlation.md'
        }
    )
    IncidentFilters = @(
        @{
            Name = 'zava-database'
            Properties = @{
                incidentPlatform = 'AzMonitor'
                impactedService = ''
                priorities = @('Sev0', 'Sev1', 'Sev2', 'Sev3', 'Sev4')
                incidentType = ''
                alertId = ''
                titleContains = 'postgres'
                titleContainsAll = @()
                titleContainsAny = @()
                titleNotContains = @()
                agentMode = 'autonomous'
                handlingAgent = 'meta_agent'
                handlingAgents = $null
                owningTeamId = ''
                owningTeamIds = @()
                maxAutomatedInvestigationAttempts = 3
                mergeEnabled = $false
                mergeWindowHours = 3
                isEnabled = $true
                icmFilterSettings = $null
                azMonitorFilterSettings = @{
                    targetResourceType = ''
                    targetResource = ''
                }
            }
        }
        @{
            Name = 'zava-performance'
            Properties = @{
                incidentPlatform = 'AzMonitor'
                impactedService = ''
                priorities = @('Sev0', 'Sev1', 'Sev2', 'Sev3', 'Sev4')
                incidentType = ''
                alertId = ''
                titleContains = 'query-slow'
                titleContainsAll = @()
                titleContainsAny = @()
                titleNotContains = @()
                agentMode = 'autonomous'
                handlingAgent = 'meta_agent'
                handlingAgents = $null
                owningTeamId = ''
                owningTeamIds = @()
                maxAutomatedInvestigationAttempts = 3
                mergeEnabled = $false
                mergeWindowHours = 3
                isEnabled = $true
                icmFilterSettings = $null
                azMonitorFilterSettings = @{
                    targetResourceType = ''
                    targetResource = ''
                }
            }
        }
        @{
            Name = 'zava-application'
            Properties = @{
                incidentPlatform = 'AzMonitor'
                impactedService = ''
                priorities = @('Sev0', 'Sev1', 'Sev2', 'Sev3', 'Sev4')
                incidentType = ''
                alertId = ''
                titleContains = 'http-5xx'
                titleContainsAll = @()
                titleContainsAny = @()
                titleNotContains = @()
                agentMode = 'autonomous'
                handlingAgent = 'meta_agent'
                handlingAgents = $null
                owningTeamId = ''
                owningTeamIds = @()
                maxAutomatedInvestigationAttempts = 3
                mergeEnabled = $false
                mergeWindowHours = 3
                isEnabled = $true
                icmFilterSettings = $null
                azMonitorFilterSettings = @{
                    targetResourceType = ''
                    targetResource = ''
                }
            }
        }
        @{
            Name = 'zava-unknown'
            Properties = @{
                incidentPlatform = 'AzMonitor'
                impactedService = ''
                priorities = @('Sev0', 'Sev1', 'Sev2', 'Sev3', 'Sev4')
                incidentType = ''
                alertId = ''
                titleContains = 'Zava'
                titleContainsAll = @()
                titleContainsAny = @()
                titleNotContains = @('postgres', 'query-slow', 'http-5xx')
                agentMode = 'review'
                handlingAgent = 'meta_agent'
                handlingAgents = $null
                owningTeamId = ''
                owningTeamIds = @()
                maxAutomatedInvestigationAttempts = 2
                mergeEnabled = $false
                mergeWindowHours = 3
                isEnabled = $true
                icmFilterSettings = $null
                azMonitorFilterSettings = @{
                    targetResourceType = ''
                    targetResource = ''
                }
            }
        }
    )
}
