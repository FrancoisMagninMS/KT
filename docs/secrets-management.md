# Secrets Management: GitHub Secrets → Azure Key Vault → Workloads

This document describes how secrets flow from source (GitHub Secrets) through Terraform into Azure Key Vault, and how each workload platform (AKS and ACA) consumes them at runtime.

---

## Overview

```
GitHub Secrets                    Terraform                      Azure Key Vault
┌────────────────┐          ┌─────────────────────┐         ┌──────────────────────┐
│ PG_ADMIN_       │──TF_VAR──▶│ azurerm_key_vault_  │────────▶│ pg-admin-password    │
│   PASSWORD      │          │   secret.pg_password │         │ pg-admin-login       │
│                 │          │   secret.pg_login    │         │ pg-host              │
│ AZURE_CLIENT_ID │──OIDC───▶│   secret.pg_host     │         └──────────┬───────────┘
│ AZURE_TENANT_ID │          └─────────────────────┘                    │
│ AZURE_          │                                                     │
│  SUBSCRIPTION_ID│                                        ┌────────────┴────────────┐
└────────────────┘                                        │                         │
                                                    ┌─────▼──────┐          ┌───────▼───────┐
                                                    │  AKS Pods  │          │  ACA Containers│
                                                    │ (CSI driver)│          │ (managed ID)   │
                                                    └────────────┘          └───────────────┘
```

---

## 1. What Gets Stored in Key Vault

Terraform writes three secrets into Azure Key Vault during `terraform apply`:

| KV Secret Name | Source | Terraform Resource |
|---|---|---|
| `pg-admin-password` | `var.pg_admin_password` (from `TF_VAR_pg_admin_password` / GitHub Secret `PG_ADMIN_PASSWORD`) | `azurerm_key_vault_secret.pg_password` |
| `pg-admin-login` | `var.pg_admin_login` (default: `pgadmin`) | `azurerm_key_vault_secret.pg_login` |
| `pg-host` | `azurerm_postgresql_flexible_server.main.fqdn` (computed at apply time) | `azurerm_key_vault_secret.pg_host` |

### What stays in GitHub Secrets only

The following values are used exclusively for CI/CD authentication and are **not** stored in Key Vault:

| GitHub Secret | Purpose |
|---|---|
| `AZURE_CLIENT_ID` | OIDC service principal for Terraform and Azure CLI |
| `AZURE_TENANT_ID` | Entra ID tenant identifier |
| `AZURE_SUBSCRIPTION_ID` | Target Azure subscription |
| `PG_ADMIN_PASSWORD` | Injected as `TF_VAR_pg_admin_password` → written to AKV by Terraform |

---

## 2. Key Vault Configuration

Defined in `terraform/key-vault.tf`:

- **RBAC-enabled** (`rbac_authorization_enabled = true`) — no access policies, uses Azure RBAC
- **Purge protection** enabled — prevents accidental permanent deletion
- **Public network access** enabled — required for GitHub Actions runners to write secrets during `terraform apply`
- **Deployer identity** gets `Key Vault Administrator` role to manage secrets

---

## 3. AKS — Secret Consumption via CSI Driver

### Infrastructure (Terraform)

- `key_vault_secrets_provider` enabled on the AKS cluster with `secret_rotation_enabled = true`
- AKS kubelet managed identity gets `Key Vault Secrets User` role on the Key Vault

### Kubernetes Manifests

#### SecretProviderClass (`apps/hello-korea-aks/k8s/secret-provider-class.yaml`)

Configures the Azure Key Vault CSI driver to:
1. Authenticate using the kubelet managed identity (`useVMManagedIdentity: "true"`)
2. Fetch `pg-admin-password`, `pg-admin-login`, and `pg-host` from Key Vault
3. Sync them into a Kubernetes Secret named `pg-secrets` with keys `PG_PASSWORD`, `PG_USERNAME`, `PG_HOST`

Placeholders `__KEY_VAULT_NAME__`, `__TENANT_ID__`, and `__KUBELET_CLIENT_ID__` are substituted at deploy time by the workflow using Terraform outputs.

#### Deployment (`apps/hello-korea-aks/k8s/deployment.yaml`)

- Mounts a CSI volume using the `azure-kvs` SecretProviderClass
- Injects `PG_PASSWORD`, `PG_USERNAME`, and `PG_HOST` as environment variables from the synced `pg-secrets` Kubernetes Secret

### Flow

```
Key Vault                CSI Driver              K8s Secret           Pod
┌──────────┐         ┌──────────────┐        ┌─────────────┐     ┌────────┐
│pg-admin- │◄────────│SecretProvider│───sync──▶│ pg-secrets  │─env─▶│ app.py │
│  password│  fetch  │    Class     │        │  PG_PASSWORD│     │        │
│pg-admin- │         │  (azure-kvs)│        │  PG_USERNAME│     │        │
│  login   │         │              │        │  PG_HOST    │     │        │
│pg-host   │         └──────────────┘        └─────────────┘     └────────┘
└──────────┘
```

---

## 4. ACA — Secret Consumption via Managed Identity

### Infrastructure (Terraform)

In `terraform/aca.tf`, each secret is declared with a Key Vault reference:

```hcl
secret {
  name                = "pg-admin-password"
  key_vault_secret_id = azurerm_key_vault_secret.pg_password.versionless_id
  identity            = azurerm_user_assigned_identity.aca.id
}
```

The ACA managed identity has `Key Vault Secrets User` role on the Key Vault (defined in `terraform/key-vault.tf`).

### Container Environment Variables

The container template maps each secret to an environment variable:

```hcl
env {
  name        = "PG_PASSWORD"
  secret_name = "pg-admin-password"
}
```

### Flow

```
Key Vault               ACA Platform            Container
┌──────────┐         ┌──────────────┐        ┌────────────┐
│pg-admin- │◄────────│ Managed ID   │──env──▶│  app.py    │
│  password│  fetch  │ secret ref   │        │ PG_PASSWORD│
│pg-admin- │         │ (ACA runtime)│        │ PG_USERNAME│
│  login   │         │              │        │ PG_HOST    │
│pg-host   │         └──────────────┘        └────────────┘
└──────────┘
```

---

## 5. CI/CD Workflow Integration

### Terraform Outputs

The workflow exports three additional outputs after `terraform apply`:

| Output | Value | Used For |
|---|---|---|
| `key_vault_name` | AKV resource name | Substituted into SecretProviderClass YAML |
| `tenant_id` | Entra ID tenant | SecretProviderClass `tenantId` parameter |
| `aks_kubelet_client_id` | Kubelet MI client ID | SecretProviderClass `userAssignedIdentityID` |

### Manifest Preparation (all environments)

The `Prepare K8s Manifests` step substitutes placeholders in both the deployment and SecretProviderClass YAMLs:

```bash
sed -i "s|__KEY_VAULT_NAME__|${{ needs.terraform-<env>.outputs.key_vault_name }}|g" apps/hello-korea-aks/k8s/secret-provider-class.yaml
sed -i "s|__TENANT_ID__|${{ needs.terraform-<env>.outputs.tenant_id }}|g" apps/hello-korea-aks/k8s/secret-provider-class.yaml
sed -i "s|__KUBELET_CLIENT_ID__|${{ needs.terraform-<env>.outputs.aks_kubelet_client_id }}|g" apps/hello-korea-aks/k8s/secret-provider-class.yaml
```

### AKS Deployment

The `Deploy to Private AKS` step now deploys three manifests:

```bash
kubectl apply -f secret-provider-class.yaml -f deployment.yaml -f service.yaml
```

---

## 6. Verifying Secrets at Runtime

Both apps expose a `/dbinfo` endpoint that reports whether each secret is available (without revealing values):

```
GET /dbinfo

<h1>Database Configuration</h1>
<p>PG_HOST: set</p>
<p>PG_USERNAME: set</p>
<p>PG_PASSWORD: set</p>
```

---

## 7. Security Considerations

| Concern | Mitigation |
|---|---|
| Secrets in Terraform state | State file stored in Azure Storage with Azure AD auth, TLS 1.2, no public blob access |
| Secret rotation | AKS CSI driver has `secret_rotation_enabled = true`; ACA resolves secrets at revision start |
| Least privilege | AKS kubelet and ACA MI get `Key Vault Secrets User` (read-only); deployer gets `Key Vault Administrator` |
| No secrets in logs | Apps only report `set`/`not-set` — never log actual values. Workflow debug step checks set/unset only |
| ACA secret references | Use `versionless_id` so the latest secret version is always fetched |
| OIDC (no client secrets) | GitHub → Azure auth uses Workload Identity Federation — no long-lived credentials |
