# Creates an Azure Service Principal for GitHub Actions deployment
# and outputs the values needed for GitHub repository secrets.

$ErrorActionPreference = "Stop"

# Ensure Azure CLI is available
$az = Get-Command az -ErrorAction SilentlyContinue |
      Select-Object -ExpandProperty Source
if (-not $az) {
    # Check common install locations
    $candidates = @(
        "C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd",
        "C:\Program Files (x86)\Microsoft SDKs\Azure\CLI2\wbin\az.cmd"
    )
    foreach ($p in $candidates) { if (Test-Path $p) { $az = $p; break } }
}
if (-not $az) {
    Write-Host "`nAzure CLI not found. Installing..." -ForegroundColor Cyan
    winget install --id Microsoft.AzureCLI --accept-source-agreements --accept-package-agreements
    # Refresh PATH after install
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path","User")
    $az = Get-Command az -ErrorAction SilentlyContinue |
          Select-Object -ExpandProperty Source
    if (-not $az) {
        Write-Host "Azure CLI installation failed. Please install manually: https://aka.ms/installazurecliwindows" -ForegroundColor Red
        exit 1
    }
}
Write-Host "Using Azure CLI: $az" -ForegroundColor Gray

# Login to Azure
Write-Host "`nLogging in to Azure..." -ForegroundColor Cyan
& $az login --output none

# List subscriptions and let user select
Write-Host "`nAvailable subscriptions:" -ForegroundColor Cyan
$subs = & $az account list --query "[].{Name:name, Id:id, State:state}" --output json | ConvertFrom-Json

for ($i = 0; $i -lt $subs.Count; $i++) {
    Write-Host "  [$i] $($subs[$i].Name) ($($subs[$i].Id)) - $($subs[$i].State)"
}

$selection = Read-Host "`nSelect subscription number"
$subscriptionId = $subs[$selection].Id
$subscriptionName = $subs[$selection].Name

Write-Host "`nUsing subscription: $subscriptionName ($subscriptionId)" -ForegroundColor Green
& $az account set --subscription $subscriptionId

# Create the service principal with Contributor role scoped to the subscription
# Use 30-day credential lifetime to comply with Azure AD policies
$endDate = (Get-Date).AddDays(30).ToString("yyyy-MM-dd")
Write-Host "`nCreating service principal 'sp-kt-github' (credential expires $endDate)..." -ForegroundColor Cyan

# Step 1: Try create-for-rbac with short lifetime
$spJson = & $az ad sp create-for-rbac `
    --name "sp-kt-github" `
    --role Contributor `
    --scopes "/subscriptions/$subscriptionId" `
    --output json 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Host "Default credential lifetime rejected by policy, using 30-day lifetime..." -ForegroundColor Yellow

    # Ensure app registration exists (may already exist from a failed attempt)
    $app = & $az ad app list --display-name "sp-kt-github" --query "[0].appId" -o tsv
    if (-not $app) {
        $app = (& $az ad app create --display-name "sp-kt-github" --output json | ConvertFrom-Json).appId
    }

    # Ensure service principal exists
    $spExists = & $az ad sp list --filter "appId eq '$app'" --query "[0].appId" -o tsv
    if (-not $spExists) {
        & $az ad sp create --id $app --output none
    }

    # Reset credentials with short lifetime
    $cred = & $az ad app credential reset --id $app --end-date $endDate --output json | ConvertFrom-Json

    # Ensure Contributor role assignment
    & $az role assignment create `
        --assignee $app `
        --role Contributor `
        --scope "/subscriptions/$subscriptionId" `
        --output none 2>$null

    $sp = [PSCustomObject]@{
        appId    = $cred.appId
        password = $cred.password
        tenant   = $cred.tenant
    }
} else {
    $sp = $spJson | ConvertFrom-Json
}

# Display the values to configure in GitHub
Write-Host "`n==============================================" -ForegroundColor Yellow
Write-Host " GitHub Repository Secrets" -ForegroundColor Yellow
Write-Host "==============================================" -ForegroundColor Yellow
Write-Host " Go to: Settings > Secrets and variables > Actions > New repository secret" -ForegroundColor Gray
Write-Host ""
Write-Host "  AZURE_CLIENT_ID       = $($sp.appId)"
Write-Host "  AZURE_CLIENT_SECRET   = $($sp.password)"
Write-Host "  AZURE_SUBSCRIPTION_ID = $subscriptionId"
Write-Host "  AZURE_TENANT_ID       = $($sp.tenant)"
Write-Host "  PG_ADMIN_PASSWORD     = <choose a strong password>"
Write-Host ""
Write-Host "==============================================" -ForegroundColor Yellow
Write-Host " GitHub Repository Variables" -ForegroundColor Yellow
Write-Host "==============================================" -ForegroundColor Yellow
Write-Host " Go to: Settings > Secrets and variables > Actions > Variables tab > New repository variable" -ForegroundColor Gray
Write-Host ""
Write-Host "  ALERT_EMAIL           = <your email for alerts>"
Write-Host ""
Write-Host "Done!" -ForegroundColor Green
