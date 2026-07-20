<#
.SYNOPSIS
    Coordinator report: Stalled Intake / Stale / No Lead(s) / Need PCM flags by Project Lead.
    PowerShell rewrite of the retired project_summary_flags.py.

.EXAMPLE
    .\Export-CoordinatorFlagsReport.ps1
#>

[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot "CoordinatorCommon.ps1")

$STALE_DAYS = 14
$STALE_DAYS_ON_HOLD = 21

$OutputDir = Join-Path $PSScriptRoot "output"
$OutputDetail = Join-Path $OutputDir "coordinator-project-flags-detail.csv"
$OutputSummary = Join-Path $OutputDir "coordinator-project-flags-summary.md"
$OutputSummaryCsv = Join-Path $OutputDir "coordinator-project-flags-summary.csv"

$Data = Import-CoordinatorProjectData
$Result = Remove-ExcludedProjects -Projects $Data.Projects -Excluded $Data.Excluded
$Projects = Add-ProjectPhase -Projects $Result.Projects -PhaseMap $Data.PhaseMap

$Now = Get-Date

foreach ($p in $Projects) {

    $LastActivity = $null
    if (-not [string]::IsNullOrWhiteSpace($p.'Last Activity Time')) {
        $Parsed = [datetime]::MinValue
        if ([datetime]::TryParseExact($p.'Last Activity Time', "MM/dd/yyyy hh:mm tt", [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$Parsed)) {
            $LastActivity = $Parsed
        }
    }

    $PctTask = [double]($p.'% Complete - Task' -replace '[%,]', '')
    $PctHours = [double]($p.'% Complete - Hours' -replace '[%,]', '')

    $DaysSinceLastActivity = $null
    if ($LastActivity) { $DaysSinceLastActivity = [int]($Now - $LastActivity).TotalDays }

    $StaleThreshold = if ($p.Phase -eq "On Hold/Inactive") { $STALE_DAYS_ON_HOLD } else { $STALE_DAYS }
    $Stale = ($null -ne $DaysSinceLastActivity) -and ($DaysSinceLastActivity -gt $StaleThreshold)

    # "New" + stale alone isn't enough - some projects sit at Status "New" while real work
    # (task/hours) has already been logged, meaning Status just never got updated. Those
    # aren't stuck in intake, so they're excluded here and fall through to the plain "Stale"
    # flag instead.
    $NoProgress = ($PctTask -eq 0) -and ($PctHours -eq 0)
    $StalledIntake = ($p.Status -eq "New") -and $Stale -and $NoProgress

    $NoLead = [string]::IsNullOrWhiteSpace($p.'Project Lead') -or [string]::IsNullOrWhiteSpace($p.'Project Team Tech Lead')
    $NeedPCM = $p.Phase -eq "Closing"

    $p | Add-Member -NotePropertyName "LastActivityParsed" -NotePropertyValue $LastActivity -Force
    $p | Add-Member -NotePropertyName "% Complete - Task" -NotePropertyValue $PctTask -Force
    $p | Add-Member -NotePropertyName "% Complete - Hours" -NotePropertyValue $PctHours -Force
    $p | Add-Member -NotePropertyName "Days Since Last Activity" -NotePropertyValue $DaysSinceLastActivity -Force
    $p | Add-Member -NotePropertyName "Flag: Stalled Intake" -NotePropertyValue $StalledIntake -Force
    $p | Add-Member -NotePropertyName "Flag: Stale" -NotePropertyValue $Stale -Force
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
        "Last Activity Time"       = if ($p.LastActivityParsed) { $p.LastActivityParsed.ToString("yyyy-MM-dd HH:mm:ss") } else { "" }
        "Days Since Last Activity" = $p.'Days Since Last Activity'
        "% Complete - Task"        = $p.'% Complete - Task'
        "% Complete - Hours"       = $p.'% Complete - Hours'
        "Flag: Stalled Intake"     = $p.'Flag: Stalled Intake'
        "Flag: Stale"              = $p.'Flag: Stale'
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
