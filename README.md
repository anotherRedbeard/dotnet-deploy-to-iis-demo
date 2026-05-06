# Deploy .NET 8 to IIS from a GitHub Release via GitHub Actions + Azure OIDC

This demo shows how to deploy an ASP.NET Core 8 application to IIS on a Windows Server Azure VM **without** storing VM credentials in GitHub.

## What Changed

This repository is moving from:

- **Old flow:** GitHub Actions -> Web Deploy (MSDeploy) -> IIS VM using VM username/password secrets

To:

- **New flow:** GitHub Actions -> GitHub Release asset -> Azure VM Run Command -> PowerShell deployment on the IIS VM

That means GitHub no longer needs the VM administrator username/password to deploy.

## Why This Is More Secure

The new flow is safer because:

- GitHub Actions authenticates to Azure with **short-lived OIDC tokens**, not a long-lived client secret or VM password.
- The workflow deploys through the **Azure control plane** (`azure/login`, VM Run Command) instead of logging directly into the VM.
- The deployment package can be distributed from **GitHub Releases**, which is closer to how an on-prem server would pull a versioned artifact.
- You can scope Azure permissions with **RBAC**.
- The VM admin password becomes a **break-glass / RDP credential**, not a CI/CD secret.
- Once Web Deploy is retired, you no longer need to depend on port **8172** for deployments.

## What's Included

| Component | Description |
|-----------|-------------|
| **ASP.NET Core 8 App** | Razor Pages frontend + `/api/health` API endpoint |
| **Bicep / Infra Script** | Provisions the Windows Server VM and supporting Azure resources |
| **PowerShell Setup Script** | Configures IIS and the application site on the VM |
| **GitHub Actions Workflow** | Builds the app, publishes a release asset, and tells the VM to deploy it |

## End-to-End Deployment Flow

On each deployment, the workflow should do the following:

1. **Build and publish** the .NET app on the GitHub runner.
2. **Authenticate to Azure** with `azure/login` using GitHub's OIDC token.
3. **Create a GitHub Release** for the run and upload the published package as a release asset.
4. **Invoke Azure VM Run Command** against the IIS VM.
5. **Run PowerShell on the VM** to download the release asset, stop/update the IIS site, copy files, and restart the app.
6. **Verify** the app is healthy, typically by hitting `/api/health`.

## Prerequisites

### Azure prerequisites

You need:

- An Azure subscription
- Azure CLI installed (`az`)
- Permission to create or update:
  - resource groups
  - storage accounts / containers
  - virtual machines
  - Microsoft Entra app registrations or service principals
  - role assignments
- Enough RBAC to assign roles at the resource group scope
  - `Owner` or `User Access Administrator` is the common setup

### GitHub prerequisites

You need:

- A GitHub repository for this code
- GitHub Actions enabled for the repository
- Permission to create repository **Actions secrets and variables**
- GitHub CLI installed (`gh`) if you want to configure variables from the command line

### Local development prerequisites

- .NET 8 SDK

## Quick Start

### 1. Deploy the Azure infrastructure

Run the deploy script:

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

> The script still prompts for a VM admin password because Windows needs a local admin account. That password is for RDP / recovery scenarios; **it is no longer a GitHub deployment secret**.

### 2. Capture the infrastructure outputs

The updated infrastructure flow should expose or print the values the workflow needs. Expect outputs equivalent to these:

| Infra output | Example | Used for |
|--------------|---------|----------|
| `resourceGroupName` | `rg-iis-demo` | GitHub variable `AZURE_RESOURCE_GROUP` |
| `vmName` | `iisdemo-vm` | GitHub variable `AZURE_VM_NAME` |
| `siteName` | `DeployToIisDemo` | GitHub variable `IIS_SITE_NAME` |
| `vmPublicIp` | `20.42.10.15` | Manual browser / curl testing |
| `vmFqdn` | `iisdemo-abc123.eastus2.cloudapp.azure.com` | Optional manual testing |

If your script prints slightly different output names, map the **equivalent values** into the GitHub variables above.

For the rest of this README, export those values into shell variables:

```bash
export GITHUB_OWNER="<your-github-user-or-org>"
export GITHUB_REPO="<your-repo-name>"

export RESOURCE_GROUP="<resourceGroupName output>"
export VM_NAME="<vmName output>"
export SITE_NAME="<siteName output>"

export SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
export TENANT_ID="$(az account show --query tenantId -o tsv)"
```

## One-Time Azure Setup for GitHub OIDC

### 3. Create the Microsoft Entra application and service principal

This application represents GitHub Actions when it deploys.

```bash
export APP_NAME="gh-${GITHUB_REPO}-deploy"

export APP_ID="$(az ad app create \
  --display-name "$APP_NAME" \
  --query appId -o tsv)"

export APP_OBJECT_ID="$(az ad app show \
  --id "$APP_ID" \
  --query id -o tsv)"

export SP_OBJECT_ID="$(az ad sp create \
  --id "$APP_ID" \
  --query id -o tsv)"
```

Save `APP_ID`; that becomes the workflow's Azure client ID.

### 4. Add the GitHub OIDC federated credential

Create a federated credential that trusts deployments from your repository's `main` branch:

```bash
cat > federated-credential.json <<EOF_JSON
{
  "name": "github-main",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:${GITHUB_OWNER}/${GITHUB_REPO}:ref:refs/heads/main",
  "description": "GitHub Actions deployments from main",
  "audiences": [
    "api://AzureADTokenExchange"
  ]
}
EOF_JSON

az ad app federated-credential create \
  --id "$APP_OBJECT_ID" \
  --parameters @federated-credential.json

rm federated-credential.json
```

If you also deploy from another branch or a GitHub Environment, add another federated credential with the matching `subject`.

Examples:

- Branch subject: `repo:OWNER/REPO:ref:refs/heads/release`
- Environment subject: `repo:OWNER/REPO:environment:production`

### 5. Grant Azure RBAC permissions

The workflow needs permission to invoke Run Command against the VM.

Create scopes:

```bash
export RG_SCOPE="$(az group show \
  --name "$RESOURCE_GROUP" \
  --query id -o tsv)"

az role assignment create \
  --assignee-object-id "$SP_OBJECT_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Virtual Machine Contributor" \
  --scope "$RG_SCOPE"
```

These assignments are enough for the documented flow in most demos:

- `Virtual Machine Contributor` lets the workflow call VM Run Command on the target VM.

If your organization requires tighter permissions, replace these with a custom role later. Start here first so you can validate the pipeline end to end.

## One-Time GitHub Repository Setup

### 6. Configure repository Actions secrets and variables

OIDC removes the need for a stored **VM credential**, but the workflow still needs Azure identity values for `azure/login`.

Add these GitHub Actions **secrets**:

- `AZURE_CLIENT_ID`
- `AZURE_TENANT_ID`
- `AZURE_SUBSCRIPTION_ID`

Add these GitHub Actions **variables**:

- `AZURE_RESOURCE_GROUP`
- `AZURE_VM_NAME`
- `IIS_SITE_NAME`

Optional GitHub Actions **secret**:

- `GITHUB_RELEASE_DOWNLOAD_TOKEN`

> The demo workflow can fall back to the per-run `GITHUB_TOKEN` when it immediately deploys the release asset to the Azure VM. For a real on-prem pull model against a private repository, use a dedicated fine-grained PAT or GitHub App token instead.

> **You should not need `WEBDEPLOY_URL`, `WEBDEPLOY_USERNAME`, or `WEBDEPLOY_PASSWORD` anymore.**

Log in to GitHub CLI and target your repository:

```bash
gh auth login
gh repo set-default "${GITHUB_OWNER}/${GITHUB_REPO}"
```

Create the secrets:

```bash
gh secret set AZURE_CLIENT_ID --body "$APP_ID"
gh secret set AZURE_TENANT_ID --body "$TENANT_ID"
gh secret set AZURE_SUBSCRIPTION_ID --body "$SUBSCRIPTION_ID"
```

Create the variables:

```bash

gh variable set AZURE_RESOURCE_GROUP --body "$RESOURCE_GROUP"
gh variable set AZURE_VM_NAME --body "$VM_NAME"
gh variable set IIS_SITE_NAME --body "$SITE_NAME"
```

Optional secret for private release downloads:

```bash
gh secret set GITHUB_RELEASE_DOWNLOAD_TOKEN --body "<fine-grained-pat-or-installation-token>"
```

If you prefer the GitHub web UI, go to:

**Settings -> Secrets and variables -> Actions**

Add the Azure identity values as **Secrets**, and add the resource names as **Variables**.

### 7. Make sure the workflow can request an OIDC token

The deployment job must request GitHub's OIDC token. In GitHub Actions that means the deploy job needs:

```yaml
permissions:
  id-token: write
  contents: write
```

And `azure/login` should use the repository secrets above:

```yaml
with:
  client-id: ${{ secrets.AZURE_CLIENT_ID }}
  tenant-id: ${{ secrets.AZURE_TENANT_ID }}
  subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
```

## Deploy the Application

### 8. Push code to `main`

```bash
git add .
git commit -m "Initial commit"
git remote add origin https://github.com/<your-org>/<your-repo-name>.git
git push -u origin main
```

### 9. What the workflow should do

When the workflow runs successfully, expect this sequence:

1. `dotnet restore`
2. `dotnet build`
3. `dotnet publish`
4. create a deployable package (typically zip)
5. create a GitHub Release for the workflow run and upload the zip as a release asset
6. `azure/login` using GitHub OIDC
7. invoke `az vm run-command invoke` or equivalent on `AZURE_VM_NAME`
8. run PowerShell on the VM to:
   - download the release asset from GitHub
   - stop or drain the IIS site/app pool as needed
   - replace application files
   - start IIS again
   - verify the deployed app

## Test the Deployment

Use the VM public IP or FQDN that the infrastructure deployment printed.

**Browser**

- Home page: `http://<vm-public-ip>/`
- Health API: `http://<vm-public-ip>/api/health`

**Command line**

```bash
curl http://<vm-public-ip>/api/health
```

Expected response shape:

```json
{
  "status": "Healthy",
  "timestamp": "2024-01-15T10:30:00Z",
  "environment": "Production",
  "machineName": "iisdemo-vm",
  "dotnetVersion": "8.0.0"
}
```

## How Infra Outputs Map to GitHub Configuration

This is the most important hand-off between Azure infrastructure and GitHub Actions:

| Azure / infra value | Where you get it | GitHub configuration |
|---------------------|------------------|----------------------|
| Azure tenant ID | `az account show --query tenantId -o tsv` | `AZURE_TENANT_ID` |
| Azure subscription ID | `az account show --query id -o tsv` | `AZURE_SUBSCRIPTION_ID` |
| Entra app client ID | `APP_ID` from `az ad app create` | `AZURE_CLIENT_ID` |
| Resource group name | infra output / `deploy.sh` output | `AZURE_RESOURCE_GROUP` |
| VM name | infra output / `deploy.sh` output | `AZURE_VM_NAME` |
| IIS site name | infra output / `deploy.sh` output | `IIS_SITE_NAME` |

If the pipeline fails, double-check this mapping first. Most setup problems come from one of these values being copied incorrectly.

## Troubleshooting

### `azure/login` fails

Check all of the following:

- the workflow/job has `permissions: id-token: write`
- `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, and `AZURE_SUBSCRIPTION_ID` are correct
- the federated credential subject exactly matches the repo and branch
- you pushed to the same repo/branch you trusted in Azure

To inspect the federated credential:

```bash
az ad app federated-credential list --id "$APP_OBJECT_ID" -o table
```

### GitHub Release creation fails

Check all of the following:

- the workflow/job has `permissions: contents: write`
- the repository allows the workflow to create releases
- the generated tag for the run does not already exist

### VM Run Command fails with authorization errors

Verify the VM role assignment:

```bash
az role assignment list \
  --assignee-object-id "$SP_OBJECT_ID" \
  --scope "$RG_SCOPE" \
  -o table
```

Make sure `Virtual Machine Contributor` is present.

### The package uploaded, but the VM deployment script failed

Start with the Run Command output in the GitHub Actions job. If you need more detail, inspect the VM directly over RDP and review the PowerShell deployment logs on the machine.

Also confirm:

- `IIS_SITE_NAME` matches the site created by your setup script
- the VM can reach `github.com` / `api.github.com` over HTTPS
- the release asset URL points to the expected repository and asset
- the deployment token can read private release assets if the repository is private
- the app files are being copied to the IIS site's physical path

Remember that there are two separate access steps:

- the GitHub runner creates the release and uploads the asset
- the VM downloads the asset from GitHub during deployment

So even if release creation succeeds, deployment can still fail if outbound GitHub access is blocked or the VM cannot authenticate to a private release asset.

### The app still shows the old version

Common causes:

- the workflow uploaded a package but invoked Run Command against the wrong VM
- `AZURE_VM_NAME` or `AZURE_RESOURCE_GROUP` points at an older environment
- the IIS site/app pool was not restarted after file copy
- the package was extracted into the wrong folder

### VM setup script did not configure IIS correctly

- Check the VM extension status in the Azure portal
- RDP into the VM and review `C:\setup-iis.log`
- Confirm the IIS site name printed by infrastructure matches `IIS_SITE_NAME`

## Project Structure

```
deploy-to-iis-demo/
├── .github/
│   └── workflows/
│       └── deploy-to-iis.yml      # Build, GitHub Release asset publish, Azure Run Command deploy
├── infra/
│   ├── main.bicep                 # Azure VM + related resources
│   ├── deploy.sh                  # One-command infrastructure deployment
│   ├── deploy-app.ps1             # VM-side deployment script invoked by Run Command
│   ├── parameters.json            # Deployment parameters
│   └── setup-iis.ps1              # IIS and VM bootstrap script
├── src/
│   └── DeployToIisDemo/
│       ├── Pages/                 # Razor Pages
│       ├── Program.cs             # App entry + health API
│       ├── web.config             # IIS configuration
│       └── DeployToIisDemo.csproj
├── DeployToIisDemo.sln
├── global.json                    # .NET 8 SDK pin
└── README.md
```

## Future Migration to Azure PaaS

When the customer is ready to move off the VM:

1. **Azure App Service** — The most direct path. Replace the VM deployment stage with an App Service deployment stage.
2. **Azure Container Apps** — Containerize the app and move to a more cloud-native deployment model.
3. **Infrastructure changes** — Swap the VM-focused Bicep template for an App Service or Container Apps template. The application code itself should require minimal change.

## Clean Up

```bash
az group delete --name "$RESOURCE_GROUP" --yes --no-wait
```
