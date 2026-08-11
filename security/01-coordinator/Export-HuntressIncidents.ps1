<#
.SYNOPSIS


.DESCRIPTION


.EXAMPLE
    .\Export-HuntressIncidents.ps1
#>

[CmdletBinding()]
param()

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

# System settings and variables

$OutputDir = Join-Path $PSScriptRoot ".\output"
$OutputDetail = Join-Path $OutputDir "huntress-incidents-detail.csv"
$OutputSummary = Join-Path $OutputDir "huntress-incidents-summary.md"
$OutputSummaryCsv = Join-Path $OutputDir "huntress-incidents-summary.csv"

# Import functions

. (Join-Path $PSScriptRoot "..\..\scripts\Functions-VA-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\scripts\Functions-Huntress-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\scripts\Functions-Formatting-Common.ps1")

# Validate output directory

Test-Directory $OutputDir

# Import settings and set API context

Write-Host "Connecting to Huntress..." -ForegroundColor Cyan
$Settings = Import-Settings -SettingsPath (Join-Path $PSScriptRoot "..\..\data\reference\HuntressSettings.txt")
$HuntressApiContext = Set-HuntressApiContext -Settings $Settings

# ---------------------------------------------------------------------------
# Step 1: Get all incidents
# ---------------------------------------------------------------------------

Write-Host "Fetching organizations (for customer name lookup)..." -ForegroundColor Cyan
$OrgLookup = Get-HuntressOrganizationLookup -Connection $HuntressApiContext

Write-Host "Fetching incidents..." -ForegroundColor Cyan
$All = Get-AllHuntressResults -Connection $HuntressApiContext -Endpoint "incident_reports"
$Open = @($All | Where-Object { $_.status -ne "closed" })

$Now = Get-Date

# ---------------------------------------------------------------------------
# Step 2: Export incident details (CSV)
# ---------------------------------------------------------------------------

Write-Host "Shaping output rows (1)..." -ForegroundColor Cyan
$Rows = foreach ($e in $Open) {
    $Sent = [datetime]$e.sent_at
    $StatusUpdated = [datetime]$e.status_updated_at
    $OrgKey = [string]$e.organization_id
    $Customer = if ($OrgLookup.ContainsKey($OrgKey)) { $OrgLookup[$OrgKey] -join "; " } else { "" }

    [PSCustomObject]@{
        "Incident ID"              = $e.id
        "Customer"                 = $Customer
        "Severity"                 = $e.severity
        "Platform"                 = $e.platform
        "Indicator Types"          = ($e.indicator_types -join "; ")
        "Subject"                  = $e.subject
        "Status"                   = $e.status
        "Sent"                     = $Sent.ToString("yyyy-MM-dd HH:mm:ss")
        "Days Since Sent"          = [math]::Round(($Now - $Sent).TotalDays, 1)
        "Status Updated"           = $StatusUpdated.ToString("yyyy-MM-dd HH:mm:ss")
        "Days Since Status Update" = [math]::Round(($Now - $StatusUpdated).TotalDays, 1)
    }
}
$Rows = @($Rows | Sort-Object "Days Since Sent" -Descending)
Export-Utf8NoBomCsv -Path $OutputDetail -InputObject $Rows

# ---------------------------------------------------------------------------
# Step 3: Export incident summary (CSV)
# ---------------------------------------------------------------------------

Write-Host "Shaping output rows (2)..." -ForegroundColor Cyan
# By customer - oldest-sent first, so the account needing the most attention surfaces
# first, same idea as the ait-patching "by location" breakdown.
$ByCustomer = @{}
foreach ($r in $Rows) {
    $Customer = $r.Customer
    if (-not $ByCustomer.ContainsKey($Customer)) {
        $ByCustomer[$Customer] = @{ Count = 0; OldestDays = 0 }
    }
    $ByCustomer[$Customer].Count++
    if ($r.'Days Since Sent' -gt $ByCustomer[$Customer].OldestDays) {
        $ByCustomer[$Customer].OldestDays = $r.'Days Since Sent'
    }
}
$ByCustomerRows = foreach ($Customer in $ByCustomer.Keys) {
    [PSCustomObject]@{
        "Customer"        = $Customer
        "Open Incidents"  = $ByCustomer[$Customer].Count
        "Oldest (Days)"   = $ByCustomer[$Customer].OldestDays
    }
}
$ByCustomerRows = @($ByCustomerRows | Sort-Object "Oldest (Days)" -Descending)

# Total row, same convention as the PM/service-delivery coordinator summaries - "Oldest
# (Days)" is left blank since it isn't a summable metric (unlike the count column).
$TotalRow = [ordered]@{
    "Customer"       = "Total"
    "Open Incidents" = $Rows.Count
    "Oldest (Days)"  = ""
}
$SummaryRows = @($ByCustomerRows) + [PSCustomObject]$TotalRow
Export-Utf8NoBomCsv -Path $OutputSummaryCsv -InputObject $SummaryRows

# ---------------------------------------------------------------------------
# Step 4: Export incident summary (Markdown)
# ---------------------------------------------------------------------------

Write-Host "Shaping output rows (3)..." -ForegroundColor Cyan
$BySeverity = $Rows | Group-Object Severity | Sort-Object Count -Descending

$Lines = [System.Collections.Generic.List[string]]::new()
$Lines.Add("# Security Coordinator Report (Incidents) - $($Now.ToString('yyyy-MM-dd HH:mm'))")
$Lines.Add("")
$Lines.Add("## Executive Summary")
$Lines.Add("")
$Lines.Add("Open (non-closed) incident(s): $($Rows.Count)")
$Lines.Add("")
if ($Rows.Count -gt 0) {
    $Oldest = $Rows[0]
    $Lines.Add("Longest-waiting: $($Oldest.'Days Since Sent') day(s) since sent - $($Oldest.Customer) - $($Oldest.Subject)")
    $Lines.Add("")
}
foreach ($g in $BySeverity) {
    $Lines.Add("- $($g.Name): $($g.Count)")
}
$Lines.Add("")
$Lines.Add("## By Customer (sorted by longest-waiting first)")
$Lines.Add("")
$Lines.Add("| Customer | Open Incidents | Oldest (Days) |")
$Lines.Add("|---|---|---|")
foreach ($row in $ByCustomerRows) {
    $CustomerDisplay = [string]$row.Customer -replace '\|', '\|'
    $Lines.Add("| $CustomerDisplay | $($row.'Open Incidents') | $($row.'Oldest (Days)') |")
}
$Lines.Add("| **Total** | $($Rows.Count) | |")
$Lines.Add("")
$Lines.Add("Summary (CSV): $(Split-Path $OutputSummaryCsv -Leaf)  ")
$Lines.Add("Full detail (every open incident): $(Split-Path $OutputDetail -Leaf)")

Set-Utf8NoBomContent -Path $OutputSummary -Value ($Lines -join "`n")

# ---------------------------------------------------------------------------
# Complete
# ---------------------------------------------------------------------------

Write-Host "Open incidents: $($Rows.Count)"
if ($Rows.Count -gt 0) {
    Write-Host "Longest-waiting: $($Rows[0].'Days Since Sent') day(s) since sent - $($Rows[0].Customer) - $($Rows[0].Subject)"
}
Write-Host "Wrote $OutputDetail, $OutputSummary, and $OutputSummaryCsv"
