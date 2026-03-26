# =============================================================================
# prereqs.ps1 — Project 3: Pre-flight validation before running deploy.ps1
# Run this first. All checks must show [OK] before deploying.
# =============================================================================

. "$PSScriptRoot\config.ps1"

$allPassed = $true

function Write-Check {
    param([string]$Label, [string]$Value, [bool]$IsOk)
    if ($IsOk) {
        Write-Host ("  [OK]   {0,-25} : {1}" -f $Label, $Value) -ForegroundColor Green
    } else {
        Write-Host ("  [FAIL] {0,-25} : {1}" -f $Label, $Value) -ForegroundColor Red
        $script:allPassed = $false
    }
}

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " Pre-requisites Check — Project 3"
Write-Host " Prefix : $prefix"
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# ── CHECK 1: config.ps1 values populated ─────────────────────────────────────
Write-Host "[CHECK 1] config.ps1 values..."
Write-Check "Prefix"    $prefix             ($prefix -ne "" -and $prefix -ne "CHANGE_ME")
Write-Check "RG"        $resourceGroupName  ($resourceGroupName -notmatch "CHANGE_ME")
Write-Check "Location"  $location           ($location -notmatch "CHANGE_ME" -and $location -ne "")
Write-Check "Email"     $alertEmailAddress  ($alertEmailAddress -notmatch "your\.email")
Write-Check "Test VM"   $targetVmName       ($targetVmName -ne "")
Write-Host "  NOTE: VM will be auto-deployed by deploy.ps1" -ForegroundColor DarkGray
Write-Host ""

# ── CHECK 2: Required Az modules installed ────────────────────────────────────
Write-Host "[CHECK 2] Required Az modules..."
$requiredModules = @(
    "Az.Accounts",
    "Az.Monitor",
    "Az.Automation",
    "Az.OperationalInsights"
)
foreach ($mod in $requiredModules) {
    $m = Get-Module -ListAvailable -Name $mod | Sort-Object Version -Descending | Select-Object -First 1
    Write-Check $mod ($m ? "v$($m.Version)" : "NOT INSTALLED") ($null -ne $m)
}
Write-Host ""
Write-Host "  NOTE: To install/update all Az modules:" -ForegroundColor DarkGray
Write-Host "  Install-Module Az -Force -AllowClobber -Scope CurrentUser" -ForegroundColor DarkGray
Write-Host ""

# ── CHECK 3: Logged into Azure ────────────────────────────────────────────────
Write-Host "[CHECK 3] Azure connection..."
try {
    $ctx = Get-AzContext -ErrorAction Stop
    if ($ctx -and $ctx.Account) {
        Write-Check "Connected as"  $ctx.Account.Id           $true
        Write-Check "Subscription"  $ctx.Subscription.Name    ($null -ne $ctx.Subscription)
    } else {
        Write-Check "Azure Context" "NOT CONNECTED — run Connect-AzAccount" $false
    }
} catch {
    Write-Check "Azure Context" "ERROR: run Connect-AzAccount first" $false
}
Write-Host ""

# ── CHECK 4: Resource group accessible ───────────────────────────────────────
Write-Host "[CHECK 4] Resource group access..."
$rg = Get-AzResourceGroup -Name $resourceGroupName -ErrorAction SilentlyContinue
Write-Check "RG found"      $resourceGroupName  ($null -ne $rg)
if ($rg) {
    Write-Check "Location match"  $rg.Location  ($rg.Location -eq $location)
}
Write-Host ""

# ── Result ────────────────────────────────────────────────────────────────────
Write-Host "==========================================" -ForegroundColor Cyan
if ($allPassed) {
    Write-Host " ALL CHECKS PASSED — Ready for deploy.ps1" -ForegroundColor Green
} else {
    Write-Host " CHECKS FAILED — Fix issues above then re-run" -ForegroundColor Red
}
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""
