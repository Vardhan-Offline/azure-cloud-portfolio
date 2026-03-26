# config.ps1
# ─────────────────────────────────────────────────────────────────────
# SINGLE SOURCE OF TRUTH — all variables live here.
# Other scripts dot-source this file: . "$PSScriptRoot/config.ps1"
#
# TO REUSE IN A DIFFERENT ACCOUNT OR CREATE A PARALLEL ENVIRONMENT:
#   Change $prefix below. Every resource name updates automatically.
#   Example: "lkv" → vnet-lkv-hardened, vm-lkv-win, nsg-lkv-hardened
# ─────────────────────────────────────────────────────────────────────

# ── ONE CHANGE = ALL NAMES CHANGE ────────────────────────────────────
$prefix = "lkv"           # ← Your initials. Change this for new environment.

# ── SANDBOX SETTINGS — update when sandbox session resets ────────────
$resourceGroupName = "1-eb641c7a-playground-sandbox"   # ← Paste from: az group list -o table
$location          = "westus"  # ← e.g. westus or eastus

# ── DERIVED NAMES — do not edit these ────────────────────────────────
$vnetName     = "vnet-$prefix-hardened"
$subnetName   = "snet-$prefix-vm"
$nsgName      = "nsg-$prefix-hardened"
$publicIpName = "pip-$prefix-hardened"
$nicName      = "nic-$prefix-hardened"
$vmName       = "vm-$prefix-win"

# ── VM SETTINGS ───────────────────────────────────────────────────────
$vnetPrefix   = "10.10.0.0/16"
$subnetPrefix = "10.10.1.0/24"
$vmSize       = "Standard_D2s_v5"   # Trusted Launch compatible
$adminUsername = "azureadmin"

# ── TAGS — applied to every resource for cost tracking ───────────────
$tags = @{
    Project     = "vm-auto-hardening"
    Environment = "sandbox"
    ManagedBy   = "PowerShell"
    Prefix      = $prefix
}