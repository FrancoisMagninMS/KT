# Monitoring Alerts

This document explains every alert configured in the KT infrastructure, what triggers it, why it matters, and what to do when it fires.

---

## How Alerts Work in Azure

Azure Monitor **alerts** are automated rules that watch your resources and notify you when something goes wrong. There are two kinds used here:

1. **Metric alerts** — watch numerical measurements (CPU %, memory %, disk %) taken directly from a resource. Fast (1-minute evaluation) and simple.
2. **Log alerts (KQL)** — run a query against log data collected in the Log Analytics Workspace. More flexible — can search log messages, count events, or correlate data across resources.

When an alert fires, it triggers an **Action Group** — a notification channel that sends an email to the configured address (`var.alert_email`).

### Severity Levels

| Severity | Meaning | When Used |
|---|---|---|
| **Sev 0** | Critical | Not used currently — reserved for outages |
| **Sev 1** | Error | Something is broken or very close to breaking (CPU > 80%, storage > 85%, lock waits, OOMKilled) |
| **Sev 2** | Warning | Something needs attention but isn't immediately dangerous (slow queries, high memory, WAL growth) |

### Where to Find Alerts

- **Azure Portal**: Navigate to **Monitor → Alerts** to see fired alerts, or **Monitor → Alert rules** to see all configured rules.
- **Terraform**: All alert definitions live in `terraform/alerts.tf`.

---

## Action Group

All alerts route to a single action group:

| Property | Value |
|---|---|
| Name | `ag-{project}-{environment}` (e.g., `ag-kt-dev`) |
| Short name | `kt-alerts` |
| Notification | Email to the address configured in `var.alert_email` |

To add more notification channels (SMS, webhook, PagerDuty, Teams), edit the `azurerm_monitor_action_group.main` resource in `terraform/alerts.tf`.

---

## PostgreSQL Alerts

### A. Log-Based Alerts (KQL)

These alerts query the `AzureDiagnostics` table in the Log Analytics Workspace. They depend on diagnostic settings being active on the PostgreSQL server (see [diagnostics.md](diagnostics.md)).

#### A1. High Error Rate

| Property | Value |
|---|---|
| Alert name | `pg-high-error-rate` |
| Severity | 1 (Error) |
| Evaluates every | 5 minutes |
| Window | 5 minutes |
| Threshold | > 10 matching log entries |
| Query | Counts log entries containing `FATAL`, `PANIC`, or `ERROR` |

**What it means**: PostgreSQL is generating a high volume of error-level log messages. This could indicate application bugs (bad queries), connection failures, authentication problems, or internal server issues.

**What to do**:
1. Open the Log Analytics Workspace in the Azure Portal
2. Run the KQL query: `AzureDiagnostics | where ResourceProvider == 'MICROSOFT.DBFORPOSTGRESQL' | where Message has_any ('FATAL','PANIC','ERROR') | sort by TimeGenerated desc`
3. Look for patterns — are errors from one application? One query? One user?
4. `FATAL` errors often mean a connection was killed. `PANIC` means the server crashed (very serious). `ERROR` can be a bad SQL query.

---

#### A2. Slow Query Spike

| Property | Value |
|---|---|
| Alert name | `pg-slowquery-spike` |
| Severity | 2 (Warning) |
| Evaluates every | 5 minutes |
| Window | 5 minutes |
| Threshold | > 20 queries with DurationMs > 500 |

**What it means**: Many queries are taking longer than 500 milliseconds. This could indicate missing indexes, table locks, resource contention, or a sudden spike in data volume.

**What to do**:
1. Query the logs: `AzureDiagnostics | where ResourceProvider == 'MICROSOFT.DBFORPOSTGRESQL' | where DurationMs > 500 | sort by DurationMs desc`
2. Identify the slowest queries and check their execution plans (`EXPLAIN ANALYZE`)
3. Look for missing indexes, sequential scans on large tables, or complex joins
4. Check if CPU or memory alerts are also firing — slow queries can be a symptom of resource pressure

---

#### A3. Lock Wait / Blocking

| Property | Value |
|---|---|
| Alert name | `pg-lock-wait` |
| Severity | 1 (Error) |
| Evaluates every | 5 minutes |
| Window | 5 minutes |
| Threshold | > 5 lock-wait entries |

**What it means**: Sessions are waiting to acquire locks on database objects (tables, rows). This usually means one transaction is holding a lock while another transaction needs the same resource.

**What to do**:
1. This is often caused by long-running transactions or `ALTER TABLE` operations running during peak hours
2. Check for stuck transactions: `SELECT * FROM pg_stat_activity WHERE wait_event_type = 'Lock';`
3. Consider whether application code is doing operations in overly large transactions
4. As a last resort, you can terminate blocking sessions: `SELECT pg_terminate_backend(pid);` — but only if you understand what you're killing

---

#### A4. Autovacuum Issues / Table Bloat Risk

| Property | Value |
|---|---|
| Alert name | `pg-autovacuum-issues` |
| Severity | 1 (Error) |
| Evaluates every | 5 minutes |
| Window | 10 minutes |
| Threshold | > 0 (any occurrence) |

**What it means**: PostgreSQL's autovacuum process was either cancelled or detected a "transaction ID wraparound" risk. Both are serious:

- **Autovacuum cancelled**: A conflicting operation (like a DDL statement) interrupted cleanup. Dead row versions accumulate, bloating tables and slowing queries.
- **Wraparound risk**: PostgreSQL uses 32-bit transaction IDs. If autovacuum can't reclaim old transaction IDs, the database will eventually shut down to prevent data loss. This is a well-known PostgreSQL failure mode.

**What to do**:
1. Check autovacuum settings — they may be too conservative for your workload
2. Manually run `VACUUM ANALYZE` on the affected tables
3. For wraparound: ensure autovacuum is not being blocked by long-running transactions
4. This alert should never fire repeatedly — if it does, escalate immediately

---

#### A5. Long Checkpoints (I/O Slowdown)

| Property | Value |
|---|---|
| Alert name | `pg-long-checkpoints` |
| Severity | 2 (Warning) |
| Evaluates every | 5 minutes |
| Window | 10 minutes |
| Threshold | > 0 checkpoints taking more than 10 seconds |

**What it means**: PostgreSQL periodically writes all modified data from memory to disk (a "checkpoint"). If a checkpoint takes more than 10 seconds, it usually means the disk I/O subsystem is under pressure or there's too much data being modified between checkpoints.

**What to do**:
1. Check the PostgreSQL SKU — a larger SKU provides better I/O performance
2. Consider increasing `checkpoint_timeout` or `max_wal_size` to spread writes over a longer period
3. Check if this correlates with CPU/memory alerts — I/O pressure often accompanies resource saturation

---

#### A6. Connection Spike

| Property | Value |
|---|---|
| Alert name | `pg-connection-spike` |
| Severity | 1 (Error) |
| Evaluates every | 5 minutes |
| Window | 5 minutes |
| Threshold | > 200 new connections in 5 minutes |

**What it means**: An unusually large number of new connections are being established. This can indicate an application restart (all instances reconnecting), a connection pool misconfiguration (creating new connections instead of reusing), or a credential rotation event.

**What to do**:
1. Check your application connection pool settings — connections should be reused, not created per request
2. Look for recent deployments that may have caused all pods/instances to restart
3. Cross-reference with the **B4. Connections Near Max** metric alert

---

### B. Metric-Based Alerts

These fire based on real-time metrics from the PostgreSQL Flexible Server itself — no log query required.

#### B1. CPU > 80%

| Property | Value |
|---|---|
| Alert name | `pg-cpu-high` |
| Severity | 1 (Error) |
| Window | 5 minutes |
| Frequency | 1 minute |
| Metric | `cpu_percent` (Average) > 80% |

**What it means**: The database server is running close to its CPU capacity. Queries will slow down, and new connections may be refused.

**What to do**:
1. Identify heavy queries via Log Analytics or `pg_stat_statements`
2. Optimize queries (add indexes, rewrite expensive joins)
3. If the problem is chronic, scale up the PostgreSQL SKU in `variables.tf` (`var.pg_sku`)

---

#### B2. Storage > 85%

| Property | Value |
|---|---|
| Alert name | `pg-storage-high` |
| Severity | 1 (Error) |
| Window | 5 minutes |
| Frequency | 1 minute |
| Metric | `storage_percent` (Average) > 85% |

**What it means**: The database is running out of disk space. If it reaches 100%, writes will fail and the database can become read-only.

**What to do**:
1. Check for table bloat: `SELECT schemaname, tablename, pg_size_pretty(pg_total_relation_size(schemaname || '.' || tablename)) FROM pg_tables ORDER BY pg_total_relation_size(schemaname || '.' || tablename) DESC LIMIT 10;`
2. Run `VACUUM FULL` on bloated tables (caution: this locks the table)
3. Increase `var.pg_storage_mb` in `variables.tf` — Azure PostgreSQL Flexible Server supports online storage expansion
4. Archive or delete old data if applicable

---

#### B3. Memory > 85%

| Property | Value |
|---|---|
| Alert name | `pg-memory-high` |
| Severity | 2 (Warning) |
| Window | 15 minutes |
| Frequency | 1 minute |
| Metric | `memory_percent` (Average) > 85% |

**What it means**: The server is using most of its available RAM. This is a warning — PostgreSQL uses memory for query execution, sorting, caching, and shared buffers. If it runs out, queries will spill to disk (slow) or fail.

**What to do**:
1. Check for memory-hungry queries using `pg_stat_activity`
2. Review `work_mem` and `shared_buffers` server parameters
3. Scale up the SKU for more memory if needed

---

#### B4. Active Connections Near Max (90%)

| Property | Value |
|---|---|
| Alert name | `pg-connections-near-max` |
| Severity | 1 (Error) |
| Window | 5 minutes |
| Frequency | 1 minute |
| Metric | `active_connections` (Average) > 90% of `var.pg_max_connections` |

**What it means**: The number of active connections is approaching the configured maximum (default: 200, threshold: 180). If it reaches the max, new connections will be refused.

**What to do**:
1. Use connection pooling (e.g., PgBouncer) to multiplex application connections
2. Close idle connections — check `pg_stat_activity` for sessions in `idle` state
3. Increase `var.pg_max_connections` if the workload genuinely needs more concurrent connections (requires restart)

---

### C. WAL Alerts

#### C1. WAL Growth Spike

| Property | Value |
|---|---|
| Alert name | `pg-wal-growth-spike` |
| Severity | 2 (Warning) |
| Evaluates every | 5 minutes |
| Window | 10 minutes |
| Threshold | > 50 WAL-related log entries |

**What it means**: Write-Ahead Log (WAL) activity is unusually high. WAL is PostgreSQL's mechanism for ensuring data durability — every change is first written to the WAL before being applied. High WAL activity can indicate bulk data loads, intensive update operations, or replication issues.

**What to do**:
1. Check if a bulk import/ETL job is running
2. Monitor storage consumption — WAL files consume disk space
3. If this coincides with replication lag, check replica health

---

## AKS Alerts

### D1. Node CPU > 80%

| Property | Value |
|---|---|
| Alert name | `aks-node-cpu-high` |
| Severity | 2 (Warning) |
| Window | 5 minutes |
| Frequency | 1 minute |
| Metric | `node_cpu_usage_percentage` (Average) > 80% |

**What it means**: AKS cluster nodes are running hot on CPU. Pods may be throttled or evicted. The Kubernetes scheduler may not be able to place new pods.

**What to do**:
1. Check which pods are consuming the most CPU: `kubectl top pods --all-namespaces --sort-by=cpu`
2. Review pod resource `requests` and `limits` in deployment manifests
3. Scale the node pool (increase `var.aks_node_count`) or use cluster autoscaler  
4. Consider if pods need horizontal scaling (more replicas with lower CPU per pod)

---

### D2. Node Memory > 80%

| Property | Value |
|---|---|
| Alert name | `aks-node-memory-high` |
| Severity | 2 (Warning) |
| Window | 5 minutes |
| Frequency | 1 minute |
| Metric | `node_memory_working_set_percentage` (Average) > 80% |

**What it means**: AKS nodes are using most of their memory. Kubernetes will start evicting pods (OOMKilling the ones over their memory limits) if memory pressure continues.

**What to do**:
1. Check memory consumption: `kubectl top pods --all-namespaces --sort-by=memory`
2. Look for memory leaks in your applications
3. Cross-reference with the **D5. OOMKilled** alert — if pods are being killed, they restart and leak again (restart loop)
4. Scale up node size (`var.aks_vm_size`) or increase node count

---

### D3. Node Disk > 85%

| Property | Value |
|---|---|
| Alert name | `aks-node-disk-high` |
| Severity | 1 (Error) |
| Window | 5 minutes |
| Frequency | 1 minute |
| Metric | `node_disk_usage_percentage` (Average) > 85% |

**What it means**: Node disks are filling up. This can be caused by container images accumulating, log files growing, or persistent volumes running out of space. If disks fill completely, nodes become unhealthy and pods can't run.

**What to do**:
1. Check for unused container images: `kubectl describe node <node-name>` and look at the image list
2. Review log rotation settings — ensure containers aren't writing unbounded logs to disk
3. Delete unused images (AKS garbage collects automatically, but it may lag)
4. If using persistent volumes, check their usage and expand if needed

---

### D4. Pods Not Ready

| Property | Value |
|---|---|
| Alert name | `aks-pods-not-ready` |
| Severity | 1 (Error) |
| Evaluates every | 5 minutes |
| Window | 5 minutes |
| Threshold | > 0 pods in non-Running/Succeeded state |
| Query | `KubePodInventory` filtered by cluster name |

**What it means**: One or more pods are not in a healthy state. They could be in `Pending` (can't be scheduled), `CrashLoopBackOff` (crashing on startup), `ImagePullBackOff` (can't pull container image), or `Failed` state.

**What to do**:
1. List unhealthy pods: `kubectl get pods --all-namespaces | grep -v Running | grep -v Completed`
2. Describe the problem pod: `kubectl describe pod <pod-name> -n <namespace>` — the "Events" section at the bottom usually explains what went wrong
3. Common causes:
   - **Pending**: Not enough CPU/memory on any node to schedule the pod → scale up
   - **ImagePullBackOff**: Wrong image name, missing ACR credentials, or ACR is unreachable
   - **CrashLoopBackOff**: The application is crashing → check logs with `kubectl logs <pod-name>`

---

### D5. OOMKilled Containers

| Property | Value |
|---|---|
| Alert name | `aks-oom-killed` |
| Severity | 1 (Error) |
| Evaluates every | 5 minutes |
| Window | 5 minutes |
| Threshold | > 0 OOMKilled events |
| Query | `KubeEvents` filtered for `OOMKilled` reason |

**What it means**: Kubernetes killed a container because it exceeded its memory limit. The container will be restarted automatically, but if it keeps exceeding the limit, it will enter a `CrashLoopBackOff` cycle.

**What to do**:
1. Identify which containers are being killed: check the KQL query results in Log Analytics
2. Increase the memory `limits` in the deployment manifest (`deployment.yaml`)
3. Investigate why the application is using so much memory — it could be a memory leak
4. Monitor the trend: occasional OOMKills during peak load may be acceptable; constant OOMKills are not

---

## Alert Reference Card

| # | Alert Name | Type | Severity | Target | Threshold |
|---|---|---|---|---|---|
| A1 | `pg-high-error-rate` | Log (KQL) | 1 | PostgreSQL | > 10 FATAL/ERROR/PANIC in 5m |
| A2 | `pg-slowquery-spike` | Log (KQL) | 2 | PostgreSQL | > 20 queries > 500ms in 5m |
| A3 | `pg-lock-wait` | Log (KQL) | 1 | PostgreSQL | > 5 lock-wait events in 5m |
| A4 | `pg-autovacuum-issues` | Log (KQL) | 1 | PostgreSQL | Any autovacuum cancel/wraparound in 10m |
| A5 | `pg-long-checkpoints` | Log (KQL) | 2 | PostgreSQL | Any checkpoint > 10s in 10m |
| A6 | `pg-connection-spike` | Log (KQL) | 1 | PostgreSQL | > 200 new connections in 5m |
| B1 | `pg-cpu-high` | Metric | 1 | PostgreSQL | CPU > 80% avg over 5m |
| B2 | `pg-storage-high` | Metric | 1 | PostgreSQL | Storage > 85% avg over 5m |
| B3 | `pg-memory-high` | Metric | 2 | PostgreSQL | Memory > 85% avg over 15m |
| B4 | `pg-connections-near-max` | Metric | 1 | PostgreSQL | Connections > 90% of max over 5m |
| C1 | `pg-wal-growth-spike` | Log (KQL) | 2 | PostgreSQL | > 50 WAL entries in 10m |
| D1 | `aks-node-cpu-high` | Metric | 2 | AKS | Node CPU > 80% avg over 5m |
| D2 | `aks-node-memory-high` | Metric | 2 | AKS | Node memory > 80% avg over 5m |
| D3 | `aks-node-disk-high` | Metric | 1 | AKS | Node disk > 85% avg over 5m |
| D4 | `aks-pods-not-ready` | Log (KQL) | 1 | AKS | Any non-Running/Succeeded pod in 5m |
| D5 | `aks-oom-killed` | Log (KQL) | 1 | AKS | Any OOMKilled event in 5m |

---

## Customizing Alerts

### Changing the notification email

Set the `ALERT_EMAIL` variable on each GitHub Environment (Settings → Environments → Variables), or change the default in `terraform/variables.tf` under `var.alert_email`.

### Changing thresholds

Edit the `threshold` value in the relevant alert resource in `terraform/alerts.tf`. For the connection threshold (B4), adjust `var.pg_max_connections` in `variables.tf` — the threshold auto-calculates to 90%.

### Adding a new alert

1. Add a new `azurerm_monitor_metric_alert` or `azurerm_monitor_scheduled_query_rules_alert_v2` resource to `terraform/alerts.tf`
2. Set `action` / `action_groups` to `azurerm_monitor_action_group.main.id`
3. Run `terraform plan` to verify, then `terraform apply`
