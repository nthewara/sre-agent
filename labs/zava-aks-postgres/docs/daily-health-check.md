# Daily Zava health report

Use a native Azure SRE Agent scheduled task to produce a read-only Markdown
report every morning. A dedicated custom agent uses the `daily-health-report`
skill to summarize the last 24 hours and check the current 15-minute window.
It reports even when healthy, without fixing anything or delegating remediation.

This guide configures an **existing** Zava lab agent. The repository supplies the
skill, not an enabled schedule. No scheduled task, custom responder, notification
connector, or OAuth consent is created by adding or synchronizing the skill.
The portal steps below are an explicit operator opt-in; no live execution or
delivery is implied by this sample.

## What is separate, and why

| Component | Responsibility |
| --- | --- |
| `sre-config/agent-extensions.psd1` and `sre-config/skills/daily-health-report.md` | Repository-managed skill definition and reporting procedure |
| `scripts/setup-sre-agent.ps1` | Synchronizes and verifies repository-managed data-plane configuration |
| Custom agent `zava-daily-health-reporter` | Dedicated responder with only the reporting skill and required read tools |
| Scheduled task `zava-daily-health-check` | Operator-created native trigger with a fixed scope, schedule, and run mode |
| Optional Outlook or Teams connector | Separately consented delivery to a fixed destination |

Do not schedule the existing `proactive-health-check` skill for this workflow.
It remains an on-demand, 15-minute check that completes silently when healthy
and hands anomalies to remediation skills. It has no schedule of its own.
`daily-health-report` is a separate seventh runtime skill that always reports,
including missing evidence, and does not hand off to incident skills.

The workflow follows the native scheduled-task pattern illustrated by
[azure-sre-agent-sandbox](https://github.com/matthansen0/azure-sre-agent-sandbox),
where a task invokes `cluster-health-monitor` for last-hour checks and Outlook
delivery. Here the scope, reporting windows, private AKS access, and
notification opt-in are specific to Zava. Do not import that example's public
cluster or pets-workload assumptions, or copy undocumented data-plane YAML
resource schemas.

## 1. Confirm access and synchronize the skill

Before making configuration changes:

- Confirm the existing SRE Agent, subscription, lab resource group, AKS cluster,
  PostgreSQL server, and Log Analytics workspace identifiers.
- Confirm the agent can read this resource group's Azure resources and
  telemetry. The application role is `zava-api`; workload Kubernetes reads
  must stay in namespace `zava-demo` on the specified cluster.
- Use PowerShell 7.4+ and an authenticated Azure CLI. The operator needs access
  to configure the existing agent and obtain its data-plane token.
- Review the repository version against the deployed environment, including any
  local customizations. Use source that matches that deployment.

From the `labs/zava-aks-postgres` directory, replace the placeholders and run:

```powershell
az login --scope "https://azuresre.dev/.default"
az account set --subscription "<subscription-id>"
pwsh ./scripts/setup-sre-agent.ps1 `
  -SubscriptionId "<subscription-id>" `
  -ResourceGroup "<lab-resource-group>" `
  -AgentName "<existing-sre-agent-name>"
```

**This is a configuration write, not a dry run or a one-skill patch.** Setup
synchronizes all seven declared skills, all four response plans, knowledge
files, agent-global custom instructions, and global Microsoft Learn MCP tool
enablement, then verifies ARM and data-plane state. It can overwrite
repository-managed portal customizations. Review that full change before
running it against a shared agent.

For a matching, already-provisioned agent, no Bicep or workload redeployment is
needed. Skills come from the manifest and Markdown files through this
data-plane synchronizer, **not** `Microsoft.App/agents/skills` ARM children.
Do not run `azd up` just to add the reporting skill. Stop and investigate setup
failures or unexpected remote entries; do not delete unrelated configuration
to force verification to pass. See [agent management](../README.md#sre-agent-management)
and [the administration skill](../.github/skills/managing-sre-agent/SKILL.md).

Confirm that `daily-health-report` is available in Builder before continuing.
The synchronizer does not create the responder or task in the next sections.

## 2. Create a dedicated reporting custom agent

In the workspace-enabled portal experience:

1. Open **Builder > Agent Canvas > Create > Custom Agent**.
2. Use the **Form** tab and name it `zava-daily-health-reporter`. The product
   also offers YAML, but this guide does not require a YAML/API schema.
3. Set instructions describing a read-only Zava reporter, with the fixed
   subscription, resource group, cluster, workspace, PostgreSQL server, and
   namespace from the task prompt below.
4. Select **only** the `daily-health-report` skill. Do not add
   `proactive-health-check`, incident/domain skills, or other responders.
5. In **Choose tools**, select the required read tools:
   `RunAzCliReadCommands`, `RunKubectlReadCommand`, and `SearchMemory`.
   Verify these support the requested telemetry queries in your environment.
   Do not select write tools, generic code execution, shell/SQL execution,
   notification tools, or remediation/delegation handoffs.
6. Create the custom agent. Inspect the canvas and selected tools, including
   any inherited or globally enabled tools, before testing.

The AKS API is private. Use the built-in `RunKubectlReadCommand` for namespaced
read operations, not terminal-native kubectl, `kubectl exec`, or an operator
`az aks command invoke` workaround. Do not enable a public cluster endpoint.
PostgreSQL checks use resource state and platform metrics, not in-pod SQL.

**These restrictions are not hard RBAC isolation.** The existing lab SRE Agent
has privileged identities and incident responders with write access, including
AKS administration and broader read scope for correlation. A dedicated custom
agent, narrow tool selection, fixed instructions, and Review mode constrain
this workflow but do not remove the underlying permissions. If enforceable
read-only isolation is required, use a separately permissioned agent/identity;
that is outside this guide. Existing alert responders can still remediate
independently of the report.

Use **Test playground**, select this custom agent, and test the prompt below
before attaching a schedule. Inspect the tool trace as well as the answer.

## 3. Use a fixed-scope task prompt

Replace every angle-bracket placeholder with the deployed value. Put these
scope and safety instructions in the custom agent and use the following as
**Task details**. Keep the initial destination to the execution thread only.

```text
Use only the daily-health-report skill to produce today's Zava daily health
report. Always return a Markdown report, including when everything is healthy.

Fixed scope:
- Subscription: <subscription-id>
- Resource group: <lab-resource-group>
- AKS cluster: <cluster-name>
- Kubernetes workload namespace: zava-demo
- PostgreSQL Flexible Server: <postgres-server-name>
- Log Analytics workspace: <workspace-resource-id>
- Application Insights application role: zava-api
- Display timezone: <timezone-name-and-UTC-offset>

Use read-only Azure CLI queries, the built-in Kubernetes read tool, and
SearchMemory for environment context. Inspect only these resources and this
namespace. Do not expand into unrelated resource groups, subscriptions, or
namespaces. Use relevant platform health events only as supporting evidence
for this scope. Memory is context, not proof of current health.

No writes, remediation, deployment changes, restarts, scaling, fault injection,
SQL, kubectl exec, command execution workarounds, delegation, or handoffs to
other skills/agents. Do not acknowledge, close, or change alerts. Do not read
secrets, credentials, connection strings, Kubernetes Secret contents, or
sensitive request payloads. If a check would require forbidden access, mark it
Unknown and explain what read-only evidence is missing. Do not request extra
privileges or configure tools or schedules.

Report both the last 24 hours and the current 15 minutes, with explicit UTC
start/end timestamps and the display timezone. Query application telemetry
with AppRoleName == 'zava-api'. For customer-facing request metrics, exclude
/livez, /api/health, and synthetic __probe paths. Break product endpoints out
separately so healthy endpoints cannot mask a failed /api/products route.
Report request counts, failed counts, failure-rate denominators, and average
and p95 latency per endpoint/window. State low-volume and synthetic-traffic
limitations; do not call zero requests or missing telemetry healthy.

Check the scoped AKS/workload state and events, PostgreSQL state and available
metrics, application requests/dependencies/errors, resource health, and
relevant alerts. ContainerLogV2 and KubePodInventory are not guaranteed; use
available read evidence and explicitly mark unavailable signals Unknown.
Do not claim a 7-day baseline: high-volume application telemetry has 4-day
retention in this lab.

Distinguish active alerts/current failures from recovered events in the last
24 hours. Compare onset, dependency targets/failures, rollout evidence, and
resource state before suggesting a shared cause. Timestamp overlap alone
does not prove causality. Keep unproven or independent causes separate.

Use Healthy, Needs attention, or Unknown for each finding and for the current
overall status. Confirmed current degradation is Needs attention even when
other checks are Unknown. Otherwise, required missing or inconclusive
evidence makes the current status Unknown. Healthy requires sufficient
current evidence; it does not mean there were no incidents in the last day.

Output:
1. Current overall status, scope, report time, and both evidence windows.
2. Last-24-hours summary, with recovered incidents separate from open issues.
3. Evidence table: component/endpoint, status, 24h evidence, current-15m
   evidence, request/sample counts, and query/resource/alert references.
4. Coverage gaps and uncertainty, with latest available signal timestamps.
5. Prioritized recommended human follow-up, without executing any action.

Keep evidence concise and sanitized. Post only in this execution thread.
Do not email, message Teams, create incidents, or send external notifications.
```

The four-day retention is a limit on available high-volume App Insights table
history, not a guarantee of four days of complete data. Ingestion delays, idle
endpoints, missing tables, permissions, and connector failures must be visible
in the report. Zero errors can be reassuring only with an observed request
denominator and adequate coverage. The lab's self-probe also hits
`/api/products`; that traffic alone does not prove real customer activity.

## 4. Attach a native daily scheduled task

Use the custom-agent node's **+ > Add scheduled task**, or open
**Scheduled tasks > Create task**. Some portal navigation labels use
**Automation**. Configure these fields explicitly rather than accepting the
main-agent and Autonomous defaults:

| Field | Recommended initial value |
| --- | --- |
| Task name | `zava-daily-health-check` |
| Response custom agent / Response subagent | `zava-daily-health-reporter` |
| Task details | The substituted prompt above |
| Frequency | Daily |
| Time of day | Your intended local morning time; check the timezone in the UI label |
| Message grouping for updates | New thread per run, not "Use same thread" |
| Agent autonomy level | Review |
| Repeat until / Run limit | A bounded trial, for example three runs |

**Daily uses the timezone shown by the UI. Custom cron is UTC.** For example,
09:00 in UTC+08 is `0 1 * * *`, not `0 8 * * *` (16:00 in UTC+08). Verify the
displayed **Next run** after creation and after timezone/schedule changes.
If your local timezone observes daylight saving, account for that when using
a fixed UTC cron.

Creating the task turns it **On**. Use **Turn off** immediately if you are not
ready for the next scheduled execution. Keep Review mode during validation;
it is human oversight, not a guarantee that every operation pauses. Do not
approve a request for writes or a broader scope merely to complete a report.

## 5. Run now, inspect history, and demonstrate safely

1. In **Scheduled tasks** / **Automation**, select the task and **Run now**.
2. Open the task's execution history, then its **Thread name** link. Check that
   the responder is the dedicated reporter, the scope/windows are correct,
   tools were read-only, and a complete Markdown report was produced.
3. On a healthy environment, expect `Healthy` only when the required evidence
   is present. Accept `Unknown` for genuine coverage gaps; fix access or
   instrumentation separately rather than weakening the reporting rule.
4. To demonstrate degradation, an operator may deliberately run an
   **existing** [break/fix scenario](../README.md#demo-scenarios), then select
   **Run now** again once relevant telemetry is available.
5. After the scenario's existing recovery path or manual fix, run the report
   again. It should distinguish the historical incident from the current
   state. A 15-minute window can still contain failures immediately after
   recovery; record recovery time and latest samples, and rerun after a full
   clean window instead of prematurely declaring it healthy.

> **Controlled chaos, lab only:** break scripts intentionally disrupt the
> application or database and may trigger autonomous incident remediation.
> Run them only when explicitly authorized, with a recovery plan, in the
> intended disposable lab. They are user-initiated demo actions, never part of
> the scheduled prompt or reporting skill. The reporter itself must not inject
> faults or perform recovery. Timing and model outcomes are not guaranteed.

If a run has no thread or fails, inspect the task history and connector/tool
errors; do not report it as successful. The product documents a **Failed**
task status after three consecutive failures. Verify the next scheduled run
as well as **Run now** before relying on daily delivery.

Edit the task to change instructions, responder, time, or run limit; history
is preserved. Use **Turn off** to pause and **Delete** to remove the task when
the trial/demo ends. Remove the dedicated responder separately if no longer
needed. Do not tear down the workload just to stop reporting.

## 6. Optional notifications, only after consent

Keep thread-only reports until the checks and scope are validated. The
repository intentionally does not wire `SendOutlookEmail` into the skill:
adding that tool before interactive OAuth consent can make the skill fail
to load.

For optional delivery, follow the official
[workflow setup](https://learn.microsoft.com/azure/sre-agent/automate-workflows):

1. An interactive operator opens **Builder > Connectors** and connects
   **Office 365 Outlook**, or follows
   [Teams connector setup](https://learn.microsoft.com/azure/sre-agent/set-up-teams-connector).
   Complete sign-in and authorization; verify the connector is **Connected**.
2. Select only the needed send operation. Start with tool **Policy: Ask** and
   use **Parameter policy** to fix the approved recipient/destination where
   supported. Do not let prompts, log content, or discovered addresses choose
   a recipient. Review organization connector and data-sharing policy.
3. Only after consent, create a separate notification custom agent with the
   selected send operation and a fixed destination, but no infrastructure
   tools. Invoke it explicitly with an approved, sanitized report. Keep
   `zava-daily-health-reporter` and its scheduled prompt thread-only:
   `daily-health-report` forbids notifications, so attaching a connector or
   changing task wording does not make delivery part of that skill.
4. Test the notification operation under Review mode and verify both its
   thread and receipt. Ask/Review policies may require approval.

An unattended report-to-notifier workflow is a separate operator-owned
extension, not a handoff implemented by this sample. Review its input handling,
fixed destination, and connector policies before enabling it. Do not promise
scheduled delivery merely because the reporting task and connector exist.

Report generation and tool calls incur SRE Agent usage; log queries,
connectors, and retained output can have additional costs or quotas. Start
with one daily task and a run limit/end date, inspect actual usage, and avoid
duplicate schedules. On retirement, turn off/delete the task, remove or
disconnect unused notification connectors, and revoke their OAuth grants.

No external example repository needs to be indexed by the agent. This lab
also deliberately keeps its own source repository disconnected because the
break scripts and application source expose the scenario answer key. The
runtime skill, environment knowledge, and live telemetry are sufficient
inputs for this workflow; do not upload this operator/demo guide as incident
knowledge.

## Official references

- [Create and edit scheduled tasks](https://learn.microsoft.com/azure/sre-agent/create-scheduled-task)
- [Automate workflows](https://learn.microsoft.com/azure/sre-agent/automate-workflows)
- [Scheduled tasks: settings, history, and run limits](https://learn.microsoft.com/azure/sre-agent/scheduled-tasks)
- [Workflow automation: custom agents, Review mode, and testing](https://learn.microsoft.com/azure/sre-agent/workflow-automation)
