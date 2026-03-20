<#
.SYNOPSIS
    Sets up OIDC Workload Identity Federation for GitHub Actions to Azure Entra ID.

.DESCRIPTION
    Creates federated credentials on an existing Azure AD App Registration
    to enable GitHub Actions OIDC-based authentication (no client secrets).

    After running this script, the pipeline uses azure/login@v2 with
    client-id, tenant-id, and subscription-id instead of a creds JSON
    containing a client secret.

.PARAMETER AppId
    The Application (Client) ID of the Azure AD App Registration.

.PARAMETER GitHubOrg
    The GitHub organization or username that owns the repository.

.PARAMETER GitHubRepo
    The GitHub repository name.

.PARAMETER Environments
    The GitHub Environments to create federated credentials for.
    Defaults to @("DEV").

.EXAMPLE
    .\setup-oidc.ps1 -AppId "00000000-0000-0000-0000-000000000000" -GitHubOrg "FrancoisMagninMS" -GitHubRepo "KT"

.EXAMPLE
    .\setup-oidc.ps1 -AppId "00000000-0000-0000-0000-000000000000" -GitHubOrg "FrancoisMagninMS" -GitHubRepo "KT" -Environments @("DEV","UAT","PROD")
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$AppId,

    [Parameter(Mandatory = $true)]
    [string]$GitHubOrg,

    [Parameter(Mandatory = $true)]
    [string]$GitHubRepo,

    [Parameter(Mandatory = $false)]
    [string[]]$Environments = @("DEV")
)

$ErrorActionPreference = "Stop"

# Verify Azure CLI is authenticated
$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Error "Azure CLI is not authenticated. Run 'az login' first."
    exit 1
}
Write-Host "Azure CLI authenticated as: $($account.user.name)" -ForegroundColor Cyan

# Get the Object ID of the app registration
$AppObjectId = az ad app show --id $AppId --query id -o tsv
if (-not $AppObjectId) {
    Write-Error "App registration with Client ID '$AppId' not found."
    exit 1
}
Write-Host "App Registration: $AppId (Object ID: $AppObjectId)" -ForegroundColor Cyan

# Create federated credentials for each environment
foreach ($env in $Environments) {
    $credName = "github-$($GitHubRepo.ToLower())-$($env.ToLower())"
    $subject = "repo:${GitHubOrg}/${GitHubRepo}:environment:${env}"

    Write-Host "`nCreating federated credential for environment '$env'..." -ForegroundColor Yellow
    Write-Host "  Subject: $subject"
    Write-Host "  Credential Name: $credName"

    # Check if credential already exists
    $existing = az ad app federated-credential list --id $AppObjectId --query "[?name=='$credName'].name" -o tsv 2>$null
    if ($existing) {
        Write-Host "  Federated credential '$credName' already exists - skipping." -ForegroundColor DarkYellow
        continue
    }

    $body = @{
        name        = $credName
        issuer      = "https://token.actions.githubusercontent.com"
        subject     = $subject
        audiences   = @("api://AzureADTokenExchange")
        description = "GitHub Actions OIDC for $GitHubOrg/$GitHubRepo environment $env"
    } | ConvertTo-Json -Compress

    az ad app federated-credential create --id $AppObjectId --parameters $body
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Created successfully." -ForegroundColor Green
    }
    else {
        Write-Error "  Failed to create federated credential for environment '$env'."
    }
}

Write-Host "`n--- Summary ---" -ForegroundColor Cyan
Write-Host "OIDC federated credentials configured for:"
foreach ($env in $Environments) {
    Write-Host "  - Environment: $env -> repo:${GitHubOrg}/${GitHubRepo}:environment:${env}"
}

Write-Host "`nNext steps:" -ForegroundColor Yellow
Write-Host "  1. Remove the AZURE_CLIENT_SECRET secret from GitHub Environments (no longer needed)."
Write-Host "  2. The deploy.yml workflow uses OIDC (client-id, tenant-id, subscription-id)."
Write-Host "  3. Verify by running a 'plan' action in the workflow."
Write-Host "  4. Optionally delete the client secret from the App Registration in Entra ID."
