# Creates a central Log Analytics Workspace for diagnostic consolidation.
# Usage: .\create-LAW.ps1
# Prerequisites: Azure CLI authenticated (az login)

$NEW_LAW_RG = "rg-monitoring-central"
$NEW_LAW_NAME = "log-central-prod"
$LOCATION = "koreacentral"

# Create Resource Group
Write-Host "Creating resource group '$NEW_LAW_RG'..." -ForegroundColor Cyan
az group create --name $NEW_LAW_RG --location $LOCATION --output none

if ($LASTEXITCODE -ne 0) {
    Write-Host "Failed to create resource group." -ForegroundColor Red
    exit 1
}

# Create Log Analytics Workspace
Write-Host "Creating Log Analytics Workspace '$NEW_LAW_NAME'..." -ForegroundColor Cyan
az monitor log-analytics workspace create `
    --resource-group $NEW_LAW_RG `
    --workspace-name $NEW_LAW_NAME `
    --location $LOCATION `
    --output table

if ($LASTEXITCODE -ne 0) {
    Write-Host "Failed to create Log Analytics Workspace." -ForegroundColor Red
    exit 1
}

Write-Host "Done!" -ForegroundColor Green
