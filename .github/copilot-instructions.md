# Project Guidelines

## Overview

Azure infrastructure-as-code project deploying AKS, ACA, PostgreSQL Flexible Server, ACR, Key Vault, and networking resources to the **koreacentral** region using Terraform and GitHub Actions.

## Architecture

- **Terraform** (`terraform/`): All infrastructure definitions — one resource type per file (e.g., `aks.tf`, `aca.tf`, `networking.tf`)
- **Scripts** (`scripts/`): PowerShell utility scripts for Azure and GitHub setup
- **Workflows** (`.github/workflows/`): GitHub Actions CI/CD with `workflow_dispatch`
- **Target region**: `koreacentral` — always verify resource/SKU/version availability in this region before proposing changes

## Terraform Conventions

- **Provider**: `azurerm >= 3.80`, Terraform `>= 1.5`, deployed via Terraform 1.10.3 in CI
- **Backend**: Azure Storage with Azure AD auth (`use_azuread_auth=true`); backend config is passed via `-backend-config` flags in the workflow, not hardcoded
- **Naming**: `{resource-prefix}-{var.project}-{var.environment}` (e.g., `aks-kt-prod`, `vnet-kt-prod`). ACR and Key Vault append `random_string.suffix.result` for global uniqueness
- **Variables**: Define in `variables.tf` with type, default (when sensible), and description. Sensitive values use `sensitive = true` and are injected via `TF_VAR_*` env vars from GitHub Secrets
- **File organization**: One `.tf` file per resource domain — don't combine unrelated resources. Use section headers with `# ───── section ─────` comments
- **Identity**: User-assigned managed identities for AKS and ACA; RBAC role assignments in the relevant resource files (e.g., ACR pull roles in `acr.tf`)
- **Diagnostics**: All resources should send logs/metrics to the single Log Analytics Workspace (`azurerm_log_analytics_workspace.main`)

## AKS Specifics

- Version 1.31 and 1.30 are **LTS-only** in koreacentral — use 1.32+ or verify with `az aks get-versions --location koreacentral`
- Uses Azure CNI with user-assigned identity for the control plane and kubelet
- OMS agent enabled for Container Insights

## PostgreSQL Specifics

- Flexible Server with private VNet integration (`public_network_access_enabled = false`)
- Diagnostic logs go to `AzureDiagnostics` table (not `PostgreSQLLogs`)
- The `errorLevel_s` column does **not** exist; use `Message has_any(...)` or `Message contains` in KQL queries
- Replication metrics (`read_replica_lag`, `physical_replication_lag_in_seconds`) only exist when read replicas are configured

## Alerts

- All alerts use a single `azurerm_monitor_action_group` with email receiver
- KQL scheduled query alerts target the LAW; metric alerts target the resource directly
- Valid `window_size` / `window_duration` values: PT1M, PT5M, PT10M, PT15M, PT30M, PT1H, PT6H, PT12H, PT1D

## Scripts

- All scripts are **PowerShell** (`.ps1`), not Bash — this is a Windows-first project
- Use full cmdlet names (e.g., `Get-ChildItem` not `ls`)

## GitHub Actions Workflow

- Environment: `DEV` (secrets/variables are scoped to this environment)
- Secrets (`AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, `AZURE_SUBSCRIPTION_ID`, `AZURE_TENANT_ID`, `PG_ADMIN_PASSWORD`) must be set as environment-level secrets, not repository-level
- Variables (`ALERT_EMAIL`) are set at the environment level
- `ARM_*` env vars must be defined at the **job** level (not workflow level) to access environment-scoped secrets

## Pipeline Security

- **Least-privilege SP**: The service principal should have only the roles it needs (Contributor, User Access Administrator, Storage Blob Data Contributor). Never grant Owner
- **No secrets in logs**: Never `echo` or print secret values. Use `::add-mask::` for any dynamically-derived sensitive values. The `Debug env vars` step must only check set/unset — never print values
- **Pin action versions**: Always pin GitHub Actions to a major tag (`@v4`, `@v3`), or to a full SHA for third-party actions. Never use `@latest` or `@main`
- **Credential rotation**: SP credentials are limited to 30 days by Azure AD policy. Plan for rotation and never hardcode credentials in files
- **Backend security**: Terraform state contains sensitive data. The backend storage account must have `allow-blob-public-access false`, `min-tls-version TLS1_2`, and Azure AD auth (`use_azuread_auth=true`). Never use storage account keys
- **Terraform plan review**: `plan` must always run before `apply`. Never skip the plan step or run `apply` without `-out=tfplan` to ensure what was reviewed is what gets applied
- **No `--no-verify` or `-auto-approve` bypasses**: Except in CI after a plan has been generated, never bypass safety checks
- **Sensitive variables**: All passwords, connection strings, and keys must be marked `sensitive = true` in Terraform and injected via `TF_VAR_*` from GitHub Secrets — never in `.tfvars` files committed to source
- **Network-first posture**: Default to private endpoints, internal load balancers, and deny-internet NSG rules. Public access must be explicitly justified

## Environment Promotion & Human Gates

- Each environment (`DEV`, `UAT`, `PROD`) is a GitHub Environment with its own secrets, variables, and protection rules
- **Required reviewers**: Configure required reviewers on each GitHub Environment (Settings → Environments → Protection rules). Apply/destroy actions on any environment must require at least one human approval
- **Branch protection**: The `main` branch requires a pull request with at least one approval before merge. Direct pushes to `main` should be disabled once the team is onboarded
- **Workflow pattern**: The pipeline uses `workflow_dispatch` with an `action` input (`plan`/`apply`/`destroy`). `plan` can run freely; `apply` and `destroy` must be gated by environment protection rules
- **Adding a new environment**: Duplicate the environment in GitHub (Settings → Environments), create environment-scoped secrets/variables, add a new Terraform workspace or variable set, and add the environment to the workflow's `environment:` field. The workflow should accept an environment input to target different stages
- **Destroy protection**: The `destroy` action should require a separate, stricter approval gate. Consider requiring two reviewers for production destroy operations

## Build and Test

```powershell
# Validate Terraform locally
cd terraform
terraform init -backend=false
terraform validate

# Check available AKS versions
az aks get-versions --location koreacentral -o table
```
