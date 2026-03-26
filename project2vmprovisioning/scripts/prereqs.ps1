# prereqs.ps1
# Validates environment before deploy.ps1 is run.
# Dot-sources config.ps1 for all variables.

. "$PSScriptRoot/config.ps1"

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host " Pre-requisites Check - Project 2"        -ForegroundColor Cyan
Write-Host " Prefix : $prefix"                        -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan

$allOk = $true

# CHECK 1: config.ps1 values filled in
Write-Host "`n[CHECK 1] config.ps1 values..." -ForegroundColor Green
if ($resourceGroupName -eq "PASTE_YOUR_RG_NAME_HERE") {
    Write-Host "  [FAIL] Open scripts/config.ps1 and set resourceGroupName" -ForegroundColor Red
    $allOk = $false
} elseif ($location -eq "PASTE_YOUR_LOCATION_HERE") {
    Write-Host "  [FAIL] Open scripts/config.ps1 and set location" -ForegroundColor Red
    $allOk = $false
} else {
    Write-Host "  [OK] RG       : $resourceGroupName" -ForegroundColor Green
    Write-Host "  [OK] Location : $location" -ForegroundColor Green
    Write-Host "  [OK] Prefix   : $prefix" -ForegroundColor Green
}

# CHECK 2: Az module available
Write-Host "`n[CHECK 2] Az PowerShell module..." -ForegroundColor Green
if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
    Write-Host "  Az module not found. Installing..." -ForegroundColor Yellow
    Install-Module -Name Az -AllowClobber -Scope CurrentUser -Force
}
$azVer = (Get-Module -ListAvailable -Name Az.Accounts | Select-Object -First 1).Version
Write-Host "  [OK] Az.Accounts version: $azVer" -ForegroundColor Green

# CHECK 3: Azure connection
Write-Host "`n[CHECK 3] Azure connection..." -ForegroundColor Green
$context = Get-AzContext
if (-not $context) {
    Write-Host "  Not connected. Running Connect-AzAccount..." -ForegroundColor Yellow
    Connect-AzAccount
    $context = Get-AzContext
}
Write-Host "  [OK] Connected as : $($context.Account.Id)" -ForegroundColor Green
Write-Host "  [OK] Subscription : $($context.Subscription.Name)" -ForegroundColor Green

# CHECK 4: Resource group accessible
Write-Host "`n[CHECK 4] Resource group access..." -ForegroundColor Green
$rg = Get-AzResourceGroup -Name $resourceGroupName -ErrorAction SilentlyContinue
if (-not $rg) {
    Write-Host "  [FAIL] RG '$resourceGroupName' not found." -ForegroundColor Red
    Write-Host "  Run: az group list -o table" -ForegroundColor Yellow
    $allOk = $false
} else {
    Write-Host "  [OK] RG found    : $resourceGroupName" -ForegroundColor Green
    Write-Host "  [OK] Location    : $($rg.Location)" -ForegroundColor Green
    if ($rg.Location -ne $location) {
        Write-Host "  [WARN] Location mismatch: config=$location, actual=$($rg.Location)" -ForegroundColor Yellow
        Write-Host "  Update location in config.ps1 to: $($rg.Location)" -ForegroundColor Yellow
        $allOk = $false
    }
}

# SUMMARY
Write-Host "`n=========================================" -ForegroundColor Cyan
if ($allOk) {
    Write-Host " ALL CHECKS PASSED. Run deploy.ps1" -ForegroundColor Green
} else {
    Write-Host " FIX THE ABOVE ERRORS then re-run prereqs.ps1" -ForegroundColor Red
}
Write-Host "=========================================" -ForegroundColor Cyan