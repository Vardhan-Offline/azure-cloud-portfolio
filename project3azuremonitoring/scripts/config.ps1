# =============================================================================
# config.ps1 — Project 3: Azure Monitoring & Automation
# Single source of truth. Change $prefix to create a parallel environment.
# =============================================================================

$prefix               = "lkv"

# ── Sandbox values — update every new Pluralsight session ────────────────────
$resourceGroupName    = "1-38d80ce7-playground-sandbox"             # az group list -o table
$location             = "westus"             # must match RG location (e.g. westus)

# ── Alert email — REQUIRED: update before running prereqs.ps1 ────────────────
$alertEmailAddress    = "lkvardhan12@gmail.com"

# ── Test VM (auto-deployed by this project for monitoring demo) ──────────────
$targetVmName         = "vm-$prefix-test"
$vmAdminUsername      = "azureuser"
$vmSize               = "Standard_B2s"      # 2 vCPU, 4GB RAM, burstable
$vmImage              = "Ubuntu2204"        # Ubuntu 22.04 LTS
$sshKeyPath           = Join-Path (Split-Path $PSScriptRoot -Parent) "docs" "ssh-key-$targetVmName"

# ── Resource names (all auto-derived from $prefix — change prefix only) ──────
$workspaceName        = "law-$prefix-monitor"
$automationAccountName= "aa-$prefix-monitor"
$runbookName          = "Restart-AzureVM"
$webhookName          = "wh-$prefix-restart-vm"
$actionGroupShortName = "ag$($prefix)cpu"       # MAX 12 chars — no hyphens
$actionGroupName      = "ag-$prefix-cpu-alert"
$alertRuleName        = "alert-$prefix-cpu-high"
$diagnosticSettingName= "diag-$prefix-vm-to-law"

# ── Alert thresholds ─────────────────────────────────────────────────────────
$cpuThreshold         = 10     # Trigger when average CPU > 75%
$alertWindowMinutes   = 5      # Measured over last 5 minutes
$alertFrequencyMinutes= 1      # Evaluated every 1 minute

# ── SKU / tier ───────────────────────────────────────────────────────────────
$workspaceSku         = "PerGB2018"
$automationSku        = "Basic"
