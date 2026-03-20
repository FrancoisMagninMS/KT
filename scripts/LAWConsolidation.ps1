# Consolidates all Azure resource diagnostic settings to a single
# Log Analytics Workspace. Removes existing diagnostic settings and
# creates a new one pointing to the central LAW.
#
# Usage: .\LAWConsolidation.ps1
# Prerequisites: Azure CLI authenticated (az login), PowerShell 5.1+

# ================================
# INPUT VARIABLES (YOUR VALUES)
# ================================

$NEW_LAW_ID = "/subscriptions/<subscriptionID>/resourceGroups/rg-monitoring-central/providers/Microsoft.OperationalInsights/workspaces/log-central-prod"
$DiagName = "send-to-central-law"

# Correct JSON (DO NOT CHANGE)
$LogsJson = '[{"categoryGroup":"allLogs","enabled":true}]'
$MetricsJson = '[{"category":"AllMetrics","enabled":true}]'

# ================================
# GET ALL RESOURCES
# ================================

Write-Host "Fetching all Azure resources..."

$Resources = az resource list -o json | ConvertFrom-Json

Write-Host "Total resources found: $($Resources.Count)"
Write-Host "------------------------------------------"

# ================================
# LOOP THROUGH EACH RESOURCE
# ================================

foreach ($res in $Resources) {

    $RES_ID   = $res.id
    $RES_NAME = $res.name
    $RES_TYPE = $res.type

    Write-Host ""
    Write-Host "Processing: $RES_NAME ($RES_TYPE)"

    # =========================================
    # STEP 1: DELETE EXISTING DIAGNOSTIC SETTINGS
    # =========================================

    try {
        $ExistingDiags = az monitor diagnostic-settings list --resource $RES_ID -o json 2>$null | ConvertFrom-Json

        if ($ExistingDiags -and $ExistingDiags.value -and $ExistingDiags.value.Count -gt 0) {

            foreach ($diag in $ExistingDiags.value) {
                Write-Host "  Removing: $($diag.name)"

                az monitor diagnostic-settings delete `
                    --name $diag.name `
                    --resource $RES_ID `
                    --output none 2>$null
            }
        }
    }
    catch {
        Write-Host "  ⚠️ Skip delete (not supported)"
    }

    # =========================================
    # STEP 2: CREATE NEW DIAGNOSTIC SETTING
    # =========================================

    try {
        az monitor diagnostic-settings create `
            --name $DiagName `
            --resource $RES_ID `
            --workspace $NEW_LAW_ID `
            --logs $LogsJson `
            --metrics $MetricsJson `
            --output none 2>$null

        if ($LASTEXITCODE -eq 0) {
            Write-Host "  ✅ Applied"
        }
        else {
            Write-Host "  ❌ Failed"
        }
    }
    catch {
        Write-Host "  ⚠️ Not supported / skipped"
    }
}

Write-Host ""
Write-Host "🎉 Completed applying diagnostic settings to all resources!"