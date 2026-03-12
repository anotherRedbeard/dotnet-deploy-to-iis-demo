param(
    [string]$PackageUrl,

    [string]$PackageUrlBase64,

    [string]$SitePath = "C:\inetpub\deploy-to-iis-demo",

    [string]$SiteName = "DeployToIisDemo"
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$logFile = "C:\deploy-app.log"
$workingRoot = "C:\deploy-to-iis-demo-staging"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $Message" | Tee-Object -FilePath $logFile -Append
}

function Invoke-Robocopy {
    param(
        [string]$Source,
        [string]$Destination
    )

    & robocopy $Source $Destination /MIR /R:3 /W:5 /NFL /NDL /NJH /NJS /NP
    $exitCode = $LASTEXITCODE
    if ($exitCode -gt 7) {
        throw "Robocopy failed with exit code $exitCode."
    }
}

$timestamp = Get-Date -Format "yyyyMMddHHmmss"
$workingPath = Join-Path $workingRoot $timestamp
$packagePath = Join-Path $workingPath "package.zip"
$expandedPath = Join-Path $workingPath "package"
$appOfflinePath = Join-Path $SitePath "app_offline.htm"
$stagedOfflinePath = Join-Path $expandedPath "app_offline.htm"
$appOfflineContent = @"
<html>
  <body>
    <h1>Deploying update...</h1>
    <p>The application will be available again in a few moments.</p>
  </body>
</html>
"@

try {
    Write-Log "Starting application deployment."

    if ([string]::IsNullOrWhiteSpace($PackageUrl)) {
        if ([string]::IsNullOrWhiteSpace($PackageUrlBase64)) {
            throw "Either PackageUrl or PackageUrlBase64 must be provided."
        }

        try {
            $PackageUrl = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($PackageUrlBase64))
        }
        catch {
            throw "PackageUrlBase64 could not be decoded as base64."
        }
    }

    New-Item -ItemType Directory -Path $workingPath -Force | Out-Null
    New-Item -ItemType Directory -Path $expandedPath -Force | Out-Null
    if (!(Test-Path $SitePath)) {
        New-Item -ItemType Directory -Path $SitePath -Force | Out-Null
    }

    Write-Log "Downloading deployment package."
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $PackageUrl -OutFile $packagePath -UseBasicParsing -TimeoutSec 300

    Write-Log "Expanding deployment package."
    Expand-Archive -Path $packagePath -DestinationPath $expandedPath -Force

    Write-Log "Putting application offline."
    Set-Content -Path $stagedOfflinePath -Value $appOfflineContent -Encoding UTF8
    Copy-Item -Path $stagedOfflinePath -Destination $appOfflinePath -Force
    Start-Sleep -Seconds 5

    Write-Log "Synchronizing files to IIS site path."
    Invoke-Robocopy -Source $expandedPath -Destination $SitePath

    Remove-Item -Path $appOfflinePath -Force -ErrorAction SilentlyContinue

    Import-Module WebAdministration
    $website = Get-Website -Name $SiteName -ErrorAction SilentlyContinue
    if ($null -ne $website -and $website.State -ne 'Started') {
        Write-Log "Starting IIS site '$SiteName'."
        Start-Website -Name $SiteName
    }

    Write-Log "Deployment completed successfully."
}
catch {
    Write-Log "Deployment failed: $_"
    throw
}
finally {
    Remove-Item -Path $appOfflinePath -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $workingPath -Recurse -Force -ErrorAction SilentlyContinue
}
