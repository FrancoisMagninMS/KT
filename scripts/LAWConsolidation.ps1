# Consolidates all Azure resource diagnostic settings to a single
# Log Analytics Workspace. Removes existing diagnostic settings and
# creates a new one pointing to the central LAW.
#
# Usage: .\LAWConsolidation.ps1
# Prerequisites: Azure CLI authenticated (az login), PowerShell 5.1+

# Destination Log Analytics Workspace (NEW)
$NEW_LAW_ID = "/subscriptions/<subscriptionID>/resourceGroups/rg-monitoring-central/providers/Microsoft.OperationalInsights/workspaces/log-central-prod"
$DiagName = "send-to-central-law"

Write-Host "Fetching all resources..."
$Resources = az resource list --query "[].id" -o tsv

foreach ($RES in $Resources) {
    Write-Host "========================================"
    Write-Host "Resource: $RES"

    # Check if diagnostics supported
    $CategoriesJson = az monitor diagnostic-settings categories list `
        --resource $RES `
        -o json 2>$null

    if (-not $CategoriesJson) {
        Write-Host "Diagnostics not supported. Skipping."
        continue
    }

    $Categories = $CategoriesJson | ConvertFrom-Json
    if (-not $Categories -or $Categories.value.Count -eq 0) {
        Write-Host "Diagnostics not supported. Skipping."
        continue
    }

    # STEP 1: Delete ALL existing diagnostic settings
    $ExistingDiagsJson = az monitor diagnostic-settings list `
        --resource $RES `
        -o json 2>$null

    if ($ExistingDiagsJson) {
        $ExistingDiags = $ExistingDiagsJson | ConvertFrom-Json
        if ($ExistingDiags -and $ExistingDiags.value.Count -gt 0) {
            foreach ($diag in $ExistingDiags.value) {
                Write-Host "  Removing existing diagnostic setting: $($diag.name)"
                az monitor diagnostic-settings delete `
                    --name $diag.name `
                    --resource $RES `
                    --output none 2>$null
            }
        } else {
            Write-Host "No existing diagnostic settings found."
        }
    } else {
        Write-Host "No existing diagnostic settings found."
    }

    # STEP 2: Create ONLY ONE diagnostic setting pointing to NEW LAW
    $LogsJson = '[{\"categoryGroup\":\"allLogs\",\"enabled\":true}]'
    $MetricsJson = '[{\"category\":\"AllMetrics\",\"enabled\":true}]'

    try {
        az monitor diagnostic-settings create `
            --name $DiagName `
            --resource $RES `
            --workspace $NEW_LAW_ID `
            --logs $LogsJson `
            --metrics $MetricsJson `
            --output none 2>$null

        if ($LASTEXITCODE -eq 0) {
            Write-Host "Applied single diagnostic setting to NEW LAW"
        } else {
            Write-Host "Failed to apply diagnostic setting"
        }
    }
    catch {
        Write-Host "Error applying diagnostic setting: $_"
    }
}