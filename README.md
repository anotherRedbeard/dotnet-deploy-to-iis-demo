# Deploy .NET 8 to IIS on Azure VM via GitHub Actions

A complete demo showing how to deploy an ASP.NET Core 8 application to IIS on a Windows Server Azure VM using GitHub Actions and Web Deploy (MSDeploy).

## What's Included

| Component | Description |
|-----------|-------------|
| **ASP.NET Core 8 App** | Razor Pages frontend + `/api/health` API endpoint |
| **Bicep Template** | Provisions a Windows Server 2022 VM with IIS, ASP.NET Core Hosting Bundle, and Web Deploy |
| **PowerShell Setup Script** | Configures IIS, installs dependencies, creates the site |
| **GitHub Actions Workflow** | Builds the app and deploys to IIS via Web Deploy on every push to `main` |

## Prerequisites

- Azure subscription
- Azure CLI installed (`az` command)
- GitHub account with a repository for this code
- .NET 8 SDK (for local development)

## Quick Start

### 1. Deploy the VM Infrastructure

Run the deploy script — it will create the resource group, deploy the VM, and print the outputs you need:

```bash
./infra/deploy.sh
```

You can customize the deployment with flags:

```bash
./infra/deploy.sh -g my-resource-group -l westus2 -p myprefix -u myadmin
```

| Flag | Description | Default |
|------|-------------|---------|
| `-g` | Resource group name | `rg-iis-demo` |
| `-l` | Azure region | `eastus2` |
| `-p` | Name prefix for resources | `iisdemo` |
| `-u` | VM admin username | `azureadmin` |

The script will prompt for the VM admin password and display the outputs when complete.

> **Note on the setup script:** The Bicep template uses a `CustomScriptExtension` that downloads `setup-iis.ps1` from your GitHub repo's `main` branch. Make sure to push this repo to GitHub before deploying, or update the `fileUris` in `main.bicep` to point to the correct raw URL for your repo.

### 2. Configure GitHub Secrets

In your GitHub repository, go to **Settings → Secrets and variables → Actions** and add:

| Secret | Value |
|--------|-------|
| `WEBDEPLOY_URL` | The `webDeployUrl` from the deployment output (e.g., `https://iisdemo-abc123.eastus2.cloudapp.azure.com:8172/msdeploy.axd`) |
| `WEBDEPLOY_USERNAME` | `azureadmin` (or whatever you set in parameters) |
| `WEBDEPLOY_PASSWORD` | The password you used during deployment |

### 3. Push Code and Deploy

```bash
git add .
git commit -m "Initial commit"
git remote add origin https://github.com/<your-org>/deploy-to-iis-demo.git
git push -u origin main
```

The GitHub Actions workflow will automatically:
1. Build the .NET 8 app
2. Publish it as a deployment artifact
3. Deploy to IIS via Web Deploy

### 4. Test the Deployment

**From your browser:**
- Home page: `http://<vm-public-ip>/`
- Health API: `http://<vm-public-ip>/api/health`

**From the command line:**
```bash
curl http://<vm-public-ip>/api/health
```

Expected health response:
```json
{
  "status": "Healthy",
  "timestamp": "2024-01-15T10:30:00Z",
  "environment": "Production",
  "machineName": "iisdemo-vm",
  "dotnetVersion": "8.0.0"
}
```

## Project Structure

```
deploy-to-iis-demo/
├── .github/
│   └── workflows/
│       └── deploy-to-iis.yml      # CI/CD pipeline
├── infra/
│   ├── main.bicep                  # Azure VM + networking
│   ├── deploy.sh                   # One-command infra deployment
│   ├── parameters.json             # Deployment parameters
│   └── setup-iis.ps1               # VM configuration script
├── src/
│   └── DeployToIisDemo/
│       ├── Pages/                  # Razor Pages
│       ├── Program.cs              # App entry + health API
│       ├── web.config              # IIS configuration
│       └── DeployToIisDemo.csproj
├── DeployToIisDemo.sln
├── global.json                     # .NET 8 SDK pin
└── README.md
```

## Troubleshooting

### Web Deploy connection refused
- Verify the VM's NSG allows inbound traffic on port 8172
- RDP into the VM and check that the Web Management Service (WMSvc) is running:
  ```powershell
  Get-Service WMSvc
  ```
- Check if Web Deploy is installed: `Get-Package -Name "Microsoft Web Deploy*"`

### App shows 500 error after deployment
- RDP into the VM and check the IIS logs: `C:\inetpub\logs\LogFiles\`
- Check the ASP.NET Core stdout logs (if enabled in `web.config`)
- Verify the ASP.NET Core Hosting Bundle is installed:
  ```powershell
  Get-ChildItem "HKLM:\SOFTWARE\dotnet\Setup\InstalledVersions\x64\sharedfx\Microsoft.AspNetCore.App"
  ```

### GitHub Actions workflow fails on deploy step
- Ensure all three secrets (`WEBDEPLOY_URL`, `WEBDEPLOY_USERNAME`, `WEBDEPLOY_PASSWORD`) are set correctly
- Check that the Web Deploy URL uses HTTPS and port 8172
- The `-allowUntrusted` flag handles self-signed certs on the VM

### VM setup script didn't run
- Check the extension status in the Azure portal under VM → Extensions
- RDP into the VM and check `C:\setup-iis.log`

## Future Migration to Azure PaaS

When the customer is ready to move off the VM:

1. **Azure App Service** — The most direct migration path. App Service runs IIS behind the scenes, so the app works as-is. Replace the Web Deploy target from the VM to an App Service publish profile.

2. **Azure Container Apps** — Containerize the app with a Dockerfile and deploy to Container Apps for a more modern, scalable approach.

3. **Infrastructure changes** — Swap the VM Bicep template for an App Service Bicep template. The app code itself requires zero changes.

## Clean Up

```bash
az group delete --name rg-iis-demo --yes --no-wait
```
