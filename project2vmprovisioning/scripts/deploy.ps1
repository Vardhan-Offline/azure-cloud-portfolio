# deploy.ps1
# ─────────────────────────────────────────────────────────────────────
# Project 2: Azure VM Auto-Hardening — Idempotent Deployment Script
#
# WHAT THIS BUILDS (zero portal clicks):
#   VNet → Subnet → NSG (Allow 80/443, Deny RDP) → Static Public IP
#   → NIC → Windows Server 2022 VM (Trusted Launch: vTPM + SecureBoot)
#   → System-Assigned Managed Identity → IIS + Health Endpoint
#   → Boot Diagnostics
#
# IDEMPOTENT: Each resource is checked before creation.
#   Exists → Skipped | Does not exist → Created
#   Safe to run multiple times.
#
# FIX APPLIED: IIS file creation uses [System.IO.File]::WriteAllText()
#   instead of Set-Content inside Base64-encoded commands.
#   Reason: Set-Content quote escaping gets doubled inside encoded
#   PowerShell commands, causing file creation to fail silently.
# ─────────────────────────────────────────────────────────────────────

. "$PSScriptRoot/config.ps1"

# ── Helper: consistent status output ─────────────────────────────────
function Write-Status($type, $name, $status) {
    $color = if ($status -like "Skipped*") { "Yellow" } else { "Gray" }
    Write-Host ("  [{0}] {1,-30} {2}" -f $type, $name, $status) -ForegroundColor $color
}

# ── Password prompt ───────────────────────────────────────────────────
Write-Host "`n[INPUT REQUIRED]" -ForegroundColor Yellow
Write-Host "Password rules: min 12 chars, uppercase, lowercase, number, special char" -ForegroundColor Gray
Write-Host "Example: Azure@Secure2026!" -ForegroundColor Gray
$adminPasswordSecure = Read-Host -AsSecureString "Enter VM admin password"
if ($adminPasswordSecure.Length -eq 0) { Write-Error "Password cannot be empty."; exit 1 }
$credential = New-Object System.Management.Automation.PSCredential($adminUsername, $adminPasswordSecure)
$stopwatch  = [System.Diagnostics.Stopwatch]::StartNew()

Write-Host "`n=========================================" -ForegroundColor Cyan
Write-Host " DEPLOYMENT START - VM Auto-Hardening"     -ForegroundColor Cyan
Write-Host " Prefix   : $prefix"                       -ForegroundColor Cyan
Write-Host " RG       : $resourceGroupName"            -ForegroundColor Cyan
Write-Host " Location : $location"                     -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan

# ── STEP 0: Verify connection ─────────────────────────────────────────
Write-Host "`n[STEP 0] Verifying Azure connection..." -ForegroundColor Green
$context = Get-AzContext
if (-not $context) { Write-Error "Not connected. Run Connect-AzAccount"; exit 1 }
Write-Host "  Connected as : $($context.Account.Id)" -ForegroundColor Gray
Write-Host "  Subscription : $($context.Subscription.Name)" -ForegroundColor Gray

# ── STEP 1: VNet + Subnet ─────────────────────────────────────────────
Write-Host "`n[STEP 1] Virtual Network and Subnet..." -ForegroundColor Green
$vnet = Get-AzVirtualNetwork -ResourceGroupName $resourceGroupName `
    -Name $vnetName -ErrorAction SilentlyContinue
if (-not $vnet) {
    $subnetConfig = New-AzVirtualNetworkSubnetConfig `
        -Name $subnetName -AddressPrefix $subnetPrefix
    $vnet = New-AzVirtualNetwork `
        -ResourceGroupName $resourceGroupName -Location $location `
        -Name $vnetName -AddressPrefix $vnetPrefix `
        -Subnet $subnetConfig -Tag $tags
    Write-Status "VNet" $vnetName "Created ($vnetPrefix)"
} else {
    Write-Status "VNet" $vnetName "Skipped (exists)"
}

# ── STEP 2: NSG + Rules + Associate to Subnet ─────────────────────────
Write-Host "`n[STEP 2] Network Security Group..." -ForegroundColor Green
$nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $resourceGroupName `
    -Name $nsgName -ErrorAction SilentlyContinue
if (-not $nsg) {
    # Allow HTTP :80 inbound — IIS serves web pages on this port
    $ruleHTTP = New-AzNetworkSecurityRuleConfig `
        -Name "Allow-HTTP-Inbound" -Protocol Tcp -Direction Inbound -Priority 100 `
        -SourceAddressPrefix Internet -SourcePortRange "*" `
        -DestinationAddressPrefix "*" -DestinationPortRange "80" -Access Allow

    # Allow HTTPS :443 inbound — secure web traffic
    $ruleHTTPS = New-AzNetworkSecurityRuleConfig `
        -Name "Allow-HTTPS-Inbound" -Protocol Tcp -Direction Inbound -Priority 110 `
        -SourceAddressPrefix Internet -SourcePortRange "*" `
        -DestinationAddressPrefix "*" -DestinationPortRange "443" -Access Allow

    # EXPLICITLY DENY RDP :3389 from internet — hardening rule
    # Why explicit: documents security intent, visible in audit reports
    # In production: use Azure Bastion instead of direct RDP
    $ruleDenyRDP = New-AzNetworkSecurityRuleConfig `
        -Name "Deny-RDP-Internet" -Protocol Tcp -Direction Inbound -Priority 200 `
        -SourceAddressPrefix Internet -SourcePortRange "*" `
        -DestinationAddressPrefix "*" -DestinationPortRange "3389" -Access Deny

    $nsg = New-AzNetworkSecurityGroup `
        -ResourceGroupName $resourceGroupName -Location $location `
        -Name $nsgName -SecurityRules @($ruleHTTP, $ruleHTTPS, $ruleDenyRDP) -Tag $tags

    # Associate NSG to subnet — creating NSG alone does nothing
    $vnet   = Get-AzVirtualNetwork -ResourceGroupName $resourceGroupName -Name $vnetName
    $subnet = Get-AzVirtualNetworkSubnetConfig -Name $subnetName -VirtualNetwork $vnet
    $subnet.NetworkSecurityGroup = $nsg
    $vnet | Set-AzVirtualNetwork | Out-Null

    Write-Status "NSG" $nsgName "Created + associated to $subnetName"
} else {
    Write-Status "NSG" $nsgName "Skipped (exists)"
}
Write-Host "  Rules: Allow-HTTP-80 | Allow-HTTPS-443 | Deny-RDP-3389" -ForegroundColor Gray

# ── STEP 3: Public IP ─────────────────────────────────────────────────
Write-Host "`n[STEP 3] Public IP Address..." -ForegroundColor Green
$publicIp = Get-AzPublicIpAddress -ResourceGroupName $resourceGroupName `
    -Name $publicIpName -ErrorAction SilentlyContinue
if (-not $publicIp) {
    $publicIp = New-AzPublicIpAddress `
        -ResourceGroupName $resourceGroupName -Location $location `
        -Name $publicIpName -AllocationMethod Static -Sku Standard -Tag $tags
    Write-Status "PIP" $publicIpName "Created (Static, Standard SKU)"
} else {
    Write-Status "PIP" $publicIpName "Skipped (exists)"
}

# ── STEP 4: NIC ───────────────────────────────────────────────────────
Write-Host "`n[STEP 4] Network Interface Card..." -ForegroundColor Green
$nic = Get-AzNetworkInterface -ResourceGroupName $resourceGroupName `
    -Name $nicName -ErrorAction SilentlyContinue
if (-not $nic) {
    # Re-fetch VNet to get updated object after NSG association
    $vnet   = Get-AzVirtualNetwork -ResourceGroupName $resourceGroupName -Name $vnetName
    $subnet = Get-AzVirtualNetworkSubnetConfig -Name $subnetName -VirtualNetwork $vnet
    $nic = New-AzNetworkInterface `
        -ResourceGroupName $resourceGroupName -Location $location `
        -Name $nicName -SubnetId $subnet.Id -PublicIpAddressId $publicIp.Id -Tag $tags
    Write-Status "NIC" $nicName "Created"
} else {
    Write-Status "NIC" $nicName "Skipped (exists)"
}

# ── STEP 5: VM Deployment (Trusted Launch) ────────────────────────────
# Trusted Launch = required by this subscription.
# Provides: vTPM (virtual Trusted Platform Module) + Secure Boot
# Protects against: firmware attacks, rootkits, boot-level malware
# SKU "2022-datacenter-g2" = Gen2 image required for Trusted Launch
Write-Host "`n[STEP 5] Windows Server 2022 VM (Trusted Launch)..." -ForegroundColor Green
$vm = Get-AzVM -ResourceGroupName $resourceGroupName `
    -Name $vmName -ErrorAction SilentlyContinue
if (-not $vm) {
    Write-Host "  Deploying VM — takes 5-8 minutes, please wait..." -ForegroundColor Gray

    $vmConfig = New-AzVMConfig -VMName $vmName -VMSize $vmSize -SecurityType "TrustedLaunch"
    $vmConfig = Set-AzVMSecurityProfile -VM $vmConfig -SecurityType "TrustedLaunch"
    $vmConfig = Set-AzVMUefi -VM $vmConfig -EnableVtpm $true -EnableSecureBoot $true
    $vmConfig = Set-AzVMOperatingSystem -VM $vmConfig -Windows -ComputerName $vmName `
        -Credential $credential -ProvisionVMAgent -EnableAutoUpdate
    $vmConfig = Set-AzVMSourceImage -VM $vmConfig `
        -PublisherName "MicrosoftWindowsServer" `
        -Offer         "WindowsServer" `
        -Skus          "2022-datacenter-g2" `
        -Version       "latest"
    $vmConfig = Set-AzVMOSDisk -VM $vmConfig `
        -Name "osdisk-$vmName" -CreateOption FromImage -StorageAccountType Standard_LRS
    $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $nic.Id
    $vmConfig = Set-AzVMBootDiagnostic -VM $vmConfig -Enable

    New-AzVM -ResourceGroupName $resourceGroupName -Location $location -VM $vmConfig -Tag $tags
    Write-Status "VM" $vmName "Created ($vmSize, Trusted Launch)"
} else {
    Write-Status "VM" $vmName "Skipped (exists)"
}

# ── STEP 6: System-Assigned Managed Identity ──────────────────────────
# Gives the VM an Azure AD identity — no passwords stored anywhere.
# The VM uses this identity to authenticate to Key Vault, Storage etc.
# Azure manages the private key; it never leaves Azure hardware.
Write-Host "`n[STEP 6] System-Assigned Managed Identity..." -ForegroundColor Green
$vm = Get-AzVM -ResourceGroupName $resourceGroupName -Name $vmName
if ($vm.Identity.Type -ne "SystemAssigned") {
    Update-AzVM -ResourceGroupName $resourceGroupName -VM $vm -IdentityType SystemAssigned
    $vm = Get-AzVM -ResourceGroupName $resourceGroupName -Name $vmName
    Write-Status "Identity" $vmName "SystemAssigned enabled"
} else {
    Write-Status "Identity" $vmName "Skipped (already enabled)"
}
Write-Host "  Principal ID : $($vm.Identity.PrincipalId)" -ForegroundColor Gray

# ── STEP 7: IIS + Health Endpoint via Custom Script Extension ─────────
# HOW IT WORKS:
#   1. Script string is Base64-encoded (Unicode) on your machine
#   2. Azure VM Agent receives the encoded command via Azure fabric
#   3. VM Agent runs: powershell.exe -EncodedCommand <base64>
#   4. Script executes INSIDE the VM as SYSTEM — no RDP needed
#
# FIX: Uses [System.IO.File]::WriteAllText() instead of Set-Content
#   because Set-Content quote escaping gets doubled inside
#   Base64-encoded commands, causing file creation to fail silently.
#
# IDEMPOTENCY: Checks if extension exists before installing.
#   Re-running extension on same VM causes a conflict error — skip if present.
Write-Host "`n[STEP 7] IIS + Health Endpoint (Custom Script Extension)..." -ForegroundColor Green
$ext = Get-AzVMExtension -ResourceGroupName $resourceGroupName `
    -VMName $vmName -Name "CustomScriptExtension" -ErrorAction SilentlyContinue
if (-not $ext) {
    Write-Host "  Installing IIS inside VM — takes 3-5 minutes..." -ForegroundColor Gray

    # This script runs INSIDE the VM
    # Using WriteAllText for reliable file creation with special characters
    $iisScript = @'
Install-WindowsFeature -Name Web-Server -IncludeManagementTools -ErrorAction Stop

New-Item -Path 'C:\inetpub\wwwroot\health' -ItemType Directory -Force | Out-Null

[System.IO.File]::WriteAllText(
    'C:\inetpub\wwwroot\health\index.json',
    '{"status":"healthy","service":"vm-lkv-win","version":"1.0","managed_by":"PowerShell","security":"TrustedLaunch"}'
)

[System.IO.File]::WriteAllText(
    'C:\inetpub\wwwroot\index.html',
    '<html><body style="font-family:Arial;padding:40px;background:#f0f0f0"><div style="background:white;padding:30px;border-radius:8px;max-width:600px"><h1 style="color:#0078d4">Azure VM Auto-Hardening</h1><p>Windows Server 2022 + IIS deployed via <strong>PowerShell Az module</strong></p><ul><li>NSG: Allow HTTP/HTTPS, Deny RDP from internet</li><li>Managed Identity: SystemAssigned (no passwords)</li><li>Boot Diagnostics: Enabled</li><li>Trusted Launch: vTPM + SecureBoot</li><li>Idempotent deployment script</li></ul><p><a href="/health/index.json" style="color:#0078d4">Health Check Endpoint</a></p></div></body></html>'
)

Import-Module WebAdministration -ErrorAction SilentlyContinue
try {
    $exists = Get-WebConfigurationProperty `
        -PSPath 'IIS:\' `
        -Filter 'system.webServer/staticContent' `
        -Name '.' |
        Where-Object { $_.fileExtension -eq '.json' }
    if (-not $exists) {
        Add-WebConfigurationProperty `
            -PSPath 'IIS:\' `
            -Filter 'system.webServer/staticContent' `
            -Name '.' `
            -Value @{ fileExtension = '.json'; mimeType = 'application/json' }
    }
} catch {}

Write-Output 'IIS setup complete'
'@

    # Encode script as Base64 Unicode — required by PowerShell -EncodedCommand
    $encodedScript = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($iisScript)
    )

    Set-AzVMExtension `
        -ResourceGroupName  $resourceGroupName `
        -VMName             $vmName `
        -Name               "CustomScriptExtension" `
        -Publisher          "Microsoft.Compute" `
        -ExtensionType      "CustomScriptExtension" `
        -TypeHandlerVersion "1.10" `
        -ProtectedSettings  @{ "commandToExecute" = "powershell.exe -EncodedCommand $encodedScript" }

    Write-Status "IIS" "CustomScriptExtension" "Installed"
} else {
    Write-Status "IIS" "CustomScriptExtension" "Skipped (already installed)"
}

# ── FINAL OUTPUT ──────────────────────────────────────────────────────
$stopwatch.Stop()
$pip = Get-AzPublicIpAddress -ResourceGroupName $resourceGroupName -Name $publicIpName
$vm  = Get-AzVM -ResourceGroupName $resourceGroupName -Name $vmName

Write-Host "`n=========================================" -ForegroundColor Cyan
Write-Host " DEPLOYMENT COMPLETE"                       -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Prefix           : $prefix"
Write-Host "  VM Name          : $vmName"
Write-Host "  VM Size          : $vmSize"
Write-Host "  Security Type    : Trusted Launch (vTPM + SecureBoot)"
Write-Host "  Public IP        : $($pip.IpAddress)"
Write-Host "  IIS Home Page    : http://$($pip.IpAddress)"
Write-Host "  Health Endpoint  : http://$($pip.IpAddress)/health/index.json"
Write-Host "  Managed Identity : $($vm.Identity.PrincipalId)"
Write-Host "  Boot Diagnostics : Enabled"
Write-Host "  Time elapsed     : $($stopwatch.Elapsed.ToString('mm\:ss'))"
Write-Host ""
Write-Host "  NEXT STEPS:" -ForegroundColor Yellow
Write-Host "  1. Test : http://$($pip.IpAddress)" -ForegroundColor Yellow
Write-Host "  2. Test : http://$($pip.IpAddress)/health/index.json" -ForegroundColor Yellow
Write-Host "  3. Take portal screenshots (see docs/screenshots/)" -ForegroundColor Yellow
Write-Host "  4. Save output is already in docs/deploy-output.txt" -ForegroundColor Yellow
Write-Host "  5. Cleanup: pwsh scripts/cleanup.ps1" -ForegroundColor Yellow
Write-Host "=========================================" -ForegroundColor Cyan