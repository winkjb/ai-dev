<#
.SYNOPSIS
    Coordinator report: open project counts by Project Lead x Phase.
    PowerShell rewrite of the retired project_summary_pm.py.

.EXAMPLE
    .\Export-CoordinatorPMReport.ps1
#>

[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot "CoordinatorCommon.ps1")

$OutputDir = Join-Path $PSScriptRoot "output"
$OutputDetail = Join-Path $OutputDir "coordinator-project-pm-detail.csv"
$OutputSummary = Join-Path $OutputDir "coordinator-project-pm-summary.md"
$OutputSummaryCsv = Join-Path $OutputDir "coordinator-project-pm-summary.csv"

$Data = Import-CoordinatorProjectData
$Result = Remove-ExcludedProjects -Projects $Data.Projects -Excluded $Data.Excluded
$Projects = Add-ProjectPhase -Projects $Result.Projects -PhaseMap $Data.PhaseMap

foreach ($p in $Projects) {
    if ([string]::IsNullOrWhiteSpace($p.'Project Lead')) {
        $p.'Project Lead' = $NO_LEAD_LABEL
    }
}

$PhaseCols = @($PHASE_ORDER)
if (@($Projects | Where-Object { $_.Phase -eq $UNKNOWN_PHASE_LABEL }).Count -gt 0) {
    $PhaseCols += $UNKNOWN_PHASE_LABEL
}

# Pivot: Project Lead x Phase counts.
$ByLead = @{}
foreach ($p in $Projects) {
    $Lead = $p.'Project Lead'
    if (-not $ByLead.ContainsKey($Lead)) {
        $ByLead[$Lead] = @{}
        foreach ($c in $PhaseCols) { $ByLead[$Lead][$c] = 0 }
    }
    $ByLead[$Lead][$p.Phase]++
}

$Pivot = foreach ($Lead in $ByLead.Keys) {
    $Row = [ordered]@{ "Project Lead" = $Lead }
    $Total = 0
    foreach ($c in $PhaseCols) { $Row[$c] = $ByLead[$Lead][$c]; $Total += $ByLead[$Lead][$c] }
    $Row["Total"] = $Total
    [PSCustomObject]$Row
}
$Pivot = @($Pivot | Sort-Object -Property Total -Descending)

$Totals = @{}
foreach ($c in $PhaseCols) { $Totals[$c] = ($Pivot | Measure-Object -Property $c -Sum).Sum }
$GrandTotal = ($Pivot | Measure-Object -Property Total -Sum).Sum

if (-not (Test-Path -LiteralPath $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }

# Detail CSV - one row per in-scope project, for drill-down/audit.
$DetailCols = @("Project Number", "Account", "Project Name", "Project Lead", "Status", "Phase", "Project Team Tech Lead", "Last Activity Time")
$DetailRows = @($Projects | Select-Object $DetailCols | Sort-Object "Project Lead", "Phase")
Export-Utf8NoBomCsv -Path $OutputDetail -InputObject $DetailRows

# CSV equivalent of the markdown summary table, Total row included.
$SummaryRows = @($Pivot | Select-Object ([string[]](@("Project Lead") + $PhaseCols + @("Total"))))
$TotalRow = [ordered]@{ "Project Lead" = "Total" }
foreach ($c in $PhaseCols) { $TotalRow[$c] = $Totals[$c] }
$TotalRow["Total"] = $GrandTotal
$SummaryRows += [PSCustomObject]$TotalRow
Export-Utf8NoBomCsv -Path $OutputSummaryCsv -InputObject $SummaryRows

$Lines = [System.Collections.Generic.List[string]]::new()
$Lines.Add("# Project Management Coordinator Report (By Project Manager) - $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
$Lines.Add("")
$Lines.Add("## Executive Summary")
$Lines.Add("")
$Lines.Add("Project(s) excluded: $($Result.ExcludedCount) (see ../data/reference/excluded-projects.csv).")
$Lines.Add("")
$Lines.Add("Project(s) analyzed: $($Projects.Count)")
$Lines.Add("")
foreach ($c in $PhaseCols) { $Lines.Add("- $c`: $($Totals[$c])") }
$Lines.Add("")
$Lines.Add("## Projects By Project Manager")
$Lines.Add("")
$Lines.Add("| Project Lead | " + ($PhaseCols -join " | ") + " | Total |")
$Lines.Add("|" + ("---|" * ($PhaseCols.Count + 2)))
foreach ($row in $Pivot) {
    $Vals = ($PhaseCols | ForEach-Object { $row.$_ }) -join " | "
    $Lines.Add("| $($row.'Project Lead') | $Vals | $($row.Total) |")
}
$TotalVals = ($PhaseCols | ForEach-Object { $Totals[$_] }) -join " | "
$Lines.Add("| **Total** | $TotalVals | $GrandTotal |")
$Lines.Add("")
$Lines.Add("Summary (CSV): $(Split-Path $OutputSummaryCsv -Leaf)  ")
$Lines.Add("Per-project detail: $(Split-Path $OutputDetail -Leaf)")

Set-Utf8NoBomContent -Path $OutputSummary -Value ($Lines -join "`n")

Write-Host "Projects analyzed: $($Projects.Count) (excluded $($Result.ExcludedCount) project(s))"
Write-Host "Wrote $OutputDetail, $OutputSummary, and $OutputSummaryCsv"
