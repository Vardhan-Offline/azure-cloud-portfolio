# cleanup.ps1
# Deletes all resources created by deploy.ps1 for this prefix.
# Safe to run even if some resources were never created.
# Order matters: VM → Disk → NIC → PIP → VNet → NSG
# (dependent resources must be deleted before the ones they depend on)

. "$PSScriptRoot/config.ps1"

Write-Host "`n=====================================" -ForegroundColor Red
Write-Host " CLEANUP - Prefix: $prefix"             -ForegroundColor Red
Write-Host " RG: $resourceGroupName"                -ForegroundColor Red
Write-Host "=====================================" -ForegroundColor Red
Write-Host ""
Write-Host "Resources targeted for deletion:" -ForegroundColor Yellow
Write-Host "  VM       : $vmName"
Write-Host "  OS Disk  : osdisk-$vmName"
Write-Host "  NIC      : $nicName"
Write-Host "  PIP      : $publicIpName"
Write-Host "  VNet     : $vnetName"
Write-Host "  NSG      : $nsgName"
Write-Host ""

$confirm = Read-Host "Type YES to confirm deletion"
if ($confirm -ne "YES") {
    Write-Host "Cleanup cancelled." -ForegroundColor Green
    exit 0
}

# 1. VM — must be deleted before NIC and disk can be freed
Write-Host "`n[1/6] Deleting VM: $vmName ..." -ForegroundColor Red
$vm = Get-AzVM -ResourceGroupName $resourceGroupName -Name $vmName -ErrorAction SilentlyContinue
if ($vm) {
    Remove-AzVM -ResourceGroupName $resourceGroupName -Name $vmName -Force
    Write-Host "  Deleted." -ForegroundColor Gray
} else {
    Write-Host "  Not found — skipped." -ForegroundColor Gray
}

# 2. OS Disk — VM deletion does NOT auto-delete managed disk
Write-Host "`n[2/6] Deleting OS Disk: osdisk-$vmName ..." -ForegroundColor Red
$disk = Get-AzDisk -ResourceGroupName $resourceGroupName `
    -DiskName "osdisk-$vmName" -ErrorAction SilentlyContinue
if ($disk) {
    Remove-AzDisk -ResourceGroupName $resourceGroupName -DiskName "osdisk-$vmName" -Force
    Write-Host "  Deleted." -ForegroundColor Gray
} else {
    Write-Host "  Not found — skipped." -ForegroundColor Gray
}

# 3. NIC
Write-Host "`n[3/6] Deleting NIC: $nicName ..." -ForegroundColor Red
$nic = Get-AzNetworkInterface -ResourceGroupName $resourceGroupName `
    -Name $nicName -ErrorAction SilentlyContinue
if ($nic) {
    Remove-AzNetworkInterface -ResourceGroupName $resourceGroupName -Name $nicName -Force
    Write-Host "  Deleted." -ForegroundColor Gray
} else {
    Write-Host "  Not found — skipped." -ForegroundColor Gray
}

# 4. Public IP
Write-Host "`n[4/6] Deleting Public IP: $publicIpName ..." -ForegroundColor Red
$pip = Get-AzPublicIpAddress -ResourceGroupName $resourceGroupName `
    -Name $publicIpName -ErrorAction SilentlyContinue
if ($pip) {
    Remove-AzPublicIpAddress -ResourceGroupName $resourceGroupName -Name $publicIpName -Force
    Write-Host "  Deleted." -ForegroundColor Gray
} else {
    Write-Host "  Not found — skipped." -ForegroundColor Gray
}

# 5. VNet (subnet is deleted automatically with VNet)
Write-Host "`n[5/6] Deleting VNet: $vnetName ..." -ForegroundColor Red
$vnet = Get-AzVirtualNetwork -ResourceGroupName $resourceGroupName `
    -Name $vnetName -ErrorAction SilentlyContinue
if ($vnet) {
    Remove-AzVirtualNetwork -ResourceGroupName $resourceGroupName -Name $vnetName -Force
    Write-Host "  Deleted." -ForegroundColor Gray
} else {
    Write-Host "  Not found — skipped." -ForegroundColor Gray
}

# 6. NSG
Write-Host "`n[6/6] Deleting NSG: $nsgName ..." -ForegroundColor Red
$nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $resourceGroupName `
    -Name $nsgName -ErrorAction SilentlyContinue
if ($nsg) {
    Remove-AzNetworkSecurityGroup -ResourceGroupName $resourceGroupName -Name $nsgName -Force
    Write-Host "  Deleted." -ForegroundColor Gray
} else {
    Write-Host "  Not found — skipped." -ForegroundColor Gray
}

Write-Host "`n=====================================" -ForegroundColor Green
Write-Host " Cleanup complete for prefix: $prefix" -ForegroundColor Green
Write-Host " To redeploy: pwsh scripts/deploy.ps1"  -ForegroundColor Green
Write-Host "=====================================" -ForegroundColor Green