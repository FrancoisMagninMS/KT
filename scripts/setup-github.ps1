# Configures the GitHub repository with the required environment, secrets,
# and variables needed to run the Deploy KT Infrastructure workflow.
# Prerequisites: GitHub CLI (gh) must be installed and authenticated.

$ErrorActionPreference = "Stop"

$repo = "FrancoisMagninMS/KT"
$environment = "DEV"

# ── Verify gh CLI ────────────────────────────────────────────
$gh = Get-Command gh -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
if (-not $gh) {
    Write-Host "GitHub CLI (gh) is not installed. Install it from https://cli.github.com" -ForegroundColor Red
    exit 1
}

$authStatus = gh auth status 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "GitHub CLI is not authenticated. Run: gh auth login" -ForegroundColor Red
    exit 1
}

Write-Host "Configuring GitHub repo: $repo (environment: $environment)" -ForegroundColor Cyan
Write-Host ""

# ── Ensure environment exists ────────────────────────────────
Write-Host "Ensuring environment '$environment' exists..." -ForegroundColor Cyan
gh api "repos/$repo/environments/$environment" --method PUT --silent 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Failed to create environment. Check your permissions on $repo" -ForegroundColor Red
    exit 1
}
Write-Host "  Environment '$environment' is ready." -ForegroundColor Green

# ── Helper functions ─────────────────────────────────────────
function Set-GitHubSecret {
    param([string]$Name, [string]$Prompt)
    $value = Read-Host -Prompt "  Enter value for secret $Name ($Prompt)"
    if ([string]::IsNullOrWhiteSpace($value)) {
        Write-Host "    SKIPPED (empty value)" -ForegroundColor Yellow
        return $false
    }
    $value | gh secret set $Name --repo $repo --env $environment
    Write-Host "    SET" -ForegroundColor Green
    return $true
}

function Set-GitHubVariable {
    param([string]$Name, [string]$Default, [string]$Prompt)
    $displayDefault = if ($Default) { " [default: $Default]" } else { "" }
    $value = Read-Host -Prompt "  Enter value for variable $Name ($Prompt)$displayDefault"
    if ([string]::IsNullOrWhiteSpace($value) -and $Default) {
        $value = $Default
        Write-Host "    Using default: $Default" -ForegroundColor Gray
    }
    if ([string]::IsNullOrWhiteSpace($value)) {
        Write-Host "    SKIPPED (empty value)" -ForegroundColor Yellow
        return $false
    }
    gh variable set $Name --repo $repo --env $environment --body $value
    Write-Host "    SET" -ForegroundColor Green
    return $true
}

# ── Secrets ──────────────────────────────────────────────────
Write-Host "`nConfiguring secrets..." -ForegroundColor Cyan

$secrets = @(
    @{ Name = "AZURE_CLIENT_ID";       Prompt = "Service principal app/client ID" },
    @{ Name = "AZURE_SUBSCRIPTION_ID"; Prompt = "Azure subscription ID" },
    @{ Name = "AZURE_TENANT_ID";       Prompt = "Azure AD tenant ID" },
    @{ Name = "PG_ADMIN_PASSWORD";     Prompt = "PostgreSQL admin password (min 8 chars, mixed case/numbers/symbols)" }
)

# Note: AZURE_CLIENT_SECRET is NOT needed — the pipeline uses OIDC federation.
# Run scripts/setup-oidc.ps1 to configure federated credentials on the App Registration.

$missingSecrets = @()
foreach ($s in $secrets) {
    $result = Set-GitHubSecret -Name $s.Name -Prompt $s.Prompt
    if (-not $result) { $missingSecrets += $s.Name }
}

# ── Variables ────────────────────────────────────────────────
Write-Host "`nConfiguring variables..." -ForegroundColor Cyan

$variables = @(
    @{ Name = "ALERT_EMAIL"; Default = ""; Prompt = "Email address for Azure Monitor alerts" }
)

$missingVars = @()
foreach ($v in $variables) {
    $result = Set-GitHubVariable -Name $v.Name -Default $v.Default -Prompt $v.Prompt
    if (-not $result) { $missingVars += $v.Name }
}

# ── Summary ──────────────────────────────────────────────────
Write-Host "`n==============================================" -ForegroundColor Yellow
Write-Host " Configuration Summary" -ForegroundColor Yellow
Write-Host "==============================================" -ForegroundColor Yellow
Write-Host "  Repository:  $repo"
Write-Host "  Environment: $environment"

if ($missingSecrets.Count -gt 0 -or $missingVars.Count -gt 0) {
    Write-Host "`n  Missing configuration:" -ForegroundColor Red
    foreach ($m in $missingSecrets) { Write-Host "    Secret:   $m" -ForegroundColor Red }
    foreach ($m in $missingVars)    { Write-Host "    Variable: $m" -ForegroundColor Red }
    Write-Host "`n  Re-run this script to set the missing values." -ForegroundColor Yellow
} else {
    Write-Host "`n  All secrets and variables are configured!" -ForegroundColor Green
    Write-Host "  You can now run the workflow from:"
    Write-Host "  https://github.com/$repo/actions/workflows/deploy.yml" -ForegroundColor Cyan
}
