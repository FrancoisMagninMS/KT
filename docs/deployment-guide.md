# Hello Korea — Deployment Guide

This guide walks through deploying the two **Hello Korea** sample applications:

| App | Platform | Access |
|-----|----------|--------|
| `hello-korea-aks` | Azure Kubernetes Service (private cluster) | Internal VNet only |
| `hello-korea-aca` | Azure Container Apps (internal environment) | Internal VNet only |

Both services are locked down — no internet inbound or outbound. Communication is allowed only within the private VNet.

---

## Prerequisites

- Azure CLI (`az`) installed and authenticated
- Docker (or Podman) for building container images
- Access to the Azure subscription (`MCAPS-Hybrid-ISD-Incubation`)
- The GitHub Actions workflow has successfully run `apply` on the `feature/hello-korea-apps` branch

---

## Step 1 — Deploy Infrastructure

1. Push the `feature/hello-korea-apps` branch to GitHub (if not already done):

   ```bash
   git push origin feature/hello-korea-apps
   ```

2. Go to **GitHub → Actions → Deploy KT Infrastructure**.

3. Click **Run workflow**, select branch `feature/hello-korea-apps`, action = `apply`.

4. Wait for the workflow to complete. Note the outputs:
   - `acr_login_server` — your ACR login server (e.g. `acrktprodxxxx.azurecr.io`)
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

## Step 5 — Test the Apps

Both apps are internal-only. To test them, you need a resource **inside the VNet** (e.g., a jumpbox VM, Azure Bastion, or VPN connection).

### Option A — Quick test from AKS

Use `az aks command invoke` to curl from inside the cluster:

```bash
# Test AKS app (using the service name within the cluster)
az aks command invoke \
  --resource-group $RG \
  --name $AKS \
  --command "curl -s http://hello-korea.default.svc.cluster.local"

# Test ACA app (using the internal FQDN — requires VNet DNS resolution)
# Get the ACA internal FQDN first:
ACA_FQDN=$(az containerapp show --name ca-hello-korea --resource-group $RG --query "properties.configuration.ingress.fqdn" -o tsv)
echo "ACA FQDN: $ACA_FQDN"
```

### Option B — Test from a VM in the VNet

If you have a VM in the VNet:

```bash
# Test AKS (replace with the LoadBalancer private IP from Step 3)
curl http://<AKS_SERVICE_PRIVATE_IP>

# Test ACA (replace with the internal FQDN)
curl http://<ACA_INTERNAL_FQDN>
```

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
┌─────────────────────────────────────────────────────┐
│  VNet: 10.0.0.0/16                                  │
│                                                     │
│  ┌──────────────────┐  ┌──────────────────────────┐ │
│  │ snet-aks         │  │ snet-aca                 │ │
│  │ 10.0.0.0/22      │  │ 10.0.4.0/23              │ │
│  │                  │  │                          │ │
│  │  AKS (private)   │  │  ACA (internal LB)       │ │
│  │  hello-korea     │◄─┤  ca-hello-korea          │ │
│  │                  │  │                          │ │
│  └──────────────────┘  └──────────────────────────┘ │
│                                                     │
│  ┌──────────────────┐                               │
│  │ snet-postgresql   │                               │
│  │ 10.0.6.0/24      │                               │
│  │                  │                               │
│  │  PostgreSQL       │                               │
│  └──────────────────┘                               │
│                                                     │
│  NSG Rules (both subnets):                          │
│  ✅ Allow VNet ↔ VNet                                │
│  ✅ Allow → AzureCloud (management)                  │
│  ❌ Deny ← Internet (inbound)                       │
│  ❌ Deny → Internet (outbound)                      │
└─────────────────────────────────────────────────────┘
```

---

## Monitoring & Alerts

All resources send diagnostics to a **single Log Analytics Workspace** (`law-kt-prod`):

| Resource | Diagnostics |
|----------|-------------|
| AKS | OMS Agent + platform diagnostics |
| ACA | Built-in LAW integration |
| PostgreSQL | Diagnostic setting (allLogs + AllMetrics) |
| VNet | Diagnostic setting (allLogs + AllMetrics) |
| ACR | Diagnostic setting (allLogs + AllMetrics) |
| Key Vault | Diagnostic setting (allLogs + AllMetrics) |

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

## Cleanup

To tear down all resources:

1. Go to **GitHub → Actions → Deploy KT Infrastructure**
2. Click **Run workflow**, select branch `feature/hello-korea-apps`, action = `destroy`

Or manually:

```bash
cd terraform
terraform destroy
```
