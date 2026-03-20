# ────────────────────────── core ──────────────────────────────

variable "subscription_id" {
  type        = string
  description = "Target Azure subscription ID"
}

variable "location" {
  type        = string
  default     = "koreacentral"
  description = "Azure region for all resources"
}

variable "environment" {
  type        = string
  default     = "prod"
  description = "Environment name (dev, uat, prod)"
}

variable "project" {
  type        = string
  default     = "kt"
  description = "Project name used in resource naming"
}

# ────────────────────────── networking ────────────────────────

variable "vnet_address_space" {
  type        = list(string)
  default     = ["10.0.0.0/16"]
  description = "VNet address space"
}

variable "aks_subnet_prefix" {
  type        = string
  default     = "10.0.0.0/22"
  description = "AKS node subnet CIDR (min /22 recommended)"
}

variable "aca_subnet_prefix" {
  type        = string
  default     = "10.0.4.0/23"
  description = "ACA environment subnet CIDR (min /23 required)"
}

variable "pg_subnet_prefix" {
  type        = string
  default     = "10.0.6.0/24"
  description = "PostgreSQL delegated subnet CIDR"
}

# ────────────────────────── AKS ──────────────────────────────

variable "aks_node_count" {
  type        = number
  default     = 3
  description = "Number of AKS nodes in the default pool"
}

variable "aks_vm_size" {
  type        = string
  default     = "Standard_D4s_v5"
  description = "VM size for AKS nodes"
}

variable "kubernetes_version" {
  type        = string
  default     = "1.32"
  description = "Kubernetes version"
}

# ────────────────────────── PostgreSQL ────────────────────────

variable "pg_sku" {
  type        = string
  default     = "GP_Standard_D2s_v3"
  description = "PostgreSQL Flexible Server SKU"
}

variable "pg_storage_mb" {
  type        = number
  default     = 32768
  description = "PostgreSQL storage in MB"
}

variable "pg_version" {
  type        = string
  default     = "16"
  description = "PostgreSQL major version"
}

variable "pg_admin_login" {
  type        = string
  default     = "pgadmin"
  description = "PostgreSQL administrator login name"
}

variable "pg_admin_password" {
  type        = string
  sensitive   = true
  description = "PostgreSQL administrator password (provide via TF_VAR_pg_admin_password or GitHub Secret)"
}

variable "pg_max_connections" {
  type        = number
  default     = 200
  description = "PostgreSQL max_connections server parameter (used for alert threshold calculation)"
}

# ────────────────────────── Log Analytics ─────────────────────

variable "law_retention_days" {
  type        = number
  default     = 30
  description = "Log Analytics Workspace retention in days"
}

# ────────────────────────── ACR ───────────────────────────────

variable "acr_sku" {
  type        = string
  default     = "Standard"
  description = "Azure Container Registry SKU (Basic, Standard, Premium)"
}

# ────────────────────────── alerts ────────────────────────────

variable "alert_email" {
  type        = string
  default     = "frmagnin@microsoft.com"
  description = "Email address for alert notifications"
}
