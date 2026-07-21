<#
.SYNOPSIS
    Service-delivery Coordinator status report (ticket data). PowerShell rewrite of the
    retired ticket_summary_flags.py.

.DESCRIPTION
    Reads the ticket export and reports on every in-scope ticket, not just problem ones.
    Each ticket gets a computed Health label:
      - Critical Unassigned: Priority 1 (Critical) with no tech assigned (worst)
      - Stalled Intake: sitting in the "New" queue at all (should have moved to a real
        work queue by now), or Dispatched in any other queue (a tech hasn't
        acknowledged/accepted the handoff yet) - a workflow/routing problem, not a
        time-based one, so no age threshold applies
      - Stale: no logged activity in STALE_DAYS+ days, based on Last Activity Time
      - Waiting External: blocked on the customer or a vendor, not on us
      - Unassigned: no tech assigned, doesn't already fall into the above
      - Active: has a tech assigned and isn't stuck in any of the above states

    Note: the source export's "Due" field is NOT a live SLA clock - it's a static ~24 hour
    first-response timer set once at ticket creation, so it isn't used for flagging.

    Excludes tickets matching any rule in ../data/reference/excluded-ticket-sources.csv.
    Each row is a Queue+Source+Resource rule where a blank cell is a wildcard (matches
    anything) and non-blank cells must ALL match (AND) for that row; a ticket is excluded
    if ANY row matches (OR across rows) - e.g. a row with only Queue set excludes that
    whole queue regardless of source, while a row with both Queue and Source set only
    excludes that combination. Queue and Source match exactly; Resource matches as a
    case-insensitive substring, since the Resources field can hold multiple assignees
    (e.g. "Saeed, Kamran (primary) | Decaria, David").

    Also labels every in-scope ticket with a Ticket Origin (Human-Generated /
    System-Generated / Unclassified) via ../data/reference/source-classification.csv - kept
    separate from the exclusion list because these tickets stay in scope (e.g. a
    system-generated monitoring ticket still needs a human to review it).

.EXAMPLE
    .\Export-CoordinatorTicketFlagsReport.ps1
#>

[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot "..\..\scripts\ReportFormatting-Common.ps1")

$STALE_DAYS = 7

$WAITING_STATUSES = @(
    "Waiting Customer", "Waiting Vendor", "Waiting CI Update",
    "Waiting Return", "Waiting*"
)

$INTAKE_QUEUE = "New"
$DISPATCHED_STATUS = "Dispatched"

$RawExport = Join-Path $PSScriptRoot "..\data\raw\Ticket Search Results.csv"
$ExcludedList = Join-Path $PSScriptRoot "..\data\reference\excluded-ticket-sources.csv"
$SourceClassification = Join-Path $PSScriptRoot "..\data\reference\source-classification.csv"

$OutputDir = Join-Path $PSScriptRoot "output"
$OutputCsv = Join-Path $OutputDir "coordinator-ticket-flags-detail.csv"
$OutputSummary = Join-Path $OutputDir "coordinator-ticket-flags-summary.md"
$OutputSummaryCsv = Join-Path $OutputDir "coordinator-ticket-flags-summary.csv"

$DateFormat = "MM/dd/yyyy hh:mm tt"

function Test-Blank {
    param($Value)
    [string]::IsNullOrWhiteSpace($Value)
}

function ConvertTo-NullableDate {
    param([string]$Value)
    if (Test-Blank $Value) { return $null }
    $Parsed = [datetime]::MinValue
    if ([datetime]::TryParseExact($Value, $DateFormat, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$Parsed)) {
        return $Parsed
    }
    return $null
}

function Test-TicketExcluded {
    param($Ticket, [array]$Rules)

    foreach ($Rule in $Rules) {
        $Match = $true
        if (-not (Test-Blank $Rule.Queue)) { $Match = $Match -and ($Ticket.Queue -eq $Rule.Queue) }
        if (-not (Test-Blank $Rule.Source)) { $Match = $Match -and ($Ticket.Source -eq $Rule.Source) }
        if (-not (Test-Blank $Rule.Resource)) {
            $Resources = if ($Ticket.Resources) { $Ticket.Resources } else { "" }
            $Match = $Match -and ($Resources.ToLower().Contains($Rule.Resource.ToLower()))
        }
        if ($Match) { return $true }
    }
    return $false
}

# --- load -----------------------------------------------------------------

$Tickets = @(Import-Csv -Path $RawExport -Encoding UTF8)
$ExcludedRules = @(Import-Csv -Path $ExcludedList -Encoding UTF8)
$Classification = @(Import-Csv -Path $SourceClassification -Encoding UTF8)

$ClassificationLookup = @{}
foreach ($row in $Classification) { $ClassificationLookup[$row.Source] = $row.Classification }

# --- exclude ----------------------------------------------------------------

$InScope = [System.Collections.Generic.List[object]]::new()
$ExcludedCount = 0
foreach ($t in $Tickets) {
    if (Test-TicketExcluded -Ticket $t -Rules $ExcludedRules) {
        $ExcludedCount++
    }
    else {
        $InScope.Add($t)
    }
}

$Now = Get-Date

# --- classify + flag ----------------------------------------------------------------

foreach ($t in $InScope) {

    $Origin = if (Test-Blank $t.Source) { "Unclassified" } else {
        if ($ClassificationLookup.ContainsKey($t.Source)) { $ClassificationLookup[$t.Source] } else { "Unclassified" }
    }

    $Created = ConvertTo-NullableDate $t.Created
    $Due = ConvertTo-NullableDate $t.Due
    $LastActivity = ConvertTo-NullableDate $t.'Last Activity Time'

    $AgeDays = if ($Created) { [math]::Round(($Now - $Created).TotalDays, 1) } else { $null }
    # [int] casts round to nearest in PowerShell (unlike Python's int(), which truncates
    # toward zero) - [math]::Truncate() matches the original pandas .apply(int) behavior.
    $DaysSinceLastActivity = if ($LastActivity) { [int][math]::Truncate(($Now - $LastActivity).TotalDays) } else { $null }

    $Unassigned = Test-Blank $t.Resources
    $Critical = $t.Priority -eq "1 (Critical)"
    $Waiting = $WAITING_STATUSES -contains $t.Status
    $StalledIntake = ($t.Queue -eq $INTAKE_QUEUE) -or (($t.Status -eq $DISPATCHED_STATUS) -and ($t.Queue -ne $INTAKE_QUEUE))
    $Stale = ($null -ne $DaysSinceLastActivity) -and ($DaysSinceLastActivity -gt $STALE_DAYS)
    $CriticalUnassigned = $Critical -and $Unassigned

    $Health =
        if ($CriticalUnassigned) { "Critical Unassigned" }
        elseif ($StalledIntake) { "Stalled Intake" }
        elseif ($Stale) { "Stale" }
        elseif ($Waiting) { "Waiting External" }
        elseif ($Unassigned) { "Unassigned" }
        else { "Active" }

    # Full picture, not just the winning flag - every tripped condition, in priority order.
    # "Unassigned" is suppressed whenever "Critical Unassigned" is also present, since that
    # flag requires unassigned=True by construction and listing both would be redundant.
    $FlagNames = [System.Collections.Generic.List[string]]::new()
    if ($CriticalUnassigned) { $FlagNames.Add("Critical Unassigned") }
    if ($StalledIntake) { $FlagNames.Add("Stalled Intake") }
    if ($Stale) { $FlagNames.Add("Stale") }
    if ($Waiting) { $FlagNames.Add("Waiting External") }
    if ($Unassigned -and -not $CriticalUnassigned) { $FlagNames.Add("Unassigned") }
    $AllFlags = if ($FlagNames.Count -gt 0) { $FlagNames -join ", " } else { "Active" }

    $t | Add-Member -NotePropertyName "Ticket Origin" -NotePropertyValue $Origin -Force
    $t | Add-Member -NotePropertyName "CreatedParsed" -NotePropertyValue $Created -Force
    $t | Add-Member -NotePropertyName "DueParsed" -NotePropertyValue $Due -Force
    $t | Add-Member -NotePropertyName "LastActivityParsed" -NotePropertyValue $LastActivity -Force
    $t | Add-Member -NotePropertyName "Age Days" -NotePropertyValue $AgeDays -Force
    $t | Add-Member -NotePropertyName "Days Since Last Activity" -NotePropertyValue $DaysSinceLastActivity -Force
    $t | Add-Member -NotePropertyName "Flag: Critical Unassigned" -NotePropertyValue $CriticalUnassigned -Force
    $t | Add-Member -NotePropertyName "Flag: Stalled Intake" -NotePropertyValue $StalledIntake -Force
    $t | Add-Member -NotePropertyName "Flag: Stale" -NotePropertyValue $Stale -Force
    $t | Add-Member -NotePropertyName "Flag: Waiting External" -NotePropertyValue $Waiting -Force
    $t | Add-Member -NotePropertyName "Flag: Unassigned" -NotePropertyValue $Unassigned -Force
    $t | Add-Member -NotePropertyName "Health" -NotePropertyValue $Health -Force
    $t | Add-Member -NotePropertyName "All Flags" -NotePropertyValue $AllFlags -Force
}

if (-not (Test-Path -LiteralPath $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }

# --- detail CSV: worst Health first, then longest-stale first (nulls last) ----------------

$HealthOrder = [ordered]@{
    "Critical Unassigned" = 0; "Stalled Intake" = 1; "Stale" = 2
    "Waiting External" = 3; "Unassigned" = 4; "Active" = 5
}

$Ordered = @($InScope | Sort-Object -Property `
    @{ Expression = { $HealthOrder[$_.Health] } }, `
    @{ Expression = { if ($null -ne $_.'Days Since Last Activity') { $_.'Days Since Last Activity' } else { -1 } }; Descending = $true })

$DetailRows = foreach ($t in $Ordered) {
    [PSCustomObject]@{
        "Ticket Number"                 = $t.'Ticket Number'
        "Account"                       = $t.Account
        "Title"                         = $t.Title
        "Queue"                         = $t.Queue
        "Source"                        = $t.Source
        "Ticket Origin"                 = $t.'Ticket Origin'
        "Priority"                      = $t.Priority
        "Status"                        = $t.Status
        "Health"                        = $t.Health
        "All Flags"                     = $t.'All Flags'
        "Resources"                     = $t.Resources
        "Created"                       = if ($t.CreatedParsed) { $t.CreatedParsed.ToString("yyyy-MM-dd HH:mm:ss") } else { "" }
        "Due"                           = if ($t.DueParsed) { $t.DueParsed.ToString("yyyy-MM-dd HH:mm:ss") } else { "" }
        "Last Activity Time"            = if ($t.LastActivityParsed) { $t.LastActivityParsed.ToString("yyyy-MM-dd HH:mm:ss") } else { "" }
        "Age Days"                      = $t.'Age Days'
        "Days Since Last Activity"      = $t.'Days Since Last Activity'
        "Flag: Critical Unassigned"     = $t.'Flag: Critical Unassigned'
        "Flag: Stalled Intake"          = $t.'Flag: Stalled Intake'
        "Flag: Stale"                   = $t.'Flag: Stale'
        "Flag: Waiting External"        = $t.'Flag: Waiting External'
        "Flag: Unassigned"              = $t.'Flag: Unassigned'
    }
}
Export-Utf8NoBomCsv -Path $OutputCsv -InputObject @($DetailRows)

# --- summary ----------------------------------------------------------------

$HealthLabels = @("Critical Unassigned", "Stalled Intake", "Stale", "Waiting External", "Unassigned", "Active")
$N = @{}
foreach ($label in $HealthLabels) {
    $N[$label] = @($InScope | Where-Object { $_.Health -eq $label }).Count
}

$FlagLabels = @("Critical Unassigned", "Stalled Intake", "Stale", "Waiting External", "Unassigned")

$Flagged = @($InScope | Where-Object { $_.Health -ne "Active" })

# Tallies the single-label Health per queue (mutually exclusive - each flagged ticket
# counted exactly once, under whichever Health won), not the 5 independent Flag: columns -
# a ticket can trip multiple flags at once, but "Flags by Queue" mirrors the Executive
# Summary's Health breakdown so the two don't disagree with each other.
$ByQueue = @{}
foreach ($t in $Flagged) {
    $Queue = $t.Queue
    if (-not $ByQueue.ContainsKey($Queue)) {
        $ByQueue[$Queue] = @{}
        foreach ($label in $FlagLabels) { $ByQueue[$Queue][$label] = 0 }
        $ByQueue[$Queue]["Total Flagged"] = 0
    }
    $ByQueue[$Queue][$t.Health]++
    $ByQueue[$Queue]["Total Flagged"]++
}

$ByQueueRows = foreach ($Queue in $ByQueue.Keys) {
    $Row = [ordered]@{ "Queue" = $Queue }
    foreach ($label in $FlagLabels) { $Row[$label] = $ByQueue[$Queue][$label] }
    $Row["Total Flagged"] = $ByQueue[$Queue]["Total Flagged"]
    [PSCustomObject]$Row
}
$ByQueueRows = @($ByQueueRows | Sort-Object -Property "Total Flagged" -Descending)

$TotalFlagged = ($FlagLabels | ForEach-Object { $N[$_] } | Measure-Object -Sum).Sum

$TotalRow = [ordered]@{ "Queue" = "Total" }
foreach ($label in $FlagLabels) { $TotalRow[$label] = $N[$label] }
$TotalRow["Total Flagged"] = $TotalFlagged
$SummaryRows = @($ByQueueRows) + [PSCustomObject]$TotalRow
Export-Utf8NoBomCsv -Path $OutputSummaryCsv -InputObject $SummaryRows

$Lines = [System.Collections.Generic.List[string]]::new()
$Lines.Add("# Service Delivery Coordinator Report (Flags) - $($Now.ToString('yyyy-MM-dd HH:mm'))")
$Lines.Add("")
$Lines.Add("## Executive Summary")
$Lines.Add("")
$Lines.Add("Ticket(s) excluded $ExcludedCount (see ../data/reference/excluded-ticket-sources.csv).")
$Lines.Add("")
$Lines.Add("Ticket(s) analyzed: $($InScope.Count)")
$Lines.Add("")
$Lines.Add("- Critical Unassigned: $($N['Critical Unassigned'])")
$Lines.Add("- Stalled Intake (New queue, or Dispatched elsewhere): $($N['Stalled Intake'])")
$Lines.Add("- Stale (no activity $STALE_DAYS+ days): $($N['Stale'])")
$Lines.Add("- Waiting External (customer/vendor): $($N['Waiting External'])")
$Lines.Add("- Unassigned (other): $($N['Unassigned'])")
$Lines.Add("- Active: $($N['Active'])")
$Lines.Add("")
$Lines.Add("## Flags by Queue (sorted worst first)")
$Lines.Add("")
$Lines.Add("| Queue | " + ($FlagLabels -join " | ") + " | Total Flagged |")
$Lines.Add("|" + ("---|" * ($FlagLabels.Count + 2)))
foreach ($row in ($ByQueueRows | Select-Object -First 15)) {
    $QueueDisplay = [string]$row.Queue -replace '\|', '\|'
    $Vals = ($FlagLabels | ForEach-Object { $row.$_ }) -join " | "
    $Lines.Add("| $QueueDisplay | $Vals | $($row.'Total Flagged') |")
}
$TotalVals = ($FlagLabels | ForEach-Object { $N[$_] }) -join " | "
$Lines.Add("| **Total** | $TotalVals | $TotalFlagged |")
$Lines.Add("")
$Lines.Add("Summary (CSV): $(Split-Path $OutputSummaryCsv -Leaf)  ")
$Lines.Add("Full detail (every in-scope ticket, not just flagged ones): $(Split-Path $OutputCsv -Leaf)")

Set-Utf8NoBomContent -Path $OutputSummary -Value ($Lines -join "`n")

Write-Host "Tickets analyzed: $($InScope.Count) (excluded $ExcludedCount ticket(s))"
Write-Host "Critical Unassigned: $($N['Critical Unassigned']) | Stalled Intake: $($N['Stalled Intake']) | Stale: $($N['Stale']) | Waiting External: $($N['Waiting External']) | Unassigned: $($N['Unassigned']) | Active: $($N['Active'])"
Write-Host "Wrote $OutputCsv, $OutputSummary, and $OutputSummaryCsv"
