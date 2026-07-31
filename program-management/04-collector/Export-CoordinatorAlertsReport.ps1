# System settings and variables

$Date = Get-Date -Format yyyy-MM-dd
$PageSize = 100
$ThrottleMs = 400

# "servit" is ServIT's own internal master account, not a real client - the alert history
# endpoint 403s on it (confirmed live), so skip it outright rather than let it warn every run.
$ExcludedTenants = @("servit")


$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

$OutputRoot = Join-Path $PSScriptRoot "..\ait-networking\data\output"
if (-not (Test-Path -LiteralPath $OutputRoot)) { New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null }
$FlaggedPath = Join-Path $OutputRoot "CollectorAlerts_Flagged_$Timestamp.csv"
$AllAlertsPath = Join-Path $OutputRoot "AllUndismissedAlerts_Raw_$Timestamp.csv"

$FlaggedResults = [System.Collections.Generic.List[object]]::new()
$AllResults = [System.Collections.Generic.List[object]]::new()

# Derived settings and variables

#$BasePath = "C:\PS\$Directory"
#$LogFile = Join-Path $BasePath "Logs\EntraGroupMemberAudit-Admins.csv"

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

# Import functions

. "..\..\scripts\Functions-VA-Common.ps1"
. "..\..\scripts\Functions-Auvik-Common.ps1"

# Start processing

$StartTime = Get-Date

# Import settings and set API context

$Settings = Import-Settings -SettingsPath "..\..\data\reference\AuvikSettings.txt"
$AuvikApiContext = Set-AuvikApiContext -Settings $Settings

# ---------------------------------------------------------------------------
# Step 1: Get all tenants
# ---------------------------------------------------------------------------
 
Write-Host "Fetching tenant list..." -ForegroundColor Cyan
$Uri = "$($AuvikApiContext.BaseUri)/tenants?page[first]=$PageSize"
$Tenants = Get-AllAuvikResults -InitialUri $Uri -Headers $AuvikApiContext.Headers
 
if (-not $Tenants -or $Tenants.Count -eq 0) {
    Write-Error "No tenants returned. Check credentials, region, and API access scope."
    return
}
 
Write-Host "Found $($Tenants.Count) tenant(s)." -ForegroundColor Green
 
# ---------------------------------------------------------------------------
# Step 2: Loop tenants, pull undismissed alerts
# ---------------------------------------------------------------------------
 
$tenantIndex = 0
foreach ($tenant in $tenants) {
    $tenantIndex++
    $tenantName = $tenant.attributes.domainPrefix
    $tenantId   = $tenant.id
    if (-not $tenantName) { $tenantName = $tenant.attributes.name }
    if (-not $tenantName) { $tenantName = $tenantId }

    if ($ExcludedTenants -contains $tenantName) {
        Write-Host "[$tenantIndex/$($tenants.Count)] Skipping tenant: $tenantName (excluded)" -ForegroundColor DarkGray
        continue
    }

    Write-Host "[$tenantIndex/$($tenants.Count)] Checking tenant: $tenantName" -ForegroundColor Yellow
 
    # Pull undismissed, unresolved alerts for this tenant
    # CONFIRMED via live curl test: the correct path is /alert/history/info
    # (not /alertHistory/info or /alert/info as third-party docs suggested).
    $alertsUri = "$($AuvikApiContext.BaseUri)/alert/history/info?tenants=$tenantId&filter[dismissed]=false&filter[status]=created&page[first]=$PageSize"
    $alerts = Get-AllAuvikResults -InitialUri $alertsUri -Headers $AuvikApiContext.Headers
 
    if (-not $alerts -or $alerts.Count -eq 0) {
        Write-Host "    No open alerts." -ForegroundColor DarkGray
        continue
    }
 
    foreach ($alert in $alerts) {
        # Confirmed field names from a live response against /alert/history/info:
        # name, description, severity, status, dismissed, dispatched, detectedOn
        $alertName    = $alert.attributes.name
        $alertDesc    = $alert.attributes.description
        $severity     = $alert.attributes.severity
        $detectedTime = $alert.attributes.detectedOn
 
        # Entity relationship doesn't include a friendly name by default (no
        # "include" param requested), so we capture type + id for reference.
        $entityType = $alert.relationships.entity.data.type
        $entityId   = $alert.relationships.entity.data.id
        $entityRef  = if ($entityType) { "$entityType`:$entityId" } else { "" }
 
        $record = [pscustomobject]@{
            Tenant       = $tenantName
            TenantId     = $tenantId
            AlertId      = $alert.id
            AlertName    = $alertName
            Description  = $alertDesc
            Entity       = $entityRef
            Severity     = $severity
            DetectedTime = $detectedTime
        }
        $AllResults.Add($record)
 
        # Keyword match against name + description
        $haystack = "$alertName $alertDesc".ToLower()
        $isCollectorAlert = $false
        foreach ($kw in $CollectorKeywords) {
            if ($haystack -like "*$($kw.ToLower())*") { $isCollectorAlert = $true; break }
        }
 
        if ($isCollectorAlert) {
            Write-Host "    FLAGGED: $alertName (Entity: $entityName, Severity: $severity)" -ForegroundColor Red
            $FlaggedResults.Add($record)
        }
    }
}
 
# ---------------------------------------------------------------------------
# Step 3: Write reports
# ---------------------------------------------------------------------------
 
$AllResults | Export-Csv -Path $AllAlertsPath -NoTypeInformation
$FlaggedResults | Export-Csv -Path $FlaggedPath -NoTypeInformation
 
Write-Host "`nDone." -ForegroundColor Cyan
Write-Host "Total undismissed alerts across all tenants: $($AllResults.Count)" -ForegroundColor Cyan
Write-Host "Flagged as collector-related: $($FlaggedResults.Count)" -ForegroundColor Cyan
Write-Host "Raw output:      $AllAlertsPath" -ForegroundColor Cyan
Write-Host "Flagged output:  $FlaggedPath" -ForegroundColor Cyan
 
if ($FlaggedResults.Count -eq 0 -and $AllResults.Count -gt 0) {
    Write-Host "`nNo alerts matched the collector keyword filter, but $($AllResults.Count) open alerts exist." -ForegroundColor Yellow
    Write-Host "Open the raw CSV and check actual AlertName values for collector-related alerts," -ForegroundColor Yellow
    Write-Host "then adjust -CollectorKeywords accordingly and re-run." -ForegroundColor Yellow
}