<#
.SYNOPSIS
    Pulls open tickets from Autotask and writes them to data/raw/Ticket Search Results.csv,
    replacing the old manual UI export as the source for the ticket flags report.

.DESCRIPTION
    "Open" here means status not in the six "done" statuses this Autotask instance uses -
    Complete (5), Pending Complete (17), Complete (50%) (22), Complete (75%) (23),
    Complete ServIT Remediate (28), Complete (Escalated) (29). Confirmed against the
    historical manual export: none of those six ever appear in it, so this reproduces the
    same "open tickets" scope, just server-side instead of via the old UI export.

    Company, Queue, Priority, Status, and Source names are resolved via batched
    Companies lookups and the entities' own picklists (not one call per ticket).

    Resources is just the assigned resource ("Last, First"), not the old manual export's
    multi-name "Name (primary) | Name2" list. That list turned out not to be reliably
    reconstructible live - spot-checking two historical multi-resource tickets found one
    where the secondary name matched completedByResourceID, and another where the
    secondary name ("Harp, James") no longer appeared on the ticket at all, because the
    ticket had been reassigned since the export. Since the flags report only ever checks
    whether Resources is blank (the Unassigned flag), not who all is listed, the single
    assigned resource is sufficient and far less fragile than chasing full reconstruction.

    Columns are limited to what Export-CoordinatorTicketFlagsReport.ps1 actually reads
    (Ticket Number, Account, Title, Queue, Source, Priority, Status, Resources, Created,
    Due, Last Activity Time) - the old export's other columns (Classification, Contact
    Phone, Contract, Complete Date, Total Hours Worked, Billed Hours, Site, Line of
    Business, Completed By, Resolution) aren't read by the report at all, and each would
    need its own lookup (Contacts, Contracts, CompanyLocations, TimeEntries aggregation,
    or UDFs) with its own chance of a wrong mapping, so they're left out per Brad's call.

.EXAMPLE
    .\Get-CoordinatorTicketData.ps1
#>

[CmdletBinding()]
param(
    [string]$OutputPath
)

if (-not $OutputPath) { $OutputPath = Join-Path $PSScriptRoot "..\data\raw\Ticket Search Results.csv" }

$FunctionsScript = Join-Path $PSScriptRoot "..\..\scripts\Autotask-Functions-Common.ps1"
if (-not (Test-Path -LiteralPath $FunctionsScript)) {
    Write-Error "Shared functions script not found: $FunctionsScript"
    exit 1
}
. $FunctionsScript

# The "done" family - confirmed none of these appear in the historical manual export.
$DoneStatusIds = @(5, 17, 22, 23, 28, 29)

Write-Host "Connecting to Autotask..." -ForegroundColor Cyan
$Connection = Connect-Autotask

Write-Host "Fetching status/priority/queue/source picklists..." -ForegroundColor Cyan
$StatusLabels = Get-AutotaskPicklist -Connection $Connection -Entity "Tickets" -FieldName "status"
$PriorityLabels = Get-AutotaskPicklist -Connection $Connection -Entity "Tickets" -FieldName "priority"
$QueueLabels = Get-AutotaskPicklist -Connection $Connection -Entity "Tickets" -FieldName "queueID"
$SourceLabels = Get-AutotaskPicklist -Connection $Connection -Entity "Tickets" -FieldName "source"

Write-Host "Fetching open tickets (status not in the Complete family)..." -ForegroundColor Cyan
$Tickets = Invoke-AutotaskQuery -Connection $Connection -Entity "Tickets" -Filter @(
    @{ op = "notIn"; field = "status"; value = $DoneStatusIds }
)
Write-Host "  $($Tickets.Count) open ticket(s) found."

Write-Host "Resolving company names..." -ForegroundColor Cyan
# $null -ne $_ (not just { $_ }) - company ID 0 is a real account in this instance
# (ServIT's own internal company) and 0 is falsy in PowerShell, so a truthy filter here
# would silently drop every internal ticket's Account name.
$CompanyIds = @($Tickets.companyID | Where-Object { $null -ne $_ } | Select-Object -Unique)
$CompanyNames = @{}
foreach ($Batch in (Get-InBatches -Values $CompanyIds)) {
    $Companies = Invoke-AutotaskQuery -Connection $Connection -Entity "Companies" -Filter @(
        @{ op = "in"; field = "id"; value = $Batch }
    )
    foreach ($c in $Companies) { $CompanyNames[[string]$c.id] = $c.companyName }
}

Write-Host "Resolving assigned resource names..." -ForegroundColor Cyan
$ResourceIds = @($Tickets.assignedResourceID | Where-Object { $_ } | Select-Object -Unique)
$ResourceNames = @{}
foreach ($Batch in (Get-InBatches -Values $ResourceIds)) {
    $Resources = Invoke-AutotaskQuery -Connection $Connection -Entity "Resources" -Filter @(
        @{ op = "in"; field = "id"; value = $Batch }
    )
    # Autotask's own Resources records have stray leading/trailing whitespace on some
    # name fields (e.g. "Pawsat ", "Harrison ") - trim so "Last, First" prints cleanly.
    foreach ($r in $Resources) { $ResourceNames[[string]$r.id] = "$($r.lastName.Trim()), $($r.firstName.Trim())" }
}

Write-Host "Shaping output rows..." -ForegroundColor Cyan
$Rows = foreach ($t in $Tickets) {
    [PSCustomObject]@{
        "Ticket Number"       = $t.ticketNumber
        "Account"             = $CompanyNames[[string]$t.companyID]
        "Title"               = $t.title
        "Queue"               = $QueueLabels[[string]$t.queueID]
        "Source"              = $SourceLabels[[string]$t.source]
        "Priority"            = $PriorityLabels[[string]$t.priority]
        "Status"              = $StatusLabels[[string]$t.status]
        "Resources"           = if ($t.assignedResourceID) { $ResourceNames[[string]$t.assignedResourceID] } else { "" }
        "Created"             = if ($t.createDate) { [datetime]$t.createDate | Get-Date -Format "MM/dd/yyyy hh:mm tt" } else { "" }
        "Due"                 = if ($t.dueDateTime) { [datetime]$t.dueDateTime | Get-Date -Format "MM/dd/yyyy hh:mm tt" } else { "" }
        "Last Activity Time"  = if ($t.lastActivityDate) { [datetime]$t.lastActivityDate | Get-Date -Format "MM/dd/yyyy hh:mm tt" } else { "" }
    }
}

$OutputDir = Split-Path $OutputPath -Parent
if (-not (Test-Path -LiteralPath $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
$Rows | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

Write-Host "Wrote $($Rows.Count) row(s) to $OutputPath" -ForegroundColor Green
