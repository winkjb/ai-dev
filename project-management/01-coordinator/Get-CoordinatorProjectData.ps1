<#
.SYNOPSIS
    Pulls open projects from Autotask and writes them to data/raw/Project Search Results.csv,
    replacing the old manual UI export as the source for the three coordinator reports.

.DESCRIPTION
    "Open" here means what Brad was actually exporting by hand: status != Complete and
    projectType != Proposal - filtered server-side so the pull never touches the other
    ~4500+ closed/proposal projects in this Autotask instance.

    Company and Project Lead names are resolved via batched Companies/Resources lookups
    (not one call per project). % Complete - Hours is actualHours/estimatedTime - confirmed
    an exact match against historical CSV values. % Complete - Task is (completed tasks /
    total tasks) per project via the Tasks entity - close to, but not a byte-exact match for,
    the historical export (Autotask's own UI likely weights this differently internally), but
    it reproduces the zero/nonzero behavior the "Stalled Intake" flag downstream depends on.

.EXAMPLE
    .\Get-CoordinatorProjectData.ps1
#>

[CmdletBinding()]
param(
    [string]$OutputPath
)

if (-not $OutputPath) { $OutputPath = Join-Path $PSScriptRoot "..\data\raw\Project Search Results.csv" }

$FunctionsScript = Join-Path $PSScriptRoot "..\..\scripts\Autotask-Functions-Common.ps1"
if (-not (Test-Path -LiteralPath $FunctionsScript)) {
    Write-Error "Shared functions script not found: $FunctionsScript"
    exit 1
}
. $FunctionsScript

function Get-InBatches {
    # Autotask's "in" filter has an undocumented practical limit - chunk to be safe rather
    # than find that limit the hard way against several hundred distinct IDs at once.
    #
    # PowerShell enumerates any IEnumerable placed in a function's output stream, including
    # nested one level deep - a List[object] containing one 69-item array gets flattened
    # into 69 separate outputs by the time `foreach ($b in Get-InBatches ...)` sees it. The
    # unary-comma trick doesn't survive an intermediate variable assignment; the only fix
    # that actually holds is Write-Output -NoEnumerate on the final result.
    param([array]$Values, [int]$BatchSize = 200)
    $Batches = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $Values.Count; $i += $BatchSize) {
        $End = [Math]::Min($i + $BatchSize - 1, $Values.Count - 1)
        $Batches.Add([object[]]($Values[$i..$End]))
    }
    Write-Output -NoEnumerate $Batches
}

Write-Host "Connecting to Autotask..." -ForegroundColor Cyan
$Connection = Connect-Autotask

Write-Host "Fetching status/project type picklists..." -ForegroundColor Cyan
$StatusLabels = Get-AutotaskPicklist -Connection $Connection -Entity "Projects" -FieldName "status"
$TypeLabels = Get-AutotaskPicklist -Connection $Connection -Entity "Projects" -FieldName "projectType"

Write-Host "Fetching open projects (status != Complete, type != Proposal)..." -ForegroundColor Cyan
$Projects = Invoke-AutotaskQuery -Connection $Connection -Entity "Projects" -Filter @(
    @{ op = "noteq"; field = "status"; value = 5 },
    # 2=Proposal, 3=Template, 8=Baseline - the old manual export never contained Template
    # or Baseline rows (confirmed against historical data: 0 of 284 rows), only
    # Client/Internal/Proposal. Proposal is excluded here too now per Brad's request;
    # excluded-projects.csv's belt-and-suspenders Proposal exclusion still applies downstream.
    @{ op = "notIn"; field = "projectType"; value = @(2, 3, 8) }
)
Write-Host "  $($Projects.Count) open project(s) found."

Write-Host "Resolving company names..." -ForegroundColor Cyan
$CompanyIds = @($Projects.companyID | Where-Object { $_ } | Select-Object -Unique)
$CompanyNames = @{}
foreach ($Batch in (Get-InBatches -Values $CompanyIds)) {
    $Companies = Invoke-AutotaskQuery -Connection $Connection -Entity "Companies" -Filter @(
        @{ op = "in"; field = "id"; value = $Batch }
    )
    foreach ($c in $Companies) { $CompanyNames[[string]$c.id] = $c.companyName }
}

Write-Host "Resolving project lead names..." -ForegroundColor Cyan
$ResourceIds = @($Projects.projectLeadResourceID | Where-Object { $_ } | Select-Object -Unique)
$ResourceNames = @{}
foreach ($Batch in (Get-InBatches -Values $ResourceIds)) {
    $Resources = Invoke-AutotaskQuery -Connection $Connection -Entity "Resources" -Filter @(
        @{ op = "in"; field = "id"; value = $Batch }
    )
    foreach ($r in $Resources) { $ResourceNames[[string]$r.id] = "$($r.lastName), $($r.firstName)" }
}

Write-Host "Fetching tasks for % Complete - Task..." -ForegroundColor Cyan
$ProjectIds = @($Projects.id)
$TaskCounts = @{}   # projectID -> @{ Total = n; Complete = n }
foreach ($Batch in (Get-InBatches -Values $ProjectIds)) {
    $Tasks = Invoke-AutotaskQuery -Connection $Connection -Entity "Tasks" -Filter @(
        @{ op = "in"; field = "projectID"; value = $Batch }
    )
    foreach ($t in $Tasks) {
        $key = [string]$t.projectID
        if (-not $TaskCounts.ContainsKey($key)) { $TaskCounts[$key] = @{ Total = 0; Complete = 0 } }
        $TaskCounts[$key].Total++
        if ($t.status -eq 5) { $TaskCounts[$key].Complete++ }
    }
}

Write-Host "Shaping output rows..." -ForegroundColor Cyan
$Rows = foreach ($p in $Projects) {

    $TechLead = ($p.userDefinedFields | Where-Object { $_.name -eq "Project Team Tech Lead" }).value

    $TaskInfo = $TaskCounts[[string]$p.id]
    $PctTask = if ($TaskInfo -and $TaskInfo.Total -gt 0) { ($TaskInfo.Complete / $TaskInfo.Total) * 100 } else { 0 }

    $PctHours = if ($p.estimatedTime -and $p.estimatedTime -ne 0) { ($p.actualHours / $p.estimatedTime) * 100 } else { 0 }

    [PSCustomObject]@{
        "Project Number"       = $p.projectNumber
        "Project Name"         = $p.projectName
        "Account"              = $CompanyNames[[string]$p.companyID]
        "Project Type"         = $TypeLabels[[string]$p.projectType]
        "Start Date"           = if ($p.startDateTime) { [datetime]$p.startDateTime | Get-Date -Format "MM/dd/yyyy" } else { "" }
        "End Date"             = if ($p.endDateTime) { [datetime]$p.endDateTime | Get-Date -Format "MM/dd/yyyy" } else { "" }
        "Status"               = $StatusLabels[[string]$p.status]
        "Project Lead"         = $ResourceNames[[string]$p.projectLeadResourceID]
        "% Complete - Task"    = "{0:N2}%" -f $PctTask
        "% Complete - Hours"   = "{0:N2}%" -f $PctHours
        "Last Activity Time"   = if ($p.lastActivityDateTime) { [datetime]$p.lastActivityDateTime | Get-Date -Format "MM/dd/yyyy hh:mm tt" } else { "" }
        "Project Team Tech Lead" = $TechLead
    }
}

$OutputDir = Split-Path $OutputPath -Parent
if (-not (Test-Path -LiteralPath $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
$Rows | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

Write-Host "Wrote $($Rows.Count) row(s) to $OutputPath" -ForegroundColor Green
