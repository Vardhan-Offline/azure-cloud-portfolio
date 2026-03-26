# azure-cloud-portfolio
Azure Infrasturcture as Code Portfolio - Terraform 3-tier Architecture, PowerShell VM Hardening and Automated Monitoring with auto Remediation

# Azure Cloud & DevOps Portfolio

Three end-to-end Azure infrastructure projects demonstrating **Infrastructure as Code**, **security hardening**, **monitoring**, and **automated remediation** — all deployed with zero portal clicks.

---

## Projects

### [Project 1: Enterprise 3-Tier Network Architecture (Terraform)](./project1-3tier-terraform/)

Deploys a **production-grade 3-tier network** on Azure using Terraform — VNet with Web, App, and Data subnets, NSGs with zero-trust firewall rules, a Standard Load Balancer, VMs with Managed Identity, and Azure Key Vault for secrets management.

| Metric | Value |
|--------|-------|
| **IaC Tool** | Terraform (azurerm provider) |
| **Resources** | 27 (VNet, 3 Subnets, 3 NSGs, Load Balancer, 3 VMs, Key Vault, Managed Identities) |
| **Key Skills** | Network segmentation, NSG rules, Load Balancer 5-tuple hash, Key Vault, Managed Identity |
| **Deploy Time** | ~5 minutes |

---

### [Project 2: Automated VM Provisioning & Hardening (PowerShell)](./project2-vm-hardening/)

Provisions a **hardened Windows Server 2022 VM** using PowerShell — Trusted Launch (vTPM + Secure Boot), explicit RDP denial, System-Assigned Managed Identity, Boot Diagnostics, and zero-touch IIS installation via Custom Script Extension. No RDP connection needed.

| Metric | Value |
|--------|-------|
| **IaC Tool** | PowerShell Az module |
| **Resources** | 7 (VNet, Subnet, NSG, Public IP, NIC, VM, Custom Script Extension) |
| **Key Skills** | Trusted Launch, Custom Script Extension, Managed Identity, Boot Diagnostics, Idempotent scripting |
| **Deploy Time** | ~8 minutes |

---

### [Project 3: Azure Monitoring & Auto-Remediation Pipeline (PowerShell)](./project3-monitoring-automation/)

Builds an **end-to-end observability and auto-remediation pipeline** — Azure Monitor detects high CPU, fires an alert, sends email notification, and triggers an Automation runbook via webhook to automatically restart the VM. Zero human intervention.

| Metric | Value |
|--------|-------|
| **IaC Tool** | PowerShell Az module (Az.Monitor, Az.Automation, Az.OperationalInsights) |
| **Resources** | 7 (Log Analytics, Automation Account, Runbook, Webhook, Action Group, Alert Rule, Diagnostic Setting) |
| **Key Skills** | Azure Monitor, Metric Alerts, Action Groups, Webhooks, Automation Runbooks, Managed Identity, KQL |
| **Deploy Time** | ~4 minutes |

---

## Architecture Overview

```
PROJECT 1 (Networking)          PROJECT 2 (Compute)           PROJECT 3 (Monitoring)
━━━━━━━━━━━━━━━━━━━━━          ━━━━━━━━━━━━━━━━━━━           ━━━━━━━━━━━━━━━━━━━━━━

┌─────────────────┐            ┌─────────────────┐            ┌─────────────────┐
│  Terraform       │            │  PowerShell      │            │  PowerShell      │
│  3-Tier Network  │            │  Hardened VM     │───────────►│  Monitor + Alert │
│  27 resources    │            │  7 resources     │  monitors  │  7 resources     │
└─────────────────┘            └─────────────────┘            └─────────────────┘

Skills: VNet, NSG,              Skills: Trusted Launch,        Skills: Azure Monitor,
Load Balancer, Key Vault        Custom Script Extension,       Runbooks, Webhooks,
Managed Identity, HCL           Boot Diagnostics, IIS          KQL, Auto-Remediation
```

## Common Themes Across All Projects

- **Managed Identity** — Passwordless authentication (no stored credentials)
- **Idempotent Deployment** — Run scripts multiple times with identical results
- **Config-Driven Design** — Change one `$prefix` variable → new environment
- **Security First** — Zero-trust NSG rules, explicit deny, Trusted Launch, Key Vault
- **Zero Portal Clicks** — Everything automated via Terraform or PowerShell

---

## Tech Stack

| Technology | Used In |
|-----------|---------|
| **Terraform** (HCL) | Project 1 |
| **PowerShell** (Az module) | Projects 2 & 3 |
| **Azure Virtual Network** | Projects 1 & 2 |
| **NSG (Firewall Rules)** | Projects 1 & 2 |
| **Azure Load Balancer** | Project 1 |
| **Azure Key Vault** | Project 1 |
| **Managed Identity** | All 3 Projects |
| **Trusted Launch (vTPM)** | Project 2 |
| **Custom Script Extension** | Project 2 |
| **Azure Monitor** | Project 3 |
| **Log Analytics (KQL)** | Project 3 |
| **Automation Runbooks** | Project 3 |
| **Webhooks** | Project 3 |

---

## Author

**Lakkoju Keerthi Vardhan**
- AZ-900 | AZ-104 | AI-900
- [LinkedIn](https://www.linkedin.com/in/keerthi-vardhan-lakkoju-197b9328b)
README.md
Displaying README.md.
