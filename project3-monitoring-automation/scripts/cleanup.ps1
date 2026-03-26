# =============================================================================
# cleanup.ps1 — Project 3: Azure Monitoring & Automation
# Deletes all Project 3 resources in reverse dependency order.
# Includes the test VM (vm-lkv-test) deployed by this project.
# =============================================================================

. "$PSScriptRoot\config.ps1"

Write-Host ""
Write-Host "==========================================" -ForegroundColor Red
Write-Host " CLEANUP — Project 3: Azure Monitoring"
Write-Host " RG : $resourceGroupName"
Write-Host "==========================================" -ForegroundColor Red
Write-Host ""
Write-Host "Resources to delete (in order):" -ForegroundColor Yellow
Write-Host "  1. Metric Alert Rule  : $alertRuleName"
Write-Host "  2. Action Group       : $actionGroupName"
Write-Host "  3. Webhook            : $webhookName"
Write-Host "  4. Runbook            : $runbookName"
Write-Host "  5. Automation Account : $automationAccountName"
Write-Host "  6. Diagnostic Setting : $diagnosticSettingName"
Write-Host "  7. Test VM + NIC + Disk + Public IP : $targetVmName"
Write-Host "  8. Log Analytics WS   : $workspaceName"
Write-Host ""

$confirm = Read-Host "Type YES to confirm deletion"
if ($confirm -ne "YES") {
    Write-Host "Cleanup cancelled." -ForegroundColor Yellow
    exit 0
}
Write-Host ""

function Remove-IfExists {
    param([string]$Label, [string]$Name, [scriptblock]$Action)
    try {
        & $Action
        Write-Host ("  [Deleted]  {0,-22} : {1}" -f $Label, $Name) -ForegroundColor Green
    } catch {
        $msg = ($_.Exception.Message -replace "`n", " ").Substring(0, [Math]::Min(60, $_.Exception.Message.Length))
        Write-Host ("  [Skipped]  {0,-22} : {1} ({2})" -f $Label, $Name, $msg) -ForegroundColor Yellow
    }
}

# 1. Alert Rule — no downstream dependencies
Remove-IfExists "Alert Rule" $alertRuleName {
    az monitor metrics alert delete `
        --resource-group $resourceGroupName `
        --name           $alertRuleName `
        --yes `
        --output         none
}

# 2. Action Group
Remove-IfExists "Action Group" $actionGroupName {
    az monitor action-group delete `
        --resource-group $resourceGroupName `
        --name           $actionGroupName `
        --yes `
        --output         none
}

# 3. Webhook — must delete before Automation Account
Remove-IfExists "Webhook" $webhookName {
    Remove-AzAutomationWebhook `
        -ResourceGroupName     $resourceGroupName `
        -AutomationAccountName $automationAccountName `
        -Name                  $webhookName `
        -ErrorAction           Stop
}

# 4. Runbook — must delete before Automation Account
Remove-IfExists "Runbook" $runbookName {
    Remove-AzAutomationRunbook `
        -ResourceGroupName     $resourceGroupName `
        -AutomationAccountName $automationAccountName `
        -Name                  $runbookName `
        -Force `
        -ErrorAction           Stop
}

# 5. Automation Account
Remove-IfExists "Automation Account" $automationAccountName {
    Remove-AzAutomationAccount `
        -ResourceGroupName $resourceGroupName `
        -Name              $automationAccountName `
        -Force `
        -ErrorAction       Stop
}

# 6. Diagnostic Setting — must delete before VM
$vm = Get-AzVM -ResourceGroupName $resourceGroupName -Name $targetVmName -ErrorAction SilentlyContinue
if ($vm) {
    Remove-IfExists "Diagnostic Setting" $diagnosticSettingName {
        az monitor diagnostic-settings delete `
            --resource $vm.Id `
            --name     $diagnosticSettingName `
            --yes `
            --output   none
    }
} else {
    Write-Host ("  [Skipped]  {0,-22} : {1} (VM not found)" -f "Diagnostic Setting", $diagnosticSettingName) -ForegroundColor Yellow
}

# 7. Test VM (created by deploy.ps1)
if ($vm) {
    Remove-IfExists "VM" $targetVmName {
        Remove-AzVM `
            -ResourceGroupName $resourceGroupName `
            -Name              $targetVmName `
            -Force `
            -ErrorAction       Stop
    }
    
    # Delete associated NIC (VM deletion doesn't auto-delete it)
    $nicName = "$targetVmName-nic"
    $nic = Get-AzNetworkInterface -ResourceGroupName $resourceGroupName -Name $nicName -ErrorAction SilentlyContinue
    if ($nic) {
        Remove-IfExists "NIC" $nicName {
            Remove-AzNetworkInterface `
                -ResourceGroupName $resourceGroupName `
                -Name              $nicName `
                -Force `
                -ErrorAction       Stop
        }
    }
    
    # Delete OS disk (auto-named by Azure)
    $osDiskName = "$($targetVmName)_OsDisk_*"
    $disk = Get-AzDisk -ResourceGroupName $resourceGroupName -ErrorAction SilentlyContinue | Where-Object { $_.Name -like $osDiskName }
    if ($disk) {
        Remove-IfExists "OS Disk" $disk.Name {
            Remove-AzDisk `
                -ResourceGroupName $resourceGroupName `
                -DiskName          $disk.Name `
                -Force `
                -ErrorAction       Stop
        }
    }
    
    # Delete public IP (auto-named by Azure CLI)
    $pipName = "$($targetVmName)PublicIP"
    $pip = Get-AzPublicIpAddress -ResourceGroupName $resourceGroupName -Name $pipName -ErrorAction SilentlyContinue
    if ($pip) {
        Remove-IfExists "Public IP" $pipName {
            Remove-AzPublicIpAddress `
                -ResourceGroupName $resourceGroupName `
                -Name              $pipName `
                -Force `
                -ErrorAction       Stop
        }
    }
} else {
    Write-Host ("  [Skipped]  {0,-22} : {1} (VM not found)" -f "VM", $targetVmName) -ForegroundColor Yellow
}

# 8. Log Analytics Workspace
Remove-IfExists "Log Analytics WS" $workspaceName {
    Remove-AzOperationalInsightsWorkspace `
        -ResourceGroupName $resourceGroupName `
        -Name              $workspaceName `
        -ForceDelete `
        -Force `
        -ErrorAction       Stop
}

# 8. Webhook URL file (local artifact)
$webhookFile = Join-Path $PSScriptRoot ".." "docs" "webhook-url.txt"
if (Test-Path $webhookFile) {
    Remove-Item $webhookFile -Force
    Write-Host "  [Deleted]  webhook-url.txt (local)" -ForegroundColor Green
}

Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host " CLEANUP COMPLETE" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
Write-Host ""
