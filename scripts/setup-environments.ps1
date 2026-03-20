<#
.SYNOPSIS
    Creates GitHub Environments (DEV, TEST, QA, PROD) with appropriate protection rules.

.DESCRIPTION
    Sets up four GitHub Environments for the multi-stage DevSecOps pipeline:
      - DEV:  No approval required (auto-deploy on push)
      - TEST: No approval required (auto-deploy after DEV)
      - QA:   Requires human approval before deployment
      - PROD: Requires human approval before deployment

    Prerequisites:
      - GitHub CLI (gh) must be installed and authenticated
      - You must have admin access to the repository

.NOTES
    This script uses the GitHub CLI and REST API to configure environments.
    Protection rules (required reviewers) must be configured in Settings > Environments
    because the GitHub CLI does not support setting reviewers directly.
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$Owner,

    [Parameter(Mandatory = $false)]
    [string]$Repo
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Verify gh CLI is available
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Write-Error "GitHub CLI (gh) is not installed. Install from https://cli.github.com/"
    exit 1
}

# Detect repo if not provided
if (-not $Owner -or -not $Repo) {
    $repoInfo = gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $repoInfo) {
        Write-Error "Could not detect repository. Provide -Owner and -Repo parameters, or run from within the repo directory."
        exit 1
    }
    $parts = $repoInfo -split '/'
    $Owner = $parts[0]
    $Repo = $parts[1]
}

Write-Host "Repository: $Owner/$Repo" -ForegroundColor Cyan
Write-Host ""

# Define environments
$environments = @(
    @{
        Name      = "DEV"
        Reviewers = $false
    },
    @{
        Name      = "TEST"
        Reviewers = $false
    },
    @{
        Name      = "QA"
        Reviewers = $true
    },
    @{
        Name      = "PROD"
        Reviewers = $true
    }
)

foreach ($env in $environments) {
    Write-Host "Creating environment: $($env.Name)..." -ForegroundColor Yellow

    # Create or update the environment via GitHub REST API
    $body = @{}

    $bodyJson = $body | ConvertTo-Json -Compress
    $bodyJson | gh api --method PUT "repos/$Owner/$Repo/environments/$($env.Name)" --input - 2>$null

    if ($LASTEXITCODE -eq 0) {
        Write-Host "  [OK] Environment '$($env.Name)' created/updated" -ForegroundColor Green
    }
    else {
        # Retry with minimal body
        gh api --method PUT "repos/$Owner/$Repo/environments/$($env.Name)" 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  [OK] Environment '$($env.Name)' created" -ForegroundColor Green
        }
        else {
            Write-Host "  [FAIL] Failed to create environment '$($env.Name)'" -ForegroundColor Red
        }
    }

    if ($env.Reviewers) {
        Write-Host "  [ACTION] Add required reviewers for '$($env.Name)' in GitHub:" -ForegroundColor Magenta
        Write-Host "    Settings > Environments > $($env.Name) > Required reviewers" -ForegroundColor Magenta
    }

    Write-Host ""
}

Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "Environment setup complete!" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Configure required reviewers for QA and PROD environments" -ForegroundColor White
Write-Host "     https://github.com/$Owner/$Repo/settings/environments" -ForegroundColor White
Write-Host ""
Write-Host "  2. Add environment-scoped secrets to each environment:" -ForegroundColor White
Write-Host "     - AZURE_CLIENT_ID" -ForegroundColor Gray
Write-Host "     - AZURE_SUBSCRIPTION_ID" -ForegroundColor Gray
Write-Host "     - AZURE_TENANT_ID" -ForegroundColor Gray
Write-Host "     - PG_ADMIN_PASSWORD" -ForegroundColor Gray
Write-Host ""
Write-Host "  3. Add environment-scoped variables to each environment:" -ForegroundColor White
Write-Host "     - ALERT_EMAIL" -ForegroundColor Gray
Write-Host ""
Write-Host "  4. Configure OIDC federated credentials for each environment" -ForegroundColor White
Write-Host "     Run: .\scripts\setup-oidc.ps1 for each environment" -ForegroundColor Gray
Write-Host "======================================================" -ForegroundColor Cyan
