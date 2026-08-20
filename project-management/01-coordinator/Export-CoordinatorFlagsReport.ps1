<#
.SYNOPSIS
    Coordinator report: Stalled Intake / Stale / No Lead(s) / Need PCM flags by Project Lead.
    PowerShell rewrite of the retired project_summary_flags.py.

.DESCRIPTION
    Flag: Stale is the OR of three independent signals, each with its own threshold, replacing
    the old single-field read of Autotask's lastActivityDateTime (found unreliable for Projects -
    it fires on any record edit, not just real activity):
      - Hours/Tasks: Actual Hours / % Complete - Task "last changed" dates are tracked locally
        via ProjectSnapshotHistory.ps1, in ../data/state/project-snapshot-history.json - Actual
        Hours replaced % Complete - Hours as the Hours signal since % Complete - Hours sits stuck
        at 0% (never seen as "changed") whenever a project has no estimated hours entered, even
        while real time keeps getting logged against it.
      - Phase: sourced directly from Autotask's own statusDateTime field (native, no local
        tracking needed) - a reasonable but imperfect proxy, since Phase is a many-to-one
        grouping of Status (status-phase-mapping.csv), so a status change that doesn't cross a
        phase boundary still resets this.
    See ProjectSnapshotHistory.ps1's header for the cold-start ("unknown until we see it change")
    behavior of the two locally-tracked signals.

.EXAMPLE
    .\Export-CoordinatorFlagsReport.ps1
#>

[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot "CoordinatorCommon.ps1")
. (Join-Path $PSScriptRoot "ProjectSnapshotHistory.ps1")

# Three independent staleness signals (see ProjectSnapshotHistory.ps1 for Hours/Tasks; Phase
# uses Autotask's own statusDateTime directly). Flag: Stale is the OR of all three - any one
# signal alone can trip it.
$STALE_DAYS_HOURS = 14
$STALE_DAYS_TASKS = 14
$STALE_DAYS_PHASE = 21

$SnapshotPath = Join-Path $PSScriptRoot "..\data\state\project-snapshot-history.json"

$OutputDir = Join-Path $PSScriptRoot "output"
$OutputDetail = Join-Path $OutputDir "coordinator-project-flags-detail.csv"
$OutputSummary = Join-Path $OutputDir "coordinator-project-flags-summary.md"
$OutputSummaryCsv = Join-Path $OutputDir "coordinator-project-flags-summary.csv"

$Data = Import-CoordinatorProjectData
$Result = Remove-ExcludedProjects -Projects $Data.Projects -Excluded $Data.Excluded
$Projects = Add-ProjectPhase -Projects $Result.Projects -PhaseMap $Data.PhaseMap

$Now = Get-Date

# % Complete - Hours and % Complete - Task aren't stored anywhere in Autotask, so their
# "last changed" dates are tracked locally here, updated with this run's values before the
# per-project flag pass below reads them back.
$History = Get-ProjectSnapshotHistory -Path $SnapshotPath
Update-ProjectSnapshotHistory -History $History -Projects $Projects -Path $SnapshotPath -Today $Now

foreach ($p in $Projects) {

    $StatusDate = $null
    if (-not [string]::IsNullOrWhiteSpace($p.'Status Date')) {
        $Parsed = [datetime]::MinValue
        if ([datetime]::TryParseExact($p.'Status Date', "MM/dd/yyyy hh:mm tt", [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$Parsed)) {
            $StatusDate = $Parsed
        }
    }

    $PctTask = [double]($p.'% Complete - Task' -replace '[%,]', '')
    $PctHours = [double]($p.'% Complete - Hours' -replace '[%,]', '')
    $ActualHours = [double]($p.'Actual Hours' -replace ',', '')

    $DaysSinceStatusChange = Get-DaysSince -Value $StatusDate -Reference $Now

    $Snapshot = $History[[string]$p.'Project ID']
    $HoursSignal = if ($Snapshot) { $Snapshot.Hours } else { $null }
    $TaskSignal  = if ($Snapshot) { $Snapshot.Task }  else { $null }
    $ActualHoursSignal = if ($Snapshot) { $Snapshot.ActualHours } else { $null }
    $DaysSinceHoursChange = Get-DaysSinceSignalChange -Signal $HoursSignal -Reference $Now
    $DaysSinceTaskChange  = Get-DaysSinceSignalChange -Signal $TaskSignal -Reference $Now
    $DaysSinceActualHoursChange = Get-DaysSinceSignalChange -Signal $ActualHoursSignal -Reference $Now
    $HoursLastChangedStr = if ($HoursSignal -and $HoursSignal.LastChanged) { $HoursSignal.LastChanged } else { "" }
    $TaskLastChangedStr  = if ($TaskSignal -and $TaskSignal.LastChanged) { $TaskSignal.LastChanged } else { "" }
    $ActualHoursLastChangedStr = if ($ActualHoursSignal -and $ActualHoursSignal.LastChanged) { $ActualHoursSignal.LastChanged } else { "" }

    # Three independent signals, any one of which is enough to call the project stale.
    $StaleActualHours = ($null -ne $DaysSinceActualHoursChange) -and ($DaysSinceActualHoursChange -gt $STALE_DAYS_HOURS)
    $StaleTasks = ($null -ne $DaysSinceTaskChange) -and ($DaysSinceTaskChange -gt $STALE_DAYS_TASKS)
    $StalePhase = ($null -ne $DaysSinceStatusChange) -and ($DaysSinceStatusChange -gt $STALE_DAYS_PHASE)
    $Stale = $StaleActualHours -or $StaleTasks -or $StalePhase

    # "New" + stale alone isn't enough - some projects sit at Status "New" while real work
    # (task/hours) has already been logged, meaning Status just never got updated. Those
    # aren't stuck in intake, so they're excluded here and fall through to the plain "Stale"
    # flag instead.
    $NoProgress = ($PctTask -eq 0) -and ($PctHours -eq 0)
    $StalledIntake = ($p.Status -eq "New") -and $Stale -and $NoProgress

    $NoLead = [string]::IsNullOrWhiteSpace($p.'Project Lead') -or [string]::IsNullOrWhiteSpace($p.'Project Team Tech Lead')
    $NeedPCM = $p.Phase -eq "Closing"

    $p | Add-Member -NotePropertyName "StatusDateParsed" -NotePropertyValue $StatusDate -Force
    $p | Add-Member -NotePropertyName "% Complete - Task" -NotePropertyValue $PctTask -Force
    $p | Add-Member -NotePropertyName "% Complete - Hours" -NotePropertyValue $PctHours -Force
    $p | Add-Member -NotePropertyName "Actual Hours" -NotePropertyValue $ActualHours -Force
    $p | Add-Member -NotePropertyName "Days Since Actual Hours Change" -NotePropertyValue $DaysSinceActualHoursChange -Force
    $p | Add-Member -NotePropertyName "Days Since Status Change" -NotePropertyValue $DaysSinceStatusChange -Force
    $p | Add-Member -NotePropertyName "Days Since Hours Change" -NotePropertyValue $DaysSinceHoursChange -Force
    $p | Add-Member -NotePropertyName "Days Since Task Change" -NotePropertyValue $DaysSinceTaskChange -Force
    $p | Add-Member -NotePropertyName "% Hours Last Changed" -NotePropertyValue $HoursLastChangedStr -Force
    $p | Add-Member -NotePropertyName "% Task Last Changed" -NotePropertyValue $TaskLastChangedStr -Force
    $p | Add-Member -NotePropertyName "Actual Hours Last Changed" -NotePropertyValue $ActualHoursLastChangedStr -Force
    $p | Add-Member -NotePropertyName "Flag: Stalled Intake" -NotePropertyValue $StalledIntake -Force
    $p | Add-Member -NotePropertyName "Flag: Stale" -NotePropertyValue $Stale -Force
    $p | Add-Member -NotePropertyName "Flag: Stale - Actual Hours" -NotePropertyValue $StaleActualHours -Force
    $p | Add-Member -NotePropertyName "Flag: Stale - Tasks" -NotePropertyValue $StaleTasks -Force
    $p | Add-Member -NotePropertyName "Flag: Stale - Phase" -NotePropertyValue $StalePhase -Force
    $p | Add-Member -NotePropertyName "Flag: No Lead(s)" -NotePropertyValue $NoLead -Force
    $p | Add-Member -NotePropertyName "Flag: Need PCM" -NotePropertyValue $NeedPCM -Force
}

foreach ($p in $Projects) {
    if ([string]::IsNullOrWhiteSpace($p.'Project Lead')) {
        $p.'Project Lead' = $NO_LEAD_LABEL
    }
}

if (-not (Test-Path -LiteralPath $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }

# Detail CSV - one row per in-scope project, for drill-down/audit.
$DetailRows = foreach ($p in ($Projects | Sort-Object "Project Lead", "Phase")) {
    [PSCustomObject]@{
        "Project Number"           = $p.'Project Number'
        "Account"                  = $p.Account
        "Project Name"             = $p.'Project Name'
        "Project Lead"             = $p.'Project Lead'
        "Status"                   = $p.Status
        "Phase"                    = $p.Phase
        "Project Team Tech Lead"   = $p.'Project Team Tech Lead'
        "Status Date"              = if ($p.StatusDateParsed) { $p.StatusDateParsed.ToString("yyyy-MM-dd HH:mm:ss") } else { "" }
        "Days Since Status Change" = $p.'Days Since Status Change'
        "% Complete - Task"        = $p.'% Complete - Task'
        "% Task Last Changed"      = $p.'% Task Last Changed'
        "Days Since Task Change"   = $p.'Days Since Task Change'
        "Actual Hours"             = $p.'Actual Hours'
        "Actual Hours Last Changed" = $p.'Actual Hours Last Changed'
        "Days Since Actual Hours Change" = $p.'Days Since Actual Hours Change'
        "% Complete - Hours"       = $p.'% Complete - Hours'
        "% Hours Last Changed"     = $p.'% Hours Last Changed'
        "Days Since Hours Change"  = $p.'Days Since Hours Change'
        "Flag: Stalled Intake"     = $p.'Flag: Stalled Intake'
        "Flag: Stale"              = $p.'Flag: Stale'
        "Flag: Stale - Actual Hours" = $p.'Flag: Stale - Actual Hours'
        "Flag: Stale - Tasks"      = $p.'Flag: Stale - Tasks'
        "Flag: Stale - Phase"      = $p.'Flag: Stale - Phase'
        "Flag: No Lead(s)"         = $p.'Flag: No Lead(s)'
        "Flag: Need PCM"           = $p.'Flag: Need PCM'
    }
}
Export-Utf8NoBomCsv -Path $OutputDetail -InputObject @($DetailRows)

$FlagCols = @("Flag: Stalled Intake", "Flag: Stale", "Flag: No Lead(s)", "Flag: Need PCM")
$FlagLabels = @("Stalled Intake", "Stale", "No Lead(s)", "Need PCM")
$FlagCounts = @{}
for ($i = 0; $i -lt $FlagCols.Count; $i++) {
    $FlagCounts[$FlagLabels[$i]] = @($Projects | Where-Object { $_.($FlagCols[$i]) }).Count
}

# By Project Lead - flagged projects only. Flags aren't mutually exclusive (a project can
# trip more than one), so "Total Flagged" counts distinct flagged projects rather than
# summing the flag columns.
$Flagged = @($Projects | Where-Object { $_.'Flag: Stalled Intake' -or $_.'Flag: Stale' -or $_.'Flag: No Lead(s)' -or $_.'Flag: Need PCM' })

$ByLead = @{}
foreach ($p in $Flagged) {
    $Lead = $p.'Project Lead'
    if (-not $ByLead.ContainsKey($Lead)) {
        $ByLead[$Lead] = @{}
        foreach ($label in $FlagLabels) { $ByLead[$Lead][$label] = 0 }
        $ByLead[$Lead]["Total Flagged"] = 0
    }
    for ($i = 0; $i -lt $FlagCols.Count; $i++) {
        if ($p.($FlagCols[$i])) { $ByLead[$Lead][$FlagLabels[$i]]++ }
    }
    $ByLead[$Lead]["Total Flagged"]++
}

$ByLeadRows = foreach ($Lead in $ByLead.Keys) {
    $Row = [ordered]@{ "Project Lead" = $Lead }
    foreach ($label in $FlagLabels) { $Row[$label] = $ByLead[$Lead][$label] }
    $Row["Total Flagged"] = $ByLead[$Lead]["Total Flagged"]
    [PSCustomObject]$Row
}
$ByLeadRows = @($ByLeadRows | Sort-Object -Property "Total Flagged" -Descending)

# CSV equivalent of the markdown summary table, Total row included.
$TotalRow = [ordered]@{ "Project Lead" = "Total" }
foreach ($label in $FlagLabels) { $TotalRow[$label] = $FlagCounts[$label] }
$TotalRow["Total Flagged"] = $Flagged.Count
$SummaryRows = @($ByLeadRows) + [PSCustomObject]$TotalRow
Export-Utf8NoBomCsv -Path $OutputSummaryCsv -InputObject $SummaryRows

$Lines = [System.Collections.Generic.List[string]]::new()
$Lines.Add("# Project Management Coordinator Report (Flags) - $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
$Lines.Add("")
$Lines.Add("## Executive Summary")
$Lines.Add("")
$Lines.Add("Project(s) excluded: $($Result.ExcludedCount) (see ../data/reference/excluded-projects.csv).")
$Lines.Add("")
$Lines.Add("Project(s) analyzed: $($Projects.Count)")
$Lines.Add("")
foreach ($label in $FlagLabels) { $Lines.Add("- $label`: $($FlagCounts[$label])") }
$Lines.Add("")
$Lines.Add("## Flags by Project Manager")
$Lines.Add("")
$Lines.Add("| Project Lead | " + ($FlagLabels -join " | ") + " | Total Flagged |")
$Lines.Add("|" + ("---|" * ($FlagLabels.Count + 2)))
foreach ($row in $ByLeadRows) {
    $Vals = ($FlagLabels | ForEach-Object { $row.$_ }) -join " | "
    $Lines.Add("| $($row.'Project Lead') | $Vals | $($row.'Total Flagged') |")
}
$TotalVals = ($FlagLabels | ForEach-Object { $FlagCounts[$_] }) -join " | "
$Lines.Add("| **Total** | $TotalVals | $($Flagged.Count) |")
$Lines.Add("")
$Lines.Add("Summary (CSV): $(Split-Path $OutputSummaryCsv -Leaf)  ")
$Lines.Add("Per-project detail: $(Split-Path $OutputDetail -Leaf)")

Set-Utf8NoBomContent -Path $OutputSummary -Value ($Lines -join "`n")

Write-Host "Projects analyzed: $($Projects.Count) (excluded $($Result.ExcludedCount) project(s))"
Write-Host "Wrote $OutputDetail, $OutputSummary, and $OutputSummaryCsv"
