# =============================================================================
# deploy.ps1 — Project 3: Azure Monitoring & Automation
# Idempotent 9-step deployment. Safe to run multiple times — check-before-create
# on every resource. No side effects on repeated runs.
#
# STEPS:
#   1. Log Analytics Workspace
#   2. Test VM (Ubuntu 22.04, Standard_B2s) — creates VM to monitor
#   3. Automation Account + System-Assigned Managed Identity
#   4. Import & Publish Runbook
#   5. Create Runbook Webhook (URL saved to docs\webhook-url.txt — shown once)
#   6. Action Group (email + webhook receiver)
#   7. Verify Target VM Resource ID
#   8. CPU Metric Alert Rule (CPU > threshold%)
#   9. Diagnostic Settings (VM metrics → Log Analytics)
# =============================================================================

. "$PSScriptRoot\config.ps1"

$startTime = Get-Date
$subId     = (Get-AzContext -ErrorAction Stop).Subscription.Id
$docsPath  = Join-Path $PSScriptRoot ".." "docs"
if (-not (Test-Path $docsPath)) { New-Item -ItemType Directory -Path $docsPath -Force | Out-Null }

function Write-Status {
    param([string]$Type, [string]$Name, [string]$Status)
    $col = switch -Wildcard ($Status) {
        "Created*" { "Green" }
        "Skipped*" { "Yellow" }
        "Enabled*" { "Green" }
        default    { "Cyan" }
    }
    Write-Host ("  [{0}]" -f $Type).PadRight(26) -ForegroundColor $col -NoNewline
    Write-Host $Name.PadRight(38) -NoNewline
    Write-Host $Status -ForegroundColor $col
}

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " PROJECT 3 — Azure Monitoring & Automation"
Write-Host " Prefix    : $prefix"
Write-Host " RG        : $resourceGroupName"
Write-Host " Location  : $location"
Write-Host " Target VM : $targetVmName"
Write-Host " Alert     : CPU > $cpuThreshold% averaged over $alertWindowMinutes min"
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

$ctx = Get-AzContext -ErrorAction Stop
Write-Host "  Subscription : $($ctx.Subscription.Name)" -ForegroundColor DarkGray
Write-Host ""

# =============================================================================
# STEP 1: Log Analytics Workspace
# =============================================================================
Write-Host "STEP 1: Log Analytics Workspace" -ForegroundColor Magenta

$workspace = Get-AzOperationalInsightsWorkspace `
    -ResourceGroupName $resourceGroupName `
    -Name              $workspaceName `
    -ErrorAction       SilentlyContinue

if (-not $workspace) {
    $workspace = New-AzOperationalInsightsWorkspace `
        -ResourceGroupName $resourceGroupName `
        -Name              $workspaceName `
        -Location          $location `
        -Sku               $workspaceSku `
        -RetentionInDays   30
    Write-Status "Workspace" $workspaceName "Created"
} else {
    Write-Status "Workspace" $workspaceName "Skipped (exists)"
}
$workspaceResourceId = $workspace.ResourceId
Write-Host ""

# =============================================================================
# STEP 2: Deploy Test VM (Ubuntu 22.04)
# Creates a lightweight VM for monitoring demonstration
# =============================================================================
Write-Host "STEP 2: Test VM (Ubuntu 22.04)" -ForegroundColor Magenta

$vm = Get-AzVM -ResourceGroupName $resourceGroupName -Name $targetVmName -ErrorAction SilentlyContinue

if (-not $vm) {
    # Generate SSH key pair (saves to docs/ folder, gitignored)
    if (-not (Test-Path $sshKeyPath)) {
        $keyDir = Split-Path $sshKeyPath -Parent
        if (-not (Test-Path $keyDir)) { New-Item -ItemType Directory -Path $keyDir -Force | Out-Null }
        
        ssh-keygen -t rsa -b 2048 -f $sshKeyPath -N '""' -C "azureuser@$targetVmName" -q
        Write-Host "  SSH key generated: $sshKeyPath" -ForegroundColor DarkGray
    }
    $sshPublicKey = Get-Content "$sshKeyPath.pub" -Raw
    
    # Create VM using Azure CLI (simpler than Az PowerShell for Linux VMs)
    Write-Host "  Creating VM (takes ~4-5 minutes)..." -ForegroundColor DarkGray
    az vm create `
        --resource-group $resourceGroupName `
        --name           $targetVmName `
        --location       $location `
        --image          $vmImage `
        --size           $vmSize `
        --admin-username $vmAdminUsername `
        --ssh-key-values $sshPublicKey `
        --public-ip-sku  Standard `
        --nsg-rule       NONE `
        --output         none
    
    Write-Status "VM" $targetVmName "Created (Ubuntu 22.04, $vmSize)"
} else {
    Write-Status "VM" $targetVmName "Skipped (exists)"
}

# Retrieve VM for further steps
$vm = Get-AzVM -ResourceGroupName $resourceGroupName -Name $targetVmName
$vmResourceId = $vm.Id
Write-Host ""

# =============================================================================
# STEP 3: Automation Account + Managed Identity
# =============================================================================
Write-Host "STEP 3: Automation Account" -ForegroundColor Magenta

$aa = Get-AzAutomationAccount `
    -ResourceGroupName $resourceGroupName `
    -Name              $automationAccountName `
    -ErrorAction       SilentlyContinue

if (-not $aa) {
    New-AzAutomationAccount `
        -ResourceGroupName $resourceGroupName `
        -Name              $automationAccountName `
        -Location          $location `
        -Plan              $automationSku | Out-Null
    Write-Status "AutomationAcct" $automationAccountName "Created"
} else {
    Write-Status "AutomationAcct" $automationAccountName "Skipped (exists)"
}

# Enable System-Assigned Managed Identity (idempotent — only if not yet enabled)
$aa = Get-AzAutomationAccount -ResourceGroupName $resourceGroupName -Name $automationAccountName
if ($aa.Identity.Type -notmatch "SystemAssigned") {
    $aa = Set-AzAutomationAccount `
        -ResourceGroupName  $resourceGroupName `
        -Name               $automationAccountName `
        -AssignSystemIdentity
    Write-Status "ManagedIdentity" $automationAccountName "Enabled"
} else {
    Write-Status "ManagedIdentity" $automationAccountName "Skipped (already enabled)"
}

$aaPrincipalId = $aa.Identity.PrincipalId
Write-Host "  Principal ID : $aaPrincipalId" -ForegroundColor DarkGray
Write-Host ""

# =============================================================================
# STEP 4: Import and Publish Runbook
# =============================================================================
Write-Host "STEP 4: Runbook — $runbookName" -ForegroundColor Magenta

$runbook = Get-AzAutomationRunbook `
    -ResourceGroupName     $resourceGroupName `
    -AutomationAccountName $automationAccountName `
    -Name                  $runbookName `
    -ErrorAction           SilentlyContinue

if (-not $runbook) {
    $runbookPath = Join-Path $PSScriptRoot ".." "runbooks" "Restart-AzureVM.ps1"
    if (-not (Test-Path $runbookPath)) {
        Write-Host "  [ERROR] Runbook file not found: $runbookPath" -ForegroundColor Red
        Write-Host "  Ensure runbooks\Restart-AzureVM.ps1 exists in the repo root." -ForegroundColor Red
        exit 1
    }
    Import-AzAutomationRunbook `
        -ResourceGroupName     $resourceGroupName `
        -AutomationAccountName $automationAccountName `
        -Name                  $runbookName `
        -Type                  "PowerShell" `
        -Path                  $runbookPath `
        -Published | Out-Null
    Write-Status "Runbook" $runbookName "Created + Published"
} else {
    Write-Status "Runbook" $runbookName "Skipped (exists)"
}
Write-Host ""

# =============================================================================
# STEP 5: Webhook for Runbook
# NOTE: The webhook URL is a secret token — Azure shows it ONLY at creation.
#       It is saved to docs\webhook-url.txt (which is .gitignored).
#       If you lose it: delete the webhook, re-run deploy.ps1 (a new one is created).
# =============================================================================
Write-Host "STEP 5: Runbook Webhook" -ForegroundColor Magenta

$webhookUrlFile  = Join-Path $docsPath "webhook-url.txt"
$existingWebhook = Get-AzAutomationWebhook `
    -ResourceGroupName     $resourceGroupName `
    -AutomationAccountName $automationAccountName `
    -RunbookName           $runbookName `
    -ErrorAction           SilentlyContinue `
    | Where-Object { $_.Name -eq $webhookName }

# If webhook exists but URL file is missing, delete and recreate (URL can't be retrieved)
if ($existingWebhook -and -not (Test-Path $webhookUrlFile)) {
    Write-Host "  [WARN] Webhook exists but URL file missing — deleting and recreating..." -ForegroundColor Yellow
    Remove-AzAutomationWebhook `
        -ResourceGroupName     $resourceGroupName `
        -AutomationAccountName $automationAccountName `
        -Name                  $webhookName `
        -Force `
        -ErrorAction           SilentlyContinue
    $existingWebhook = $null
}

if (-not $existingWebhook) {
    $expiry     = (Get-Date).AddYears(1)
    $newWebhook = New-AzAutomationWebhook `
        -ResourceGroupName     $resourceGroupName `
        -AutomationAccountName $automationAccountName `
        -RunbookName           $runbookName `
        -Name                  $webhookName `
        -IsEnabled             $true `
        -ExpiryTime            $expiry `
        -Force
    $webhookUrl = $newWebhook.WebhookURI
    $webhookUrl | Set-Content -Path $webhookUrlFile -Encoding UTF8
    Write-Status "Webhook" $webhookName "Created"
    Write-Host "  URL saved to : docs\webhook-url.txt  (gitignored — never committed)" -ForegroundColor Yellow
} else {
    $webhookUrl = (Get-Content $webhookUrlFile -Raw).Trim()
    Write-Status "Webhook" $webhookName "Skipped (exists)"
    Write-Host "  URL loaded from : docs\webhook-url.txt" -ForegroundColor DarkGray
}
Write-Host ""

# =============================================================================
# STEP 6: Action Group (email + webhook)
# Using Azure CLI for Cloud Shell compatibility (Az.Monitor version issues)
# =============================================================================
Write-Host "STEP 6: Action Group" -ForegroundColor Magenta

# Check if Action Group already exists
$agExists = az monitor action-group show `
    --resource-group $resourceGroupName `
    --name           $actionGroupName `
    2>$null

if (-not $agExists) {
    # Create Action Group with email and webhook receivers using Azure CLI
    Write-Host "  Creating Action Group with email ($alertEmailAddress) and webhook..." -ForegroundColor DarkGray
    
    $createResult = az monitor action-group create `
        --resource-group $resourceGroupName `
        --name           $actionGroupName `
        --short-name     $actionGroupShortName `
        --action email EmailAlert $alertEmailAddress `
        --action webhook RunbookWebhook $webhookUrl `
        2>&1

    # Verify Action Group was created
    $agVerify = az monitor action-group show `
        --resource-group $resourceGroupName `
        --name           $actionGroupName `
        2>$null

    if ($agVerify) {
        Write-Status "ActionGroup" $actionGroupName "Created (email + webhook)"
    } else {
        Write-Host "  [ERROR] Action Group creation failed!" -ForegroundColor Red
        Write-Host "  $createResult" -ForegroundColor Red
        throw "Action Group creation failed - cannot continue"
    }
} else {
    Write-Status "ActionGroup" $actionGroupName "Skipped (exists)"
}
Write-Host ""

# =============================================================================
# STEP 7: Resolve Target VM Resource ID (Created in Step 2)
# =============================================================================
Write-Host "STEP 7: Verify target VM resource ID" -ForegroundColor Magenta

# VM was created in Step 2, retrieve fresh state
$vm = Get-AzVM -ResourceGroupName $resourceGroupName -Name $targetVmName -ErrorAction Stop
$vmResourceId = $vm.Id
Write-Status "VM" $targetVmName "Verified (created in Step 2)"
Write-Host "  Resource ID : $vmResourceId" -ForegroundColor DarkGray
Write-Host ""

# =============================================================================
# STEP 8: CPU Metric Alert Rule  (CPU > threshold% averaged over window)
# Using Azure CLI for Cloud Shell compatibility
# =============================================================================
Write-Host "STEP 8: CPU Metric Alert Rule" -ForegroundColor Magenta

# Check if alert rule exists
$alertExists = az monitor metrics alert show `
    --resource-group $resourceGroupName `
    --name           $alertRuleName `
    2>$null

if (-not $alertExists) {
    # Get Action Group resource ID - must exist from Step 6
    $agResourceId = az monitor action-group show `
        --resource-group $resourceGroupName `
        --name           $actionGroupName `
        --query          id -o tsv `
        2>$null

    if (-not $agResourceId) {
        Write-Host "  [ERROR] Action Group '$actionGroupName' not found!" -ForegroundColor Red
        Write-Host "          Step 6 (Action Group) must succeed before creating Alert Rule." -ForegroundColor Red
        throw "Action Group missing - cannot create Alert Rule"
    }

    # Create metric alert rule
    # Condition: Percentage CPU > threshold%, averaged over window, evaluated every frequency
    az monitor metrics alert create `
        --resource-group $resourceGroupName `
        --name           $alertRuleName `
        --description    "P3: CPU > $cpuThreshold% averaged over $alertWindowMinutes min on $targetVmName" `
        --scopes         $vmResourceId `
        --condition      "avg Percentage CPU > $cpuThreshold" `
        --window-size    "$($alertWindowMinutes)m" `
        --evaluation-frequency "$($alertFrequencyMinutes)m" `
        --severity       2 `
        --action         $agResourceId `
        --auto-mitigate  true `
        --output         none

    Write-Status "AlertRule" $alertRuleName "Created  (Sev 2 — CPU > $cpuThreshold% / $alertWindowMinutes min)"
} else {
    Write-Status "AlertRule" $alertRuleName "Skipped (exists)"
}
Write-Host ""

# =============================================================================
# STEP 9: Diagnostic Settings — VM metrics streamed to Log Analytics
# VM was created in Step 2, so this always succeeds
# Using Azure CLI for Cloud Shell compatibility
# =============================================================================
Write-Host "STEP 9: Diagnostic Settings (VM → Log Analytics)" -ForegroundColor Magenta

# Check if diagnostic setting exists
$diagExists = az monitor diagnostic-settings show `
    --resource $vmResourceId `
    --name     $diagnosticSettingName `
    2>$null

if (-not $diagExists) {
    # Create diagnostic setting - send all VM metrics to Log Analytics
    az monitor diagnostic-settings create `
        --resource         $vmResourceId `
        --name             $diagnosticSettingName `
        --workspace        $workspaceResourceId `
        --metrics          '[{"category": "AllMetrics", "enabled": true}]' `
        --output           none
    
    Write-Status "DiagnosticSetting" $diagnosticSettingName "Created"
} else {
    Write-Status "DiagnosticSetting" $diagnosticSettingName "Skipped (exists)"
}
Write-Host ""

# =============================================================================
# SANDBOX NOTE: Role assignment for runbook Managed Identity
# Pluralsight Starkiller role cannot write AAD RBAC assignments.
# In a real environment, run this command once:
# =============================================================================
Write-Host "IMPORTANT: Runbook Managed Identity Role Assignment" -ForegroundColor Yellow
Write-Host "  The runbook authenticates as the Automation Account's Managed Identity."
Write-Host "  It needs 'Virtual Machine Contributor' on the target VM to restart it."
Write-Host ""
Write-Host "  In a real subscription, run:"
Write-Host "  New-AzRoleAssignment -ObjectId '$aaPrincipalId' \"
Write-Host "    -RoleDefinitionName 'Virtual Machine Contributor' \"
Write-Host "    -Scope '$vmResourceId'"
Write-Host ""
Write-Host "  In Pluralsight sandbox: assign this role via Azure Portal instead:"
Write-Host "  VM → Access Control (IAM) → Add role assignment → Virtual Machine Contributor"
Write-Host "  → Assign access to: Managed Identity → $automationAccountName"
Write-Host ""

# =============================================================================
# Deployment Summary
# =============================================================================
$elapsed = (Get-Date) - $startTime

Write-Host "==========================================" -ForegroundColor Green
Write-Host " DEPLOYMENT COMPLETE" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Prefix             : $prefix"
Write-Host "  Log Analytics WS   : $workspaceName"
Write-Host "  Automation Account : $automationAccountName"
Write-Host "  Runbook            : $runbookName"
Write-Host "  Webhook            : $webhookName  (URL in docs\webhook-url.txt)"
Write-Host "  Action Group       : $actionGroupName"
Write-Host "  Alert Rule         : $alertRuleName  (CPU > $cpuThreshold%)"
Write-Host "  Target VM          : $targetVmName"
Write-Host "  Alert Email        : $alertEmailAddress"
Write-Host "  Time elapsed       : $('{0:mm\:ss}' -f $elapsed)"
Write-Host ""
Write-Host "  VERIFY IN PORTAL:"
Write-Host "  1. Monitor → Alerts → Alert rules"
Write-Host "  2. Monitor → Action groups"
Write-Host "  3. Automation Accounts → $automationAccountName → Runbooks"
Write-Host "  4. Log Analytics workspaces → $workspaceName → Logs"
Write-Host ""
