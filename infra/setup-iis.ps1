# PowerShell script to configure IIS and the ASP.NET Core Hosting Bundle.
# This script is executed during VM provisioning via Azure VM Run Command.

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$logFile = "C:\setup-iis.log"
$siteName = "DeployToIisDemo"
$appPoolName = "DeployToIisDemo"
$sitePath = "C:\inetpub\deploy-to-iis-demo"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $Message" | Tee-Object -FilePath $logFile -Append
}

function Download-WithRetry {
    param([string]$Url, [string]$OutFile, [int]$MaxRetries = 3)
    for ($i = 1; $i -le $MaxRetries; $i++) {
        try {
            Write-Log "  Download attempt $i of ${MaxRetries}: $Url"
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec 300
            Write-Log "  Download complete."
            return
        }
        catch {
            Write-Log "  Download attempt $i failed: $_"
            if ($i -eq $MaxRetries) { throw }
            Start-Sleep -Seconds 10
        }
    }
}

Write-Log "Starting IIS setup..."

Write-Log "Installing IIS..."
Install-WindowsFeature -Name Web-Server, Web-Mgmt-Tools -IncludeManagementTools
Write-Log "IIS installed."

Write-Log "Downloading ASP.NET Core 8.0 Hosting Bundle..."
$hostingBundlePath = "C:\dotnet-hosting-bundle.exe"
Download-WithRetry -Url "https://builds.dotnet.microsoft.com/dotnet/aspnetcore/Runtime/8.0.14/dotnet-hosting-8.0.14-win.exe" -OutFile $hostingBundlePath
Write-Log "Installing ASP.NET Core 8.0 Hosting Bundle..."
$proc = Start-Process -FilePath $hostingBundlePath -ArgumentList "/install", "/quiet", "/norestart" -Wait -NoNewWindow -PassThru
Write-Log "ASP.NET Core Hosting Bundle installer exited with code $($proc.ExitCode)."

Write-Log "Creating IIS site..."
if (!(Test-Path $sitePath)) {
    New-Item -ItemType Directory -Path $sitePath -Force | Out-Null
}

Import-Module WebAdministration
if (Get-Website -Name "Default Web Site" -ErrorAction SilentlyContinue) {
    Remove-Website -Name "Default Web Site"
}

if (!(Test-Path "IIS:\AppPools\$appPoolName")) {
    New-WebAppPool -Name $appPoolName | Out-Null
}
Set-ItemProperty "IIS:\AppPools\$appPoolName" -Name managedRuntimeVersion -Value ""

if (Get-Website -Name $siteName -ErrorAction SilentlyContinue) {
    Set-ItemProperty "IIS:\Sites\$siteName" -Name physicalPath -Value $sitePath
}
else {
    New-Website -Name $siteName -PhysicalPath $sitePath -Port 80 -ApplicationPool $appPoolName -Force | Out-Null
}
Set-ItemProperty "IIS:\Sites\$siteName" -Name applicationPool -Value $appPoolName
Write-Log "IIS site '$siteName' created at $sitePath."

Write-Log "Configuring firewall rules..."
New-NetFirewallRule -DisplayName "Allow HTTP" -Direction Inbound -Protocol TCP -LocalPort 80 -Action Allow -ErrorAction SilentlyContinue | Out-Null
New-NetFirewallRule -DisplayName "Allow HTTPS" -Direction Inbound -Protocol TCP -LocalPort 443 -Action Allow -ErrorAction SilentlyContinue | Out-Null
Write-Log "Firewall rules configured."

Write-Log "Restarting IIS..."
& iisreset /restart
Write-Log "IIS restarted."

Write-Log "Setup complete! VM is ready for GitHub Actions deployments via Azure VM Run Command."
