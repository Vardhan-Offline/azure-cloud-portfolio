# Azure VM Auto-Hardening

Fully automated, idempotent PowerShell script that provisions a hardened
Windows Server 2022 VM on Azure — zero portal clicks. Demonstrates
security hardening, zero-touch provisioning, Managed Identity, and
config-driven infrastructure with a single prefix variable controlling
all resource names.

---

## Architecture Diagram

![Architecture](docs/architecture.png)

---

## What This Project Builds

| Resource | Name | Purpose |
|---|---|---|
| Virtual Network | vnet-lkv-hardened | Private network (10.10.0.0/16) |
| Subnet | snet-lkv-vm (10.10.1.0/24) | VM network segment |
| NSG | nsg-lkv-hardened | Allow HTTP/HTTPS, Deny RDP from internet |
| Public IP | pip-lkv-hardened | Static Standard SKU — VM public face |
| NIC | nic-lkv-hardened | VM network interface card |
| VM | vm-lkv-win | Windows Server 2022, Standard_D2s_v5, Trusted Launch |
| OS Disk | osdisk-vm-lkv-win | Standard_LRS managed disk |
| Extension | CustomScriptExtension | Installs IIS + health endpoint inside VM |
| Identity | SystemAssigned | Passwordless Azure AD identity |

---

## Security Features

| Feature | Detail |
|---|---|
| **NSG: Deny RDP** | Explicit deny on :3389 from internet (priority 200) — documented hardening intent |
| **NSG: Allow HTTP/HTTPS** | Ports 80 and 443 only — minimal attack surface |
| **Trusted Launch** | vTPM + Secure Boot — hardware-backed firmware and boot protection |
| **Managed Identity** | SystemAssigned — no passwords in code, config, or environment variables |
| **Boot Diagnostics** | Serial console logging — diagnose VM failures without opening ports |
| **Standard Public IP** | Closed by default — NSG must explicitly allow all traffic |
| **ProtectedSettings** | Custom Script Extension content encrypted at rest and in transit |

---

## NSG Rules

| Rule | Direction | Source | Port | Priority | Action |
|---|---|---|---|---|---|
| Allow-HTTP-Inbound | Inbound | Internet | 80 | 100 | Allow |
| Allow-HTTPS-Inbound | Inbound | Internet | 443 | 110 | Allow |
| Deny-RDP-Internet | Inbound | Internet | 3389 | 200 | **Deny** |

> **Why explicit Deny RDP vs relying on implicit deny?**
> Azure has a built-in DenyAllInbound at priority 65500. Writing an explicit Deny at priority 200
> documents security intent — visible in compliance audit reports as a conscious decision, not an oversight.
> In production: replace direct RDP with Azure Bastion.

---

## Trusted Launch Details

| Feature | What It Protects Against |
|---|---|
| **vTPM (virtual TPM)** | Stores boot measurements — detects if VM firmware was tampered with between reboots |
| **Secure Boot** | Only Microsoft-signed bootloaders run — blocks rootkits and bootkits before OS loads |

> Requires Gen2 image SKU: `2022-datacenter-g2`
> VM size must support Trusted Launch: `Standard_D2s_v5` ✅

---

## Managed Identity Flow

```
vm-lkv-win (SystemAssigned identity)
    |
    | App calls IMDS endpoint (only reachable inside VM):
    | http://169.254.169.254/metadata/identity/oauth2/token
    |
    ▼
Azure AD issues JWT token (valid ~1 hour, auto-refreshed by SDK)
    |
    | Token presented to Azure Key Vault / Storage / SQL
    |
    ▼
Service validates token with Azure AD
    |
    | Checks RBAC / Access Policy permissions
    |
    ▼
Access granted — no password ever transmitted or stored
```

---

## Custom Script Extension Flow

```
deploy.ps1 on your machine
    |
    | 1. IIS setup script written as PowerShell here-string @'...'@
    | 2. Encoded: [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    | 3. Set-AzVMExtension sends to Azure API via ProtectedSettings (encrypted)
    |
Azure Fabric
    |
    | 4. Azure VM Agent (installed during VM provisioning via -ProvisionVMAgent)
    |    receives encoded command
    |
Inside VM (Windows Server 2022) — runs as SYSTEM, no RDP needed
    |
    | 5. powershell.exe -EncodedCommand <base64>
    | 6. Install-WindowsFeature Web-Server
    | 7. [System.IO.File]::WriteAllText() creates health files
    | 8. MIME type .json registered in IIS
    |
    ▼
http://<PUBLIC_IP>                   → IIS home page ✅
http://<PUBLIC_IP>/health/index.json → Health JSON   ✅
```

> **Why `[System.IO.File]::WriteAllText()` not `Set-Content`?**
> `Set-Content` quote escaping gets doubled inside Base64-encoded commands —
> `{"status":"healthy"}` becomes `{\"status\":\"healthy\"}` in the file.
> `WriteAllText()` is a .NET method with no PowerShell reinterpretation layer —
> writes exactly what you provide.

---

## Idempotency Design

Each resource is checked before creation. Running `deploy.ps1` twice produces no errors and no duplicates:

```powershell
$vnet = Get-AzVirtualNetwork -ResourceGroupName $rg -Name $vnetName -ErrorAction SilentlyContinue
if (-not $vnet) {
    # Create VNet
    Write-Status "VNet" $vnetName "Created"
} else {
    Write-Status "VNet" $vnetName "Skipped (exists)"
}
```

**Second run output (all resources existing):**
```
[VNet]     vnet-lkv-hardened     Skipped (exists)
[NSG]      nsg-lkv-hardened      Skipped (exists)
[PIP]      pip-lkv-hardened      Skipped (exists)
[NIC]      nic-lkv-hardened      Skipped (exists)
[VM]       vm-lkv-win            Skipped (exists)
[Identity] vm-lkv-win            Skipped (already enabled)
[IIS]      CustomScriptExtension Skipped (already installed)
```

**Safe for CI/CD pipelines — no side effects on repeated runs.**

---

## Config-Driven Design

All settings live in `scripts/config.ps1`. One variable change creates a
completely separate parallel environment:

```powershell
# scripts/config.ps1
$prefix = "lkv"    # Change this ONE value

# All names derive from it automatically:
$vnetName     = "vnet-$prefix-hardened"   # → vnet-lkv-hardened
$nsgName      = "nsg-$prefix-hardened"    # → nsg-lkv-hardened
$vmName       = "vm-$prefix-win"          # → vm-lkv-win
$nicName      = "nic-$prefix-hardened"    # → nic-lkv-hardened
$publicIpName = "pip-$prefix-hardened"    # → pip-lkv-hardened
```

| Prefix | Environment Created |
|---|---|
| `lkv` | vnet-lkv-hardened, vm-lkv-win (your dev environment) |
| `prod` | vnet-prod-hardened, vm-prod-win (production naming) |
| `lkv2` | vnet-lkv2-hardened, vm-lkv2-win (parallel test environment) |

---

## Tech Stack

- **Automation:** PowerShell Az module 5.x
- **Azure Services:** VNet, NSG, Standard Public IP, NIC, Windows VM,
  Custom Script Extension, Managed Identity, Boot Diagnostics
- **VM OS:** Windows Server 2022 Datacenter Gen2 (Trusted Launch)
- **Web Server:** IIS with `/health/index.json` health endpoint

---

## Repository Structure

```
azure-vm-auto-hardening/
│
├── .gitignore
├── README.md
│
├── scripts/
│   ├── config.ps1          ← Single source of truth (prefix, RG, location, names)
│   ├── prereqs.ps1         ← Environment validation (4 checks)
│   ├── deploy.ps1          ← Idempotent deployment (8 steps)
│   └── cleanup.ps1         ← Safe teardown in dependency order
│
├── extensions/
│   └── install-iis.ps1     ← Reference file: human-readable version of what runs inside VM
│
└── docs/
    ├── architecture.png
    ├── deploy-output.txt
    ├── verification-output.txt
    ├── cleanup-output.txt
    └── screenshots/
        ├── 01-resource-group-overview.png
        ├── 02-vnet-subnet-nsg-attached.png
        ├── 03-nsg-inbound-rules.png
        ├── 04-nsg-outbound-rules.png
        ├── 05-nsg-subnet-association.png
        ├── 06-public-ip-static-standard.png
        ├── 07-vm-overview-running.png
        ├── 08-vm-security-trusted-launch.png
        ├── 09-vm-managed-identity-on.png
        ├── 10-vm-boot-diagnostics.png
        ├── 11-vm-extension-succeeded.png
        ├── 12-browser-iis-home-page.png
        ├── 13-browser-health-endpoint.png
        └── 14-terminal-cleanup-complete.png
```

---

## Prerequisites

- Azure account or Pluralsight sandbox
- PowerShell 7+ (Azure Cloud Shell has this pre-installed)
- Az PowerShell module (`prereqs.ps1` auto-installs if missing)
- Logged in via `Connect-AzAccount` or Azure Cloud Shell session

---

## How to Deploy

```powershell
# 1. Clone the repository
git clone https://github.com/yourusername/azure-vm-auto-hardening.git
cd azure-vm-auto-hardening

# 2. Set your environment values in config.ps1
#    - resourceGroupName  (from: az group list -o table)
#    - location           (from: az group list -o table)
#    - prefix             (your initials)
notepad scripts/config.ps1   # Windows
# or: nano scripts/config.ps1   # Cloud Shell

# 3. Validate environment — all 4 checks must show [OK]
pwsh scripts/prereqs.ps1

# 4. Deploy and save output
pwsh scripts/deploy.ps1 2>&1 | Tee-Object -FilePath "docs/deploy-output.txt"
# Enter VM admin password when prompted
# Takes approximately 12-15 minutes

# 5. Test
# Browser → http://<PUBLIC_IP>
# Browser → http://<PUBLIC_IP>/health/index.json
```

---

## How to Destroy

```powershell
pwsh scripts/cleanup.ps1
# Type: YES when prompted
# Deletes in dependency order: VM → Disk → NIC → PIP → VNet → NSG
```

---

## Script Reference

| Script | Purpose |
|---|---|
| `scripts/config.ps1` | All variables — change `$prefix` here for new environment |
| `scripts/prereqs.ps1` | Validates Az module, Azure connection, config values, RG access |
| `scripts/deploy.ps1` | 8-step idempotent deployment — check-before-create pattern |
| `scripts/cleanup.ps1` | Safe teardown — checks existence before each delete |
| `extensions/install-iis.ps1` | Reference only — shows what runs inside VM via Custom Script Extension |

---

## Deployment Steps

| Step | What Happens | Approx Time |
|---|---|---|
| 0 | Verify Azure connection + subscription | Instant |
| 1 | Create VNet (10.10.0.0/16) + Subnet (10.10.1.0/24) | ~30s |
| 2 | Create NSG (3 rules) + associate to subnet | ~45s |
| 3 | Create Static Standard Public IP | ~20s |
| 4 | Create NIC linked to subnet + public IP | ~20s |
| 5 | Deploy Windows Server 2022 VM (Trusted Launch, D2s_v5) | ~5-8 min |
| 6 | Enable System-Assigned Managed Identity | ~30s |
| 7 | Install IIS + health endpoint via Custom Script Extension | ~3-5 min |

---

## Prereqs Check Output

```
=========================================
 Pre-requisites Check - Project 2
 Prefix : lkv
=========================================

[CHECK 1] config.ps1 values...
  [OK] RG       : 1-eb641c7a-playground-sandbox
  [OK] Location : westus
  [OK] Prefix   : lkv

[CHECK 2] Az PowerShell module...
  [OK] Az.Accounts version: 5.3.2

[CHECK 3] Azure connection...
  [OK] Connected as : MSI@50342
  [OK] Subscription : P8-Real Hands-On Labs

[CHECK 4] Resource group access...
  [OK] RG found    : 1-eb641c7a-playground-sandbox
  [OK] Location    : westus

=========================================
 ALL CHECKS PASSED. Run deploy.ps1
=========================================
```

---

## Deployment Output

```
=========================================
 DEPLOYMENT COMPLETE
=========================================

  Prefix           : lkv
  VM Name          : vm-lkv-win
  VM Size          : Standard_D2s_v5
  Security Type    : Trusted Launch (vTPM + SecureBoot)
  Public IP        : 20.237.247.146
  IIS Home Page    : http://20.237.247.146
  Health Endpoint  : http://20.237.247.146/health/index.json
  Managed Identity : 1229c8e2-d8dc-472b-812c-b42131887949
  Boot Diagnostics : Enabled
  Time elapsed     : 07:00
```

---

## Health Endpoint Response

```
GET http://20.237.247.146/health/index.json

{
  "status": "healthy",
  "service": "vm-lkv-win",
  "version": "1.0",
  "managed_by": "PowerShell",
  "security": "TrustedLaunch"
}
```

---

## Verification Commands

```powershell
# All resources exist
az resource list --resource-group "1-eb641c7a-playground-sandbox" \
  --query "[].{Name:name, Type:type}" -o table

# NSG rules correct
az network nsg rule list --resource-group "1-eb641c7a-playground-sandbox" \
  --nsg-name nsg-lkv-hardened \
  --query "[].{Name:name,Priority:priority,Direction:direction,Access:access,Port:destinationPortRange}" -o table

# VM running
az vm get-instance-view --resource-group "1-eb641c7a-playground-sandbox" \
  --name vm-lkv-win \
  --query "instanceView.statuses[1].displayStatus" -o tsv

# Managed Identity active
az vm identity show --resource-group "1-eb641c7a-playground-sandbox" --name vm-lkv-win

# Extension succeeded
az vm extension list --resource-group "1-eb641c7a-playground-sandbox" \
  --vm-name vm-lkv-win \
  --query "[].{Name:name,State:provisioningState}" -o table

# Trusted Launch confirmed
az vm show --resource-group "1-eb641c7a-playground-sandbox" \
  --name vm-lkv-win \
  --query "{SecurityType:securityProfile.securityType,vTPM:securityProfile.uefiSettings.vTpmEnabled,SecureBoot:securityProfile.uefiSettings.secureBootEnabled}" -o table
```

---

## Screenshots

All verification screenshots in [`docs/screenshots/`](docs/screenshots/).

| # | Screenshot |
|---|---|
| 01 | Resource Group — all resources listed |
| 02 | VNet + subnet with NSG column showing nsg-lkv-hardened |
| 03 | NSG inbound rules (Allow-HTTP-80, Allow-HTTPS-443, Deny-RDP-3389) |
| 04 | NSG outbound rules |
| 05 | NSG subnet association (snet-lkv-vm listed) |
| 06 | Public IP — Static, Standard SKU, IP address |
| 07 | VM Overview — Status: Running, Size: Standard_D2s_v5 |
| 08 | VM Security — Trusted Launch, vTPM ON, Secure Boot ON |
| 09 | VM Identity — SystemAssigned ON, Principal ID visible |
| 10 | VM Boot Diagnostics — Enabled |
| 11 | VM Extensions — CustomScriptExtension: Succeeded |
| 12 | Browser — IIS home page loaded |
| 13 | Browser — /health/index.json JSON response |
| 14 | Terminal — Cleanup complete |

---

## Cost Estimate

| Resource | Estimated Hourly Cost |
|---|---|
| VM Standard_D2s_v5 (2 vCPU, 8GB) | ~$0.096/hr |
| Standard Public IP | ~$0.004/hr |
| Managed Disk (Standard_LRS 128GB) | ~$0.001/hr |
| **Total** | **~$0.10/hr** |

> Tested on Pluralsight Azure sandbox (free).
> For personal Azure accounts: run `cleanup.ps1` immediately after screenshots.
> Full 15-minute test session cost: ~$0.03

---

## Sandbox Adaptations (Pluralsight)

| Constraint | Root Cause | Adaptation |
|---|---|---|
| Location locked to `westus` | Starkiller role scope | Set `$location = "westus"` in config.ps1 |
| RG pre-created by Pluralsight | Sandbox setup | Read RG from `az group list` — don't create it |
| Trusted Launch required | Subscription feature flag | `-SecurityType TrustedLaunch` + `2022-datacenter-g2` SKU |
| Standard_B2s insufficient for IIS | RAM constraint with Windows | Upgraded to `Standard_D2s_v5` (2 vCPU, 8GB RAM) |

---

## Key Learnings

- Idempotency pattern: check-before-create makes scripts safe for CI/CD pipelines
- Config-driven design: one `$prefix` change = fully parallel environment
- `[System.IO.File]::WriteAllText()` vs `Set-Content` inside Base64-encoded commands
- Custom Script Extension = zero-touch VM provisioning, no RDP needed
- `ProtectedSettings` encrypts extension content — use instead of `Settings` for scripts
- System-Assigned Managed Identity lifecycle tied to VM — auto-deleted with VM
- Azure Run Command for VM diagnostics without opening any ports
- Trusted Launch requires Gen2 image SKU (`-g2` suffix) — standard SKU will fail

---

## Author

**L Vardhan**
AZ-900 | AZ-104
[GitHub](https://github.com/yourusername) | [LinkedIn](https://linkedin.com/in/yourprofile)
