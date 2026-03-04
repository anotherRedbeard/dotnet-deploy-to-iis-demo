#!/usr/bin/env bash
set -euo pipefail

# Deploy or destroy the IIS Demo infrastructure on Azure
# Usage: ./infra/deploy.sh [-g resource-group] [-l location] [-p name-prefix] [-u admin-username] [--destroy]

RESOURCE_GROUP="rg-iis-demo"
LOCATION="eastus2"
NAME_PREFIX="iisdemo"
ADMIN_USERNAME="azureadmin"
DESTROY=false

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

# Parse long options first
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

# Check for Azure CLI
if ! command -v az &> /dev/null; then
  echo "Error: Azure CLI (az) is not installed. Install it from https://aka.ms/install-azure-cli"
  exit 1
fi

# Check login status
if ! az account show &> /dev/null; then
  echo "Not logged in to Azure. Running 'az login'..."
  az login
fi

echo "Subscription: $(az account show --query '{name:name, id:id}' -o tsv)"
echo ""

# --- Destroy mode ---
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

# --- Deploy mode ---

# Prompt for the VM admin password
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

# Create resource group
echo ""
echo "Creating resource group '$RESOURCE_GROUP' in '$LOCATION'..."
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none

# Deploy Bicep template
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

# Extract outputs
VM_PUBLIC_IP=$(echo "$DEPLOYMENT_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['vmPublicIp']['value'])" 2>/dev/null || echo "unknown")
VM_FQDN=$(echo "$DEPLOYMENT_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['vmFqdn']['value'])" 2>/dev/null || echo "unknown")
WEBDEPLOY_URL=$(echo "$DEPLOYMENT_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['webDeployUrl']['value'])" 2>/dev/null || echo "unknown")

echo ""
echo "=== Deployment Complete ==="
echo ""
echo "  VM Public IP:    $VM_PUBLIC_IP"
echo "  VM FQDN:         $VM_FQDN"
echo "  Web Deploy URL:  $WEBDEPLOY_URL"
echo ""
echo "=== Next Steps ==="
echo ""
echo "1. Wait ~5 minutes for the VM setup script to finish installing IIS + Web Deploy."
echo "   You can check progress by RDP'ing in and viewing C:\\setup-iis.log"
echo ""
echo "2. Add these GitHub Secrets to your repository:"
echo "   WEBDEPLOY_URL      = $WEBDEPLOY_URL"
echo "   WEBDEPLOY_USERNAME = $ADMIN_USERNAME"
echo "   WEBDEPLOY_PASSWORD = <the password you just entered>"
echo ""
echo "3. Push your code to the 'main' branch to trigger the deployment workflow."
echo ""
echo "4. Test the app:"
echo "   Browser:  http://$VM_PUBLIC_IP/"
echo "   Health:   http://$VM_PUBLIC_IP/api/health"
echo ""
echo "=== Clean Up (when done) ==="
echo "   ./infra/deploy.sh --destroy -g $RESOURCE_GROUP"
