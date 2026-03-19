locals {
  pg_conn_threshold = var.pg_max_connections * 90 / 100
}

###############################################################################
# Action Group
###############################################################################

resource "azurerm_monitor_action_group" "main" {
  name                = "ag-${var.project}-${var.environment}"
  resource_group_name = azurerm_resource_group.main.name
  short_name          = "kt-alerts"

  email_receiver {
    name          = "primary"
    email_address = var.alert_email
  }
}

###############################################################################
# A. LOG ALERTS (KQL-based) — against PostgreSQLLogs in LAW
###############################################################################

# A1. High Error Rate (FATAL/ERROR/PANIC)
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "pg_high_error_rate" {
  name                = "pg-high-error-rate"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  description         = "High rate of FATAL/ERROR/PANIC log entries on PostgreSQL"
  severity            = 1
  evaluation_frequency = "PT5M"
  window_duration      = "PT5M"
  scopes               = [azurerm_log_analytics_workspace.main.id]

  criteria {
    query                   = "PostgreSQLLogs | where LogLevel in ('FATAL','PANIC','ERROR')"
    time_aggregation_method = "Count"
    operator                = "GreaterThan"
    threshold               = 10
  }

  action {
    action_groups = [azurerm_monitor_action_group.main.id]
  }

  depends_on = [azurerm_monitor_diagnostic_setting.postgresql]
}

# A2. Slow Query Spike
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "pg_slowquery_spike" {
  name                = "pg-slowquery-spike"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  description         = "High volume of slow queries (DurationMs > 500)"
  severity            = 2
  evaluation_frequency = "PT5M"
  window_duration      = "PT5M"
  scopes               = [azurerm_log_analytics_workspace.main.id]

  criteria {
    query                   = "PostgreSQLLogs | where DurationMs > 500"
    time_aggregation_method = "Count"
    operator                = "GreaterThan"
    threshold               = 20
  }

  action {
    action_groups = [azurerm_monitor_action_group.main.id]
  }

  depends_on = [azurerm_monitor_diagnostic_setting.postgresql]
}

# A3. Lock Wait / Blocking
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "pg_lock_wait" {
  name                = "pg-lock-wait"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  description         = "Excessive lock waits / blocked sessions on PostgreSQL"
  severity            = 1
  evaluation_frequency = "PT5M"
  window_duration      = "PT5M"
  scopes               = [azurerm_log_analytics_workspace.main.id]

  criteria {
    query                   = "PostgreSQLLogs | where (Message contains 'lock' or LogLevel == 'WARNING') and Message contains 'waiting'"
    time_aggregation_method = "Count"
    operator                = "GreaterThan"
    threshold               = 5
  }

  action {
    action_groups = [azurerm_monitor_action_group.main.id]
  }

  depends_on = [azurerm_monitor_diagnostic_setting.postgresql]
}

# A4. Autovacuum Issues / Table Bloat Risk
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "pg_autovacuum_issues" {
  name                = "pg-autovacuum-issues"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  description         = "Autovacuum cancelled or wraparound risk on PostgreSQL"
  severity            = 1
  evaluation_frequency = "PT5M"
  window_duration      = "PT10M"
  scopes               = [azurerm_log_analytics_workspace.main.id]

  criteria {
    query                   = "PostgreSQLLogs | where Message contains 'autovacuum' and (Message contains 'cancelled' or Message contains 'wraparound')"
    time_aggregation_method = "Count"
    operator                = "GreaterThan"
    threshold               = 0
  }

  action {
    action_groups = [azurerm_monitor_action_group.main.id]
  }

  depends_on = [azurerm_monitor_diagnostic_setting.postgresql]
}

# A5. Checkpoint or IO Slowdown
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "pg_long_checkpoints" {
  name                = "pg-long-checkpoints"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  description         = "Long checkpoints detected (DurationMs > 10000) on PostgreSQL"
  severity            = 2
  evaluation_frequency = "PT5M"
  window_duration      = "PT10M"
  scopes               = [azurerm_log_analytics_workspace.main.id]

  criteria {
    query                   = "PostgreSQLLogs | where Message contains 'checkpoint' and DurationMs > 10000"
    time_aggregation_method = "Count"
    operator                = "GreaterThan"
    threshold               = 0
  }

  action {
    action_groups = [azurerm_monitor_action_group.main.id]
  }

  depends_on = [azurerm_monitor_diagnostic_setting.postgresql]
}

# A6. Connection Spike / Connection Exhaustion
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "pg_connection_spike" {
  name                = "pg-connection-spike"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  description         = "Connection spike detected on PostgreSQL (> 200 new connections in 5 min)"
  severity            = 1
  evaluation_frequency = "PT5M"
  window_duration      = "PT5M"
  scopes               = [azurerm_log_analytics_workspace.main.id]

  criteria {
    query                   = "PostgreSQLLogs | where Message contains 'connection authorized'"
    time_aggregation_method = "Count"
    operator                = "GreaterThan"
    threshold               = 200
  }

  action {
    action_groups = [azurerm_monitor_action_group.main.id]
  }

  depends_on = [azurerm_monitor_diagnostic_setting.postgresql]
}

###############################################################################
# B. METRIC ALERTS
###############################################################################

# B1. CPU > 80%
resource "azurerm_monitor_metric_alert" "pg_cpu_high" {
  name                = "pg-cpu-high"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_postgresql_flexible_server.main.id]
  description         = "High CPU on PostgreSQL Flexible Server"
  severity            = 1
  window_size         = "PT5M"
  frequency           = "PT1M"

  criteria {
    metric_namespace = "Microsoft.DBforPostgreSQL/flexibleServers"
    metric_name      = "cpu_percent"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 80
  }

  action {
    action_group_id = azurerm_monitor_action_group.main.id
  }
}

# B2. Storage > 85%
resource "azurerm_monitor_metric_alert" "pg_storage_high" {
  name                = "pg-storage-high"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_postgresql_flexible_server.main.id]
  description         = "Critical storage consumption on PostgreSQL Flexible Server"
  severity            = 1
  window_size         = "PT5M"
  frequency           = "PT1M"

  criteria {
    metric_namespace = "Microsoft.DBforPostgreSQL/flexibleServers"
    metric_name      = "storage_percent"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 85
  }

  action {
    action_group_id = azurerm_monitor_action_group.main.id
  }
}

# B3. Memory > 85%
resource "azurerm_monitor_metric_alert" "pg_memory_high" {
  name                = "pg-memory-high"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_postgresql_flexible_server.main.id]
  description         = "High memory pressure on PostgreSQL Flexible Server"
  severity            = 2
  window_size         = "PT10M"
  frequency           = "PT1M"

  criteria {
    metric_namespace = "Microsoft.DBforPostgreSQL/flexibleServers"
    metric_name      = "memory_percent"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 85
  }

  action {
    action_group_id = azurerm_monitor_action_group.main.id
  }
}

# B4. Active Connections Near Max (90%)
resource "azurerm_monitor_metric_alert" "pg_connections_near_max" {
  name                = "pg-connections-near-max"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_postgresql_flexible_server.main.id]
  description         = "Active connections approaching max_connections on PostgreSQL (90% of ${var.pg_max_connections})"
  severity            = 1
  window_size         = "PT5M"
  frequency           = "PT1M"

  criteria {
    metric_namespace = "Microsoft.DBforPostgreSQL/flexibleServers"
    metric_name      = "active_connections"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = local.pg_conn_threshold
  }

  action {
    action_group_id = azurerm_monitor_action_group.main.id
  }
}

###############################################################################
# C. REPLICATION & WAL ALERTS
###############################################################################

# C1a. Read Replica Lag — Warning (> 5s)
resource "azurerm_monitor_metric_alert" "pg_replica_lag_warning" {
  name                = "pg-replica-lag-warning"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_postgresql_flexible_server.main.id]
  description         = "Read replica lag exceeds 5 seconds (Warning)"
  severity            = 2
  window_size         = "PT10M"
  frequency           = "PT1M"

  criteria {
    metric_namespace = "Microsoft.DBforPostgreSQL/flexibleServers"
    metric_name      = "read_replica_lag"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 5
  }

  action {
    action_group_id = azurerm_monitor_action_group.main.id
  }
}

# C1b. Read Replica Lag — Critical (> 30s)
resource "azurerm_monitor_metric_alert" "pg_replica_lag_critical" {
  name                = "pg-replica-lag-critical"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_postgresql_flexible_server.main.id]
  description         = "Read replica lag exceeds 30 seconds (Critical)"
  severity            = 1
  window_size         = "PT10M"
  frequency           = "PT1M"

  criteria {
    metric_namespace = "Microsoft.DBforPostgreSQL/flexibleServers"
    metric_name      = "read_replica_lag"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 30
  }

  action {
    action_group_id = azurerm_monitor_action_group.main.id
  }
}

# C2. Physical Replication Lag (> 50 MB)
resource "azurerm_monitor_metric_alert" "pg_physical_replication_lag" {
  name                = "pg-physical-replication-lag"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_postgresql_flexible_server.main.id]
  description         = "Physical replication lag exceeds 50 MB on PostgreSQL"
  severity            = 2
  window_size         = "PT10M"
  frequency           = "PT1M"

  criteria {
    metric_namespace = "Microsoft.DBforPostgreSQL/flexibleServers"
    metric_name      = "physical_replication_lag_bytes"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 52428800
  }

  action {
    action_group_id = azurerm_monitor_action_group.main.id
  }
}

# C3. WAL Growth Spike (Log-based)
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "pg_wal_growth_spike" {
  name                = "pg-wal-growth-spike"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  description         = "Unusual WAL activity spike on PostgreSQL"
  severity            = 2
  evaluation_frequency = "PT5M"
  window_duration      = "PT10M"
  scopes               = [azurerm_log_analytics_workspace.main.id]

  criteria {
    query                   = "PostgreSQLLogs | where Message contains 'WAL'"
    time_aggregation_method = "Count"
    operator                = "GreaterThan"
    threshold               = 50
  }

  action {
    action_groups = [azurerm_monitor_action_group.main.id]
  }

  depends_on = [azurerm_monitor_diagnostic_setting.postgresql]
}
