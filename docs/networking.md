# Networking Architecture

This document explains the full networking setup of the KT infrastructure — the virtual network, subnets, NAT Gateway, Network Security Groups, DNS, and how traffic flows between components. It's written for people who may not be familiar with Azure networking concepts.

---

## Key Concepts (Quick Primer)

If you're new to Azure networking, here are the building blocks:

| Concept | What It Is | Analogy |
|---|---|---|
| **Virtual Network (VNet)** | A private network in Azure that your resources live in. Resources in a VNet can talk to each other but are isolated from the public internet by default. | Your office LAN |
| **Subnet** | A subdivision of a VNet. Different subnets hold different types of resources and can have different security rules. | Different floors in an office building |
| **CIDR notation** | A way to express IP address ranges. `10.0.0.0/16` means everything from `10.0.0.0` to `10.0.255.255` (65,536 addresses). The smaller the number after `/`, the larger the range. | — |
| **NSG (Network Security Group)** | A set of firewall rules attached to a subnet. Controls what traffic is allowed in and out. | A security guard with a checklist |
| **NAT Gateway** | Allows resources in a private subnet to reach the internet (outbound) using a single static public IP, without being directly reachable from the internet. | A mail room — you can send letters out, but nobody can walk in |
| **Private DNS Zone** | DNS name resolution that only works inside your VNet. External users can't resolve these names. | An internal phone directory |
| **Delegation** | Some Azure services require "ownership" of a subnet — only that service's resources can be placed there. | A reserved parking space |
| **Public IP** | An IP address reachable from the internet. | Your office's street address |
| **SNAT (Source Network Address Translation)** | When a private IP resource talks to the internet, Azure translates its private IP to a public IP. | Like a company switchboard presenting one phone number to outside callers |

---

## Network Topology

```
                          Internet
                             │
                     ┌───────┴───────┐
                     │  NAT Gateway  │  ← pip-nat-kt-{env} (single static public IP)
                     │  natgw-kt-{e} │    All outbound traffic exits through here
                     └───────┬───────┘
                             │
┌────────────────────────────┼────────────────────────────────────────┐
│ VNet: vnet-kt-{env}       │           10.0.0.0/16                  │
│                            │                                        │
│  ┌─────────────────────────┴─────────────────────────┐              │
│  │ snet-aks                10.0.0.0/22               │              │
│  │ (1,024 IPs)             NSG: nsg-aks-kt-{env}     │              │
│  │                         NAT Gateway attached       │              │
│  │  ┌──────────────────────────────────────────────┐ │              │
│  │  │ AKS Private Cluster (aks-kt-{env})           │ │              │
│  │  │  • Nodes get IPs from this subnet (Azure CNI)│ │              │
│  │  │  • Pods get IPs from this subnet (Azure CNI) │ │              │
│  │  │  • No public API server endpoint             │ │              │
│  │  │  • Internal load balancer for services       │ │              │
│  │  └──────────────────────────────────────────────┘ │              │
│  └───────────────────────────────────────────────────┘              │
│                                                                      │
│  ┌───────────────────────────────────────────────────┐              │
│  │ snet-aca                10.0.4.0/23               │              │
│  │ (512 IPs)               NSG: auto-managed by Azure│              │
│  │                         Delegation: Microsoft.App  │              │
│  │  ┌──────────────────────────────────────────────┐ │              │
│  │  │ ACA Environment (cae-kt-{env})               │ │              │
│  │  │  • Internal load balancer (publicNetworkAccess│ │              │
│  │  │    = Disabled)                                │ │              │
│  │  │  • Container Apps run here                    │ │              │
│  │  └──────────────────────────────────────────────┘ │              │
│  └───────────────────────────────────────────────────┘              │
│                                                                      │
│  ┌───────────────────────────────────────────────────┐              │
│  │ snet-postgresql         10.0.6.0/24               │              │
│  │ (256 IPs)               No NSG (delegated)        │              │
│  │                         Delegation: PostgreSQL     │              │
│  │                         Private DNS Zone linked    │              │
│  │  ┌──────────────────────────────────────────────┐ │              │
│  │  │ PostgreSQL Flexible Server (psql-kt-{env})   │ │              │
│  │  │  • public_network_access_enabled = false     │ │              │
│  │  │  • Only reachable from within the VNet       │ │              │
│  │  └──────────────────────────────────────────────┘ │              │
│  └───────────────────────────────────────────────────┘              │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

---

## VNet and Subnets

### VNet

| Property | Value |
|---|---|
| Name | `vnet-{project}-{environment}` (e.g., `vnet-kt-dev`) |
| Address space | `10.0.0.0/16` (65,536 addresses) |
| Region | `koreacentral` |
| Terraform | `azurerm_virtual_network.main` in `terraform/networking.tf` |

The `/16` address space is intentionally large enough to accommodate future growth (new subnets for additional services).

### Subnets

| Subnet | CIDR | Size | Resource | Delegation | NSG |
|---|---|---|---|---|---|
| `snet-aks` | `10.0.0.0/22` | 1,024 IPs | AKS cluster | None | `nsg-aks-kt-{env}` (custom) |
| `snet-aca` | `10.0.4.0/23` | 512 IPs | ACA environment | `Microsoft.App/environments` | Auto-managed by Azure |
| `snet-postgresql` | `10.0.6.0/24` | 256 IPs | PostgreSQL server | `Microsoft.DBforPostgreSQL/flexibleServers` | None (delegated) |

#### Why these sizes?

- **AKS (`/22`)**: Azure CNI assigns each pod a real VNet IP address. With 3 nodes running many pods, you need a large address space. AKS recommends at least `/22` for production clusters.
- **ACA (`/23`)**: Azure Container Apps requires a minimum of `/23` for the managed environment subnet. This is a hard Azure requirement.
- **PostgreSQL (`/24`)**: Only one server lives here, but Azure requires a dedicated delegated subnet. `/24` (256 IPs) is the standard choice.

#### What is `default_outbound_access_enabled = false`?

All three subnets have this setting. By default, Azure gives every resource a hidden method to reach the internet called "default SNAT" — even if you didn't create a NAT Gateway or public IP. This is a security risk because:

1. Resources can phone home to the internet without you knowing
2. The public IP used is shared and unpredictable
3. You can't audit or control what leaves your network

Setting `default_outbound_access_enabled = false` **disables this hidden path**. The only way out to the internet is through the NAT Gateway (which is only attached to the AKS subnet). ACA and PostgreSQL have **no outbound internet access at all**.

---

## NAT Gateway

| Property | Value |
|---|---|
| Name | `natgw-{project}-{environment}` (e.g., `natgw-kt-dev`) |
| SKU | Standard |
| Public IP | `pip-nat-{project}-{environment}` (Static, Standard SKU) |
| Associated subnet | `snet-aks` only |
| Terraform | `azurerm_nat_gateway.main` in `terraform/networking.tf` |

### What it does

The NAT Gateway allows AKS nodes (and their pods) to reach the internet for:
- **Pulling container images** from external registries (Docker Hub, MCR)
- **Downloading packages** (pip, npm, apt during image builds)
- **Azure telemetry** (sending metrics and logs to Azure services)
- **DNS resolution** (resolving external hostnames)

### Why a NAT Gateway and not a regular public IP?

| Approach | Pros | Cons |
|---|---|---|
| **NAT Gateway** (used here) | Single known egress IP; no public IP on any node; can be audited and firewalled; scales to thousands of connections | Monthly cost (~$32/month + data processing) |
| **Load balancer outbound rules** | Free with standard LB | Shared with inbound traffic; SNAT port exhaustion risk |
| **Direct public IP on nodes** | Simple | Every node is directly reachable from the internet (very risky) |
| **Default SNAT** | Zero config | Shared IP, unpredictable, can't be audited, Microsoft may remove it |

### The static public IP

The NAT Gateway uses a single static public IP. This is important because:
- **Firewall whitelisting**: External services can whitelist this one IP (e.g., "only allow connections from `20.x.x.x`")
- **Audit trail**: All outbound traffic from AKS exits through one known IP that appears in Network Watcher flow logs
- **Consistency**: The IP doesn't change across restarts or redeployments

You can find this IP in the Terraform output: `nat_gateway_public_ip`.

### What about ACA and PostgreSQL?

Neither ACA nor PostgreSQL has a NAT Gateway attached. Combined with `default_outbound_access_enabled = false`, these subnets have **no path to the internet**. This is intentional:

- **ACA**: Runs internal workloads only. The ACA environment is configured with `internal = true` and `publicNetworkAccess = "Disabled"`.
- **PostgreSQL**: A database should never reach out to the internet. It only needs VNet connectivity to receive connections from AKS and ACA.

---

## Network Security Group (NSG)

An NSG is a stateful firewall for a subnet. It contains ordered rules that `Allow` or `Deny` traffic by direction, protocol, source, and destination.

### AKS Subnet NSG

| Priority | Name | Direction | Action | Source | Destination | Purpose |
|---|---|---|---|---|---|---|
| 100 | AllowVNetInbound | Inbound | Allow | VirtualNetwork | VirtualNetwork | Pods ↔ Pods, Nodes ↔ Nodes, AKS ↔ PostgreSQL |
| 110 | AllowAzureLoadBalancerInbound | Inbound | Allow | AzureLoadBalancer | * | Azure health probes for the internal load balancer |
| 4000 | DenyInternetInbound | Inbound | Deny | Internet | * | Block any inbound traffic from the internet |
| 100 | AllowVNetOutbound | Outbound | Allow | VirtualNetwork | VirtualNetwork | Pod-to-pod, node-to-node, AKS ↔ PostgreSQL |
| 200 | AllowAzureCloudOutbound | Outbound | Allow | * | AzureCloud | AKS management plane, Azure Monitor, ACR, Key Vault |

#### How to read NSG rules

- Rules are evaluated in **priority order** (lowest number first)
- The **first matching rule wins** — subsequent rules are not evaluated
- **Stateful**: If outbound traffic is allowed, the response is automatically allowed inbound (you don't need a separate rule)
- **VirtualNetwork** is a service tag that means "any address in this VNet or peered VNets"
- **AzureCloud** is a service tag that means "any Azure datacenter IP" — needed because AKS nodes talk to Azure APIs for management, monitoring, and image pulling
- **AzureLoadBalancer** is a service tag for Azure's internal health probe system

#### Why no Internet outbound rule?

The NAT Gateway handles outbound internet connectivity. NSG rules for outbound internet would be redundant — NAT Gateway provides the path, and the NSG's `AllowAzureCloudOutbound` rule covers Azure service endpoints. All other outbound traffic goes through VNet routing to the NAT Gateway.

### ACA Subnet — No Custom NSG

Azure Container Apps automatically manages its own NSG on the ACA subnet. **Do not create or attach a custom NSG** — it will conflict with ACA's managed rules and can break the environment.

### PostgreSQL Subnet — No NSG

The PostgreSQL subnet is delegated to `Microsoft.DBforPostgreSQL/flexibleServers`. Delegated subnets have their own access controls managed by the Azure service. Adding an NSG is not needed (and in some cases not supported for delegated subnets).

---

## Private DNS

### PostgreSQL Private DNS Zone

| Property | Value |
|---|---|
| Zone name | `{project}{environment}.postgres.database.azure.com` (e.g., `ktdev.postgres.database.azure.com`) |
| Linked to | `vnet-{project}-{environment}` |
| Terraform | `azurerm_private_dns_zone.postgresql` in `terraform/postgresql.tf` |

When the PostgreSQL Flexible Server is created with VNet integration, Azure registers its FQDN in this private DNS zone. Any resource in the VNet can resolve `psql-kt-dev.ktdev.postgres.database.azure.com` to the server's private IP — but resources outside the VNet cannot.

This means:
- **AKS pods can connect** to PostgreSQL using the FQDN (not a raw IP address)
- **ACA containers can connect** to PostgreSQL using the FQDN
- **Nobody on the internet** can resolve or reach the database

### AKS Private DNS

AKS creates its own private DNS zone for the Kubernetes API server (because `private_cluster_enabled = true`). This is fully managed by Azure — you don't need to create it.

---

## Traffic Flow Diagrams

### AKS Pod → PostgreSQL (internal, VNet-to-VNet)

```
Pod (10.0.x.x)                   PostgreSQL (10.0.6.x)
     │                                  ▲
     │ DNS: psql-kt-dev.ktdev.         │
     │       postgres.database.        │
     │       azure.com                 │
     │                                  │
     └──── snet-aks ──── VNet ──── snet-postgresql ────┘
           NSG: AllowVNetOutbound       (delegated, no NSG)
```

- Traffic stays entirely within the VNet
- NSG rule `AllowVNetOutbound` on the AKS subnet permits it
- PostgreSQL accepts connections from the delegated subnet
- DNS resolution happens via the private DNS zone

### AKS Pod → Internet (outbound via NAT Gateway)

```
Pod (10.0.x.x)     NAT Gateway         Internet
     │                  │                  ▲
     │                  │                  │
     └── snet-aks ──────┘                  │
         NAT Gateway    pip-nat-kt-{env} ──┘
         translates     (e.g., 20.39.x.x)
         10.0.x.x → 20.39.x.x
```

- Pod sends a request to an internet address
- Traffic routes to the NAT Gateway (attached to snet-aks)
- NAT Gateway translates the source IP from the pod's private IP to the static public IP
- External service sees the request coming from `20.39.x.x`
- Response comes back to the NAT Gateway, which routes it back to the pod

### Internet → AKS (blocked)

```
Internet                  AKS
   │                       ✗ BLOCKED
   │                       │
   └── NSG: DenyInternetInbound (priority 4000)
```

- No inbound traffic from the internet can reach AKS nodes or pods
- The AKS API server is private (no public endpoint)
- The internal load balancer for K8s services is VNet-only

### ACA → PostgreSQL (internal, VNet-to-VNet)

```
ACA Container (10.0.4.x)        PostgreSQL (10.0.6.x)
     │                                ▲
     └─── snet-aca ─── VNet ─── snet-postgresql ───┘
          (ACA-managed NSG)           (delegated)
```

Same pattern as AKS-to-PostgreSQL — all traffic stays within the VNet.

---

## Security Posture Summary

| Principle | How It's Implemented |
|---|---|
| **No public endpoints** | AKS API server is private; ACA is internal-only; PostgreSQL has `public_network_access_enabled = false` |
| **No default SNAT** | `default_outbound_access_enabled = false` on all subnets |
| **Controlled egress** | Only AKS has internet access, via NAT Gateway with a known static public IP |
| **No internet ingress** | NSG rule `DenyInternetInbound` blocks all inbound from internet on AKS subnet; ACA and PostgreSQL subnets don't expose anything |
| **Network segmentation** | Three separate subnets with different security profiles |
| **VNet-only communication** | All service-to-service traffic uses private VNet IPs |
| **Private DNS** | PostgreSQL is only resolvable within the VNet |
| **Audit trail** | All egress uses one public IP; VNet flow logs go to Log Analytics |

---

## Common Questions

### Can I SSH into AKS nodes?

No. AKS nodes have no public IPs and inbound internet is blocked. To debug nodes, use `az aks command invoke` (which tunnels through the Azure API, not through the network) or `kubectl debug node/<node-name>`.

### Can I access PostgreSQL from my local machine?

Not directly — it's private. Options:
1. Use a jump box/bastion VM in the VNet
2. Set up Azure VPN Gateway or ExpressRoute
3. Use `az postgres flexible-server connect` with Azure Cloud Shell (which runs inside Azure)

### Why can't ACA reach the internet?

By design. ACA runs internal workloads that don't need internet access. If you add a workload that needs to call an external API, you'll need to either:
1. Attach a NAT Gateway to the ACA subnet
2. Use a user-defined route (UDR) to route traffic through a firewall or existing NAT Gateway

### What if I need to add another subnet?

1. Choose an unused CIDR range in `10.0.0.0/16` (e.g., `10.0.8.0/24`)
2. Add a new `azurerm_subnet` resource in `terraform/networking.tf`
3. Set `default_outbound_access_enabled = false`
4. Add NSG rules if needed
5. If the subnet needs internet access, create a NAT Gateway association

### Can AKS and ACA talk to each other?

Yes — both subnets are in the same VNet with VirtualNetwork ↔ VirtualNetwork traffic allowed. AKS pods can reach ACA's internal FQDN, and vice versa.

---

## Terraform Files

| File | Contains |
|---|---|
| `terraform/networking.tf` | VNet, subnets, NAT Gateway, public IP, NSG, NSG rules, subnet associations |
| `terraform/postgresql.tf` | Private DNS zone, VNet link, PostgreSQL server (VNet-integrated) |
| `terraform/aks.tf` | AKS cluster with private cluster, Azure CNI, NAT Gateway outbound type |
| `terraform/aca.tf` | ACA managed environment with internal load balancer |
| `terraform/variables.tf` | `vnet_address_space`, `aks_subnet_prefix`, `aca_subnet_prefix`, `pg_subnet_prefix` |

---

## IP Address Map

| Range | Subnet | Used By |
|---|---|---|
| `10.0.0.0` – `10.0.3.255` | `snet-aks` (`/22`) | AKS nodes and pods (Azure CNI) |
| `10.0.4.0` – `10.0.5.255` | `snet-aca` (`/23`) | ACA managed environment |
| `10.0.6.0` – `10.0.6.255` | `snet-postgresql` (`/24`) | PostgreSQL Flexible Server |
| `10.0.7.0` – `10.0.255.255` | Unallocated | Available for future subnets |
| `10.1.0.0/16` | — | AKS Kubernetes service CIDRs (virtual, not in VNet) |
| `10.1.0.10` | — | AKS DNS service IP |
