# PowerShell script to configure IIS, ASP.NET Core Hosting Bundle, and Web Deploy
# This script is executed during VM provisioning via Azure runCommands.

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$logFile = "C:\setup-iis.log"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $Message" | Tee-Object -FilePath $logFile -Append
}

function Download-WithRetry {
    param([string]$Url, [string]$OutFile, [int]$MaxRetries = 3)
    for ($i = 1; $i -le $MaxRetries; $i++) {
        try {
            Write-Log "  Download attempt $i of $MaxRetries: $Url"
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec 300
            Write-Log "  Download complete."
            return
        } catch {
            Write-Log "  Download attempt $i failed: $_"
            if ($i -eq $MaxRetries) { throw }
            Start-Sleep -Seconds 10
        }
    }
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
$hostingBundlePath = "C:\dotnet-hosting-bundle.exe"
Download-WithRetry -Url "https://builds.dotnet.microsoft.com/dotnet/aspnetcore/Runtime/8.0.14/dotnet-hosting-8.0.14-win.exe" -OutFile $hostingBundlePath
Write-Log "Installing ASP.NET Core 8.0 Hosting Bundle..."
$proc = Start-Process -FilePath $hostingBundlePath -ArgumentList "/install", "/quiet", "/norestart" -Wait -NoNewWindow -PassThru
Write-Log "ASP.NET Core Hosting Bundle installer exited with code $($proc.ExitCode)."

# --------------------------------------------------
# 3. Install Web Deploy 4.0
# --------------------------------------------------
Write-Log "Downloading Web Deploy 3.6..."
$webDeployPath = "C:\WebDeploy_amd64.msi"
Download-WithRetry -Url "https://download.microsoft.com/download/0/1/D/01DC28EA-638C-4A22-A57B-4CEF97755C6C/WebDeploy_amd64_en-US.msi" -OutFile $webDeployPath
Write-Log "Installing Web Deploy..."
$proc = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i", $webDeployPath, "/quiet", "/norestart", "ADDLOCAL=ALL" -Wait -NoNewWindow -PassThru
Write-Log "Web Deploy installer exited with code $($proc.ExitCode)."

# --------------------------------------------------
# 4. Enable Web Management Service (WMSvc)
# --------------------------------------------------
Write-Log "Configuring Web Management Service..."
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WebManagement\Server" -Name "EnableRemoteManagement" -Value 1
Set-Service -Name WMSvc -StartupType Automatic
Start-Service WMSvc
Write-Log "Web Management Service configured and started."

# --------------------------------------------------
# 5. Create IIS site for the app
# --------------------------------------------------
Write-Log "Creating IIS site..."
$sitePath = "C:\inetpub\deploy-to-iis-demo"
if (!(Test-Path $sitePath)) {
    New-Item -ItemType Directory -Path $sitePath -Force
}

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
