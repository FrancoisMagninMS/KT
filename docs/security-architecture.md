# KT Solution Security Architecture

This document describes the security posture of the KT infrastructure from two perspectives: **infrastructure security** (how Azure resources are hardened) and **DevSecOps** (how the CI/CD pipeline enforces security throughout the development lifecycle).

---

## 1. Infrastructure Security

### 1.1 Network Isolation

All infrastructure resources are deployed into a private VNet (`10.0.0.0/16`) with no public endpoints.

| Subnet | CIDR | Resource | Delegation |
|--------|------|----------|------------|
| `snet-aks` | `10.0.0.0/22` | AKS (private cluster) | — |
| `snet-aca` | `10.0.4.0/23` | ACA (internal LB) | `Microsoft.App/environments` |
| `snet-postgresql` | `10.0.6.0/24` | PostgreSQL Flexible Server | `Microsoft.DBforPostgreSQL/flexibleServers` |

**Key controls**:
- **`default_outbound_access_enabled = false`** on all three subnets — disables Azure's default SNAT. No resource can reach the internet unless explicitly routed.
- **NAT Gateway** with a single static public IP on the AKS subnet — provides controlled, auditable outbound for AKS nodes (image pulls, package downloads, telemetry). All outbound traffic exits through one known IP.
- **No public IPs** on any workload resource — AKS, ACA, and PostgreSQL are all VNet-internal only.

### 1.2 Network Security Groups (NSGs)

**AKS subnet NSG**:

| Rule | Direction | Action | Source/Dest | Purpose |
|------|-----------|--------|-------------|---------|
| AllowVNetInbound | Inbound | Allow | VirtualNetwork → VirtualNetwork | Inter-service communication |
| AllowAzureLoadBalancerInbound | Inbound | Allow | AzureLoadBalancer → * | Health probes |
| DenyInternetInbound | Inbound | Deny | Internet → * | Block all inbound internet |
| AllowVNetOutbound | Outbound | Allow | VirtualNetwork → VirtualNetwork | Inter-service communication |
| AllowAzureCloudOutbound | Outbound | Allow | * → AzureCloud | Azure management plane |

**ACA subnet**: NSG auto-managed by Azure. No custom NSG attached (ACA manages its own rules).

**PostgreSQL subnet**: Delegated subnet with private DNS zone. No public access.

### 1.3 AKS Security

| Control | Setting | Description |
|---------|---------|-------------|
| Private cluster | `private_cluster_enabled = true` | API server has no public endpoint |
| No public FQDN | `private_cluster_public_fqdn_enabled = false` | DNS doesn't resolve publicly |
| Azure CNI | `network_plugin = azure` | Pods get VNet IPs — no overlay networking |
| Network Policy | `network_policy = azure` | Pod-to-pod traffic control via Azure Network Policy |
| NAT Gateway outbound | `outbound_type = userAssignedNATGateway` | Controlled egress via single static IP |
| Azure AD RBAC | `azure_rbac_enabled = true` | Kubernetes RBAC tied to Entra ID roles (Cluster Admin, Admin, Writer, Reader) |
| Azure Policy add-on | `azure_policy_enabled = true` | In-cluster policy enforcement via Gatekeeper/OPA |
| Host encryption | Not available in azurerm v3 inline node pool | Requires azurerm v4+ or separate node pool resource |
| User-assigned identity | Control plane + kubelet | No system-assigned or SPN credentials on nodes |
| Key Vault CSI | `secret_rotation_enabled = true` | Secrets injected from Key Vault, rotated automatically |
| OMS Agent | `log_analytics_workspace_id` | Container Insights for monitoring and diagnostics |

### 1.4 ACA Security

| Control | Setting | Description |
|---------|---------|-------------|
| Internal load balancer | `internal = true` | No public endpoint — VNet-only access |
| Public network access disabled | `publicNetworkAccess = Disabled` | Explicitly blocks public ingress |
| User-assigned identity | UAMI for ACR pull and Key Vault access | No admin credentials |
| VNet integration | Deployed into delegated `snet-aca` | Full network isolation |
| Default outbound disabled | `default_outbound_access_enabled = false` | No Azure default SNAT |

### 1.5 PostgreSQL Security

| Control | Setting | Description |
|---------|---------|-------------|
| Private VNet integration | `delegated_subnet_id` | No public endpoint, not even optional |
| Public access disabled | `public_network_access_enabled = false` | Explicit block |
| Private DNS zone | `*.postgres.database.azure.com` linked to VNet | Name resolution within VNet only |
| Default outbound disabled | `default_outbound_access_enabled = false` | No Azure default SNAT |
| Password in Key Vault | Stored as `pg-admin-password` secret | Not in `.tfvars` or code |
| Diagnostic logging | allLogs + AllMetrics to LAW | Full audit trail |

### 1.6 Key Vault Security

| Control | Setting | Description |
|---------|---------|-------------|
| RBAC authorization | `enable_rbac_authorization = true` | No access policies — Entra ID RBAC only |
| Purge protection | `purge_protection_enabled = true` | Prevents permanent deletion |
| Soft delete | `soft_delete_retention_days = 7` | Recovery window |
| Least privilege | Deployer: KV Administrator; AKS/ACA: KV Secrets User | Scoped roles |
| Diagnostics | Azure Policy `setByPolicy` | Automatic log forwarding |

### 1.7 ACR Security

| Control | Setting | Description |
|---------|---------|-------------|
| Admin disabled | `admin_enabled = false` | No shared admin credentials |
| AcrPull RBAC | AKS kubelet and ACA identities | Image pull via managed identity |
| AcrPush RBAC | Deployer SP only | Image push limited to CI pipeline |
| Diagnostics | Azure Policy `setByPolicy` | Automatic log forwarding |

> **Note**: Several additional ACR hardening features (content trust, quarantine, private endpoints, geo-replication, retention policies, zone redundancy, dedicated data endpoints) require **Premium SKU**. The current deployment uses Standard SKU. These are documented in `terraform/.checkov.yaml` as acknowledged skip items.

### 1.8 Azure Policy (Governance)

A custom **DeployIfNotExists** policy automatically configures diagnostic settings on supported Azure resource types, ensuring logs and metrics flow to the central Log Analytics Workspace without manual Terraform configuration per resource.

Covered resource types include: VMs, NSGs, Load Balancers, AKS, PostgreSQL, Key Vault, ACR, Storage Accounts, and 20+ others.

### 1.9 Monitoring & Alerting

All resources send diagnostics to a single **Log Analytics Workspace** (`law-kt-prod`):

| Resource | How diagnostics are configured |
|----------|-------------------------------|
| AKS | OMS Agent + Azure Policy (`setByPolicy`) |
| ACA | Built-in LAW integration |
| PostgreSQL | Terraform diagnostic setting |
| VNet | Terraform diagnostic setting |
| ACR | Azure Policy (`setByPolicy`) |
| Key Vault | Azure Policy (`setByPolicy`) |

**Alerts** are configured for:
- AKS: node CPU/memory/disk, pods not ready, OOMKilled events
- ACA: container restarts, zero replicas
- PostgreSQL: CPU, storage, memory, high error rate, slow queries, lock waits, autovacuum, checkpoints, connection spikes, WAL growth
- All alerts route to a single email action group

---

## 2. DevSecOps

### 2.1 Identity & Authentication

| Aspect | Implementation |
|--------|---------------|
| Pipeline → Azure auth | **OIDC Workload Identity Federation** — GitHub Actions exchanges a short-lived token with Entra ID. No client secrets stored or rotated. |
| Federated credentials | Configured per GitHub Environment via `scripts/setup-oidc.ps1`. Don't expire. |
| Service principal RBAC | Contributor + User Access Administrator + Storage Blob Data Contributor (least privilege) |
| Workload identities | User-Assigned Managed Identities (UAMI) for AKS control plane, AKS kubelet, and ACA |

### 2.2 Shift-Left Security (PR Pipeline)

Every pull request to `main` triggers automated security checks that must pass before merge:

| Check | Category | Tool | What it catches |
|-------|----------|------|-----------------|
| SAST | Code vulnerabilities | CodeQL | SQL injection, XSS, command injection, path traversal |
| SCA | Vulnerable dependencies | Dependency Review | Known CVEs in new/updated packages |
| IaC validation | Terraform errors | terraform validate + TFLint | Invalid config, deprecated syntax, bad SKU references |
| IaC security | Terraform misconfig | tfsec | Public access, missing encryption, overly permissive rules |
| Container scan | Image vulnerabilities | Trivy | HIGH/CRITICAL CVEs in base images and libraries |

### 2.3 Pre-Deploy Security (Deploy Pipeline)

Before any infrastructure changes are applied, the deploy pipeline runs:

| Check | Category | Tool | Fail mode |
|-------|----------|------|-----------|
| Code formatting | Consistency | terraform fmt | Hard fail |
| IaC security | Terraform misconfig | tfsec | Soft fail (SARIF uploaded) |
| IaC linting | Best practices | TFLint | Non-blocking |
| IaC compliance | CIS/NIST policies | Checkov | Soft fail (SARIF uploaded) |
| Secret detection | Committed credentials | TruffleHog | Hard fail on verified secrets |
| Container scan | Image vulnerabilities | Trivy | Hard fail on HIGH/CRITICAL |

### 2.4 Supply Chain Security

| Control | Implementation |
|---------|---------------|
| Dependabot | Weekly automated dependency updates for GitHub Actions, Python packages, and Terraform providers |
| Container image scanning | Trivy scans in CI before images are pushed to ACR |
| Immutable image tags | CI pipeline tags images with `${{ github.sha }}` — no mutable `:latest` tags used for deployments |
| ACR admin disabled | No shared credentials — RBAC via managed identity only |
| Minimal base images | Python slim images in Dockerfiles |

### 2.5 Terraform State Security

| Control | Implementation |
|---------|---------------|
| Remote backend | Azure Storage Account (`stkttfstate`) |
| Azure AD auth | `use_azuread_auth = true` — no storage account keys |
| OIDC backend auth | `use_oidc = true` — backend authenticates via federated credential |
| Encryption | Azure Storage default encryption at rest |
| Public access blocked | `allow-blob-public-access false` on storage account |
| TLS enforced | `min-tls-version TLS1_2` |
| Sensitive variables | Passwords marked `sensitive = true`, injected via `TF_VAR_*` from GitHub Secrets |
| Plan artifact | Terraform plan uploaded as workflow artifact for audit trail |

### 2.6 Pipeline Security Practices

| Practice | Implementation |
|----------|---------------|
| No secrets in logs | `Debug env vars` step checks set/unset — never prints values |
| Pinned action versions | All GitHub Actions pinned to major (`@v4`) or specific (`@v3.88.12`) tags |
| Least-privilege permissions | Workflow `permissions` block limits to `contents: read`, `security-events: write`, `id-token: write` |
| Plan before apply | `terraform plan -out=tfplan` → `terraform apply tfplan` — what was reviewed is what gets applied |
| No `-auto-approve` bypass | Apply only runs against a saved plan file |
| SARIF integration | tfsec and Checkov results uploaded to GitHub Security tab for centralized visibility |

### 2.7 Environment Promotion & Human Gates

| Aspect | Implementation |
|--------|---------------|
| GitHub Environments | Each stage (DEV, UAT, PROD) is a GitHub Environment with its own secrets, variables, and protection rules |
| Required reviewers | Configured on GitHub Environments — apply/destroy actions require human approval |
| Branch protection | `main` requires PR with at least one approval. Direct pushes disabled. |
| Workflow pattern | `workflow_dispatch` with `action` input (plan/apply/destroy). Plan runs freely; apply/destroy gated. |
| Destroy protection | Stricter approval gate recommended. Consider dual reviewers for production. |

---

## 3. Security Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        DEVELOPER WORKSTATION                           │
│  Code → PR → main branch                                              │
└───────────┬─────────────────────────────────────────────────────────────┘
            │ Pull Request
            ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  PR CHECKS (pr-checks.yml)                                             │
│  ┌──────────┐ ┌────────────────┐ ┌──────────────┐ ┌────────────────┐  │
│  │ CodeQL   │ │ Dep. Review    │ │ TF Validate  │ │ Trivy Scan     │  │
│  │ (SAST)   │ │ (SCA)          │ │ fmt/tfsec    │ │ (Containers)   │  │
│  └──────────┘ └────────────────┘ └──────────────┘ └────────────────┘  │
│  All must pass → PR can be merged                                      │
└───────────┬─────────────────────────────────────────────────────────────┘
            │ Merge to main
            ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  DEPLOY PIPELINE (deploy.yml — workflow_dispatch)                      │
│                                                                        │
│  1. Validate Config ─────────────────────────────────────────────────  │
│  2. Security Scan ──── fmt → tfsec → TFLint → Checkov → TruffleHog   │
│                        └── Trivy (containers) ──────────────────────   │
│  3. Bootstrap (TF state backend) ───────────────────────────────────  │
│  4. Terraform plan → [artifact] → apply ────────────────────────────  │
│  5. Build & Push images (ACR Tasks) ────────────────────────────────  │
│  6. Deploy AKS (az aks command invoke) ─────────────────────────────  │
│  7. Deploy ACA (az containerapp update) ────────────────────────────  │
└───────────┬─────────────────────────────────────────────────────────────┘
            │ OIDC (no secrets)
            ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  AZURE (koreacentral)                                                  │
│                                                                        │
│  ┌─ VNet 10.0.0.0/16 ──────────────────────────────────────────────┐  │
│  │                                                                  │  │
│  │  ┌─ snet-aks ──────┐  ┌─ snet-aca ───────┐                     │  │
│  │  │ AKS (private)   │  │ ACA (internal)    │                     │  │
│  │  │ • Azure AD RBAC │  │ • No public access│                     │  │
│  │  │ • Network Policy│  │ • UAMI for ACR/KV │                     │  │
│  │  │ • Azure Policy  │  │ • Auto-managed NSG│                     │  │
│  │  │ • Host encrypt  │  │                   │                     │  │
│  │  │ • KV CSI driver │  └───────────────────┘                     │  │
│  │  └───────┬─────────┘                                            │  │
│  │          │                                                       │  │
│  │  ┌───────▼─────────┐  ┌─ snet-postgresql ─┐                    │  │
│  │  │ NAT Gateway     │  │ PostgreSQL         │                    │  │
│  │  │ (static IP)     │  │ • Private DNS      │                    │  │
│  │  └─────────────────┘  │ • No public access │                    │  │
│  │                       └────────────────────┘                    │  │
│  │                                                                  │  │
│  │  default_outbound_access_enabled = false (all subnets)          │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                        │
│  ┌─────────────┐  ┌─────────────┐  ┌───────────────────────────────┐  │
│  │ ACR         │  │ Key Vault   │  │ Log Analytics Workspace       │  │
│  │ • AcrPull   │  │ • RBAC auth │  │ • All diagnostics             │  │
│  │ • AcrPush   │  │ • Purge     │  │ • Alerts → email              │  │
│  │ • No admin  │  │   protected │  │ • Azure Policy auto-config    │  │
│  └─────────────┘  └─────────────┘  └───────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 4. OWASP & CIS Alignment

| OWASP Top 10 (2021) | How we address it |
|----------------------|-------------------|
| A01 — Broken Access Control | Azure AD RBAC on AKS, RBAC on Key Vault, UAMI (no shared credentials), NSG deny rules |
| A02 — Cryptographic Failures | Host encryption on AKS nodes, TLS 1.2 on storage, Key Vault for secrets |
| A03 — Injection | CodeQL SAST scanning on every PR |
| A04 — Insecure Design | Private cluster, internal LB, delegation-based subnets, no public endpoints |
| A05 — Security Misconfiguration | tfsec + Checkov scan every Terraform change; Azure Policy enforces diagnostic settings |
| A06 — Vulnerable Components | Dependabot + Dependency Review + Trivy container scanning |
| A07 — Auth Failures | OIDC (no stored secrets), UAMI, Azure AD RBAC, no admin accounts |
| A08 — Software Integrity | Immutable SHA-tagged container images, Terraform plan artifacts, pinned action versions |
| A09 — Logging Failures | Azure Policy auto-deploys diagnostic settings; central LAW; alerts for anomalies |
| A10 — SSRF | Private endpoints only — no public-facing services to exploit |

| CIS Azure Benchmark | How we address it |
|----------------------|-------------------|
| 4.x — Networking | Private endpoints, NSGs, NAT Gateway, no default outbound |
| 5.x — Logging | Azure Policy DeployIfNotExists for diagnostic settings |
| 6.x — Storage | RBAC auth, no public access, TLS 1.2 |
| 7.x — Key Vault | RBAC, purge protection, soft delete |
| 8.x — AKS | Private cluster, Azure AD RBAC, network policy, Azure Policy add-on |

---

## 5. Accepted Risks & Future Enhancements

### Accepted Risks (documented in `.checkov.yaml`)

All accepted risks relate to **ACR Standard SKU limitations** — upgrading to Premium would resolve them:
- No content trust (image signing)
- No quarantine workflow
- No private endpoints on ACR
- No geo-replication or zone redundancy
- No retention policy for untagged manifests
- No dedicated data endpoints

AKS disk encryption set (CKV_AZURE_117) requires customer-managed keys (CMK) infrastructure.

### Recommended Future Enhancements

| Enhancement | Benefit |
|-------------|---------|
| Upgrade ACR to Premium | Enables private endpoints, content trust, retention, geo-replication |
| SBOM generation (Syft/Anchore) | Software Bill of Materials for supply chain transparency |
| Container signing (Cosign) | Cryptographic proof of image provenance |
| Kyverno / Gatekeeper policies | K8s admission control (block privileged pods, enforce labels, restrict registries) |
| Defender for Containers | Runtime threat detection inside AKS |
| Customer-managed keys (CMK) | AKS disk encryption with Azure Key Vault managed HSM |
| ArgoCD GitOps | Declarative K8s deployments with drift detection (see KT DevSecOps guide) |
| Release freeze windows | GitHub Environment deployment windows for change management |
