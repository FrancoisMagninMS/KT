# DevSecOps Pipeline Stages

This document describes the multi-environment deployment pipeline for the KT infrastructure project. The pipeline promotes changes through four stages with security scanning, automated deployments, and human approval gates.

---

## Pipeline Overview

```
Push to main
     │
     ▼
┌──────────────┐
│ Security Scan │  terraform fmt, tfsec, TFLint, Checkov, TruffleHog, Trivy
└──────┬───────┘
       ▼
┌──────────────┐
│  Bootstrap   │  Create/verify Terraform state backend (idempotent)
└──────┬───────┘
       ▼
┌──────────────┐
│    DEV       │  ◄── Automatic (no approval)
└──────┬───────┘
       ▼
┌──────────────┐
│    TEST      │  ◄── Automatic after successful DEV
└──────┬───────┘
       ▼
┌──────────────┐
│     QA       │  ◄── Requires human approval
└──────┬───────┘
       ▼
┌──────────────┐
│    PROD      │  ◄── Requires human approval
└──────────────┘
```

---

## Triggers

| Trigger | What happens |
|---------|-------------|
| **Push to `main`** | Full pipeline: Security Scan → Bootstrap → DEV → TEST → QA → PROD |
| **`workflow_dispatch` with `apply`** | Full pipeline starting from the target environment |
| **`workflow_dispatch` with `plan`** | Runs `terraform plan` on the selected environment only (no deployment) |
| **`workflow_dispatch` with `destroy`** | Destroys infrastructure in the selected environment only |

---

## Stage Details

### 1. Security Scan

**Trigger**: Runs on every pipeline execution (first job).

**Purpose**: Validate code quality and scan for security vulnerabilities before any infrastructure changes are applied.

| Scanner | What it checks | Fail behavior |
|---------|---------------|---------------|
| **terraform fmt** | Code formatting consistency | Hard fail |
| **tfsec** | Terraform security misconfigurations | Soft fail (SARIF uploaded) |
| **TFLint** | Terraform linting and best practices | Non-blocking |
| **Checkov** | CIS/NIST IaC policy compliance | Soft fail (SARIF uploaded) |
| **TruffleHog** | Committed secrets and credentials | Hard fail on verified secrets |
| **Trivy** | Container image vulnerabilities (HIGH/CRITICAL) | Hard fail |

All SARIF results are uploaded to the GitHub **Security → Code scanning** tab.

---

### 2. Bootstrap

**Trigger**: Runs after Security Scan passes.

**Purpose**: Create and configure the shared Terraform state backend. This is idempotent — safe to run repeatedly.

**What it does**:
- Creates resource group `rg-kt-tfstate` in `koreacentral`
- Creates storage account `stkttfstate` with Azure AD auth, TLS 1.2, no public blob access
- Creates blob container `tfstate`
- Assigns `Storage Blob Data Contributor` role to the service principal
- Verifies the role assignment

---

### 3. DEV

**Trigger**: Automatic — runs immediately after Bootstrap completes on every push to `main`.

**Approval**: None required.

**Purpose**: Deploy to the development environment for early validation. All code changes are tested here first.

**GitHub Environment**: `DEV` — no protection rules.

**Jobs**:

| Job | Purpose |
|-----|---------|
| `terraform-dev` | Plan and apply infrastructure with `TF_VAR_environment=dev` |
| `build-and-push-dev` | Build container images and push to ACR |
| `deploy-aks-dev` | Deploy to AKS via `az aks command invoke` |
| `deploy-aca-dev` | Update ACA container app image |

**Resources created**: `rg-kt-dev`, `aks-kt-dev`, `vnet-kt-dev`, `psql-kt-dev`, etc.

**State file**: `kt-infrastructure-dev.tfstate`

---

### 4. TEST

**Trigger**: Automatic — runs after all DEV jobs complete successfully.

**Approval**: None required.

**Purpose**: Validate changes in a test environment that mirrors production configuration. Automated integration tests and smoke tests should target this environment.

**GitHub Environment**: `TEST` — no protection rules.

**Jobs**:

| Job | Purpose |
|-----|---------|
| `terraform-test` | Plan and apply infrastructure with `TF_VAR_environment=test` |
| `build-and-push-test` | Build container images and push to ACR |
| `deploy-aks-test` | Deploy to AKS via `az aks command invoke` |
| `deploy-aca-test` | Update ACA container app image |

**Resources created**: `rg-kt-test`, `aks-kt-test`, `vnet-kt-test`, `psql-kt-test`, etc.

**State file**: `kt-infrastructure-test.tfstate`

---

### 5. QA

**Trigger**: Runs after all TEST jobs complete successfully.

**Approval**: **Human approval required** — the pipeline pauses and waits for a designated reviewer to approve before proceeding. Configured via GitHub Environment protection rules on the `QA` environment.

**Purpose**: Quality assurance environment for manual testing, user acceptance testing (UAT), and stakeholder sign-off before production.

**GitHub Environment**: `QA` — **required reviewers** must be configured in Settings → Environments → QA → Protection rules.

**Jobs**:

| Job | Purpose |
|-----|---------|
| `terraform-qa` | Plan and apply infrastructure with `TF_VAR_environment=qa` |
| `build-and-push-qa` | Build container images and push to ACR |
| `deploy-aks-qa` | Deploy to AKS via `az aks command invoke` |
| `deploy-aca-qa` | Update ACA container app image |

**Resources created**: `rg-kt-qa`, `aks-kt-qa`, `vnet-kt-qa`, `psql-kt-qa`, etc.

**State file**: `kt-infrastructure-qa.tfstate`

---

### 6. PROD

**Trigger**: Runs after all QA jobs complete successfully.

**Approval**: **Human approval required** — the pipeline pauses and waits for a designated reviewer to approve before proceeding. Configured via GitHub Environment protection rules on the `PROD` environment.

**Purpose**: Production environment serving live workloads. Only changes that have passed through DEV, TEST, and QA reach production.

**GitHub Environment**: `PROD` — **required reviewers** must be configured in Settings → Environments → PROD → Protection rules.

**Jobs**:

| Job | Purpose |
|-----|---------|
| `terraform-prod` | Plan and apply infrastructure with `TF_VAR_environment=prod` |
| `build-and-push-prod` | Build container images and push to ACR |
| `deploy-aks-prod` | Deploy to AKS via `az aks command invoke` |
| `deploy-aca-prod` | Update ACA container app image |

**Resources created**: `rg-kt-prod`, `aks-kt-prod`, `vnet-kt-prod`, `psql-kt-prod`, etc.

**State file**: `kt-infrastructure-prod.tfstate`

---

## Manual Operations

The pipeline also supports manual `workflow_dispatch` for targeted operations on individual environments:

| Action | Use case |
|--------|----------|
| **`plan`** | Preview what Terraform would change in a specific environment without applying |
| **`destroy`** | Tear down all infrastructure in a specific environment |

For `plan` and `destroy`, only the selected environment is affected — the full promotion chain does not run.

> **Note**: Destroying QA or PROD requires human approval because those environments have GitHub Environment protection rules.

---

## Approval Gates Summary

| Stage | Automatic? | Approval Required? | When it runs |
|-------|:----------:|:------------------:|-------------|
| Security Scan | Yes | No | Every pipeline run |
| Bootstrap | Yes | No | After Security Scan |
| **DEV** | **Yes** | **No** | After Bootstrap |
| **TEST** | **Yes** | **No** | After successful DEV |
| **QA** | No | **Yes** | After successful TEST, pending reviewer approval |
| **PROD** | No | **Yes** | After successful QA, pending reviewer approval |

---

## Resource Isolation

Each environment is fully isolated:

| Aspect | How it's isolated |
|--------|------------------|
| **Terraform state** | Separate state files (`kt-infrastructure-{env}.tfstate`) in a shared storage account |
| **Resource groups** | One per environment (`rg-kt-dev`, `rg-kt-test`, `rg-kt-qa`, `rg-kt-prod`) |
| **Resource naming** | Environment embedded in all names (e.g., `aks-kt-dev`, `psql-kt-prod`) |
| **Tags** | All resources carry `environment`, `project`, and `managed_by` tags |
| **GitHub Secrets** | Each environment has its own scoped secrets and variables |
| **Network** | Each environment gets its own VNet, subnets, NSGs, and NAT Gateway |

---

## Configuring Approval Gates

To set up required reviewers for QA and PROD:

1. Go to **Settings → Environments** in the GitHub repository
2. Select the environment (**QA** or **PROD**)
3. Under **Environment protection rules**, enable **Required reviewers**
4. Add one or more users or teams who must approve deployments
5. Optionally enable **Prevent self-review** to require a different person to approve

Alternatively, run `scripts/setup-environments.ps1` to create all four environments, then configure reviewers manually in the GitHub UI.

---

## Per-Stage Jobs Flow

Each environment stage follows the same pattern:

```
terraform init (environment-specific state file)
       │
       ▼
terraform validate
       │
       ▼
terraform plan -out=tfplan
       │
       ▼
terraform apply tfplan
       │
       ▼
Build & push container images to ACR
       │
       ├──────────────────┐
       ▼                  ▼
Deploy to AKS        Deploy to ACA
(az aks command       (az containerapp
 invoke)               update)
```

AKS and ACA deployments run in parallel within each stage.
