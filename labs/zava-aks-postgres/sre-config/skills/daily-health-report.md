## Daily health report (Zava)

Always return a Markdown digest, including when everything is healthy or every
query fails. Never complete silently. This is a separate reporting workflow, not
`proactive-health-check`: do not run that skill or change its 15-minute,
silent-when-healthy, remediation-capable behavior.

Resource Group `@@RG@@`; private AKS namespace `zava-demo`; deployments
`zava-api` and `zava-storefront`; PostgreSQL Flexible Server dependency.
Filter every application telemetry query by `AppRoleName == 'zava-api'`.

### 1. Reporting-only boundaries

- Use only `RunAzCliReadCommands`, `RunKubectlReadCommand`, and `SearchMemory`.
  Use memory to find Zava resource names and telemetry conventions, not as live
  evidence or authority to perform the incident runbooks' write operations.
- No writes, remediation, incident modification, handoffs, or delegation.
  Do not load other skills, launch subagents, or follow global incident
  instructions to investigate in parallel or select a remediation. Collect
  evidence in this reporting thread and suggest follow-ups for a human only.
- No `RunAzCliWriteCommands`, `RunKubectlWriteCommand`, generic code execution,
  SQL execution (including SELECT), `kubectl exec`, `az aks command invoke`,
  credential retrieval, secret reads, notifications, or consent-based connectors.
  Do not create or change schedules, tasks, alerts, agent configuration, or RBAC.
- Azure CLI calls must be individual read commands; `az rest` must use GET.
  No shell pipes or command chaining. KQL pipes inside the quoted query are
  query syntax, not shell pipes. Never bypass a denied/unavailable read with a
  write tool or a different execution surface. Record the gap and continue with
  independent permitted reads; always return the partial report.
- The portal task must use a dedicated custom agent selecting ONLY this skill
  and these read tools, in Review mode. Skill/tool selection and instructions
  are not a separate RBAC boundary: the existing agent identity can have broader
  permissions. This workflow neither changes nor claims to restrict that RBAC.

### 2. Freeze the scope and assess coverage

Record report generation time and freeze one UTC end time T for all queries.
Use half-open windows: previous 24 hours [T-24h, T), current last 15 minutes
[T-15m, T). State UTC explicitly; show the configured schedule timezone
separately if supplied, otherwise say "schedule timezone not supplied".
Do not substitute calendar-day or moving `ago()` windows across calls.

Discover the AKS cluster, PostgreSQL server, App Insights resource and its linked
Log Analytics workspace in `@@RG@@`, using memory plus scoped Azure reads:
`az resource list -g @@RG@@ -o json`. Resolve resource IDs and workspace customer
ID before querying; if several candidates exist, use their actual links rather
than choosing the first. Constrain application telemetry by the discovered App
Insights `_ResourceId` as well as role, including in a shared workspace. Replace
the resource-ID placeholder below with that ID, not the workspace ID.

Use `az monitor log-analytics query --workspace <workspace-customer-id>
--analytics-query "<KQL>" --timespan <window-start-utc>/<window-end-utc> -o json`
through the Azure read tool. Replace KQL time placeholders with those same UTC
timestamps. Run each table query separately so a missing optional table cannot
hide other evidence. Do not install CLI extensions or execute local code.

For every source record the query/command reference, execution time, requested
window, first/last observation, observed row count, coverage and any denial,
error, truncation or pagination gap. For telemetry also record latest event time
and ingestion time/lag when available. Last observation older than 5 minutes at
T is stale for current health when offered as positive current evidence. This
guard applies to expected request/dependency/metric samples, not the arrival of
sparse error or change events. An old error is historical, not proof that its
pipeline stopped. This is a reporting freshness guardrail, not an Azure alert
threshold. Null ingestion time means ingestion freshness is unknown.
Distinguish missing telemetry from an observed failing service.

Minimum reporting-confidence guardrails, not alert definitions:
- For an endpoint's current health require at least 20 observed request samples
  in the last 15 minutes and a fresh last observation. Show smaller samples but
  label their performance assessment Unknown.
- For a full-day endpoint assessment require at least 100 observed samples
  spanning at least 20 hourly buckets. Otherwise report only the observed portion
  with Unknown coverage; never fill empty buckets with successful requests.
- A baseline is optional: only compare the preceding 24 hours [T-48h, T-24h)
  when both day windows meet the same sample/coverage guards, the current
  endpoint data is sufficient and fresh, and endpoint/instrumentation scope is
  comparable. State counts, coverage and baseline window with any delta.
  High-volume tables retain only 4 days: never request a 7-day baseline.
  If unsuitable, state "baseline unavailable" and give the reason.

### 3. API traffic, errors and products latency

Run the following query separately for the 24-hour and 15-minute windows.
It returns both the non-probe API aggregate and each endpoint, so high-volume
health/live requests cannot dilute products latency. Never combine all products
routes into one performance number. Preserve each category endpoint.

```kusto
let WindowStart = datetime(<window-start-utc>);
let WindowEnd = datetime(<window-end-utc>);
let R = materialize(
    AppRequests
    | where TimeGenerated >= WindowStart and TimeGenerated < WindowEnd
    | where AppRoleName == 'zava-api'
    | where _ResourceId =~ '<app-insights-resource-id>'
    | extend Path = tostring(parse_url(Url).Path), IngestedAt = ingestion_time()
    | extend Path = iff(isempty(Path), extract(@"^[A-Z]+\s+([^?\s]+)", 1, Name), Path)
    | where Path startswith '/api/'
    | where Path !in ('/api/health', '/api/health/', '/livez', '/health', '/healthz', '/readyz')
    | where Path !contains '__probe' and Name !contains '__probe'
    | extend Weight = tolong(iff(isnull(ItemCount) or ItemCount < 1, 1, ItemCount)),
             Code = toint(ResultCode)
);
union (R | extend Endpoint = Name), (R | extend Endpoint = 'ALL non-probe /api/*')
| summarize Samples = count(), Requests = sum(Weight),
            Http5xx = sumif(Weight, Code between (500 .. 599)),
            UnknownCodes = sumif(Weight, isnull(Code) or Code < 100 or Code > 599),
            DurationWeight = sumif(Weight, DurationMs >= 0),
            DurationTotal = sumif(DurationMs * Weight, DurationMs >= 0),
            P95Ms = percentilew(iff(DurationMs >= 0, DurationMs, real(null)), Weight, 95),
            FirstSeen = min(TimeGenerated), LastSeen = max(TimeGenerated),
            LastIngested = max(IngestedAt),
            ObservedHours = dcount(bin(TimeGenerated, 1h))
    by Endpoint
| extend Http5xxPct = iff(Requests > 0, 100.0 * Http5xx / Requests, real(null)),
         AvgMs = iff(DurationWeight > 0, DurationTotal / DurationWeight, real(null))
| order by Endpoint asc
```

Report raw Samples and ItemCount-weighted Requests, 5xx count/rate, avg/p95 in
milliseconds and the last timestamp. Sampling makes weighted counts estimates;
do not represent them as exact unsampled traffic. The 5xx numerator is HTTP
500..599, not every `Success == false`, and the denominator is all requests in
the same scope/window. A zero denominator means Unknown, never 0% errors or
100% availability. Unknown status codes or incomplete duration samples make the
respective assessment Unknown. Do not label `100 - 5xx%` a success rate.
Show per-endpoint products values alongside the aggregate error rate.

The app self-probes `/api/products` as well as `/api/health`, `/livez`, and
`/api/products/category/__probe`. Path filtering removes explicit probe routes,
but `/api/products` can still mix synthetic and user traffic. Label that mix;
never claim the remaining traffic is proven human traffic or use it to infer
category coverage. Inspect `SyntheticSource` if populated and document any
additional exclusion rather than assuming all synthetic calls are tagged.
Query excluded health/live/probe routes separately for freshness/connectivity;
never merge those counts into the non-probe API rate or latency.

### 4. PostgreSQL connectivity and current state

Read the discovered server with
`az postgres flexible-server show -g @@RG@@ -n <server> --query
"{id:id,state:state,host:fullyQualifiedDomainName}" -o json`.
Record state and retrieval timestamp. `Ready` proves control-plane state, not
app-to-database connectivity; `Stopped` is positive evidence needing attention.
An unknown state or denied read is Unknown, not Ready.

Query `AppDependencies` separately for both windows, with the same time bounds,
role and App Insights resource-ID filters. Group by `Target`, `DependencyType`,
and `ResultCode`; report
observed samples, ItemCount-weighted calls and failures (`Success == false`),
unknown outcomes, avg/p95 duration and first/last timestamps. Identify PostgreSQL
targets from the discovered host and observed dependency type, not arbitrary
string assumptions. Keep localhost/app HTTP dependencies separate. Never treat
all failed dependencies as database failures or expose SQL text/credentials.

Query `AppTraces` for the same bounds, role and resource ID, `SeverityLevel >= 3`, matching
Message or Properties against `ECONNREFUSED`, `ETIMEDOUT`, `connection refused`,
`timeout exceeded when trying to connect`, `connection timeout`, and
`connection terminated`. Report counts and first/last times without dumping
sensitive log payloads. If `AppExceptions` exists, use its available schema to
corroborate those failures, again filtered by role, resource ID and time.

Read separate `/api/health` request counts/result codes and recent successful
PostgreSQL dependencies to corroborate actual connectivity. `/api/health`
includes a DB ping; `/livez` is shallow liveness and cannot prove DB recovery.
Absence of warn/error traces is not proof of connectivity, nor inherently an
outage: this application emits only warn/error application logs. If positive,
fresh connectivity evidence is absent or dependency instrumentation is missing,
connectivity is Unknown even when the server and pods are Ready.

Read PostgreSQL platform metrics for both windows with
`az monitor metrics list --resource <postgres-resource-id> --metric
cpu_percent memory_percent active_connections --start-time <window-start-utc>
--end-time <window-end-utc> --interval PT5M --aggregation Average Maximum -o json`.
Include timestamps/coverage; only query supported metrics. Missing metrics are
gaps, not zeros. High latency with successful DB calls plus CPU evidence may
support a performance concern, but does not prove a missing index or root cause.
Do not invoke the in-cluster SQL helper, even for diagnostic reads.

### 5. Private AKS current state and retained history

Use only the built-in Kubernetes read tool against the discovered private
cluster. Do not set up terminal-native kubectl, obtain kubeconfig, open a socket,
or fall back to ARM command execution when access fails.

- Read pods in `zava-demo`: phase, readiness, waiting reasons, current/last
  termination reasons and timestamps, and each container's restartCount.
  Inspect `OOMKilled`, CrashLoopBackOff, pending/unschedulable and failed pods.
  Request metadata/status only, not secret values or environment contents.
- Read nodes: Ready condition, pressure conditions, schedulability and relevant
  timestamps. Node reads are cluster-scoped infrastructure evidence; workload
  reads stay in `zava-demo`. Node Ready alone does not establish API health.
- Read `zava-api` and `zava-storefront` deployment replica/availability status,
  ReplicaSet revisions and creation times, and relevant namespace events.
  Use these to record recent rollouts and compare their times with errors.
- Restart counters are since container/pod creation, not "restarts in 24h".
  Give lifetime counts with pod creation/termination timestamps. Only claim a
  window delta when retained snapshots/events actually establish it.
  Deleted pods, old OOMs and events may no longer be retained.
- Do not assume Container Insights or `KubePodInventory`, `KubeEvents` or
  `ContainerLogV2` exists. Current Kubernetes reads are primary. If historical
  tables are available, verify schema and scope by cluster ID/namespace before
  querying them; otherwise label historical AKS coverage Unknown.

### 6. Alerts, changes and resource health

Through the Azure read tool, inventory scoped scheduled-query and metric rules:

`az rest --method get --url "https://management.azure.com/subscriptions/<sub>/resourceGroups/@@RG@@/providers/microsoft.insights/scheduledQueryRules?api-version=2023-03-15-preview" -o json`

`az monitor metrics alert list -g @@RG@@ -o json`

Read fired/recovered history and current fired alerts separately. Use an
explicit 30-day alert inventory lookback, not the API's default one day, to
include incidents that started earlier but remained active or recovered during
the report day. This is alert inventory, not a telemetry baseline:

`az rest --method get --url "https://management.azure.com/subscriptions/<sub>/providers/Microsoft.AlertsManagement/alerts?api-version=2019-05-05-preview&timeRange=30d&pageCount=250" -o json`

`az rest --method get --url "https://management.azure.com/subscriptions/<sub>/providers/Microsoft.AlertsManagement/alerts?api-version=2019-05-05-preview&monitorCondition=Fired&timeRange=30d&pageCount=250" -o json`

Follow continuation links with GET and explicitly record the bounded lookback:
it cannot rule out older incidents outside the API's returned history. Record
any other service time-range limit or incomplete inventory. Filter to `@@RG@@` using targetResourceGroup,
alertRule ID and scoped target IDs; log-alert targets may be the shared workspace.
For the daily history use start/resolution/modified timestamps to identify
overlap with [T-24h, T), not merely the service's relative time filter. Include
severity, monitor condition, incident lifecycle state, target, rule ID, onset,
resolution and last modification when returned. Acknowledged/Closed is not the
same as telemetry recovery; Resolved is not proof of current health.

Preserve the monitored alert semantics, not invented daily thresholds:

| Rule | Repository definition (verify the deployed rule) |
| --- | --- |
| `Zava-http-5xx-errors` | More than 5 raw AppRequests rows with `Success == false` and `toint(ResultCode) >= 500` in a 5-minute window |
| `postgres-unreachable` | More than 3 matching error AppTraces rows in a 5-minute window |
| `Zava-products-query-slow` | Any `GET /api/products/category/` endpoint excluding `__probe` with unweighted avg DurationMs > 30 in a 5-minute window |

All three dispatching rules evaluate every 5 minutes with a 5-minute window.
Daily totals, weighted counts, 15-minute rates, and p95 are descriptive report
metrics, not those alert criteria. Never compare a 24-hour error count to a
5-minute threshold or claim a rule fired from a daily aggregate. When checking a
reported breach, use its actual query, evaluation window and observed alert
history. A 5-minute-binned trend approximates, but does not reproduce, evaluation
boundaries. Inventory disabled rules too; `Zava-db-cpu-saturation` is disabled by
default, not proof that CPU is normal. Note rule drift without changing rules.

Read resource-group Activity Log for the exact day window, relevant ARM
deployment records, and the Kubernetes rollout evidence above. Distinguish
successful, failed and in-progress operations and retained-history limits.
Query per-resource health:

`az rest --method get --url "https://management.azure.com/subscriptions/<sub>/resourceGroups/@@RG@@/providers/Microsoft.ResourceHealth/availabilityStatuses?api-version=2023-07-01-preview" -o json`

For relevant service context query subscription Service Health:

`az rest --method get --url "https://management.azure.com/subscriptions/<sub>/providers/Microsoft.ResourceHealth/events?api-version=2022-10-01&queryStartTime=<window-start-utc>" -o json`

Match returned events to actual resources/regions/services and their impact
windows. Unsupported resource health, an empty response or denied access is
Unknown coverage, not "all resources healthy". No matching events in a successful,
complete inventory means only "no relevant events observed".

Compare any incident window with current 15-minute evidence per endpoint and
dependency target. Report "recovered" only with fresh, sufficient recovery
evidence; otherwise say "recovery unverified". Do not turn a quiet telemetry
window into a spurious outage. Timing alone never proves causation: no invented
baselines, correlations or root causes. Keep independent symptoms separate.

### 7. Always publish this Markdown digest

Use only these health assessments: **Healthy**, **Needs attention**, **Unknown**.
Assign each check a day-window and current assessment. Confirmed problems or a
relevant incident in the day require Needs attention for that window, even if
now recovered. If no problem is confirmed but required evidence is missing,
denied, stale, sparse or there is no traffic, use Unknown, not Healthy.
Healthy requires sufficient fresh evidence for that check; it never means
guaranteed availability. Overall assessment is Needs attention if any required
check has a confirmed problem, otherwise Unknown if any required check is
Unknown, otherwise Healthy. Keep the current assessment separate from history.

Always include:

1. **Daily Zava health digest**: overall and current assessments, generated-at
   UTC, resource group `@@RG@@`, cluster/namespace, PostgreSQL server, workspace,
   the exact 24-hour/current windows and schedule timezone.
2. **Executive summary**: observed impact, active or recovered concerns and
   uncertainty. Explicitly say when no concerns were observed within coverage.
3. **Evidence table**: check | day status/value | current status/value |
   observation timestamp/freshness | query reference. Cover API 5xx counts and
   denominators, each products endpoint avg/p95, DB connectivity/state/metrics,
   pods/nodes/restarts/OOMs, alerts, deployments and resource health.
4. **Incidents and changes**: event/evidence timeline, current comparison,
   verified versus unverified recovery and any supported relationships.
5. **Coverage and gaps**: sample counts, covered hours, source/event/ingestion
   freshness, mixed synthetic traffic, missing/denied/stale data, pagination and
   history limits, and baseline used or unavailable with reason.
6. **Top follow-ups**: up to three evidence-backed checks for a human, in
   priority order. If none, say "No follow-ups indicated by available evidence".
   Do not execute them, assign a remediation agent, or modify an incident.
7. **Evidence references**: compact query/command identifiers with resource
   scope, absolute time bounds, execution/observation timestamps and errors.
   Include query text or returned portal links when useful; never invent links.

End with "Read-only report. No resources or incidents were changed." Deliver in
the task/thread output only; do not send email, chat notifications or webhooks.
