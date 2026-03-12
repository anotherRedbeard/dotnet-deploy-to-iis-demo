#!/usr/bin/env bash
set -euo pipefail

# Deploy or destroy the IIS Demo infrastructure on Azure
# Usage: ./infra/deploy.sh [-g resource-group] [-l location] [-p name-prefix] [-u admin-username] [--destroy]

RESOURCE_GROUP="rg-iis-demo"
LOCATION="eastus2"
NAME_PREFIX="iisdemo"
ADMIN_USERNAME="azureadmin"
DESTROY=false
DEPLOYMENT_CONTAINER="deployments"

usage() {
  echo "Usage: $0 [-g resource-group] [-l location] [-p name-prefix] [-u admin-username] [--destroy]"
  echo ""
  echo "Options:"
  echo "  -g         Resource group name (default: $RESOURCE_GROUP)"
  echo "  -l         Azure region (default: $LOCATION)"
  echo "  -p         Name prefix for resources (default: $NAME_PREFIX)"
  echo "  -u         VM admin username (default: $ADMIN_USERNAME)"
  echo "  --destroy  Tear down the resource group and all resources"
  echo "  -h         Show this help"
  exit 0
}

for arg in "$@"; do
  case $arg in
    --destroy) DESTROY=true; shift ;;
  esac
done

while getopts "g:l:p:u:h" opt; do
  case $opt in
    g) RESOURCE_GROUP="$OPTARG" ;;
    l) LOCATION="$OPTARG" ;;
    p) NAME_PREFIX="$OPTARG" ;;
    u) ADMIN_USERNAME="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Deploy to IIS Demo - Infrastructure Setup ==="
echo ""
echo "  Resource Group:  $RESOURCE_GROUP"
echo "  Location:        $LOCATION"
echo "  Name Prefix:     $NAME_PREFIX"
echo "  Admin Username:  $ADMIN_USERNAME"
echo ""

if ! command -v az &> /dev/null; then
  echo "Error: Azure CLI (az) is not installed. Install it from https://aka.ms/install-azure-cli"
  exit 1
fi

if ! az account show &> /dev/null; then
  echo "Not logged in to Azure. Running 'az login'..."
  az login
fi

echo "Subscription: $(az account show --query '{name:name, id:id}' -o tsv)"
echo ""

if [ "$DESTROY" = true ]; then
  echo "=== Destroying Infrastructure ==="
  echo ""
  echo "  Resource Group: $RESOURCE_GROUP"
  echo ""
  read -p "Are you sure you want to delete '$RESOURCE_GROUP' and ALL its resources? [y/N]: " CONFIRM
  if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Deleting resource group '$RESOURCE_GROUP'..."
    az group delete --name "$RESOURCE_GROUP" --yes --output none
    echo "Resource group '$RESOURCE_GROUP' deleted."
  else
    echo "Aborted."
  fi
  exit 0
fi

read -s -p "Enter VM admin password (min 12 chars, must include upper, lower, digit, special): " ADMIN_PASSWORD
echo ""
read -s -p "Confirm password: " ADMIN_PASSWORD_CONFIRM
echo ""

if [ "$ADMIN_PASSWORD" != "$ADMIN_PASSWORD_CONFIRM" ]; then
  echo "Error: Passwords do not match."
  exit 1
fi

if [ ${#ADMIN_PASSWORD} -lt 12 ]; then
  echo "Error: Password must be at least 12 characters."
  exit 1
fi

echo ""
echo "Creating resource group '$RESOURCE_GROUP' in '$LOCATION'..."
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none

echo "Deploying infrastructure (this may take 5-10 minutes)..."
DEPLOYMENT_OUTPUT=$(az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file "$SCRIPT_DIR/main.bicep" \
  --parameters \
    adminUsername="$ADMIN_USERNAME" \
    adminPassword="$ADMIN_PASSWORD" \
    location="$LOCATION" \
    vmSize="Standard_B2s" \
    namePrefix="$NAME_PREFIX" \
  --query 'properties.outputs' \
  --output json)

VM_PUBLIC_IP=$(echo "$DEPLOYMENT_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['vmPublicIp']['value'])" 2>/dev/null || echo "unknown")
VM_FQDN=$(echo "$DEPLOYMENT_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['vmFqdn']['value'])" 2>/dev/null || echo "unknown")
VM_NAME=$(echo "$DEPLOYMENT_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['vmName']['value'])" 2>/dev/null || echo "${NAME_PREFIX}-vm")
STORAGE_ACCOUNT_NAME=$(echo "$DEPLOYMENT_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['storageAccountName']['value'])" 2>/dev/null || echo "unknown")
DEPLOYMENT_CONTAINER=$(echo "$DEPLOYMENT_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['storageContainerName']['value'])" 2>/dev/null || echo "$DEPLOYMENT_CONTAINER")
SITE_NAME=$(echo "$DEPLOYMENT_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['siteName']['value'])" 2>/dev/null || echo "DeployToIisDemo")

echo ""
echo "VM deployed. Now configuring IIS (this may take 5-10 minutes)..."
if ! az vm run-command invoke \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --command-id RunPowerShellScript \
  --scripts @"$SCRIPT_DIR/setup-iis.ps1" \
  --query 'value[0].message' -o tsv; then
  echo ""
  echo "Error: VM setup script failed. RDP into the VM and check C:\\setup-iis.log for details."
  exit 1
fi

echo ""
echo "=== Deployment Complete ==="
echo ""
echo "  VM Public IP:      $VM_PUBLIC_IP"
echo "  VM FQDN:           $VM_FQDN"
echo "  VM Name:           $VM_NAME"
echo "  Storage Account:   $STORAGE_ACCOUNT_NAME"
echo "  Blob Container:    $DEPLOYMENT_CONTAINER"
echo ""
echo "=== Next Steps ==="
echo ""
echo "1. Create or update an Azure AD app/service principal for GitHub Actions OIDC."
echo "   Grant it permissions to run VM commands and manage deployment blobs in this resource group."
echo ""
echo "2. Add these GitHub repository secrets for azure/login@v2:"
echo "   AZURE_CLIENT_ID       = <app registration client ID>"
echo "   AZURE_TENANT_ID       = <tenant ID>"
echo "   AZURE_SUBSCRIPTION_ID = $(az account show --query id -o tsv)"
echo ""
echo "3. Add these GitHub repository variables for the workflow:"
echo "   AZURE_RESOURCE_GROUP  = $RESOURCE_GROUP"
echo "   AZURE_VM_NAME         = $VM_NAME"
echo "   AZURE_STORAGE_ACCOUNT = $STORAGE_ACCOUNT_NAME"
echo "   AZURE_STORAGE_CONTAINER = $DEPLOYMENT_CONTAINER"
echo "   IIS_SITE_NAME         = $SITE_NAME"
echo ""
echo "4. Configure a federated credential on the Azure AD app for this repository/branch."
echo "   The workflow will upload deployment packages to '$DEPLOYMENT_CONTAINER' and deploy via Azure VM Run Command."
echo ""
echo "5. Push your code to the 'main' branch to trigger the deployment workflow."
echo ""
echo "6. Test the app:"
echo "   Browser:  http://$VM_PUBLIC_IP/"
echo "   Health:   http://$VM_PUBLIC_IP/api/health"
echo ""
echo "=== Clean Up (when done) ==="
echo "   ./infra/deploy.sh --destroy -g $RESOURCE_GROUP"
