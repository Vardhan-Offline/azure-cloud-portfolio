# install-iis.ps1
# ─────────────────────────────────────────────────────────────────────
# REFERENCE FILE — Human-readable version of what runs INSIDE the VM.
# deploy.ps1 encodes this as Base64 and injects it via Custom Script Extension.
# Do NOT run this directly from your terminal.
# ─────────────────────────────────────────────────────────────────────

# Install IIS Web Server role + management tools
Install-WindowsFeature -Name Web-Server -IncludeManagementTools -ErrorAction Stop

# Create /health directory for health check endpoint
New-Item -Path "C:\inetpub\wwwroot\health" -ItemType Directory -Force

# Create JSON health check response
# Load Balancer / monitoring tools call this URL to verify the server is alive
$healthJson = '{"status":"healthy","service":"vm-hardened-win","version":"1.0","managed_by":"PowerShell"}'
Set-Content -Path "C:\inetpub\wwwroot\health\index.json" -Value $healthJson

# Create HTML home page
Set-Content -Path "C:\inetpub\wwwroot\index.html" -Value @"
<html>
<body style="font-family:Arial;padding:40px">
  <h1 style="color:#0078d4">Azure VM Auto-Hardening</h1>
  <p>Windows Server 2022 + IIS deployed via PowerShell Az module</p>
  <ul>
    <li>NSG: HTTP/HTTPS allowed, RDP blocked from internet</li>
    <li>Managed Identity: SystemAssigned (no passwords)</li>
    <li>Boot Diagnostics: Enabled</li>
    <li>Trusted Launch: vTPM + SecureBoot</li>
  </ul>
  <p><a href="/health/index.json">Health Check Endpoint</a></p>
</body>
</html>
"@