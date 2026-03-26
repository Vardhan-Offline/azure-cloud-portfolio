# Azure Monitoring & Automation

Fully automated, idempotent PowerShell solution that provisions an end-to-end
Azure monitoring and auto-remediation pipeline — zero portal clicks. Monitors a
Windows Server VM for high CPU, sends an email alert, and automatically triggers
an Azure Automation runbook to restart the VM.

Builds on [Project 2: VM Auto-Hardening](https://github.com/yourusername/azure-vm-auto-hardening)
by adding observability and automated remediation to the `vm-lkv-win` VM.

---

## Architecture Diagram

![Architecture](docs/architecture.png)

```
                        ┌─────────────────────────────────────────────────────┐
                        │              Azure Monitor                          │
                        │                                                     │
  vm-lkv-win  ─────────►│  Percentage CPU > 75%                               │
  (from P2)   metrics   │  averaged over 5 minutes                           │
                        │  evaluated every 1 minute                          │
                        │                                                     │
                        │  Alert Rule: alert-lkv-cpu-high  (Severity 2)      │
                        └──────────────────────┬──────────────────────────────┘
                                               │ fires
                                               ▼
                        ┌─────────────────────────────────────────────────────┐
                        │           Action Group: ag-lkv-cpu-alert            │
                        │                                                     │
                        │  ① Email receiver  ──────────► your@email.com      │
                        │  ② Webhook receiver ────────────────────────────┐  │
                        └─────────────────────────────────────────────────│──┘
                                                                          │ POST
                                                                          ▼
                        ┌─────────────────────────────────────────────────────┐
                        │       Automation Account: aa-lkv-monitor            │
                        │                                                     │
                        │  Webhook: wh-lkv-restart-vm                        │
                        │         │                                           │
                        │         ▼  triggers                                 │
                        │  Runbook: Restart-AzureVM (PowerShell)              │
                        │         │  Connect-AzAccount -Identity             │
                        │         │  (Managed Identity auth)                 │
                        │         ▼                                           │
                        │  Restart-AzVM vm-lkv-win                           │
                        └─────────────────────────────────────────────────────┘
                                               │
                        ┌─────────────────────────────────────────────────────┐
                        │    Log Analytics Workspace: law-lkv-monitor         │
                        │                                                     │
                        │  Diagnostic Setting: VM → AllMetrics               │
                        │  Query CPU trends with KQL                         │
                        └─────────────────────────────────────────────────────┘
```

---

## What This Project Builds

| Resource | Name | Purpose |
|---|---|---|
| Log Analytics Workspace | law-lkv-monitor | Receives VM metrics, enables KQL queries |
| Automation Account | aa-lkv-monitor | Hosts runbooks, has Managed Identity |
| Runbook | Restart-AzureVM | PowerShell script that restarts the target VM |
| Webhook | wh-lkv-restart-vm | Secret URL that triggers the runbook |
| Action Group | ag-lkv-cpu-alert | Sends email + calls webhook when alert fires |
| Metric Alert Rule | alert-lkv-cpu-high | Triggers when CPU > 75% for 5 min |
| Diagnostic Setting | diag-lkv-vm-to-law | Streams VM metrics to Log Analytics |

---

## Alert Rule Design

| Property | Value | Why |
|---|---|---|
| **Metric** | `Percentage CPU` | Built-in VM metric — no agent required |
| **Operator** | GreaterThan | Trigger when CPU exceeds threshold |
| **Threshold** | 75% | High enough to catch real issues, low enough to catch before outage |
| **Time aggregation** | Average | Smooths short spikes — responds to sustained load |
| **Window size** | 5 minutes | Avoids false positives from momentary bursts |
| **Evaluation frequency** | 1 minute | Checks every minute within the 5-min window |
| **Severity** | 2 (Warning) | Below Critical (1) — VM still running but needs attention |
| **Auto-mitigate** | true | Alert auto-resolves when CPU drops below threshold |

> **Why Average over 5 minutes, not Maximum?**
> Maximum CPU would trigger on any 1-second spike during the window — too noisy.
> Average over 5 minutes means CPU has been consistently high, indicating a real problem.

---

## Automation Flow — Alert to Runbook

```
1. CPU > 75% average over 5 minutes on vm-lkv-win

2. Azure Monitor evaluates rule every 1 minute
   → Condition met → Alert fires (Severity 2: Warning)

3. Action Group triggered simultaneously:
   ① Email sent to alertEmailAddress
   ② HTTP POST to webhook URL (wh-lkv-restart-vm)
      Body: Common Alert Schema JSON containing:
        - alertRule name
        - severity
        - alertTargetIDs[0] = VM resource ID

4. Webhook triggers Automation Account runbook: Restart-AzureVM

5. Runbook execution (inside Azure, not your local machine):
   a. Parse Common Alert Schema — extract RG and VM name from resource ID
   b. Connect-AzAccount -Identity  (uses Automation Account Managed Identity)
   c. Get-AzVM -Status             (check current power state)
   d. Restart-AzVM                 (if VM running)
      Start-AzVM                   (if VM deallocated or stopped)
   e. Wait 60 seconds, verify new state

6. CPU drops as VM reboots → Azure Monitor auto-resolves the alert
```

---

## Managed Identity Flow — Runbook Authentication

```
Automation Account aa-lkv-monitor
    │
    │  System-Assigned Identity enabled
    │  Principal ID: <output after deploy>
    │
    ▼
Azure AD Object Representing the Automation Account
    │
    │  Role Assignment (manual step in sandbox):
    │  Virtual Machine Contributor on vm-lkv-win
    │
    ▼
Inside running runbook:
    Connect-AzAccount -Identity
    ↓
    IMDS endpoint (169.254.169.254) issues Azure AD token
    ↓
    Token used for all subsequent Az cmdlets
    ↓
    Restart-AzVM  succeeds  (no password, no stored credentials)
```

> **Why Managed Identity instead of a Service Principal with a password?**
> Service Principal credentials expire, can be leaked in code, require rotation.
> Managed Identity credentials are issued on-demand by Azure AD, valid for ~1 hour,
> auto-rotated, and never visible to any human or stored anywhere.

---

## Webhook Security

| Property | Detail |
|---|---|
| URL structure | Contains a 64-character random token in the query string |
| Storage | Saved to `docs/webhook-url.txt` on your machine (`.gitignored`) |
| Transmission | HTTPS only — token never sent in plaintext |
| Expiry | 1 year from creation (set in deploy.ps1) |
| Rotation | If compromised: delete webhook in portal, re-run deploy.ps1 |
| Azure protection | URL cannot be retrieved after creation — stored hash only |

> **Warning:** Never commit `docs/webhook-url.txt` to GitHub.
> The `.gitignore` prevents this — verify before `git add .`

---

## Common Alert Schema — Payload Structure

What Azure Monitor sends to your webhook (what the runbook parses):

```json
{
  "schemaId": "azureMonitorCommonAlertSchema",
  "data": {
    "essentials": {
      "alertId": "/subscriptions/.../alerts/...",
      "alertRule": "alert-lkv-cpu-high",
      "severity": "Sev2",
      "signalType": "Metric",
      "monitorCondition": "Fired",
      "firedDateTime": "2026-03-20T10:30:00Z",
      "alertTargetIDs": [
        "/subscriptions/xxx/resourceGroups/1-eb641c7a-playground-sandbox/providers/Microsoft.Compute/virtualMachines/vm-lkv-win"
      ]
    }
  }
}
```

The runbook parses `alertTargetIDs[0]`, splits on `/`, and extracts `resourceGroups[3]`
and the last segment as the VM name — no hardcoded values in the runbook.

---

## KQL Queries — Log Analytics

After deploying and collecting metrics, run these queries in your workspace:

```kusto
-- Average CPU over last hour
AzureMetrics
| where ResourceProvider == "MICROSOFT.COMPUTE"
| where MetricName == "Percentage CPU"
| summarize avg(Average) by bin(TimeGenerated, 5m), Resource
| render timechart

-- CPU spikes above threshold
AzureMetrics
| where MetricName == "Percentage CPU"
| where Maximum > 75
| project TimeGenerated, Resource, Maximum
| order by TimeGenerated desc

-- Runbook job history
AzureDiagnostics
| where ResourceType == "AUTOMATIONACCOUNTS"
| where Category == "JobLogs"
| project TimeGenerated, RunbookName_s, ResultDescription_s, ResultType
| order by TimeGenerated desc
```

---

## Idempotency Design

Every resource uses the check-before-create pattern. Running `deploy.ps1` twice:

```powershell
$workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $rg -Name $workspaceName -ErrorAction SilentlyContinue
if (-not $workspace) {
    # Create workspace
    Write-Status "Workspace" $workspaceName "Created"
} else {
    Write-Status "Workspace" $workspaceName "Skipped (exists)"
}
```

**Second run output (all resources existing):**
```
  [Workspace]    law-lkv-monitor                Skipped (exists)
  [AutomationAcct] aa-lkv-monitor               Skipped (exists)
  [ManagedIdentity] aa-lkv-monitor              Skipped (already enabled)
  [Runbook]      Restart-AzureVM                Skipped (exists)
  [Webhook]      wh-lkv-restart-vm              Skipped (exists)
  [ActionGroup]  ag-lkv-cpu-alert               Configured (email + webhook)
  [VM]           vm-lkv-win                     Found
  [AlertRule]    alert-lkv-cpu-high             Skipped (exists)
  [DiagnosticSetting] diag-lkv-vm-to-law        Skipped (exists)
```

> `Set-AzActionGroup` is an upsert — safe to call every time.

---

## Config-Driven Design

One `$prefix` change creates a completely separate monitoring environment:

```powershell
# scripts/config.ps1
$prefix = "lkv"   # Change this ONE value

$workspaceName         = "law-$prefix-monitor"    # → law-lkv-monitor
$automationAccountName = "aa-$prefix-monitor"     # → aa-lkv-monitor
$actionGroupName       = "ag-$prefix-cpu-alert"   # → ag-lkv-cpu-alert
$alertRuleName         = "alert-$prefix-cpu-high" # → alert-lkv-cpu-high
$targetVmName          = "vm-$prefix-win"         # → vm-lkv-win
```

| Prefix | Environment |
|---|---|
| `lkv` | law-lkv-monitor, aa-lkv-monitor, alert-lkv-cpu-high |
| `prod` | law-prod-monitor, aa-prod-monitor, alert-prod-cpu-high |
| `dev` | law-dev-monitor, aa-dev-monitor, alert-dev-cpu-high |

---

## Tech Stack

- **Automation:** PowerShell Az module (Az.Monitor, Az.Automation, Az.OperationalInsights)
- **Azure Services:** Log Analytics Workspace, Automation Account, PowerShell Runbook,
  Automation Webhook, Action Group, Metric Alert Rule (V2), Diagnostic Settings
- **Authentication:** System-Assigned Managed Identity (no passwords anywhere)
- **Alert schema:** Azure Monitor Common Alert Schema
- **Query language:** KQL (Kusto Query Language) for Log Analytics

---

## Repository Structure

```
azure-monitoring-automation/
│
├── .gitignore                      ← Excludes webhook-url.txt and secrets
├── README.md
│
├── scripts/
│   ├── config.ps1                  ← Single source of truth (prefix + all names)
│   ├── prereqs.ps1                 ← Pre-flight: 4 checks must all pass
│   ├── deploy.ps1                  ← 8-step idempotent deployment
│   └── cleanup.ps1                 ← Reverse-order teardown
│
├── runbooks/
│   └── Restart-AzureVM.ps1        ← Runs inside Azure Automation, not locally
│
└── docs/
    ├── architecture.png
    ├── deploy-output.txt
    ├── webhook-url.txt             ← GITIGNORED — created at deploy time
    └── screenshots/
        ├── 01-resource-group-overview.png
        ├── 02-log-analytics-workspace.png
        ├── 03-automation-account-overview.png
        ├── 04-automation-managed-identity.png
        ├── 05-runbook-published.png
        ├── 06-webhook-created.png
        ├── 07-action-group-overview.png
        ├── 08-action-group-receivers.png
        ├── 09-alert-rule-overview.png
        ├── 10-alert-rule-condition.png
        ├── 11-alert-rule-action-group.png
        ├── 12-diagnostic-setting.png
        ├── 13-alert-fired-email.png
        ├── 14-runbook-job-succeeded.png
        ├── 15-runbook-job-output.png
        ├── 16-kql-cpu-query.png
        └── 17-cleanup-complete.png
```

---

## Prerequisites

- Azure account or Pluralsight sandbox
- PowerShell 7+ (or Azure Cloud Shell)
- Az PowerShell module with Az.Monitor, Az.Automation, Az.OperationalInsights
- Connected via `Connect-AzAccount` or Cloud Shell session
- **Project 2 VM deployed** (`vm-lkv-win`) — this project monitors that VM
- VM must have **Virtual Machine Contributor** role assigned to `aa-lkv-monitor` Managed Identity
  (done manually via portal IAM blade in Pluralsight sandbox)

---

## How to Deploy

```powershell
# 1. Clone the repository
git clone https://github.com/yourusername/azure-monitoring-automation.git
cd azure-monitoring-automation

# 2. Update config.ps1 with your sandbox values
notepad scripts\config.ps1
#   Set: $resourceGroupName, $location, $alertEmailAddress
#   Verify: $targetVmName matches your Project 2 VM (vm-lkv-win)

# 3. Run pre-flight checks — all must show [OK]
pwsh scripts\prereqs.ps1

# 4. Deploy and save output
pwsh scripts\deploy.ps1 2>&1 | Tee-Object -FilePath "docs\deploy-output.txt"

# 5. Assign Managed Identity role (Pluralsight sandbox — portal only):
#    Portal: vm-lkv-win → Access Control (IAM) → Add role assignment
#    Role: Virtual Machine Contributor
#    Assign to: Managed Identity → aa-lkv-monitor

# 6. Test alert (optional — triggers real CPU load on VM):
#    Portal: Automation Accounts → aa-lkv-monitor → Runbooks → Restart-AzureVM → Start
#    Leave WebhookData blank → runs in manual test mode
```

---

## How to Destroy

```powershell
pwsh scripts\cleanup.ps1
# Type: YES when prompted
# Deletes in order: Alert Rule → Action Group → Webhook → Runbook → Automation Account
#                   → Diagnostic Setting → Log Analytics Workspace
# Does NOT delete vm-lkv-win — that belongs to Project 2
```

---

## Script Reference

| Script | Purpose |
|---|---|
| `scripts/config.ps1` | All variables — change `$prefix` here for a new environment |
| `scripts/prereqs.ps1` | 4 checks: config values, Az modules, connection, RG access |
| `scripts/deploy.ps1` | 8-step idempotent deployment with detailed status output |
| `scripts/cleanup.ps1` | Dependency-ordered teardown — checks existence before each delete |
| `runbooks/Restart-AzureVM.ps1` | Runs inside Azure Automation (not locally) — parses alert payload, restarts VM |

---

## Deployment Steps

| Step | What Happens | Approx Time |
|---|---|---|
| 1 | Create Log Analytics Workspace (PerGB2018, 30-day retention) | ~30s |
| 2 | Create Automation Account + enable System-Assigned Managed Identity | ~45s |
| 3 | Import Restart-AzureVM.ps1 runbook + publish it | ~30s |
| 4 | Create runbook webhook (URL saved to docs\webhook-url.txt) | ~15s |
| 5 | Create Action Group with email + webhook receivers | ~20s |
| 6 | Resolve target VM resource ID | Instant |
| 7 | Create CPU metric alert rule (CPU > 75% / 5 min / Sev 2) | ~20s |
| 8 | Create diagnostic setting (VM → AllMetrics → Log Analytics) | ~20s |
| **+** | **Manual**: Assign VM Contributor role to Managed Identity | ~2 min |

---

## Prereqs Check Output

```
==========================================
 Pre-requisites Check — Project 3
 Prefix : lkv
==========================================

[CHECK 1] config.ps1 values...
  [OK]   Prefix                    : lkv
  [OK]   RG                        : 1-eb641c7a-playground-sandbox
  [OK]   Location                  : westus
  [OK]   Email                     : lvardhan@example.com
  [OK]   VM target                 : vm-lkv-win

[CHECK 2] Required Az modules...
  [OK]   Az.Accounts               : v2.15.0
  [OK]   Az.Monitor                : v5.2.0
  [OK]   Az.Automation             : v1.10.0
  [OK]   Az.OperationalInsights    : v3.2.0

[CHECK 3] Azure connection...
  [OK]   Connected as              : MSI@50342
  [OK]   Subscription              : P8-Real Hands-On Labs

[CHECK 4] Resource group access...
  [OK]   RG found                  : 1-eb641c7a-playground-sandbox
  [OK]   Location match            : westus

==========================================
 ALL CHECKS PASSED — Ready for deploy.ps1
==========================================
```

---

## Deployment Output

```
==========================================
 DEPLOYMENT COMPLETE
==========================================

  Prefix             : lkv
  Log Analytics WS   : law-lkv-monitor
  Automation Account : aa-lkv-monitor
  Runbook            : Restart-AzureVM
  Webhook            : wh-lkv-restart-vm  (URL in docs\webhook-url.txt)
  Action Group       : ag-lkv-cpu-alert
  Alert Rule         : alert-lkv-cpu-high  (CPU > 75%)
  Target VM          : vm-lkv-win
  Alert Email        : lvardhan@example.com
  Time elapsed       : 04:12

  VERIFY IN PORTAL:
  1. Monitor → Alerts → Alert rules
  2. Monitor → Action groups
  3. Automation Accounts → aa-lkv-monitor → Runbooks
  4. Log Analytics workspaces → law-lkv-monitor → Logs
```

---

## Verification Commands

```powershell
# All Project 3 resources exist
az resource list --resource-group "1-eb641c7a-playground-sandbox" \
  --query "[?contains(name,'lkv')].{Name:name,Type:type}" -o table

# Alert rule config
az monitor metrics alert show \
  --resource-group "1-eb641c7a-playground-sandbox" \
  --name "alert-lkv-cpu-high" \
  --query "{Name:name,Severity:severity,Enabled:enabled,Condition:criteria}" -o json

# Action Group receivers
az monitor action-group show \
  --resource-group "1-eb641c7a-playground-sandbox" \
  --name "ag-lkv-cpu-alert" \
  --query "{Name:name,Email:emailReceivers,Webhook:webhookReceivers}" -o json

# Automation Account identity
az automation account show \
  --resource-group "1-eb641c7a-playground-sandbox" \
  --name "aa-lkv-monitor" \
  --query "{Name:name,Identity:identity}" -o json

# Runbook status
az automation runbook show \
  --resource-group "1-eb641c7a-playground-sandbox" \
  --automation-account-name "aa-lkv-monitor" \
  --name "Restart-AzureVM" \
  --query "{Name:name,State:state,Type:runbookType}" -o table

# Log Analytics workspace
az monitor log-analytics workspace show \
  --resource-group "1-eb641c7a-playground-sandbox" \
  --workspace-name "law-lkv-monitor" \
  --query "{Name:name,Sku:sku,Retention:retentionInDays}" -o table

# Diagnostic settings on VM
az monitor diagnostic-settings show \
  --resource "/subscriptions/<sub>/resourceGroups/1-eb641c7a-playground-sandbox/providers/Microsoft.Compute/virtualMachines/vm-lkv-win" \
  --name "diag-lkv-vm-to-law" -o json
```

---

## Runbook Job Output

When the runbook is triggered (manually or via webhook):

```
========================================
 Runbook  : Restart-AzureVM
 Started  : 2026-03-20 11:45:02 UTC
 Alert    : alert-lkv-cpu-high  |  Severity: Sev2
 Target   : vm-lkv-win  in  1-eb641c7a-playground-sandbox
========================================

Authenticating with Managed Identity...
Authenticated as  : <GUID>@<TenantID>
Subscription      : P8-Real Hands-On Labs

Checking current VM state...
Current VM state  : VM running

VM is running — restarting to recover from high CPU condition...
Restart command accepted.
Waiting 60 seconds for VM to complete restart...
VM state after restart : VM running

========================================
 RUNBOOK COMPLETE
 Finished : 2026-03-20 11:46:15 UTC
========================================
```

---

## Screenshots

All verification screenshots in [`docs/screenshots/`](docs/screenshots/).

| # | Screenshot |
|---|---|
| 01 | Resource Group — all monitoring resources listed |
| 02 | Log Analytics Workspace — overview with workspace ID |
| 03 | Automation Account — overview page |
| 04 | Automation Account — Identity tab (System Assigned ON, Principal ID visible) |
| 05 | Runbook — Published status |
| 06 | Webhook — Created, Enabled, Expiry date |
| 07 | Action Group — overview |
| 08 | Action Group — Email receiver + Webhook receiver both listed |
| 09 | Alert Rule — overview (Sev 2, Enabled) |
| 10 | Alert Rule — Condition: CPU > 75%, 5 min average |
| 11 | Alert Rule — Action Group: ag-lkv-cpu-alert attached |
| 12 | Diagnostic Setting — AllMetrics streamed to law-lkv-monitor |
| 13 | Alert fired email — notification received in inbox |
| 14 | Runbook Job — Status: Completed |
| 15 | Runbook Job — Output stream showing restart steps |
| 16 | KQL query — CPU trend chart in Log Analytics |
| 17 | Terminal — Cleanup complete, all resources deleted |

---

## Cost Estimate

| Resource | Estimated Cost |
|---|---|
| Log Analytics Workspace | ~$2.30/GB ingested (first 5GB/month free) |
| Automation Account | Free up to 500 min/month job run time |
| Metric Alert Rule | ~$0.10/month per rule |
| Action Group | Free up to 1000 email notifications/month |
| Automation Webhook | Free |
| **Total for demo** | **~$0.10 (mostly free tier)** |

> Tested on Pluralsight Azure sandbox (free).
> For personal accounts: Log Analytics charges apply after 5GB free tier.
> Run `cleanup.ps1` immediately after screenshots to avoid any charges.

---

## Sandbox Adaptations (Pluralsight)

| Constraint | Root Cause | Adaptation |
|---|---|---|
| Cannot run `New-AzRoleAssignment` | Starkiller role cannot write AAD RBAC | Assign Managed Identity role via portal IAM blade manually |
| RG pre-created | Sandbox setup | Read existing RG — don't create it |
| Location locked | Starkiller scope | Set `$location` in config.ps1 to match sandbox RG |
| VM exists from Project 2 | Shared environment | `$targetVmName = "vm-$prefix-win"` targets existing VM |

---

## Key Learnings

- **Azure Monitor metric alerts** evaluate independently — no agent needed for CPU
- **Common Alert Schema** standardizes webhook payload across all alert types
- **Action Group** is the single delivery mechanism — alert rules don't send notifications directly
- **Webhook URL is a one-time secret** — must save it at creation time (`docs/webhook-url.txt` pattern)
- **`Set-AzActionGroup` is an upsert** — idempotent by design, unlike most `New-Az*` cmdlets
- **Runbooks authenticate via `-Identity`** — `Connect-AzAccount -Identity` inside the runbook uses IMDS
- **Diagnostic Settings** bridge the gap between real-time alerts (Azure Monitor) and historical analysis (Log Analytics)
- **Severity 2 = Warning** — Common AlertSchema includes severity so runbooks can make conditional decisions
- **`-AutoMitigate $true`** on alert rules auto-resolves when condition clears — prevents alert storm

---

## Author

**L Vardhan**
AZ-900 | AZ-104
[GitHub](https://github.com/yourusername) | [LinkedIn](https://linkedin.com/in/yourprofile)
