# PowerShell script to configure IIS, ASP.NET Core Hosting Bundle, and Web Deploy
# This script is executed by the Azure VM CustomScriptExtension during provisioning.

$ErrorActionPreference = "Stop"
$logFile = "C:\setup-iis.log"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $Message" | Tee-Object -FilePath $logFile -Append
}

Write-Log "Starting IIS and Web Deploy setup..."

# --------------------------------------------------
# 1. Install IIS with management tools
# --------------------------------------------------
Write-Log "Installing IIS..."
Install-WindowsFeature -Name Web-Server, Web-Mgmt-Tools, Web-Mgmt-Service -IncludeManagementTools
Write-Log "IIS installed."

# --------------------------------------------------
# 2. Install ASP.NET Core 8.0 Hosting Bundle
# --------------------------------------------------
Write-Log "Downloading ASP.NET Core 8.0 Hosting Bundle..."
$hostingBundleUrl = "https://download.visualstudio.microsoft.com/download/pr/2a7ae819-fbc4-4611-a1ba-f3b072d4ea25/32f3b931550f7b315d9827d564202571/dotnet-hosting-8.0.11-win.exe"
$hostingBundlePath = "C:\dotnet-hosting-bundle.exe"
Invoke-WebRequest -Uri $hostingBundleUrl -OutFile $hostingBundlePath -UseBasicParsing
Write-Log "Installing ASP.NET Core 8.0 Hosting Bundle..."
Start-Process -FilePath $hostingBundlePath -ArgumentList "/install", "/quiet", "/norestart" -Wait -NoNewWindow
Write-Log "ASP.NET Core Hosting Bundle installed."

# --------------------------------------------------
# 3. Install Web Deploy 3.6
# --------------------------------------------------
Write-Log "Downloading Web Deploy 3.6..."
$webDeployUrl = "https://download.microsoft.com/download/0/1/D/01DC28EA-638C-4A22-A57B-4CEF97755C6C/WebDeploy_amd64_en-US.msi"
$webDeployPath = "C:\WebDeploy_amd64.msi"
Invoke-WebRequest -Uri $webDeployUrl -OutFile $webDeployPath -UseBasicParsing
Write-Log "Installing Web Deploy 3.6..."
Start-Process -FilePath "msiexec.exe" -ArgumentList "/i", $webDeployPath, "/quiet", "/norestart", "ADDLOCAL=ALL" -Wait -NoNewWindow
Write-Log "Web Deploy installed."

# --------------------------------------------------
# 4. Enable Web Management Service (WMSvc)
# --------------------------------------------------
Write-Log "Configuring Web Management Service..."
Set-Service -Name WMSvc -StartupType Automatic
Start-Service WMSvc
# Allow remote connections
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WebManagement\Server" -Name "EnableRemoteManagement" -Value 1
Restart-Service WMSvc
Write-Log "Web Management Service configured and started."

# --------------------------------------------------
# 5. Create IIS site for the app
# --------------------------------------------------
Write-Log "Creating IIS site..."
$sitePath = "C:\inetpub\deploy-to-iis-demo"
if (!(Test-Path $sitePath)) {
    New-Item -ItemType Directory -Path $sitePath -Force
}

# Remove default site and create our app site
Import-Module WebAdministration
if (Get-Website -Name "Default Web Site" -ErrorAction SilentlyContinue) {
    Remove-Website -Name "Default Web Site"
}
New-Website -Name "DeployToIisDemo" -PhysicalPath $sitePath -Port 80 -Force
Write-Log "IIS site 'DeployToIisDemo' created at $sitePath."

# --------------------------------------------------
# 6. Configure firewall rules
# --------------------------------------------------
Write-Log "Configuring firewall rules..."
New-NetFirewallRule -DisplayName "Allow HTTP" -Direction Inbound -Protocol TCP -LocalPort 80 -Action Allow -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName "Allow HTTPS" -Direction Inbound -Protocol TCP -LocalPort 443 -Action Allow -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName "Allow Web Deploy" -Direction Inbound -Protocol TCP -LocalPort 8172 -Action Allow -ErrorAction SilentlyContinue
Write-Log "Firewall rules configured."

# --------------------------------------------------
# 7. Restart IIS to pick up the hosting bundle
# --------------------------------------------------
Write-Log "Restarting IIS..."
& iisreset /restart
Write-Log "IIS restarted."

Write-Log "Setup complete! VM is ready for Web Deploy."
