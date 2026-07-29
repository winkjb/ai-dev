<#
.SYNOPSIS
    Deletes monthly-rotated log files older than the retention window. Meant to run monthly
    via the central dispatcher (scripts/Invoke-ScheduledScripts.ps1), not as its own scheduled
    task.

.DESCRIPTION
    Every log file this workspace writes is named with a trailing yyyy-MM month stamp
    (e.g. Dispatcher_2026-07.log, scheduled-run-2026-07.log) - one file per calendar month,
    never appended to across a month boundary. That makes retention simple: a file's *name*
    says its age, so there's no need to parse individual log lines - just delete whole files
    whose stamped month is older than the cutoff.

    Scans a fixed list of known log directories (below) rather than searching the whole repo,
    so a coincidentally-named .log file elsewhere never gets caught up in this by accident.

.PARAMETER RetentionMonths
    Keep log files stamped with a month within this many months of today; delete anything
    older. Defaults to 12.

.PARAMETER LogDirectories
    Directories to scan for dated .log files. Defaults to every known logging location in
    this workspace - add new ones here as new coordinators/dispatched scripts start logging.

.PARAMETER DryRun
    Lists what WOULD be deleted without deleting anything.

.EXAMPLE
    .\Remove-OldLogs.ps1 -DryRun
#>

[CmdletBinding()]
param(
    [int]$RetentionMonths = 12,

    [string[]]$LogDirectories = @(
        (Join-Path $PSScriptRoot "..\data\output"),
        (Join-Path $PSScriptRoot "..\project-management\01-coordinator\output"),
        (Join-Path $PSScriptRoot "..\service-delivery\01-coordinator\output"),
        (Join-Path $PSScriptRoot "..\security\01-coordinator\output")
    ),

    [switch]$DryRun
)

# First-of-month cutoff, so "12 months" means "keep this month and the 11 before it" -
# a clean calendar-month boundary rather than a fuzzy day-count.
$ThisMonth = Get-Date -Day 1 -Hour 0 -Minute 0 -Second 0 -Millisecond 0
$Cutoff = $ThisMonth.AddMonths(-$RetentionMonths)

$DatePattern = '(\d{4})-(\d{2})(?=\.log$)'

$Deleted = 0
$Kept = 0
$Unmatched = 0

foreach ($Dir in $LogDirectories) {
    if (-not (Test-Path -LiteralPath $Dir)) {
        Write-Host "Skipping (not found): $Dir"
        continue
    }

    Get-ChildItem -LiteralPath $Dir -Filter "*.log" -File | ForEach-Object {
        $Match = [regex]::Match($_.Name, $DatePattern)
        if (-not $Match.Success) {
            Write-Host "Skipping (no yyyy-MM stamp in name): $($_.FullName)"
            $script:Unmatched++
            return
        }

        $FileMonth = Get-Date -Year ([int]$Match.Groups[1].Value) -Month ([int]$Match.Groups[2].Value) -Day 1 -Hour 0 -Minute 0 -Second 0 -Millisecond 0

        if ($FileMonth -lt $Cutoff) {
            if ($DryRun) {
                Write-Host "Would delete (older than $RetentionMonths month(s)): $($_.FullName)"
            } else {
                Remove-Item -LiteralPath $_.FullName -Force
                Write-Host "Deleted (older than $RetentionMonths month(s)): $($_.FullName)"
            }
            $script:Deleted++
        } else {
            $script:Kept++
        }
    }
}

Write-Host ""
Write-Host "$(if ($DryRun) { 'Would delete' } else { 'Deleted' }): $Deleted | Kept: $Kept | Unmatched (left alone): $Unmatched"
