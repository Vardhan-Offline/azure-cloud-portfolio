# Azure 3-Tier Secure Environment

A production-grade, secure 3-tier architecture on Azure provisioned entirely
via Terraform — zero portal clicks. Demonstrates network segmentation,
defense-in-depth security, load balancing, and passwordless authentication
using Managed Identity.

---

## Architecture Diagram

![Architecture](docs/architecture.png)

---

## What This Project Builds

| Resource | Name | Purpose |
|---|---|---|
| Virtual Network | vnet-3tier-eastus | Private network container (10.0.0.0/16) |
| Subnet — Web | snet-web (10.0.1.0/24) | Front-end VMs — faces internet |
| Subnet — App | snet-app (10.0.2.0/24) | Application VMs — internal only |
| Subnet — DB | snet-db (10.0.3.0/24) | Database — most isolated |
| NSG — Web | nsg-web | Allow :443/:80 IN, Allow :8080 OUT to app |
| NSG — App | nsg-app | Allow :8080 from web only, Deny internet IN |
| NSG — DB | nsg-db | Allow :1433 from app only, Deny all other |
| Public IP | pip-lb-web | Static Standard SKU — LB frontend |
| Load Balancer | lb-web-frontend | Standard SKU, TCP health probe (15s/2 failures) |
| VM — Web x2 | vm-web-01, vm-web-02 | Ubuntu 20.04, Standard_B1s, SystemAssigned identity |
| VM — App | vm-app-01 | Ubuntu 20.04, Standard_B1s, SystemAssigned identity |
| Key Vault | kv-3tier-lkv-001 | Stores DB connection string securely |
| KV Access Policy 1 | Admin | Full secret management (deploy time) |
| KV Access Policy 2 | vm-app-01 identity | Get/List only (runtime — least privilege) |

**Total resources deployed: 27**

---

## Security Design

```
INTERNET → Web Tier (NSG: :443/:80 only)
               ↓ :8080
          App Tier (NSG: Web subnet only, no internet)
               ↓ :1433
           DB Tier (NSG: App subnet only, deny all else + internet OUT)
```

- Each tier is isolated in its own subnet with a dedicated NSG
- App tier is completely unreachable from the internet
- Database tier cannot initiate outbound internet connections
- No credentials in code — app VM uses Managed Identity to read Key Vault secrets
- Load Balancer health probe automatically removes unhealthy VMs from rotation

---

## NSG Rules — Per Tier

### Web NSG (nsg-web)

| Rule | Direction | Source | Port | Action |
|---|---|---|---|---|
| Allow-HTTPS-Inbound | Inbound | Internet | 443 | Allow |
| Allow-HTTP-Inbound | Inbound | Internet | 80 | Allow |
| Allow-Outbound-To-App | Outbound | 10.0.1.0/24 | 8080 | Allow |

### App NSG (nsg-app)

| Rule | Direction | Source | Port | Action |
|---|---|---|---|---|
| Allow-Inbound-From-Web | Inbound | 10.0.1.0/24 | 8080 | Allow |
| Deny-Internet-Inbound | Inbound | Internet | Any | **Deny** |
| Allow-Outbound-To-DB | Outbound | 10.0.2.0/24 | 1433 | Allow |

### DB NSG (nsg-db)

| Rule | Direction | Source | Port | Action |
|---|---|---|---|---|
| Allow-Inbound-From-App | Inbound | 10.0.2.0/24 | 1433 | Allow |
| Deny-All-Other-Inbound | Inbound | Any | Any | **Deny** |
| Deny-Internet-Outbound | Outbound | Any | Internet | **Deny** |

---

## Load Balancer Design

| Component | Configuration |
|---|---|
| SKU | Standard |
| Frontend IP | pip-lb-web — Static, Standard |
| Backend Pool | vm-web-01, vm-web-02 |
| Health Probe | TCP :443, every 15 seconds, 2 failure threshold |
| LB Rule | Port 443 → 443, DNAT to backend pool |
| Distribution | 5-tuple hash (Source IP, Source Port, Dest IP, Dest Port, Protocol) |

**Health probe cycle:**
```
Every 15 seconds per VM:
  TCP connect on :443 succeeds → VM stays in rotation    ✅
  TCP connect fails × 2 in a row → VM removed           ❌
  TCP connect succeeds × 2 after recovery → VM re-added ✅
```

---

## Managed Identity Flow

```
vm-app-01 (SystemAssigned identity)
    |
    | 1. App calls IMDS: http://169.254.169.254/metadata/identity/oauth2/token
    |
    ▼
Azure AD issues JWT token (valid ~1 hour, auto-refreshed by SDK)
    |
    | 2. App presents token to Key Vault
    |
    ▼
Key Vault validates token with Azure AD
    |
    | 3. Key Vault checks Access Policy: does this identity have Get/List?
    |
    ▼
Key Vault returns secret value — no password ever transmitted
```

---

## Tech Stack

- **IaC:** Terraform >= 1.5.0
- **Provider:** azurerm ~> 3.90.0
- **Azure Services:** VNet, NSG, Standard Load Balancer, Linux VM (Ubuntu 20.04),
  Key Vault, Managed Identity, Boot Diagnostics
- **Authentication:** Azure CLI (`az login`) + System-Assigned Managed Identity

---

## Repository Structure

```
azure-3tier-secure-env/
│
├── .gitignore
├── README.md
│
├── terraform/
│   ├── providers.tf                    ← Provider + auth + Key Vault features
│   ├── variables.tf                    ← All input declarations
│   ├── main.tf                         ← All Azure resources
│   ├── outputs.tf                      ← Display values post-apply
│   ├── terraform.tfvars.example        ← Commit this (placeholder values)
│   └── terraform.tfvars                ← GITIGNORED (real password)
│
└── docs/
    ├── architecture.png
    ├── terraform-plan-output.txt
    ├── terraform-apply-idempotency.txt
    └── screenshots/
        ├── 01-resource-group-overview.png
        ├── 02-vnet-overview.png
        ├── 03-vnet-subnets-nsg-attached.png
        ├── 04-nsg-web-inbound.png
        ├── 05-nsg-web-outbound.png
        ├── 06-nsg-web-subnet-association.png
        ├── 07-nsg-app-inbound.png
        ├── 08-nsg-app-outbound.png
        ├── 09-nsg-db-inbound.png
        ├── 10-nsg-db-outbound.png
        ├── 11-lb-frontend-ip.png
        ├── 12-lb-backend-pool.png
        ├── 13-lb-health-probe.png
        ├── 14-lb-rule.png
        ├── 15-app-vm-managed-identity.png
        ├── 16-keyvault-overview.png
        ├── 17-keyvault-access-policies.png
        ├── 18-keyvault-secret.png
        ├── 19-terraform-apply-success.png
        └── 20-terraform-destroy-complete.png
```

---

## Prerequisites

- Azure account or Pluralsight sandbox
- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5.0
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)
- Logged in via `az login`

---

## How to Deploy

```bash
# 1. Clone the repository
git clone https://github.com/yourusername/azure-3tier-secure-env.git
cd azure-3tier-secure-env/terraform

# 2. Login to Azure
az login
az account show   # Verify correct subscription

# 3. Copy and fill in your variable values
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — set admin_password and key_vault_name

# 4. Initialize Terraform (downloads azurerm provider ~60MB)
terraform init

# 5. Validate syntax
terraform validate

# 6. Preview what will be created — read this before applying
terraform plan

# 7. Deploy (takes ~8-12 minutes)
terraform apply
# Type: yes when prompted
```

---

## How to Destroy

```bash
terraform destroy
# Type: yes when prompted
# All 27 resources deleted — output confirms count
```

---

## Variable Reference

| Variable | Description | Default |
|---|---|---|
| `location` | Azure region — locked to eastus for sandbox | `eastus` |
| `resource_group_name` | Pre-existing RG (sandbox) or new RG | `rg-3tier-secure-prod` |
| `admin_username` | VM admin username | `azureadmin` |
| `admin_password` | VM admin password — **set in tfvars only, never hardcode** | *(required)* |
| `key_vault_name` | **Globally unique** — change `lkv` to your initials | `kv-3tier-lkv-001` |

> Password requirements: min 12 chars, 1 uppercase, 1 lowercase, 1 number, 1 special char

---

## Idempotency Proof

Running `terraform apply` a second time with no `.tf` changes:

```
Apply complete! Resources: 0 added, 0 changed, 0 destroyed.
```

Full output saved in `docs/terraform-apply-idempotency.txt`

---

## Terraform Key Concepts Used

| Concept | Where Used | Why |
|---|---|---|
| `data` block | Resource Group, client config | Read existing resources — not created by Terraform |
| `resource` block | All Azure resources | Created and managed by Terraform |
| `sensitive = true` | admin_password variable | Masks value in all output and logs |
| `depends_on` | KV Secret | Explicit dependency when Terraform cannot infer order |
| `~> version` | azurerm provider | Allow patch updates, block major version changes |
| `purge_soft_delete_on_destroy` | Key Vault features block | Required for sandbox re-deployment |
| Implicit dependency | All resource references | Terraform builds correct creation order automatically |

---

## Sandbox Adaptations (Pluralsight)

| Constraint | Root Cause | Adaptation |
|---|---|---|
| RG already exists | Pluralsight pre-creates it | `data` block instead of `resource` block |
| Location locked to `eastus` | Starkiller role scope | Hardcoded location variable |
| Cannot write AAD RBAC assignments | Starkiller role has no subscription-level write | Key Vault Access Policies instead of `azurerm_role_assignment` |
| Soft-deleted KV blocks re-deploy | Azure KV soft-delete protection | `purge_soft_delete_on_destroy = true` in provider |

---

## Deployment Output

```
Apply complete! Resources: 27 added, 0 changed, 0 destroyed.

Outputs:

app_vm1_private_ip                    = "10.0.2.4"
app_vm_managed_identity_principal_id  = "9ef13cff-b286-4152-bcb9-122f47a14b75"
key_vault_uri                         = "https://kv-3tier-lkv-001.vault.azure.net/"
load_balancer_public_ip               = "20.127.77.203"
resource_group_name                   = "1-27cc5856-playground-sandbox"
web_vm1_private_ip                    = "10.0.1.5"
web_vm2_private_ip                    = "10.0.1.4"
```

---

## Screenshots

All verification screenshots in [`docs/screenshots/`](docs/screenshots/).

| # | Screenshot |
|---|---|
| 01 | Resource Group — all 27 resources listed |
| 02 | VNet overview (10.0.0.0/16) |
| 03 | Subnets with NSG column showing association |
| 04-06 | NSG Web — inbound rules, outbound rules, subnet association |
| 07-09 | NSG App — inbound rules (Web-only source), outbound rules |
| 10-11 | NSG DB — inbound rules (App-only source), outbound deny |
| 12-15 | Load Balancer — frontend IP, backend pool, health probe, LB rule |
| 16 | App VM — Identity blade, SystemAssigned ON, Principal ID |
| 17-19 | Key Vault — overview, access policies (2 entries), secret |
| 20 | terraform apply — terminal output (27 resources) |
| 21 | terraform destroy — terminal output (clean teardown) |

---

## Cost Estimate

| Resource | Estimated Monthly Cost |
|---|---|
| 3x VMs (Standard_B1s) | ~$31 |
| Standard Load Balancer | ~$18 |
| Public IP (Standard) | ~$3 |
| Key Vault (Standard) | ~$1 |
| **Total (if left running)** | **~$53/month** |

> Tested on Pluralsight Azure sandbox (free credit).
> For personal Azure accounts: run `terraform destroy` immediately after screenshots.
> Estimated cost for a 1-hour test session: ~$0.07

---

## Key Learnings

- `data` vs `resource` — reading existing resources vs creating new ones
- NSG association is separate — creating NSG alone enforces nothing
- `depends_on` for explicit dependency when references cannot be inferred
- `sensitive = true` prevents credentials appearing in logs or terminal output
- Key Vault soft-delete must be purged for clean sandbox re-deployments
- Terraform state is Terraform's memory — never delete or commit it to Git
- Access Policies work within sandbox constraints where RBAC role assignment is blocked

---

## Author

**L Vardhan**
AZ-900 | AZ-104
[GitHub](https://github.com/yourusername) | [LinkedIn](https://linkedin.com/in/yourprofile)
