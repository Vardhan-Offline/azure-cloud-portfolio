<#
.SYNOPSIS
    Restart-AzureVM.ps1 — Azure Automation Runbook
    Triggered by Azure Monitor metric alert via Action Group webhook when CPU > threshold.

.DESCRIPTION
    - Parses the Common Alert Schema webhook payload from Azure Monitor
    - Authenticates to Azure using the Automation Account's System-Assigned Managed Identity
    - Checks the current power state of the target VM
    - Restarts a running VM, or starts a stopped/deallocated VM
    - Handles transitional states gracefully (no action taken)

.REQUIREMENTS
    - Automation Account must have System-Assigned Managed Identity enabled
    - Managed Identity must have 'Virtual Machine Contributor' role assigned on the target VM
    - Action Group must use Common Alert Schema (UseCommonAlertSchema = $true)

.TESTING
    To test manually in Azure Portal, without triggering a real alert:
    Automation Accounts → {AA} → Runbooks → Restart-AzureVM → Start
    Leave WebhookData blank → runs in manual test mode with hardcoded VM values below
#>

param (
    [Parameter(Mandatory = $false)]
    [object] $WebhookData
)

# =============================================================================
# SECTION 1: Parse Webhook Payload
# Azure Monitor sends the Common Alert Schema as JSON in WebhookData.RequestBody
# =============================================================================

if ($null -ne $WebhookData -and $null -ne $WebhookData.RequestBody) {
    Write-Output "Webhook payload received. Parsing Common Alert Schema..."

    try {
        $body        = $WebhookData.RequestBody | ConvertFrom-Json
        $essentials  = $body.data.essentials

        $alertName   = $essentials.alertRule
        $severity    = $essentials.severity
        $firedTime   = $essentials.firedDateTime
        $resourceIds = $essentials.alertTargetIDs

        if (-not $resourceIds -or $resourceIds.Count -eq 0) {
            throw "alertTargetIDs is empty in webhook payload."
        }

        # Resource ID format:
        # /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Compute/virtualMachines/{vmName}
        $resourceId = $resourceIds[0]
        $parts      = $resourceId.TrimStart("/") -split "/"

        $rgName  = $parts[3]      # index 3 = resourceGroups value
        $vmName  = $parts[-1]     # last segment = VM name

        Write-Output "Alert name  : $alertName"
        Write-Output "Severity    : $severity"
        Write-Output "Fired at    : $firedTime"
        Write-Output "Target VM   : $vmName"
        Write-Output "Target RG   : $rgName"

    } catch {
        Write-Error "Failed to parse webhook payload: $_"
        Write-Output "Raw RequestBody:"
        Write-Output $WebhookData.RequestBody
        throw
    }

} else {
    # ── Manual test mode (no webhook data — started from Azure Portal) ─────────
    Write-Output "INFO: No WebhookData provided — running in manual test mode."
    Write-Output "      Update the values below to match your environment."

    $rgName    = "CHANGE_ME_RG"        # e.g. 1-38d80ce7-playground-sandbox
    $vmName    = "CHANGE_ME_VM"        # e.g. vm-lkv-test (deployed by Project 3)
    $alertName = "ManualTest"
    $severity  = "2"
}

Write-Output ""
Write-Output "========================================"
Write-Output " Runbook  : Restart-AzureVM"
Write-Output " Started  : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') UTC"
Write-Output " Alert    : $alertName  |  Severity: $severity"
Write-Output " Target   : $vmName  in  $rgName"
Write-Output "========================================"
Write-Output ""

# =============================================================================
# SECTION 2: Authenticate via Managed Identity
# The Automation Account's System-Assigned identity must have
# "Virtual Machine Contributor" on the target VM (assigned in IAM blade).
# =============================================================================

Write-Output "Authenticating with Managed Identity..."
try {
    Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
    $ctx = Get-AzContext
    Write-Output "Authenticated as  : $($ctx.Account.Id)"
    Write-Output "Subscription      : $($ctx.Subscription.Name)"
} catch {
    Write-Error "Managed Identity authentication failed: $_"
    Write-Output ""
    Write-Output "Troubleshooting:"
    Write-Output "  1. Automation Account → Identity → System Assigned → Status = On"
    Write-Output "  2. VM → Access Control (IAM) → Role assignments → Managed Identity has 'Virtual Machine Contributor'"
    throw
}
Write-Output ""

# =============================================================================
# SECTION 3: Get VM Power State
# =============================================================================

Write-Output "Checking current VM state..."
try {
    $vmStatus   = Get-AzVM -ResourceGroupName $rgName -Name $vmName -Status -ErrorAction Stop
    $powerState = ($vmStatus.Statuses | Where-Object { $_.Code -like "PowerState/*" }).DisplayStatus
    Write-Output "Current VM state  : $powerState"
} catch {
    Write-Error "Could not retrieve VM status for '$vmName' in '$rgName': $_"
    throw
}
Write-Output ""

# =============================================================================
# SECTION 4: Take Remediation Action
# =============================================================================

switch ($powerState) {

    "VM running" {
        Write-Output "VM is running — restarting to recover from high CPU condition..."
        try {
            Restart-AzVM -ResourceGroupName $rgName -Name $vmName -ErrorAction Stop | Out-Null
            Write-Output "Restart command accepted."
        } catch {
            Write-Error "Restart failed: $_"
            throw
        }

        # Wait and confirm new state
        Write-Output "Waiting 60 seconds for VM to complete restart..."
        Start-Sleep -Seconds 60

        $vmAfter    = Get-AzVM -ResourceGroupName $rgName -Name $vmName -Status
        $stateAfter = ($vmAfter.Statuses | Where-Object { $_.Code -like "PowerState/*" }).DisplayStatus
        Write-Output "VM state after restart : $stateAfter"
    }

    "VM deallocated" {
        Write-Output "VM is deallocated — starting VM..."
        Start-AzVM -ResourceGroupName $rgName -Name $vmName -ErrorAction Stop | Out-Null
        Write-Output "Start command sent."
    }

    "VM stopped" {
        Write-Output "VM is stopped (OS shutdown, still allocated) — starting VM..."
        Start-AzVM -ResourceGroupName $rgName -Name $vmName -ErrorAction Stop | Out-Null
        Write-Output "Start command sent."
    }

    default {
        Write-Output "VM is in state '$powerState' — no action taken."
        Write-Output "The VM may be starting up or shutting down. Azure will re-evaluate the alert condition."
    }
}

Write-Output ""
Write-Output "========================================"
Write-Output " RUNBOOK COMPLETE"
Write-Output " Finished : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') UTC"
Write-Output "========================================"
