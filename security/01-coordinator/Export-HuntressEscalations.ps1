<#
.SYNOPSIS
    

.DESCRIPTION
    

.EXAMPLE
    .\Export-HuntressEscalations.ps1
#>

[CmdletBinding()]
param()

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

# System settings and variables

$OutputDir = Join-Path $PSScriptRoot ".\output"
$OutputDetail = Join-Path $OutputDir "huntress-escalations-detail.csv"
$OutputSummary = Join-Path $OutputDir "huntress-escalations-summary.md"
$OutputSummaryCsv = Join-Path $OutputDir "huntress-escalations-summary.csv"

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
# Step 1: Get all escalations
# ---------------------------------------------------------------------------

Write-Host "Fetching escalations..." -ForegroundColor Cyan
$All = Get-AllHuntressResults -Connection $HuntressApiContext -Endpoint "escalations"
$Open = @($All | Where-Object { $_.status -ne "resolved" })

$Now = Get-Date

# ---------------------------------------------------------------------------
# Step 2: Export escalation details (CSV)
# ---------------------------------------------------------------------------

Write-Host "Shaping output rows (1)..." -ForegroundColor Cyan
$Rows = foreach ($e in $Open) {
    $Created = [datetime]$e.created_at
    $Customer = if ($e.organizations) { ($e.organizations.name) -join "; " } else { "" }

    [PSCustomObject]@{
        "Escalation ID"    = $e.id
        "Customer"         = $Customer
        "Severity"         = $e.severity
        "Type"             = $e.type
        "Subtype"          = $e.subtype
        "Subject"          = $e.subject
        "Status"           = $e.status
        "Created"          = $Created.ToString("yyyy-MM-dd HH:mm:ss")
        "Days Waiting"     = [math]::Round(($Now - $Created).TotalDays, 1)
    }
}
$Rows = @($Rows | Sort-Object "Days Waiting" -Descending) 
Export-Utf8NoBomCsv -Path $OutputDetail -InputObject $Rows

# ---------------------------------------------------------------------------
# Step 3: Export escalation summary (CSV)
# ---------------------------------------------------------------------------

Write-Host "Shaping output rows (2)..." -ForegroundColor Cyan
# By customer - oldest-waiting first, so the account needing the most attention surfaces
# first, same idea as the ait-patching "by location" breakdown.
$ByCustomer = @{}
foreach ($r in $Rows) {
    $Customer = $r.Customer
    if (-not $ByCustomer.ContainsKey($Customer)) {
        $ByCustomer[$Customer] = @{ Count = 0; OldestDays = 0 }
    }
    $ByCustomer[$Customer].Count++
    if ($r.'Days Waiting' -gt $ByCustomer[$Customer].OldestDays) {
        $ByCustomer[$Customer].OldestDays = $r.'Days Waiting'
    }
}
$ByCustomerRows = foreach ($Customer in $ByCustomer.Keys) {
    [PSCustomObject]@{
        "Customer"          = $Customer
        "Open Escalations"  = $ByCustomer[$Customer].Count
        "Oldest (Days)"     = $ByCustomer[$Customer].OldestDays
    }
}
$ByCustomerRows = @($ByCustomerRows | Sort-Object "Oldest (Days)" -Descending)

# Total row, same convention as the PM/service-delivery coordinator summaries - "Oldest
# (Days)" is left blank since it isn't a summable metric (unlike the count column).
$TotalRow = [ordered]@{
    "Customer"         = "Total"
    "Open Escalations" = $Rows.Count
    "Oldest (Days)"    = ""
}
$SummaryRows = @($ByCustomerRows) + [PSCustomObject]$TotalRow
Export-Utf8NoBomCsv -Path $OutputSummaryCsv -InputObject $SummaryRows

# ---------------------------------------------------------------------------
# Step 4: Export escalation details (CSV)
# ---------------------------------------------------------------------------

Write-Host "Shaping output rows (3)..." -ForegroundColor Cyan
$BySeverity = $Rows | Group-Object Severity | Sort-Object Count -Descending

$Lines = [System.Collections.Generic.List[string]]::new()
$Lines.Add("# Security Coordinator Report (Escalations) - $($Now.ToString('yyyy-MM-dd HH:mm'))")
$Lines.Add("")
$Lines.Add("## Executive Summary")
$Lines.Add("")
$Lines.Add("Open (non-resolved) escalation(s): $($Rows.Count)")
$Lines.Add("")
if ($Rows.Count -gt 0) {
    $Oldest = $Rows[0]
    $Lines.Add("Longest-waiting: $($Oldest.'Days Waiting') day(s) - $($Oldest.Customer) - $($Oldest.Subject)")
    $Lines.Add("")
}
foreach ($g in $BySeverity) {
    $Lines.Add("- $($g.Name): $($g.Count)")
}
$Lines.Add("")
$Lines.Add("## By Customer (sorted by longest-waiting first)")
$Lines.Add("")
$Lines.Add("| Customer | Open Escalations | Oldest (Days) |")
$Lines.Add("|---|---|---|")
foreach ($row in $ByCustomerRows) {
    $CustomerDisplay = [string]$row.Customer -replace '\|', '\|'
    $Lines.Add("| $CustomerDisplay | $($row.'Open Escalations') | $($row.'Oldest (Days)') |")
}
$Lines.Add("| **Total** | $($Rows.Count) | |")
$Lines.Add("")
$Lines.Add("Summary (CSV): $(Split-Path $OutputSummaryCsv -Leaf)  ")
$Lines.Add("Full detail (every open escalation): $(Split-Path $OutputDetail -Leaf)")

Set-Utf8NoBomContent -Path $OutputSummary -Value ($Lines -join "`n")

# ---------------------------------------------------------------------------
# Complete
# ---------------------------------------------------------------------------

Write-Host "Open escalations: $($Rows.Count)"
if ($Rows.Count -gt 0) {
    Write-Host "Longest-waiting: $($Rows[0].'Days Waiting') day(s) - $($Rows[0].Customer) - $($Rows[0].Subject)"
}
Write-Host "Wrote $OutputDetail, $OutputSummary, and $OutputSummaryCsv"
