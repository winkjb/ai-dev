<#
.SYNOPSIS
    Deletes monthly-rotated log files older than the retention window. Meant to run monthly
    via the central dispatcher (scripts/Invoke-ScheduledScripts.ps1), not as its own scheduled
    task.

.DESCRIPTION
    Every log file this workspace writes is named with a trailing yyyy-MM month stamp
    (e.g. dispatcher_2026-07.log, scheduled-run-2026-07.log) - one file per calendar month,
    never appended to across a month boundary. That makes retention simple: a file's *name*
    says its age, so there's no need to parse individual log lines - just delete whole files
    whose stamped month is older than the cutoff.

    Discovers log directories dynamically (every folder literally named "output" anywhere in
    the repo) rather than relying on a hand-maintained list, so new coordinators/dispatched
    scripts get covered automatically. Safety instead comes from the .log extension filter plus
    the required yyyy-MM stamp below - a coincidentally-named .log file elsewhere still won't
    get caught up in this by accident, it just gets reported as unmatched and left alone.

.PARAMETER RetentionMonths
    Keep log files stamped with a month within this many months of today; delete anything
    older. Defaults to 12.

.PARAMETER LogDirectories
    Directories to scan for dated .log files. Defaults to every folder named "output" found
    anywhere under the repo root - pass this explicitly to override/restrict the scan.

.PARAMETER DryRun
    Lists what WOULD be deleted without deleting anything.

.EXAMPLE
    .\Remove-OldLogs.ps1 -DryRun
#>

[CmdletBinding()]
param(
    [int]$RetentionMonths = 12,

    [string[]]$LogDirectories,

    [switch]$DryRun
)

# $PSScriptRoot is unreliable (empty) at param-default-value evaluation time when this script
# is invoked via "powershell.exe -File <fullpath>" (Task Scheduler's invocation style) -
# confirmed live; see scripts/Invoke-ScheduledScripts.ps1 for the same bug and full
# explanation. Resolving the repo root and default directories here in the body instead.
if (-not $LogDirectories) {
    $RepoRoot = Split-Path $PSScriptRoot -Parent
    $LogDirectories = @(Get-ChildItem -LiteralPath $RepoRoot -Recurse -Directory -Filter "output" | Select-Object -ExpandProperty FullName)
}

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
