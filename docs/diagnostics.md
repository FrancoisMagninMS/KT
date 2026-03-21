# Diagnostic Settings & Log Analytics

This document explains how the KT infrastructure collects logs and metrics from all Azure resources into a central location, why it matters, and how the system enforces it automatically.

---

## What Are Diagnostic Settings?

Every Azure resource generates **logs** (records of what happened — errors, connections, queries) and **metrics** (numerical measurements — CPU %, memory %, request counts). By default, these stay inside the resource and eventually age out.

**Diagnostic settings** tell Azure to continuously export these logs and metrics to a central destination. In this project, that destination is a **Log Analytics Workspace (LAW)** — a searchable database where you can query data from all your resources in one place using Kusto Query Language (KQL).

### Why This Matters

Without centralized logging:
- You must check each resource individually in the Azure Portal to see its logs
- You can't correlate events (e.g., "did the database slow down at the same time AKS nodes ran out of memory?")
- You can't create alerts that query log data (the KQL-based alerts in [alerts.md](alerts.md) depend on this)
- When something breaks at 3 AM, you have very limited forensic data

With centralized logging:
- One place to search everything
- Alerts can query across resources
- Dashboards can show the full picture
- Compliance teams can audit activity

---

## Architecture Overview

```
┌─────────────────┐
│ Log Analytics    │  ← Central destination for ALL logs and metrics
│ Workspace (LAW) │     law-{project}-{environment}
│ SKU: PerGB2018  │     Retention: var.law_retention_days (default 30 days)
└───────┬─────────┘
        │
        ├──── VNet logs & metrics           (Terraform diagnostic setting)
        ├──── PostgreSQL logs & metrics     (Terraform diagnostic setting)
        ├──── AKS Container Insights        (OMS agent on AKS nodes)
        ├──── AKS resource logs & metrics   (Azure Policy — DeployIfNotExists)
        ├──── ACR logs & metrics            (Azure Policy — DeployIfNotExists)
        └──── Key Vault logs & metrics      (Azure Policy — DeployIfNotExists)
```

---

## How Diagnostic Settings Are Created

There are **three different mechanisms** that create diagnostic settings. This is intentional — it ensures complete coverage.

### 1. Terraform Diagnostic Settings (Explicit)

These are defined directly in Terraform files. They are created during `terraform apply` and managed by Terraform's state.

| Resource | Terraform Resource | Defined In |
|---|---|---|
| VNet | `azurerm_monitor_diagnostic_setting.vnet` | `terraform/log-analytics.tf` |
| PostgreSQL Flexible Server | `azurerm_monitor_diagnostic_setting.postgresql` | `terraform/postgresql.tf` |

Each sends:
- **All log categories** (`category_group = "allLogs"`)
- **All metrics** (`category = "AllMetrics"`)

### 2. Azure Policy (DeployIfNotExists) — Automatic

An Azure Policy automatically creates diagnostic settings on resources that don't already have them. This acts as a safety net — even if someone creates a resource outside of Terraform, or if Terraform doesn't manage diagnostic settings for a resource, the policy will deploy them.

**Policy name**: `enable-diagnostic-settings`  
**Effect**: `DeployIfNotExists` — if a supported resource type lacks a diagnostic setting pointing to the LAW, Azure automatically creates one named `setByPolicy`.

This policy covers these resource types (and more):

| Category | Resources |
|---|---|
| Compute | Virtual Machines |
| Networking | NSGs, Load Balancers, Public IPs, App Gateways, Firewall, VPN Gateways |
| Data | SQL Databases, PostgreSQL, MySQL, Redis, Cosmos DB |
| Containers | AKS, ACR |
| Security | Key Vault |
| Storage | Storage Accounts |
| App Services | Web Apps |
| Integration | Event Hubs, Service Bus, API Management, SignalR |
| AI | Cognitive Services |
| Analytics | Data Factory, Log Analytics Workspaces, Automation Accounts |

**Important**: Because AKS, ACR, and Key Vault diagnostic settings are managed by this policy, Terraform does **not** create separate diagnostic settings for them. This avoids conflicts where Terraform and the policy fight over the same resource.

**Where it's defined**: `terraform/policies.tf` — only created by the `prod` environment (`count = local.manage_policies ? 1 : 0`) to avoid duplicate policy definitions across environments.

### 3. AKS OMS Agent (Container Insights)

The AKS cluster has the OMS (Operations Management Suite) agent enabled:

```hcl
oms_agent {
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id
}
```

This installs a DaemonSet on every AKS node that collects:
- **Container logs** (stdout/stderr from all pods)
- **Container metrics** (CPU, memory, network per container)
- **Kubernetes inventory** (pods, nodes, deployments, services)
- **Kubernetes events** (scheduling, scaling, failures)

This data appears in Log Analytics tables like `ContainerLog`, `KubePodInventory`, `KubeEvents`, `Perf`, and others. The AKS alerts in [alerts.md](alerts.md) query these tables.

---

## The Log Analytics Workspace

| Property | Value |
|---|---|
| Name | `law-{project}-{environment}` (e.g., `law-kt-dev`) |
| SKU | `PerGB2018` (pay-per-GB ingested) |
| Retention | `var.law_retention_days` (default: 30 days) |
| Location | `koreacentral` |
| Terraform resource | `azurerm_log_analytics_workspace.main` in `terraform/log-analytics.tf` |

### Querying Logs

You can query the LAW using **KQL** (Kusto Query Language) in the Azure Portal:

1. Navigate to your Log Analytics Workspace in the Azure Portal
2. Click **Logs** in the left menu
3. Write and run KQL queries

#### Example queries

**See all PostgreSQL errors in the last hour:**
```kql
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.DBFORPOSTGRESQL"
| where Message has_any ("FATAL", "ERROR", "PANIC")
| where TimeGenerated > ago(1h)
| sort by TimeGenerated desc
```

**See all AKS pods that aren't running:**
```kql
KubePodInventory
| where PodStatus !in ("Running", "Succeeded")
| summarize count() by PodStatus, Name, Namespace
| sort by count_ desc
```

**See container crash events in the last 24 hours:**
```kql
KubeEvents
| where Reason == "OOMKilled" or Reason == "BackOff"
| where TimeGenerated > ago(24h)
| project TimeGenerated, Name, Namespace, Reason, Message
| sort by TimeGenerated desc
```

**Check VNet flow logs:**
```kql
AzureDiagnostics
| where ResourceType == "VIRTUALNETWORKS"
| where TimeGenerated > ago(1h)
| sort by TimeGenerated desc
```

---

## Azure Policy: Deny Extra Workspaces

To prevent "workspace sprawl" (multiple teams creating their own Log Analytics Workspaces, splitting data across destinations), a second policy blocks the creation of any LAW that doesn't match the approved naming pattern.

**Policy name**: `deny-extra-law`  
**Effect**: `Deny` — blocks creation of any LAW whose name is not in the allowed list.

**Allowed LAW names**: `law-kt-dev`, `law-kt-test`, `law-kt-qa`, `law-kt-prod`

This ensures all data stays in the one LAW per environment, making queries, alerts, and dashboards work correctly.

---

## Cost Considerations

Log Analytics charges based on **data ingested** (how much log data is sent to the workspace). Key factors:

| Factor | Impact | Recommendation |
|---|---|---|
| Container Insights | Often the largest contributor — every pod's stdout goes here | Set appropriate log levels in your applications; avoid verbose `DEBUG` logging in production |
| Retention period | Data older than 30 days is free to query but costs for storage beyond the retention period | Default 30 days is a good balance; increase only if needed for compliance |
| Diagnostic settings | All-logs/all-metrics can generate significant volume for busy resources | The policy enables everything by default; you can refine to specific categories if cost is a concern |
| Sentinel integration | Not used in this project, but enabling Sentinel adds additional costs | Only enable if you need SIEM capabilities |

### Estimating costs

In the Azure Portal, go to your LAW → **Usage and estimated costs** to see current ingestion rates and monthly projections.

---

## How to Verify Diagnostic Settings Are Working

### For a specific resource

1. Go to the resource in the Azure Portal
2. Navigate to **Monitoring → Diagnostic settings**
3. You should see either a Terraform-managed setting or a `setByPolicy` setting pointing to the LAW

### For the policy

1. Go to **Azure Policy** in the Portal
2. Click **Compliance**
3. Find the `Enable Diagnostic Settings to Log Analytics` policy assignment
4. Check the compliance percentage — non-compliant resources will be remediated automatically

### Check data is flowing

```kql
// Check what tables have data in the last hour
search *
| where TimeGenerated > ago(1h)
| summarize count() by $table
| sort by count_ desc
```

---

## Troubleshooting

### No data in Log Analytics

1. **Check the diagnostic setting exists** on the resource (Portal → resource → Diagnostic settings)
2. **Wait 5-10 minutes** — there's a small delay between when events happen and when they appear in LAW
3. **Check the policy remediation** — go to Policy → Remediation and look for failed tasks
4. **Verify the LAW ID** — the diagnostic setting must point to the correct workspace

### Policy remediation failed

1. Check the policy's managed identity has the required roles: `Monitoring Contributor` and `Log Analytics Contributor`
2. These role assignments are in `terraform/policies.tf`
3. Re-run remediation from Azure Policy → Remediation → Create remediation task

### Duplicate diagnostic settings

If both Terraform and the policy create settings for the same resource, you'll see two entries. The policy creates `setByPolicy`; Terraform creates a named setting (e.g., `pg-diagnostics`). Both send data to the same LAW, which causes duplicate log entries. This is why PostgreSQL and VNet have explicit Terraform settings, while AKS, ACR, and Key Vault rely on the policy.
