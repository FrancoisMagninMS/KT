# Hello Korea — Deployment Guide

This guide walks through deploying the two **Hello Korea** sample applications:

| App | Platform | Access |
|-----|----------|--------|
| `hello-korea-aks` | Azure Kubernetes Service (private cluster) | Internal VNet only |
| `hello-korea-aca` | Azure Container Apps (internal environment) | Internal VNet only |

Both services are locked down — no internet inbound, outbound controlled via NAT Gateway. Communication is allowed only within the private VNet.

---

## Prerequisites

- **Azure CLI** (`az`) installed and authenticated — [Install Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)
- **GitHub CLI** (`gh`) installed and authenticated — [Install GitHub CLI](https://cli.github.com)
- Access to the Azure subscription (`MCAPS-Hybrid-ISD-Incubation`)
- An Azure AD **App Registration** (service principal) with the following roles:
  - `Contributor` on the subscription
  - `User Access Administrator` on the subscription
  - `Storage Blob Data Contributor` on the Terraform state storage account

---

## One-Time Setup

These steps only need to be done once when setting up a new environment.

### 1. Create the Service Principal

If you don't already have one:

```powershell
az ad sp create-for-rbac --name "sp-kt-deploy" --role Contributor `
  --scopes "/subscriptions/<SUBSCRIPTION_ID>"
```

Note the `appId` — this is your `AZURE_CLIENT_ID`.

### 2. Configure OIDC Federated Credentials

The pipeline uses **OIDC Workload Identity Federation** — no client secrets needed. Run the setup script to create federated credentials on the App Registration:

```powershell
.\scripts\setup-oidc.ps1 `
  -AppId "<AZURE_CLIENT_ID>" `
  -GitHubOrg "<GITHUB_ORG>" `
  -GitHubRepo "KT" `
  -Environments @("DEV","TEST","QA","PROD")
```

> **Note**: Federated credentials don't expire — no rotation needed. If you previously used a client secret (`AZURE_CLIENT_SECRET`), you can delete it from the App Registration.

### 3. Create GitHub Environments

Run the environment setup script to create all four GitHub Environments:

```powershell
.\scripts\setup-environments.ps1
```

This creates `DEV`, `TEST`, `QA`, and `PROD` environments. After running:
- **QA** and **PROD** require manual configuration of required reviewers in GitHub Settings → Environments
- **DEV** and **TEST** have no approval gates

### 4. Configure GitHub Secrets & Variables

Run the interactive setup script to configure the GitHub environment:

```powershell
.\scripts\setup-github.ps1
```

The following must be set on **each** environment (DEV, TEST, QA, PROD):

| Type | Name | Description |
|------|------|-------------|
| Secret | `AZURE_CLIENT_ID` | Service principal app/client ID |
| Secret | `AZURE_SUBSCRIPTION_ID` | Azure subscription ID |
| Secret | `AZURE_TENANT_ID` | Azure AD tenant ID |
| Secret | `PG_ADMIN_PASSWORD` | PostgreSQL admin password |
| Variable | `ALERT_EMAIL` | Email for Azure Monitor alerts |

> `AZURE_CLIENT_SECRET` is **not needed** — the pipeline authenticates via OIDC.
> Secrets and variables must be set at the **environment** level, not the repository level.

---

## Step 1 — Deploy Infrastructure

The pipeline deploys infrastructure through four stages: **DEV → TEST → QA → PROD**.

### Automatic deployment (push to main)

Pushing to `main` triggers the full pipeline:
1. **DEV** — deploys automatically
2. **TEST** — deploys automatically after successful DEV
3. **QA** — pauses for human approval, then deploys
4. **PROD** — pauses for human approval, then deploys

```bash
git push origin main
```

### Manual deployment (workflow_dispatch)

For plan/destroy operations on a specific environment:

1. Go to **GitHub → Actions → Deploy KT Infrastructure**
2. Click **Run workflow**
3. Select the target **environment** (dev, test, qa, prod) and **action** (plan, apply, destroy)

> **Note**: The `apply` action via workflow_dispatch also triggers the full multi-stage pipeline starting from the selected environment.

4. Wait for the workflow to complete. Note the outputs:
   - `acr_login_server` — your ACR login server (e.g. `acrktdevxxxx.azurecr.io`)
   - `aks_cluster_name` — AKS cluster name
   - `resource_group_name` — resource group name

   You can also get these from the Terraform state:
   ```bash
   cd terraform
   terraform output acr_login_server
   terraform output aks_cluster_name
   terraform output resource_group_name
   ```

---

## Step 2 — Build & Push Container Images

Log in to ACR and build both images:

```bash
# Set your ACR name (from terraform output)
ACR_NAME="acrktprodXXXX"   # Replace with actual value

# Log in to ACR
az acr login --name $ACR_NAME

# Build and push the AKS app
cd apps/hello-korea-aks
docker build -t $ACR_NAME.azurecr.io/hello-korea-aks:latest .
docker push $ACR_NAME.azurecr.io/hello-korea-aks:latest

# Build and push the ACA app
cd ../hello-korea-aca
docker build -t $ACR_NAME.azurecr.io/hello-korea-aca:latest .
docker push $ACR_NAME.azurecr.io/hello-korea-aca:latest
```

**Alternative — build remotely with ACR Tasks** (no local Docker needed):

```bash
az acr build --registry $ACR_NAME --image hello-korea-aks:latest apps/hello-korea-aks/
az acr build --registry $ACR_NAME --image hello-korea-aca:latest apps/hello-korea-aca/
```

---

## Step 3 — Deploy to AKS (Private Cluster)

Since AKS is a **private cluster**, the API server is not accessible from the public internet. Use `az aks command invoke` to run kubectl commands via the Azure management plane.

### 3.1 — Update the deployment manifest

Replace the placeholder ACR login server in the Kubernetes manifest:

```bash
# On Linux/macOS:
sed -i "s|__ACR_LOGIN_SERVER__|$ACR_NAME.azurecr.io|g" apps/hello-korea-aks/k8s/deployment.yaml

# On Windows PowerShell:
(Get-Content apps/hello-korea-aks/k8s/deployment.yaml) -replace '__ACR_LOGIN_SERVER__', "$ACR_NAME.azurecr.io" | Set-Content apps/hello-korea-aks/k8s/deployment.yaml
```

### 3.2 — Deploy via `az aks command invoke`

```bash
RG="rg-kt-prod"
AKS="aks-kt-prod"

# Apply the deployment
az aks command invoke \
  --resource-group $RG \
  --name $AKS \
  --command "kubectl apply -f deployment.yaml -f service.yaml" \
  --file apps/hello-korea-aks/k8s/deployment.yaml \
  --file apps/hello-korea-aks/k8s/service.yaml

# Verify pods are running
az aks command invoke \
  --resource-group $RG \
  --name $AKS \
  --command "kubectl get pods -l app=hello-korea"

# Get the internal service IP
az aks command invoke \
  --resource-group $RG \
  --name $AKS \
  --command "kubectl get svc hello-korea"
```

The service will receive a **private IP** from the AKS subnet (10.0.0.0/22). Note this IP — you can use it to test from a VM in the same VNet.

---

## Step 4 — Deploy to ACA

The ACA container app (`ca-hello-korea`) was already created by Terraform with the MCR quickstart image. Update it to use your custom image:

```bash
RG="rg-kt-prod"
ACR_NAME="acrktprodXXXX"   # Replace with actual value

az containerapp update \
  --name ca-hello-korea \
  --resource-group $RG \
  --image $ACR_NAME.azurecr.io/hello-korea-aca:latest
```

Verify the app is running:

```bash
az containerapp show \
  --name ca-hello-korea \
  --resource-group $RG \
  --query "properties.latestRevisionFqdn" -o tsv
```

Since the ACA environment uses an **internal load balancer**, the FQDN resolves to a private IP only accessible from within the VNet.

---

## Step 5 — Access the Apps (Private Network)

Both apps are **private-only** — they have no public endpoints. The AKS API server, the AKS service LoadBalancer, and the ACA environment all resolve to private IPs within the VNet. You cannot reach them from the public internet or your local machine directly.

Choose one of the methods below to access the apps.

### Method 1 — Azure Bastion + Jumpbox VM (recommended for demos)

Deploy a small VM inside the VNet and connect via Azure Bastion (no public IP needed on the VM).

```bash
RG="rg-kt-prod"

# Create a Bastion subnet (required name: AzureBastionSubnet)
az network vnet subnet create \
  --resource-group $RG \
  --vnet-name vnet-kt-prod \
  --name AzureBastionSubnet \
  --address-prefixes 10.0.7.0/26

# Create a Bastion host
az network bastion create \
  --resource-group $RG \
  --name bastion-kt-prod \
  --vnet-name vnet-kt-prod \
  --location koreacentral \
  --sku Basic

# Create a jumpbox VM in the AKS subnet (no public IP)
az vm create \
  --resource-group $RG \
  --name vm-jumpbox \
  --image Ubuntu2404 \
  --size Standard_B2s \
  --vnet-name vnet-kt-prod \
  --subnet snet-aks \
  --public-ip-address "" \
  --admin-username azureuser \
  --generate-ssh-keys
```

Connect via Bastion in the Azure Portal: **VM → Connect → Bastion**. Then from the VM:

```bash
# Test AKS app (use the internal LoadBalancer IP from Step 3)
curl http://<AKS_SERVICE_PRIVATE_IP>

# Test ACA app (use the internal FQDN)
curl http://<ACA_INTERNAL_FQDN>
```

### Method 2 — `az aks command invoke` (AKS app only, no VM needed)

For the AKS app, you can test directly via the Azure management plane — no VNet access required:

```bash
RG="rg-kt-prod"
AKS="aks-kt-prod"

# Test the AKS app via the service DNS name inside the cluster
az aks command invoke \
  --resource-group $RG \
  --name $AKS \
  --command "curl -s http://hello-korea.default.svc.cluster.local"
```

This runs `curl` on a pod inside the cluster, so it can reach the internal service. This method **does not work for ACA** — it only reaches services inside the AKS cluster.

### Method 3 — VPN Gateway (for ongoing development)

For regular access from your workstation, set up a Point-to-Site VPN:

```bash
# Create a GatewaySubnet
az network vnet subnet create \
  --resource-group $RG \
  --vnet-name vnet-kt-prod \
  --name GatewaySubnet \
  --address-prefixes 10.0.8.0/27

# Create a VPN gateway (takes ~30 minutes)
az network vnet-gateway create \
  --resource-group $RG \
  --name vpngw-kt-prod \
  --vnet vnet-kt-prod \
  --gateway-type Vpn \
  --vpn-type RouteBased \
  --sku VpnGw1 \
  --location koreacentral
```

After configuring the P2S VPN client on your machine, both apps will be reachable directly:

```bash
curl http://<AKS_SERVICE_PRIVATE_IP>
curl http://<ACA_INTERNAL_FQDN>
```

### Method 4 — Azure Cloud Shell with VNet integration

If your subscription supports Cloud Shell VNet integration, you can mount it into the VNet and access both apps directly. See [Cloud Shell in a VNet](https://learn.microsoft.com/en-us/azure/cloud-shell/vnet/overview).

### Getting the App Endpoints

Regardless of which method you use, you need the private endpoints:

```bash
RG="rg-kt-prod"
AKS="aks-kt-prod"

# AKS — get the internal LoadBalancer IP
az aks command invoke \
  --resource-group $RG \
  --name $AKS \
  --command "kubectl get svc hello-korea -o jsonpath='{.status.loadBalancer.ingress[0].ip}'"

# ACA — get the internal FQDN
az containerapp show \
  --name ca-hello-korea \
  --resource-group $RG \
  --query "properties.configuration.ingress.fqdn" -o tsv

# ACA — get the environment's internal IP (for DNS-less testing)
az containerapp env show \
  --name cae-kt-prod \
  --resource-group $RG \
  --query "properties.staticIp" -o tsv
```

> **Note on ACA DNS**: The internal FQDN (e.g., `ca-hello-korea.internal.<env-unique-id>.koreacentral.azurecontainerapps.io`) resolves via the ACA environment's private DNS zone linked to the VNet. If testing from a VM in the VNet, DNS should resolve automatically. If not, use the static IP directly: `curl -H "Host: <ACA_FQDN>" http://<STATIC_IP>`

### Expected Output

**AKS app:**
```html
<h1>Hello Korea! 🇰🇷</h1><p>Running on <b>AKS</b></p><p>Pod: hello-korea-xxxxx-yyyyy</p>
```

**ACA app:**
```html
<h1>Hello Korea! 🇰🇷</h1><p>Running on <b>Azure Container Apps</b></p><p>Revision: ca-hello-korea--xxxxxxx</p>
```

---

## Network Architecture

```
┌──────────────────────────────────────────────────────────────┐
│  VNet: 10.0.0.0/16                                           │
│                                                              │
│  ┌──────────────────┐  ┌──────────────────────────┐          │
│  │ snet-aks         │  │ snet-aca                 │          │
│  │ 10.0.0.0/22      │  │ 10.0.4.0/23              │          │
│  │                  │  │                          │          │
│  │  AKS (private)   │  │  ACA (internal LB)       │          │
│  │  hello-korea     │◄─┤  ca-hello-korea          │          │
│  │                  │  │                          │          │
│  └────────┬─────────┘  └──────────────────────────┘          │
│           │                                                  │
│  ┌────────▼─────────┐  ┌──────────────────────────┐          │
│  │ NAT Gateway      │  │ snet-postgresql           │          │
│  │ (static public   │  │ 10.0.6.0/24              │          │
│  │  IP for egress)  │  │                          │          │
│  └──────────────────┘  │  PostgreSQL (private DNS) │          │
│                        └──────────────────────────┘          │
│                                                              │
│  Outbound: default_outbound_access_enabled = false (all)     │
│  AKS outbound routed through NAT Gateway (single static IP) │
│                                                              │
│  NSG Rules (AKS subnet):                                    │
│  ✅ Allow VNet ↔ VNet                                        │
│  ✅ Allow → AzureCloud (management)                          │
│  ❌ Deny ← Internet (inbound)                               │
│  ACA: NSG auto-managed by Azure                             │
│  PostgreSQL: delegated subnet, no direct internet            │
└──────────────────────────────────────────────────────────────┘
```

---

## Monitoring & Alerts

All resources send diagnostics to a **single Log Analytics Workspace** per environment (e.g., `law-kt-dev`, `law-kt-prod`):

| Resource | Diagnostics |
|----------|-------------|
| AKS | OMS Agent + Azure Policy (`setByPolicy`) |
| ACA | Built-in LAW integration |
| PostgreSQL | Terraform diagnostic setting (allLogs + AllMetrics) |
| VNet | Terraform diagnostic setting (allLogs + AllMetrics) |
| ACR | Azure Policy (`setByPolicy` — DeployIfNotExists) |
| Key Vault | Azure Policy (`setByPolicy` — DeployIfNotExists) |

Alerts are sent to: **frmagnin@microsoft.com**

### Alert Summary

| Alert | Scope | Severity | Trigger |
|-------|-------|----------|---------|
| Node CPU > 80% | AKS | 2 | Avg CPU across nodes |
| Node Memory > 80% | AKS | 2 | Avg memory across nodes |
| Node Disk > 85% | AKS | 1 | Avg disk usage |
| Pods Not Ready | AKS | 1 | KQL: pods in non-ready state |
| OOMKilled | AKS | 1 | KQL: OOMKilled events |
| Container Restarts > 3 | ACA | 1 | Restart count in 5 min |
| Replicas = 0 | ACA | 0 (Critical) | App has no running replicas |
| PG CPU > 80% | PostgreSQL | 1 | Avg CPU |
| PG Storage > 85% | PostgreSQL | 1 | Avg storage |
| PG Memory > 85% | PostgreSQL | 2 | Avg memory |
| PG High Error Rate | PostgreSQL | 1 | KQL: FATAL/ERROR/PANIC |
| PG Slow Queries | PostgreSQL | 2 | KQL: Duration > 500ms |
| + 8 more PG alerts | PostgreSQL | 1-2 | Various |

---

## CI/CD Pipeline

### Authentication

The pipeline uses **OIDC Workload Identity Federation** — GitHub Actions exchanges a short-lived token with Azure AD, so no client secrets are stored or rotated. This is configured via `scripts/setup-oidc.ps1`.

### Environment Promotion

The pipeline implements a four-stage promotion model:

| Stage | Environment | Trigger | Approval |
|-------|-------------|---------|----------|
| 1 | **DEV** | Push to `main` | Automatic |
| 2 | **TEST** | Successful DEV deployment | Automatic |
| 3 | **QA** | Successful TEST deployment | Human approval required |
| 4 | **PROD** | Successful QA deployment | Human approval required |

Each environment uses an isolated Terraform state file (`kt-infrastructure-{env}.tfstate`) and creates resources with the environment in the name (e.g., `rg-kt-dev`, `aks-kt-prod`).

### Deploy Workflow (`deploy.yml` — `push` to `main` + `workflow_dispatch`)

Each environment stage runs the following jobs:

| Job | Purpose |
|-----|---------||
| **terraform-{env}** | `plan` → `apply` with environment-specific state |
| **build-and-push-{env}** | Builds container images via ACR Tasks |
| **deploy-aks-{env}** | Deploys to AKS via `az aks command invoke` |
| **deploy-aca-{env}** | Updates ACA container app image |

Shared jobs that run once:

| Job | Purpose |
|-----|---------||
| **security-scan** | Runs terraform fmt, tfsec, TFLint, Checkov, TruffleHog, and Trivy |
| **bootstrap** | Creates the Terraform state backend (storage account with Azure AD auth) |
| **manual-terraform** | Plan/destroy operations on individual environments via `workflow_dispatch` |

### PR Checks (`pr-checks.yml` — on `pull_request` to `main`)

| Job | Purpose |
|-----|---------|
| **CodeQL** | SAST analysis for application code (Python) |
| **Dependency Review** | SCA for vulnerable dependencies in PRs |
| **Terraform Validation** | fmt, init, validate, TFLint, tfsec with SARIF upload |
| **Container Scan** | Trivy vulnerability scan of Dockerfiles (HIGH/CRITICAL) |

### Security Scanning

The pipeline includes six security scanners that run before any infrastructure changes:

| Scanner | What it checks |
|---------|---------------|
| **terraform fmt** | Code formatting consistency |
| **tfsec** | Terraform-specific security misconfigurations (SARIF → GitHub Security tab) |
| **TFLint** | Terraform linting and best practices |
| **Checkov** | Broad IaC policy checks (CIS, NIST) with SARIF upload |
| **TruffleHog** | Detects committed secrets and credentials |
| **Trivy** | Container image vulnerability scanning (HIGH/CRITICAL) |

Scanning results are uploaded as SARIF to the GitHub **Security → Code scanning** tab for tfsec and Checkov.

### Dependency Management

Dependabot (`.github/dependabot.yml`) automatically opens PRs for outdated:
- GitHub Actions versions
- Python packages (pip)
- Terraform providers

---

## Cleanup

To tear down resources for a specific environment:

1. Go to **GitHub → Actions → Deploy KT Infrastructure**
2. Click **Run workflow**, select the target **environment** and action = `destroy`

> **Note**: Destroying QA or PROD requires human approval via GitHub Environment protection rules.

Or manually:

```bash
cd terraform
terraform init -backend-config="key=kt-infrastructure-<env>.tfstate" ...
TF_VAR_environment=<env> terraform destroy
```
