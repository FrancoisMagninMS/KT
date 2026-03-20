# Project Guidelines

## Overview

Azure infrastructure-as-code project deploying AKS, ACA, PostgreSQL Flexible Server, ACR, Key Vault, and networking resources to the **koreacentral** region using Terraform and GitHub Actions.

## Architecture

- **Terraform** (`terraform/`): All infrastructure definitions — one resource type per file (e.g., `aks.tf`, `aca.tf`, `networking.tf`)
- **Scripts** (`scripts/`): PowerShell utility scripts for Azure and GitHub setup
- **Workflows** (`.github/workflows/`): GitHub Actions CI/CD with `workflow_dispatch`
- **Target region**: `koreacentral` — always verify resource/SKU/version availability in this region before proposing changes

## Terraform Conventions

- **Provider**: `azurerm >= 3.80`, `azapi >= 1.9`, Terraform `>= 1.5`, deployed via Terraform 1.10.3 in CI
- **Backend**: Azure Storage with Azure AD auth (`use_azuread_auth=true`); backend config is passed via `-backend-config` flags in the workflow, not hardcoded
- **Naming**: `{resource-prefix}-{var.project}-{var.environment}` (e.g., `aks-kt-prod`, `vnet-kt-prod`). ACR and Key Vault append `random_string.suffix.result` for global uniqueness
- **Variables**: Define in `variables.tf` with type, default (when sensible), and description. Sensitive values use `sensitive = true` and are injected via `TF_VAR_*` env vars from GitHub Secrets
- **File organization**: One `.tf` file per resource domain — don't combine unrelated resources. Use section headers with `# ───── section ─────` comments
- **Identity**: User-assigned managed identities for AKS and ACA; RBAC role assignments in the relevant resource files (e.g., ACR pull roles in `acr.tf`)
- **Diagnostics**: Resources should send logs/metrics to the single Log Analytics Workspace (`azurerm_log_analytics_workspace.main`). AKS, ACR, and Key Vault diagnostics are managed by Azure Policy (`setByPolicy` — DeployIfNotExists); do **not** create Terraform diagnostic settings for those resources

## AKS Specifics

- Version 1.31 and 1.30 are **LTS-only** in koreacentral — use 1.32+ or verify with `az aks get-versions --location koreacentral`
- Uses Azure CNI with user-assigned identity for the control plane and kubelet
- OMS agent enabled for Container Insights
- Azure AD RBAC enabled (`azure_rbac_enabled = true`) — supports granular Kubernetes RBAC via Entra ID roles (Cluster Admin, Admin, Writer, Reader)
- Outbound type: `userAssignedNATGateway` — all egress goes through a NAT Gateway with a single static public IP
- `default_outbound_access_enabled = false` on the AKS subnet (no Azure default SNAT)

## ACA Specifics

- ACA managed environment is created via `azapi_resource` (not `azurerm`) because `azurerm` v3 lacks `public_network_access_enabled`
- API version: `2024-10-02-preview` with `schema_validation_enabled = false`
- Internal load balancer (`internal = true`) with `publicNetworkAccess = "Disabled"`
- ACA manages its own NSG on its subnet — do **not** create a custom NSG for the ACA subnet
- `default_outbound_access_enabled = false` on the ACA subnet

## PostgreSQL Specifics

- Flexible Server with private VNet integration (`public_network_access_enabled = false`)
- Diagnostic logs go to `AzureDiagnostics` table (not `PostgreSQLLogs`)
- The `errorLevel_s` column does **not** exist; use `Message has_any(...)` or `Message contains` in KQL queries
- Replication metrics (`read_replica_lag`, `physical_replication_lag_in_seconds`) only exist when read replicas are configured
- `default_outbound_access_enabled = false` on the PostgreSQL subnet

## Networking

- **VNet**: `10.0.0.0/16` with three subnets: AKS (`10.0.0.0/22`), ACA (`10.0.4.0/23`), PostgreSQL (`10.0.6.0/24`)
- **NAT Gateway**: Standard SKU with a static public IP, associated to the AKS subnet for controlled egress
- **All subnets** have `default_outbound_access_enabled = false` — no Azure default SNAT
- **NSG** on AKS subnet: Allow VNet↔VNet, Allow AzureLoadBalancer inbound, Allow AzureCloud outbound, Deny Internet inbound
- **ACA subnet**: NSG auto-managed by Azure; do not attach a custom NSG
- **PostgreSQL subnet**: Delegated to `Microsoft.DBforPostgreSQL/flexibleServers`, private DNS zone

## Alerts

- All alerts use a single `azurerm_monitor_action_group` with email receiver
- KQL scheduled query alerts target the LAW; metric alerts target the resource directly
- Valid `window_size` / `window_duration` values: PT1M, PT5M, PT10M, PT15M, PT30M, PT1H, PT6H, PT12H, PT1D

## Scripts

- All scripts are **PowerShell** (`.ps1`), not Bash — this is a Windows-first project
- Use full cmdlet names (e.g., `Get-ChildItem` not `ls`)

## GitHub Actions Workflow

- **Authentication**: OIDC Workload Identity Federation from GitHub → Entra ID (no client secrets). Run `scripts/setup-oidc.ps1` to configure federated credentials
- Environment: `DEV`, `TEST`, `QA`, `PROD` (secrets/variables are scoped to each environment)
- Secrets (`AZURE_CLIENT_ID`, `AZURE_SUBSCRIPTION_ID`, `AZURE_TENANT_ID`, `PG_ADMIN_PASSWORD`) must be set as environment-level secrets on each environment, not repository-level. `AZURE_CLIENT_SECRET` is **not needed** with OIDC
- Variables (`ALERT_EMAIL`) are set at the environment level on each environment
- `ARM_*` env vars must be defined at the **job** level (not workflow level) to access environment-scoped secrets. Use `ARM_USE_OIDC: 'true'` for Terraform OIDC authentication

### Pipeline Jobs (`deploy.yml` — `push` to `main` + `workflow_dispatch`)

1. **security-scan** — terraform fmt, tfsec, TFLint, Checkov, TruffleHog, Trivy (SARIF uploaded to GitHub Security tab)
2. **bootstrap** — Creates Terraform state backend storage
3. **DEV stage** — `terraform-dev` → `build-and-push-dev` → `deploy-aks-dev` + `deploy-aca-dev` (auto on push)
4. **TEST stage** — `terraform-test` → `build-and-push-test` → `deploy-aks-test` + `deploy-aca-test` (auto after DEV)
5. **QA stage** — `terraform-qa` → `build-and-push-qa` → `deploy-aks-qa` + `deploy-aca-qa` (requires human approval)
6. **PROD stage** — `terraform-prod` → `build-and-push-prod` → `deploy-aks-prod` + `deploy-aca-prod` (requires human approval)
7. **manual-terraform** — For `plan`/`destroy` operations on individual environments via `workflow_dispatch`

### PR Checks (`pr-checks.yml` — on `pull_request` to `main`)

1. **CodeQL** — SAST analysis for application code
2. **Dependency Review** — SCA for vulnerable dependencies in PRs
3. **Terraform Validation** — fmt, init, validate, TFLint, tfsec
4. **Container Scan** — Trivy vulnerability scan of Dockerfiles

## Pipeline Security

- **Least-privilege SP**: The service principal should have only the roles it needs (Contributor, User Access Administrator, Storage Blob Data Contributor). Never grant Owner
- **No secrets in logs**: Never `echo` or print secret values. Use `::add-mask::` for any dynamically-derived sensitive values. The `Debug env vars` step must only check set/unset — never print values
- **Pin action versions**: Always pin GitHub Actions to a major tag (`@v4`, `@v3`), or to a full SHA for third-party actions. Never use `@latest` or `@main`
- **OIDC authentication**: Use Workload Identity Federation from GitHub → Entra ID (no client secrets). Run `scripts/setup-oidc.ps1` to configure federated credentials. Federated credentials don't expire — no rotation needed
- **Dependabot**: Automated dependency updates for GitHub Actions, Python packages, and Terraform providers via `.github/dependabot.yml`
- **Backend security**: Terraform state contains sensitive data. The backend storage account must have `allow-blob-public-access false`, `min-tls-version TLS1_2`, and Azure AD auth (`use_azuread_auth=true`). Never use storage account keys
- **Terraform plan review**: `plan` must always run before `apply`. Never skip the plan step or run `apply` without `-out=tfplan` to ensure what was reviewed is what gets applied
- **No `--no-verify` or `-auto-approve` bypasses**: Except in CI after a plan has been generated, never bypass safety checks
- **Sensitive variables**: All passwords, connection strings, and keys must be marked `sensitive = true` in Terraform and injected via `TF_VAR_*` from GitHub Secrets — never in `.tfvars` files committed to source
- **Network-first posture**: Default to private endpoints, internal load balancers, NAT Gateway for outbound, and `default_outbound_access_enabled = false` on all subnets. Public access must be explicitly justified

## Environment Promotion & Human Gates

- Four environments: `DEV`, `TEST`, `QA`, `PROD` — each is a GitHub Environment with its own secrets, variables, and protection rules
- **DEV**: Auto-deploys on every push to `main` — no approval required
- **TEST**: Auto-deploys after successful DEV deployment — no approval required
- **QA**: Requires human approval before deployment (configure required reviewers in GitHub Environment settings)
- **PROD**: Requires human approval before deployment (configure required reviewers in GitHub Environment settings); only runs after successful QA deployment
- **Required reviewers**: Configure required reviewers on QA and PROD environments (Settings → Environments → Protection rules)
- **Branch protection**: The `main` branch requires a pull request with at least one approval before merge. Direct pushes to `main` should be disabled once the team is onboarded
- **Workflow pattern**: The pipeline triggers on `push` to `main` (full DEV→TEST→QA→PROD chain) and `workflow_dispatch` for manual plan/destroy on individual environments
- **Adding a new environment**: Create a GitHub Environment, add environment-scoped secrets/variables, set up OIDC federated credentials, and add the environment stage to the workflow
- **Destroy protection**: Use `workflow_dispatch` with `destroy` action targeting a specific environment. QA and PROD environments require reviewer approval
- **Terraform state isolation**: Each environment uses a separate state file (`kt-infrastructure-dev.tfstate`, `kt-infrastructure-test.tfstate`, etc.) in the shared backend storage account
- **Resource naming**: All resources include the environment in their name (e.g., `rg-kt-dev`, `aks-kt-prod`) and carry `environment`, `project`, and `managed_by` tags
- **Environment setup**: Run `scripts/setup-environments.ps1` to create all four GitHub Environments

## Build and Test

```powershell
# Validate Terraform locally
cd terraform
terraform init -backend=false
terraform validate

# Check available AKS versions
az aks get-versions --location koreacentral -o table
```
