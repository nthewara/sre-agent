---
name: managing-sre-agent
description: "Manage Azure SRE Agent configuration for this demo: connectors, skills, response plans, and the knowledge base. Use when asked to create, list, update, or delete SRE Agent resources."
---

# SRE Agent Administration

For **this demo**, configuration has two owners because external tenants cannot
deploy the skill and incident-filter ARM child types.

## ARM-owned configuration

`infra/modules/sre-agent.bicep` deploys:

- **Agent settings** — autonomous mode, High access level, Azure Monitor incident binding
- **Connectors** — `app-insights`, `log-analytics`, `azure-monitor` (MonitorClient), `learn-docs` (Microsoft Learn no-auth MCP)
- **RBAC** — system-assigned managed identity granted Reader, Monitoring Reader,
  Contributor, and AKS RBAC Cluster Admin on the resource group; the runtime
  user-assigned identity also has subscription-level Reader so the
  correlation skill can read Alerts Management and Resource Health event feeds

To change these resources, edit Bicep and run `azd provision`.

Do not design overlapping response plans around an assumed priority or
specificity rule. Treat multiple matches as undefined, keep purpose-built
filters mutually exclusive where routing matters, and make any fallback both
positively scoped and explicitly exclude every known route.

## Data-plane-owned configuration

`scripts/setup-sre-agent.ps1` owns:

- **Custom skills** - the seven definitions in
  `sre-config/agent-extensions.psd1`, with markdown bodies under
  `sre-config/skills/`
- **Response plans / incident filters** — `zava-database`,
  `zava-performance`, `zava-application`, and `zava-unknown`, also declared in
  `agent-extensions.psd1`
- **Knowledge files**, **agent-global custom instructions**, and global
  **Microsoft Learn MCP tool enablement**

Run the synchronizer after ARM provisioning:

```powershell
.\scripts\setup-sre-agent.ps1
```

For an existing, correctly provisioned agent, a skill update does not require
Bicep or workload redeployment. Setup synchronizes all repository-managed
skills, response plans, knowledge, global instructions, and Learn tool state,
not just the changed skill. Match source to the deployed environment and
review portal customizations before running it. Pass `-SubscriptionId`,
`-ResourceGroup`, and `-AgentName` explicitly when not relying on an azd
environment.

The separate `daily-health-report` skill does not create or enable a scheduled
task or custom responder. Follow the operator-managed
[daily reporting workflow](../../../docs/daily-health-check.md) for a dedicated
responder, fixed scope, Review-mode testing, and optional notification consent.
Keep the reporting skill read-only and separate from `proactive-health-check`
and incident remediation. Do not add `SendOutlookEmail` before interactive
OAuth consent; the unconsented tool can prevent skill loading.

PUTs use a bounded readiness retry budget. Verification requires the exact
declared skill and incident-filter name sets, so retired remote entries are a
failure rather than silently remaining active.

The knowledge sync reads every `*.md` under `sre-config/knowledge-base/`, substitutes
`@@RG@@` -> the actual resource group, computes a SHA256, and uploads only files
whose content has changed since the last run (cache in
`sre-config/knowledge-base/.upload-hashes.json`). Any failed upload or
replacement is fatal because a stale same-name remote file cannot be verified
by name alone. To add new agent knowledge:

1. Drop a new `*.md` file into `sre-config/knowledge-base/`
2. Use `@@RG@@` placeholder anywhere you need the resource group name
3. Re-run `.\scripts\setup-sre-agent.ps1`

To remove a knowledge file: delete the local `.md`, then delete the corresponding
`<name>.md` from the agent's Builder UI > Knowledge sources view (the
script does not delete remote files that are no longer present locally).

The same script also syncs the singleton agent-global custom instructions from
`sre-config/custom-instructions.md` and enables the Microsoft Learn MCP tools.
Keep global instructions short; detailed procedures belong in a skill so they
load only when relevant.

## Recovery after a partial `azd up`

ARM may successfully deploy the AKS/PostgreSQL workload and agent before the
post-provision data-plane hook fails to obtain the `azuresre.dev` token. Do not
redeploy the workload first. Authenticate with the required scope, then rerun
only setup:

```powershell
az login --scope "https://azuresre.dev/.default"
.\scripts\setup-sre-agent.ps1
```

If verification reports `[UNEXPECTED]`, remove the named retired skill or
response plan in the SRE Agent Builder UI, then rerun setup. If it reports
`[MISSING]`, rerun setup to recreate the declared data-plane item. Use
`azd provision` only for missing or drifted ARM-owned resources.

## When helping users

1. **"Add a skill / response plan"** — edit
   `sre-config/agent-extensions.psd1` plus the referenced skill markdown, then
   run `setup-sre-agent.ps1`.
2. **"Add a connector or change agent/RBAC settings"** — edit
   `infra/modules/sre-agent.bicep` and run `azd provision`.
3. **"Add a knowledge file"** — drop the markdown under `sre-config/knowledge-base/`
   and run `setup-sre-agent.ps1`.
4. **"Verify the agent is configured"** — run `setup-sre-agent.ps1`; Step 4
   verifies ARM resources plus exact data-plane skill/response-plan sets.
5. **Activity-log alerts gotcha** — they fire as Sev4 regardless of the configured
   severity, so response plan filters must match all severities
   (`agent-extensions.psd1` already does).
6. **Runbook philosophy** - the seven skills (`database-incidents`, `performance-incidents`,
   `application-incidents`, `general-triage`, `proactive-health-check`,
   `incident-correlation`, `daily-health-report`) declared by
   `agent-extensions.psd1`
   state the facts the agent can't infer (the RBAC it holds, what each alert means, which
   table to look at) — e.g. the `database-incidents` runbook's `postgres-unreachable` triage
   table maps alert → ARM-state check → action TYPE — while keeping the actual remediation at
   the action-type level, NOT copy-paste SQL/kubectl recipes. Preserve both halves when
   adding/modifying skills. See AGENTS.md "Non-Obvious Things" for the full rationale.
7. **Kubernetes tool guidance** — use `RunKubectlReadCommand` and
   `RunKubectlWriteCommand` directly in runtime skills. Do not make runbooks
   depend on terminal-native kubectl.
