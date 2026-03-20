# Retrieves the resource ID of a Log Analytics Workspace.
# Usage: .\get-LAW-ID.ps1 -ResourceGroup <rg-name> -WorkspaceName <law-name>
# Prerequisites: Azure CLI authenticated (az login)

param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [Parameter(Mandatory)][string]$WorkspaceName
)

$LAW_ID = az monitor log-analytics workspace show `
    -g $ResourceGroup `
    -n $WorkspaceName `
    --query id -o tsv

if ($LASTEXITCODE -ne 0 -or -not $LAW_ID) {
    Write-Host "Failed to retrieve LAW ID. Check the resource group and workspace name." -ForegroundColor Red
    exit 1
}

Write-Output $LAW_ID
