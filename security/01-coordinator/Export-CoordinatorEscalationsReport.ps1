<#
.SYNOPSIS
    Security Coordinator report: every open (non-resolved) Huntress escalation, with how
    long each has been waiting on us since it was created. PowerShell rewrite/rework of the
    prior HuntressCustomerAudit-Escalations.ps1 (a copy-paste from an external script store),
    adapted to this workspace's conventions and pointed at the workspace's own encrypted
    settings file.

.DESCRIPTION
    Unlike the project/ticket coordinators, there's no derived Health/flag logic here - per
    Brad, every open escalation is already actionable by definition (that's what "open"
    means for a Huntress escalation), so this just surfaces the detail and sorts by how long
    it's been sitting (oldest/longest-waiting first), rather than computing a flag.

    "Open" = status other than "resolved" - confirmed live against the Huntress API that
    "sent" and "resolved" are the only two status values currently in use. Age is measured
    from created_at (when Huntress first raised it), since that's when it started waiting on
    us, not updated_at (which moves on any change, not just our action).

    The Huntress API's own status filter param rejected "status=sent" as an invalid value
    when tested live, so - matching the original script's approach - status filtering here
    is done client-side against the full fetched list, not server-side via a query param.

.EXAMPLE
    .\Export-CoordinatorEscalationsReport.ps1
#>

[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot "..\scripts\Huntress-Functions-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\scripts\ReportFormatting-Common.ps1")

$OutputDir = Join-Path $PSScriptRoot "output"
$OutputDetail = Join-Path $OutputDir "coordinator-escalations-detail.csv"
$OutputSummary = Join-Path $OutputDir "coordinator-escalations-summary.md"
$OutputSummaryCsv = Join-Path $OutputDir "coordinator-escalations-summary.csv"

$RESOLVED_STATUS = "resolved"

$Connection = Connect-Huntress
$All = Invoke-HuntressQuery -Connection $Connection -Endpoint "escalations"
$Open = @($All | Where-Object { $_.status -ne $RESOLVED_STATUS })

$Now = Get-Date

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

if (-not (Test-Path -LiteralPath $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
Export-Utf8NoBomCsv -Path $OutputDetail -InputObject $Rows

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
Export-Utf8NoBomCsv -Path $OutputSummaryCsv -InputObject $ByCustomerRows

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
$Lines.Add("")
$Lines.Add("Summary (CSV): $(Split-Path $OutputSummaryCsv -Leaf)  ")
$Lines.Add("Full detail (every open escalation): $(Split-Path $OutputDetail -Leaf)")

Set-Utf8NoBomContent -Path $OutputSummary -Value ($Lines -join "`n")

Write-Host "Open escalations: $($Rows.Count)"
if ($Rows.Count -gt 0) {
    Write-Host "Longest-waiting: $($Rows[0].'Days Waiting') day(s) - $($Rows[0].Customer) - $($Rows[0].Subject)"
}
Write-Host "Wrote $OutputDetail, $OutputSummary, and $OutputSummaryCsv"
